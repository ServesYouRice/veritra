// Jumping to a search result walks the list across several frames; leaving
// the chat mid-jump must not touch the disposed scroll controller (TASK-069).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

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

Future<AppState> _stateWithHistory(int messages) async {
  final store = MemoryLocalStore();
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
    messageEffects: <MessageEffect>[
      for (var i = 1; i <= messages; i++)
        InsertMessageEffect(
          key: 'peerdev:m$i',
          conversationId: 'conv',
          senderAccountId: 'peer',
          senderDeviceId: 'peerdev',
          kind: LocalMessageKind.text,
          body: 'message number $i',
          createdAt: DateTime.utc(2026, 10, 24, 8, 0, i).millisecondsSinceEpoch,
          state: LocalMessageState.received,
        ),
    ],
  ));
  final state = AppState(
    apiClientFactory: (_) => ApiClient(baseUrl: 'https://example.test'),
    cryptoService: _MlsStub(),
    localStore: store,
    syncServiceFactory: (_, __) => _QuietSync(),
  )
    ..session = const Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'me',
      deviceId: 'medev',
    )
    ..conversations = <Conversation>[
      Conversation(id: 'conv', kind: 'group', title: 'Team'),
    ];
  await state.refreshHistory('conv');
  return state;
}

void main() {
  testWidgets('leaving the chat while a jump waits for a frame is harmless',
      (tester) async {
    final state = await _stateWithHistory(150);
    addTearDown(state.dispose);
    // A route above this one that is popped mid-jump.
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: const SizedBox(),
    ));
    unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        state: state,
        conversationId: 'conv',
        initialMessageKey: 'peerdev:m12',
      ),
    )));
    // One frame builds the chat; its post-frame callback starts the jump,
    // which jumps once and then waits for the next frame to end.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    navigator.currentState!.pop();
    // The jump's continuation now runs against a disposed screen.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing the chat screen mid-jump is harmless', (tester) async {
    final state = await _stateWithHistory(150);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        state: state,
        conversationId: 'conv',
        initialMessageKey: 'peerdev:m12',
      ),
    ));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a jump that is left alone still lands on the message',
      (tester) async {
    final state = await _stateWithHistory(150);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        state: state,
        conversationId: 'conv',
        initialMessageKey: 'peerdev:m12',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('message number 12'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
