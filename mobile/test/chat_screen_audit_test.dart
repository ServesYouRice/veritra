import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/call_controller.dart';
import 'package:private_messenger/calls/call_service.dart';
import 'package:private_messenger/features/chat/conversation_details_screen.dart';
import 'package:private_messenger/features/chat/message_ticks.dart';
import 'package:private_messenger/features/chat/sender_colors.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/receipts_state.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/formatted_message.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/tokens.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'call_service_fakes.dart';
import 'goldens/golden_harness.dart';

/// UI-audit cards U7, U13, U14, U29 and U36 on the chat screen.
void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'U14: your own bubble is filled with the plum token, $brightness',
      (tester) async {
        final store = MemoryLocalStore(), state = _state();
        state.localStoreOverride = store;
        await _seed(store);
        await state.refreshHistory('conv');
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: ChatScreen(state: state, conversationId: 'conv'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.ancestor(
            of: find.text('hello'),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Container &&
                  (widget.decoration as BoxDecoration?)?.color ==
                      BoneColors.ownBubble(brightness),
            ),
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
  }

  testWidgets('U13: "encrypted" is said once, at the start of the chat', (
    tester,
  ) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(
      store,
      extra: [
        for (var i = 0; i < 3; i++)
          InsertMessageEffect(
            key: 'dev:m$i',
            conversationId: 'conv',
            senderAccountId: i.isEven ? 'alice' : 'bob',
            senderDeviceId: 'dev',
            kind: LocalMessageKind.text,
            body: 'body $i',
            createdAt: 2 + i,
            state: LocalMessageState.received,
          ),
      ],
    );
    await state.refreshHistory('conv');
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(state: state, conversationId: 'conv'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FormattedMessage), findsNWidgets(4));
    // One notice, and it is the only padlock: no header line, no per-bubble
    // lock.
    final notice = find.byKey(const Key('chat-encryption-notice'));
    expect(notice, findsOneWidget);
    expect(find.text(englishL10n.chatNoticeEncryptedDm), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.textContaining('ENCRYPTED'), findsNothing);
    // It opens the chat: above the oldest message.
    expect(
      tester.getBottomLeft(notice).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.text('hello')).dy),
    );
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('U13: a muted chat keeps a plain Muted line in its header', (
    tester,
  ) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(state: state, conversationId: 'conv'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.chatStatusMuted), findsNothing);
    await state.setConversationMuted('conv', true);
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.chatStatusMuted), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  for (final (kind, dm) in <(String, bool)>[('dm', true), ('group', false)]) {
    testWidgets('U36: an empty $kind chat says who can read it', (
      tester,
    ) async {
      final state = _state()
        ..conversations = [
          Conversation(
            id: 'conv',
            kind: kind,
            title: 'Team',
            createdBy: 'alice',
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(state: state, conversationId: 'conv'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          dm
              ? englishL10n.chatEmptyMessageDm
              : englishL10n.chatEmptyMessageGroup,
        ),
        findsOneWidget,
      );
      expect(englishL10n.chatEmptyMessageDm, 'Only you two can read this.');
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  group('U29: chat screen tidy', () {
    // A real Roboto, when the Flutter SDK has one: the test font draws every
    // glyph as a full-width square, so "12 characters fit" can only be asked
    // of real glyph widths.
    Future<bool> loadRoboto() async {
      final root = Platform.environment['FLUTTER_ROOT'];
      if (root == null) return false;
      final dir = '$root/bin/cache/artifacts/material_fonts';
      final files = <String>[
        '$dir/Roboto-Regular.ttf',
        '$dir/Roboto-Medium.ttf',
      ];
      if (!files.every((path) => File(path).existsSync())) return false;
      final loader = FontLoader('Roboto');
      for (final path in files) {
        loader.addFont(
          Future<ByteData>.value(
            ByteData.sublistView(File(path).readAsBytesSync()),
          ),
        );
      }
      await loader.load();
      return true;
    }

    testWidgets(
      'a 12-character name fits beside the call buttons at 360 dp and opens the details',
      (tester) async {
        final haveRoboto = await tester.runAsync(loadRoboto) ?? false;
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const name = 'Konstantinop';
        expect(name, hasLength(12));
        final state = _state()
          ..conversations = [
            Conversation(
              id: 'conv',
              kind: 'dm',
              title: name,
              createdBy: 'alice',
            ),
          ];
        final log = <String>[];
        final controller = CallController(
          service: NativeCallService(
            api: FakeCallApi(log),
            token: 't',
            crypto: FakeCallCrypto(log),
            incoming: const Stream.empty(),
            media: FakeMediaFactory(log),
          ),
          selfAccountId: 'alice',
        );
        state.callController.value = controller;
        addTearDown(controller.dispose);
        var theme = veritraLightTheme();
        if (haveRoboto) {
          theme = theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
            appBarTheme: theme.appBarTheme.copyWith(
              titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                fontFamily: 'Roboto',
              ),
            ),
          );
        }
        // Pushed, as on a phone, so the bar carries a back button too.
        await tester.pumpWidget(
          MaterialApp(theme: theme, home: const SizedBox()),
        );
        unawaited(
          tester.state<NavigatorState>(find.byType(Navigator)).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ChatScreen(state: state, conversationId: 'conv'),
                ),
              ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(BackButton), findsOneWidget);

        // The call buttons are there, and so is the menu; star and info are not
        // bars of their own.
        expect(find.byKey(const Key('chat-call-voice')), findsOneWidget);
        expect(find.byKey(const Key('chat-call-video')), findsOneWidget);
        expect(find.byKey(const Key('chat-menu')), findsOneWidget);
        expect(find.byIcon(Icons.star_outline), findsNothing);
        expect(find.byIcon(Icons.info_outline), findsNothing);

        final title = find.text(name);
        expect(title, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(title);
        final width = tester.getSize(title).width;
        final fontSize = paragraph.text.style?.fontSize ?? 17;
        if (haveRoboto) {
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: 'the name is cut with an ellipsis',
          );
          final painter = TextPainter(
            text: paragraph.text,
            textDirection: TextDirection.ltr,
          )..layout();
          expect(painter.width, lessThanOrEqualTo(width));
        } else {
          // Without a real font, hold the line the budget draws: 12 average
          // glyphs of 0.55 em.
          expect(width, greaterThanOrEqualTo(12 * 0.55 * fontSize));
        }

        // Tapping the name opens the details.
        await tester.tap(title);
        await tester.pumpAndSettle();
        expect(find.byType(ConversationDetailsScreen), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );

    testWidgets('star and info open from one menu', (tester) async {
      final store = MemoryLocalStore(), state = _state();
      state.localStoreOverride = store;
      await _seed(store);
      await state.refreshHistory('conv');
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(state: state, conversationId: 'conv'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-menu')));
      await tester.pumpAndSettle();
      expect(find.text(englishL10n.w8StarredMessages), findsOneWidget);
      expect(find.text(englishL10n.chatListDetails), findsOneWidget);
      await tester.tap(find.text(englishL10n.chatListDetails));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationDetailsScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    test('sent, delivered and read ticks differ by shape', () {
      final glyphs = MessageTick.values.map(messageTickGlyph).toSet();
      expect(glyphs, hasLength(MessageTick.values.length));
    });

    testWidgets('one + holds files and polls, and the mic turns into Send', (
      tester,
    ) async {
      final state = _state(attachments: true);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(state: state, conversationId: 'conv'),
        ),
      );
      await tester.pumpAndSettle();
      // One +, no loose attach or poll buttons.
      expect(find.byKey(const Key('composer-add')), findsOneWidget);
      expect(find.byIcon(Icons.attach_file), findsNothing);
      expect(find.byIcon(Icons.poll_outlined), findsNothing);
      await tester.tap(find.byKey(const Key('composer-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer-add-file')), findsOneWidget);
      expect(find.byKey(const Key('composer-add-poll')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Empty: the mic. A character: Send, and the mic is gone.
      expect(find.byKey(const Key('composer-mic')), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      expect(find.byKey(const Key('composer-mic')), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.byKey(const Key('composer-mic')), findsOneWidget);
      state.flushDrafts();
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    testWidgets('a failed send reads "Not sent · Retry" and the line retries', (
      tester,
    ) async {
      final state = _state();
      state.pendingOutbox = [
        MessageEnvelope(
          conversationId: 'conv',
          idempotencyKey: 'k1',
          ciphertext: const [1],
          cryptoProtocol: 'test',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(state: state, conversationId: 'conv'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Not sent · Retry'), findsOneWidget);
      expect(find.text(englishL10n.chatPendingNotSentRetry), findsOneWidget);
      expect(find.text(englishL10n.commonRetry), findsNothing);
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.byKey(const Key('pending-not-sent-retry')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  });

  group('U36: small polish', () {
    testWidgets('a message request says what the sender can see', (
      tester,
    ) async {
      final state = _state()
        ..conversations = [
          Conversation(
            id: 'conv',
            kind: 'dm',
            peerAccountId: 'bob',
            peerUsername: 'bob',
            createdBy: 'bob',
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(state: state, conversationId: 'conv'),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('request-shared'));
      expect(card, findsOneWidget);
      for (final text in <String>[
        englishL10n.requestSharedTitle,
        englishL10n.requestSharedNow,
        englishL10n.requestSharedAccept,
        englishL10n.requestSharedDelete,
      ]) {
        expect(
          find.descendant(of: card, matching: find.text(text)),
          findsOneWidget,
        );
      }
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    testWidgets('a swipe across a message opens its actions', (tester) async {
      final store = MemoryLocalStore(), state = _state();
      state.localStoreOverride = store;
      await _seed(store);
      await state.refreshHistory('conv');
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(state: state, conversationId: 'conv'),
        ),
      );
      await tester.pumpAndSettle();
      // Too short, too vertical and the wrong way do nothing.
      for (final offset in <Offset>[
        const Offset(-30, 0),
        const Offset(-120, 80),
        const Offset(120, 0),
      ]) {
        await tester.drag(find.text('hello'), offset, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(
          find.text(englishL10n.chatCopyText),
          findsNothing,
          reason: '$offset',
        );
      }
      // Toward the start of the line, far enough and quick enough.
      await tester.drag(find.text('hello'), const Offset(-140, 4));
      await tester.pumpAndSettle();
      expect(find.text(englishL10n.chatCopyText), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    testWidgets('the call relay note lives in Settings, not on a call screen', (
      tester,
    ) async {
      setWindowSize(tester, phoneSize);
      final state = await connectedState();
      await tester.pumpWidget(veritraTestApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.settings_outlined).first);
      await tester.pumpAndSettle();
      final note = find.text(englishL10n.settingsCallsRelayNote);
      await tester.scrollUntilVisible(
        note,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(note, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('settings-calls-relay')),
        findsOneWidget,
      );
    });

    for (final brightness in Brightness.values) {
      testWidgets('group sender names take one colour each, $brightness', (
        tester,
      ) async {
        // Two senders whose IDs land in different colour slots.
        final senders = <String>['bob', 'carol', 'dave', 'erin']
            .where((id) => senderColorSlot(id) != senderColorSlot('bob'))
            .take(1)
            .toList()
          ..insert(0, 'bob');
        expect(senderColorSlot(senders[0]), isNot(senderColorSlot(senders[1])));
        final store = MemoryLocalStore(), state = _state();
        state.localStoreOverride = store;
        state.conversations = [
          Conversation(
            id: 'conv',
            kind: 'group',
            title: 'Team',
            createdBy: 'alice',
          ),
        ];
        await _seed(
          store,
          extra: [
            for (var i = 0; i < senders.length; i++)
              InsertMessageEffect(
                key: 'dev:${senders[i]}',
                conversationId: 'conv',
                senderAccountId: senders[i],
                senderDeviceId: 'dev_${senders[i]}',
                kind: LocalMessageKind.text,
                body: 'from ${senders[i]}',
                createdAt: 2 + i,
                state: LocalMessageState.received,
              ),
          ],
        );
        await state.refreshHistory('conv');
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: ChatScreen(state: state, conversationId: 'conv'),
          ),
        );
        await tester.pumpAndSettle();
        Color? nameColor(String id) {
          final names = find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.data != null &&
                widget.data!.contains(id.substring(0, 3)) &&
                widget.style?.fontWeight == FontWeight.w600,
          );
          expect(names, findsOneWidget, reason: id);
          return tester.widget<Text>(names).style?.color;
        }

        expect(nameColor(senders[0]), senderNameColor(senders[0], brightness));
        expect(nameColor(senders[1]), senderNameColor(senders[1], brightness));
        expect(nameColor(senders[0]), isNot(nameColor(senders[1])));
        // Normal small text, not the capitalised micro style.
        final label = tester.widget<Text>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.data != null &&
                widget.data!.contains(senders[0].substring(0, 3)) &&
                widget.style?.fontWeight == FontWeight.w600,
          ),
        );
        final textTheme = Theme.of(
          tester.element(find.byType(ChatScreen)),
        ).textTheme;
        expect(label.style?.fontSize, textTheme.bodySmall?.fontSize);
        expect(label.style?.letterSpacing, textTheme.bodySmall?.letterSpacing);
        expect(
          label.style?.letterSpacing,
          isNot(textTheme.labelSmall?.letterSpacing),
        );
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      });
    }
  });

  testWidgets('U7: a long-press on the message text opens the action sheet', (
    tester,
  ) async {
    final store = MemoryLocalStore(), state = _state();
    state.localStoreOverride = store;
    await _seed(store);
    await state.refreshHistory('conv');
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(state: state, conversationId: 'conv'),
      ),
    );
    await tester.pumpAndSettle();
    // The text itself, not the bubble's padding.
    await tester.longPress(find.text('hello'));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.chatCopyText), findsOneWidget);
    expect(find.text(englishL10n.chatSelectText), findsOneWidget);
    // Selecting happens inside the sheet that "Select text" opens.
    await tester.tap(find.text(englishL10n.chatSelectText));
    await tester.pumpAndSettle();
    final selectable = find.byKey(const Key('select-text'));
    expect(selectable, findsOneWidget);
    expect(
      find.descendant(of: selectable, matching: find.byType(SelectableText)),
      findsOneWidget,
    );
    // No bubble in the thread is selectable by itself.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}

class _UiState extends AppState {
  _UiState._(this.stub, {bool attachments = false})
      : super(
          apiClientFactory: (_) => _UiApi(),
          cryptoService: stub,
          localStore: MemoryLocalStore(),
          attachmentService:
              attachments ? AttachmentCryptoService(_NoBindings()) : null,
          syncServiceFactory: (_, __) => _QuietSync(),
        );
  factory _UiState([_MlsStub? stub, bool attachments = false]) =>
      _UiState._(stub ?? _MlsStub(), attachments: attachments);
  final _MlsStub stub;
  LocalStore? localStoreOverride;
  @override
  LocalStore get localStore => localStoreOverride ?? super.localStore;
}

class _UiApi extends ApiClient {
  _UiApi() : super(baseUrl: 'https://example.test');
  @override
  Future<ConversationMute> setConversationMute(
    String token,
    String conversationId, {
    required bool muted,
    Duration? forDuration,
  }) async =>
      ConversationMute(muted: muted);
  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}
  @override
  Future<List<ConversationMember>> conversationMembers(
    String token,
    String conversationId,
  ) async =>
      const [];
}

class _NoBindings implements NativeCryptoBindings {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

_UiState _state({bool attachments = false}) {
  final stub = _MlsStub();
  return _UiState(stub, attachments)
    ..api = _UiApi()
    ..session = const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'alice',
      deviceId: 'dev',
    )
    ..conversations = [
      Conversation(id: 'conv', kind: 'dm', title: 'Team', createdBy: 'alice'),
    ]
    ..conversationsLoaded = true;
}

Future<void> _seed(
  LocalStore store, {
  String messageState = LocalMessageState.received,
  String conversationId = 'conv',
  String key = 'dev:t',
  String body = 'hello',
  String? formatJson,
  int? forwardHops,
  List<MessageEffect> extra = const [],
}) async {
  if (await store.loadCryptoState() == null) {
    await store.saveCryptoState(
      StoredCryptoState(
        counter: 1,
        stateKey: List.filled(32, 1),
        sealedState: [1],
      ),
      0,
    );
  }
  final current = (await store.loadCryptoState())!;
  final cursor = await store.loadSyncCursor();
  await store.commitMlsTransition(
    MlsStateTransition(
      messageId: 'seed-${cursor + 1}',
      conversationId: conversationId,
      expectedCounter: current.counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
        counter: current.counter + 1,
        stateKey: current.stateKey,
        sealedState: [current.counter + 1],
      ),
      cursor: cursor + 1,
      messageEffects: [
        InsertMessageEffect(
          key: key,
          conversationId: conversationId,
          senderAccountId: 'alice',
          senderDeviceId: 'dev',
          kind: LocalMessageKind.text,
          body: body,
          formatJson: formatJson,
          forwardHops: forwardHops,
          createdAt: 1,
          state: messageState,
        ),
        ...extra,
      ],
    ),
  );
}

class _MlsStub implements MlsConversationCryptoService {
  AppPayloadType? lastEncryptedType;
  Map<String, Object?>? lastEncryptedBody;

  @override
  Future<void> dispose() async {}
  @override
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const [],
    String? draftText,
  }) async {
    lastEncryptedType = type;
    lastEncryptedBody = body;
    return MessageEnvelope(
      conversationId: conversationId,
      idempotencyKey: 'action',
      ciphertext: const [1],
      cryptoProtocol: 'test',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}
