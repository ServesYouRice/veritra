// C1 prerequisite 1: a conversation paused by its own sync failure says so,
// offers a retry (or only leaving it when the server no longer holds the
// missing events), and leaves every other conversation's chat alone.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/l10n/app_localizations_en.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/conversation_pause.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);

  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      const <ConversationMember>[];

  @override
  Future<ConversationMute> conversationMute(
          String token, String conversationId) async =>
      ConversationMute(muted: false);

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<void> markRead(
      String token, String conversationId, String messageId) async {}
}

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

AppState _state(Map<String, ConversationPause> pauses) {
  final api = _Api();
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _Sync(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
    )
    ..conversations = <Conversation>[
      Conversation(id: 'conv_1', kind: 'group'),
      Conversation(id: 'conv_2', kind: 'group'),
    ]
    ..conversationPauses = pauses;
}

ConversationPause _pause(SyncFailureKind kind) => ConversationPause(
      conversationId: 'conv_1',
      resumeAfter: 3,
      failedEventId: 4,
      kind: kind,
      recordedAt: DateTime.utc(2026, 11, 7),
    );

Future<void> _open(WidgetTester tester, AppState state, String id) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(state: state, conversationId: id),
  ));
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester) async {
  // Lets the draft debounce run out before the test ends.
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  final notice = AppLocalizationsEn().chatSyncPausedNotice;
  const retry = ValueKey('sync-paused-retry');
  const leave = ValueKey('sync-paused-leave');

  testWidgets('a paused conversation offers retry and leave', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final state = _state(<String, ConversationPause>{
      'conv_1': _pause(SyncFailureKind.mlsState),
    });
    await _open(tester, state, 'conv_1');
    expect(find.text(notice), findsOneWidget);
    expect(find.byKey(retry), findsOneWidget);
    expect(find.byKey(leave), findsOneWidget);
    await _close(tester);
  });

  testWidgets('a conversation the server cannot replay offers only leave',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final state = _state(<String, ConversationPause>{
      'conv_1': _pause(SyncFailureKind.cursorExpired),
    });
    await _open(tester, state, 'conv_1');
    expect(find.text(notice), findsOneWidget);
    expect(find.byKey(retry), findsNothing);
    expect(find.byKey(leave), findsOneWidget);
    await _close(tester);
  });

  testWidgets('another conversation shows no notice', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final state = _state(<String, ConversationPause>{
      'conv_1': _pause(SyncFailureKind.mlsState),
    });
    await _open(tester, state, 'conv_2');
    expect(find.text(notice), findsNothing);
    expect(find.byKey(retry), findsNothing);
    await _close(tester);
  });
}
