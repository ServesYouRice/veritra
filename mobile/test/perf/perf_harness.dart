// Shared fixtures for the T49C mobile state and render measurements.
//
// These run on the host inside `flutter test`: JIT code with debug asserts,
// a fake clock and no GPU rasterisation. Absolute times are only comparable
// with other runs on the same host; before/after ratios and the counts are
// what the evidence uses. Runs on representative low-end devices wait for
// G24 (no device or emulator is available to the tests).
//
// Message text is synthetic and the crypto is a stand-in that commits the
// same kind of transition the native MLS service commits; nothing here
// exercises or weakens the real crypto path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/main.dart' show VeritraApp;
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/about.dart' show veritraProductName;
import 'package:private_messenger/ui/app_shell.dart';
import 'package:private_messenger/ui/appearance.dart';
import 'package:private_messenger/ui/theme.dart';

const Session benchSession = Session(
  baseUrl: 'https://chat.example.org',
  token: 'bench-token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'bench-secret',
  username: 'me',
);

/// The long group conversation the chat scenarios open.
const String longConversationId = 'conv_long';

/// Phone window used for every render scenario, at a pixel ratio of 1.
const Size benchPhone = Size(360, 800);

/// A window wide enough for the master-detail workspace layout.
const Size benchWide = Size(1280, 800);

final DateTime _epoch = DateTime.utc(2025, 1, 1);

String benchMemberAccount(int index) =>
    index == 0 ? benchSession.accountId! : 'acct_m${_pad(index)}';

String benchMemberDevice(int index) =>
    index == 0 ? benchSession.deviceId! : 'dev_m${_pad(index)}';

String _pad(int value) => value.toString().padLeft(4, '0');

/// [count] conversations, newest activity first: the long group, then DMs.
List<Conversation> benchConversations(int count) => <Conversation>[
      Conversation(
        id: longConversationId,
        kind: 'group',
        title: 'Long group',
        lastMessageAt: _epoch.add(const Duration(days: 400)),
        unreadCount: 3,
      ),
      for (var i = 1; i < count; i++)
        Conversation(
          id: 'conv_${_pad(i)}',
          kind: i % 9 == 0 ? 'group' : 'dm',
          title: i % 9 == 0 ? 'Group $i' : null,
          peerAccountId: i % 9 == 0 ? null : 'acct_peer${_pad(i)}',
          peerUsername: i % 9 == 0 ? null : 'peer$i',
          lastMessageAt: _epoch.add(Duration(days: 300, minutes: -i * 13)),
          unreadCount: i % 5 == 0 ? 2 : 0,
          retentionSeconds: i % 11 == 0 ? 86400 : null,
        ),
    ];

/// The long group's roster: this account first, then [count] - 1 others.
List<ConversationMember> benchMembers(int count) => <ConversationMember>[
      for (var i = 0; i < count; i++)
        ConversationMember(
          accountId: benchMemberAccount(i),
          role: i == 0 ? 'owner' : 'member',
          username: i == 0 ? 'me' : 'member$i',
        ),
    ];

/// The [index]-th message of [conversationId], seven minutes apart, from
/// one of [senders] roster members (member 0 is this account).
ReceivedMessageEnvelope benchEnvelope(
  String conversationId,
  int index, {
  int senders = 8,
}) {
  final sender = index % senders;
  return ReceivedMessageEnvelope(
    id: '$conversationId-m$index',
    conversationId: conversationId,
    senderAccountId: benchMemberAccount(sender),
    senderDeviceId: benchMemberDevice(sender),
    idempotencyKey: 'k$index',
    ciphertext: List<int>.filled(96 + (index % 7) * 64, 7),
    cryptoProtocol: 'mls10-openmls-v1',
    createdAt: _epoch.add(Duration(minutes: index * 7)),
  );
}

/// Messages [from] (inclusive) to [to] (exclusive), newest first, the order
/// the server pages them in.
List<ReceivedMessageEnvelope> benchEnvelopes(
  String conversationId,
  int from,
  int to, {
  int senders = 8,
}) =>
    <ReceivedMessageEnvelope>[
      for (var i = to - 1; i >= from; i--)
        benchEnvelope(conversationId, i, senders: senders),
    ];

