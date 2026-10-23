// T49C render measurements: scrolling, rebuilds per new message, theme
// recreation, tab switching and per-bubble lookups. See perf_harness.dart
// for what host numbers mean, and testing/evidence/benchmarks-t49c.md for
// the recorded results.
//
// The assertions are deterministic counts and identities, never wall-clock
// thresholds, so they stay stable on a shared CI runner. The timings are
// printed as `T49C | ...` lines.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/theme.dart';

import 'perf_harness.dart';

class _Bench {
  _Bench(this.state, this.api, this.sync);

  final AppState state;
  final BenchApi api;
  final BenchSync sync;
}

/// A signed-in demo-build state: [conversations] conversations, and
/// [messages] decrypted messages in the long group from [members] senders.
/// The server's newest page holds the latest 50 envelopes; the rest of the
/// timeline comes from local history, as on a device that has been in the
/// group for a long time (D23).
Future<_Bench> _connected({
  int conversations = 1000,
  int messages = 2000,
  int members = 8,
  bool longLast = false,
}) async {
  final store = MemoryLocalStore();
  await store.saveSession(benchSession);
  final envelopes =
      benchEnvelopes(longConversationId, 0, messages, senders: members);
  await seedHistory(store, benchHistoryEffects(envelopes));
  final list = benchConversations(conversations);
  final api = BenchApi(
    conversationList:
        longLast ? <Conversation>[...list.skip(1), list.first] : list,
  )
    ..members = benchMembers(members)
    ..pages[longConversationId] = envelopes.take(50).toList(growable: false);
  final sync = BenchSync();
  final state = benchState(api: api, store: store, sync: sync);
  await state.tryRestoreSession();
  return _Bench(state, api, sync);
}

Future<void> _start(
  WidgetTester tester,
  _Bench bench, {
  Size size = benchPhone,
}) async {
  setBenchWindow(tester, size);
  await tester.pumpWidget(benchApp(bench.state));
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester, Finder scrollable) =>
    tester.state<ScrollableState>(scrollable).position;

/// Jumps [scrollable] forward [steps] times by [step] pixels and times the
/// frame after each jump.
Future<FrameStats> _scrollFrames(
  WidgetTester tester,
  Finder scrollable, {
  int steps = 60,
  double step = 120,
}) async {
  final frames = <int>[];
  for (var i = 1; i <= steps; i++) {
    final position = _position(tester, scrollable);
    position
        .jumpTo((position.pixels + step).clamp(0.0, position.maxScrollExtent));
    frames.add(await timedPump(tester));
  }
  return FrameStats(frames);
}

/// Sends [count] bare AppState notifications, one frame each.
Future<FrameStats> _notificationFrames(
  WidgetTester tester,
  AppState state, {
  int count = 20,
}) async {
  final frames = <int>[];
  for (var i = 0; i < count; i++) {
    state.notifyListeners();
    frames.add(await timedPump(tester));
  }
  return FrameStats(frames);
}

Finder get _chatListScrollable => find
    .descendant(
      of: find.byType(ChatListScreen),
      matching: find.byType(Scrollable),
    )
    .first;

Finder get _chatScrollable => find
    .descendant(
      of: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_MessageList'),
      matching: find.byType(Scrollable),
    )
    .first;

/// Taps a destination in whichever navigation the layout shows.
Future<void> _tapNav(WidgetTester tester, IconData icon) async {
  final nav = find.byWidgetPredicate((widget) =>
      widget is NavigationRail ||
      widget.runtimeType.toString() == '_FloatingNav');
  await tester.tap(find.descendant(of: nav, matching: find.byIcon(icon)));
}

/// Opens the long group as its chat-list row does, without needing the row
/// on screen.
Future<void> _openLongConversation(WidgetTester tester, _Bench bench) async {
  bench.state.selectAndPrepare(longConversationId);
  unawaited(Navigator.of(tester.element(find.byType(ChatListScreen)))
      .push(MaterialPageRoute<void>(
    builder: (_) => ChatScreen(
      state: bench.state,
      conversationId: longConversationId,
    ),
  )));
  await tester.pumpAndSettle();
  expect(find.byType(ChatScreen), findsOneWidget);
}

