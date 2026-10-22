import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/auth/qr_scan_screen.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/new_conversation_sheet.dart';
import 'package:private_messenger/features/settings/device_link_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/app_shell.dart';
import 'package:private_messenger/ui/format.dart';
import 'package:private_messenger/ui/widgets/text_prompt_dialog.dart';
import 'package:private_messenger/ui/widgets/unavailable_reason.dart';

import 'test_crypto_service.dart';

void main() {
  test('conversation parses activity ordering and unread metadata', () {
    final conversation = Conversation.fromJson(<String, Object?>{
      'id': 'conv_1',
      'kind': 'dm',
      'created_at': '2026-06-01T10:00:00Z',
      'last_message_at': '2026-06-02T12:30:00Z',
      'unread_count': 4,
    });
    expect(conversation.unreadCount, 4);
    expect(conversation.lastMessageAt, isNotNull);
    // lastActivityAt prefers the last message time over creation.
    expect(conversation.lastActivityAt, conversation.lastMessageAt);
  });

  test('conversation defaults unread to zero and falls back to createdAt', () {
    final conversation = Conversation.fromJson(<String, Object?>{
      'id': 'conv_1',
      'kind': 'dm',
      'created_at': '2026-06-01T10:00:00Z',
    });
    expect(conversation.unreadCount, 0);
    expect(conversation.lastMessageAt, isNull);
    expect(conversation.lastActivityAt, conversation.createdAt);
  });

  test('copyWith updates unread while preserving other fields', () {
    final conversation = Conversation(
      id: 'conv_1',
      kind: 'group',
      title: 'Family',
      unreadCount: 5,
    );
    final cleared = conversation.copyWith(unreadCount: 0);
    expect(cleared.unreadCount, 0);
    expect(cleared.title, 'Family');
    expect(cleared.kind, 'group');
    expect(cleared.id, 'conv_1');
  });

  test('parseDeviceLinkCode extracts the code from a link URI', () {
    expect(
      parseDeviceLinkCode('veritra://device-link?code=ABCD1234'),
      'ABCD1234',
    );
  });

  test('parseDeviceLinkCode falls back to the raw scan for a bare code', () {
    expect(parseDeviceLinkCode('  BARECODE  '), 'BARECODE');
  });

  test('device-link QR rejects unrelated URLs and accepts HTTPS origins only',
      () {
    expect(parseDeviceLinkCode('https://example.org/not-a-link'), isEmpty);
    expect(
      parseDeviceLinkOrigin(
        'veritra://device-link?code=ABCD&origin=https%3A%2F%2Fchat.example.org',
      ),
      'https://chat.example.org',
    );
    expect(
      parseDeviceLinkOrigin(
        'veritra://device-link?code=ABCD&origin=http%3A%2F%2Flocalhost',
      ),
      isNull,
    );
  });

  test('markNewestMessageRead clears the unread badge locally', () async {
    final api = _ReadApiClient();
    final state = _connectedState(api);
    state.conversations = <Conversation>[
      Conversation(id: 'conv_1', kind: 'dm', unreadCount: 3),
      Conversation(id: 'conv_2', kind: 'dm', unreadCount: 2),
    ];
    state.messagesByConversation['conv_1'] = <ReceivedMessageEnvelope>[
      _message('m_newest'),
    ];

    await state.markNewestMessageRead('conv_1');

    expect(state.conversations[0].unreadCount, 0);
    // Untouched conversations keep their badge.
    expect(state.conversations[1].unreadCount, 2);
    expect(api.lastReadMessageId, 'm_newest');
  });

  test('per-list loaded flags flip after refresh and reset on logout',
      () async {
    final api = _ReadApiClient();
    final state = _connectedState(api);
    expect(state.communitiesLoaded, isFalse);
    expect(state.invitesLoaded, isFalse);
    expect(state.devicesLoaded, isFalse);

    await state.refreshCommunities();
    await state.refreshInvites();
    await state.refreshDevices();
    expect(state.communitiesLoaded, isTrue);
    expect(state.invitesLoaded, isTrue);
    expect(state.devicesLoaded, isTrue);

    await state.logout();
    expect(state.communitiesLoaded, isFalse);
    expect(state.invitesLoaded, isFalse);
    expect(state.devicesLoaded, isFalse);
  });

  // T44B: conversation, list and form quality.
  group('list time', () {
    testWidgets('is relative to today and follows the locale formatters',
        (tester) async {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (built) {
          context = built;
          return const SizedBox();
        }),
      ));
      final now = DateTime(2026, 10, 22, 15, 30);
      final localizations = MaterialLocalizations.of(context);

      final earlierToday = DateTime(2026, 10, 22, 9, 5);
      expect(
        formatListTimestamp(context, earlierToday, now: now),
        localizations.formatTimeOfDay(TimeOfDay.fromDateTime(earlierToday)),
      );
      expect(
        formatListTimestamp(context, DateTime(2026, 10, 21, 23, 59), now: now),
        'Yesterday',
      );
      expect(
        formatListTimestamp(context, DateTime(2026, 10, 2), now: now),
        localizations.formatShortMonthDay(DateTime(2026, 10, 2)),
      );
      // An older year carries its year, which the old medium date dropped.
      expect(
        formatListTimestamp(context, DateTime(2025, 10, 20), now: now),
        allOf(contains('2025'),
            localizations.formatShortDate(DateTime(2025, 10, 20))),
      );
      expect(
        formatDayLabel(context, DateTime(2026, 10, 22, 1), now: now),
        'Today',
      );
      expect(
        formatDayLabel(context, DateTime(2025, 10, 22), now: now),
        contains('2025'),
      );
      // A daylight-saving night is still one calendar day.
      expect(
        calendarDaysBefore(DateTime(2026, 3, 28, 23), DateTime(2026, 3, 29, 1)),
        1,
      );
    });

    testWidgets('a row shows today\'s time at 320dp and 200% text',
        (tester) async {
      _phone(tester, textScale: 2);
      final state = _connectedState(_QualityApi())
        ..conversations = <Conversation>[
          Conversation(
            id: 'conv_1',
            kind: 'group',
            title: 'Family',
            lastMessageAt: DateTime.now(),
            unreadCount: 3,
            retentionSeconds: 86400,
          ),
        ];
      await tester.pumpWidget(MaterialApp(home: ChatListScreen(state: state)));
      await tester.pump();

      final context = tester.element(find.byType(ChatListScreen));
      expect(
        find.text(formatTimeOfDay(context, DateTime.now())),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('breakpoints', () {
    Future<void> pumpShell(WidgetTester tester, double width) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      final state = _connectedState(_QualityApi())
        ..lifecycle = SessionLifecycle.ready
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group', title: 'Family'),
        ];
      await tester.pumpWidget(MaterialApp(home: AppShell(state: state)));
      await tester.pump();
    }

    testWidgets('a phone keeps the bottom nav and one pane', (tester) async {
      await pumpShell(tester, 320);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('No conversation selected'), findsNothing);
    });

    testWidgets('medium width gets the rail but not a cramped split',
        (tester) async {
      // 720dp used to split, leaving the conversation under 300dp.
      await pumpShell(tester, 720);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('No conversation selected'), findsNothing);
    });

    testWidgets('expanded width shows list and conversation side by side',
        (tester) async {
      await pumpShell(tester, twoPaneBreakpoint);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('No conversation selected'), findsOneWidget);
    });
  });

  group('jump to latest', () {
    testWidgets('returns to the newest message and keeps loaded history',
        (tester) async {
      _phone(tester);
      final api = _QualityApi();
      final history = <ReceivedMessageEnvelope>[
        for (var i = 80; i > 0; i--) _timedMessage('m$i', i),
      ];
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ]
        ..messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
          'conv_1': history,
        };
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pump();

      final jump = find.byTooltip('Jump to latest messages');
      expect(jump, findsNothing);
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      position.jumpTo(2000);
      await tester.pump();
      expect(jump, findsOneWidget);
      expect(find.text('New messages'), findsNothing);

      // A newer message arrives through a refresh while the reader is back
      // in history: the control says so, and nothing loaded is dropped.
      api.newestPage = MessagePage(
        messages: <ReceivedMessageEnvelope>[
          _timedMessage('m81', 81),
          ...history.take(49),
        ],
        nextBefore: 'older',
      );
      await state.loadMessages('conv_1');
      await tester.pump();
      expect(find.text('New messages'), findsOneWidget);
      expect(state.timelineFor('conv_1'), hasLength(81));

      await tester.tap(find.text('New messages'));
      await tester.pumpAndSettle();
      expect(position.pixels, 0);
      expect(find.text('New messages'), findsNothing);
      expect(jump, findsNothing);
      expect(state.timelineFor('conv_1'), hasLength(81));
      expect(state.timelineFor('conv_1').last.id, 'm1');
    });
  });

  group('gated controls', () {
    testWidgets('the attachment reason is reachable by keyboard and reader',
        (tester) async {
      final state = _connectedState(_QualityApi())
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ];
      expect(state.attachmentsAvailable, isFalse);
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pump();

      final attach = tester.widget<IconButton>(find.ancestor(
        of: find.byIcon(Icons.attach_file),
        matching: find.byType(IconButton),
      ));
      // Still a disabled control: explaining the gate never opens it.
      expect(attach.onPressed, isNull);
      expect(find.byTooltip(attachmentsUnavailableReason), findsOneWidget);
      expect(
        tester.getSemantics(find.byIcon(Icons.attach_file)),
        matchesSemantics(
          tooltip: attachmentsUnavailableReason,
          isButton: true,
          hasEnabledState: true,
        ),
      );

      final reason = find.descendant(
        of: find.byType(UnavailableReason),
        matching: find.byType(Focus),
      );
      final node = Focus.of(tester.element(find.descendant(
        of: reason.first,
        matching: find.byType(Tooltip),
      )));
      var tabs = 0;
      while (!node.hasFocus && tabs < 8) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        tabs++;
      }
      expect(node.hasFocus, isTrue, reason: 'Tab never reached the reason');
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.descendant(
          of: find.byType(Overlay),
          matching: find.text(attachmentsUnavailableReason),
        ),
        findsOneWidget,
      );
    });
  });

  group('inline validation', () {
    testWidgets('a new group is checked under its fields, not in a snack bar',
        (tester) async {
      _phone(tester, textScale: 2);
      final api = _QualityApi();
      final state = _connectedState(api);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNewConversationSheet(context, state),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Group'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create group'));
      await tester.tap(find.text('Create group'));
      await tester.pumpAndSettle();

      expect(find.text('Give the group a name.'), findsOneWidget);
      expect(find.text('Add at least one other member.'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(api.createdConversations, 0);

      await tester.enterText(
        find.widgetWithText(TextField, 'Group name'),
        'Family',
      );
      await tester.pumpAndSettle();
      expect(find.text('Give the group a name.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a prompt stays open and explains an invalid value',
        (tester) async {
      _phone(tester, textScale: 2);
      String? result = 'unset';
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showTextPromptDialog(
                  context,
                  title: 'Verification code',
                  label: 'Code shown on the new device',
                  confirmLabel: 'Approve',
                  validator: validateVerificationCode,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(
          find.text('Enter the code shown on the new device.'), findsOneWidget);
      expect(find.text('Verification code'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '12ab');
      await tester.pumpAndSettle();
      expect(find.text('The code is digits only.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), ' 12345678 ');
      await tester.pumpAndSettle();
      expect(find.text('The code is digits only.'), findsNothing);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(result, '12345678');
      expect(tester.takeException(), isNull);
    });
  });

  group('composer length and keys', () {
    Future<AppState> pumpComposer(WidgetTester tester) async {
      final state = _connectedState(_QualityApi())
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ];
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(state: state, conversationId: 'conv_1'),
      ));
      await tester.pump();
      return state;
    }

    String composerText(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    IconButton sendButton(WidgetTester tester) =>
        tester.widget<IconButton>(find.ancestor(
          of: find.byIcon(Icons.send),
          matching: find.byType(IconButton),
        ));

    testWidgets('shows the count near the limit and refuses, not truncates',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      _phone(tester, textScale: 2);
      await pumpComposer(tester);

      await tester.enterText(
          find.byType(TextField), 'a' * (messageCounterThreshold - 1));
      await tester.pump();
      expect(find.textContaining('/ 4,000'), findsNothing);

      await tester.enterText(
          find.byType(TextField), 'a' * messageCounterThreshold);
      await tester.pump();
      expect(find.text('3,600 / 4,000'), findsOneWidget);
      expect(sendButton(tester).onPressed, isNotNull);

      final tooLong = '${'a' * maxMessageLength}bc';
      await tester.enterText(find.byType(TextField), tooLong);
      await tester.pump();
      expect(find.text('4,002 / 4,000 · shorten to send'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('too long to send')), findsWidgets);
      expect(sendButton(tester).onPressed, isNull);

      // Enter neither sends nor cuts the text short.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(composerText(tester), tooLong);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Ctrl+Enter sends from a hardware keyboard on Android',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final state = await pumpComposer(tester);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      // Plain Enter is a newline on a phone, never a send.
      expect(composerText(tester), isNotEmpty);
      expect(state.pendingFor('conv_1'), isEmpty);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(composerText(tester), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    test('the limit always fits the encrypted payload', () {
      // Worst case: every code point JSON-escaped to six bytes.
      expect(maxMessageLength * 6, lessThan(64 * 1024 - 1024));
      expect(messageLengthProblem('a' * maxMessageLength), isNull);
      expect(messageLengthProblem('😀' * maxMessageLength), isNull);
      expect(messageLengthProblem('a' * (maxMessageLength + 1)), isNotNull);
    });
  });

  group('row actions', () {
    testWidgets('a long-press offers only supported actions', (tester) async {
      _phone(tester, textScale: 2);
      final api = _QualityApi();
      final state = _connectedState(api)
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group', title: 'Family'),
        ];
      await tester.pumpWidget(MaterialApp(home: ChatListScreen(state: state)));
      await tester.pump();

      await tester.longPress(find.text('Family'));
      await tester.pumpAndSettle();
      expect(find.text('Mute notifications'), findsOneWidget);
      expect(find.text('Conversation details'), findsOneWidget);
      for (final unsupported in <String>['Pin', 'Archive', 'Delete']) {
        expect(find.textContaining(unsupported), findsNothing);
      }

      await tester.tap(find.text('Mute notifications'));
      await tester.pumpAndSettle();
      expect(api.muted['conv_1'], isTrue);
      expect(state.isMuted('conv_1'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the row exposes its actions to a screen reader',
        (tester) async {
      final handle = tester.ensureSemantics();
      final state = _connectedState(_QualityApi())
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group', title: 'Family'),
        ];
      await tester.pumpWidget(MaterialApp(home: ChatListScreen(state: state)));
      await tester.pump();

      expect(
        tester.getSemantics(find.text('Family')),
        isSemantics(
          customActions: <CustomSemanticsAction>[
            const CustomSemanticsAction(label: 'Conversation actions'),
          ],
        ),
      );
      handle.dispose();
    });
  });

  testWidgets('chat list shows a typed load error with retry, not a spinner',
      (tester) async {
    final api = _ReadApiClient()
      ..conversationFailure = ApiException(503, 'upstream $_leakedDetail');
    final state = _connectedState(api);
    await tester.runAsync(state.refreshConversations);

    await tester.pumpWidget(MaterialApp(
      home: AnimatedBuilder(
        animation: state,
        builder: (context, _) => ChatListScreen(state: state),
      ),
    ));
    expect(find.text('Couldn’t load conversations'), findsOneWidget);
    expect(find.text('The server had a problem. Try again shortly.'),
        findsOneWidget);
    expect(find.textContaining(_leakedDetail), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(find.text('Retry'));
      await state.refreshConversations();
    });
    await tester.pump();
    expect(find.text('Couldn’t load conversations'), findsNothing);
    expect(find.text('No conversations yet'), findsOneWidget);
  });
}

ReceivedMessageEnvelope _message(String id) {
  return ReceivedMessageEnvelope.fromJson(<String, Object?>{
    'id': id,
    'conversation_id': 'conv_1',
    'sender_account_id': 'acct_other',
    'sender_device_id': 'dev_other',
    'idempotency_key': id,
    'ciphertext': '',
    'crypto_protocol': 'test',
    'created_at': '2026-06-02T12:30:00Z',
  });
}

const _leakedDetail = 'raw-server-body-detail';

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
    );
}

class _ReadApiClient extends ApiClient {
  _ReadApiClient() : super(baseUrl: 'https://localhost:8080');

  String? lastReadMessageId;
  Object? conversationFailure;

  @override
  Future<List<Conversation>> conversations(String token) async {
    final failure = conversationFailure;
    conversationFailure = null;
    if (failure != null) throw failure;
    return <Conversation>[];
  }

  @override
  Future<void> markRead(
    String token,
    String conversationId,
    String messageId,
  ) async {
    lastReadMessageId = messageId;
  }

  @override
  Future<List<Community>> listCommunities(String token) async {
    return <Community>[];
  }

  @override
  Future<List<Invite>> listInvites(String token) async {
    return <Invite>[];
  }

  @override
  Future<List<Device>> devices(String token) async {
    return <Device>[];
  }

  @override
  Future<void> logout(String token) async {}
}

class _FakeSyncService implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {
    _controller.close();
  }
}

/// A 320dp phone, optionally at a larger text scale.
void _phone(WidgetTester tester, {double textScale = 1}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 640);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

ReceivedMessageEnvelope _timedMessage(String id, int minute) {
  return ReceivedMessageEnvelope.fromJson(<String, Object?>{
    'id': id,
    'conversation_id': 'conv_1',
    'sender_account_id': 'acct_other',
    'sender_device_id': 'dev_other',
    'idempotency_key': id,
    'ciphertext': '',
    'crypto_protocol': 'test',
    'created_at': DateTime.utc(2026, 9, 24, 8)
        .add(Duration(minutes: minute))
        .toIso8601String(),
  });
}

class _QualityApi extends _ReadApiClient {
  MessagePage newestPage =
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);
  int createdConversations = 0;
  final Map<String, bool> muted = <String, bool>{};

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      before == null
          ? newestPage
          : const MessagePage(messages: <ReceivedMessageEnvelope>[]);

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}

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
    createdConversations++;
    return Conversation(id: 'conv_new', kind: kind, title: title);
  }

  @override
  Future<bool> setConversationMuted(
    String token,
    String conversationId,
    bool muted,
  ) async {
    this.muted[conversationId] = muted;
    return muted;
  }
}