String benchKey(ReceivedMessageEnvelope envelope) =>
    '${envelope.senderDeviceId}:${envelope.idempotencyKey}';

String _benchText(int index) {
  final words = 4 + (index * 7) % 23;
  return List<String>.generate(words, (word) => 'word${(index + word) % 97}')
      .join(' ');
}

/// Decrypted history for [envelopes]: text for each, a reply on every tenth
/// and a reaction on every sixth.
List<MessageEffect> benchHistoryEffects(
    List<ReceivedMessageEnvelope> envelopes) {
  final oldestFirst = envelopes.reversed.toList(growable: false);
  final effects = <MessageEffect>[];
  for (var i = 0; i < oldestFirst.length; i++) {
    final envelope = oldestFirst[i];
    effects.add(InsertMessageEffect(
      key: benchKey(envelope),
      serverMessageId: envelope.id,
      conversationId: envelope.conversationId,
      senderAccountId: envelope.senderAccountId,
      senderDeviceId: envelope.senderDeviceId,
      kind: LocalMessageKind.text,
      body: _benchText(i),
      replyTo: i > 0 && i % 10 == 0 ? benchKey(oldestFirst[i - 1]) : null,
      createdAt: envelope.createdAt.millisecondsSinceEpoch,
      state: envelope.senderDeviceId == benchSession.deviceId
          ? LocalMessageState.sent
          : LocalMessageState.received,
    ));
    if (i % 6 == 0) {
      effects.add(ReactionEffect(
        targetKey: benchKey(envelope),
        reactorAccountId: benchMemberAccount(1 + i % 3),
        reaction: '👍',
        at: envelope.createdAt.millisecondsSinceEpoch + 1000,
      ));
    }
  }
  return effects;
}

/// Commits [effects] (and [envelopes]) in one MLS transition, starting the
/// protected state first when the store has none.
Future<void> seedHistory(
  LocalStore store,
  List<MessageEffect> effects, {
  List<ReceivedMessageEnvelope> envelopes = const <ReceivedMessageEnvelope>[],
  String conversationId = longConversationId,
}) async {
  var state = await store.loadCryptoState();
  if (state == null) {
    state = StoredCryptoState(
      counter: 1,
      stateKey: List<int>.filled(32, 1),
      sealedState: <int>[1],
    );
    await store.saveCryptoState(state, 0);
  }
  final cursor = await store.loadSyncCursor();
  await store.commitMlsTransition(MlsStateTransition(
    messageId: 'seed:${cursor + 1}',
    conversationId: conversationId,
    expectedCounter: state.counter,
    expectedCursor: cursor,
    state: StoredCryptoState(
      counter: state.counter + 1,
      stateKey: state.stateKey,
      sealedState: state.sealedState,
    ),
    cursor: cursor + 1,
    upsertedEnvelopes: envelopes,
    messageEffects: effects,
  ));
}

/// An inline `message.envelope.created` event, as the server sends it.
SyncEvent benchEnvelopeEvent(int id, ReceivedMessageEnvelope envelope) =>
    SyncEvent(
      id: id,
      type: 'message.envelope.created',
      conversationId: envelope.conversationId,
      payload: <String, Object?>{
        'message_id': envelope.id,
        'conversation_id': envelope.conversationId,
        'envelope': envelope.toJson(),
      },
      createdAt: envelope.createdAt,
    );

/// Stands in for the native MLS service: each application message commits
/// its envelope, decrypted text, protected state and cursor in one
/// transition, exactly as `NativeCryptoService` does, without any crypto.
class BenchMlsCrypto implements MlsConversationCryptoService {
  BenchMlsCrypto(this.store);

  final LocalStore store;
  int applied = 0;

  /// Wall time spent applying messages, store commits included.
  int applyMicros = 0;

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      null;

