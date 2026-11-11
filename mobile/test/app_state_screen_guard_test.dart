import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _NoopSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _RefreshApi implements ApiClient {
  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryLocalStore store;
  late FakeScreenGuard screenGuard;
  late _RefreshApi api;
  late AppState state;
  var disposed = false;

  setUp(() {
    disposed = false;
    store = MemoryLocalStore();
    screenGuard = FakeScreenGuard();
    api = _RefreshApi();
    state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      screenGuard: screenGuard,
      syncServiceFactory: (_, __) => _NoopSync(),
    )..api = api;
  });

  tearDown(() async {
    if (!disposed) {
      state.dispose();
    }
    await state.backgroundWorkIdle.timeout(const Duration(seconds: 10));
  });

  test(
      'default setting is true and screen guard is inactive before entering chat',
      () async {
    expect(state.screenGuardChats, isTrue);
    expect(state.activeChatViewsForTesting, 0);
    expect(state.isScreenGuardActive, isFalse);
    expect(await screenGuard.isSecure(), isFalse);
  });

  test('entering and leaving chat views toggles screen guard', () async {
    state.enterChatView();
    expect(state.activeChatViewsForTesting, 1);
    expect(state.isScreenGuardActive, isTrue);
    expect(await screenGuard.isSecure(), isTrue);
    expect(screenGuard.history, [true]);

    // Second view (e.g. nested route or wide layout) keeps guard active
    state.enterChatView();
    expect(state.activeChatViewsForTesting, 2);
    expect(state.isScreenGuardActive, isTrue);
    expect(screenGuard.history, [true, true]);

    state.leaveChatView();
    expect(state.activeChatViewsForTesting, 1);
    expect(state.isScreenGuardActive, isTrue);

    state.leaveChatView();
    expect(state.activeChatViewsForTesting, 0);
    expect(state.isScreenGuardActive, isFalse);
    expect(await screenGuard.isSecure(), isFalse);
    expect(screenGuard.history, [true, true, true, false]);

    // Leaving when already 0 does not underflow
    state.leaveChatView();
    expect(state.activeChatViewsForTesting, 0);
    expect(state.isScreenGuardActive, isFalse);
  });

  test('disabling the setting turns off screen guard even when in chat',
      () async {
    state.enterChatView();
    expect(state.isScreenGuardActive, isTrue);
    expect(await screenGuard.isSecure(), isTrue);

    var notified = false;
    state.addListener(() => notified = true);

    await state.setScreenGuardChats(false);
    expect(state.screenGuardChats, isFalse);
    expect(notified, isTrue);
    expect(await store.loadSetting('screen_guard_chats'), 'false');
    expect(state.isScreenGuardActive, isFalse);
    expect(await screenGuard.isSecure(), isFalse);

    // Entering another chat while setting is false does not activate guard
    state.enterChatView();
    expect(state.activeChatViewsForTesting, 2);
    expect(state.isScreenGuardActive, isFalse);
    expect(await screenGuard.isSecure(), isFalse);

    // Re-enabling setting while in chat activates guard immediately
    await state.setScreenGuardChats(true);
    expect(state.screenGuardChats, isTrue);
    expect(await store.loadSetting('screen_guard_chats'), 'true');
    expect(state.isScreenGuardActive, isTrue);
    expect(await screenGuard.isSecure(), isTrue);

    state.leaveChatView();
    state.leaveChatView();
    expect(state.isScreenGuardActive, isFalse);
    expect(await screenGuard.isSecure(), isFalse);
  });

  test('refreshConversations loads screen guard setting from store', () async {
    await store.saveSetting('screen_guard_chats', 'false');
    state.session = const Session(
      baseUrl: 'https://localhost',
      token: 'tok',
      accountId: 'acct',
      deviceId: 'dev',
    );
    await state.refreshConversations();
    expect(state.screenGuardChats, isFalse);

    await store.saveSetting('screen_guard_chats', 'true');
    await state.refreshConversations();
    expect(state.screenGuardChats, isTrue);
  });

  test('dispose disables screen guard', () async {
    state.enterChatView();
    expect(await screenGuard.isSecure(), isTrue);

    disposed = true;
    state.dispose();
    expect(await screenGuard.isSecure(), isFalse);
  });
}
