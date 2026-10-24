import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/push/push_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'goldens/golden_harness.dart' show veritraTestApp;
import 'test_crypto_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('account sync owner coalesces overlapping requests', () async {
    final gate = Completer<void>();
    var runs = 0;
    var owner = true;
    final engine = AccountSyncEngine(
      isOwner: () => owner,
      work: () async {
        runs++;
        if (runs == 1) await gate.future;
      },
    );

    final first = engine.request();
    await Future<void>.delayed(Duration.zero);
    final second = engine.request();
    expect(runs, 1);
    gate.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(runs, 2);

    owner = false;
    await engine.request();
    expect(runs, 2);
    engine.dispose();
  });

  test('paused push wake does not sync and resumes from the durable marker',
      () async {
    final localStore = MemoryLocalStore();
    await localStore.saveSession(const Session(
      baseUrl: 'https://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
    ));
    final api = _WakeApiClient();
    final push = _WakePushService(initialGeneration: 1);
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
      pushService: push,
    );
    state.handleAppLifecycleState(AppLifecycleState.paused);

    await state.tryRestoreSession();
    await push.registered.future.timeout(const Duration(seconds: 2));
    push.emitWake();
    await Future<void>.delayed(Duration.zero);
    expect(api.syncCalls, 0);
    expect(await localStore.loadSyncCursor(), 0);
    expect(push.generation, 2);

    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await api.cursorAdvanced.future.timeout(const Duration(seconds: 2));
    for (var attempt = 0;
        attempt < 10 && await localStore.loadSyncCursor() != 7;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(await localStore.loadSyncCursor(), 7);
    expect(push.acknowledged, <int>[2]);
    expect(push.generation, 0);
    state.dispose();
  });

  test('message envelope serializes ciphertext without plaintext body field',
      () {
    final envelope = MessageEnvelope(
      conversationId: 'conv_1',
      idempotencyKey: 'key_1',
      ciphertext: <int>[1, 2, 3],
      cryptoProtocol: 'mls-openmls-todo',
    );
    final json = envelope.toJson();
    expect(json.containsKey('ciphertext'), isTrue);
    expect(json.containsKey('body'), isFalse);
    expect(json.containsKey('text'), isFalse);
  });

  test('metadata search result parses non-message metadata only', () {
    final result = MetadataSearchResult.fromJson(<String, Object?>{
      'type': 'community',
      'id': 'comm_1',
      'label': 'Family',
    });
    expect(result.type, 'community');
    expect(result.label, 'Family');
  });

  test('device link parses transcript metadata without a server SAS', () {
    final link = DeviceLink.fromJson(<String, Object?>{
      'id': 'dlink_1',
      'state': 'pending',
      'expires_at': '2026-05-29T12:00:00Z',
      'code': 'PAIRCODE',
      'link_uri': 'veritra://device-link?code=PAIRCODE',
      'protocol_version': 'veritra-device-link-v1',
      'link_nonce': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=',
    });
    expect(link.code, 'PAIRCODE');
    expect(link.verificationCode, isEmpty);
    expect(link.linkNonce, hasLength(32));
  });

  test('app state can store session through local abstraction', () async {
    final localStore = MemoryLocalStore();
    final state = AppState(
      apiClientFactory: (_) => throw UnimplementedError(),
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );
    await localStore.saveSession(
        const Session(baseUrl: 'https://localhost:8080', token: 'token'));
    expect((await state.localStore.loadSession())?.token, 'token');
  });

  test('crypto state and cursor commit together and reject rollback', () async {
    final store = MemoryLocalStore();
    final first = StoredCryptoState(
      counter: 4,
      stateKey: List<int>.filled(32, 7),
      sealedState: <int>[1, 2, 3],
    );
    await store.saveCryptoState(first, 91);

    final restored = await store.loadCryptoState();
    expect(restored?.counter, 4);
    expect(await store.loadSyncCursor(), 91);
    await expectLater(
      store.saveCryptoState(
        StoredCryptoState(
          counter: 4,
          stateKey: List<int>.filled(32, 8),
          sealedState: <int>[4],
        ),
        92,
      ),
      throwsStateError,
    );
    expect(await store.loadSyncCursor(), 91);
  });

  test('app state drives device link claim through approval', () async {
    final localStore = MemoryLocalStore();
    final api = FakeDeviceLinkApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );

    await state.claimDeviceLink('https://localhost:8080', 'PAIRCODE');
    expect(state.pendingDeviceLinkClaim?.deviceLink.verificationCode, '654321');
    expect(state.session, isNull);

    await state.completeDeviceLinkClaim();
    expect(state.session?.token, 'linked-token');
    expect((await localStore.loadSession())?.token, 'linked-token');
  });

  test('app state can create and approve a device link', () async {
    final api = FakeDeviceLinkApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
      );

    await state.createDeviceLink();
    expect(state.activeDeviceLink?.code, 'PAIRCODE');

    await state.refreshActiveDeviceLink();
    expect(state.activeDeviceLink?.claimedDeviceName, 'linked tablet');
    expect(state.activeDeviceLink?.code, 'PAIRCODE');

    await state.approveActiveDeviceLink('654321');
    expect(state.activeDeviceLink?.state, 'approved');
    expect(state.activeDeviceLink?.approvedDeviceId, 'dev_linked');
  });

  test('device link rejects a server-substituted transcript', () async {
    final api = FakeDeviceLinkApiClient(transcriptByte: 8);
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
      );
    await state.createDeviceLink();
    await state.refreshActiveDeviceLink();
    expect(state.error, contains('substituted'));
    expect(state.activeDeviceLink?.verificationCode, isNot('654321'));
  });

  for (final (name, makeApi) in <(String, FakeDeviceLinkApiClient Function())>[
    (
      'a missing transcript hash',
      () => FakeDeviceLinkApiClient(omitTranscript: true)
    ),
    (
      'a different transcript hash',
      () => FakeDeviceLinkApiClient(transcriptByte: 8)
    ),
    ('a different nonce', () => FakeDeviceLinkApiClient(refreshNonceByte: 2)),
    (
      'a different account',
      () => FakeDeviceLinkApiClient(refreshAccountId: 'acct_other')
    ),
  ]) {
    test('device link refresh with $name fails closed', () async {
      final api = makeApi();
      final state = AppState(
        apiClientFactory: (_) => api,
        cryptoService: TestOnlyCryptoService(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => FakeSyncService(),
      )
        ..api = api
        ..session = const Session(
          baseUrl: 'https://localhost:8080',
          token: 'owner-token',
        );
      await state.createDeviceLink();
      await state.refreshActiveDeviceLink();
      expect(state.error, isNotNull);
      expect(state.activeDeviceLink?.verificationCode, isEmpty);
      expect(state.activeDeviceLink?.transcriptHash, isNull);
      expect(state.activeDeviceLink?.linkNonce, List<int>.filled(32, 1));
      await state.approveActiveDeviceLink('654321');
      expect(state.activeDeviceLink?.state, isNot('approved'));
    });
  }

  test('app state refreshes encrypted messages for selected conversation',
      () async {
    final api = FakeDeviceLinkApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group'),
      ];

    state.selectConversation('conv_1');
    await Future<void>.delayed(Duration.zero);

    expect(state.selectedMessages, hasLength(1));
    expect(state.selectedMessages.first.ciphertext, <int>[1, 2, 3]);
  });

  test('logout preserves local device identity for password sign-in', () async {
    final localStore = MemoryLocalStore();
    final api = FakeDeviceLinkApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      );

    await localStore.saveSession(state.session!);
    await state.logout();

    expect(state.session, isNull);
    final stored = await localStore.loadSession();
    expect(stored?.token, '');
    expect(stored?.deviceId, 'dev_owner');
  });

  group('reauthentication token rotation (T37C)', () {
    late MemoryLocalStore localStore;
    late _ReauthApiClient api;
    late List<String> syncTokens;
    late AppState state;

    setUp(() async {
      localStore = MemoryLocalStore();
      api = _ReauthApiClient();
      syncTokens = <String>[];
      state = AppState(
        apiClientFactory: (_) => api,
        cryptoService: TestOnlyCryptoService(),
        localStore: localStore,
        syncServiceFactory: (_, token) {
          syncTokens.add(token);
          return FakeSyncService();
        },
      )
        ..api = api
        ..session = const Session(
          baseUrl: 'https://localhost:8080',
          token: 'owner-token',
          accountId: 'acct_owner',
          deviceId: 'dev_owner',
          username: 'owner',
          deviceSecret: 'device-secret',
          role: 'owner',
        );
      await localStore.saveSession(state.session!);
    });

    tearDown(() => state.dispose());

    test('adopts, persists and reconnects with a rotated token', () async {
      api.rotatedToken = 'rotated-token';
      expect(await state.reauthenticate('owner-password-123'), isTrue);
      expect(api.reauthTokens, <String>['owner-token']);
      final current = state.session!;
      expect(current.token, 'rotated-token');
      expect(current.accountId, 'acct_owner');
      expect(current.deviceId, 'dev_owner');
      expect(current.deviceSecret, 'device-secret');
      expect(current.role, 'owner');
      expect((await localStore.loadSession())?.token, 'rotated-token');
      await pumpEventQueue();
      expect(syncTokens, contains('rotated-token'));
      expect(syncTokens, isNot(contains('owner-token')));

      // The next sensitive action uses the new token, never the old one.
      api.rotatedToken = 'rotated-again';
      expect(await state.reauthenticate('owner-password-123'), isTrue);
      expect(api.reauthTokens, <String>['owner-token', 'rotated-token']);
      expect(state.session?.token, 'rotated-again');
    });

    test('keeps the token when the server does not rotate', () async {
      api.rotatedToken = null;
      expect(await state.reauthenticate('owner-password-123'), isTrue);
      expect(state.session?.token, 'owner-token');
      expect((await localStore.loadSession())?.token, 'owner-token');
      expect(syncTokens, isEmpty);
    });

    test('a refused reauthentication keeps the session and token', () async {
      api.failure = ApiException(429, '{"error":"reauth_backoff"}');
      expect(await state.reauthenticate('owner-password-123'), isFalse);
      expect(state.session?.token, 'owner-token');
      expect((await localStore.loadSession())?.token, 'owner-token');
    });

    test('a wrong reauthentication password does not sign out', () async {
      api.failure = ApiException(401, '{"error":"invalid_credentials"}');
      expect(await state.reauthenticate('wrong-password'), isFalse);
      expect(state.session?.token, 'owner-token');
      expect((await localStore.loadSession())?.token, 'owner-token');
      expect(state.error, isNotNull);
    });

    test('a rejected session token still signs out', () async {
      api.failure = ApiException(401, '{"error":"unauthorized"}');
      expect(await state.reauthenticate('owner-password-123'), isFalse);
      expect(state.session, isNull);
    });
  });

  test('failed encrypted envelope persists and retry reuses its key', () async {
    final localStore = MemoryLocalStore();
    final api = _OutboxApiClient()..failSend = true;
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group'),
      ];

    await state.sendMessageTo('conv_1', 'test-only plaintext');

    for (var attempt = 0;
        attempt < 20 &&
            state.outboxState(
                    state.pendingFor('conv_1').single.idempotencyKey) ==
                OutboxDeliveryState.sending;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(state.pendingFor('conv_1'), hasLength(1));
    final key = state.pendingFor('conv_1').single.idempotencyKey;
    expect(state.outboxState(key), OutboxDeliveryState.retrying);
    expect((await localStore.pendingEnvelopes()).single.idempotencyKey, key);

    api.failSend = false;
    await state.retryEnvelope(key);

    expect(api.sentKeys, <String>[key, key]);
    expect(state.pendingFor('conv_1'), isEmpty);
    expect(await localStore.pendingEnvelopes(), isEmpty);
  });

  test('restore failure enters recovery without resetting the cursor',
      () async {
    final localStore = _FailingRestoreStore();
    await localStore.saveSyncCursor(42);
    final state = AppState(
      apiClientFactory: (_) => throw UnimplementedError(),
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );

    await state.tryRestoreSession();

    expect(state.lifecycle, SessionLifecycle.recoveryRequired);
    expect(state.recoveryMessage, isNotNull);
    expect(await localStore.loadSyncCursor(), 42);
    state.continueWithoutRestore();
    expect(state.lifecycle, SessionLifecycle.ready);
    state.dispose();
  });

  test('an unreadable database offers retry or a confirmed reset only',
      () async {
    final localStore = _UnreadableStore();
    final state = AppState(
      apiClientFactory: (_) => throw UnimplementedError(),
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );

    await state.tryRestoreSession();
    expect(state.lifecycle, SessionLifecycle.recoveryRequired);
    expect(state.localStoreFailure, LocalStoreFailureKind.keyMissing);
    expect(state.canContinueWithoutRestore, isFalse);
    expect(state.recoveryMessage, contains('Nothing has been deleted'));

    // Continuing to sign in is not offered and does nothing.
    state.continueWithoutRestore();
    expect(state.lifecycle, SessionLifecycle.recoveryRequired);
    expect(() => state.resetUnreadableLocalData(confirmed: false),
        throwsArgumentError);
    expect(localStore.quarantined, isFalse);

    await state.resetUnreadableLocalData(confirmed: true);
    expect(localStore.quarantined, isTrue);
    expect(state.lifecycle, SessionLifecycle.ready);
    expect(state.localStoreFailure, isNull);
    state.dispose();
  });

  test('a wrong key and a failed upgrade get their own recovery messages',
      () async {
    final localStore = _UnreadableStore(LocalStoreFailureKind.keyRejected);
    final state = AppState(
      apiClientFactory: (_) => throw UnimplementedError(),
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );

    await state.tryRestoreSession();
    expect(state.localStoreFailure, LocalStoreFailureKind.keyRejected);
    expect(state.recoveryMessage, state.l10n.recoveryKeyMissing);
    expect(state.canResetLocalData, isTrue);

    // An upgrade that ran out of space is not a wrong key: the message says
    // to free space and retry, and no reset is offered or done at first.
    localStore.kind = LocalStoreFailureKind.upgradeStorageFull;
    await state.tryRestoreSession();
    expect(state.lifecycle, SessionLifecycle.recoveryRequired);
    expect(state.localStoreFailure, LocalStoreFailureKind.upgradeStorageFull);
    expect(state.recoveryMessage, state.l10n.recoveryUpgradeFailed);
    expect(state.recoveryMessage, isNot(state.l10n.recoveryKeyMissing));
    expect(state.canResetLocalData, isFalse);
    expect(state.canContinueWithoutRestore, isFalse);
    await state.resetUnreadableLocalData(confirmed: true);
    expect(localStore.quarantined, isFalse);
    expect(state.lifecycle, SessionLifecycle.recoveryRequired);

    // Once there is room again, a retry opens it.
    localStore.kind = null;
    await state.tryRestoreSession();
    expect(state.lifecycle, SessionLifecycle.ready);
    expect(state.localStoreFailure, isNull);
    expect(localStore.quarantined, isFalse);
    state.dispose();
  });

  test('an upgrade that keeps failing for space offers the confirmed reset',
      () async {
    final localStore =
        _UnreadableStore(LocalStoreFailureKind.upgradeStorageFull);
    final state = AppState(
      apiClientFactory: (_) => throw UnimplementedError(),
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );

    await state.tryRestoreSession();
    expect(state.canResetLocalData, isFalse);

    // The retry fails the same way: the user is not left stuck.
    await state.tryRestoreSession();
    expect(state.localStoreFailure, LocalStoreFailureKind.upgradeStorageFull);
    expect(state.recoveryMessage, state.l10n.recoveryUpgradeStillFull);
    expect(state.canResetLocalData, isTrue);
    expect(state.canContinueWithoutRestore, isFalse);
    expect(() => state.resetUnreadableLocalData(confirmed: false),
        throwsArgumentError);
    expect(localStore.quarantined, isFalse);

    // A restore that opens the database ends the run: a later failure for
    // space asks to free space and retry first again.
    localStore.kind = null;
    await state.tryRestoreSession();
    expect(state.lifecycle, SessionLifecycle.ready);
    localStore.kind = LocalStoreFailureKind.upgradeStorageFull;
    await state.tryRestoreSession();
    expect(state.recoveryMessage, state.l10n.recoveryUpgradeFailed);
    expect(state.canResetLocalData, isFalse);
    // So does a different failure in between.
    await state.tryRestoreSession();
    expect(state.canResetLocalData, isTrue);
    localStore.kind = LocalStoreFailureKind.keyUnavailable;
    await state.tryRestoreSession();
    localStore.kind = LocalStoreFailureKind.upgradeStorageFull;
    await state.tryRestoreSession();
    expect(state.canResetLocalData, isFalse);

    await state.tryRestoreSession();
    await state.resetUnreadableLocalData(confirmed: true);
    expect(localStore.quarantined, isTrue);
    expect(state.lifecycle, SessionLifecycle.ready);
    expect(state.localStoreFailure, isNull);
    state.dispose();
  });

  test('an upgrade that fails for another reason offers the reset at once',
      () async {
    final localStore = _UnreadableStore(LocalStoreFailureKind.upgradeFailed);
    final state = AppState(
      apiClientFactory: (_) => throw UnimplementedError(),
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );

    await state.tryRestoreSession();
    expect(state.lifecycle, SessionLifecycle.recoveryRequired);
    expect(state.localStoreFailure, LocalStoreFailureKind.upgradeFailed);
    // Freeing space would not help, so the message does not ask for it.
    expect(state.recoveryMessage, state.l10n.recoveryUpgradeError);
    expect(state.recoveryMessage, isNot(contains('space')));
    expect(state.canResetLocalData, isTrue);
    expect(state.canContinueWithoutRestore, isFalse);
    expect(() => state.resetUnreadableLocalData(confirmed: false),
        throwsArgumentError);
    expect(localStore.quarantined, isFalse);

    await state.resetUnreadableLocalData(confirmed: true);
    expect(localStore.quarantined, isTrue);
    expect(state.lifecycle, SessionLifecycle.ready);
    state.dispose();
  });

  for (final kind in <LocalStoreFailureKind>[
    LocalStoreFailureKind.keyRejected,
    LocalStoreFailureKind.upgradeStorageFull,
    LocalStoreFailureKind.upgradeFailed,
  ]) {
    testWidgets('the recovery screen for ${kind.name}', (tester) async {
      final state = AppState(
        apiClientFactory: (_) => throw UnimplementedError(),
        cryptoService: TestOnlyCryptoService(),
        localStore: _UnreadableStore(kind),
        syncServiceFactory: (_, __) => FakeSyncService(),
      );
      await tester.runAsync(state.tryRestoreSession);
      await tester.pumpWidget(veritraTestApp(state: state));
      await tester.pumpAndSettle();

      final message = switch (kind) {
        LocalStoreFailureKind.upgradeStorageFull =>
          state.l10n.recoveryUpgradeFailed,
        LocalStoreFailureKind.upgradeFailed => state.l10n.recoveryUpgradeError,
        _ => state.l10n.recoveryKeyMissing,
      };
      for (final text in <String>{
        state.l10n.recoveryUpgradeFailed,
        state.l10n.recoveryUpgradeError,
        state.l10n.recoveryKeyMissing,
      }) {
        expect(
            find.text(text), text == message ? findsOneWidget : findsNothing);
      }
      expect(find.text(state.l10n.shellRetryRestore), findsOneWidget);
      expect(find.text(state.l10n.shellContinueToSignIn), findsNothing);
      expect(
          find.text(state.l10n.shellResetDevice),
          kind == LocalStoreFailureKind.upgradeStorageFull
              ? findsNothing
              : findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  testWidgets('a retry that runs out of space again shows the reset',
      (tester) async {
    final localStore =
        _UnreadableStore(LocalStoreFailureKind.upgradeStorageFull);
    final state = AppState(
      apiClientFactory: (_) => throw UnimplementedError(),
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );
    await tester.runAsync(state.tryRestoreSession);
    await tester.pumpWidget(veritraTestApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text(state.l10n.shellResetDevice), findsNothing);

    await tester.tap(find.text(state.l10n.shellRetryRestore));
    // The retry queues behind the first restore, which ran outside the fake
    // clock; let that queue move.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text(state.l10n.recoveryUpgradeStillFull), findsOneWidget);
    expect(find.text(state.l10n.shellRetryRestore), findsOneWidget);

    // The reset still asks first; cancelling changes nothing.
    await tester.tap(find.text(state.l10n.shellResetDevice));
    await tester.pumpAndSettle();
    expect(find.text(state.l10n.shellResetTitle), findsOneWidget);
    await tester.tap(find.text(state.l10n.commonCancel));
    await tester.pumpAndSettle();
    expect(localStore.quarantined, isFalse);
    expect(state.lifecycle, SessionLifecycle.recoveryRequired);

    await tester.tap(find.text(state.l10n.shellResetDevice));
    await tester.pumpAndSettle();
    await tester.tap(find.text(state.l10n.shellResetConfirm));
    await tester.pumpAndSettle();
    expect(localStore.quarantined, isTrue);
    expect(state.lifecycle, SessionLifecycle.ready);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  test('full outbox refuses before encryption and keeps all entries', () async {
    final localStore = MemoryLocalStore();
    for (var index = 0; index < maxPendingEnvelopes; index++) {
      await localStore.enqueueEnvelope(_outboxEnvelope('queued_$index'));
    }
    final crypto = _CountingCryptoService();
    final state = AppState(
      apiClientFactory: (_) => _OutboxApiClient(),
      cryptoService: crypto,
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = _OutboxApiClient()
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      )
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group')
      ];

    expect(await state.sendMessageTo('conv_1', 'not accepted'), isFalse);
    expect(crypto.encryptCalls, 0);
    expect(await localStore.pendingEnvelopes(), hasLength(maxPendingEnvelopes));
    expect(
      (await localStore.pendingEnvelopes()).map((item) => item.idempotencyKey),
      contains('queued_0'),
    );
    state.dispose();
  });

  test('a retention change refreshes conversations and sync moves on',
      () async {
    final localStore = MemoryLocalStore();
    await localStore.saveSession(const Session(
      baseUrl: 'https://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
    ));
    final api = _RetentionApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    );

    await state.tryRestoreSession();
    for (var attempt = 0;
        attempt < 50 && await localStore.loadSyncCursor() < 3;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(await localStore.loadSyncCursor(), 3);
    expect(state.deviceRecoveryRequired, isFalse);
    expect(state.conversations.single.retentionSeconds, 3600);
  });

  test('sync fails closed when an edited event lacks its immutable envelope',
      () async {
    final localStore = MemoryLocalStore();
    final conversation = Conversation(id: 'conv_1', kind: 'group');
    final newest = ReceivedMessageEnvelope(
      id: 'msg_newest',
      conversationId: conversation.id,
      senderAccountId: 'acct_owner',
      senderDeviceId: 'dev_owner',
      idempotencyKey: 'idem_newest',
      ciphertext: <int>[1],
      cryptoProtocol: 'mls-openmls-todo',
      createdAt: DateTime.parse('2026-05-29T12:01:00Z'),
    );
    await localStore.saveSession(const Session(
      baseUrl: 'https://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
    ));
    await localStore.saveSnapshot(
      <Conversation>[conversation],
      <String, List<ReceivedMessageEnvelope>>{
        conversation.id: <ReceivedMessageEnvelope>[newest],
      },
      0,
    );
    final api = _RepairApiClient();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: localStore,
      syncServiceFactory: (_, __) => FakeSyncService(),
    )..selectedConversationId = conversation.id;

    await state.tryRestoreSession();
    for (var attempt = 0;
        attempt < 20 && !state.deviceRecoveryRequired;
        attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(api.listMessagesCalls, 0);
    expect(state.deviceRecoveryRequired, isTrue);
    expect(await localStore.loadSyncCursor(), 0);
    expect(state.messagesFor(conversation.id).map((message) => message.id),
        <String>['msg_newest']);
    state.dispose();
  });

  test('a failed list refresh keeps stale lists, reports safely, and retries',
      () async {
    final api = _FlakyListApiClient();
    final state = _signedInState(api);
    await state.refreshConversations();
    await state.refreshDevices();
    expect(state.conversations.map((c) => c.id), <String>['conv_1']);
    expect(state.devices.map((d) => d.id), <String>['dev_owner']);
    expect(state.errorFor(Ops.conversations), isNull);

    api.failure = ApiException(503, '{"error":"server_draining"}');
    await state.refreshConversations();
    await state.refreshDevices();
    expect(state.conversations.map((c) => c.id), <String>['conv_1'],
        reason: 'the last good list survives a failed refresh');
    expect(state.devices.map((d) => d.id), <String>['dev_owner']);
    expect(state.errorFor(Ops.conversations),
        'The server is restarting. Try again shortly.');
    expect(state.errorFor(Ops.devices),
        'The server is restarting. Try again shortly.');
    expect(state.session, isNotNull);

    api.failure = const ApiResponseException();
    await state.refreshConversations();
    expect(state.errorFor(Ops.conversations),
        'The server returned an unexpected response.');

    api.failure = null;
    await state.refreshConversations();
    await state.refreshDevices();
    expect(state.errorFor(Ops.conversations), isNull);
    expect(state.errorFor(Ops.devices), isNull);
    state.dispose();
  });

  test('a 401 list refresh signs out instead of surfacing raw errors',
      () async {
    final api = _FlakyListApiClient()
      ..failure = ApiException(401, '{"error":"unauthorized"}');
    final state = _signedInState(api);
    await state.refreshConversations();
    expect(state.session, isNull);
    expect(state.errorFor(Ops.conversations),
        'Your session is no longer valid. Sign in again.');
    state.dispose();
  });

  test('search failures reach the UI only as mapped sentences', () async {
    final api = _FlakyListApiClient()
      ..failure = ApiException(500, 'SENTINEL_BODY');
    final state = _signedInState(api);
    await expectLater(
      state.searchMetadata('alice'),
      throwsA(isA<UserFacingException>().having((e) => e.toString(), 'text',
          'The server had a problem. Try again shortly.')),
    );
    api.failure = StateError('internal invariant broke');
    await expectLater(
      state.searchMetadata('alice'),
      throwsA(isA<UserFacingException>()
          .having((e) => e.toString(), 'text', isNot(contains('invariant')))),
    );
    state.dispose();
  });
}

AppState _signedInState(ApiClient api) => AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      );

class _FlakyListApiClient extends ApiClient {
  _FlakyListApiClient() : super(baseUrl: 'https://localhost:8080');

  Object? failure;

  void _maybeFail() {
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<List<Conversation>> conversations(String token) async {
    _maybeFail();
    return <Conversation>[Conversation(id: 'conv_1', kind: 'dm')];
  }

  @override
  Future<List<Device>> devices(String token) async {
    _maybeFail();
    return <Device>[
      Device(
        id: 'dev_owner',
        accountId: 'acct_owner',
        name: 'Phone',
        createdAt: DateTime.utc(2026),
      ),
    ];
  }

  @override
  Future<List<MetadataSearchResult>> searchMetadata(
    String token,
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    _maybeFail();
    return const <MetadataSearchResult>[];
  }

  @override
  Future<void> logout(String token) async {}
}

class _WakePushService implements MobilePushService {
  _WakePushService({required int initialGeneration})
      : generation = initialGeneration;

  final _events = StreamController<PushEvent>.broadcast();
  final registered = Completer<void>();
  final List<int> acknowledged = <int>[];
  int generation;

  @override
  Stream<PushEvent> get events => _events.stream;

  @override
  Future<void> register({
    required String instance,
    String vapid = '',
    List<String> providers = const <String>[],
  }) {
    if (!registered.isCompleted) registered.complete();
    return Future<void>.value();
  }

  @override
  Future<NotificationPermission> notificationPermission() async =>
      NotificationPermission.granted;

  @override
  Future<NotificationPermission> requestNotificationPermission() async =>
      NotificationPermission.granted;

  @override
  Future<void> pickDistributor() async {}

  @override
  Future<void> unregister(String instance) async {}

  @override
  Future<int> pendingWakeGeneration() async => generation;

  @override
  Future<bool> acknowledgeWake(int target) async {
    if (target != generation) return false;
    acknowledged.add(target);
    generation = 0;
    return true;
  }

  void emitWake() {
    generation++;
    _events.add(const PushWakeEvent());
  }

  @override
  void dispose() {
    unawaited(_events.close());
  }
}

class _WakeApiClient extends FakeDeviceLinkApiClient {
  final cursorAdvanced = Completer<void>();
  int syncCalls = 0;
  bool _sentEvent = false;

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      <String, Object?>{
        'enabled': true,
        'providers': <String>['webpush'],
        'vapid_public_key': 'test-vapid',
      };

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')];

  @override
  Future<List<Device>> devices(String token) async => <Device>[];

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    syncCalls++;
    if (_sentEvent) return <SyncEvent>[];
    _sentEvent = true;
    if (!cursorAdvanced.isCompleted) cursorAdvanced.complete();
    return <SyncEvent>[
      SyncEvent(
        id: 7,
        type: 'conversation.updated',
        createdAt: DateTime.parse('2026-08-14T12:00:00Z'),
      ),
    ];
  }
}

class _CountingCryptoService extends TestOnlyCryptoService {
  int encryptCalls = 0;

  @override
  Future<MessageEnvelope> encrypt(String conversationId, String plaintext) {
    encryptCalls++;
    return super.encrypt(conversationId, plaintext);
  }
}

MessageEnvelope _outboxEnvelope(String key) => MessageEnvelope(
      conversationId: 'conv_1',
      idempotencyKey: key,
      ciphertext: <int>[1, 2, 3],
      cryptoProtocol: 'test-only-not-production',
    );

class _OutboxApiClient extends ApiClient {
  _OutboxApiClient() : super(baseUrl: 'https://localhost:8080');

  bool failSend = false;
  final List<String> sentKeys = <String>[];

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    sentKeys.add(envelope.idempotencyKey);
    if (failSend) {
      throw ApiException(503, 'unavailable');
    }
  }

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);
}

class FakeDeviceLinkApiClient extends ApiClient {
  FakeDeviceLinkApiClient({
    this.transcriptByte = 7,
    this.omitTranscript = false,
    this.refreshNonceByte = 1,
    this.refreshAccountId = 'acct_owner',
  }) : super(baseUrl: 'https://localhost:8080');

  final int transcriptByte;
  final bool omitTranscript;
  final int refreshNonceByte;
  final String refreshAccountId;

  @override
  Future<DeviceLink> createDeviceLink(String token) async {
    return _link(state: 'pending', code: 'PAIRCODE');
  }

  @override
  Future<DeviceLink> deviceLink(String token, String linkId) async {
    return _link(
      state: 'claimed',
      claimedDeviceName: 'linked tablet',
      refresh: true,
    );
  }

  @override
  Future<EnrollmentReservation> reserveDeviceLinkEnrollment(String code) async {
    return const EnrollmentReservation(
      id: 'dlink_1',
      accountId: 'acct_owner',
      deviceId: 'dev_linked',
      challenge: <int>[1, 2, 3],
      protocolVersion: 'veritra-device-link-v1',
      linkNonce: <int>[
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
      ],
      existingDeviceId: 'dev_owner',
      existingSigningKey: <int>[
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
        2,
      ],
    );
  }

  @override
  Future<DeviceLinkClaim> claimDeviceLink({
    required String code,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
    required DeviceLinkVerification verification,
  }) async {
    return DeviceLinkClaim(
      deviceLink: _link(state: 'claimed'),
      claimToken: 'claim-token',
      deviceSecret: 'device-secret',
    );
  }

  @override
  Future<DeviceLink> approveDeviceLink(
    String token,
    String linkId,
    List<int> transcriptHash,
  ) async {
    if (transcriptHash.length != 32 || transcriptHash.first != 7) {
      throw StateError('verification mismatch');
    }
    return _link(
      state: 'approved',
      code: 'PAIRCODE',
      approvedDeviceId: 'dev_linked',
    );
  }

  @override
  Future<Session?> completeDeviceLinkClaim(String linkId, String claimToken,
      List<int> expectedTranscriptHash) async {
    return const Session(
      baseUrl: 'https://localhost:8080',
      token: 'linked-token',
      accountId: 'acct_owner',
      deviceId: 'dev_linked',
    );
  }

  @override
  Future<List<Conversation>> conversations(String token) async {
    return <Conversation>[];
  }

  @override
  Future<List<Invite>> listInvites(String token) async {
    return <Invite>[];
  }

  @override
  Future<List<Community>> listCommunities(String token) async {
    return <Community>[];
  }

  @override
  Future<List<Channel>> listChannels(String token, String communityId) async {
    return <Channel>[];
  }

  @override
  Future<List<Device>> devices(String token) async {
    return <Device>[
      Device(
        id: 'dev_linked',
        accountId: 'acct_owner',
        name: 'linked tablet',
        createdAt: DateTime.parse('2026-05-29T12:00:00Z'),
      ),
    ];
  }

  @override
  Future<void> logout(String token) async {}

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    return MessagePage(messages: <ReceivedMessageEnvelope>[
      ReceivedMessageEnvelope(
        id: 'msg_1',
        conversationId: conversationId,
        senderAccountId: 'acct_owner',
        senderDeviceId: 'dev_owner',
        idempotencyKey: 'idem_1',
        ciphertext: <int>[1, 2, 3],
        cryptoProtocol: 'mls-openmls-todo',
        createdAt: DateTime.parse('2026-05-29T12:00:00Z'),
      ),
    ]);
  }

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    return <SyncEvent>[];
  }

  DeviceLink _link({
    required String state,
    String? code,
    String? approvedDeviceId,
    String? claimedDeviceName,
    bool refresh = false,
  }) {
    return DeviceLink(
      id: 'dlink_1',
      state: state,
      verificationCode: state == 'pending' ? '' : '654321',
      expiresAt: DateTime.parse('2026-05-29T12:00:00Z'),
      code: code,
      linkUri: code == null ? null : 'veritra://device-link?code=$code',
      claimedDeviceName: claimedDeviceName,
      approvedDeviceId: approvedDeviceId,
      accountId: refresh ? refreshAccountId : 'acct_owner',
      createdByDeviceId: 'dev_owner',
      protocolVersion: 'veritra-device-link-v1',
      linkNonce: List<int>.filled(32, refresh ? refreshNonceByte : 1),
      existingSigningKey: List<int>.filled(32, 2),
      claimedDeviceId: state == 'pending' ? null : 'dev_linked',
      claimedSigningKey: state == 'pending' ? null : List<int>.filled(32, 9),
      transcriptHash: state == 'pending' || (refresh && omitTranscript)
          ? null
          : List<int>.filled(32, transcriptByte),
    );
  }
}

