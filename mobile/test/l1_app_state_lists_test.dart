import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/device_lists.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'native_test_env.dart';

/// L1-3 through AppState with the real native engine and real pins: every
/// version this device signs (setup genesis, migration genesis, removal,
/// recovery key) reaches the server and verifies as the next step of the
/// account's chain. The fake server keeps the chain the way L1-2 does
/// (version = head + 1, else 409 `device_list_conflict`).
const _origin = 'https://localhost:8443';
const _account = 'acct_owner';
const _own = 'dev_owner';

void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  test('setup carries a genesis that names this device with its key', () async {
    final api = _ListApi(bindings);
    final crypto =
        NativeCryptoService(bindings: bindings, localStore: MemoryLocalStore());
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    await state.createOwner(_origin, 'owner', 'password', 'setup');
    expect(api.chain, hasLength(1));
    final chain = bindings.checkDeviceListChain(idBytes(_account), api.chain);
    expect(chain.head.change, DeviceListChange.genesis);
    expect(chain.head.entries.single.deviceId, idBytes(_own));
    expect(
        chain.head.entries.single.signingKey, await crypto.currentSigningKey());
    // Review fix: the own genesis is the account's anchor, not something
    // the first refresh takes from the server on trust: a server that shows
    // another chain for the account is not adopted.
    final pin = await crypto.localStore.loadDeviceListPin(_account);
    expect(pin?.version, 1);
    expect(pin?.headStatement, api.chain.single);
  }, skip: skip);

  test('the own genesis is pinned even when the server shows another chain',
      () async {
    final api = _ListApi(bindings);
    final crypto =
        NativeCryptoService(bindings: bindings, localStore: MemoryLocalStore());
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    // The server stores the real genesis but serves a made-up one: a ghost
    // device that signed a genesis of its own for this account.
    final ghost = bindings.createDevice(_account, 'dev_ghost');
    addTearDown(ghost.close);
    api.served = [
      ghost.signDeviceList(
          DeviceListBody(
            accountId: idBytes(_account),
            version: 1,
            prevHash: DeviceListBody.zeroHash,
            createdAtMs: 1,
            change: DeviceListChange.genesis,
            entries: [
              DeviceListPair(idBytes('dev_ghost'), ghost.signingPublicKey())
            ],
          ),
          idBytes('dev_ghost')),
    ];
    await state.createOwner(_origin, 'owner', 'password', 'setup');
    final pin = await crypto.localStore.loadDeviceListPin(_account);
    expect(pin?.headStatement, api.chain.single,
        reason: 'the own genesis, not the chain the server served');
    expect(pin?.standing(idBytes('dev_ghost'), ghost.signingPublicKey()),
        PinStanding.unknown);
  }, skip: skip);

  for (final registration in [false, true]) {
    for (final read in ['empty', 'missing', 'unavailable']) {
      test(
          '${registration ? 'registration' : 'setup'} keeps its genesis '
          'when list reads are $read', () async {
        final api = _ListApi(bindings)..listRead = read;
        final store = MemoryLocalStore();
        final crypto =
            NativeCryptoService(bindings: bindings, localStore: store);
        final state = _state(api, crypto);
        addTearDown(state.dispose);
        if (registration) {
          await state.registerWithInvite(
              _origin, 'invite', 'owner', 'password');
        } else {
          await state.createOwner(_origin, 'owner', 'password', 'setup');
        }
        expect(api.chain, hasLength(1));
        final original = api.chain.single;
        expect(
            (await store.loadDeviceListPin(_account))?.headStatement, original);

        // Withholding the real list first must not allow a later first-use
        // replacement with a server-controlled identity for this account.
        final ghost = bindings.createDevice(_account, 'dev_ghost');
        addTearDown(ghost.close);
        api
          ..listRead = 'normal'
          ..served = [
            ghost.signDeviceList(
              DeviceListBody(
                accountId: idBytes(_account),
                version: 1,
                prevHash: DeviceListBody.zeroHash,
                createdAtMs: 1,
                change: DeviceListChange.genesis,
                entries: [
                  DeviceListPair(
                      idBytes('dev_ghost'), ghost.signingPublicKey()),
                ],
              ),
              idBytes('dev_ghost'),
            ),
          ];
        await DeviceListPins(
          store: store,
          source: _ApiLists(api),
          verifier: crypto,
        ).refresh(_account, force: true);
        final pin = await store.loadDeviceListPin(_account);
        expect(pin?.headStatement, original);
        expect(pin?.conflict, isFalse);
        expect(pin?.standing(idBytes('dev_ghost'), ghost.signingPublicKey()),
            PinStanding.unknown);
        expect(pin?.standing(idBytes(_own), await crypto.currentSigningKey()),
            PinStanding.approved);
      }, skip: skip);
    }
  }

  for (final registration in [false, true]) {
    for (final failure in ['journal', 'session', 'pin', 'crypto']) {
      test(
          '${registration ? 'registration' : 'setup'} stops at $failure '
          'storage failure and never restores through TOFU', () async {
        final api = _ListApi(bindings);
        final store = _FailingActivationStore(failure);
        final crypto =
            NativeCryptoService(bindings: bindings, localStore: store);
        final state = _state(api, crypto);
        if (registration) {
          await state.registerWithInvite(
              _origin, 'invite', 'owner', 'password');
        } else {
          await state.createOwner(_origin, 'owner', 'password', 'setup');
        }
        expect(state.session, isNull);
        expect(state.error, isNotNull);
        expect(api.listFetches, 0);
        final saved = await store.loadSession();
        expect(saved != null, failure == 'pin' || failure == 'crypto');
        final genesis = api.chain.single;
        final ghost = bindings.createDevice(_account, 'dev_ghost');
        addTearDown(ghost.close);
        api.served = [
          ghost.signDeviceList(
              DeviceListBody(
                accountId: idBytes(_account),
                version: 1,
                prevHash: DeviceListBody.zeroHash,
                createdAtMs: 1,
                change: DeviceListChange.genesis,
                entries: [
                  DeviceListPair(idBytes('dev_ghost'), ghost.signingPublicKey())
                ],
              ),
              idBytes('dev_ghost'))
        ];
        state.dispose();
        // Real cold start: no in-memory pending identity or pin cache.
        final restart = _state(
            api, NativeCryptoService(bindings: bindings, localStore: store));
        await restart.tryRestoreSession();
        expect(restart.session, isNull);
        expect(api.listFetches, 0);
        if (saved != null) {
          expect(restart.lifecycle, SessionLifecycle.recoveryRequired);
          // The pin failure persists across restart; no server chain is read.
          if (failure == 'pin') {
            expect(await store.loadDeviceListPin(_account), isNull);
            store.fail = false;
            await restart.tryRestoreSession();
          }
          expect((await store.loadDeviceListPin(_account))?.headStatement,
              genesis);
        }
        restart.dispose();
      }, skip: skip);
    }
  }

  for (final failure in ['crypto-committed', 'clear']) {
    test(
        'interruption after $failure restores the original native identity and pin',
        () async {
      final api = _ListApi(bindings);
      final store = _FailingActivationStore(failure);
      final crypto = NativeCryptoService(bindings: bindings, localStore: store);
      final state = _state(api, crypto);
      await state.createOwner(_origin, 'owner', 'password', 'setup');
      expect(state.session, isNull);
      expect(state.error, isNotNull);
      expect(await store.loadCryptoState(), isNotNull);
      final original = api.chain.single;
      final key = bindings
          .checkDeviceListChain(idBytes(_account), [original])
          .head
          .entries
          .single
          .signingKey;
      state.dispose();
      final ghost = bindings.createDevice(_account, 'dev_ghost');
      addTearDown(ghost.close);
      api.served = [
        ghost.signDeviceList(
            DeviceListBody(
              accountId: idBytes(_account),
              version: 1,
              prevHash: DeviceListBody.zeroHash,
              createdAtMs: 1,
              change: DeviceListChange.genesis,
              entries: [
                DeviceListPair(idBytes('dev_ghost'), ghost.signingPublicKey())
              ],
            ),
            idBytes('dev_ghost'))
      ];
      store.fail = false;
      final restoredCrypto =
          NativeCryptoService(bindings: bindings, localStore: store);
      final restart = _state(api, restoredCrypto);
      addTearDown(restart.dispose);
      await restart.tryRestoreSession();
      expect(restart.session?.deviceId, _own);
      expect(await restoredCrypto.currentSigningKey(), key);
      expect(
          (await store.loadDeviceListPin(_account))?.headStatement, original);
    }, skip: skip);
  }

  test('activation journal survives closing and reopening the database',
      () async {
    final dir = Directory.systemTemp.createTempSync('l1-anchor-journal');
    final file = File('${dir.path}/local.sqlite');
    final api = _ListApi(bindings);
    var database = EncryptedLocalDatabase(NativeDatabase(file));
    var store = _JournalDatabaseStore(database)..failPin = true;
    var state =
        _state(api, NativeCryptoService(bindings: bindings, localStore: store));
    try {
      await state.createOwner(_origin, 'owner', 'password', 'setup');
      expect(state.session, isNull);
      expect(await store.loadSession(), isNotNull);
      expect(await store.loadDeviceListPin(_account), isNull);
      state.dispose();
      await database.close();
      // No state survives in Dart. Only the on-disk journal/session do.
      database = EncryptedLocalDatabase(NativeDatabase(file));
      store = _JournalDatabaseStore(database);
      state = _state(
          api, NativeCryptoService(bindings: bindings, localStore: store));
      api.listRead = 'unavailable';
      await state.tryRestoreSession();
      expect((await store.loadDeviceListPin(_account))?.headStatement,
          api.chain.single);
      expect(api.listFetches, 0);
      // A crash before the first MLS save loses that key, requiring explicit
      // recovery. It must never activate using a replacement server anchor.
      expect(state.session, isNull);
      expect(state.lifecycle, SessionLifecycle.recoveryRequired);
    } finally {
      state.dispose();
      await database.close();
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);

  test(
      'an account from before L1 reviews its devices once; removals and the '
      'recovery key then chain, re-signed after a 409', () async {
    final api = _ListApi(bindings)..acceptGenesis = false;
    final store = MemoryLocalStore();
    final crypto = NativeCryptoService(bindings: bindings, localStore: store);
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    // An existing pre-L1 identity, with no locally signed genesis. New
    // accounts always keep their own genesis even if an old server ignores it.
    await crypto.createEnrollmentCredential(await api.reserveOwnerEnrollment());
    await store.saveSession(_ListApi._session);
    await crypto.activateSession(_ListApi._session);
    state
      ..api = api
      ..session = _ListApi._session;
    expect(api.chain, isEmpty);

    final phone = bindings.createDevice(_account, 'dev_phone');
    final stranger = bindings.createDevice(_account, 'dev_stranger');
    addTearDown(phone.close);
    addTearDown(stranger.close);
    api.serverDevices = [
      Device(
          id: _own,
          accountId: _account,
          name: 'This',
          createdAt: DateTime.utc(2026),
          signingKey: await crypto.currentSigningKey()),
      Device(
          id: 'dev_phone',
          accountId: _account,
          name: 'Phone',
          createdAt: DateTime.utc(2026),
          signingKey: phone.signingPublicKey()),
      Device(
          id: 'dev_stranger',
          accountId: _account,
          name: '?',
          createdAt: DateTime.utc(2026),
          signingKey: stranger.signingPublicKey()),
    ];
    await state.refreshDevices();
    await _until(() => state.ownDeviceListMissing);

    expect(await state.createApprovedDeviceList({_own, 'dev_phone'}),
        RecoveryActionResult.done);
    var chain = bindings.checkDeviceListChain(idBytes(_account), api.chain);
    expect(chain.head.change, DeviceListChange.migrationGenesis);
    expect(chain.head.entries.map((e) => utf8.decode(e.deviceId)),
        unorderedEquals([_own, 'dev_phone']));
    // The unticked device was revoked; it was never listed, so no version.
    expect(api.revoked, {'dev_stranger': null});
    expect(state.ownDeviceListMissing, isFalse);

    // Another device of the account moved the head meanwhile: the first
    // revoke is refused with 409, and it is re-signed on the new head.
    api
      ..conflictsLeft = 1
      ..revokeAttempts = 0;
    await state.revokeDevice('dev_phone');
    expect(api.revokeAttempts, 2);
    chain = bindings.checkDeviceListChain(idBytes(_account), api.chain);
    expect(chain.head.change, DeviceListChange.remove);
    expect(chain.head.entries.single.deviceId, idBytes(_own));
    expect(api.revoked['dev_phone'], api.chain.last);

    final draft = await state.createRecoveryKeyDraft();
    expect(await state.saveRecoveryKey(draft), RecoveryActionResult.done);
    chain = bindings.checkDeviceListChain(idBytes(_account), api.chain);
    expect(chain.head.change, DeviceListChange.recoveryKey);
    expect(chain.head.recoveryKey, isNotNull);
    expect(api.recoveryKeyLists.single, api.chain.last);
  }, skip: skip);
}

AppState _state(_ListApi api, NativeCryptoService crypto) => AppState(
      screenGuard: FakeScreenGuard(),
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: crypto.localStore,
      syncServiceFactory: (_, __) => _QuietSync(),
    );

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

class _ApiLists implements DeviceListSource {
  _ApiLists(this.api);
  final _ListApi api;

  @override
  Future<DeviceListPage?> fetchDeviceList(String accountId,
          {required int after}) =>
      api.fetchDeviceList('tok', accountId, after: after);
}

class _ListApi extends ApiClient with LegacySyncPageFake {
  _ListApi(this.bindings) : super(baseUrl: _origin);

  final NativeCryptoBindings bindings;
  final List<Uint8List> chain = <Uint8List>[];
  bool acceptGenesis = true;
  int conflictsLeft = 0;
  int revokeAttempts = 0;
  final Map<String, List<int>?> revoked = <String, List<int>?>{};
  final List<List<int>> recoveryKeyLists = <List<int>>[];
  List<Device> serverDevices = const <Device>[];

  static const _session = Session(
    baseUrl: _origin,
    token: 'tok',
    accountId: _account,
    deviceId: _own,
  );

  /// Takes [statement] the way L1-2 does: it must be the next version
  /// and verify against the head; else 409 or 400.
  void _take(List<int>? statement) {
    if (statement == null) return;
    if (conflictsLeft > 0) {
      conflictsLeft--;
      // Another device's version landed first (as the server says); the
      // client must refresh, re-sign and send again.
      throw ApiException(409,
          '{"error":"device_list_conflict","head_version":${chain.length}}');
    }
    final list = [...chain, Uint8List.fromList(statement)];
    try {
      bindings.checkDeviceListChain(idBytes(_account), list);
    } on NativeCryptoException {
      throw ApiException(400, '{"error":"invalid_device_list"}');
    }
    chain.add(Uint8List.fromList(statement));
  }

  @override
  Future<EnrollmentReservation> reserveOwnerEnrollment(
          {String setupToken = ''}) async =>
      const EnrollmentReservation(
          id: 'enroll_1',
          accountId: _account,
          deviceId: _own,
          challenge: <int>[1, 2, 3]);

  @override
  Future<Session> createOwner({
    required String username,
    required String password,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
    String setupToken = '',
    String? instanceName,
    List<int>? deviceList,
  }) async {
    if (acceptGenesis) _take(deviceList);
    return _session;
  }

  int listFetches = 0;
  String listRead = 'normal';

  /// What fetches serve instead of [chain] (a lying server).
  List<Uint8List>? served;

  @override
  Future<DeviceListPage?> fetchDeviceList(String token, String accountId,
      {required int after}) async {
    listFetches++;
    if (listRead == 'empty') {
      return const DeviceListPage(headVersion: 0, statements: [], more: false);
    }
    if (listRead == 'missing') return null;
    if (listRead == 'unavailable') throw ApiException(503, '');
    if (accountId != _account) return null;
    final rest = (served ?? chain).skip(after).toList();
    return DeviceListPage(
      headVersion: (served ?? chain).length,
      more: false,
      statements: [
        for (var i = 0; i < rest.length; i++)
          (version: after + i + 1, statement: rest[i]),
      ],
    );
  }

  @override
  Future<EnrollmentReservation> reserveRegistrationEnrollment(
          String inviteCode) =>
      reserveOwnerEnrollment();

  @override
  Future<Session> register({
    required String inviteCode,
    required String username,
    required String password,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
    List<int>? deviceList,
  }) async {
    if (acceptGenesis) _take(deviceList);
    return _session;
  }

  @override
  Future<int> publishDeviceList(String token, List<int> statement) async {
    _take(statement);
    return chain.length;
  }

  @override
  Future<void> revokeDevice(String token, String deviceId,
      {List<int>? deviceList}) async {
    revokeAttempts++;
    _take(deviceList);
    revoked[deviceId] = deviceList;
    serverDevices = [
      for (final device in serverDevices)
        if (device.id != deviceId) device,
    ];
  }

  @override
  Future<RecoveryKeyStatus> putRecoveryKey(String token,
      {required List<int> rkAuthPub,
      required List<int> rkId,
      List<int>? deviceList}) async {
    _take(deviceList);
    if (deviceList != null) recoveryKeyLists.add(deviceList);
    return RecoveryKeyStatus(
        available: true, configured: true, setAt: DateTime.utc(2026, 11, 7));
  }

  @override
  Future<List<Device>> devices(String token) async => serverDevices;

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<void> publishDeviceKeyPackages(String token, List<List<int>> packages,
      {Duration lifetime = const Duration(days: 14)}) async {}

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      const <SyncEvent>[];

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<Invite>> listInvites(String token) async => const <Invite>[];

  @override
  Future<List<Community>> listCommunities(String token) async =>
      const <Community>[];

  @override
  Future<RecoveryKeyStatus> recoveryKeyStatus(String token) async =>
      const RecoveryKeyStatus(available: true, configured: false);
}

/// Injects a durable-store failure at each activation boundary.
class _FailingActivationStore extends MemoryLocalStore {
  _FailingActivationStore(this.stage);
  final String stage;
  bool fail = true;

  @override
  Future<void> saveSetting(String name, String value) async {
    if (fail && stage == 'journal' && name.startsWith('l1.activation.')) {
      throw StateError('journal write failed');
    }
    if (fail &&
        stage == 'clear' &&
        name.startsWith('l1.activation.') &&
        value.isEmpty) {
      throw StateError('journal clear failed');
    }
    await super.saveSetting(name, value);
  }

  @override
  Future<void> saveSession(Session session) async {
    if (fail && stage == 'session') throw StateError('session write failed');
    await super.saveSession(session);
  }

  @override
  Future<bool> saveDeviceListPin(DeviceListPin pin,
      {required int? expectedVersion}) async {
    if (fail && stage == 'pin') throw StateError('pin write failed');
    return super.saveDeviceListPin(pin, expectedVersion: expectedVersion);
  }

  @override
  Future<void> saveCryptoState(StoredCryptoState state, int cursor) async {
    if (fail && stage == 'crypto') throw StateError('crypto write failed');
    await super.saveCryptoState(state, cursor);
    if (fail && stage == 'crypto-committed') {
      throw StateError('lost crypto write result');
    }
  }
}

/// Uses the production SQLite journal/session/pin primitives across reopen.
/// MLS state is deliberately absent: the injected failure precedes activation.
class _JournalDatabaseStore extends MemoryLocalStore {
  _JournalDatabaseStore(this.database);
  final EncryptedLocalDatabase database;
  bool failPin = false;

  @override
  Future<void> saveSetting(String name, String value) =>
      database.writeMetadata('setting:$name', value);

  @override
  Future<String?> loadSetting(String name) =>
      database.readMetadata('setting:$name');

  @override
  Future<void> saveSession(Session session) =>
      database.writeSessionJson(jsonEncode({
        'base_url': session.baseUrl,
        'token': session.token,
        'account_id': session.accountId,
        'device_id': session.deviceId,
      }));

  @override
  Future<Session?> loadSession() async {
    final raw = await database.readSessionJson();
    if (raw == null) return null;
    final value = jsonDecode(raw) as Map<String, dynamic>;
    return Session(
        baseUrl: value['base_url'] as String,
        token: value['token'] as String,
        accountId: value['account_id'] as String,
        deviceId: value['device_id'] as String);
  }

  @override
  Future<DeviceListPin?> loadDeviceListPin(String accountId) =>
      database.readDeviceListPin(accountId);

  @override
  Future<bool> saveDeviceListPin(DeviceListPin pin,
      {required int? expectedVersion}) async {
    if (failPin) throw StateError('pin write failed');
    return database.writeDeviceListPin(pin, expectedVersion: expectedVersion);
  }
}
