import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

// C7 in the app (docs/designs/C7-channel-history.md): a channel creation
// sends a create record, the work pass after sync sends what is due and
// proposes stale records again with their layout generation, the setting
// switch proposes a record, and the timeline's system lines come from the
// crypto service. The crypto service is a recording fake.

const _session = Session(
    baseUrl: 'https://example.test',
    token: 'token',
    accountId: 'alice',
    deviceId: 'dev');
final _community = 'comm_${'1' * 32}';
final _open = 'chan_${'2' * 32}';
final _private = 'chan_${'3' * 32}';

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');

  /// Epochs the server reports a history_sync delivered for.
  final delivered = <(String, int)>{};
  final asked = <(String, int)>[];

  /// History rows the server holds per stream (`''`: group-level), newest
  /// first, and every history request as (channel, before, limit).
  final history = <String, List<Map<String, Object?>>>{};
  final historyAsked = <(String, String?, int)>[];
  var formerAsked = 0;

  /// While set, every history request fails as a server error.
  var historyFails = false;

  @override
  Future<List<Map<String, Object?>>> historyBodies(
      String token, String conversationId,
      {String? channelId, String? beforeId, int limit = 50}) async {
    historyAsked.add((channelId ?? '', beforeId, limit));
    if (historyFails) throw ApiException(500, '{"error":"internal"}');
    final rows = history[channelId ?? ''] ?? const <Map<String, Object?>>[];
    final start = beforeId == null
        ? 0
        : rows.indexWhere((row) => row['message_id'] == beforeId) + 1;
    return rows.sublist(start, (start + limit).clamp(0, rows.length));
  }

  @override
  Future<List<Map<String, Object?>>> formerMemberKeys(
      String token, String conversationId) async {
    formerAsked++;
    return <Map<String, Object?>>[
      <String, Object?>{
        'device_id': 'dev_gone',
        'account_id': 'gone',
        'signing_key': base64Encode(List<int>.filled(32, 7)),
        'revoked': false,
      },
      // Malformed: skipped.
      <String, Object?>{'device_id': 'dev_bad', 'signing_key': 'x'},
    ];
  }

  /// What a send of each envelope answers; absent is success.
  final refusals = <String, ApiException>{};
  final sentKeys = <String>[];

  @override
  Future<bool> historySyncDelivered(
      String token, String conversationId, int forEpoch) async {
    asked.add((conversationId, forEpoch));
    return delivered.contains((conversationId, forEpoch));
  }

  @override
  Future<MessageEnvelope> sendEnvelope(
      String token, MessageEnvelope envelope) async {
    sentKeys.add(envelope.idempotencyKey);
    final refusal = refusals[envelope.idempotencyKey];
    if (refusal != null) throw refusal;
    return envelope;
  }

  @override
  Future<ChannelCreation> createChannel(
      String token, String communityId, String name,
      {String kind = 'private'}) async {
    return ChannelCreation(
      channel: Channel(
          id: _open,
          communityId: communityId,
          name: name,
          kind: kind,
          conversationId: 'conv_shared',
          layoutGeneration: 3),
      conversation: Conversation(
          id: 'conv_shared',
          kind: 'community_shared',
          communityId: communityId,
          createdBy: 'alice'),
    );
  }
}

typedef _Proposal = ({
  String conversation,
  String channel,
  bool full,
  bool create,
  int? layoutGeneration,
});