/// Delivers one new message through the realtime poke and sync catch-up,
/// pumping frames until the app is idle again. Returns the frame times.
Future<FrameStats> _deliverOne(
    WidgetTester tester, _Bench bench, int index) async {
  final envelope = benchEnvelope(longConversationId, index);
  bench.api.events = <SyncEvent>[
    ...bench.api.events,
    benchEnvelopeEvent(1000 + index, envelope),
  ];
  bench.sync.poke();
  final frames = <int>[];
  for (var i = 0; i < 20; i++) {
    frames.add(await timedPump(tester));
    final arrived =
        bench.state.timelineFor(longConversationId).first.id == envelope.id;
    if (arrived && !tester.binding.hasScheduledFrame) break;
  }
  expect(bench.state.timelineFor(longConversationId).first.id, envelope.id);
  return FrameStats(frames);
}

/// Rebuilds by widget type. Since T49C-1 each screen rebuilds under its own
/// listener, so the open chat shows as `MessageList` and `Composer` (its
/// content) rather than `ChatScreen` (the route's page, rebuilt only by the
/// Navigator), and the list as `rows`.
Map<String, Object> _rebuilds(RebuildCounter counter, {int frames = 1}) =>
    <String, Object>{
      'elements': counter.total ~/ frames,
      'MaterialApp': counter.of('MaterialApp') ~/ frames,
      'AppShell': counter.of('AppShell') ~/ frames,
      'ChatListScreen': counter.of('ChatListScreen') ~/ frames,
      'rows': counter.of('_ConversationTile') ~/ frames,
      'ChatScreen': counter.of('ChatScreen') ~/ frames,
      'MessageList': counter.of('_MessageList') ~/ frames,
      'Composer': counter.of('_Composer') ~/ frames,
      'bubbles': counter.of('_MessageBubble') ~/ frames,
    };