  @override
  Future<List<int>?> processApplicationMessage(
    ReceivedMessageEnvelope envelope,
    int syncEventId,
  ) async {
    final watch = Stopwatch()..start();
    try {
      return await _apply(envelope, syncEventId);
    } finally {
      applyMicros += watch.elapsedMicroseconds;
    }
  }

  Future<List<int>?> _apply(
    ReceivedMessageEnvelope envelope,
    int syncEventId,
  ) async {
    final marker = 'application:$syncEventId:${envelope.id}';
    if (await store.hasProcessedMlsMessage(marker)) return null;
    final previous = (await store.loadCryptoState())!;
    final cursor = await store.loadSyncCursor();
    final text = 'Incoming ${envelope.id}';
    await store.commitMlsTransition(MlsStateTransition(
      messageId: marker,
      conversationId: envelope.conversationId,
      expectedCounter: previous.counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
        counter: previous.counter + 1,
        stateKey: previous.stateKey,
        sealedState: previous.sealedState,
      ),
      cursor: syncEventId,
      upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
      messageEffects: <MessageEffect>[
        InsertMessageEffect(
          key: benchKey(envelope),
          serverMessageId: envelope.id,
          conversationId: envelope.conversationId,
          senderAccountId: envelope.senderAccountId,
          senderDeviceId: envelope.senderDeviceId,
          kind: LocalMessageKind.text,
          body: text,
          createdAt: envelope.createdAt.millisecondsSinceEpoch,
          state: LocalMessageState.received,
        ),
      ],
    ));
    applied++;
    return utf8.encode(text);
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Answers every request the measured flows make, without a network.
class BenchApi extends ApiClient {
  BenchApi({List<Conversation>? conversationList})
      : conversationList = conversationList ?? benchConversations(20),
        super(baseUrl: benchSession.baseUrl);

  List<Conversation> conversationList;
  List<ConversationMember> members = benchMembers(8);
  final Map<String, List<ReceivedMessageEnvelope>> pages =
      <String, List<ReceivedMessageEnvelope>>{};
  List<SyncEvent> events = <SyncEvent>[];

  /// When true, list requests fail as if the server were unreachable.
  bool offline = false;
  int syncCalls = 0;

  void _maybeOffline() {
    if (offline) throw const SocketException('bench: offline');
  }

  @override
  Future<List<Conversation>> conversations(String token) async {
    _maybeOffline();
    return conversationList;
  }

  @override
  Future<List<Device>> devices(String token) async {
    _maybeOffline();
    return const <Device>[];
  }

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    syncCalls++;
    _maybeOffline();
    return events
        .where((event) => event.id > after)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    _maybeOffline();
    return MessagePage(
      messages: before == null
          ? pages[conversationId] ?? const <ReceivedMessageEnvelope>[]
          : const <ReceivedMessageEnvelope>[],
    );
  }

  @override
  Future<List<ConversationMember>> conversationMembers(
    String token,
    String conversationId,
  ) async {
    _maybeOffline();
    return conversationId == longConversationId
        ? members
        : const <ConversationMember>[];
  }

  @override
  Future<bool> conversationMuted(String token, String conversationId) async =>
      false;

  @override
  Future<void> markRead(
    String token,
    String conversationId,
    String messageId,
  ) async {}

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<List<MlsPendingChange>> mlsPendingChanges(String token) async =>
      const <MlsPendingChange>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<BlockedAccount>> listBlocks(String token) async =>
      const <BlockedAccount>[];

  @override
  Future<List<Invite>> listInvites(String token) async => const <Invite>[];

  @override
  Future<List<Community>> listCommunities(String token) async =>
      const <Community>[];

  @override
  Future<ReceivedMessageEnvelope> message(
          String token, String messageId) async =>
      throw ApiException(404, '{"error":"not_found"}');
}

/// A realtime socket that only speaks when a test asks it to.
class BenchSync implements SyncService {
  final StreamController<Map<String, Object?>> _controller =
      StreamController<Map<String, Object?>>.broadcast();