class _C7Crypto extends UnavailableCryptoService
    implements C7HistoryService, C7HistoryConsumer {
  @override
  bool c7SealedBodies = true;
  final proposals = <_Proposal>[];
  final sent = <C7Due>[];
  final settled = <(String, int)>[];
  final asked = <List<String>>[];
  LocalStore? outbox;
  List<C7Due> due = const <C7Due>[];
  DateTime? next;
  Map<String, bool> lines = const <String, bool>{};
  List<String> importDue = const <String>[];
  final imports = <({
    String conversation,
    C7HistoryPage groupLevel,
    Map<String, C7HistoryPage> channels,
    List<C7FormerKey> keys,
    bool first,
  })>[];
  Map<String, String> earlier = const <String, String>{};
  Set<String> former = const <String>{};
  C7ChannelView view =
      const C7ChannelView(full: false, status: 'ok', pending: false);

  MessageEnvelope _envelope(String conversationId) => MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey: 'action-${proposals.length + sent.length}',
      ciphertext: const [1],
      cryptoProtocol: 'test');

  @override
  Future<MessageEnvelope> c7ProposeRecord(
      String conversationId, String channelId,
      {required bool full, bool create = false, int? layoutGeneration}) async {
    proposals.add((
      conversation: conversationId,
      channel: channelId,
      full: full,
      create: create,
      layoutGeneration: layoutGeneration,
    ));
    return _envelope(conversationId);
  }

  @override
  Future<C7ChannelView?> c7ChannelView(
          String conversationId, String channelId) async =>
      view;

  @override
  Future<List<C7Due>> c7DueWork(Iterable<String> conversationIds) async {
    asked.add(conversationIds.toList()..sort());
    final out = due;
    due = const <C7Due>[];
    return out;
  }

  @override
  Future<MessageEnvelope?> c7Send(C7Due due) async {
    sent.add(due);
    final envelope = _envelope(due.conversationId);
    await outbox?.enqueueEnvelope(envelope);
    return envelope;
  }

  @override
  Future<void> c7SyncDelivered(String conversationId, int forEpoch) async {
    settled.add((conversationId, forEpoch));
  }

  @override
  Future<void> c7CommitExpiredSkip(SyncEventCommit tombstone) async {}

  @override
  Future<Map<String, bool>> c7HistoryLines(String conversationId) async =>
      conversationId == 'conv_shared' ? lines : const <String, bool>{};

  @override
  Future<DateTime?> c7NextDueAt(Iterable<String> conversationIds) async => next;

  @override
  Future<List<String>> c7ImportDue(Iterable<String> conversationIds) async {
    final out = importDue;
    importDue = const <String>[];
    return out;
  }

  @override
  Future<int> c7ImportHistory(String conversationId,
      {required C7HistoryPage groupLevel,
      required Map<String, C7HistoryPage> channels,
      List<C7FormerKey> formerKeys = const <C7FormerKey>[],
      bool first = true}) async {
    imports.add((
      conversation: conversationId,
      groupLevel: groupLevel,
      channels: channels,
      keys: formerKeys,
      first: first,
    ));
    return 0;
  }

  @override
  Future<String?> c7EarlierCursor(
          String conversationId, String channelId) async =>
      conversationId == 'conv_shared' ? earlier[channelId] : null;

  @override
  Future<Set<String>> c7FormerMemberPosts(String conversationId) async =>
      conversationId == 'conv_shared' ? former : const <String>{};
}

/// [count] history rows of [stream], newest first.
List<Map<String, Object?>> _rows(String stream, int count) =>
    <Map<String, Object?>>[
      for (var i = count; i > 0; i--)
        <String, Object?>{
          'message_id': 'm_${stream}_$i',
          'sender_device_id': 'dev_x',
          'action_id': 'a_$i',
          if (stream.isNotEmpty) 'channel_id': stream,
          'created_at': '2026-11-01T00:00:00Z',
          'epoch': 3,
          'body': base64Encode(<int>[1, 2, 3]),
        },
    ];

(AppState, _C7Crypto) _app() => _appWith(_Api());

