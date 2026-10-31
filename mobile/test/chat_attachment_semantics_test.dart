// Assistive technology must reach the attachments inside a chat bubble
// (TASK-067): each tile is its own node with the file name and a tap action,
// while a text bubble keeps its single merged label.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/features/chat/attachment_views.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/formatted_message.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

class _NoBindings implements NativeCryptoBindings {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _State extends AppState {
  _State()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://example.test'),
          cryptoService: _MlsStub(),
          localStore: MemoryLocalStore(),
          attachmentService: AttachmentCryptoService(_NoBindings()),
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  LocalStore? localStoreOverride;

  @override
  LocalStore get localStore => localStoreOverride ?? super.localStore;
}

class _MlsStub implements MlsConversationCryptoService {
  @override
  Future<void> dispose() async {}

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

Map<String, Object?> _attachment(String id, String name, String type) =>
    <String, Object?>{
      'id': id,
      'conversation_id': 'conv',
      'file_name': name,
      'media_type': type,
      'plaintext_size': 2048,
      'ciphertext_size': 2100,
    };

Future<void> _seed(LocalStore store) async {
  await store.saveCryptoState(
    StoredCryptoState(
        counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
    0,
  );
  await store.commitMlsTransition(MlsStateTransition(
    messageId: 'seed',
    conversationId: 'conv',
    expectedCounter: 1,
    expectedCursor: 0,
    state: StoredCryptoState(
        counter: 2, stateKey: List.filled(32, 1), sealedState: [2]),
    cursor: 1,
    messageEffects: [
      InsertMessageEffect(
        key: 'bobdev:text',
        conversationId: 'conv',
        senderAccountId: 'bob',
        senderDeviceId: 'bobdev',
        kind: LocalMessageKind.text,
        body: 'hello there',
        createdAt: 1,
        state: LocalMessageState.received,
      ),
      InsertMessageEffect(
        key: 'bobdev:files',
        conversationId: 'conv',
        senderAccountId: 'bob',
        senderDeviceId: 'bobdev',
        kind: LocalMessageKind.attachment,
        body: jsonEncode(<Object?>[
          _attachment('att_photo', 'photo.png', 'image/png'),
          _attachment('att_doc', 'report.pdf', 'application/pdf'),
        ]),
        createdAt: 2,
        state: LocalMessageState.received,
      ),
    ],
  ));
}

/// Opens the chat with one text message and one message with two
/// attachments, with semantics on, and runs [body].
Future<void> _inChat(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final semantics = tester.ensureSemantics();
  final state = _State()
    ..session = const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'alice',
      deviceId: 'dev',
    )
    ..conversations = <Conversation>[
      Conversation(id: 'conv', kind: 'dm', title: 'Team', createdBy: 'alice'),
    ]
    ..conversationsLoaded = true
    ..localStoreOverride = MemoryLocalStore();
  try {
    await _seed(state.localStoreOverride!);
    await state.refreshHistory('conv');
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(state: state, conversationId: 'conv'),
    ));
    await tester.pumpAndSettle();
    expect(state.attachmentsAvailable, isTrue);
    await body();
  } finally {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    semantics.dispose();
  }
}

Finder _tile(String name) => find.ancestor(
      of: find.text(name),
      matching: find.byType(AttachmentTile),
    );

void main() {
  testWidgets('each attachment of a bubble is a node with a tap action',
      (tester) async {
    await _inChat(tester, () async {
      final photo = tester.getSemantics(_tile('photo.png'));
      expect(photo.label, contains('photo.png'));
      expect(photo.getSemanticsData().hasAction(SemanticsAction.tap), isTrue,
          reason: 'the image tile can be activated');
      final pdf = tester.getSemantics(_tile('report.pdf'));
      expect(pdf.label, contains('report.pdf'));
      expect(pdf.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(photo.id, isNot(pdf.id), reason: 'one node per attachment');

      // Activating the node runs the same open callback as a tap.
      tester.semantics.performAction(
        find.semantics.byLabel(RegExp('photo.png')),
        SemanticsAction.tap,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentImageScreen), findsOneWidget);
    });
  });

  testWidgets('the attachment bubble is announced once, not per child',
      (tester) async {
    await _inChat(tester, () async {
      expect(
        find.semantics.byLabel(RegExp(r'^Attachment from bob')),
        findsOneWidget,
      );
    });
  });

  testWidgets('a text bubble keeps its merged label and its long press',
      (tester) async {
    await _inChat(tester, () async {
      final bubble = tester.getSemantics(find.byType(FormattedMessage));
      expect(bubble.label, contains('hello there'));
      expect(bubble.label, contains('bob'));
      expect(bubble.getSemanticsData().hasAction(SemanticsAction.longPress),
          isTrue);
    });
  });
}
