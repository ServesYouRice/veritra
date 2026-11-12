import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/api_errors.dart';
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
}

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
