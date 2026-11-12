import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/sealed_sender.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/report_key_pins.dart';
import 'package:private_messenger/features/settings/sealed_key_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// L2-3: Settings shows the pinned sealed sender key, and a changed key the
/// server shows since, which the person can accept.
void main() {
  const origin = 'https://localhost:8080';

  Future<AppState> stateWith(SealedKeyPin? pin) async {
    final store = MemoryLocalStore();
    if (pin != null) await store.saveSealedKeyPin(pin);
    final api = ApiClient(baseUrl: origin);
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _NoSync(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: origin,
        token: 'token',
        accountId: 'acct_a',
        deviceId: 'dev_a',
        username: 'a',
      );
    state.sealedSender =
        SealedSender(origin: origin, localStore: store, crypto: _NoCrypto())
          ..enabled = true;
    return state;
  }

  final pinned = List<int>.filled(32, 0x11);
  final changed = List<int>.filled(32, 0x22);

  testWidgets('a changed key is shown beside the pin and can be accepted',
      (tester) async {
    final state = await stateWith(SealedKeyPin(
      origin: origin,
      keyId: 'a' * 32,
      publicKey: pinned,
      pinnedAt: 1,
      seenKeyId: 'b' * 32,
      seenPublicKey: changed,
    ));
    await tester.pumpWidget(MaterialApp(home: SealedKeyScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.text(reportKeyFingerprint(pinned)), findsOneWidget);
    expect(find.text(reportKeyFingerprint(changed)), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Accept new key'));
    await tester.pumpAndSettle();
    // The confirmation says what accepting risks; confirm.
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Accept new key')));
    await tester.pumpAndSettle();

    final pin = (await state.sealedKeyPin())!;
    expect(pin.keyId, 'b' * 32);
    expect(pin.changed, isFalse);
    await tester.pumpAndSettle();
    expect(find.text(reportKeyFingerprint(changed)), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Accept new key'), findsNothing);
  });

  testWidgets('no pin yet says so', (tester) async {
    final state = await stateWith(null);
    await tester.pumpWidget(MaterialApp(home: SealedKeyScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.textContaining('No key pinned yet'), findsOneWidget);
  });
}

class _NoCrypto implements SealedSendingCryptoService {
  @override
  set sealedTokenSource(SealedTokenSource? source) {}
  @override
  Future<ReceivedMessageEnvelope> processSealedApplicationMessage(
          ReceivedMessageEnvelope envelope, int syncEventId,
          {void Function()? checkCanCommit}) =>
      throw UnimplementedError();
  @override
  ({Uint8List state, Uint8List request}) sealedTokenRequest(
          {required List<int> publicKey,
          required String conversationId,
          required int epoch,
          required int count}) =>
      throw UnimplementedError();
  @override
  List<SealedToken> sealedTokenFinalize(
          {required List<int> state,
          required List<int> response,
          required String conversationId,
          required String keyId,
          required int epoch}) =>
      throw UnimplementedError();
}

class _NoSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get events => _controller.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async => _controller.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
