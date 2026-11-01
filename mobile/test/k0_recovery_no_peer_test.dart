import 'package:flutter/material.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/conversation_details_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/theme.dart';

import 'k0_recovery_fakes.dart';

/// K0 R4, conversations no one can add a recovered device to (design,
/// client flow step 7; K0 step 8): the history stays, the composer is
/// replaced by a notice, nothing is sent, and a Welcome (a group on this
/// device) makes the conversation normal again.

/// Group membership as the recovered device sees it: [groups] are the
/// conversations it holds an MLS group for.
class _NoPeerCrypto extends K0Crypto {
  final Set<String> groups = <String>{};

  /// Conversations a send reached encryption for. Encryption then fails,
  /// so nothing is queued.
  final List<String> encrypted = <String>[];

  @override
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  }) async {
    encrypted.add(conversationId);
    throw StateError('test encryption');
  }

  /// A Welcome to this device gives it the group.
  @override
  Future<void> processMlsMessage(MlsMessage message) async {
    if (message.kind == 'welcome') groups.add(message.conversationId);
  }

  @override
  Future<({int epoch, bool pending})?> groupEpoch(
          String conversationId) async =>
      groups.contains(conversationId) ? (epoch: 3, pending: false) : null;
}

class _NoPeerApi extends K0Api {
  _NoPeerApi(super.server, this.rosters, [super.baseUrl]);

  /// Each conversation's member accounts; a missing one fails to load.
  final Map<String, List<String>> rosters;
  final List<String> writes = <String>[];
  final List<MlsMessage> mls = <MlsMessage>[];

  @override
  Future<List<MlsMessage>> mlsMessages(String token,
          {int after = 0, int limit = 100}) async =>
      mls.where((item) => item.syncEventId > after).toList(growable: false);

  @override
  Future<MlsMessage> mlsMessage(String token, String messageId) async =>
      mls.singleWhere((item) => item.id == messageId);

  @override
  Future<AttachmentEnvelope> uploadEncryptedAttachment(
    String token,
    String conversationId,
    Stream<List<int>> ciphertext, {
    required int ciphertextLength,
    required Map<String, Object?> cryptoMetadata,
  }) async {
    writes.add('upload');
    throw StateError('no upload expected');
  }

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[
        for (final id in rosters.keys)
          Conversation(id: id, kind: 'group', title: id, createdBy: 'acct_me'),
      ];

  @override
  Future<List<ConversationMember>> conversationMembers(
      String token, String conversationId) async {
    final roster = rosters[conversationId];
    if (roster == null) throw ApiException(503, '{"error":"unavailable"}');
    return <ConversationMember>[
      for (final account in roster)
        ConversationMember(
            accountId: account,
            role: account == 'acct_me' ? 'owner' : 'member'),
    ];
  }

  @override
  Future<MessagePage> listMessagePage(String token, String conversationId,
          {int limit = 50, String? before}) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);

  @override
  Future<ConversationMute> conversationMute(
          String token, String conversationId) async =>
      ConversationMute(muted: false);

  @override
  Future<void> markRead(
      String token, String conversationId, String messageId) async {}

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    writes.add('send');
  }

  @override
  Future<void> addConversationMember(
      String token, String conversationId, String accountId,
      {String role = 'member'}) async {
    writes.add('add-member');
  }
}

