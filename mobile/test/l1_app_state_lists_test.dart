import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/device_lists.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
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

  test(
      'an account from before L1 reviews its devices once; removals and the '
      'recovery key then chain, re-signed after a 409', () async {
    final api = _ListApi(bindings)..acceptGenesis = false;
    final store = MemoryLocalStore();
    final crypto = NativeCryptoService(bindings: bindings, localStore: store);
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    await state.createOwner(_origin, 'owner', 'password', 'setup');
    expect(api.chain, isEmpty, reason: 'a pre-L1 server took no genesis');

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

class _ListApi extends ApiClient {
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

  /// What fetches serve instead of [chain] (a lying server).
  List<Uint8List>? served;

  @override
  Future<DeviceListPage?> fetchDeviceList(String token, String accountId,
      {required int after}) async {
    listFetches++;
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
