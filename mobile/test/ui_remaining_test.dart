import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/conversation_details_screen.dart';
import 'package:private_messenger/features/settings/blocked_accounts_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/format.dart';
import 'package:private_messenger/ui/widgets/connection_banner.dart';

import 'test_crypto_service.dart';

void main() {
  group('DM identity', () {
    test('a DM is titled by its peer, not by its kind', () {
      final alice = Conversation(
        id: 'conv_1',
        kind: 'dm',
        peerAccountId: 'acct_alice',
        peerUsername: 'alice',
      );
      final bob = Conversation(
        id: 'conv_2',
        kind: 'dm',
        peerAccountId: 'acct_bob',
        peerUsername: 'bob',
      );
      expect(conversationTitle(alice), '@alice');
      expect(conversationTitle(bob), '@bob');
      expect(conversationTitle(alice), isNot(conversationTitle(bob)));
    });

    test('a DM without a username still distinguishes the peer', () {
      final one = Conversation(
        id: 'conv_1',
        kind: 'dm',
        peerAccountId: 'acct_0000000000000001',
      );
      final two = Conversation(
        id: 'conv_2',
        kind: 'dm',
        peerAccountId: 'acct_0000000000000002',
      );
      expect(conversationTitle(one), isNot('Direct message'));
      expect(conversationTitle(one), isNot(conversationTitle(two)));
    });

    test('peer identity survives a snapshot round trip', () {
      final original = Conversation(
        id: 'conv_1',
        kind: 'dm',
        peerAccountId: 'acct_alice',
        peerUsername: 'alice',
      );
      final restored = Conversation.fromJson(original.toJson());
      expect(restored.peerAccountId, 'acct_alice');
      expect(restored.peerUsername, 'alice');
    });

    test('an empty server-supplied username is not shown as a blank name', () {
      final conversation = Conversation.fromJson(<String, Object?>{
        'id': 'conv_1',
        'kind': 'dm',
        'peer_account_id': 'acct_alice',
        'peer_username': '',
      });
      expect(conversation.peerUsername, isNull);
      expect(conversationTitle(conversation), contains('acct_'));
    });

    testWidgets('the chat list renders distinct rows for two DMs',
        (tester) async {
      final state = _connectedState(_FakeApi())
        ..conversations = <Conversation>[
          Conversation(
            id: 'conv_1',
            kind: 'dm',
            peerAccountId: 'acct_alice',
            peerUsername: 'alice',
          ),
          Conversation(
            id: 'conv_2',
            kind: 'dm',
            peerAccountId: 'acct_bob',
            peerUsername: 'bob',
          ),
        ]
        ..conversationsLoaded = true;

      await tester.pumpWidget(_app(ChatListScreen(state: state)));

      expect(find.text('@alice'), findsOneWidget);
      expect(find.text('@bob'), findsOneWidget);
      expect(find.text('Direct message'), findsNothing);
    });

    test('starting a DM reuses the existing conversation with that peer',
        () async {
      final api = _FakeApi();
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(
            id: 'conv_1',
            kind: 'dm',
            peerAccountId: 'acct_alice',
            peerUsername: 'alice',
          ),
        ];

      final result = await state.startConversation(
        kind: 'dm',
        memberAccountIds: <String>['acct_alice'],
      );

      expect(result?.id, 'conv_1');
      expect(api.createdConversations, isEmpty);
      expect(state.conversations, hasLength(1));
    });
  });

  group('message history', () {
    test('the newest page records the cursor and older pages prepend',
        () async {
      final api = _FakeApi()
        ..pages = <String?, MessagePage>{
          null: MessagePage(
            messages: <ReceivedMessageEnvelope>[
              _message('m_30', '2026-06-03T12:00:00Z'),
              _message('m_29', '2026-06-03T11:00:00Z'),
            ],
            nextBefore: 'm_29',
          ),
          'm_29': MessagePage(
            messages: <ReceivedMessageEnvelope>[
              _message('m_28', '2026-06-03T10:00:00Z'),
            ],
          ),
        };
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ];

      await state.loadMessages('conv_1');
      expect(state.hasMoreHistory('conv_1'), isTrue);
      expect(state.messagesFor('conv_1').map((m) => m.id), <String>[
        'm_30',
        'm_29',
      ]);

      await state.loadOlderMessages('conv_1');

      expect(state.messagesFor('conv_1').map((m) => m.id), <String>[
        'm_30',
        'm_29',
        'm_28',
      ]);
      // The server reported no further cursor, so the UI can stop offering
      // "load older" instead of looping forever.
      expect(state.hasMoreHistory('conv_1'), isFalse);

      await state.loadOlderMessages('conv_1');
      expect(api.pageRequests, <String?>[null, 'm_29']);
    });

    test('a repeated older page does not duplicate messages', () async {
      final api = _FakeApi()
        ..pages = <String?, MessagePage>{
          null: MessagePage(
            messages: <ReceivedMessageEnvelope>[
              _message('m_2', '2026-06-03T12:00:00Z'),
            ],
            nextBefore: 'm_2',
          ),
          'm_2': MessagePage(
            messages: <ReceivedMessageEnvelope>[
              _message('m_2', '2026-06-03T12:00:00Z'),
              _message('m_1', '2026-06-03T11:00:00Z'),
            ],
          ),
        };
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ];

      await state.loadMessages('conv_1');
      await state.loadOlderMessages('conv_1');

      expect(state.messagesFor('conv_1').map((m) => m.id), <String>[
        'm_2',
        'm_1',
      ]);
    });

    test('refetching the newest page keeps already-loaded older history',
        () async {
      final api = _FakeApi()
        ..pages = <String?, MessagePage>{
          null: MessagePage(
            messages: <ReceivedMessageEnvelope>[
              _message('m_2', '2026-06-03T12:00:00Z'),
            ],
            nextBefore: 'm_2',
          ),
          'm_2': MessagePage(
            messages: <ReceivedMessageEnvelope>[
              _message('m_1', '2026-06-03T11:00:00Z'),
            ],
          ),
        };
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ];

      await state.loadMessages('conv_1');
      await state.loadOlderMessages('conv_1');
      await state.loadMessages('conv_1');

      expect(state.messagesFor('conv_1').map((m) => m.id), <String>[
        'm_2',
        'm_1',
      ]);
    });

    test('a failed older page is reported and does not consume the cursor',
        () async {
      final api = _FakeApi()
        ..pages = <String?, MessagePage>{
          null: MessagePage(
            messages: <ReceivedMessageEnvelope>[
              _message('m_2', '2026-06-03T12:00:00Z'),
            ],
            nextBefore: 'm_2',
          ),
        }
        ..failPages = <String?>{'m_2'};
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ];

      await state.loadMessages('conv_1');
      await state.loadOlderMessages('conv_1');

      expect(state.messageLoadError('conv_1'), isNotNull);
      expect(state.hasMoreHistory('conv_1'), isTrue);
      expect(state.isLoadingOlder('conv_1'), isFalse);
    });
  });

  group('membership', () {
    testWidgets('the roster is listed and add-member is hidden on a DM',
        (tester) async {
      final api = _FakeApi()
        ..members = <ConversationMember>[
          ConversationMember(
            accountId: 'acct_owner',
            role: 'owner',
            username: 'owner',
          ),
          ConversationMember(
            accountId: 'acct_alice',
            role: 'member',
            username: 'alice',
          ),
        ];
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(
            id: 'conv_1',
            kind: 'dm',
            currentRole: 'owner',
            peerAccountId: 'acct_alice',
            peerUsername: 'alice',
          ),
        ];

      await tester.pumpWidget(_app(
        ConversationDetailsScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pumpAndSettle();

      expect(find.text('@owner'), findsOneWidget);
      expect(find.text('@alice'), findsWidgets);
      // A DM is a fixed pair; offering "Add member" here silently converts it
      // into a group.
      expect(find.text('Add member'), findsNothing);
    });

    testWidgets('a remove control is hidden when the actor cannot use it',
        (tester) async {
      final api = _FakeApi()
        ..members = <ConversationMember>[
          ConversationMember(
            accountId: 'acct_owner',
            role: 'owner',
            username: 'owner',
          ),
          ConversationMember(
            accountId: 'acct_alice',
            role: 'admin',
            username: 'alice',
          ),
        ];
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group', currentRole: 'moderator'),
        ];

      await tester.pumpWidget(_app(
        ConversationDetailsScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pumpAndSettle();

      // A moderator outranks neither an owner nor an admin.
      expect(find.byTooltip('Remove @alice'), findsNothing);
      expect(find.byTooltip('Remove @owner'), findsNothing);
    });

    testWidgets('an owner can remove a ranked-below member', (tester) async {
      final api = _FakeApi()
        ..members = <ConversationMember>[
          ConversationMember(
            accountId: 'acct_owner',
            role: 'owner',
            username: 'owner',
          ),
          ConversationMember(
            accountId: 'acct_alice',
            role: 'member',
            username: 'alice',
          ),
        ];
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group', currentRole: 'owner'),
        ];

      await tester.pumpWidget(_app(
        ConversationDetailsScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove @alice'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove @alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(api.removedMembers, <String>['acct_alice']);
      expect(state.membersFor('conv_1').map((m) => m.accountId),
          <String>['acct_owner']);
    });

    test('leaving drops the conversation and its local state', () async {
      final api = _FakeApi();
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
          Conversation(id: 'conv_2', kind: 'group'),
        ]
        ..selectedConversationId = 'conv_1';
      state.messagesByConversation['conv_1'] = <ReceivedMessageEnvelope>[
        _message('m_1', '2026-06-03T11:00:00Z'),
      ];

      final ok = await state.leaveConversation('conv_1');

      expect(ok, isTrue);
      expect(api.removedMembers, <String>['me']);
      expect(state.conversations.map((c) => c.id), <String>['conv_2']);
      expect(state.messagesByConversation.containsKey('conv_1'), isFalse);
      expect(state.selectedConversationId, isNull);
    });

    test('a failed leave keeps the conversation and reports scoped error',
        () async {
      final api = _FakeApi()..failMemberWrites = true;
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ];

      final ok = await state.leaveConversation('conv_1');

      expect(ok, isFalse);
      expect(state.conversations, hasLength(1));
      expect(state.errorFor(Ops.members), isNotNull);
      // The failure is scoped: unrelated controls stay usable.
      expect(state.errorFor(Ops.send), isNull);
      expect(state.busy, isFalse);
    });
  });

  group('blocking', () {
    test('blocking and unblocking update local block state', () async {
      final api = _FakeApi();
      final state = _connectedState(api);

      expect(state.isBlocked('acct_alice'), isFalse);
      expect(await state.blockAccount('acct_alice'), isTrue);
      expect(state.isBlocked('acct_alice'), isTrue);

      expect(await state.unblockAccount('acct_alice'), isTrue);
      expect(state.isBlocked('acct_alice'), isFalse);
    });

    testWidgets('a DM exposes a block action naming the peer', (tester) async {
      final dm = Conversation(
        id: 'conv_1',
        kind: 'dm',
        currentRole: 'owner',
        peerAccountId: 'acct_alice',
        peerUsername: 'alice',
      );
      final api = _FakeApi()..conversationList = <Conversation>[dm];
      final state = _connectedState(api)..conversations = <Conversation>[dm];

      await tester.pumpWidget(_app(
        ConversationDetailsScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Block @alice'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Block @alice'), findsOneWidget);
      await tester.tap(find.text('Block @alice'));
      await tester.pumpAndSettle();

      expect(api.blocked, <String>['acct_alice']);
      expect(find.text('Unblock @alice'), findsOneWidget);
    });

    testWidgets('the blocked-accounts screen lists blocks and unblocks them',
        (tester) async {
      final api = _FakeApi()
        ..blocks = <BlockedAccount>[
          BlockedAccount(accountId: 'acct_alice', username: 'alice'),
        ];
      final state = _connectedState(api);

      await tester.pumpWidget(_app(BlockedAccountsScreen(state: state)));
      await tester.pumpAndSettle();

      expect(find.text('@alice'), findsOneWidget);
      await tester.tap(find.text('Unblock'));
      await tester.pumpAndSettle();

      expect(api.unblocked, <String>['acct_alice']);
      expect(find.text('No blocked accounts'), findsOneWidget);
    });
  });

  group('notification mute', () {
    testWidgets('the mute switch reflects and updates server state',
        (tester) async {
      final api = _FakeApi();
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group', currentRole: 'owner'),
        ];

      await tester.pumpWidget(_app(
        ConversationDetailsScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pumpAndSettle();

      expect(state.isMuted('conv_1'), isFalse);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(api.mutedConversations['conv_1'], isTrue);
      expect(state.isMuted('conv_1'), isTrue);
    });
  });

  group('connection state', () {
    testWidgets('the banner is hidden while online and shown when offline',
        (tester) async {
      final state = _connectedState(_FakeApi())
        ..connectionStatus = ConnectionStatus.online;

      await tester.pumpWidget(_app(ConnectionBanner(state: state)));
      expect(find.text('Offline'), findsNothing);

      state.connectionStatus = ConnectionStatus.offline;
      await tester.pumpWidget(_app(ConnectionBanner(state: state)));
      await tester.pump();

      expect(find.text('Offline'), findsOneWidget);
      expect(
        find.textContaining('queued on this device'),
        findsOneWidget,
      );
    });
  });

  group('composer', () {
    testWidgets('an unrelated busy operation does not disable sending',
        (tester) async {
      final api = _FakeApi();
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ]
        // A long-running unrelated action used to disable every control.
        ..busy = true;

      await tester.pumpWidget(_app(
        ChatScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pumpAndSettle();

      final sendButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.send),
          matching: find.byType(IconButton),
        ),
      );
      expect(sendButton.onPressed, isNotNull);
    });

    testWidgets('the composer clears immediately after enqueueing',
        (tester) async {
      final api = _FakeApi()..holdSend = Completer<void>();
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ];

      await tester.pumpWidget(_app(
        ChatScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'first');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(find.text('first'), findsNothing);

      api.holdSend!.complete();
      await tester.pumpAndSettle();
    });
  });

  group('account labels', () {
    test('a username wins over the account id, which is the fallback', () {
      expect(accountLabel('acct_00000000000001', 'alice'), '@alice');
      expect(accountLabel('acct_00000000000001', null), contains('acct_'));
      expect(accountLabel('acct_00000000000001', ''), contains('acct_'));
    });

    test('initials never invent a letter for an unknown account', () {
      expect(accountInitials('acct_1', 'alice'), 'AL');
      expect(accountInitials('____', null), '?');
    });
  });
}