class _RetentionApiClient extends FakeDeviceLinkApiClient {
  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[
        Conversation(id: 'conv_1', kind: 'group', retentionSeconds: 3600),
      ];

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    if (after >= 3) return <SyncEvent>[];
    return <SyncEvent>[
      SyncEvent(
        id: 3,
        type: 'retention.updated',
        conversationId: 'conv_1',
        payload: <String, Object?>{'id': 'conv_1'},
        createdAt: DateTime.parse('2026-09-24T12:00:00Z'),
      ),
    ];
  }
}

class _RepairApiClient extends FakeDeviceLinkApiClient {
  final Completer<void> repairFetched = Completer<void>();
  int listMessagesCalls = 0;

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')];

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    if (after >= 7) {
      return <SyncEvent>[];
    }
    return <SyncEvent>[
      SyncEvent(
        id: 7,
        type: 'message.envelope.edited',
        conversationId: 'conv_1',
        payload: <String, Object?>{
          'message_id': 'msg_old',
          'conversation_id': 'conv_1',
        },
        createdAt: DateTime.parse('2026-05-29T12:02:00Z'),
      ),
    ];
  }

  @override
  Future<ReceivedMessageEnvelope> message(
    String token,
    String messageId,
  ) async {
    if (!repairFetched.isCompleted) {
      repairFetched.complete();
    }
    return ReceivedMessageEnvelope(
      id: messageId,
      conversationId: 'conv_1',
      senderAccountId: 'acct_owner',
      senderDeviceId: 'dev_owner',
      idempotencyKey: 'idem_old',
      ciphertext: <int>[9, 9],
      cryptoProtocol: 'mls-openmls-todo',
      createdAt: DateTime.parse('2026-05-29T12:00:00Z'),
      editedAt: DateTime.parse('2026-05-29T12:02:00Z'),
    );
  }

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    listMessagesCalls++;
    return const MessagePage(messages: <ReceivedMessageEnvelope>[]);
  }
}

class _UnreadableStore extends MemoryLocalStore {
  _UnreadableStore([this.kind = LocalStoreFailureKind.keyMissing]);

  LocalStoreFailureKind? kind;
  bool quarantined = false;

  @override
  Future<Session?> loadSession() async {
    final failure = kind;
    if (quarantined || failure == null) return null;
    throw LocalStoreUnavailableException(failure);
  }

  @override
  Future<void> quarantineUnreadableDatabase({required bool confirmed}) async {
    quarantined = true;
  }
}

class _FailingRestoreStore extends MemoryLocalStore {
  @override
  Future<Session?> loadSession() async {
    throw StateError('database key unavailable');
  }
}

class _ReauthApiClient extends FakeDeviceLinkApiClient {
  String? rotatedToken;
  Object? failure;
  final List<String> reauthTokens = <String>[];

  @override
  Future<String?> reauthenticate(
    String token,
    String password,
    String deviceSecret,
  ) async {
    final error = failure;
    if (error != null) throw error;
    reauthTokens.add(token);
    return rotatedToken;
  }
}

class FakeSyncService implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {
    _controller.close();
  }
}