(AppState, _C7Crypto) _appWith(_Api api) {
  final crypto = _C7Crypto();
  final store = MemoryLocalStore();
  final state = AppState(
      apiClientFactory: (_) => api,
      syncServiceFactory: (_, __) => _QuietSync(),
      localStore: store,
      cryptoService: crypto);
  addTearDown(state.dispose);
  state.session = _session;
  state.api = api;
  state.communities = [
    Community(
        id: _community, name: 'Club', sharedConversationId: 'conv_shared'),
  ];
  state.conversations = [
    Conversation(
        id: 'conv_shared',
        kind: 'community_shared',
        communityId: _community,
        createdBy: 'alice',
        currentRole: 'owner'),
    Conversation(
        id: 'conv_private',
        kind: 'community_channel',
        communityId: _community,
        createdBy: 'alice'),
    Conversation(id: 'conv_dm', kind: 'direct', createdBy: 'alice'),
  ];
  state.channelsByCommunity = {
    _community: [
      Channel(
          id: _open,
          communityId: _community,
          name: '',
          kind: 'open',
          conversationId: 'conv_shared',
          layoutGeneration: 3),
      Channel(
          id: _private,
          communityId: _community,
          name: '',
          kind: 'private',
          conversationId: 'conv_private',
          layoutGeneration: 3),
    ],
  };
  state.governanceOverrideForTesting =
      (_) => GovernanceState(rev: 1, owner: 'alice', ownerRev: 0);
  return (state, crypto);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a new channel sends its create record with the chosen setting',
      () async {
    final (state, crypto) = _app();
    state.channelsByCommunity = {_community: const <Channel>[]};
    final channel =
        await state.createChannel(_community, 'general', fullHistory: true);
    expect(channel?.id, _open);
    for (var i = 0; i < 100 && crypto.proposals.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(crypto.proposals, [
      (
        conversation: 'conv_shared',
        channel: _open,
        full: true,
        create: true,
        layoutGeneration: 3,
      ),
    ]);
  });

  test('with C7 off nothing is proposed', () async {
    final (state, crypto) = _app();
    crypto.c7SealedBodies = false;
    expect(state.channelHistoryAvailable, isFalse);
    await state.createChannel(_community, 'general');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(crypto.proposals, isEmpty);
    expect(
        await state.setChannelHistory(
            state.channelsByCommunity[_community]!.first,
            full: true),
        isFalse);
  });

  test(
      'the work pass sends what is due in community groups only, proposes '
      'stale records again with their layout generation, and arms a timer',
      () async {
    final (state, crypto) = _app();
    crypto.due = <C7Due>[
      const C7DueSync('conv_shared', 4),
      const C7DueRequest('conv_private', 2),
      C7DueRepropose('conv_shared', _open, full: true),
      C7DueRepropose('conv_private', _private, full: false),
    ];
    crypto.next = DateTime.now().toUtc().add(const Duration(seconds: 30));
    crypto.lines = {'dev_bob:act': true};
    await state.c7WorkPassForTesting();
    expect(crypto.asked.single, ['conv_private', 'conv_shared']);
    expect(crypto.sent.map((d) => d.conversationId),
        ['conv_shared', 'conv_private']);
    expect(crypto.proposals, [
      (
        conversation: 'conv_shared',
        channel: _open,
        full: true,
        create: false,
        layoutGeneration: 3,
      ),
      (
        conversation: 'conv_private',
        channel: _private,
        full: false,
        create: false,
        layoutGeneration: null,
      ),
    ]);
    expect(state.channelHistoryLine('conv_shared', 'dev_bob:act'), isTrue);
    expect(state.channelHistoryLine('conv_shared', 'dev_bob:other'), isNull);
    expect(state.c7TimerArmed, isTrue);
  });

  test(
      'a member asks the server first: a history_sync the newcomers already '
      'have settles its duty unsent; one they lack is sent', () async {
    final api = _Api()..delivered.add(('conv_shared', 4));
    final (state, crypto) = _appWith(api);
    crypto.due = <C7Due>[
      const C7DueSync('conv_shared', 4),
      const C7DueSync('conv_private', 2),
      const C7DueRequest('conv_private', 3),
    ];
    await state.c7WorkPassForTesting();
    expect(api.asked, [('conv_shared', 4), ('conv_private', 2)]);
    expect(crypto.settled, [('conv_shared', 4)]);
    expect(crypto.sent.map((d) => (d.conversationId, d.runtimeType)),
        [('conv_private', C7DueSync), ('conv_private', C7DueRequest)]);
  });

  test(
      "a history_sync the server refuses as delivered leaves the outbox; "
      'any other refusal stays as a failed send', () async {
    final api = _Api();
    final (state, crypto) = _appWith(api);
    crypto.outbox = state.localStore;
    crypto.due = <C7Due>[
      const C7DueSync('conv_shared', 4),
      const C7DueSync('conv_private', 2),
    ];
    api.refusals['action-1'] =
        ApiException(409, '{"error":"history_sync_delivered"}');
    api.refusals['action-2'] =
        ApiException(409, '{"error":"idempotency_conflict"}');
    await state.c7WorkPassForTesting();
    for (var i = 0; i < 100 && api.sentKeys.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.sentKeys, containsAll(<String>['action-1', 'action-2']));
    final left = await state.localStore.pendingEnvelopeRecords();
    expect(left.map((r) => r.envelope.idempotencyKey), ['action-2']);
    expect(left.single.terminal, isTrue);
  });

  test(
      'a newcomer fetches the same first page of every channel and the '
      'group-level stream whatever the modes, and the former-member keys '
      'once (decision 10, owner answer Q1)', () async {
    final api = _Api();
    final (state, crypto) = _appWith(api);
    final second = 'chan_${'4' * 32}';
    state.channelsByCommunity = {
      _community: [
        ...state.channelsByCommunity[_community]!,
        Channel(
            id: second,
            communityId: _community,
            name: '',
            kind: 'open',
            conversationId: 'conv_shared',
            layoutGeneration: 3),
      ],
    };
    // Whatever each channel's mode: the app never asks before fetching.
    api.history[_open] = _rows(_open, 1500);
    api.history[second] = _rows(second, 1500);
    api.history[''] = _rows('', 30);
    crypto.importDue = <String>['conv_shared'];
    await state.c7WorkPassForTesting();
    List<(String?, int)> asked(String stream) => <(String?, int)>[
          for (final (channel, before, limit) in api.historyAsked)
            if (channel == stream) (before?.replaceFirst(stream, 'S'), limit),
        ];
    // The first page stops at 1,000 bodies, 100 per request, in both.
    expect(asked(_open), hasLength(10));
    expect(asked(_open), asked(second));
    expect(asked(_open).first, (null, 100));
    expect(asked(''), [(null, 100)]);
    expect(api.formerAsked, 1);
    final run = crypto.imports.single;
    expect(run.first, isTrue);
    expect(run.groupLevel.complete, isTrue);
    expect(run.groupLevel.rows, hasLength(30));
    expect(run.channels.keys.toSet(), {_open, second});
    for (final page in run.channels.values) {
      expect(page.rows, hasLength(1000));
      expect(page.complete, isFalse);
    }
    expect(run.keys.map((k) => k.deviceId), ['dev_gone']);
  });

  test(
      'a failing import waits before it is fetched again: 1 min, doubling, '
      'and a success clears the wait', () async {
    final api = _Api()..historyFails = true;
    final (state, crypto) = _appWith(api);
    var now = DateTime.utc(2026, 11, 12, 10);
    state.c7Clock = () => now;
    Future<int> pass() async {
      final before = api.historyAsked.length;
      crypto.importDue = <String>['conv_shared'];
      await state.c7WorkPassForTesting();
      return api.historyAsked.length - before;
    }

    expect(await pass(), 1);
    // The next foreground passes fetch nothing until the wait is over.
    expect(await pass(), 0);
    now = now.add(const Duration(seconds: 59));
    expect(await pass(), 0);
    now = now.add(const Duration(seconds: 1));
    expect(await pass(), 1);
    // The second failure waits two minutes.
    now = now.add(const Duration(minutes: 1));
    expect(await pass(), 0);
    now = now.add(const Duration(minutes: 1));
    api.historyFails = false;
    expect(await pass(), greaterThan(0));
    expect(crypto.imports, hasLength(1));
    // A success clears the wait: the next due import goes at once.
    expect(await pass(), greaterThan(0));
  });

  test(
      '"Load earlier posts" pages a full channel on demand, and imported '
      'posts from former members are marked', () async {
    final api = _Api();
    final (state, crypto) = _appWith(api);
    api.history[_open] = _rows(_open, 1200);
    crypto.earlier = <String, String>{_open: 'm_${_open}_201'};
    crypto.former = <String>{'dev_gone:a_1'};
    state.selectChannel('conv_shared', _open);
    expect(state.channelHistoryEarlier('conv_shared'), isFalse);
    await state.c7WorkPassForTesting();
    expect(state.channelHistoryEarlier('conv_shared'), isTrue);
    expect(state.channelHistoryFormerMember('conv_shared', 'dev_gone:a_1'),
        isTrue);
    expect(
        state.channelHistoryFormerMember('conv_shared', 'dev_x:a_1'), isFalse);
    await state.loadEarlierChannelPosts('conv_shared');
    expect(api.historyAsked.first, (_open, 'm_${_open}_201', 100));
    final run = crypto.imports.single;
    expect(run.first, isFalse);
    expect(run.channels.keys, [_open]);
    expect(run.channels[_open]!.rows, hasLength(200));
    expect(run.channels[_open]!.complete, isTrue);
    expect(api.formerAsked, 0);
    // Not offered where the crypto service has no cursor (another mode).
    state.selectChannel('conv_shared', null);
    expect(state.channelHistoryEarlier('conv_shared'), isFalse);
  });

  test('the switch proposes a switch, or a create for a channel with none',
      () async {
    final (state, crypto) = _app();
    final open = state.channelsByCommunity[_community]!.first;
    expect(await state.setChannelHistory(open, full: true), isTrue);
    crypto.view = const C7ChannelView(
        full: false, status: 'ok', pending: false, recorded: false);
    expect(await state.setChannelHistory(open, full: false), isTrue);
    expect(crypto.proposals.map((p) => (p.full, p.create, p.layoutGeneration)),
        [(true, false, 3), (false, true, 3)]);
  });
}
