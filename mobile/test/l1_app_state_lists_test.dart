import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:drift/native.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/device_lists.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/l10n/l10n.dart' show englishL10n;
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

  for (final answer in [
    'valid',
    'partial',
    'duplicate',
    'wrong-account',
    'ghost'
  ]) {
    test('creation discovers signed devices; claim answer $answer', () async {
      final api = _DiscoveryApi(bindings)..answer = answer;
      final store = MemoryLocalStore();
      final crypto = NativeCryptoService(bindings: bindings, localStore: store);
      final state = _state(api, crypto);
      addTearDown(state.dispose);
      await state.createOwner(_origin, 'owner', 'password', 'setup');
      await _addSignedPhone(bindings, api, crypto);
      final created = await state.startConversation(kind: 'group');
      expect(api.claims.single, ['dev_phone']);
      if (['duplicate', 'wrong-account', 'ghost'].contains(answer)) {
        expect(created, isNull);
        expect(api.bundles, isEmpty);
        expect(await crypto.groupEpoch('conv_discovery'), isNull);
      } else {
        expect(created?.id, 'conv_discovery');
        expect(api.bundles, hasLength(1));
        expect(api.bundles.single.added.map((ref) => ref.deviceId),
            answer == 'partial' ? isEmpty : ['dev_phone']);
      }
    }, skip: skip);
  }

  test('reconcile discovers an approved device omitted from pending adds',
      () async {
    final api = _DiscoveryApi(bindings);
    final store = MemoryLocalStore();
    final crypto = NativeCryptoService(bindings: bindings, localStore: store);
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    await state.createOwner(_origin, 'owner', 'password', 'setup');
    await state.startConversation(kind: 'group');
    expect(api.claims, isEmpty);
    await _addSignedPhone(bindings, api, crypto);
    api.pending = true;
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await _until(() => api.bundles.length == 2);
    expect(api.claims.single, ['dev_phone']);
    expect(api.bundles.last.added.single.deviceId, 'dev_phone');
    expect(api.bundles.last.added.any((ref) => ref.deviceId == 'dev_ghost'),
        isFalse);
  }, skip: skip);

  test('failed add discovery still permits a removal commit', () async {
    final api = _DiscoveryApi(bindings);
    final crypto =
        NativeCryptoService(bindings: bindings, localStore: MemoryLocalStore());
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    await state.createOwner(_origin, 'owner', 'password', 'setup');
    await _addSignedPhone(bindings, api, crypto);
    await state.startConversation(kind: 'group');
    expect(api.bundles.single.added.single.deviceId, 'dev_phone');
    api
      ..pending = true
      ..removing = true
      ..membersUnavailable = true;
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await _until(() => api.bundles.length == 2);
    expect(api.bundles.last.added, isEmpty);
    expect(api.bundles.last.removed.single.deviceId, 'dev_phone');
    expect(api.claims, hasLength(1),
        reason: 'no claims during failed discovery');
  }, skip: skip);

  // L2-3, the real-app path that lists a franking key: a device another
  // device added (change 2) has none on its list; its first sealed token
  // pass signs change 7 naming exactly its own key, once.
  test('a device added without a franking key lists it with change 7, once',
      () async {
    final api = _ListApi(bindings);
    final store = MemoryLocalStore();
    final crypto = NativeCryptoService(bindings: bindings, localStore: store);
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    const session = Session(
        baseUrl: _origin, token: 'tok', accountId: _account, deviceId: _own);
    await crypto.createEnrollmentCredential(const EnrollmentReservation(
        id: 'enroll_own',
        accountId: _account,
        deviceId: _own,
        challenge: <int>[1, 2, 3]));
    await store.saveSession(session);
    await crypto.activateSession(session);
    final tablet = bindings.createDevice(_account, 'dev_tablet');
    addTearDown(tablet.close);
    final tabletPair =
        DeviceListPair(idBytes('dev_tablet'), tablet.signingPublicKey());
    api.chain.add(tablet.signDeviceList(
        DeviceListBody(
          accountId: idBytes(_account),
          version: 1,
          prevHash: DeviceListBody.zeroHash,
          createdAtMs: 1,
          change: DeviceListChange.genesis,
          entries: [tabletPair],
        ),
        idBytes('dev_tablet')));
    await DeviceListPins(store: store, source: _ApiLists(api), verifier: crypto)
        .pinChain(_account, api.chain, expectedHead: api.chain.last);
    state
      ..api = api
      ..session = session;

    // Not on the list: no context, nothing signed.
    expect(await state.debugSealedFrankContext(), isNull);
    expect(api.chain, hasLength(1));

    // The tablet adds this device: its entry has no franking key.
    final genesis =
        bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
    final add = tablet.signDeviceList(
        DeviceListBody(
          accountId: idBytes(_account),
          version: 2,
          prevHash: genesis.listHash,
          createdAtMs: 2,
          change: DeviceListChange.add,
          entries: [
            DeviceListPair(idBytes(_own), await crypto.currentSigningKey()),
            tabletPair,
          ],
        ),
        idBytes('dev_tablet'));
    await api.publishDeviceList('tok', add);
    await DeviceListPins(store: store, source: _ApiLists(api), verifier: crypto)
        .refresh(_account, force: true);
    expect(
        bindings
            .checkDeviceListChain(idBytes(_account), api.chain)
            .head
            .frankKeyOf(idBytes(_own)),
        isNull);

    final own = await crypto.currentFrankKey();
    final context = await state.debugSealedFrankContext();
    expect(context, isNotNull);
    expect(context!.listedKey, own);
    expect(api.chain, hasLength(3));
    final head =
        bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
    expect(head.change, DeviceListChange.frankKey);
    expect(head.frankKeyOf(idBytes(_own)), own);
    expect(head.frankKeys, hasLength(1));
    expect(head.entries, hasLength(2));
    // The pin moved with it.
    expect((await store.loadDeviceListPin(_account))!.version, 3);

    // The next pass signs nothing.
    expect((await state.debugSealedFrankContext())!.listedKey, own);
    expect(api.chain, hasLength(3));
  }, skip: skip);

  // Condition A: with the server's sealed switch off, every version this
  // device signs alone is L1 format 1, byte for byte the earlier format
  // (main's servers and apps refuse format 2); change 7 adds the key later.
  test('with sealed sending off, the setup genesis is format 1', () async {
    final api = _ListApi(bindings);
    final crypto =
        NativeCryptoService(bindings: bindings, localStore: MemoryLocalStore());
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    await state.createOwner(_origin, 'owner', 'password', 'setup');
    expect(api.chain, hasLength(1));
    await _expectFormat1(crypto, api.chain);
  }, skip: skip);

  test('setup carries a genesis that names this device with its key', () async {
    final api = _ListApi(bindings)..sealedSwitch = true;
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
    // L2-3: the genesis lists this device's own franking key.
    expect(
        chain.head.frankKeyOf(idBytes(_own)), await crypto.currentFrankKey());
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
    // Condition A: the switch is off, so no franking key and format 1.
    await _expectFormat1(crypto, api.chain);
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

  // ------------------------------------------------------------------
  // The four L1 flows of 2026-11-11 (docs/designs/L1-approved-devices.md):
  // the complete-adds audit, the incomplete-join notice, the recovery
  // retype and the pre-L1 recovery-key confirmation, with the review fixes.

  /// An owner with [groups] groups that hold only this device; then
  /// [devices] are signed onto the owner's list. A first catch-up runs
  /// before they are added, so no earlier pass sees them.
  Future<({_AuditApi api, AppState state, NativeCryptoService crypto})>
      auditSetup(
          {int groups = 1,
          List<String> devices = const ['dev_phone'],
          Duration? interval,
          bool tearDown = true}) async {
    final api = _AuditApi(bindings);
    final crypto =
        NativeCryptoService(bindings: bindings, localStore: MemoryLocalStore());
    final state = _state(api, crypto)..reconcileFallback = Duration.zero;
    if (tearDown) addTearDown(state.dispose);
    expect(state.l1JoinAuditInterval, const Duration(minutes: 15));
    state.l1JoinAuditInterval = Duration.zero;
    await state.createOwner(_origin, 'owner', 'password', 'setup');
    for (var i = 0; i < groups; i++) {
      expect(
          (await state.startConversation(kind: 'group'))?.id, 'conv_${i + 1}');
    }
    await _catchUp(state);
    expect(api.claims, isEmpty);
    for (final id in devices) {
      await _addSignedDevice(bindings, api, crypto, id);
    }
    state.l1JoinAuditInterval = interval ?? const Duration(minutes: 15);
    return (api: api, state: state, crypto: crypto);
  }

  /// A new app instance on the same store (a restart).
  Future<AppState> restart(_AuditApi api, NativeCryptoService crypto,
      {Duration fallback = Duration.zero,
      Duration interval = const Duration(minutes: 15)}) async {
    final state = _state(api, crypto)
      ..reconcileFallback = fallback
      ..l1JoinAuditInterval = interval;
    await state.tryRestoreSession();
    expect(state.session?.deviceId, _own);
    return state;
  }

  Future<void> stop(AppState state) async {
    state.dispose();
    await state.backgroundWorkIdle;
  }

  test(
      'audit: a group the server never reports gains the approved device '
      'by explicit claim; the next audit finds it complete', () async {
    final (:api, :state, :crypto) = await auditSetup(interval: Duration.zero);
    final created = api.bundles.length;
    await _catchUp(state);
    expect(api.claims, [
      ['dev_phone']
    ]);
    expect(api.bundles, hasLength(created + 1));
    expect(api.bundles.last.added.map((ref) => ref.deviceId), ['dev_phone']);
    // The tree now holds it: the next audit claims nothing and clears the
    // recorded gap.
    await _catchUp(state);
    expect(api.claims, hasLength(1));
    expect(await crypto.localStore.loadSetting('l1.missing_joins'), isEmpty);
    expect(state.incompleteJoinAccounts('conv_1'), isEmpty);
  }, skip: skip);

  test(
      'audit: the reconcile fallback gives an honest coordinator the first '
      'turn', () async {
    final (:api, :state, :crypto) = await auditSetup();
    state.reconcileFallback = const Duration(minutes: 3);
    await _catchUp(state);
    expect(api.claims, isEmpty, reason: 'waits out the fallback first');
    // The gap is recorded (and persisted) at once, with no notice yet.
    final stored =
        jsonDecode((await crypto.localStore.loadSetting('l1.missing_joins'))!)
            as Map;
    expect(stored['owner'], '$_account\u0000$_own');
    expect((stored['joins'] as Map)['conv_1'], contains(_account));
    expect(state.incompleteJoinAccounts('conv_1'), isEmpty);
    expect(
        state.incompleteJoinAccounts('conv_1',
            now: DateTime.now().toUtc().add(const Duration(hours: 1))),
        {_account});
  }, skip: skip);

  test('audit: at most 8 groups per pass, each at most every 15 minutes',
      () async {
    final (:api, :state, :crypto) = await auditSetup(groups: 9);
    // Claims answer nothing, so every audited group keeps its gap.
    api.answer = 'partial';
    await _catchUp(state);
    expect(api.claims, hasLength(8));
    await _catchUp(state);
    // Only the ninth was left; the first eight wait out their interval.
    expect(api.claims, hasLength(9));
    await _catchUp(state);
    expect(api.claims, hasLength(9));
    expect(api.bundles.where((bundle) => bundle.added.isNotEmpty), isEmpty);
  }, skip: skip);

  test('audit: one refused device (403) does not keep its siblings out',
      () async {
    final (:api, :state, :crypto) =
        await auditSetup(devices: ['dev_phone', 'dev_tablet']);
    api.refuse = {'dev_tablet'};
    await _catchUp(state);
    expect(api.claims, hasLength(3));
    expect(api.claims.first, unorderedEquals(['dev_phone', 'dev_tablet']));
    expect(api.claims.skip(1).map((ids) => ids.single),
        unorderedEquals(['dev_phone', 'dev_tablet']));
    expect(api.bundles.last.added.map((ref) => ref.deviceId), ['dev_phone']);
  }, skip: skip);

  test(
      'audit (review fix): a change listed at a stale epoch still gets '
      'discovery', () async {
    final (:api, :state, :crypto) = await auditSetup();
    api
      ..pending = true // A device_list.updated event asks for reconcile.
      ..pendingList = const [
        MlsPendingChange(
            conversationId: 'conv_1', epoch: 99, add: [], remove: [])
      ];
    await _catchUp(state);
    expect(api.staleReadBeforeClaim, isTrue,
        reason: 'reconcile read the stale change before the audit claimed');
    expect(api.claims, [
      ['dev_phone']
    ]);
    expect(api.bundles.last.added.single.deviceId, 'dev_phone');
  }, skip: skip);

  test(
      'audit (review fix): an account the server leaves out of the member '
      'list is still examined', () async {
    final (:api, :state, :crypto) = await auditSetup();
    api.memberList = const <ConversationMember>[];
    await _catchUp(state);
    expect(api.claims, [
      ['dev_phone']
    ]);
    expect(api.bundles.last.added.single.deviceId, 'dev_phone');
  }, skip: skip);

  test(
      'notice: a gap older than the grace is shown after a restart; a '
      'refused bundle keeps it, only the tree clears it', () async {
    final (:api, :state, :crypto) =
        await auditSetup(devices: const [], tearDown: false);
    // Signed while this device is active, added while the app is closed.
    final add = await _signDeviceAdd(bindings, api, crypto, 'dev_phone');
    await stop(state);
    await _publishDeviceAdd(api, crypto, add);
    final twoHoursAgo = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 2))
        .millisecondsSinceEpoch;
    await crypto.localStore.saveSetting(
        'l1.missing_joins',
        jsonEncode({
          'owner': '$_account\u0000$_own',
          'joins': {
            'conv_1': {_account: twoHoursAgo}
          },
        }));
    // The claim answers but the server refuses the commit: the device stays
    // out of the tree, so the clock keeps running (d396c6d).
    api.refuseBundles = true;
    var running = await restart(api, crypto);
    await _catchUp(running);
    expect(api.claims, isNotEmpty);
    expect(api.refusedBundles, greaterThan(0));
    expect(running.incompleteJoinAccounts('conv_1'), {_account});
    await stop(running);

    // The server takes the commit: the notice stays until a later audit
    // finds the device in the tree.
    api.refuseBundles = false;
    running = await restart(api, crypto, interval: Duration.zero);
    addTearDown(running.dispose);
    await _catchUp(running);
    expect(api.bundles.last.added.single.deviceId, 'dev_phone');
    await _catchUp(running);
    expect(running.incompleteJoinAccounts('conv_1'), isEmpty);
    expect(await crypto.localStore.loadSetting('l1.missing_joins'), isEmpty);
  }, skip: skip);

  test('notice: clocks stored for another identity are not used', () async {
    final (:api, :state, :crypto) =
        await auditSetup(devices: const [], tearDown: false);
    // Signed while this device is active, added while the app is closed.
    final add = await _signDeviceAdd(bindings, api, crypto, 'dev_phone');
    await stop(state);
    await _publishDeviceAdd(api, crypto, add);
    await crypto.localStore.saveSetting(
        'l1.missing_joins',
        jsonEncode({
          'owner': '$_account\u0000dev_other',
          'joins': {
            'conv_1': {_account: 1}
          },
        }));
    final running =
        await restart(api, crypto, fallback: const Duration(minutes: 3));
    addTearDown(running.dispose);
    await _catchUp(running);
    // A fresh clock: no notice, and no claim before the fallback.
    expect(running.incompleteJoinAccounts('conv_1'), isEmpty);
    expect(api.claims, isEmpty);
    final stored =
        jsonDecode((await crypto.localStore.loadSetting('l1.missing_joins'))!)
            as Map;
    expect(stored['owner'], '$_account\u0000$_own');
  }, skip: skip);

  /// An owner whose list's head names recovery key [key] (change 5), and
  /// [chained]: a genuine next version of that head, signed but not sent.
  Future<
      ({
        _ListApi api,
        RecoveryKeyDraft key,
        RecoveryKeyDraft other,
        Uint8List chained
      })> ownerWithRecoveryKey() async {
    final api = _ListApi(bindings);
    final crypto =
        NativeCryptoService(bindings: bindings, localStore: MemoryLocalStore());
    final owner = _state(api, crypto);
    await owner.createOwner(_origin, 'owner', 'password', 'setup');
    final key = await owner.createRecoveryKeyDraft();
    final other = await owner.createRecoveryKeyDraft();
    addTearDown(key.dispose);
    addTearDown(other.dispose);
    expect(await owner.saveRecoveryKey(key), RecoveryActionResult.done);
    final head =
        bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
    expect(head.change, DeviceListChange.recoveryKey);
    final tablet = bindings.createDevice(_account, 'dev_tablet');
    addTearDown(tablet.close);
    final chained = await crypto.signDeviceList(DeviceListBody(
      accountId: idBytes(_account),
      version: head.version + 1,
      prevHash: head.listHash,
      createdAtMs: 3,
      change: DeviceListChange.add,
      entries: [
        ...head.entries,
        DeviceListPair(idBytes('dev_tablet'), tablet.signingPublicKey())
      ],
      recoveryKey: head.recoveryKey,
      // L2-3: devices that stay keep their franking keys.
      frankKeys: head.frankKeys,
    ));
    await stop(owner);
    return (api: api, key: key, other: other, chained: chained);
  }

  /// A device recovered into the owner's account (K0-R) whose held seed is
  /// gone: it is not on the list and nothing was posted.
  Future<({AppState state, NativeCryptoService crypto})> recovered(_ListApi api,
      {RecoveryKeyDraft? heldKey}) async {
    final store = MemoryLocalStore();
    final crypto = NativeCryptoService(bindings: bindings, localStore: store);
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    const session = Session(
        baseUrl: _origin,
        token: 'tok',
        accountId: _account,
        deviceId: 'dev_rec');
    await crypto.createEnrollmentCredential(const EnrollmentReservation(
        id: 'enroll_rec',
        accountId: _account,
        deviceId: 'dev_rec',
        challenge: <int>[4, 5, 6]));
    // The seed K0-R holds on the waiting identity, before activation.
    if (heldKey != null) {
      await crypto.holdRecoveryListSeed(
          await crypto.decodeRecoveryKey(heldKey.display));
    }
    await store.saveSession(session);
    await crypto.activateSession(session);
    await store.saveSetting('k0.recovered_device', '$_account\u0000dev_rec');
    await DeviceListPins(store: store, source: _ApiLists(api), verifier: crypto)
        .pinChain(_account, api.chain, expectedHead: api.chain.last);
    state
      ..api = api
      ..session = session;
    return (state: state, crypto: crypto);
  }

  test(
      'retype: a recovered device without its held seed signs change 4 '
      'from the typed key; a wrong key signs nothing', () async {
    final (:api, :key, :other, chained: _) = await ownerWithRecoveryKey();
    final (:state, :crypto) = await recovered(api);
    await state.refreshDevices();
    await _until(() => state.recoveryListNeedsRetype);
    final before = api.chain.length;

    expect(await state.finishRecoveryWithTypedKey(other.display), isFalse);
    expect(
        state.errorFor(Ops.recoveryKey), englishL10n.recoveryKeyNotThisAccount);
    expect(api.chain, hasLength(before));
    expect(state.recoveryListNeedsRetype, isTrue);

    expect(await state.finishRecoveryWithTypedKey(key.display), isTrue);
    expect(api.chain, hasLength(before + 1));
    final head =
        bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
    expect(head.change, DeviceListChange.recovery);
    expect(head.entries.single.deviceId, idBytes('dev_rec'));
    expect(head.entries.single.signingKey, await crypto.currentSigningKey());
    // Condition A: the switch is off, so no franking key and format 1.
    await _expectFormat1(crypto, api.chain);
    expect(state.recoveryListNeedsRetype, isFalse);
    expect(await crypto.localStore.loadSetting('l1.recovery_list_statement'),
        isEmpty);
  }, skip: skip);

  test('with sealed sending on, the typed-key recovery lists its own key',
      () async {
    final (:api, :key, other: _, chained: _) = await ownerWithRecoveryKey();
    final (:state, :crypto) = await recovered(api);
    api.sealedSwitch = true;
    await state.refreshDevices();
    await _until(() => state.recoveryListNeedsRetype);
    expect(await state.finishRecoveryWithTypedKey(key.display), isTrue);
    final head =
        bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
    expect(head.change, DeviceListChange.recovery);
    expect(head.frankKeyOf(idBytes('dev_rec')), await crypto.currentFrankKey());
    expect(api.chain.last[4], 2);
  }, skip: skip);

  for (final sealedOn in [false, true]) {
    test(
        'held-seed recovery with sealed sending '
        '${sealedOn ? 'on lists its own key' : 'off is format 1'}', () async {
      final (:api, :key, other: _, chained: _) = await ownerWithRecoveryKey();
      final (:state, :crypto) = await recovered(api, heldKey: key);
      api.sealedSwitch = sealedOn;
      final before = api.chain.length;
      await state.debugPostRecoveryDeviceList();
      expect(api.chain, hasLength(before + 1));
      final head =
          bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
      expect(head.change, DeviceListChange.recovery);
      expect(head.entries.single.deviceId, idBytes('dev_rec'));
      if (sealedOn) {
        expect(head.frankKeyOf(idBytes('dev_rec')),
            await crypto.currentFrankKey());
        expect(api.chain.last[4], 2);
      } else {
        await _expectFormat1(crypto, api.chain);
      }
    }, skip: skip);
  }

  for (final chains in [false, true]) {
    test(
        'retype (review fix): after a conflict, a stored version the head '
        '${chains ? 'still chains on is kept' : 'moved past is dropped'}',
        () async {
      final (:api, :key, :other, :chained) = await ownerWithRecoveryKey();
      final (:state, :crypto) = await recovered(api);
      // The stale one chains on the genesis, which the head moved past.
      final stored = chains ? chained : api.chain.first;
      await crypto.localStore.saveSetting(
          'l1.recovery_list_statement',
          jsonEncode({
            'account_id': _account,
            'device_id': 'dev_rec',
            'statement': base64Encode(stored),
          }));
      final before = api.chain.length;
      api.conflictsLeft = 1;
      await state.refreshDevices();
      await _until(() => api.conflictsLeft == 0);
      if (chains) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
            await crypto.localStore.loadSetting('l1.recovery_list_statement'),
            isNotEmpty);
        expect(state.recoveryListNeedsRetype, isFalse);
        expect(api.chain, hasLength(before));
        return;
      }
      String? left = 'unread';
      for (var i = 0; i < 200 && left != ''; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        left =
            await crypto.localStore.loadSetting('l1.recovery_list_statement');
      }
      expect(left, isEmpty);
      await _until(() => state.recoveryListNeedsRetype);
      // The prompt leads to a fresh version on the current head.
      expect(await state.finishRecoveryWithTypedKey(key.display), isTrue);
      expect(api.chain, hasLength(before + 1));
      expect(
          bindings
              .checkDeviceListChain(idBytes(_account), api.chain)
              .head
              .change,
          DeviceListChange.recovery);
    }, skip: skip);
  }

  test(
      'pre-L1 key: matched by rk_id, then set again with change 5 after '
      'recent auth; a wrong key sends nothing', () async {
    final api = _ListApi(bindings)..acceptGenesis = false;
    final store = MemoryLocalStore();
    final crypto = NativeCryptoService(bindings: bindings, localStore: store);
    final state = _state(api, crypto);
    addTearDown(state.dispose);
    await crypto.createEnrollmentCredential(await api.reserveOwnerEnrollment());
    await store.saveSession(_ListApi._session);
    await crypto.activateSession(_ListApi._session);
    state
      ..api = api
      ..session = _ListApi._session;
    api.serverDevices = [
      Device(
          id: _own,
          accountId: _account,
          name: 'This',
          createdAt: DateTime.utc(2026),
          signingKey: await crypto.currentSigningKey()),
    ];
    await state.refreshDevices();
    await _until(() => state.ownDeviceListMissing);
    expect(await state.createApprovedDeviceList({_own}),
        RecoveryActionResult.done);
    expect(
        bindings
            .checkDeviceListChain(idBytes(_account), api.chain)
            .head
            .recoveryKey,
        isNull);
    // A key set before L1: the server knows its rk_id, the list does not.
    final key = await state.createRecoveryKeyDraft();
    final other = await state.createRecoveryKeyDraft();
    addTearDown(key.dispose);
    addTearDown(other.dispose);
    final values = await crypto
        .deriveRecoveryKey(await crypto.decodeRecoveryKey(key.display));
    api.recoveryStatus =
        RecoveryKeyStatus(available: true, configured: true, rkId: values.rkId);
    await state.refreshRecoveryKeyStatus();
    await state.refreshDevices();
    await _until(() => state.recoveryKeyNeedsConfirmation);
    final before = api.chain.length;

    expect(await state.confirmPreL1RecoveryKey(other.display),
        RecoveryActionResult.failed);
    expect(
        state.errorFor(Ops.recoveryKey), englishL10n.recoveryKeyNotThisAccount);
    expect(api.chain, hasLength(before));
    expect(api.putRkIds, isEmpty);

    api.recentAuthLeft = 1;
    expect(await state.confirmPreL1RecoveryKey(key.display),
        RecoveryActionResult.needsRecentAuth);
    expect(api.putRkIds, isEmpty);
    expect(api.chain, hasLength(before));
    expect(state.recoveryKeyNeedsConfirmation, isTrue);

    expect(await state.confirmPreL1RecoveryKey(key.display),
        RecoveryActionResult.done);
    expect(api.putRkIds.single, values.rkId);
    final head =
        bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
    expect(head.change, DeviceListChange.recoveryKey);
    expect(head.recoveryKey, values.rkListPub);
    expect(api.recoveryKeyLists.single, api.chain.last);
    expect(state.recoveryKeyNeedsConfirmation, isFalse);
  }, skip: skip);
}

