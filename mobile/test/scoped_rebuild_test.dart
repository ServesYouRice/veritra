// T49C-1 regression: AppState is one ChangeNotifier, and the app root used
// to rebuild everything on every notification (1,233 elements with a chat
// open). Each screen now listens for the parts it shows. These tests fail if
// a state change that does not touch the open conversation rebuilds it, and
// also if a change that does touch it no longer reaches the screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'perf/perf_harness.dart';

const String _otherConversationId = 'conv_0001';

class _App {
  _App(this.state, this.api, this.sync);

  final AppState state;
  final BenchApi api;
  final BenchSync sync;
  // Above the cursor that seeding the history left behind.
  int _nextEventId = 1000;

  /// Delivers one message through the realtime poke and sync catch-up, as
  /// the server would, and waits until it is shown.
  Future<ReceivedMessageEnvelope> deliver(
    WidgetTester tester,
    String conversationId,
    int index,
  ) async {
    final envelope = benchEnvelope(conversationId, index);
    api.events = <SyncEvent>[
      ...api.events,
      benchEnvelopeEvent(_nextEventId++, envelope),
    ];
    sync.poke();
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      if (state.timelineFor(conversationId).first.id == envelope.id &&
          !tester.binding.hasScheduledFrame) {
        break;
      }
    }
    expect(state.timelineFor(conversationId).first.id, envelope.id);
    return envelope;
  }
}

Future<_App> _signedIn(WidgetTester tester, Size size) async {
  final store = MemoryLocalStore();
  await store.saveSession(benchSession);
  final envelopes = benchEnvelopes(longConversationId, 0, 40);
  await seedHistory(store, benchHistoryEffects(envelopes));
  final api = BenchApi(conversationList: benchConversations(20))
    ..pages[longConversationId] = envelopes;
  final sync = BenchSync();
  final state = benchState(api: api, store: store, sync: sync);
  await state.tryRestoreSession();
  setBenchWindow(tester, size);
  await tester.pumpWidget(benchApp(state));
  await tester.pumpAndSettle();
  // Opens the long group the way a person does: its row in the chat list.
  await tester.tap(find.text('Long group'));
  await tester.pumpAndSettle();
  expect(_count('_MessageList'), findsOneWidget);
  return _App(state, api, sync);
}

Finder _count(String type) =>
    find.byWidgetPredicate((widget) => widget.runtimeType.toString() == type);

/// Runs [change], pumps until idle, and returns what rebuilt meanwhile and
/// how many notifications the state sent.
Future<(RebuildCounter, int)> _measure(
  WidgetTester tester,
  AppState state,
  Future<void> Function() change,
) async {
  var notifications = 0;
  void count() => notifications++;
  state.addListener(count);
  final counter = RebuildCounter()..start();
  try {
    await change();
    await tester.pumpAndSettle();
  } finally {
    counter.stop();
    state.removeListener(count);
  }
  return (counter, notifications);
}

void _expectChatUntouched(RebuildCounter counter, String change) {
  for (final type in <String>[
    'MaterialApp',
    'ChatScreen',
    '_MessageList',
    '_MessageBubble',
    '_Composer',
  ]) {
    expect(counter.of(type), 0, reason: '$change rebuilt $type');
  }
}

void main() {
  for (final layout in <(String, Size)>[
    ('phone (pushed chat)', benchPhone),
    ('wide (detail pane)', benchWide),
  ]) {
    group('${layout.$1}:', () {
      testWidgets('unrelated state changes do not rebuild the open chat',
          (tester) async {
        final app = await _signedIn(tester, layout.$2);
        final state = app.state;

        final (bare, bareSent) = await _measure(tester, state, () async {
          state.notifyListeners();
        });
        expect(bareSent, 1);
        _expectChatUntouched(bare, 'a bare notification');

        final (devices, devicesSent) =
            await _measure(tester, state, state.refreshDevices);
        expect(devicesSent, greaterThan(0));
        _expectChatUntouched(devices, 'refreshing the device list');

        final (connection, connectionSent) =
            await _measure(tester, state, () async {
          state.connectionStatus = ConnectionStatus.offline;
          state.lastSyncedAt = DateTime.utc(2025, 6, 1);
          state.notifyListeners();
        });
        expect(connectionSent, 1);
        _expectChatUntouched(connection, 'going offline');

        final before = state.timelineFor(longConversationId).first;
        final (other, otherSent) = await _measure(tester, state, () async {
          await app.deliver(tester, _otherConversationId, 0);
        });
        expect(otherSent, greaterThan(0));
        expect(state.timelineFor(_otherConversationId), hasLength(1));
        expect(state.timelineFor(longConversationId).first, same(before));
        _expectChatUntouched(other, 'a message in another conversation');

        state.dispose();
      });

      testWidgets('a message in the open conversation still reaches it',
          (tester) async {
        final app = await _signedIn(tester, layout.$2);
        final (counter, _) = await _measure(tester, app.state, () async {
          await app.deliver(tester, longConversationId, 40);
        });
        expect(counter.of('_MessageList'), greaterThan(0));
        expect(counter.of('MaterialApp'), 0);
        expect(find.text('Incoming $longConversationId-m40'), findsOneWidget);
        app.state.dispose();
      });
    });
  }

  testWidgets('the shell still follows the session lifecycle on its own',
      (tester) async {
    // The root no longer rebuilds on state changes, so the shell has to
    // notice a change of lifecycle itself.
    final app = await _signedIn(tester, benchWide);
    final state = app.state;
    state.recoveryMessage = 'Recovery needed.';
    state.lifecycle = SessionLifecycle.recoveryRequired;
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Recovery needed.'), findsOneWidget);
    expect(_count('_MessageList'), findsNothing);

    state.recoveryMessage = 'Still needed.';
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Still needed.'), findsOneWidget);

    state.lifecycle = SessionLifecycle.ready;
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Long group'), findsWidgets);
    state.dispose();
  });
}
