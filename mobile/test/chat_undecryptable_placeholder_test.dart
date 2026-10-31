// D54: a peer message this device can never decrypt is committed past with
// a visible "couldn't unlock" placeholder that holds no content.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'goldens/golden_harness.dart';

void main() {
  testWidgets('an undecryptable message shows a placeholder, never content',
      (tester) async {
    setWindowSize(tester, phoneSize);
    final state = await connectedState();
    await _addUndecryptable(state);

    await tester.pumpWidget(veritraTestApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@alice'));
    await tester.pumpAndSettle();

    final label = find.text(englishL10n.chatMessageUndecryptable);
    expect(label, findsOneWidget);
    expect(
        find.descendant(
            of: find.ancestor(of: label, matching: find.byType(Row)).first,
            matching: find.byIcon(Icons.lock_outline)),
        findsOneWidget);
    // The older "could not be read" placeholder is a different case.
    expect(find.text(englishL10n.chatMessageInvalid), findsNothing);
    expect(find.bySemanticsLabel(englishL10n.chatMessageUndecryptable),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// Stores what NativeCryptoService commits for an envelope it can never
/// decrypt, and has the server list that envelope.
Future<void> _addUndecryptable(AppState state) async {
  final envelope = ReceivedMessageEnvelope(
    id: 'm5',
    conversationId: chatConversationId,
    senderAccountId: 'acct_alice',
    senderDeviceId: 'dev_alice',
    idempotencyKey: 'm5',
    ciphertext: const <int>[7, 7, 7],
    cryptoProtocol: 'mls10-openmls-v1',
    createdAt: DateTime.utc(2025, 3, 14, 9, 20),
  );
  final stored = (await state.localStore.loadCryptoState())!;
  await state.localStore.commitMlsTransition(MlsStateTransition(
    messageId: 'application:2:m5',
    conversationId: chatConversationId,
    expectedCounter: stored.counter,
    expectedCursor: await state.localStore.loadSyncCursor(),
    state: StoredCryptoState(
      counter: stored.counter + 1,
      stateKey: stored.stateKey,
      sealedState: const <int>[3],
    ),
    cursor: 2,
    upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
    messageEffects: <MessageEffect>[
      InsertMessageEffect(
        key: 'undecryptable:2:m5',
        serverMessageId: 'm5',
        conversationId: chatConversationId,
        senderAccountId: 'acct_alice',
        senderDeviceId: 'dev_alice',
        kind: LocalMessageKind.invalid,
        createdAt: envelope.createdAt.millisecondsSinceEpoch,
        state: LocalMessageState.received,
      ),
    ],
  ));
  // The fixture server pages its envelopes newest first.
  ((state.api! as dynamic).envelopes as List<ReceivedMessageEnvelope>)
      .insert(0, envelope);
  await state.refreshHistory(chatConversationId);
}