Future<void> _addSignedPhone(NativeCryptoBindings bindings, _DiscoveryApi api,
    NativeCryptoService crypto) async {
  final phone = bindings.createDevice(_account, 'dev_phone');
  try {
    final head =
        bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
    final statement = await crypto.signDeviceList(DeviceListBody(
      accountId: idBytes(_account),
      version: head.version + 1,
      prevHash: head.listHash,
      createdAtMs: 2,
      change: DeviceListChange.add,
      entries: [
        ...head.entries,
        DeviceListPair(idBytes('dev_phone'), phone.signingPublicKey())
      ],
      // L2-3: devices that stay keep their franking keys.
      frankKeys: head.frankKeys,
    ));
    api._take(statement);
    await DeviceListPins(
            store: crypto.localStore, source: _ApiLists(api), verifier: crypto)
        .pinOwnStep(_account, statement);
    api.package = DeviceKeyPackage(
        id: 'kp_phone',
        accountId: _account,
        deviceId: 'dev_phone',
        keyPackage: phone.createKeyPackage(),
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)));
  } finally {
    phone.close();
  }
}

/// Condition A: the last statement of [chain] is L1 format 1 with no
/// franking key. A genesis is also checked to be byte for byte the format-1
/// encoding of the same content: re-signed from its parsed body, Ed25519
/// gives the same bytes only if the body is the same.
Future<void> _expectFormat1(
    NativeCryptoService crypto, List<Uint8List> chain) async {
  final statement = chain.last;
  expect(utf8.decode(statement.sublist(0, 4)), 'VDL1');
  expect(statement[4], 1, reason: 'L1 format byte');
  final head =
      crypto.bindings.checkDeviceListChain(idBytes(_account), chain).head;
  expect(head.frankKeys, isEmpty);
  if (chain.length != 1) return;
  final again = await crypto.signDeviceList(DeviceListBody(
    accountId: idBytes(_account),
    version: head.version,
    prevHash: DeviceListBody.zeroHash,
    createdAtMs: head.createdAtMs,
    change: head.change,
    entries: head.entries,
    recoveryKey: head.recoveryKey,
  ));
  expect(again, statement);
}

