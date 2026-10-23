// T49C state measurements on the real encrypted database: cold start to the
// first frame from a populated local database, a sync burst of incoming
// messages, and the snapshot rewrite that opening a conversation triggers.
// See perf_harness.dart for what host numbers mean, and
// testing/evidence/benchmarks-t49c.md for the recorded results.
//
// Assertions are counts and outcomes, never wall-clock thresholds.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'perf_harness.dart';

/// The populated device: [conversations] cached conversations with
/// [envelopesPerConversation] cached envelopes each, and [history]
/// decrypted messages in the long group.
const int _conversations = 500;
const int _envelopesPerConversation = 20;
const int _history = 2000;

/// The burst: [_burst] new messages in the long group, paged by the app's
/// own page size of 200.
const int _burst = 500;

/// Counts the history reads the UI path makes.
class _CountingStore extends SecureLocalStore {
  _CountingStore({
    required super.storage,
    required super.directoryProvider,
    required super.databaseFactory,
  });

  int messageLoads = 0;
  int reactionLoads = 0;
  int projectionWrites = 0;

  @override
  Future<List<LocalMessage>> loadMessages(String conversationId) {
    messageLoads++;
    return super.loadMessages(conversationId);
  }

  @override
  Future<List<LocalMessageReaction>> loadReactions(String conversationId) {
    reactionLoads++;
    return super.loadReactions(conversationId);
  }

  @override
  Future<void> saveProjection(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
  ) {
    projectionWrites++;
    return super.saveProjection(conversations, messagesByConversation);
  }
}

/// Waits for a completed sync catch-up (after [after], when given), so no
/// database work is still running when a test closes the database.
Future<void> _untilSynced(AppState state, {DateTime? after}) async {
  final watch = Stopwatch()..start();
  while (state.lastSyncedAt == null ||
      (after != null && !state.lastSyncedAt!.isAfter(after))) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (watch.elapsed > const Duration(minutes: 3)) fail('sync stalled');
  }
}

