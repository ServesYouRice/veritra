import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/sealed_sender.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/core/report_models.dart';
import 'package:private_messenger/crypto/franking.dart'
    show reportInboxInstanceOwner;
import 'package:private_messenger/crypto/owner_key_watch.dart';
import 'package:private_messenger/crypto/owner_proof_pins.dart';
import 'package:private_messenger/crypto/report_key_pins.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/features/settings/sealed_key_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// L2-3: Settings shows the pinned sealed sender key, and a changed key the
/// server shows since, which the person can accept.
void main() {
  const origin = 'https://localhost:8080';

  Future<AppState> stateWith(SealedKeyPin? pin,
      {List<ReportKeyPin> owners = const <ReportKeyPin>[]}) async {
    final store = MemoryLocalStore();
    if (pin != null) await store.saveSealedKeyPin(pin);
    for (final owner in owners) {
      await store.saveReportKeyPin(owner);
    }
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

  // Owner decision 4: with no pinned owner key a sealed message is provable
  // to no one, and the screen says so; else it names how many owners.
  testWidgets('the screen says who a sealed message is provable to',
      (tester) async {
    final key = SealedKeyPin(
        origin: origin, keyId: 'a' * 32, publicKey: pinned, pinnedAt: 1);
    var state = await stateWith(key);
    await tester.pumpWidget(MaterialApp(home: SealedKeyScreen(state: state)));
    await tester.pumpAndSettle();
    expect(find.textContaining('can then be proven to no one'), findsOneWidget);

    ReportKeyPin owner(String id, int fill) => ReportKeyPin(
        origin: origin,
        ownerAccountId: id,
        publicKey: List<int>.filled(32, fill),
        keyRev: 1,
        pinnedAt: 1);
    state = await stateWith(key, owners: <ReportKeyPin>[
      owner('acct_owner_1', 0x31),
      owner('acct_owner_2', 0x32),
      // A community moderator inbox is not an instance owner.
      owner('comm_1:acct_mod', 0x33),
    ]);
    await tester.pumpWidget(MaterialApp(
        key: const ValueKey('second'), home: SealedKeyScreen(state: state)));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('sealed-provable-owners')))
            .data,
        contains(': 2.'));
    expect(await state.sealedProvableOwnerCount(), 2);
  });

  // Owner decision 2026-11-12: a key that changed, an owner added and an
  // owner gone since the first pin are shown here to accept or reject, and
  // Settings warns while any is waiting.
  testWidgets('owner key differences wait for the person', (tester) async {
    final key = SealedKeyPin(
        origin: origin, keyId: 'a' * 32, publicKey: pinned, pinnedAt: 1);
    final state = await stateWith(key);
    final watch = OwnerKeyWatch(state.localStore, origin);
    ReportInboxRecipient owner(String id, int fill) => ReportInboxRecipient(
        inboxId: id, publicKey: List<int>.filled(32, fill), keyRev: 1);
    // First sight pins acct_o1 and acct_o2.
    expect(
        await watch.observe(ReportInbox(
            kind: reportInboxInstanceOwner,
            recipients: [owner('acct_o1', 0x41), owner('acct_o2', 0x42)])),
        isTrue);
    // Then o1's key changes, o2 is gone and o3 is new.
    expect(
        await watch.observe(ReportInbox(
            kind: reportInboxInstanceOwner,
            recipients: [owner('acct_o1', 0x51), owner('acct_o3', 0x43)])),
        isFalse);
    await state.loadOwnerKeyReview();

    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SettingsScreen(state: state)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('owner-key-review-tile')), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
        key: const ValueKey('screen'), home: SealedKeyScreen(state: state)));
    await tester.pumpAndSettle();
    for (final id in ['acct_o1', 'acct_o2', 'acct_o3']) {
      expect(find.byKey(ValueKey('owner-key-review-$id')), findsOneWidget);
    }
    expect(find.text(reportKeyFingerprint(List<int>.filled(32, 0x41))),
        findsOneWidget);
    expect(find.text(reportKeyFingerprint(List<int>.filled(32, 0x51))),
        findsOneWidget);
    expect(find.textContaining(': 2.'), findsOneWidget);

    // Reject the changed key: the pin stays.
    await tester.tap(find.byKey(const ValueKey('owner-key-reject-acct_o1')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('owner-key-review-acct_o1')), findsNothing);
    // Accept the new owner, after the warning.
    await tester.tap(find.byKey(const ValueKey('owner-key-accept-acct_o3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('owner-key-accept-confirm')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('owner-key-review-acct_o3')), findsNothing);
    // Accept that o2 is gone.
    await tester.tap(find.byKey(const ValueKey('owner-key-accept-acct_o2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('owner-key-accept-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('owner-key-review')), findsNothing);

    // The decisions act on the proof recipients only: no report pin.
    final pins = {
      for (final pin
          in await OwnerProofPins(state.localStore, origin).effective())
        pin.ownerAccountId: pin.publicKey
    };
    expect(await state.localStore.loadReportKeyPins(origin), isEmpty);
    expect(pins, {
      'acct_o1': List<int>.filled(32, 0x41),
      'acct_o3': List<int>.filled(32, 0x43),
    });
    expect(state.ownerKeyReview, isEmpty);
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
  Future<MessageEnvelope?> reencryptSealedAsIdentified(
          MessageEnvelope sealed) =>
      throw UnimplementedError();
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
