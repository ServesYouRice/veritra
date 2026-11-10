import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/message_format.dart'
    show pinLimitPerChat;
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/message_ticks.dart';
import 'package:private_messenger/features/chat/formatted_message.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

void main() {
  testWidgets(
      'spoilers stay concealed until tapped and reset on a changed message',
      (tester) async {
    Widget app(String text) => MaterialApp(
        home: Scaffold(
            body: FormattedMessage(
                text: text,
                formatJson: jsonEncode({
                  'entities': [
                    {'type': 'spoiler', 'offset': 0, 'length': text.length}
                  ]
                }))));
    await tester.pumpWidget(app('secret'));
    String visible() => tester
        .widget<SelectableText>(find.byType(SelectableText))
        .textSpan!
        .toPlainText();
    expect(visible(), '█' * 6);
    await tester.tap(find.byType(SelectableText));
    await tester.pump();
    expect(visible(), 'secret');
    await tester.pumpWidget(app('different'));
    expect(visible(), '█' * 9);
  });

  testWidgets(
      'message actions scroll, star browsing works, delete for me hides the row',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    expect(find.byType(FormattedMessage), findsOneWidget);
    await tester.tap(find.byType(FormattedMessage),
        buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(englishL10n.w8Star));
    await tester.tap(find.text(englishL10n.w8Star));
    await tester.pumpAndSettle();
    expect(await store.loadStarred(), {'dev:t'});
    await tester.tap(find.byTooltip(englishL10n.w8StarredMessages));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.w8StarredMessages), findsOneWidget);
    expect(find.byIcon(Icons.star), findsWidgets);
    await tester.tap(find.text('hello').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FormattedMessage),
        buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(englishL10n.w8DeleteForMe));
    await tester.tap(find.text(englishL10n.w8DeleteForMe));
    await tester.pumpAndSettle();
    expect(find.byType(FormattedMessage), findsNothing);
    expect(await store.loadStarred(), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
      'restored own bubbles show snapshot provenance without live ticks',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store, messageState: LocalMessageState.restored);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.k2CopiedHistory), findsOneWidget);
    expect(
        tester
            .widget<MessageTickBuilder>(find.byType(MessageTickBuilder))
            .enabled,
        false);
    expect(find.byType(MessageTickIcon), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('fifty pins scroll in a bounded bar and any group member pins',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _seed(store, extra: [
      for (var i = 0; i < pinLimitPerChat; i++) ...[
        InsertMessageEffect(
            key: 'dev:p$i',
            conversationId: 'conv',
            senderAccountId: 'alice',
            senderDeviceId: 'dev',
            kind: LocalMessageKind.text,
            body: 'pinned $i',
            createdAt: now,
            state: LocalMessageState.received),
        PinMessageEffect(
            conversationId: 'conv',
            targetKey: 'dev:p$i',
            accountId: 'alice',
            at: now + i,
            pinned: true,
            durationSeconds: 86400),
      ]
    ]);
    await state.refreshHistory('conv');
    expect(state.pinsFor('conv'), hasLength(pinLimitPerChat));
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    final bar = find.byKey(const ValueKey('pin-bar'));
    expect(bar, findsOneWidget);
    expect(tester.getSize(bar).height, lessThanOrEqualTo(144));
    expect(find.byType(FormattedMessage), findsWidgets,
        reason: 'the timeline keeps its room below the pin bar');
    expect(tester.takeException(), isNull);

    state.conversations = [
      Conversation(id: 'conv', kind: 'group', title: 'Team', createdBy: 'bob')
    ];
    state.membersByConversation = {
      'conv': [
        ConversationMember(accountId: 'alice', role: 'member'),
        ConversationMember(accountId: 'bob', role: 'owner'),
      ]
    };
    expect(state.canPinMessages('conv'), isTrue);
    state.conversations = [
      Conversation(
          id: 'conv',
          kind: 'community_channel',
          title: 'Team',
          createdBy: 'bob')
    ];
    expect(state.canPinMessages('conv'), isFalse,
        reason: 'community channels keep moderator roles until C4');
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('archived chats remain reachable through the archive switch',
      (tester) async {
    final state = _state();
    await state.setConversationArchived('conv', true);
    await tester.pumpWidget(MaterialApp(home: ChatListScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('Team'), findsNothing);
    await tester.tap(find.byTooltip(englishL10n.w8ArchivedChats));
    await tester.pumpAndSettle();
    expect(find.text('Team'), findsOneWidget);
    expect(find.text(englishL10n.w8ArchivedChats), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('tapping a mention opens the member details modal sheet',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    state.membersByConversation = {
      'conv': [
        ConversationMember(accountId: 'bob', username: 'robert', role: 'member'),
      ]
    };
    await _seed(store,
        body: 'hello @robert',
        formatJson: jsonEncode({
          'mentions': [
            {'account_id': 'bob', 'offset': 6, 'length': 7}
          ]
        }));
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    expect(find.byType(FormattedMessage), findsOneWidget);
    // Tap on the formatted message text where @robert is displayed
    await tester.tap(find.textContaining('@robert'));
    await tester.pumpAndSettle();
    expect(find.text('robert'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
      'forward labels show hop count and forward dialog limits work in UI',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    state.conversations = [
      Conversation(id: 'conv', kind: 'dm', title: 'Chat 1', createdBy: 'alice'),
      Conversation(id: 'dest1', kind: 'dm', title: 'Chat 2', createdBy: 'alice'),
      Conversation(id: 'dest2', kind: 'dm', title: 'Chat 3', createdBy: 'alice'),
    ];
    await _seed(store,
        key: 'dev:f1',
        body: 'forward once',
        forwardHops: 1,
        extra: [
          const InsertMessageEffect(
              key: 'dev:f5',
              conversationId: 'conv',
              senderAccountId: 'alice',
              senderDeviceId: 'dev',
              kind: LocalMessageKind.text,
              body: 'forward many',
              forwardHops: 5,
              createdAt: 2,
              state: LocalMessageState.received)
        ]);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.w8Forwarded), findsOneWidget);
    expect(find.text(englishL10n.w8ForwardedMany), findsOneWidget);

    // Right-click on the f1 bubble and open forward dialog
    await tester.tap(find.text('forward once'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(englishL10n.w8Forward));
    await tester.tap(find.text(englishL10n.w8Forward));
    await tester.pumpAndSettle();

    // The forward dialog shows destinations with checkboxes
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(englishL10n.w8Forward), findsWidgets);
    await tester.tap(find.text('Chat 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, englishL10n.w8Forward));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('pin action sheet allows selecting duration and unpinning',
      (tester) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
        MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')));
    await tester.pumpAndSettle();

    // Right-click to open message actions
    await tester.tap(find.byType(FormattedMessage),
        buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(englishL10n.w8Pin));
    await tester.tap(find.text(englishL10n.w8Pin));
    await tester.pumpAndSettle();

    // Duration choices are shown: 1 day, 7 days, 30 days
    expect(find.text(englishL10n.w8PinDays(1)), findsOneWidget);
    expect(find.text(englishL10n.w8PinDays(7)), findsOneWidget);
    expect(find.text(englishL10n.w8PinDays(30)), findsOneWidget);
    await tester.tap(find.text(englishL10n.w8PinDays(7)));
    await tester.pumpAndSettle();

    // Simulate pin applied on store
    await store.commitMlsTransition(MlsStateTransition(
        messageId: 'pin-event',
        conversationId: 'conv',
        expectedCounter: 2,
        expectedCursor: 1,
        state: StoredCryptoState(
            counter: 3, stateKey: List.filled(32, 1), sealedState: [3]),
        cursor: 2,
        messageEffects: [
          PinMessageEffect(
              conversationId: 'conv',
              targetKey: 'dev:t',
              accountId: 'alice',
              at: DateTime.now().millisecondsSinceEpoch,
              pinned: true,
              durationSeconds: 604800)
        ]));
    await state.refreshHistory('conv');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pin-bar')), findsOneWidget);

    // Open message actions again; unpin should now be present
    await tester.tap(find.byType(FormattedMessage),
        buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(englishL10n.w8Pin));
    await tester.tap(find.text(englishL10n.w8Pin));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.w8Unpin), findsOneWidget);
    await tester.tap(find.text(englishL10n.w8Unpin));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('pinned chats appear at top of chat list and order by pinnedAt desc',
      (tester) async {
    final state = _state();
    state.conversations = [
      Conversation(id: 'c1', kind: 'group', title: 'Chat Alpha', createdBy: 'alice'),
      Conversation(id: 'c2', kind: 'group', title: 'Chat Beta', createdBy: 'alice'),
      Conversation(id: 'c3', kind: 'group', title: 'Chat Gamma', createdBy: 'alice'),
    ];
    // Pin c2 first (pinnedAt = 100), then c3 later (pinnedAt = 200)
    await state.localStore.saveConversationPref(const LocalConversationPref(conversationId: 'c2', pinnedAt: 100));
    await state.localStore.saveConversationPref(const LocalConversationPref(conversationId: 'c3', pinnedAt: 200));
    state.conversationPrefs = {
      'c2': const LocalConversationPref(conversationId: 'c2', pinnedAt: 100),
      'c3': const LocalConversationPref(conversationId: 'c3', pinnedAt: 200),
    };

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatListScreen(state: state),
    ));
    await tester.pump();

    // Find the positions of each title in the list
    final alphaY = tester.getTopLeft(find.text('Chat Alpha')).dy;
    final betaY = tester.getTopLeft(find.text('Chat Beta')).dy;
    final gammaY = tester.getTopLeft(find.text('Chat Gamma')).dy;

    // Pinned chats come first: Gamma (pinned later) > Beta (pinned earlier) > Alpha (unpinned)
    expect(gammaY, lessThan(betaY));
    expect(betaY, lessThan(alphaY));

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}

class _UiState extends AppState {
  _UiState()
      : super(
            apiClientFactory: (_) => _UiApi(),
            cryptoService: _MlsStub(),
            localStore: MemoryLocalStore(),
            syncServiceFactory: (_, __) => _QuietSync());
  LocalStore? localStoreOverride;
  @override
  LocalStore get localStore => localStoreOverride ?? super.localStore;
}

class _UiApi extends ApiClient {
  _UiApi() : super(baseUrl: 'https://example.test');
  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}
  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      const [];
}

_UiState _state() => _UiState()
  ..session = const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'alice',
      deviceId: 'dev')
  ..conversations = [
    Conversation(id: 'conv', kind: 'dm', title: 'Team', createdBy: 'alice')
  ]
  ..conversationsLoaded = true;
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
  @override
  Future<void> dispose() async {}
  @override
  Future<MessageEnvelope> encryptPayload(
      String conversationId, AppPayloadType type, Map<String, Object?> body,
      {List<String> attachmentRefs = const [], String? draftText}) async =>
    MessageEnvelope(
        conversationId: conversationId,
        idempotencyKey: 'action',
        ciphertext: const [1],
        cryptoProtocol: 'test');
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
