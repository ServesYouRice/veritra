// Cards I30 and I32: paused-future tests for duplicate sync pages, the
// restore lifecycle and account switching. Nothing here may let a page from
// an old session write into the next one, or let the cursor move backwards
// or past an event that was not applied.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _alice = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token-alice',
  accountId: 'acct_alice',
  deviceId: 'dev_alice',
);
const _bob = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token-bob',
  accountId: 'acct_bob',
  deviceId: 'dev_bob',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState stateFor(LocalStore store, _SessionApi api) => AppState(
        apiClientFactory: (_) => api,
        cryptoService: TestOnlyCryptoService(),
        localStore: store,
        syncServiceFactory: (_, __) => _QuietSync(),
      );

  Future<void> waitFor(FutureOr<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    fail('condition not reached');
  }

  Future<void> settle() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('I30: replayed and repeated sync events are never applied twice',
      () async {
    final store = MemoryLocalStore();
    await store.saveSession(_alice);
    final api = _SessionApi()
      ..pages[_alice.token] = <List<SyncEvent>>[
        <SyncEvent>[_event(1), _event(2), _event(3)],
      ];
    final state = stateFor(store, api);
    await state.tryRestoreSession();
    await waitFor(() async => await store.loadSyncCursor() == 3);
    final refreshes = api.conversationCalls;

    // The server replays events at or below the cursor: nothing is applied,
    // the cursor stays, and the failure is retried rather than recorded.
    api.pages[_alice.token]!
      ..add(<SyncEvent>[_event(2), _event(3), _event(4)])
      ..add(<SyncEvent>[_event(5), _event(5)]);
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await waitFor(() => api.syncCalls[_alice.token]! >= 2);
    await settle();
    expect(await store.loadSyncCursor(), 3);
    expect(api.conversationCalls, refreshes);
    expect(state.syncRecovery, isNull);
    expect(await store.loadSyncRecovery(), isNull);

    // A page that repeats one event id is refused the same way.
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await waitFor(() => api.syncCalls[_alice.token]! >= 3);
    await settle();
    expect(await store.loadSyncCursor(), 3);
    expect(api.conversationCalls, refreshes);

    // Once the server is sane again sync carries on from the kept cursor.
    api.pages[_alice.token]!.add(<SyncEvent>[_event(4)]);
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    await waitFor(() async => await store.loadSyncCursor() == 4);
    expect(api.afterSeen[_alice.token]!.last, 3);
    expect(await store.hasProcessedMlsMessage('sync:4'), isTrue);
    state.dispose();
  });

  test('I32: restoring a session never shows a ready, signed-out state',
      () async {
    final store = _GatedStore();
    await store.saveSession(_alice);
    final api = _SessionApi()..conversationGate = Completer<void>();
    final state = stateFor(store, api);
    final seen = <String>[];
    state.addListener(() {
      seen.add('${state.lifecycle.name}:${state.session != null}');
    });

    final restore = state.tryRestoreSession();
    await settle();
    expect(state.lifecycle, SessionLifecycle.initializing);
    expect(state.session, isNull);

    store.sessionGate.complete();
    await waitFor(() => api.conversationCalls > 0);
    expect(state.lifecycle, SessionLifecycle.initializing,
        reason: 'ready before the restore finished');

    api.conversationGate!.complete();
    await restore;
    expect(state.lifecycle, SessionLifecycle.ready);
    expect(state.session?.accountId, _alice.accountId);
    expect(seen, isNot(contains('ready:false')),
        reason: 'a signed-in user briefly looked logged out: $seen');
    state.dispose();
  });

  test(
      'I30/I32: a page held across logout and account switch never writes '
      'into either account', () async {
    final store = MemoryLocalStore();
    await store.saveSession(_alice);
    final held = Completer<void>();
    final api = _SessionApi()
      ..pages[_alice.token] = <List<SyncEvent>>[
        <SyncEvent>[_event(1), _event(2)],
      ]
      ..pages[_bob.token] = <List<SyncEvent>>[
        <SyncEvent>[_event(11)],
      ]
      ..syncGate[_alice.token] = held;
    final state = stateFor(store, api);
    await state.tryRestoreSession();
    await waitFor(() => api.syncHeld.contains(_alice.token));

    // Alice signs out while her page is in flight. Logout fences the old
    // session at once and then waits for the page to drain (I32).
    var loggedOut = false;
    final logout = state.logout().then((_) => loggedOut = true);
    await settle();
    expect(loggedOut, isFalse, reason: 'logout did not wait for sync');
    expect(await store.loadSyncCursor(), 0);
    final aliceCallsAtLogout = api.conversationCallsFor[_alice.token] ?? 0;
    held.complete();
    await logout;
    expect(state.session, isNull);
    await settle();
    expect(await store.loadSyncCursor(), 0);
    expect(await store.hasProcessedMlsMessage('sync:1'), isFalse);
    expect(api.conversationCallsFor[_alice.token] ?? 0, aliceCallsAtLogout,
        reason: 'the held page refreshed state after logout');
    expect(state.conversations, isEmpty);

    // Bob signs in on the same device: his sync starts from his own cursor
    // and nothing from Alice's page reaches his state.
    await store.saveSession(_bob);
    await state.tryRestoreSession();
    await waitFor(() async => await store.loadSyncCursor() == 11);
    expect(api.afterSeen[_bob.token], <int>[0]);
    expect(await store.hasProcessedMlsMessage('sync:1'), isFalse);
    expect(await store.hasProcessedMlsMessage('sync:2'), isFalse);
    expect(state.session?.accountId, _bob.accountId);
    expect(state.conversations.map((item) => item.id), <String>['conv_bob']);
    expect(api.syncCalls[_alice.token], 1,
        reason: 'Alice was synced again after she signed out');
    state.dispose();
  });
}

SyncEvent _event(int id) => SyncEvent(
      id: id,
      type: 'conversation.updated',
      createdAt: DateTime.utc(2026, 10, 23),
    );

class _SessionApi extends ApiClient {
  _SessionApi() : super(baseUrl: 'https://localhost:8080');

  final Map<String, List<List<SyncEvent>>> pages =
      <String, List<List<SyncEvent>>>{};
  final Map<String, Completer<void>> syncGate = <String, Completer<void>>{};
  final Set<String> syncHeld = <String>{};
  final Map<String, int> syncCalls = <String, int>{};
  final Map<String, List<int>> afterSeen = <String, List<int>>{};
  final Map<String, int> conversationCallsFor = <String, int>{};
  Completer<void>? conversationGate;
  int conversationCalls = 0;

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    syncCalls[token] = (syncCalls[token] ?? 0) + 1;
    (afterSeen[token] ??= <int>[]).add(after);
    final gate = syncGate.remove(token);
    if (gate != null) {
      syncHeld.add(token);
      await gate.future;
    }
    final queue = pages[token];
    if (queue == null || queue.isEmpty) return const <SyncEvent>[];
    return queue.removeAt(0);
  }

  @override
  Future<List<Conversation>> conversations(String token) async {
    conversationCalls++;
    conversationCallsFor[token] = (conversationCallsFor[token] ?? 0) + 1;
    final gate = conversationGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    return <Conversation>[
      Conversation(
          id: token == _bob.token ? 'conv_bob' : 'conv_alice', kind: 'group'),
    ];
  }

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<void> logout(String token) async {}
}

class _GatedStore extends MemoryLocalStore {
  final Completer<void> sessionGate = Completer<void>();

  @override
  Future<Session?> loadSession() async {
    await sessionGate.future;
    return super.loadSession();
  }
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
