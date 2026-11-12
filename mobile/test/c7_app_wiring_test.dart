import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/crypto/c7_move.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show
        InsertMessageEffect,
        LocalMessageKind,
        LocalMessageState,
        MessageEffect;
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

typedef _Answer = ({Map<String, Object?> move, Conversation? conversation});

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

  /// While set, the history and moved routes answer with this status.
  int? historyRefusal;

  @override
  Future<List<Map<String, Object?>>> historyBodies(
      String token, String conversationId,
      {String? channelId, String? beforeId, int limit = 50}) async {
    historyAsked.add((channelId ?? '', beforeId, limit));
    if (historyFails) throw ApiException(500, '{"error":"internal"}');
    final refusal = historyRefusal;
    if (refusal != null) throw ApiException(refusal, '{"error":"refused"}');
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

  final moved = <String, List<Map<String, Object?>>>{};
  final movedAsked = <(String, String, bool)>[];
  final moves = <(String, String)>[];

  /// Awaited, then thrown, by the next move (once each): the server moved
  /// the channel, and the answer is late or lost.
  Completer<void>? moveGate;
  Object? moveThrows;

  /// Changes to the next answers to a move: fields over the move, and
  /// the conversation in place of the usual one.
  _Answer? answer;

  @override
  Future<({Map<String, Object?> move, Conversation conversation})> moveChannel(
      String token, String channelId, String accessMode) async {
    final usual = await _moveAnswer(channelId, accessMode);
    await moveGate?.future;
    moveGate = null;
    final thrown = moveThrows;
    moveThrows = null;
    if (thrown != null) throw thrown;
    final change = answer;
    if (change == null) return usual;
    return (
      move: <String, Object?>{...usual.move, ...change.move},
      conversation: change.conversation ?? usual.conversation,
    );
  }

  Future<({Map<String, Object?> move, Conversation conversation})> _moveAnswer(
      String channelId, String accessMode) async {
    moves.add((channelId, accessMode));
    if (accessMode == 'private') {
      return (
        move: <String, Object?>{
          'channel_id': channelId,
          'from_conversation_id': 'conv_shared',
          'to_conversation_id': 'conv_new',
          'layout_generation': 4,
        },
        conversation: Conversation(
            id: 'conv_new',
            kind: 'community_channel',
            communityId: _community,
            createdBy: 'alice'),
      );
    }
    return (
      move: <String, Object?>{
        'channel_id': channelId,
        'from_conversation_id': 'conv_private',
        'to_conversation_id': 'conv_shared',
        'layout_generation': 4,
      },
      conversation: Conversation(
          id: 'conv_shared',
          kind: 'community_shared',
          communityId: _community,
          createdBy: 'alice'),
    );
  }

  /// The shared conversation's roster, and every add as (conversation,
  /// account).
  final roster = <String>['alice', 'bob', 'carol', 'dave'];
  final added = <(String, String)>[];

  /// While set, adding this account fails as a server error.
  String? addFails;

  @override
  Future<List<ConversationMember>> conversationMembers(
          String token, String conversationId) async =>
      <ConversationMember>[
        for (final account in roster)
          ConversationMember(
              accountId: account,
              role: account == 'alice' ? 'owner' : 'member'),
      ];

  @override
  Future<void> addConversationMember(
      String token, String conversationId, String accountId,
      {String role = 'member'}) async {
    if (accountId == addFails) throw ApiException(500, '{"error":"internal"}');
    added.add((conversationId, accountId));
  }

  @override
  Future<List<Map<String, Object?>>> movedHistoryBodies(
      String token, String channelId, String fromConversationId,
      {required bool group, String? beforeId, int limit = 50}) async {
    movedAsked.add((channelId, fromConversationId, group));
    final refusal = historyRefusal;
    if (refusal != null) throw ApiException(refusal, '{"error":"refused"}');
    return moved[group ? '' : channelId] ?? const <Map<String, Object?>>[];
  }

  @override
  Future<List<Map<String, Object?>>> movedMemberKeys(
          String token, String channelId, String fromConversationId) async =>
      const <Map<String, Object?>>[];

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

  final notes = <({String channel, String from, String to, bool own})>[];
  final moveProposals = <(C7DueMove, int?)>[];
  List<C7Move> movesDue = const <C7Move>[];
  final movedImports = <({
    C7Move move,
    C7HistoryPage channel,
    C7HistoryPage groupLevel,
    List<C7FormerKey> keys,
  })>[];

  @override
  Future<void> c7NoteMove({
    required String channelId,
    required String fromConversationId,
    required String toConversationId,
    required bool own,
  }) async =>
      notes.add((
        channel: channelId,
        from: fromConversationId,
        to: toConversationId,
        own: own,
      ));

  @override
  Future<MessageEnvelope?> c7ProposeMove(C7DueMove due,
      {int? layoutGeneration}) async {
    moveProposals.add((due, layoutGeneration));
    return _envelope(due.conversationId);
  }

  @override
  Future<List<C7Move>> c7MovedImportsDue() async => movesDue;

  @override
  Future<int> c7ImportMoved(C7Move move,
      {required C7HistoryPage channel,
      required C7HistoryPage groupLevel,
      List<C7FormerKey> keys = const <C7FormerKey>[]}) async {
    movedImports.add(
        (move: move, channel: channel, groupLevel: groupLevel, keys: keys));
    movesDue = const <C7Move>[];
    return channel.rows.length;
  }
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

  test(
      'a move event rehomes the rows even before this device is in the new '
      'conversation, and notes the move', () async {
    final (state, crypto) = _app();
    await state.localStore.importC7History(<MessageEffect>[
      InsertMessageEffect(
          key: 'dev_bob:a1',
          conversationId: 'conv_shared',
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          createdAt: 1,
          state: LocalMessageState.received,
          body: 'earlier',
          channelId: _open),
    ]);
    // Malformed: nothing happens.
    await state.channelMovedForTesting(<String, Object?>{'channel_id': _open});
    await state.channelMovedForTesting(<String, Object?>{
      'channel_id': _open,
      'from_conversation_id': 'conv_shared',
      'to_conversation_id': 'conv_new',
      'access_mode': 'private',
    });
    expect(state.conversations.any((c) => c.id == 'conv_new'), isFalse);
    expect(await state.localStore.loadMessages('conv_shared'), isEmpty);
    final rows = await state.localStore.loadMessages('conv_new');
    expect(rows.single.body, 'earlier');
    expect(rows.single.channelId, isNull);
    expect(crypto.notes,
        [(channel: _open, from: 'conv_shared', to: 'conv_new', own: false)]);
  });

  Future<void> seedRows(AppState state) async {
    InsertMessageEffect row(
            String key, String conversation, String? channel, String body) =>
        InsertMessageEffect(
            key: key,
            conversationId: conversation,
            senderAccountId: 'bob',
            senderDeviceId: 'dev_bob',
            kind: LocalMessageKind.text,
            createdAt: 1,
            state: LocalMessageState.received,
            body: body,
            channelId: channel);
    await state.localStore.importC7History(<MessageEffect>[
      row('dev_bob:s1', 'conv_shared', _open, 'open post'),
      row('dev_bob:p1', 'conv_private', null, 'private post'),
      row('dev_bob:d1', 'conv_dm', null, 'direct post'),
      row('dev_bob:g1', 'conv_ghost', null, 'unlisted post'),
    ]);
  }

  Future<List<(String, String?, String?)>> rowsOf(AppState state) async => [
        for (final id in [
          'conv_shared',
          'conv_private',
          'conv_dm',
          'conv_new',
          'conv_ghost'
        ])
          for (final row in await state.localStore.loadMessages(id))
            (id, row.channelId, row.body),
      ];

  for (final c7 in [true, false]) {
    test(
        'a move event that does not fit the channel as this device knows it '
        'moves no rows and notes nothing (review M-A, C7 ${c7 ? 'on' : 'off'})',
        () async {
      final (state, crypto) = _app();
      crypto.c7SealedBodies = c7;
      // A group the server says is of the community is still no channel's.
      state.conversations = [
        ...state.conversations,
        Conversation(
            id: 'conv_group',
            kind: 'group',
            communityId: _community,
            createdBy: 'alice'),
      ];
      await seedRows(state);
      final before = await rowsOf(state);
      Map<String, Object?> event(
              String channel, String from, String to, String access) =>
          <String, Object?>{
            'channel_id': channel,
            'from_conversation_id': from,
            'to_conversation_id': to,
            'access_mode': access,
            'moved_by': 'mallory',
          };
      for (final forged in [
        // Into a direct conversation.
        event(_open, 'conv_shared', 'conv_dm', 'private'),
        event(_open, 'conv_shared', 'conv_group', 'private'),
        // Into another channel's private conversation.
        event(_open, 'conv_shared', 'conv_private', 'private'),
        // Another channel's private conversation into the shared one.
        event(_open, 'conv_private', 'conv_shared', 'open'),
        event(_open, 'conv_dm', 'conv_shared', 'open'),
        // Not from where the channel is.
        event(_private, 'conv_shared', 'conv_new', 'private'),
        // An open channel cannot be made open, a private one private.
        event(_private, 'conv_private', 'conv_new', 'private'),
        // A private channel opens only into the community's shared one.
        event(_private, 'conv_private', 'conv_dm', 'open'),
        event(_private, 'conv_private', 'conv_new', 'open'),
        // A channel this device does not know.
        event('chan_unknown', 'conv_shared', 'conv_new', 'private'),
        // An access mode no move has.
        event(_private, 'conv_private', 'conv_shared', 'everyone'),
      ]) {
        await state.channelMovedForTesting(forged);
        expect(await rowsOf(state), before, reason: '$forged');
      }
      expect(crypto.notes, isEmpty);
      expect(
          state.channelsByCommunity[_community]!
              .map((c) => (c.id, c.kind, c.conversationId)),
          [
            (_open, 'open', 'conv_shared'),
            (_private, 'private', 'conv_private')
          ]);
    });
  }

  test(
      'a channel moved twice in one run follows both moves, and a move '
      'already in the channel list is followed too (review M-A)', () async {
    final (state, crypto) = _app();
    await seedRows(state);
    await state.channelMovedForTesting(<String, Object?>{
      'channel_id': _open,
      'from_conversation_id': 'conv_shared',
      'to_conversation_id': 'conv_new',
      'access_mode': 'private',
    });
    expect(
        state.channelsByCommunity[_community]!
            .where((c) => c.id == _open)
            .map((c) => (c.kind, c.conversationId)),
        [('private', 'conv_new')]);
    await state.channelMovedForTesting(<String, Object?>{
      'channel_id': _open,
      'from_conversation_id': 'conv_new',
      'to_conversation_id': 'conv_shared',
      'access_mode': 'announcement',
    });
    expect(
        state.channelsByCommunity[_community]!
            .where((c) => c.id == _open)
            .map((c) => (c.kind, c.conversationId)),
        [('announcement', 'conv_shared')]);
    expect(
        (await state.localStore.loadMessages('conv_shared'))
            .map((row) => (row.channelId, row.body)),
        [(_open, 'open post')]);
    expect(await state.localStore.loadMessages('conv_new'), isEmpty);
    // The channel list was read again before the event (sync start runs
    // both at once): the private channel already opens into the shared
    // conversation, and its rows still follow.
    state.channelsByCommunity = {
      _community: [
        for (final c in state.channelsByCommunity[_community]!)
          if (c.id == _private)
            Channel(
                id: _private,
                communityId: _community,
                name: '',
                kind: 'open',
                conversationId: 'conv_shared',
                layoutGeneration: 4)
          else
            c,
      ],
    };
    await state.channelMovedForTesting(<String, Object?>{
      'channel_id': _private,
      'from_conversation_id': 'conv_private',
      'to_conversation_id': 'conv_shared',
      'access_mode': 'open',
    });
    expect(await state.localStore.loadMessages('conv_private'), isEmpty);
    // There, a conversation this device does not list gives up no rows:
    // the channel list names only where the channel is now. The move is
    // still noted, for the import its record allows.
    await state.channelMovedForTesting(<String, Object?>{
      'channel_id': _open,
      'from_conversation_id': 'conv_ghost',
      'to_conversation_id': 'conv_shared',
      'access_mode': 'open',
    });
    expect((await state.localStore.loadMessages('conv_ghost')).single.body,
        'unlisted post');
    expect(crypto.notes.map((n) => (n.channel, n.from, n.to)), [
      (_open, 'conv_shared', 'conv_new'),
      (_open, 'conv_new', 'conv_shared'),
      (_private, 'conv_private', 'conv_shared'),
      (_open, 'conv_ghost', 'conv_shared'),
    ]);
  });

  for (final (name, answer) in <(String, _Answer)>[
    (
      'another channel',
      (move: {'channel_id': 'chan_other'}, conversation: null)
    ),
    (
      'from elsewhere',
      (move: {'from_conversation_id': 'conv_dm'}, conversation: null)
    ),
    (
      'a different conversation than its move',
      (move: {'to_conversation_id': 'conv_other'}, conversation: null)
    ),
    (
      'into a direct conversation',
      (
        move: {'to_conversation_id': 'conv_direct'},
        conversation: Conversation(
            id: 'conv_direct',
            kind: 'direct',
            communityId: _community,
            createdBy: 'alice')
      )
    ),
    (
      "into another channel's conversation",
      (
        move: {'to_conversation_id': 'conv_private'},
        conversation: Conversation(
            id: 'conv_private',
            kind: 'community_channel',
            communityId: _community,
            createdBy: 'alice')
      )
    ),
    (
      'that names another channel',
      (
        move: <String, Object?>{},
        conversation: Conversation(
            id: 'conv_new',
            kind: 'community_channel',
            communityId: _community,
            channelId: 'chan_other',
            createdBy: 'alice')
      )
    ),
    (
      'into another community',
      (
        move: <String, Object?>{},
        conversation: Conversation(
            id: 'conv_new',
            kind: 'community_channel',
            communityId: 'comm_other',
            createdBy: 'alice')
      )
    ),
    (
      'to an access it did not ask for',
      (move: {'to_access': 'open'}, conversation: null)
    ),
  ]) {
    test(
        'an answer to making a channel private $name is not followed (review M-A)',
        () async {
      final api = _Api()..answer = answer;
      final (state, crypto) = _appWith(api);
      await seedRows(state);
      final before = await rowsOf(state);
      final channel = state.channelsByCommunity[_community]!
          .where((c) => c.id == _open)
          .single;
      expect(await state.convertChannel(channel, toPrivate: true), isFalse);
      expect(await rowsOf(state), before);
      expect(crypto.notes, isEmpty);
      expect(
          state.channelsByCommunity[_community]!
              .where((c) => c.id == _open)
              .single
              .conversationId,
          'conv_shared');
    });
  }

  test(
      'making a private channel open keeps the posting mode the server '
      'restored, and refuses an answer that is not the shared conversation '
      '(review L-8, M-A)', () async {
    final api = _Api();
    final (state, _) = _appWith(api);
    Channel privateChannel() => state.channelsByCommunity[_community]!
        .where((c) => c.id == _private)
        .single;
    final channel = privateChannel();
    api.answer = (
      move: {'to_conversation_id': 'conv_new'},
      conversation: Conversation(
          id: 'conv_new',
          kind: 'community_shared',
          communityId: _community,
          createdBy: 'alice'),
    );
    expect(await state.convertChannel(channel, toPrivate: false), isFalse);
    api.answer = (
      move: <String, Object?>{},
      conversation: Conversation(
          id: 'conv_shared',
          kind: 'community_channel',
          communityId: _community,
          createdBy: 'alice'),
    );
    expect(await state.convertChannel(channel, toPrivate: false), isFalse);
    api.answer = (move: {'to_access': 'private'}, conversation: null);
    expect(await state.convertChannel(channel, toPrivate: false), isFalse);
    expect(privateChannel().conversationId, 'conv_private');
    api.answer = (move: {'to_access': 'announcement'}, conversation: null);
    expect(await state.convertChannel(channel, toPrivate: false), isTrue);
    expect(privateChannel().kind, 'announcement');
    expect(privateChannel().conversationId, 'conv_shared');
  });

  Map<String, Object?> ownMove() => <String, Object?>{
        'channel_id': _open,
        'from_conversation_id': 'conv_shared',
        'to_conversation_id': 'conv_new',
        'access_mode': 'private',
        'moved_by': 'alice',
      };

  Future<void> settle(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<String?> pending(AppState state) async {
    final raw = await state.localStore.loadSetting('c3.pending_conversions');
    final all =
        raw == null ? const <String, Object?>{} : jsonDecode(raw) as Map;
    return all.isEmpty ? null : all.keys.join(',');
  }

  for (final lost in <Object>[
    const SocketException('lost'),
    ApiException(502, '{"error":"bad_gateway"}'),
  ])
    test(
        'a conversion whose answer was lost ($lost) is finished from its own '
        'move event: asked again, its readers added, its move owed here '
        '(review L-6)', () async {
      final api = _Api()..moveThrows = lost;
      final (state, crypto) = _appWith(api);
      final channel = state.channelsByCommunity[_community]!
          .where((c) => c.id == _open)
          .single;
      expect(
          await state
              .convertChannel(channel, toPrivate: true, members: ['bob']),
          isFalse);
      expect(api.added, isEmpty);
      expect(await pending(state), _open);
      await state.channelMovedForTesting(ownMove());
      await settle(() => api.added.isNotEmpty);
      expect(api.moves, [(_open, 'private'), (_open, 'private')]);
      expect(api.added, [('conv_new', 'bob')]);
      expect(crypto.notes.map((n) => n.own), [false, true]);
      expect(await pending(state), isNull);
    });

  for (final other in ['alice', 'bob']) {
    test(
        'a conversion pending here is forgotten, not asked again, when its '
        'channel moved on (${other == 'alice' ? 'by another device of this account' : 'by another admin'}, review L-6)',
        () async {
      final api = _Api()..moveThrows = const SocketException('lost');
      final (state, crypto) = _appWith(api);
      final channel = state.channelsByCommunity[_community]!
          .where((c) => c.id == _open)
          .single;
      expect(
          await state
              .convertChannel(channel, toPrivate: true, members: ['bob']),
          isFalse);
      expect(await pending(state), _open);
      // The request never reached the server; the channel was made
      // private and open again since.
      await state.channelMovesForTesting([
        {...ownMove(), 'moved_by': other, 'to_conversation_id': 'conv_other'},
        <String, Object?>{
          'channel_id': _open,
          'from_conversation_id': 'conv_other',
          'to_conversation_id': 'conv_shared',
          'access_mode': 'open',
          'moved_by': other,
        },
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(api.moves, [(_open, 'private')]);
      expect(await pending(state), isNull);
      // A later move like the one asked for finishes nothing either.
      await state.channelMovedForTesting(ownMove());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(api.moves, [(_open, 'private')]);
      expect(crypto.notes.map((n) => n.own), [false, false, false]);
    });
  }

  test(
      'an own move event finishes nothing here when this device did not '
      'ask, or its request was refused (review L-6)', () async {
    // Another device of this account converted it.
    final api = _Api();
    final (state, crypto) = _appWith(api);
    await state.channelMovedForTesting(ownMove());
    // Lost here, but the move is another admin's.
    final lost = _Api()..moveThrows = const SocketException('lost');
    final (third, _) = _appWith(lost);
    expect(
        await third.convertChannel(
            third.channelsByCommunity[_community]!
                .where((c) => c.id == _open)
                .single,
            toPrivate: true,
            members: ['bob']),
        isFalse);
    expect(await pending(third), _open);
    await third.channelMovedForTesting({...ownMove(), 'moved_by': 'bob'});
    // Refused: nothing moved.
    final refused = _Api()
      ..moveThrows = ApiException(403, '{"error":"forbidden"}');
    final (other, otherCrypto) = _appWith(refused);
    expect(
        await other.convertChannel(
            other.channelsByCommunity[_community]!
                .where((c) => c.id == _open)
                .single,
            toPrivate: true,
            members: ['bob']),
        isFalse);
    expect(await pending(other), isNull);
    await other.channelMovedForTesting(ownMove());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(api.moves, isEmpty);
    expect(crypto.notes.map((n) => n.own), [false]);
    expect(refused.moves, [(_open, 'private')]);
    expect(lost.moves, [(_open, 'private')]);
    expect(await pending(third), isNull);
    expect(otherCrypto.notes.map((n) => n.own), [false]);
  });

  for (final lost in [true, false]) {
    test(
        'an own move event while the answer is awaited '
        '${lost ? 'finishes the conversion once the answer is lost' : 'asks nothing again once it comes'} '
        '(review L-6)', () async {
      final api = _Api()
        ..moveGate = Completer<void>()
        ..moveThrows = lost ? const SocketException('lost') : null;
      final (state, crypto) = _appWith(api);
      final channel = state.channelsByCommunity[_community]!
          .where((c) => c.id == _open)
          .single;
      final converting =
          state.convertChannel(channel, toPrivate: true, members: ['bob']);
      await settle(() => api.moves.isNotEmpty);
      await state.channelMovedForTesting(ownMove());
      api.moveGate!.complete();
      expect(await converting, !lost);
      await settle(() => api.added.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(api.moves.length, lost ? 2 : 1);
      expect(api.added, [('conv_new', 'bob')]);
      expect(crypto.notes.map((n) => n.own), [false, true]);
      expect(await pending(state), isNull);
    });
  }

  test('a second conversion of a channel while one runs asks nothing',
      () async {
    final api = _Api()..moveGate = Completer<void>();
    final (state, _) = _appWith(api);
    final channel = state.channelsByCommunity[_community]!
        .where((c) => c.id == _open)
        .single;
    final first =
        state.convertChannel(channel, toPrivate: true, members: ['bob']);
    expect(
        await state.convertChannel(channel, toPrivate: true, members: ['bob']),
        isFalse);
    await settle(() => api.moves.isNotEmpty);
    api.moveGate!.complete();
    expect(await first, isTrue);
    expect(api.moves, [(_open, 'private')]);
  });

  test(
      'an admin who is not in a private channel cannot open it '
      '(review L-6)', () async {
    final api = _Api();
    final (state, _) = _appWith(api);
    final channel = state.channelsByCommunity[_community]!
        .where((c) => c.id == _private)
        .single;
    expect(state.mayConvertChannel(channel), isTrue);
    state.conversations = [
      for (final c in state.conversations)
        if (c.id != 'conv_private') c,
    ];
    expect(state.mayConvertChannel(channel), isFalse);
    expect(await state.convertChannel(channel, toPrivate: false), isFalse);
    expect(api.moves, isEmpty);
    // An open channel is still made private by any admin.
    expect(
        state.mayConvertChannel(state.channelsByCommunity[_community]!
            .where((c) => c.id == _open)
            .single),
        isTrue);
  });

  test(
      'converting moves the rows and notes an owed move; the work pass '
      'proposes it with its layout generation and fetches moved pages',
      () async {
    final api = _Api();
    final (state, crypto) = _appWith(api);
    await state.localStore.importC7History(<MessageEffect>[
      InsertMessageEffect(
          key: 'dev_bob:p1',
          conversationId: 'conv_private',
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          createdAt: 1,
          state: LocalMessageState.received,
          body: 'private earlier'),
    ]);
    final channel = state.channelsByCommunity[_community]!
        .where((c) => c.id == _private)
        .single;
    expect(state.mayConvertChannel(channel), isTrue);
    expect(await state.convertChannel(channel, toPrivate: false), isTrue);
    expect(api.moves, [(_private, 'open')]);
    final rows = await state.localStore.loadMessages('conv_shared');
    expect(rows.single.channelId, _private);
    expect(crypto.notes.first, (
      channel: _private,
      from: 'conv_private',
      to: 'conv_shared',
      own: true
    ));
    final converted = state.channelsByCommunity[_community]!
        .where((c) => c.id == _private)
        .single;
    expect(converted.kind, 'open');
    expect(converted.conversationId, 'conv_shared');
    expect(converted.layoutGeneration, 4);
    final due = C7DueMove('conv_shared', _private, 'conv_private');
    crypto.due = <C7Due>[due];
    api.moved['chan_x'] = _rows('chan_x', 2);
    crypto.movesDue = <C7Move>[
      const C7Move(
          channelId: 'chan_x',
          fromConversationId: 'conv_private',
          toConversationId: 'conv_shared'),
    ];
    await state.c7WorkPassForTesting();
    expect(crypto.moveProposals.last, (due, 4));
    expect(api.movedAsked, contains(('chan_x', 'conv_private', true)));
    expect(api.movedAsked, contains(('chan_x', 'conv_private', false)));
    expect(crypto.movedImports, hasLength(1));
  });

  test(
      'making an open channel private adds the readers left ticked, and '
      'only them, in one reconcile; the channel\'s rows move with it '
      '(owner answer 2026-11-12, "Admin picks during switch")', () async {
    final api = _Api();
    final (state, crypto) = _appWith(api);
    await state.localStore.importC7History(<MessageEffect>[
      InsertMessageEffect(
          key: 'dev_bob:o1',
          conversationId: 'conv_shared',
          channelId: _open,
          senderAccountId: 'bob',
          senderDeviceId: 'dev_bob',
          kind: LocalMessageKind.text,
          createdAt: 1,
          state: LocalMessageState.received,
          body: 'open earlier'),
    ]);
    final channel = state.channelsByCommunity[_community]!
        .where((c) => c.id == _open)
        .single;
    // The screen lists everyone but this account, all ticked.
    expect((await state.channelReaders(channel)).map((m) => m.accountId),
        ['bob', 'carol', 'dave']);
    // Carol is unticked; this account is never added to its own channel.
    expect(
        await state.convertChannel(channel,
            toPrivate: true, members: ['bob', 'dave', 'alice']),
        isTrue);
    expect(api.moves, [(_open, 'private')]);
    expect(api.added, [('conv_new', 'bob'), ('conv_new', 'dave')]);
    expect(state.mlsReconcileNowForTesting('conv_new'), isTrue);
    expect(crypto.notes.first,
        (channel: _open, from: 'conv_shared', to: 'conv_new', own: true));
    final rows = await state.localStore.loadMessages('conv_new');
    expect(rows.single.body, 'open earlier');
    expect(await state.localStore.loadMessages('conv_shared'), isEmpty);
  });

  test(
      'an add the server refuses leaves the channel converted, still adds '
      'the other ticked readers and names the refused one', () async {
    final api = _Api()..addFails = 'carol';
    final (state, _) = _appWith(api);
    final channel = state.channelsByCommunity[_community]!
        .where((c) => c.id == _open)
        .single;
    expect(
        await state.convertChannel(channel,
            toPrivate: true, members: ['bob', 'carol', 'dave']),
        isTrue);
    expect(api.added, [('conv_new', 'bob'), ('conv_new', 'dave')]);
    expect(state.channelConversionNotAdded, ['carol']);
    expect(state.error, isNotNull);
    expect(state.mlsReconcileNowForTesting('conv_new'), isTrue);
    final converted = state.channelsByCommunity[_community]!
        .where((c) => c.id == _open)
        .single;
    expect(converted.kind, 'private');
    expect(converted.conversationId, 'conv_new');
  });

  test('making a private channel open adds no one', () async {
    final api = _Api();
    final (state, _) = _appWith(api);
    final channel = state.channelsByCommunity[_community]!
        .where((c) => c.id == _private)
        .single;
    expect(
        await state.convertChannel(channel, toPrivate: false, members: ['bob']),
        isTrue);
    expect(api.added, isEmpty);
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
      "a history_sync the server refuses as delivered, and a newcomer's "
      'request it spaces out, leave the outbox; any other refusal stays as a '
      'failed send', () async {
    final api = _Api();
    final (state, crypto) = _appWith(api);
    crypto.outbox = state.localStore;
    crypto.due = <C7Due>[
      const C7DueSync('conv_shared', 4),
      const C7DueSync('conv_private', 2),
      const C7DueRequest('conv_private', 3),
    ];
    api.refusals['action-1'] =
        ApiException(409, '{"error":"history_sync_delivered"}');
    api.refusals['action-2'] =
        ApiException(409, '{"error":"idempotency_conflict"}');
    api.refusals['action-3'] =
        ApiException(409, '{"error":"history_sync_request_too_soon"}');
    await state.c7WorkPassForTesting();
    for (var i = 0; i < 100 && api.sentKeys.length < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.sentKeys,
        containsAll(<String>['action-1', 'action-2', 'action-3']));
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

  for (final status in [403, 404]) {
    test(
        'an import whose routes the server refuses ($status) waits a day, '
        'for a newcomer import and a moved one (review L-5)', () async {
      final api = _Api()..historyRefusal = status;
      final (state, crypto) = _appWith(api);
      var now = DateTime.utc(2026, 11, 12, 10);
      state.c7Clock = () => now;
      api.moved[_open] = _rows(_open, 1);
      Future<(int, int)> pass() async {
        final history = api.historyAsked.length;
        final moved = api.movedAsked.length;
        crypto.importDue = <String>['conv_shared'];
        crypto.movesDue = <C7Move>[
          C7Move(
              channelId: _open,
              fromConversationId: 'conv_private',
              toConversationId: 'conv_shared'),
        ];
        await state.c7WorkPassForTesting();
        return (
          api.historyAsked.length - history,
          api.movedAsked.length - moved
        );
      }

      expect(await pass(), (1, 1));
      now = now.add(const Duration(hours: 23, minutes: 59));
      expect(await pass(), (0, 0));
      now = now.add(const Duration(minutes: 1));
      api.historyRefusal = null;
      final (history, moved) = await pass();
      expect(history, greaterThan(0));
      expect(moved, greaterThan(0));
    });
  }

  test('"Load earlier posts" pages a full channel on demand', () async {
    final api = _Api();
    final (state, crypto) = _appWith(api);
    api.history[_open] = _rows(_open, 1200);
    crypto.earlier = <String, String>{_open: 'm_${_open}_201'};
    state.selectChannel('conv_shared', _open);
    expect(state.channelHistoryEarlier('conv_shared'), isFalse);
    await state.c7WorkPassForTesting();
    expect(state.channelHistoryEarlier('conv_shared'), isTrue);
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
