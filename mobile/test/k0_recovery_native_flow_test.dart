import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/account_recovery.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// K0 R3/R4 through [NativeCryptoService] and the real ABI 11 library: the
/// recovery key round trip, and a recovery claim's identity sealed at claim
/// time, kept as the persisted claim (JSON), reopened by a new service (an
/// app restart during the wait), activated, and then reachable by its
/// claim key package: a peer adds it to a group and messages flow.
void main() {
  late NativeCryptoBindings bindings;

  setUp(() {
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  Session session(String accountId, String deviceId) => Session(
        baseUrl: 'https://chat.example.org',
        token: 'token',
        accountId: accountId,
        deviceId: deviceId,
      );

  test('recovery key: generate, show, type back, derive', () async {
    final service =
        NativeCryptoService(bindings: bindings, localStore: MemoryLocalStore());
    final entropy = await service.generateRecoveryKey();
    expect(entropy, hasLength(30));
    final display = await service.encodeRecoveryKey(entropy);
    expect(display, hasLength(52));
    // Pasted from a note: groups split by tabs, a newline and en dashes.
    final pasted = groupRecoveryKey(display.toLowerCase())
        .replaceAll('-', '–')
        .replaceFirst('–', '\t')
        .replaceFirst('–', '\r\n');
    expect(() => bindings.decodeRecoveryKey(pasted), throwsA(anything));
    final decoded =
        await service.decodeRecoveryKey(normalizeRecoveryKeyInput(pasted));
    expect(decoded, entropy);
    final derived = await service.deriveRecoveryKey(entropy);
    expect(derived.rkAuthPub, hasLength(32));
    expect(derived.rkId, hasLength(16));
    expect(derived.rkPub, hasLength(32));
    expect((await service.deriveRecoveryKey(decoded)).rkAuthPub,
        derived.rkAuthPub);
  }, skip: nativeCryptoSkip());

  test('a sealed claim identity survives a restart and joins a group',
      () async {
    // The account's other member, enrolled the usual way.
    final aliceStore = MemoryLocalStore();
    final alice =
        NativeCryptoService(bindings: bindings, localStore: aliceStore);
    await alice.createEnrollmentCredential(const EnrollmentReservation(
        id: 'res_alice',
        accountId: 'acct_alice',
        deviceId: 'dev_alice',
        challenge: <int>[1]));
    await alice.activateSession(session('acct_alice', 'dev_alice'));

    // Claim time: a fresh identity, its proof, and the sealed state.
    final first =
        NativeCryptoService(bindings: bindings, localStore: MemoryLocalStore());
    const reservation = EnrollmentReservation(
        id: 'res_bob',
        accountId: 'acct_bob',
        deviceId: 'dev_bob',
        challenge: <int>[7, 7, 7]);
    final credential = await first.createEnrollmentCredential(reservation);
    final entropy = await first.generateRecoveryKey();
    final proof = await first.signRecoveryProof(
      entropy: entropy,
      challenge: reservation.challenge,
      signingKey: credential.signingKey,
      keyPackage: credential.deviceKeyPackage,
      origin: 'https://chat.example.org',
    );
    expect(proof, hasLength(64));
    final relayed = await first.signRecoveryProof(
      entropy: entropy,
      challenge: reservation.challenge,
      signingKey: credential.signingKey,
      keyPackage: credential.deviceKeyPackage,
      origin: 'https://chat.example.org.evil',
    );
    expect(relayed, isNot(proof));
    entropy.fillRange(0, entropy.length, 0);
    final sealed = await first.sealPendingEnrollment();
    // Sealing again returns the same state, never a new generation.
    final again = await first.sealPendingEnrollment();
    expect(again.sealedState, sealed.sealedState);
    expect(again.stateKey, sealed.stateKey);
    final persisted = PendingAccountRecovery(
      origin: 'https://chat.example.org',
      username: 'bob',
      accountId: 'acct_bob',
      deviceId: 'dev_bob',
      deviceName: 'Phone',
      requestId: 'arr_1',
      claimToken: 'claim',
      deviceSecret: 'secret',
      readyAt: DateTime.utc(2026, 11, 8),
      mlsState: sealed,
    ).toEnrollment();
    await first.dispose();

    // Days later, after a restart: a new service over a new, empty store.
    final bobStore = MemoryLocalStore();
    final bob = NativeCryptoService(bindings: bindings, localStore: bobStore);
    final pending = PendingAccountRecovery.fromEnrollment(persisted)!;
    await bob.resumePendingEnrollment(
        accountId: 'acct_bob', deviceId: 'dev_bob', state: pending.mlsState);
    await bob.activateSession(session('acct_bob', 'dev_bob'));
    final stored = await bobStore.loadCryptoSnapshot();
    expect(stored.state!.counter, 1);
    expect(stored.state!.sealedState, sealed.sealedState);

    // The claim's key package is the one the server got: a peer adds it.
    await alice.initializeConversation('conv_1', <DeviceKeyPackage>[
      DeviceKeyPackage(
        id: 'kp_claim',
        deviceId: 'dev_bob',
        accountId: 'acct_bob',
        keyPackage: credential.deviceKeyPackage,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 30)),
      ),
    ]);
    final bundle = (await aliceStore.pendingMlsMessages()).single;
    await alice.completeCommitBundle(bundle);
    await bob.processMlsMessage(MlsMessage(
      id: 'mls_1',
      conversationId: 'conv_1',
      senderAccountId: 'acct_alice',
      senderDeviceId: 'dev_alice',
      kind: 'welcome',
      payload: MlsCommitBundle.decode(bundle.payload).welcome,
      idempotencyKey: '${bundle.idempotencyKey}:welcome:dev_bob',
      syncEventId: 1,
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: 'dev_bob',
    ));
    final hello = await alice
        .encryptPayload('conv_1', AppPayloadType.text, {'text': 'welcome'});
    await bob.processApplicationMessage(
      ReceivedMessageEnvelope(
        id: 'srv_1',
        conversationId: 'conv_1',
        senderAccountId: 'acct_alice',
        senderDeviceId: 'dev_alice',
        idempotencyKey: hello.idempotencyKey,
        ciphertext: hello.ciphertext,
        cryptoProtocol: hello.cryptoProtocol,
        createdAt: DateTime.now().toUtc(),
      ),
      2,
    );
    expect((await bobStore.loadMessages('conv_1')).last.body, 'welcome');
    await alice.dispose();
    await bob.dispose();
  }, skip: nativeCryptoSkip());

  test('abandoning drops the pending identity', () async {
    final service =
        NativeCryptoService(bindings: bindings, localStore: MemoryLocalStore());
    await service.createEnrollmentCredential(const EnrollmentReservation(
        id: 'res', accountId: 'acct', deviceId: 'dev', challenge: <int>[1]));
    await service.abandonPendingEnrollment();
    expect(service.sealPendingEnrollment(), throwsStateError);
    await expectLater(
        service.activateSession(session('acct', 'dev')), throwsStateError);
  }, skip: nativeCryptoSkip());

  test('UnavailableCryptoService refuses every recovery call', () async {
    final crypto = UnavailableCryptoService();
    final entropy = Uint8List(30);
    await expectLater(crypto.generateRecoveryKey(), throwsStateError);
    await expectLater(crypto.encodeRecoveryKey(entropy), throwsStateError);
    await expectLater(crypto.decodeRecoveryKey('A' * 52), throwsStateError);
    await expectLater(crypto.deriveRecoveryKey(entropy), throwsStateError);
    await expectLater(
        crypto.signRecoveryProof(
            entropy: entropy,
            challenge: const <int>[1],
            signingKey: List<int>.filled(32, 1),
            keyPackage: List<int>.filled(64, 1),
            origin: 'https://chat.example.org'),
        throwsStateError);
    await expectLater(crypto.sealPendingEnrollment(), throwsStateError);
    await expectLater(
        crypto.resumePendingEnrollment(
            accountId: 'a',
            deviceId: 'd',
            state: StoredCryptoState(
                counter: 1,
                stateKey: List<int>.filled(32, 0),
                sealedState: [])),
        throwsStateError);
  });
}
