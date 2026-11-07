import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/link_preview_service.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/link_preview.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/link_preview_card.dart';
import 'package:private_messenger/features/settings/link_preview_tile.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

const _link = 'https://github.com/ServesYouRice/veritra';
const _text = 'read $_link now';

void main() {
  testWidgets('the card shows the real host, the title and the description',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LinkPreviewCard(
            preview: LinkPreview(
              url: _link,
              title: 'Veritra',
              description: 'A private messenger',
            ),
          ),
        ),
      ),
    );
    expect(find.text('github.com'), findsOneWidget);
    expect(find.text('Veritra'), findsOneWidget);
    expect(find.text('A private messenger'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a thumbnail that cannot be decoded leaves a blank, not a crash',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkPreviewCard(
            preview: LinkPreview(
              url: _link,
              title: 'Veritra',
              thumbnail: LinkPreviewThumbnail(
                png: Uint8List.fromList(List<int>.filled(60, 3)),
                width: 8,
                height: 8,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Veritra'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chat bubble draws a valid preview and ignores a mismatched one',
      (tester) async {
    final store = MemoryLocalStore();
    final state = _state()..localStoreOverride = store;
    await _seed(store, <String, Object?>{
      'link_preview': <String, Object?>{'url': _link, 'title': 'Veritra'},
    });
    await state.refreshHistory('conv');
    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(state: state, conversationId: 'conv')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LinkPreviewCard), findsOneWidget);
    expect(find.text('Veritra'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();

    final other = MemoryLocalStore();
    final second = _state()..localStoreOverride = other;
    await _seed(other, <String, Object?>{
      'link_preview': <String, Object?>{
        'url': 'https://bank.example/login',
        'title': 'Bank',
      },
    });
    await second.refreshHistory('conv');
    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(state: second, conversationId: 'conv')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LinkPreviewCard), findsNothing);
    expect(find.text('Bank'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    second.dispose();
  });

  testWidgets('the setting offers all three modes', (tester) async {
    LinkPreviewMode? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkPreviewTile(
            mode: LinkPreviewMode.allowListed,
            onChanged: (mode) => chosen = mode,
          ),
        ),
      ),
    );
    expect(find.text(englishL10n.b2LinkPreviews), findsOneWidget);
    expect(find.text(englishL10n.b2LinkPreviewsKnown), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-preview-mode')));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.b2LinkPreviewsOff), findsOneWidget);
    expect(find.text(englishL10n.b2LinkPreviewsAll), findsOneWidget);
    await tester.tap(find.text(englishL10n.b2LinkPreviewsAll));
    await tester.pumpAndSettle();
    expect(chosen, LinkPreviewMode.anySite);
  });
}

Future<void> _seed(LocalStore store, Map<String, Object?> decoration) async {
  await store.saveCryptoState(
    StoredCryptoState(
      counter: 1,
      stateKey: List.filled(32, 1),
      sealedState: [1],
    ),
    0,
  );
  await store.commitMlsTransition(
    MlsStateTransition(
      messageId: 'seed',
      conversationId: 'conv',
      expectedCounter: 1,
      expectedCursor: 0,
      state: StoredCryptoState(
        counter: 2,
        stateKey: List.filled(32, 1),
        sealedState: [2],
      ),
      cursor: 1,
      messageEffects: [
        InsertMessageEffect(
          key: 'dev:t',
          conversationId: 'conv',
          senderAccountId: 'alice',
          senderDeviceId: 'dev',
          kind: LocalMessageKind.text,
          body: _text,
          createdAt: 1,
          state: LocalMessageState.received,
          formatJson: jsonEncode(decoration),
        ),
      ],
    ),
  );
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

class _UiState extends AppState {
  _UiState()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://example.test'),
          cryptoService: _MlsStub(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  LocalStore? localStoreOverride;

  @override
  LocalStore get localStore => localStoreOverride ?? super.localStore;
}

_UiState _state() => _UiState()
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