  /// Tells the app that new events are waiting, as the server's socket does.
  void poke() => _controller.add(const <String, Object?>{'type': 'sync'});

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

/// Builds an [AppState] wired to the bench fakes.
AppState benchState({
  required BenchApi api,
  required LocalStore store,
  CryptoService? crypto,
  BenchSync? sync,
}) {
  final realtime = sync ?? BenchSync();
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: crypto ?? BenchMlsCrypto(store),
    localStore: store,
    syncServiceFactory: (_, __) => realtime,
  );
}

/// The real app root from `main.dart`, with an in-memory appearance store.
Widget benchApp(AppState state) => VeritraApp(
      state: state,
      appearance: AppearanceController(MemoryAppearanceStore(ThemeMode.light)),
    );

/// A what-if root for the evidence file, never used by the app: the same
/// MaterialApp as `main.dart`, but only the appearance controller rebuilds
/// it, and the shell listens to [state] itself. It measures what the
/// recommendation in `testing/evidence/benchmarks-t49c.md` would save.
Widget scopedRootApp(AppState state) {
  final appearance =
      AppearanceController(MemoryAppearanceStore(ThemeMode.light));
  return AnimatedBuilder(
    animation: appearance,
    builder: (context, _) => AppearanceScope(
      controller: appearance,
      child: MaterialApp(
        title: veritraProductName,
        theme: veritraLightTheme(),
        darkTheme: veritraDarkTheme(),
        themeMode: appearance.mode,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AnimatedBuilder(
          animation: state,
          builder: (context, _) => AppShell(state: state),
        ),
      ),
    ),
  );
}

void setBenchWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Counts element rebuilds by widget type while it is running, using the
/// framework's debug rebuild hook (test builds run with asserts on).
class RebuildCounter {
  final Map<String, int> counts = <String, int>{};
  int total = 0;

  void start() {
    counts.clear();
    total = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      total++;
      final type = element.widget.runtimeType.toString();
      counts[type] = (counts[type] ?? 0) + 1;
    };
  }

  void stop() => debugOnRebuildDirtyWidget = null;

  int of(String type) => counts[type] ?? 0;
}

/// Wall-clock durations of individual frames, in microseconds.
class FrameStats {
  FrameStats(List<int> micros) : _sorted = List<int>.of(micros)..sort();

  final List<int> _sorted;

  int get count => _sorted.length;
  double _at(double fraction) => _sorted.isEmpty
      ? 0
      : _sorted[math.min(
              _sorted.length - 1, (_sorted.length * fraction).floor())] /
          1000;
  double get medianMs => _at(0.5);
  double get p90Ms => _at(0.9);
  double get maxMs => _sorted.isEmpty ? 0 : _sorted.last / 1000;
  double get totalMs =>
      _sorted.fold<int>(0, (sum, value) => sum + value) / 1000;

  Map<String, Object> get fields => <String, Object>{
        'frames': count,
        'median_ms': medianMs,
        'p90_ms': p90Ms,
        'max_ms': maxMs,
      };

  @override
  String toString() => 'frames=$count median=${medianMs.toStringAsFixed(2)}ms '
      'p90=${p90Ms.toStringAsFixed(2)}ms max=${maxMs.toStringAsFixed(2)}ms';
}

/// Pumps one frame and returns how long it took, in microseconds.
Future<int> timedPump(WidgetTester tester, [Duration? duration]) async {
  final watch = Stopwatch()..start();
  await tester.pump(duration);
  return watch.elapsedMicroseconds;
}

/// Times [body] [runs] times after one warm-up and returns the median, in
/// microseconds.
double medianMicros(int runs, void Function() body) {
  body();
  final samples = <int>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    body();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2].toDouble();
}

/// One line per measurement, easy to grep out of the test log:
/// `T49C | <scenario> | key=value ...`.
void benchReport(String scenario, Map<String, Object> values) {
  final fields = values.entries.map((entry) {
    final value = entry.value;
    return '${entry.key}=${value is double ? value.toStringAsFixed(2) : value}';
  }).join(' ');
  debugPrint('T49C | $scenario | $fields');
}
