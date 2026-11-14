import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/formatted_message.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/tokens.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// UI-audit cards U7, U13, U14, U29 and U36 on the chat screen.
void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
        'U14: your own bubble is filled with the plum token, $brightness',
        (tester) async {
      final store = MemoryLocalStore(), state = _state();
      state.localStoreOverride = store;
      await _seed(store);
      await state.refreshHistory('conv');
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: ChatScreen(state: state, conversationId: 'conv')));
      await tester.pumpAndSettle();
      expect(
          find.ancestor(
              of: find.text('hello'),
              matching: find.byWidgetPredicate((widget) =>
                  widget is Container &&
                  (widget.decoration as BoxDecoration?)?.color ==
                      BoneColors.ownBubble(brightness))),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  testWidgets('U13: "encrypted" is said once, at the start of the chat',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store, extra: [
      for (var i = 0; i < 3; i++)
        InsertMessageEffect(
            key: 'dev:m$i',
            conversationId: 'conv',
            senderAccountId: i.isEven ? 'alice' : 'bob',
            senderDeviceId: 'dev',
            kind: LocalMessageKind.text,
            body: 'body $i',
            createdAt: 2 + i,
            state: LocalMessageState.received),
    ]);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    expect(find.byType(FormattedMessage), findsNWidgets(4));
    // One notice, and it is the only padlock: no header line, no per-bubble
    // lock.
    final notice = find.byKey(const Key('chat-encryption-notice'));
    expect(notice, findsOneWidget);
    expect(find.text(englishL10n.chatNoticeEncryptedDm), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.textContaining('ENCRYPTED'), findsNothing);
    // It opens the chat: above the oldest message.
    expect(tester.getBottomLeft(notice).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.text('hello')).dy));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('U13: a muted chat keeps a plain Muted line in its header',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.chatStatusMuted), findsNothing);
    await state.setConversationMuted('conv', true);
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.chatStatusMuted), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  for (final (kind, dm) in <(String, bool)>[('dm', true), ('group', false)]) {
    testWidgets('U36: an empty $kind chat says who can read it',
        (tester) async {
      final state = _state()
        ..conversations = [
          Conversation(
              id: 'conv', kind: kind, title: 'Team', createdBy: 'alice')
        ];
      await tester.pumpWidget(
          MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
      await tester.pumpAndSettle();
      expect(
          find.text(dm
              ? englishL10n.chatEmptyMessageDm
              : englishL10n.chatEmptyMessageGroup),
          findsOneWidget);
      expect(englishL10n.chatEmptyMessageDm, 'Only you two can read this.');
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  testWidgets('U7: a long-press on the message text opens the action sheet',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    // The text itself, not the bubble's padding.
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.chatCopyText), findsOneWidget);
    expect(find.text(englishL10n.chatSelectText), findsOneWidget);
    // Selecting happens inside the sheet that "Select text" opens.
    await tester.tap(find.text(englishL10n.chatSelectText));
    await tester.pumpAndSettle();
    final selectable = find.byKey(const Key('select-text'));
    expect(selectable, findsOneWidget);
    expect(
        find.descendant(of: selectable, matching: find.byType(SelectableText)),
        findsOneWidget);
    // No bubble in the thread is selectable by itself.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}

class _UiState extends AppState {
  _UiState._(this.stub)
      : super(
            apiClientFactory: (_) => _UiApi(),
            cryptoService: stub,
            localStore: MemoryLocalStore(),
            syncServiceFactory: (_, __) => _QuietSync());
  factory _UiState([_MlsStub? stub]) => _UiState._(stub ?? _MlsStub());
  final _MlsStub stub;
  LocalStore? localStoreOverride;
  @override
  LocalStore get localStore => localStoreOverride ?? super.localStore;
}

class _UiApi extends ApiClient {
  _UiApi() : super(baseUrl: 'https://example.test');
  @override
  Future<ConversationMute> setConversationMute(
    String token,
    String conversationId, {
    required bool muted,
    Duration? forDuration,
  }) async =>
      ConversationMute(muted: muted);
  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}
  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      const [];
}

_UiState _state() {
  final stub = _MlsStub();
  return _UiState(stub)
    ..api = _UiApi()
    ..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'alice',
        deviceId: 'dev')
    ..conversations = [
      Conversation(id: 'conv', kind: 'dm', title: 'Team', createdBy: 'alice')
    ]
    ..conversationsLoaded = true;
}

Future<void> _seed(LocalStore store,
    {String messageState = LocalMessageState.received,
    String conversationId = 'conv',
    String key = 'dev:t',
    String body = 'hello',
    String? formatJson,
    int? forwardHops,
    List<MessageEffect> extra = const []}) async {
  if (await store.loadCryptoState() == null) {
    await store.saveCryptoState(
        StoredCryptoState(
            counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
        0);
  }
  final current = (await store.loadCryptoState())!;
  final cursor = await store.loadSyncCursor();
  await store.commitMlsTransition(MlsStateTransition(
      messageId: 'seed-${cursor + 1}',
      conversationId: conversationId,
      expectedCounter: current.counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
          counter: current.counter + 1,
          stateKey: current.stateKey,
          sealedState: [current.counter + 1]),
      cursor: cursor + 1,
      messageEffects: [
        InsertMessageEffect(
            key: key,
            conversationId: conversationId,
            senderAccountId: 'alice',
            senderDeviceId: 'dev',
            kind: LocalMessageKind.text,
            body: body,
            formatJson: formatJson,
            forwardHops: forwardHops,
            createdAt: 1,
            state: messageState),
        ...extra,
      ]));
}

class _MlsStub implements MlsConversationCryptoService {
  AppPayloadType? lastEncryptedType;
  Map<String, Object?>? lastEncryptedBody;

  @override
  Future<void> dispose() async {}
  @override
  Future<MessageEnvelope> encryptPayload(
      String conversationId, AppPayloadType type, Map<String, Object?> body,
      {List<String> attachmentRefs = const [], String? draftText}) async {
    lastEncryptedType = type;
    lastEncryptedBody = body;
    return MessageEnvelope(
        conversationId: conversationId,
        idempotencyKey: 'action',
        ciphertext: const [1],
        cryptoProtocol: 'test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}