class _DiscoveryApi extends _ListApi {
  _DiscoveryApi(super.bindings);
  final claims = <List<String>>[];
  final bundles = <MlsCommitBundle>[];
  DeviceKeyPackage? package;
  String answer = 'valid';
  bool pending = false;
  bool removing = false;
  bool membersUnavailable = false;

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      [
        if (pending && after == 0)
          SyncEvent(
              id: 1,
              type: 'device_list.updated',
              accountId: _account,
              payload: const {'version': 2},
              createdAt: DateTime.utc(2026, 11, 11)),
      ];

  @override
  Future<Conversation> createConversationDetailed(
    String token, {
    required String kind,
    String? title,
    String? communityId,
    String? channelId,
    List<String> memberAccountIds = const [],
    int? retentionSeconds,
  }) async =>
      Conversation(id: 'conv_discovery', kind: kind, createdBy: _account);

  @override
  Future<List<ConversationMember>> conversationMembers(
      String token, String id) async {
    if (membersUnavailable) throw ApiException(503, '');
    return [ConversationMember(accountId: _account, role: 'owner')];
  }

  @override
  Future<List<DeviceKeyPackage>> claimConversationKeyPackages(
          String token, String id) =>
      throw StateError('claim-all must not be used for L1 creation');

  @override
  Future<List<DeviceKeyPackage>> claimDeviceKeyPackages(
      String token, String id, List<String> deviceIds) async {
    claims.add(deviceIds);
    final item = package!;
    if (answer == 'partial') return [];
    if (answer == 'duplicate') return [item, item];
    if (answer == 'valid') return [item];
    return [
      DeviceKeyPackage(
          id: item.id,
          accountId: answer == 'wrong-account' ? 'acct_other' : _account,
          deviceId: answer == 'ghost' ? 'dev_ghost' : item.deviceId,
          keyPackage: item.keyPackage,
          ciphersuite: item.ciphersuite,
          expiresAt: item.expiresAt)
    ];
  }

