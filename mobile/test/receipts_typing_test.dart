import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/receipts_state.dart';
import 'package:private_messenger/core/typing_state.dart';
import 'package:private_messenger/features/chat/message_ticks.dart';
import 'package:private_messenger/features/chat/typing_line.dart';
import 'package:private_messenger/features/settings/read_receipts_tile.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// W5: ticks, the typing line and the read-receipts switch.
void main() {
  final created = DateTime.utc(2026, 6, 2, 12, 0);

  MemberReceipt receipt(String id, {DateTime? delivered, DateTime? read}) =>
      MemberReceipt(
          accountId: id, deliveredThrough: delivered, readThrough: read);

  group('ticks', () {
    test('a message nobody has fetched stays sent', () {
      expect(
          tickForReceipts(<MemberReceipt>[receipt('a')], created,
              showRead: true),
          MessageTick.sent);
      expect(tickForReceipts(const <MemberReceipt>[], created, showRead: true),
          MessageTick.sent);
    });

    test('a DM goes sent, delivered, read', () {
      expect(
          tickForReceipts(
              <MemberReceipt>[receipt('a', delivered: created)], created,
              showRead: true),
          MessageTick.delivered);
      expect(
          tickForReceipts(<MemberReceipt>[
            receipt('a', delivered: created, read: created)
          ], created, showRead: true),
          MessageTick.read);
    });

    test('a cursor before the message does not cover it', () {
      final before = created.subtract(const Duration(microseconds: 1));
      expect(
          tickForReceipts(<MemberReceipt>[
            receipt('a', delivered: before, read: before)
          ], created, showRead: true),
          MessageTick.sent);
    });

    test('a member who joined after the message is not asked', () {
      final late = MemberReceipt(
        accountId: 'late',
        memberSince: created.add(const Duration(minutes: 1)),
      );
      final early = receipt('early', delivered: created, read: created);
      expect(
          tickForReceipts(<MemberReceipt>[early, late], created,
              showRead: true),
          MessageTick.read);
      // A message sent after they joined does count them.
      final newer = created.add(const Duration(minutes: 2));
      expect(
          tickForReceipts(<MemberReceipt>[
            receipt('early', delivered: newer, read: newer),
            late
          ], newer, showRead: true),
          MessageTick.sent);
    });

    test('a group needs every other member', () {
      final receipts = <MemberReceipt>[
        receipt('a', delivered: created, read: created),
        receipt('b', delivered: created),
        receipt('c'),
      ];
      expect(
          tickForReceipts(receipts, created, showRead: true), MessageTick.sent);
      expect(
          tickForReceipts(<MemberReceipt>[...receipts.take(2)], created,
              showRead: true),
          MessageTick.delivered);
      expect(
          tickForReceipts(<MemberReceipt>[
            receipt('a', delivered: created, read: created),
            receipt('b', delivered: created, read: created),
          ], created, showRead: true),
          MessageTick.read);
    });

    test('with your own receipts off you see delivery only', () {
      expect(
          tickForReceipts(<MemberReceipt>[
            receipt('a', delivered: created, read: created)
          ], created, showRead: false),
          MessageTick.delivered);
    });

    test('the fixture decodes', () {
      final fixture = jsonDecode(
        File('test/fixtures/api/v1/responses.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final rows = ((fixture['receipts_page']! as Map)['receipts']! as List)
          .map((row) =>
              MemberReceipt.fromJson(Map<String, Object?>.from(row as Map)))
          .toList();
      expect(rows[0].accountId, 'acct_peer');
      expect(rows[0].deliveredThrough,
          DateTime.utc(2026, 6, 2, 12, 30, 0, 123, 456));
      expect(rows[0].readThrough, DateTime.utc(2026, 6, 2, 12, 29));
      expect(rows[0].memberSince, DateTime.utc(2026, 6, 1, 8));
      expect(rows[1].deliveredThrough, isNull);
      expect(rows[1].readThrough, isNull);
    });
  });

  group('typing state', () {
    testWidgets('a fresh signal extends the window, silence ends it',
        (tester) async {
      final typing = TypingState();
      addTearDown(typing.dispose);
      typing.remoteTyping('c1', 'a');
      await tester.pump(const Duration(seconds: 3));
      typing.remoteTyping('c1', 'a');
      await tester.pump(const Duration(seconds: 3));
      expect(typing.typersIn('c1'), <String>['a']);
      await tester.pump(const Duration(seconds: 3));
      expect(typing.typersIn('c1'), isEmpty);
    });

    test('a message from the typer ends it at once', () {
      final typing = TypingState();
      addTearDown(typing.dispose);
      typing.remoteTyping('c1', 'a');
      typing.stoppedTyping('c1', 'a');
      expect(typing.typersIn('c1'), isEmpty);
    });

    test('sends are throttled per conversation', () {
      var now = DateTime.utc(2026, 6, 2, 12);
      final typing = TypingState(now: () => now);
      addTearDown(typing.dispose);
      expect(typing.takeSendSlot('c1'), isTrue);
      expect(typing.takeSendSlot('c1'), isFalse);
      expect(typing.takeSendSlot('c2'), isTrue);
      now = now.add(typingSendInterval);
      expect(typing.takeSendSlot('c1'), isTrue);
    });

    testWidgets('the timer clears the line', (tester) async {
      final typing = TypingState();
      addTearDown(typing.dispose);
      var notified = 0;
      typing.addListener(() => notified++);
      typing.remoteTyping('c1', 'a');
      expect(notified, 1);
      await tester.pump(typingExpiry + const Duration(seconds: 1));
      expect(notified, 2, reason: 'expiry tells the typing line');
      expect(typing.typersIn('c1'), isEmpty);
    });
  });

  group('app state', () {
    test('typing frames are routed and never trigger a catch-up', () {
      final state = _state(_Api());
      addTearDown(state.dispose);
      expect(
        state.handleEphemeralFrame(<String, Object?>{
          'type': 'typing.updated',
          'conversation_id': 'c1',
          'payload': <String, Object?>{'account_id': 'acct_peer'},
        }),
        isTrue,
      );
      expect(state.typing.typersIn('c1'), <String>['acct_peer']);
      // Your own echo is ignored.
      state.handleEphemeralFrame(<String, Object?>{
        'type': 'typing.updated',
        'conversation_id': 'c2',
        'payload': <String, Object?>{'account_id': 'acct_me'},
      });
      expect(state.typing.typersIn('c2'), isEmpty);
      expect(
        state.handleEphemeralFrame(<String, Object?>{'type': 'sync.connected'}),
        isFalse,
      );
    });

    test('delivery announcements are read once after a burst', () async {
      final api = _Api()
        ..receipts = <MemberReceipt>[
          receipt('acct_peer', delivered: created),
        ];
      final state = _state(api)..selectedConversationId = 'c1';
      addTearDown(state.dispose);
      for (var i = 0; i < 5; i++) {
        state.handleEphemeralFrame(<String, Object?>{
          'type': 'delivery_receipt.updated',
          'conversation_id': 'c1',
        });
      }
      await pumpEventQueue();
      expect(api.receiptReads, 0, reason: 'waits for the burst to end');
      await Future<void>.delayed(
          AppState.receiptsRefreshDebounce + const Duration(milliseconds: 100));
      await pumpEventQueue();
      expect(api.receiptReads, 1);
      expect(state.receipts.receiptsFor('c1').single.accountId, 'acct_peer');
      expect(state.receipts.tickFor('c1', created, showRead: true),
          MessageTick.delivered);
    });

    test('typing is sent throttled, and not to large conversations', () async {
      final api = _Api();
      final state = _state(api);
      addTearDown(state.dispose);
      state.membersByConversation = <String, List<ConversationMember>>{
        'small': [
          for (var i = 0; i < typingMaxMembers; i++)
            ConversationMember(accountId: 'a$i', role: 'member'),
        ],
        'large': [
          for (var i = 0; i <= typingMaxMembers; i++)
            ConversationMember(accountId: 'a$i', role: 'member'),
        ],
      };
      state.notifyTyping('small');
      state.notifyTyping('small');
      state.notifyTyping('large');
      state.notifyTyping('unknown');
      await pumpEventQueue();
      expect(api.typingSent, <String>['small']);
    });

    test('the switch decides whether a receipt is public or private', () async {
      final api = _Api();
      final state = _state(api)
        ..messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
          'c1': <ReceivedMessageEnvelope>[_message('m1', created)],
        };
      addTearDown(state.dispose);
      await state.markNewestMessageRead('c1');
      expect(api.reads, <String>['public:m1']);
      await state.receiptPreferences.setSendReadReceipts(false);
      await state.markNewestMessageRead('c1');
      expect(api.reads, <String>['public:m1', 'private:m1']);
      await state.receiptPreferences.setSendReadReceipts(true);
      await state.markNewestMessageRead('c1');
      expect(api.reads.last, 'public:m1');
    });

    test('a saved "off" is honoured before the first receipt', () async {
      final api = _Api();
      final state = AppState(
        apiClientFactory: (_) => api,
        cryptoService: TestOnlyCryptoService(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => _QuietSync(),
        receiptPreferences:
            ReceiptPreferences(MemoryReceiptPreferenceStore(false)),
      )
        ..api = api
        ..session = _session
        ..messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
          'c1': <ReceivedMessageEnvelope>[_message('m1', created)],
        };
      addTearDown(state.dispose);
      await state.markNewestMessageRead('c1');
      expect(api.reads, <String>['private:m1']);
    });

    test('the account switch from another device is adopted', () async {
      final api = _Api()..serverReceiptSetting = false;
      final state = _state(api);
      addTearDown(state.dispose);
      expect(state.receiptPreferences.sendReadReceipts, isTrue);
      await state.refreshReadReceiptsSetting();
      expect(state.receiptPreferences.sendReadReceipts, isFalse);
    });

    test(
        'ticks are offered in DMs and small groups, not channels or big groups',
        () {
      final state = _state(_Api())
        ..conversations = <Conversation>[
          Conversation(id: 'dm', kind: 'dm'),
          Conversation(id: 'group', kind: 'group'),
          Conversation(id: 'big', kind: 'group'),
          Conversation(id: 'channel', kind: 'community_channel'),
        ]
        ..membersByConversation = <String, List<ConversationMember>>{
          'big': [
            for (var i = 0; i <= tickMaxMembers; i++)
              ConversationMember(accountId: 'a$i', role: 'member'),
          ],
        };
      addTearDown(state.dispose);
      expect(state.ticksApply('dm'), isTrue);
      expect(state.ticksApply('group'), isTrue);
      expect(state.ticksApply('big'), isFalse);
      expect(state.ticksApply('channel'), isFalse);
      expect(state.ticksApply('unknown'), isFalse);
    });

    test('reconnecting reads the cursors again but still catches up', () async {
      final api = _Api()
        ..receipts = <MemberReceipt>[receipt('acct_peer', delivered: created)];
      final state = _state(api)..selectedConversationId = 'c1';
      addTearDown(state.dispose);
      expect(
        state.handleEphemeralFrame(<String, Object?>{'type': 'sync.connected'}),
        isFalse,
      );
      await pumpEventQueue();
      expect(state.receipts.receiptsFor('c1'), hasLength(1));
    });

    test('preferences persist and load', () async {
      final store = MemoryReceiptPreferenceStore();
      final first = ReceiptPreferences(store);
      await first.setSendReadReceipts(false);
      final second = ReceiptPreferences(store);
      await second.loaded;
      expect(second.sendReadReceipts, isFalse);
    });
  });

  group('widgets', () {
    Widget host(Widget child) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        );

    testWidgets('the typing line names one, two and several people',
        (tester) async {
      final state = _state(_Api())
        ..membersByConversation = <String, List<ConversationMember>>{
          'c1': <ConversationMember>[
            ConversationMember(accountId: 'acct_me', role: 'member'),
            ConversationMember(
                accountId: 'acct_a', role: 'member', username: 'alice'),
            ConversationMember(
                accountId: 'acct_b', role: 'member', username: 'bob'),
            ConversationMember(
                accountId: 'acct_c', role: 'member', username: 'carol'),
          ],
        };
      addTearDown(state.dispose);
      await tester
          .pumpWidget(host(TypingLine(state: state, conversationId: 'c1')));
      expect(find.textContaining('typing'), findsNothing);
      state.typing.remoteTyping('c1', 'acct_a');
      await tester.pump();
      expect(find.text('@alice is typing…'), findsOneWidget);
      state.typing.remoteTyping('c1', 'acct_b');
      await tester.pump();
      expect(find.text('@alice and @bob are typing…'), findsOneWidget);
      state.typing.remoteTyping('c1', 'acct_c');
      await tester.pump();
      expect(find.text('Several people are typing…'), findsOneWidget);
      await tester.pump(typingExpiry + const Duration(seconds: 1));
      expect(find.textContaining('typing'), findsNothing);
    });

    testWidgets('no typing line in a conversation over the limit',
        (tester) async {
      final state = _state(_Api())
        ..membersByConversation = <String, List<ConversationMember>>{
          'big': [
            for (var i = 0; i <= typingMaxMembers; i++)
              ConversationMember(accountId: 'a$i', role: 'member'),
          ],
        };
      addTearDown(state.dispose);
      state.typing.remoteTyping('big', 'a1');
      await tester
          .pumpWidget(host(TypingLine(state: state, conversationId: 'big')));
      expect(find.textContaining('typing'), findsNothing);
      await tester.pump(typingExpiry + const Duration(seconds: 1));
    });

    testWidgets('ticks follow the cursors and the switch', (tester) async {
      final state = _state(_Api());
      addTearDown(state.dispose);
      MessageTick? seen;
      await tester.pumpWidget(host(MessageTickBuilder(
        state: state,
        conversationId: 'c1',
        createdAt: created,
        enabled: true,
        builder: (context, tick) {
          seen = tick;
          return tick == null
              ? const SizedBox.shrink()
              : Column(children: <Widget>[
                  MessageTickIcon(tick: tick),
                  Text(messageTickLabel(context.l10n, tick)),
                ]);
        },
      )));
      expect(seen, MessageTick.sent);
      expect(find.byIcon(Icons.done), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);

      state.receipts.set('c1', <MemberReceipt>[
        receipt('acct_peer', delivered: created),
      ]);
      await tester.pump();
      expect(seen, MessageTick.delivered);
      expect(find.byIcon(Icons.done_all), findsOneWidget);

      state.receipts.set('c1', <MemberReceipt>[
        receipt('acct_peer', delivered: created, read: created),
      ]);
      await tester.pump();
      expect(seen, MessageTick.read);
      final icon = tester.widget<Icon>(find.byIcon(Icons.done_all));
      expect(icon.color,
          Theme.of(tester.element(find.byType(Column))).colorScheme.primary);

      await state.receiptPreferences.setSendReadReceipts(false);
      await tester.pump();
      expect(seen, MessageTick.delivered,
          reason: 'receipts off hides the read state');
    });

    testWidgets('the settings switch tells the server and follows the answer',
        (tester) async {
      final api = _Api();
      final state = _state(api);
      addTearDown(state.dispose);
      await tester.pumpWidget(host(ReadReceiptsTile(
        preferences: state.receiptPreferences,
        onChanged: state.setSendReadReceipts,
      )));
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(api.serverReceiptSetting, isFalse);
      expect(state.receiptPreferences.sendReadReceipts, isFalse);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      // The server refuses: the switch stays as it was and says so.
      api.failSetting = true;
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.pump();
      expect(state.receiptPreferences.sendReadReceipts, isFalse);
      expect(find.textContaining('could not be changed'), findsOneWidget);
    });
  });
}

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  username: 'me',
);

