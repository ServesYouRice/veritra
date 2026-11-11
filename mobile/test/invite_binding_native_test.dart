import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/membership_invite_link.dart';
import 'package:private_messenger/core/membership_models.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';

/// C1 invitation binding v2 against the native engine (ABI 13): the shared
/// vector (`testing/vectors/invite-binding-v2.json`, checked by Rust and Go
/// too), a real device signature and its strict check, and the roster key
/// read that anchors the inviter's key. Skipped without
/// VERITRA_CRYPTO_LIBRARY; with VERITRA_REQUIRE_NATIVE_CRYPTO=1 it fails
/// instead.
void main() {
  final vector = jsonDecode(
    File('../testing/vectors/invite-binding-v2.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final inputs = vector['inputs'] as Map<String, dynamic>;
  final outputs = vector['outputs'] as Map<String, dynamic>;

  Uint8List hex(Object? value) {
    final text = value as String;
    return Uint8List.fromList(<int>[
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  late NativeCryptoBindings bindings;
  setUp(
      () => bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary()));

  test('the vector signature verifies in the invitation domain only', () {
    final key = hex(outputs['signing_public_key_hex']);
    final message = hex(outputs['signed_message_hex']);
    final signature = hex(outputs['signature_hex']);
    expect(
      bindings.c7Verify(
        domain: inviteBindingSigningDomain,
        publicKey: key,
        message: message,
        signature: signature,
      ),
      isTrue,
    );
    for (final other in <String>[
      'veritra-c7-post-sig-v1',
      'veritra-c7-history-v1',
    ]) {
      expect(
        bindings.c7Verify(
          domain: other,
          publicKey: key,
          message: message,
          signature: signature,
        ),
        isFalse,
        reason: other,
      );
    }
    final altered = Uint8List.fromList(message)..[10] ^= 1;
    expect(
      bindings.c7Verify(
        domain: inviteBindingSigningDomain,
        publicKey: key,
        message: altered,
        signature: signature,
      ),
      isFalse,
    );
    expect(
      () => bindings.c7Verify(
        domain: 'veritra-invite-binding-v1',
        publicKey: key,
        message: message,
        signature: signature,
      ),
      throwsA(isA<NativeCryptoException>()),
    );
  }, skip: nativeCryptoSkip());

  test('a device signs a link binding and another device verifies it',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    final aliceKey = await alice.service.deviceSigningPublicKey(
      accountId: 'acct_alice',
      deviceId: 'dev_alice',
    );

    final link = MembershipInviteLink.generate(
      origin: inputs['origin'] as String,
      inviterSigningKey: aliceKey,
    );
    Uint8List messageFor(String targetId) => link.bindingMessage(
          kind: InviteTargetKind.group,
          targetId: targetId,
          inviterAccountId: 'acct_alice',
          inviterDeviceId: 'dev_alice',
          inviterSigningKey: aliceKey,
        );
    final message = messageFor('conv_1');
    final signature = await alice.service.signInviteBinding(
      accountId: 'acct_alice',
      deviceId: 'dev_alice',
      message: message,
    );
    expect(signature, hasLength(64));

    // Bob checks it with no secret and no state of Alice's.
    Future<bool> bobVerifies(List<int> key, List<int> m, List<int> sig) =>
        bob.service.verifyInviteBinding(
          signingKey: key,
          message: m,
          signature: sig,
        );
    expect(await bobVerifies(aliceKey, message, signature), isTrue);
    // A swapped target, another key, and a flipped bit are all refused.
    expect(
        await bobVerifies(aliceKey, messageFor('conv_2'), signature), isFalse);
    expect(
      await bobVerifies(
        await bob.service
            .deviceSigningPublicKey(accountId: 'acct_bob', deviceId: 'dev_bob'),
        message,
        signature,
      ),
      isFalse,
    );
    final flipped = Uint8List.fromList(signature)..[5] ^= 1;
    expect(await bobVerifies(aliceKey, message, flipped), isFalse);
    expect(await bobVerifies(aliceKey, message, signature.sublist(1)), isFalse);

    // The link matches a binding built from it (commitment, tag, lengths).
    final binding = InviteBinding(
      kind: InviteTargetKind.group,
      targetId: 'conv_1',
      inviterAccountId: 'acct_alice',
      inviterDeviceId: 'dev_alice',
      inviterSigningKey: aliceKey,
      tag: link.bindingTag(
        kind: InviteTargetKind.group,
        targetId: 'conv_1',
        inviterAccountId: 'acct_alice',
        inviterDeviceId: 'dev_alice',
        inviterSigningKey: aliceKey,
      ),
      signature: signature,
    );
    expect(link.matches(binding), isTrue);

    // Bob holds a group with Alice: its roster names the same key. A stranger
    // and an unknown conversation read as nothing.
    expect(
      await bob.service.memberSigningKey(
        conversationId: 'conv_1',
        accountId: 'acct_alice',
        deviceId: 'dev_alice',
      ),
      aliceKey,
    );
    expect(
      await bob.service.memberSigningKey(
        conversationId: 'conv_1',
        accountId: 'acct_mallory',
        deviceId: 'dev_alice',
      ),
      isNull,
    );
    expect(
      await bob.service.memberSigningKey(
        conversationId: 'conv_unknown',
        accountId: 'acct_alice',
        deviceId: 'dev_alice',
      ),
      isNull,
    );

    // A device signs only as itself.
    await expectLater(
      bob.service.signInviteBinding(
        accountId: 'acct_alice',
        deviceId: 'dev_alice',
        message: message,
      ),
      throwsStateError,
    );
  }, skip: nativeCryptoSkip());
}

Session _session(String accountId, String deviceId) => Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    );

int _serverIds = 0;

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int events = 0;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId) async {
    final store = MemoryLocalStore();
    final service = NativeCryptoService(bindings: bindings, localStore: store);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(_session(accountId, deviceId));
    return _Client(service, store, accountId, deviceId);
  }

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );
}

Future<void> _startConversation(_Client alice, _Client bob) async {
  await alice.service.initializeConversation(
      'conv_1', <DeviceKeyPackage>[await bob.keyPackage()]);
  final item = (await alice.store.pendingMlsMessages()).single;
  await alice.service.completeCommitBundle(item);
  await bob.service.processMlsMessage(MlsMessage(
    id: 'mls_${++_serverIds}',
    conversationId: 'conv_1',
    senderAccountId: alice.accountId,
    senderDeviceId: alice.deviceId,
    kind: 'welcome',
    payload: MlsCommitBundle.decode(item.payload).welcome,
    idempotencyKey: '${item.idempotencyKey}:welcome:${bob.deviceId}',
    syncEventId: ++bob.events,
    createdAt: DateTime.now().toUtc(),
    recipientDeviceId: bob.deviceId,
  ));
}
