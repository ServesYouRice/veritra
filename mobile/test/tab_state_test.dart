// T49C-4: in the wide layout, switching destinations used to drop the chat
// list's scroll offset, an unsent draft and the reply target. Drafts and
// reply targets are now held per conversation in memory only, and the list
// offset in the route's page storage.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/composer_drafts.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'perf/perf_harness.dart';

const String _otherConversationId = 'conv_0001';

/// A signed-in wide window with [conversations] conversations; the long
/// group holds three messages with known text.
Future<(AppState, MemoryLocalStore)> _wide(
  WidgetTester tester, {
  int conversations = 20,
}) async {
  final store = MemoryLocalStore();
  await store.saveSession(benchSession);
  final envelopes = benchEnvelopes(longConversationId, 0, 3);
  await seedHistory(
    store,
    <MessageEffect>[
      for (final (index, envelope) in envelopes.reversed.indexed)
        InsertMessageEffect(
          key: benchKey(envelope),
          serverMessageId: envelope.id,
          conversationId: envelope.conversationId,
          senderAccountId: envelope.senderAccountId,
          senderDeviceId: envelope.senderDeviceId,
          kind: LocalMessageKind.text,
          body: 'Message number $index',
          createdAt: envelope.createdAt.millisecondsSinceEpoch,
          state: envelope.senderDeviceId == benchSession.deviceId
              ? LocalMessageState.sent
              : LocalMessageState.received,
        ),
    ],
    envelopes: envelopes,
  );
  final api = BenchApi(conversationList: benchConversations(conversations))
    ..pages[longConversationId] = envelopes;
  final state = benchState(api: api, store: store);
  await state.tryRestoreSession();
  setBenchWindow(tester, benchWide);
  await tester.pumpWidget(benchApp(state));
  await tester.pumpAndSettle();
  return (state, store);
}

Finder get _chatList => find
    .descendant(
      of: find.byType(ChatListScreen),
      matching: find.byType(Scrollable),
    )
    .first;

ScrollPosition _listPosition(WidgetTester tester) =>
    tester.state<ScrollableState>(_chatList).position;

Finder get _composer => find.byType(TextField).last;

String _composerText(WidgetTester tester) =>
    tester.widget<TextField>(_composer).controller!.text;

/// Settings, then back to Chats, through the navigation rail.
Future<void> _visitSettings(WidgetTester tester) async {
  for (final icon in <IconData>[
    Icons.settings_outlined,
    Icons.chat_bubble_outline,
  ]) {
    await tester.tap(find.descendant(
      of: find.byType(NavigationRail),
      matching: find.byIcon(icon),
    ));
    await tester.pumpAndSettle();
  }
}

Future<void> _open(WidgetTester tester, String title) async {
  await tester.tap(find.descendant(
    of: find.byType(ChatListScreen),
    matching: find.text(title),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the chat list keeps its scroll offset across destinations',
      (tester) async {
    final (state, _) = await _wide(tester, conversations: 400);
    _listPosition(tester).jumpTo(2400);
    await tester.pump();
    await _visitSettings(tester);
    expect(_listPosition(tester).pixels, 2400);
    state.dispose();
  });

  testWidgets('an unsent draft is kept across destinations, on device only',
      (tester) async {
    final (state, store) = await _wide(tester);
    await _open(tester, 'Long group');
    await tester.enterText(_composer, 'half a thought');
    await tester.pump();
    await _visitSettings(tester);

    expect(state.selectedConversationId, longConversationId);
    expect(_composerText(tester), 'half a thought');
    // Nothing was sent or stored: the draft lives only in memory.
    expect(state.pendingFor(longConversationId), isEmpty);
    expect(await store.pendingEnvelopeRecords(), isEmpty);
    final stored = await store.loadMessages(longConversationId);
    expect(
        stored.where((message) => message.body == 'half a thought'), isEmpty);
    expect('${state.composerDrafts}', isNot(contains('half a thought')));
    state.dispose();
  });

  testWidgets('the reply target is kept across destinations', (tester) async {
    final (state, _) = await _wide(tester);
    await _open(tester, 'Long group');
    // Long-pressing the text selects it; the bubble around it opens the
    // message actions.
    final bubble = find
        .ancestor(
          of: find.ancestor(
            of: find.text('Message number 1'),
            matching: find.byType(SelectableText),
          ),
          matching: find.byType(DecoratedBox),
        )
        .first;
    final rect = tester.getRect(bubble);
    // In the left padding, clear of the rounded corners and the text.
    await tester.longPressAt(Offset(rect.left + 7, rect.center.dy));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    const replying = 'Replying to: Message number 1';
    expect(find.text(replying), findsOneWidget);

    await _visitSettings(tester);
    expect(find.text(replying), findsOneWidget);

    // Cancelling is kept too.
    await tester.tap(find.byTooltip('Cancel reply'));
    await tester.pumpAndSettle();
    await _visitSettings(tester);
    expect(find.text(replying), findsNothing);
    state.dispose();
  });

  testWidgets('each conversation keeps its own draft', (tester) async {
    final (state, _) = await _wide(tester);
    await _open(tester, 'Long group');
    await tester.enterText(_composer, 'for the group');
    await tester.pump();

    await _open(tester, '@peer1');
    expect(state.selectedConversationId, _otherConversationId);
    expect(_composerText(tester), isEmpty);
    await tester.enterText(_composer, 'for peer one');
    await tester.pump();

    await _open(tester, 'Long group');
    expect(_composerText(tester), 'for the group');
    await _open(tester, '@peer1');
    expect(_composerText(tester), 'for peer one');
    state.dispose();
  });

  test('drafts are forgotten when the session ends', () async {
    final store = MemoryLocalStore();
    await store.saveSession(benchSession);
    final state = benchState(api: BenchApi(), store: store);
    await state.tryRestoreSession();
    state.composerDrafts
      ..setText(longConversationId, 'not for the next account')
      ..setReplyTarget(longConversationId, null);
    await state.logout();
    expect(state.connected, isFalse);
    expect(state.composerDrafts.isEmpty, isTrue);
    state.dispose();
  });

  group('ComposerDrafts', () {
    LocalMessage message(String key) => LocalMessage(
          key: key,
          conversationId: longConversationId,
          senderAccountId: 'acct_peer',
          senderDeviceId: 'dev_peer',
          kind: LocalMessageKind.text,
          body: 'quoted',
          createdAt: 0,
          state: LocalMessageState.received,
        );

    test('a sent draft is cleared, a newer edit or reply is kept', () {
      final drafts = ComposerDrafts();
      final first = message('dev_peer:1');
      drafts
        ..setText(longConversationId, ' hello ')
        ..setReplyTarget(longConversationId, first);
      drafts.clearSent(longConversationId, text: 'hello', replyTo: first);
      expect(drafts.isEmpty, isTrue);

      final second = message('dev_peer:2');
      drafts
        ..setText(longConversationId, 'hello again')
        ..setReplyTarget(longConversationId, second);
      drafts.clearSent(longConversationId, text: 'hello', replyTo: first);
      expect(drafts.textFor(longConversationId), 'hello again');
      expect(drafts.replyTargetFor(longConversationId), same(second));
    });

    test('never prints draft text, and clear forgets everything', () {
      final drafts = ComposerDrafts()
        ..setText(longConversationId, 'secret plans')
        ..setReplyTarget(_otherConversationId, message('dev_peer:1'));
      expect('$drafts', isNot(contains('secret')));
      drafts.clear();
      expect(drafts.isEmpty, isTrue);
      expect(drafts.textFor(longConversationId), isEmpty);
    });
  });
}