/// Disposes [state] and lets its in-flight database work (outbox and sync
/// bookkeeping it started without awaiting) finish before the test closes
/// the database under it.
Future<void> _disposeQuietly(AppState state) async {
  state.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-t49c-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  /// A store on the shared temp directory with a fresh database handle, as
  /// after an app restart.
  _CountingStore openStore() => _CountingStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );

  Future<void> closeAll() async {
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
  }

  /// Writes the populated device and closes it again.
  Future<List<Conversation>> populate() async {
    final store = openStore();
    await store.saveSession(benchSession);
    final conversations = benchConversations(_conversations);
    final cached = <String, List<ReceivedMessageEnvelope>>{
      for (final conversation in conversations)
        conversation.id:
            benchEnvelopes(conversation.id, 0, _envelopesPerConversation),
    };
    final history = benchEnvelopes(longConversationId, 0, _history);
    cached[longConversationId] = history.take(200).toList(growable: false);
    await seedHistory(store, benchHistoryEffects(history));
    await store.saveProjection(conversations, cached);
    await closeAll();
    return conversations;
  }

  testWidgets('cold start to the first chat-list frame from the local database',
      (tester) async {
    final conversations = await tester.runAsync(populate);
    setBenchWindow(tester, benchPhone);
    // Two starts on the same database: the first also pays for compiling
    // the UI code (JIT), which a release build does not; the second is the
    // closer stand-in for an AOT start with a cold database handle.
    for (final pass in <String>['first', 'second']) {
      final store = openStore();
      // The server is unreachable, so the first frame can only come from the
      // encrypted cache; that is the path a phone on a bad network takes.
      final api = BenchApi(conversationList: conversations)..offline = true;
      final state = benchState(api: api, store: store);
      await tester.pumpWidget(benchApp(state));
      final restoreWatch = Stopwatch()..start();
      await tester.runAsync(state.tryRestoreSession);
      final restoreMicros = restoreWatch.elapsedMicroseconds;
      final frameMicros = await timedPump(tester);
      final totalMicros = restoreWatch.elapsedMicroseconds;
      expect(state.lifecycle, SessionLifecycle.ready);
      expect(state.conversations, hasLength(_conversations));
      expect(find.byType(ChatListScreen), findsOneWidget);
      expect(find.text('Long group'), findsOneWidget);
      benchReport(
          'cold start ($pass), $_conversations conversations cached',
          <String, Object>{
            'restore_ms': restoreMicros / 1000,
            'first_frame_ms': frameMicros / 1000,
            'total_ms': totalMicros / 1000,
            'cached_envelopes': state.messagesByConversation.values
                .fold<int>(0, (sum, list) => sum + list.length),
          });
      await tester.runAsync(() async {
        // Let the offline catch-up finish before the database closes.
        while (state.connectionStatus != ConnectionStatus.offline) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await _disposeQuietly(state);
        await closeAll();
      });
    }
  });

  test('a burst of incoming messages through sync catch-up', () async {
    final conversations = await populate();
    final store = openStore();
    final api = BenchApi(conversationList: conversations);
    final state = benchState(api: api, store: store);
    await state.tryRestoreSession();
    await _untilSynced(state);
    // The conversation is open, so its history is in memory as on screen.
    await state.refreshHistory(longConversationId);
    final reloadWatch = Stopwatch()..start();
    await state.refreshHistory(longConversationId);
    final reloadMicros = reloadWatch.elapsedMicroseconds;
    final crypto = state.cryptoService as BenchMlsCrypto;
    var notifications = 0;
    state.addListener(() => notifications++);
    store
      ..messageLoads = 0
      ..reactionLoads = 0
      ..projectionWrites = 0;
    final startCursor = await store.loadSyncCursor();
    api.events = <SyncEvent>[
      for (var i = 0; i < _burst; i++)
        benchEnvelopeEvent(startCursor + 1 + i,
            benchEnvelope(longConversationId, _history + i)),
    ];
    final synced = state.lastSyncedAt;
    final watch = Stopwatch()..start();
    state.handleAppLifecycleState(AppLifecycleState.resumed);
    while (state.historyFor(longConversationId).messages.length <
            _history + _burst ||
        await store.loadSyncCursor() < startCursor + _burst) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (watch.elapsed > const Duration(minutes: 3)) fail('burst stalled');
    }
    final micros = watch.elapsedMicroseconds;
    await _untilSynced(state, after: synced);
    expect(crypto.applied, _burst);
    expect(state.historyFor(longConversationId).messages,
        hasLength(_history + _burst));
    expect(state.timelineFor(longConversationId).first.id,
        '$longConversationId-m${_history + _burst - 1}');
    benchReport('sync burst, $_burst messages into $_history', <String, Object>{
      'total_ms': micros / 1000,
      'per_message_ms': micros / 1000 / _burst,
      'one_history_reload_ms': reloadMicros / 1000,
      'history_loads': store.messageLoads,
      'reaction_loads': store.reactionLoads,
      'notifications': notifications,
      'snapshot_writes': store.projectionWrites,
    });
    await _disposeQuietly(state);
  });

  test('opening a conversation rewrites the cached snapshot', () async {
    final conversations = await populate();
    final store = openStore();
    final api = BenchApi(conversationList: conversations)
      ..pages[longConversationId] =
          benchEnvelopes(longConversationId, _history - 50, _history);
    final state = benchState(api: api, store: store);
    final restoreWatch = Stopwatch()..start();
    await state.tryRestoreSession();
    final restoreMicros = restoreWatch.elapsedMicroseconds;
    final restoreWrites = store.projectionWrites;
    await _untilSynced(state);
    store.projectionWrites = 0;
    final watch = Stopwatch()..start();
    await state.loadMessages(longConversationId);
    final micros = watch.elapsedMicroseconds;
    final single = Stopwatch()..start();
    await store.saveProjection(
        state.conversations, state.messagesByConversation);
    final writeMicros = single.elapsedMicroseconds;
    benchReport('online restore and open conversation', <String, Object>{
      'online_restore_ms': restoreMicros / 1000,
      'restore_snapshot_writes': restoreWrites,
      'loadMessages_ms': micros / 1000,
      'snapshot_writes': store.projectionWrites,
      'one_snapshot_write_ms': writeMicros / 1000,
      'cached_envelopes': state.messagesByConversation.values
          .fold<int>(0, (sum, list) => sum + list.length),
    });
    expect(state.historyFor(longConversationId).messages, hasLength(_history));
    await _disposeQuietly(state);
  });
}