AppState _state(_Api api) => AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _QuietSync(),
    )
      ..api = api
      ..session = _session;

ReceivedMessageEnvelope _message(String id, DateTime createdAt) =>
    ReceivedMessageEnvelope.fromJson(<String, Object?>{
      'id': id,
      'conversation_id': 'c1',
      'sender_account_id': 'acct_peer',
      'sender_device_id': 'dev_peer',
      'idempotency_key': 'k_$id',
      'ciphertext': '',
      'crypto_protocol': 'test',
      'created_at': createdAt.toIso8601String(),
    });

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  List<MemberReceipt> receipts = <MemberReceipt>[];
  final List<String> typingSent = <String>[];
  final List<String> reads = <String>[];
  int receiptReads = 0;
  bool serverReceiptSetting = true;
  bool failSetting = false;

  @override
  Future<bool> readReceiptsEnabled(String token) async => serverReceiptSetting;

  @override
  Future<void> setReadReceiptsEnabled(String token, bool enabled) async {
    if (failSetting) throw const ApiResponseException();
    serverReceiptSetting = enabled;
  }

  @override
  Future<List<MemberReceipt>> listReceipts(
      String token, String conversationId) async {
    receiptReads++;
    return receipts;
  }

  @override
  Future<void> sendTyping(String token, String conversationId) async =>
      typingSent.add(conversationId);

  @override
  Future<void> markRead(
          String token, String conversationId, String messageId) async =>
      reads.add('public:$messageId');

  @override
  Future<void> markReadPrivate(
          String token, String conversationId, String messageId) async =>
      reads.add('private:$messageId');
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async => _controller.close();
}
