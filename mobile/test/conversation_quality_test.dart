import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/new_conversation_sheet.dart';
import 'package:private_messenger/features/communities/community_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/app_shell.dart';
import 'package:private_messenger/ui/format.dart';
import 'package:private_messenger/ui/validation.dart';
import 'package:private_messenger/ui/widgets/gated_explanation.dart';

import 'test_crypto_service.dart';

/// T44B: conversation, list and form quality.
void main() {
  group('list time', () {
    testWidgets('is relative to today and locale-formatted otherwise',
        (tester) async {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (value) {
          context = value;
          return const SizedBox();
        }),
      ));
      final now = DateTime(2026, 10, 22, 15, 30);
      String at(DateTime time) => formatListTime(context, time, now: now);

      expect(at(DateTime(2026, 10, 22, 9, 5)), '9:05 AM');
      // Slight server clock skew ahead of the device is still today.
      expect(at(DateTime(2026, 10, 22, 15, 31)), '3:31 PM');
      expect(at(DateTime(2026, 10, 21, 23, 59)), 'Yesterday');
      expect(at(DateTime(2026, 3, 4, 12)), 'Mar 4');
      expect(at(DateTime(2025, 12, 31, 12)), 'Dec 31, 2025');
    });

    testWidgets('a chat row shows the time, not the date, for today',
        (tester) async {
      final now = DateTime.now();
      final state = _connectedState(_FakeApi())
        ..conversations = <Conversation>[
          Conversation(
            id: 'conv_1',
            kind: 'group',
            title: 'Family',
            lastMessageAt: now,
          ),
        ]
        ..conversationsLoaded = true;
      await tester.pumpWidget(_app(ChatListScreen(state: state)));
      final context = tester.element(find.text('Family'));
      expect(find.text(formatTimeOfDay(context, now)), findsOneWidget);
      expect(find.text(formatDate(context, now)), findsNothing);
    });
  });

  test('shell breakpoints follow the Material 3 window classes', () {
    expect(shellLayoutFor(360), ShellLayout.compact);
    expect(shellLayoutFor(599), ShellLayout.compact);
    expect(shellLayoutFor(600), ShellLayout.rail);
    expect(shellLayoutFor(839), ShellLayout.rail);
    expect(shellLayoutFor(840), ShellLayout.workspace);
  });

  test('display names are checked the way the server checks them', () {
    expect(displayNameError(''), isNotNull);
    expect(displayNameError('   '), isNotNull);
    expect(displayNameError('  Family  '), isNull);
    expect(displayNameError('a' * maxDisplayNameBytes), isNull);
    expect(displayNameError('a' * (maxDisplayNameBytes + 1)), isNotNull);
    // 33 two-byte characters are 66 bytes: over, though only 33 long.
    expect(displayNameError('é' * 33), isNotNull);
  });

  group('composer', () {
    testWidgets('an over-long draft is flagged inline and kept, not cut',
        (tester) async {
      final state = _groupState(_FakeApi());
      await tester.pumpWidget(_app(
        ChatScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pumpAndSettle();

      final draft = 'x' * (maxAppTextLength + 1);
      await tester.enterText(find.byType(TextField), draft);
      await tester.pump();

      expect(find.text(messageTooLongText), findsOneWidget);
      expect(
        find.text('${maxAppTextLength + 1} / $maxAppTextLength'),
        findsOneWidget,
      );
      expect(_sendButton(tester).onPressed, isNull);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        draft,
      );

      await tester.enterText(find.byType(TextField), 'short');
      await tester.pump();
      expect(find.text(messageTooLongText), findsNothing);
      expect(_sendButton(tester).onPressed, isNotNull);
    });

    testWidgets('the unavailable attachment reason is reachable by focus',
        (tester) async {
      final state = _groupState(_FakeApi());
      expect(state.attachmentsAvailable, isFalse);
      await tester.pumpWidget(_app(
        ChatScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pumpAndSettle();

      final attach = tester.widget<IconButton>(find.ancestor(
        of: find.byIcon(Icons.attach_file),
        matching: find.byType(IconButton),
      ));
      expect(attach.onPressed, isNull, reason: 'the control stays disabled');
      expect(find.text(attachmentsUnavailableReason), findsNothing);

      final gate = find.byType(GatedExplanation);
      expect(gate, findsOneWidget);
      // The wrapper's own node, not the disabled button's.
      final focus = Focus.of(tester.element(find
          .descendant(of: gate, matching: find.byType(DecoratedBox))
          .first));
      expect(focus.canRequestFocus, isTrue);
      focus.requestFocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(attachmentsUnavailableReason), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 2));
    });
  });

  testWidgets(
      'jump to latest returns to the newest message without '
      'dropping loaded history', (tester) async {
    final api = _FakeApi();
    final state = _groupState(api)
      ..messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
        'conv_1': <ReceivedMessageEnvelope>[
          for (var i = 80; i > 0; i--)
            _message('m$i', DateTime.utc(2026, 9, 24, 10, i)),
        ],
      };
    await tester.pumpWidget(_app(
      ChatScreen(state: state, conversationId: 'conv_1'),
    ));
    await tester.pumpAndSettle();
    final loaded = state.timelineFor('conv_1').length;
    expect(find.byTooltip('Jump to latest'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 1500));
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    final controller = tester.widget<ListView>(list).controller!;
    expect(controller.offset, greaterThan(480));
    expect(find.byTooltip('Jump to latest'), findsOneWidget);

    await tester.tap(find.byTooltip('Jump to latest'));
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
    expect(find.byTooltip('Jump to latest'), findsNothing);
    expect(state.timelineFor('conv_1'), hasLength(loaded));
    expect(api.pageRequests, isEmpty, reason: 'nothing was refetched');
  });

  testWidgets('a chat row offers mute and details on long press',
      (tester) async {
    final api = _FakeApi();
    final state = _connectedState(api)
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group', title: 'Family'),
      ]
      ..conversationsLoaded = true;
    await tester.pumpWidget(_app(ChatListScreen(state: state)));

    await tester.longPress(find.text('Family'));
    await tester.pumpAndSettle();
    expect(find.text('Conversation details'), findsOneWidget);
    // Only already-supported actions: nothing that needs message content.
    expect(find.textContaining('Delete'), findsNothing);
    expect(find.textContaining('Search'), findsNothing);

    await tester.tap(find.text('Mute notifications'));
    await tester.pumpAndSettle();
    expect(api.mutedConversations['conv_1'], isTrue);
    expect(state.isMuted('conv_1'), isTrue);
  });

  testWidgets('a community name is validated before Create enables',
      (tester) async {
    final state = _connectedState(_FakeApi());
    await tester.pumpWidget(_app(CommunityScreen(state: state)));
    await tester.tap(find.text('New community'));
    // The screen behind may show a spinner, so settle on the dialog only.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    FilledButton create() => tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'));
    expect(create().onPressed, isNull);
    expect(find.text('Enter a name.'), findsNothing);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(find.text('Enter a name.'), findsOneWidget);
    expect(create().onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'x' * 65);
    await tester.pump();
    expect(find.text('That name is too long.'), findsOneWidget);
    expect(create().onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Neighbours');
    await tester.pump();
    expect(create().onPressed, isNotNull);
  });

  testWidgets('the new conversation form validates inline', (tester) async {
    final api = _FakeApi();
    final state = _connectedState(api);
    await tester.pumpWidget(_app(Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => showNewConversationSheet(context, state),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Group'));
    await tester.pumpAndSettle();
    // An untouched form does not open in red.
    expect(find.text('Enter a group name.'), findsNothing);

    await tester.tap(find.text('Create group'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a group name.'), findsOneWidget);
    expect(find.text('Add at least one other member.'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(api.createdConversations, isEmpty);

    await tester.enterText(
      find.widgetWithText(TextField, 'Group name'),
      'Family',
    );
    await tester.pump();
    expect(find.text('Enter a group name.'), findsNothing);
  });
}

Widget _app(Widget child) => MaterialApp(home: child);

IconButton _sendButton(WidgetTester tester) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.send),
        matching: find.byType(IconButton),
      ),
    );

ReceivedMessageEnvelope _message(String id, DateTime createdAt) {
  return ReceivedMessageEnvelope.fromJson(<String, Object?>{
    'id': id,
    'conversation_id': 'conv_1',
    'sender_account_id': 'acct_other',
    'sender_device_id': 'dev_other',
    'idempotency_key': id,
    'ciphertext': '',
    'crypto_protocol': 'test',
    'created_at': createdAt.toIso8601String(),
  });
}

AppState _groupState(ApiClient api) => _connectedState(api)
  ..conversations = <Conversation>[
    Conversation(id: 'conv_1', kind: 'group'),
  ];

AppState _connectedState(ApiClient api) {
  return AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _FakeSyncService(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost:8080',
      token: 'owner-token',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
    );
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(baseUrl: 'https://localhost:8080');

  List<String?> pageRequests = <String?>[];
  List<String> createdConversations = <String>[];
  Map<String, bool> mutedConversations = <String, bool>{};

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async {
    pageRequests.add(before);
    return const MessagePage(messages: <ReceivedMessageEnvelope>[]);
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
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[];

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
  Future<void> dispose() async {
    await _controller.close();
  }
}