void main() {
  final l10n = englishL10n;
  late K0Server server;
  late MemoryLocalStore store;
  late _NoPeerCrypto crypto;
  late Map<String, List<String>> rosters;
  late List<_NoPeerApi> apis;
  late _Attachments attachments;
  late AppState state;

  AppState makeApp() => AppState(
        apiClientFactory: (url) {
          final api = _NoPeerApi(server, rosters, url);
          apis.add(api);
          return api;
        },
        cryptoService: crypto,
        attachmentService: attachments,
        localStore: store,
        syncServiceFactory: (_, __) => K0QuietSync(),
      );

  setUp(() {
    server = K0Server();
    store = MemoryLocalStore();
    crypto = _NoPeerCrypto();
    rosters = <String, List<String>>{
      'conv_self': <String>['acct_me'],
      'conv_peer': <String>['acct_me', 'acct_bob'],
    };
    apis = <_NoPeerApi>[];
    attachments = _Attachments();
    state = makeApp();
  });

  tearDown(() => state.dispose());

  /// Claims and completes a recovery, as k0_recovery_flow_test does.
  Future<void> recover(AppState app) async {
    expect(
        await app.startAccountRecovery(
            baseUrl: k0Origin,
            username: 'alice',
            password: 'pw',
            recoveryKey: k0Display),
        isTrue,
        reason: app.errorFor(Ops.accountRecovery));
    server.statusAnswers.add(const AccountRecoveryStatus(
      phase: AccountRecoveryPhase.completed,
      accountId: 'acct_me',
      deviceId: 'dev_new',
      username: 'alice',
      role: 'member',
      token: 'tok_new',
    ));
    expect(await app.checkAccountRecovery(), isTrue,
        reason: app.errorFor(Ops.accountRecovery));
    await app.refreshConversations();
  }

  Future<void> open(AppState app, String id) async {
    expect(await app.loadConversationMembers(id), isTrue);
    app.selectAndPrepare(id);
    await pumpEventQueue();
  }

  group('read-only no-peer conversations', () {
    test('no group and no other account: history only, nothing sent', () async {
      await recover(state);
      await open(state, 'conv_self');
      expect(state.readOnlyWithoutPeer('conv_self'), isTrue);

      Future<void> refused(Future<bool> attempt) async {
        state.clearError(Ops.send);
        expect(await attempt, isFalse);
        expect(state.errorFor(Ops.send), l10n.chatNoPeerReadOnly);
      }

      await refused(state.sendMessageTo('conv_self', 'hello'));
      await refused(state.react('conv_self', 'k', '👍'));
      await refused(state.deleteMessage('conv_self', 'k'));
      await refused(state.replyTo('conv_self', 'k', 'hello'));
      await refused(state.editMessage('conv_self', 'k', 'hello'));
      await refused(state.pinMessage('conv_self', 'k', pinned: true));
      expect(crypto.encrypted, isEmpty);
      expect(
          await state.sendAttachment('conv_self',
              path: '/nonexistent/photo.jpg', fileName: 'photo.jpg'),
          isFalse);
      expect(state.errorFor(Ops.attachment), l10n.chatNoPeerReadOnly);
      expect(attachments.calls, isEmpty);
      expect(await store.pendingEnvelopeRecords(), isEmpty);
      expect(apis.expand((api) => api.writes), isEmpty);
    });

    test('a member list naming another account is a normal conversation',
        () async {
      await recover(state);
      await open(state, 'conv_peer');
      expect(state.readOnlyWithoutPeer('conv_peer'), isFalse);
      // The send goes on to encryption (which fails here: no group yet).
      expect(await state.sendMessageTo('conv_peer', 'hello'), isFalse);
      expect(state.errorFor(Ops.send), isNot(l10n.chatNoPeerReadOnly));
      expect(crypto.encrypted, <String>['conv_peer']);
    });

    test('forwarding into a read-only conversation is refused', () async {
      await recover(state);
      await open(state, 'conv_self');
      await open(state, 'conv_peer');
      crypto.groups.add('conv_peer');
      await store.saveCryptoState(
          StoredCryptoState(
              counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
          0);
      await store.commitMlsTransition(MlsStateTransition(
          messageId: 'seed',
          conversationId: 'conv_peer',
          expectedCounter: 1,
          expectedCursor: 0,
          state: StoredCryptoState(
              counter: 2, stateKey: List.filled(32, 1), sealedState: [2]),
          cursor: 1,
          messageEffects: [
            InsertMessageEffect(
                key: 'dev_bob:m1',
                conversationId: 'conv_peer',
                senderAccountId: 'acct_bob',
                senderDeviceId: 'dev_bob',
                kind: LocalMessageKind.text,
                body: 'hi',
                createdAt: 1,
                state: LocalMessageState.received),
          ]));
      await state.refreshHistory('conv_peer');
      final source = state.historyFor('conv_peer').forKey('dev_bob:m1')!;
      expect(
          await state.forwardMessage(source, <String>['conv_self']), isFalse);
      expect(state.errorFor(Ops.send), l10n.chatNoPeerReadOnly);
      expect(crypto.encrypted, isEmpty);
    });

    test('adding a member is refused and not offered', () async {
      await recover(state);
      await open(state, 'conv_self');
      await state.addConversationMember('conv_self', 'acct_carol');
      expect(state.error, l10n.chatNoPeerReadOnly);
      expect(apis.expand((api) => api.writes), isEmpty);
    });

    test('becomes normal once a Welcome gave this device the group', () async {
      await recover(state);
      await open(state, 'conv_self');
      expect(state.readOnlyWithoutPeer('conv_self'), isTrue);

      crypto.groups.add('conv_self');
      // The list refresh reads only new conversations; opening one reads
      // its group again.
      await state.refreshConversations();
      expect(state.readOnlyWithoutPeer('conv_self'), isTrue);
      await open(state, 'conv_self');
      expect(state.readOnlyWithoutPeer('conv_self'), isFalse);
      expect(await state.sendMessageTo('conv_self', 'hello'), isFalse);
      expect(state.errorFor(Ops.send), isNot(l10n.chatNoPeerReadOnly));
      expect(crypto.encrypted, <String>['conv_self']);
    });

    test('the notice stays while a membership event reloads the list',
        () async {
      await recover(state);
      await open(state, 'conv_self');
      expect(state.readOnlyWithoutPeer('conv_self'), isTrue);
      // As a membership event does: the list is dropped until read again.
      state.membersByConversation = Map.of(state.membersByConversation)
        ..remove('conv_self');
      expect(state.readOnlyWithoutPeer('conv_self'), isTrue);
      expect(await state.sendMessageTo('conv_self', 'hello'), isFalse);
      expect(state.errorFor(Ops.send), l10n.chatNoPeerReadOnly);
    });

    test('the mark applies before any notice refresh has run', () async {
      await recover(state);
      state.dispose();
      // A new app with the session set directly: nothing read the mark.
      state = makeApp()
        ..session = server.session()
        ..api = _NoPeerApi(server, rosters)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_self', kind: 'group', createdBy: 'acct_me'),
        ];
      expect(await state.loadConversationMembers('conv_self'), isTrue);
      expect(await state.sendMessageTo('conv_self', 'hello'), isFalse);
      expect(state.errorFor(Ops.send), l10n.chatNoPeerReadOnly);
      expect(crypto.encrypted, isEmpty);
    });

    test('a Welcome through sync ends it without a refresh', () async {
      await recover(state);
      await open(state, 'conv_self');
      expect(state.readOnlyWithoutPeer('conv_self'), isTrue);

      final at = DateTime.now().toUtc();
      final eventId = (server.events.isEmpty ? 0 : server.events.last.id) + 1;
      apis.last.mls.add(MlsMessage(
        id: 'mls_welcome',
        conversationId: 'conv_self',
        senderAccountId: 'acct_me',
        senderDeviceId: 'dev_link',
        recipientDeviceId: 'dev_new',
        kind: 'welcome',
        payload: const <int>[7],
        idempotencyKey: 'welcome',
        syncEventId: eventId,
        createdAt: at,
      ));
      server.events.add(SyncEvent(
        id: eventId,
        type: 'mls.message.created',
        conversationId: 'conv_self',
        payload: const <String, Object?>{
          'mls_message_id': 'mls_welcome',
          'kind': 'welcome',
        },
        createdAt: at,
      ));
      var redrawn = false;
      state.addListener(() {
        if (!state.readOnlyWithoutPeer('conv_self')) redrawn = true;
      });
      state.handleAppLifecycleState(AppLifecycleState.resumed);
      for (var i = 0; i < 400 && !redrawn; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(redrawn, isTrue);
      expect(crypto.groups, contains('conv_self'));
    });

    test('a member list not loaded yet shows no notice but sends nothing',
        () async {
      rosters['conv_unknown'] = <String>['acct_me', 'acct_bob'];
      await recover(state);
      rosters.remove('conv_unknown');
      expect(await state.loadConversationMembers('conv_unknown'), isFalse);
      expect(state.readOnlyWithoutPeer('conv_unknown'), isFalse);
      expect(await state.sendMessageTo('conv_unknown', 'hello'), isFalse);
      expect(state.errorFor(Ops.send), l10n.chatNoPeerCheckFailed);
      expect(crypto.encrypted, isEmpty);
      expect(await store.pendingEnvelopeRecords(), isEmpty);
    });

    test('survives a restart; a device that was not recovered never shows it',
        () async {
      await recover(state);
      state.dispose();
      state = makeApp();
      await state.tryRestoreSession();
      await open(state, 'conv_self');
      expect(state.readOnlyWithoutPeer('conv_self'), isTrue);

      // Another device's session over the same store: the mark is scoped
      // to the recovered device.
      state.dispose();
      await store.saveSession(k0SignedIn);
      state = makeApp();
      await state.tryRestoreSession();
      // The mark is still stored; it names another device.
      expect(await store.loadSetting('k0.recovered_device'),
          'acct_me\u0000dev_new');
      await open(state, 'conv_self');
      expect(state.readOnlyWithoutPeer('conv_self'), isFalse);
    });
  });

  testWidgets('the chat shows the notice in place of the composer',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await recover(state);
      await open(state, 'conv_self');
    });
    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      home: ChatScreen(state: state, conversationId: 'conv_self'),
    ));
    await tester.pumpAndSettle();
    expect(find.text(l10n.chatNoPeerReadOnly), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      home:
          ConversationDetailsScreen(state: state, conversationId: 'conv_self'),
    ));
    // The screen reloads the member list; let that finish for real.
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(find.text(l10n.detailsAddMember), findsNothing);
    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      home: ChatScreen(state: state, conversationId: 'conv_self'),
    ));
    await tester.pumpAndSettle();

    crypto.groups.add('conv_self');
    await tester.runAsync(() => open(state, 'conv_self'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.chatNoPeerReadOnly), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      home:
          ConversationDetailsScreen(state: state, conversationId: 'conv_self'),
    ));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(find.text(l10n.detailsAddMember), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}

/// Records any use; the guard must refuse before encryption.
class _Attachments implements AttachmentCryptoService {
  final List<Symbol> calls = <Symbol>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw UnimplementedError('${invocation.memberName}');
  }
}