Widget _app(Widget child) => MaterialApp(home: child);

ReceivedMessageEnvelope _message(String id, String createdAt) {
  return ReceivedMessageEnvelope.fromJson(<String, Object?>{
    'id': id,
    'conversation_id': 'conv_1',
    'sender_account_id': 'acct_other',
    'sender_device_id': 'dev_other',
    'idempotency_key': id,
    'ciphertext': '',
    'crypto_protocol': 'test',
    'created_at': createdAt,
  });
}

AppState _connectedState(ApiClient api) {
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _FakeSyncService(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'http://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
    );
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: 'http://localhost:8080');

  Map<String?, MessagePage> pages = <String?, MessagePage>{};
  Set<String?> failPages = <String?>{};
  List<String?> pageRequests = <String?>[];
  List<ConversationMember> members = <ConversationMember>[];
  List<BlockedAccount> blocks = <BlockedAccount>[];
  List<String> removedMembers = <String>[];
  List<String> blocked = <String>[];
  List<String> unblocked = <String>[];
  List<String> createdConversations = <String>[];
  Map<String, bool> mutedConversations = <String, bool>{};
  bool failMemberWrites = false;
  Completer<void>? holdSend;

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    pageRequests.add(before);
    if (failPages.contains(before)) {
      throw ApiException(503, 'unavailable');
    }
    return pages[before] ??
        const MessagePage(messages: <ReceivedMessageEnvelope>[]);
  }

  @override
  Future<List<ConversationMember>> conversationMembers(
    String token,
    String conversationId,
  ) async =>
      members;

  @override
  Future<void> removeConversationMember(
    String token,
    String conversationId,
    String accountId,
  ) async {
    if (failMemberWrites) {
      throw ApiException(503, 'unavailable');
    }
    removedMembers.add(accountId);
  }

  @override
  Future<List<BlockedAccount>> listBlocks(String token) async => blocks;

  @override
  Future<BlockedAccount> blockAccount(String token, String accountId) async {
    blocked.add(accountId);
    final block = BlockedAccount(accountId: accountId);
    blocks = <BlockedAccount>[block, ...blocks];
    return block;
  }

  @override
  Future<void> unblockAccount(String token, String accountId) async {
    unblocked.add(accountId);
    blocks = blocks.where((block) => block.accountId != accountId).toList();
  }

  @override
  Future<bool> conversationMuted(String token, String conversationId) async =>
      mutedConversations[conversationId] ?? false;

  @override
  Future<bool> setConversationMuted(
    String token,
    String conversationId,
    bool muted,
  ) async {
    mutedConversations[conversationId] = muted;
    return muted;
  }

  @override
  Future<Conversation> createConversationDetailed(
    String token, {
    required String kind,
    String? title,
    String? communityId,
    String? channelId,
    List<String> memberAccountIds = const <String>[],
    int? retentionSeconds,
  }) async {
    final id = 'conv_new_${createdConversations.length}';
    createdConversations.add(id);
    return Conversation(id: id, kind: kind, title: title);
  }

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    await holdSend?.future;
  }

  /// What a conversation refresh returns. Block/unblock refresh the list, so
  /// tests that keep a screen mounted across a block must keep it populated.
  List<Conversation> conversationList = <Conversation>[];

  @override
  Future<List<Conversation>> conversations(String token) async =>
      conversationList;

  @override
  Future<void> markRead(
    String token,
    String conversationId,
    String messageId,
  ) async {}
}

class _FakeSyncService implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() {
    _controller.close();
  }
}