  @override
  Future<int> sendMlsCommitBundle(
    String token,
    String id, {
    required String idempotencyKey,
    required MlsCommitBundle bundle,
  }) async {
    bundles.add(bundle);
    pending = false;
    return bundle.epoch + (bundle.hasCommit ? 1 : 0);
  }

  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async => [
        if (pending)
          MlsPendingChange(
              conversationId: 'conv_discovery',
              epoch: removing ? 1 : 0,
              add: const [
                (accountId: _account, deviceId: 'dev_ghost')
              ],
              remove: [
                if (removing) (accountId: _account, deviceId: 'dev_phone')
              ]),
      ];
}

AppState _state(_ListApi api, NativeCryptoService crypto) => AppState(
      screenGuard: FakeScreenGuard(),
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: crypto.localStore,
      syncServiceFactory: (_, __) => _QuietSync(),
    );

Future<void> _until(bool Function() condition, {int ticks = 200}) async {
  for (var i = 0; i < ticks && !condition(); i++) {
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

  /// The server's `sealed_sender` switch, as its setup status reports it
  /// (L2-3, condition A). Off by default, like a real server.
  bool sealedSwitch = false;

  @override
  Future<Map<String, Object?>> setupStatus() async =>
      <String, Object?>{'sealed_sender': sealedSwitch};

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

  /// What `GET /account/recovery-key` answers (null: none configured).
  RecoveryKeyStatus? recoveryStatus;
  int recentAuthLeft = 0;
  final List<List<int>> putRkIds = <List<int>>[];

  @override
  Future<RecoveryKeyStatus> putRecoveryKey(String token,
      {required List<int> rkAuthPub,
      required List<int> rkId,
      List<int>? deviceList}) async {
    if (recentAuthLeft > 0) {
      recentAuthLeft--;
      throw ApiException(403, '{"error":"recent_auth_required"}');
    }
    _take(deviceList);
    putRkIds.add(rkId);
    if (deviceList != null) recoveryKeyLists.add(deviceList);
    return recoveryStatus = RecoveryKeyStatus(
        available: true,
        configured: true,
        setAt: DateTime.utc(2026, 11, 7),
        rkId: Uint8List.fromList(rkId));
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
      recoveryStatus ??
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

/// Runs one foreground catch-up (sync, reconcile, the L1 audit) to its end.
Future<void> _catchUp(AppState state) async {
  final before = state.lastSyncedAt;
  state.handleAppLifecycleState(AppLifecycleState.resumed);
  await _until(() => state.lastSyncedAt != before, ticks: 600);
  await state.backgroundWorkIdle;
}

/// Signs [deviceId] onto the owner's list (an add) and offers its package.
Future<void> _addSignedDevice(NativeCryptoBindings bindings, _AuditApi api,
    NativeCryptoService crypto, String deviceId) async {
  await _publishDeviceAdd(
      api, crypto, await _signDeviceAdd(bindings, api, crypto, deviceId));
}

/// The owner's next list version adding [deviceId] (signed, not sent), and
/// the device's key package offered by [api].
Future<Uint8List> _signDeviceAdd(NativeCryptoBindings bindings, _AuditApi api,
    NativeCryptoService crypto, String deviceId) async {
  final device = bindings.createDevice(_account, deviceId);
  try {
    api.packages[deviceId] = DeviceKeyPackage(
        id: 'kp_$deviceId',
        accountId: _account,
        deviceId: deviceId,
        keyPackage: device.createKeyPackage(),
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)));
    final head =
        bindings.checkDeviceListChain(idBytes(_account), api.chain).head;
    return await crypto.signDeviceList(DeviceListBody(
      accountId: idBytes(_account),
      version: head.version + 1,
      prevHash: head.listHash,
      createdAtMs: 2,
      change: DeviceListChange.add,
      entries: [
        ...head.entries,
        DeviceListPair(idBytes(deviceId), device.signingPublicKey())
      ],
      // L2-3: devices that stay keep their franking keys.
      frankKeys: head.frankKeys,
    ));
  } finally {
    device.close();
  }
}

/// The server takes [statement] and the owner's pin advances to it.
Future<void> _publishDeviceAdd(
    _AuditApi api, NativeCryptoService crypto, Uint8List statement) async {
  api._take(statement);
  await DeviceListPins(
          store: crypto.localStore, source: _ApiLists(api), verifier: crypto)
      .pinOwnStep(_account, statement);
}

/// A server for the audit: numbered groups it lists, a pending-change list
/// it controls (empty: it reports nothing), explicit claims by device with
/// per-device 403s, and commit bundles it may refuse.
class _AuditApi extends _DiscoveryApi {
  _AuditApi(super.bindings);
  final Map<String, DeviceKeyPackage> packages = <String, DeviceKeyPackage>{};
  final List<Conversation> groups = <Conversation>[];
  List<MlsPendingChange> pendingList = const <MlsPendingChange>[];
  List<ConversationMember>? memberList;
  Set<String> refuse = const <String>{};
  bool refuseBundles = false;
  int refusedBundles = 0;
  bool _servedStale = false;

  /// Whether a pending-change read that listed [pendingList] came before
  /// the first claim (null: no claim yet).
  bool? staleReadBeforeClaim;

  @override
  Future<Conversation> createConversationDetailed(
    String token, {
    required String kind,
    String? title,
    String? communityId,
    String? channelId,
    List<String> memberAccountIds = const [],
    int? retentionSeconds,
  }) async {
    final created = Conversation(
        id: 'conv_${groups.length + 1}', kind: kind, createdBy: _account);
    groups.add(created);
    return created;
  }

  @override
  Future<List<Conversation>> conversations(String token) async =>
      List<Conversation>.of(groups);

  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String id) async =>
      memberList ?? [ConversationMember(accountId: _account, role: 'owner')];

  @override
  Future<List<DeviceKeyPackage>> claimDeviceKeyPackages(
      String token, String id, List<String> deviceIds) async {
    claims.add(deviceIds);
    staleReadBeforeClaim ??= _servedStale;
    if (deviceIds.any(refuse.contains)) {
      throw ApiException(403, '{"error":"forbidden"}');
    }
    if (answer == 'partial') return const <DeviceKeyPackage>[];
    return [
      for (final device in deviceIds)
        if (packages[device] case final DeviceKeyPackage package) package,
    ];
  }

  @override
  Future<int> sendMlsCommitBundle(
    String token,
    String id, {
    required String idempotencyKey,
    required MlsCommitBundle bundle,
  }) async {
    if (refuseBundles && bundle.added.isNotEmpty) {
      refusedBundles++;
      throw ApiException(409, '{"error":"mls_epoch_conflict"}');
    }
    return super.sendMlsCommitBundle(token, id,
        idempotencyKey: idempotencyKey, bundle: bundle);
  }

  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async {
    if (pendingList.isNotEmpty) _servedStale = true;
    return pendingList;
  }
}
