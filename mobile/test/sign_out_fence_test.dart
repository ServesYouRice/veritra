// Sign-out takes several awaits before `session` becomes null. Work that
// started under the old session and finishes in that window must not write
// to the store after its wipe (TASK-061 follow-up).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a mute reply that lands after sign-out leaves no row behind', () async {
    final store = MemoryLocalStore();
    final api = _HeldMuteApi();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _IdleSync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      );
    await store.saveSession(state.session!);

    final read = state.loadConversationMuted('conv_1');
    await api.asked.future;
    await state.logout();
    expect(state.session, isNull);

    api.reply.complete(const ConversationMute(muted: true));
    expect(await read, isFalse, reason: 'the reply belongs to an old session');
    await Future<void>.delayed(Duration.zero);
    expect(state.isMuted('conv_1'), isFalse);
    expect(await store.loadConversationMutes(), isEmpty);
  });

  test('a mute reply while sign-out is still running is dropped', () async {
    final store = MemoryLocalStore();
    final api = _HeldMuteApi();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _IdleSync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      );
    final entered = Completer<void>();
    final release = Completer<void>();
    state.beforeLocalSessionClear = () async {
      entered.complete();
      await release.future;
    };

    final read = state.loadConversationMuted('conv_1');
    await api.asked.future;
    final signOut = state.logout();
    await entered.future;
    // The session is still set: this is the window the fence covers.
    expect(state.session, isNotNull);
    api.reply.complete(const ConversationMute(muted: true));
    expect(await read, isFalse);
    release.complete();
    await signOut;
    expect(state.isMuted('conv_1'), isFalse);
    expect(await store.loadConversationMutes(), isEmpty);
  });

  test('a mute read that starts while sign-out runs stores nothing', () async {
    final store = MemoryLocalStore();
    final api = _HeldMuteApi();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _IdleSync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      );
    final entered = Completer<void>();
    final release = Completer<void>();
    state.beforeLocalSessionClear = () async {
      entered.complete();
      await release.future;
    };
    final signOut = state.logout();
    await entered.future;
    expect(state.session, isNotNull);
    expect(state.sessionEnding, isTrue);
    api.reply.complete(const ConversationMute(muted: true));
    expect(await state.loadConversationMuted('conv_1'), isFalse);
    release.complete();
    await signOut;
    expect(state.sessionEnding, isFalse);
    expect(state.isMuted('conv_1'), isFalse);
    expect(await store.loadConversationMutes(), isEmpty);
  });
}

class _HeldMuteApi extends ApiClient {
  _HeldMuteApi() : super(baseUrl: 'https://localhost:8080');

  final Completer<void> asked = Completer<void>();
  final Completer<ConversationMute> reply = Completer<ConversationMute>();

  @override
  Future<ConversationMute> conversationMute(
      String token, String conversationId) {
    asked.complete();
    return reply.future;
  }

  @override
  Future<void> logout(String token) async {}

  @override
  void close() {}
}

class _IdleSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}