void main() {
  testWidgets('long conversation list scrolls', (tester) async {
    final bench = await _connected(conversations: 1000, messages: 50);
    await _start(tester, bench);
    final counter = RebuildCounter()..start();
    final stats = await _scrollFrames(tester, _chatListScrollable);
    counter.stop();
    benchReport('chat list scroll, 1000 conversations', <String, Object>{
      ...stats.fields,
      'rows_built': counter.of('_ConversationTile'),
      'elements_rebuilt': counter.total,
    });
    expect(_position(tester, _chatListScrollable).pixels, greaterThan(0));
    bench.state.dispose();
  });

  testWidgets('long conversation scrolls back through history', (tester) async {
    final bench = await _connected(conversations: 200, messages: 2000);
    await _start(tester, bench);
    await _openLongConversation(tester, bench);
    expect(bench.state.timelineFor(longConversationId), hasLength(2000));
    final counter = RebuildCounter()..start();
    final stats = await _scrollFrames(tester, _chatScrollable);
    counter.stop();
    benchReport('chat scroll, 2000 messages', <String, Object>{
      ...stats.fields,
      'bubbles_built': counter.of('_MessageBubble'),
      'elements_rebuilt': counter.total,
    });
    expect(counter.of('_MessageBubble'), greaterThan(0));
    bench.state.dispose();
  });

  testWidgets('one new message and one bare notification: what rebuilds',
      (tester) async {
    final bench = await _connected(conversations: 200, messages: 2000);
    await _start(tester, bench);

    final listCounter = RebuildCounter()..start();
    final listFrames = await _deliverOne(tester, bench, 2000);
    listCounter.stop();
    benchReport('one message, chat list open', <String, Object>{
      'frames': listFrames.count,
      'total_ms': listFrames.totalMs,
      ..._rebuilds(listCounter),
    });

    final listCounterBare = RebuildCounter()..start();
    final listBare = await _notificationFrames(tester, bench.state);
    listCounterBare.stop();
    benchReport('notification, chat list open', <String, Object>{
      ...listBare.fields,
      ..._rebuilds(listCounterBare, frames: listBare.count),
    });

    await _openLongConversation(tester, bench);
    final chatCounter = RebuildCounter()..start();
    final chatFrames = await _deliverOne(tester, bench, 2001);
    chatCounter.stop();
    benchReport('one message, chat open', <String, Object>{
      'frames': chatFrames.count,
      'total_ms': chatFrames.totalMs,
      ..._rebuilds(chatCounter),
    });

    final chatCounterBare = RebuildCounter()..start();
    final chatBare = await _notificationFrames(tester, bench.state);
    chatCounterBare.stop();
    benchReport('notification, chat open', <String, Object>{
      ...chatBare.fields,
      ..._rebuilds(chatCounterBare, frames: chatBare.count),
    });
    // Since T49C-1 the root listens only to the appearance, and every screen
    // rebuilds only for what it shows: a notification that changes nothing
    // rebuilds nothing, and a new message rebuilds the open chat, not the
    // app root or the list hidden under it.
    expect(chatCounterBare.counts, isEmpty);
    expect(listCounterBare.counts, isEmpty);
    expect(chatCounter.of('MaterialApp'), 0);
    expect(chatCounter.of('_ConversationTile'), 0);
    expect(chatCounter.of('_MessageList'), greaterThan(0));
    bench.state.dispose();
  });

  testWidgets('theme objects across a state notification', (tester) async {
    final bench = await _connected(conversations: 20, messages: 20);
    await _start(tester, bench);
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    final light = app().theme;
    final dark = app().darkTheme;
    bench.state.notifyListeners();
    await tester.pump();
    final buildMicros = medianMicros(50, () {
      veritraLightTheme();
      veritraDarkTheme();
    });
    final first = veritraLightTheme();
    final second = veritraLightTheme();
    var equal = false;
    final equalityMicros = medianMicros(50, () => equal = first == second);
    benchReport('theme per root rebuild', <String, Object>{
      'light_reused': identical(light, app().theme),
      'dark_reused': identical(dark, app().darkTheme),
      'build_pair_us': buildMicros,
      'equality_us': equalityMicros,
    });
    // Equal themes never animate or notify Theme dependents, so the cost of
    // recreating them was the build and the comparison above. The themes
    // are now built once (T49C fix).
    expect(equal, isTrue);
    expect(identical(light, app().theme), isTrue);
    expect(identical(dark, app().darkTheme), isTrue);
    bench.state.dispose();
  });

  testWidgets('tab switching keeps the selection; records what is lost',
      (tester) async {
    final bench = await _connected(conversations: 1000, messages: 200);
    await _start(tester, bench);
    _position(tester, _chatListScrollable).jumpTo(3000);
    await tester.pump();
    final switches = <int>[];
    for (var i = 0; i < 5; i++) {
      for (final icon in <IconData>[
        Icons.settings_outlined,
        Icons.groups_outlined,
        Icons.chat_bubble_outline,
      ]) {
        await _tapNav(tester, icon);
        switches.add(await timedPump(tester));
        await tester.pumpAndSettle();
      }
    }
    final compact = FrameStats(switches);
    final listOffset = _position(tester, _chatListScrollable).pixels;

    // Workspace layout: the open conversation and its draft.
    setBenchWindow(tester, benchWide);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long group').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'unsent draft');
    await _tapNav(tester, Icons.settings_outlined);
    await tester.pumpAndSettle();
    await _tapNav(tester, Icons.chat_bubble_outline);
    await tester.pumpAndSettle();
    final selection = bench.state.selectedConversationId;
    final draftKept = find.text('unsent draft').evaluate().isNotEmpty;

    benchReport('tab switch, first frame', <String, Object>{
      ...compact.fields,
      'chat_list_offset_after_return': listOffset,
      'wide_selection_kept': selection == longConversationId,
      'wide_draft_kept': draftKept,
    });
    expect(selection, longConversationId);
    bench.state.dispose();
  });

  for (final size in <({int conversations, int members})>[
    (conversations: 20, members: 8),
    (conversations: 2000, members: 500),
  ]) {
    testWidgets(
        'per-bubble lookups: ${size.conversations} conversations, '
        '${size.members} members', (tester) async {
      // The long group is last, so a per-bubble scan of the conversation
      // list walks all of it, and every sender is a different member.
      final bench = await _connected(
        conversations: size.conversations,
        messages: 2000,
        members: size.members,
        longLast: true,
      );
      await _start(tester, bench);
      await _openLongConversation(tester, bench);
      final counter = RebuildCounter()..start();
      final stats =
          await _scrollFrames(tester, _chatScrollable, steps: 40, step: 400);
      counter.stop();
      final bubbles = counter.of('_MessageBubble');
      final timelineMicros =
          medianMicros(20, () => bench.state.timelineFor(longConversationId));
      benchReport(
          'chat scroll, ${size.conversations} conversations, '
          '${size.members} members',
          <String, Object>{
            ...stats.fields,
            'bubbles_built': bubbles,
            'bubbles_per_frame': bubbles / stats.count,
            'timelineFor_us': timelineMicros,
          });
      expect(bubbles, greaterThan(0));
      bench.state.dispose();
    });
  }
}
