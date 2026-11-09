import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

/// C7 (ABI 13): the device-level calls. Commit outcomes come from MLS, the
/// epoch-returning decrypt, the member key read and credential-key signing.
/// The stateless calls and the shared vector are in c7_primitives_test.dart.
void main() {
  group('native ABI 13, C7 device calls', () {
    late NativeCryptoBindings bindings;
    setUp(() {
      bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    });

    ({
      NativeCryptoDevice alice,
      NativeCryptoDevice bob,
      NativeCryptoDevice carol
    }) threeMembers(String group) {
      final alice = bindings.createDevice('acct_alice', 'dev_alice');
      final bob = bindings.createDevice('acct_bob', 'dev_bob');
      final carol = bindings.createDevice('acct_carol', 'dev_carol');
      alice.createGroup(group);
      final added = alice.stageCommit(group, adds: [
        (
          keyPackage: bob.createKeyPackage(),
          accountId: 'acct_bob',
          deviceId: 'dev_bob'
        ),
        (
          keyPackage: carol.createKeyPackage(),
          accountId: 'acct_carol',
          deviceId: 'dev_carol'
        ),
      ]);
      alice.mergePendingCommit(group);
      bob.joinGroup(group, added.welcome);
      carol.joinGroup(group, added.welcome);
      return (alice: alice, bob: bob, carol: carol);
    }

    test(
      'a removal reports itself and the same root on every device',
      () {
        final m = threeMembers('conv_c7_removal');
        final removal = m.alice.stageCommit('conv_c7_removal',
            removes: [(accountId: 'acct_bob', deviceId: 'dev_bob')]);
        final own = m.alice.c7MergePendingCommit('conv_c7_removal');
        final other =
            m.carol.c7ProcessCommit('conv_c7_removal', removal.commit);
        final removed =
            m.bob.c7ProcessCommit('conv_c7_removal', removal.commit);
        expect(own.removedAny, isTrue);
        expect(own.addedAny, isFalse);
        expect(own.removedSelf, isFalse);
        expect(own.membership, isTrue);
        expect(own.newEpoch, m.alice.groupEpoch('conv_c7_removal').epoch);
        expect(own.root, hasLength(32));
        expect(other.removedAny, isTrue);
        expect(other.newEpoch, own.newEpoch);
        // The exporter secret of the epoch is the same on every member.
        expect(other.root, own.root);
        // The removed device learns it was removed and gets no root.
        expect(removed.removedAny, isTrue);
        expect(removed.removedSelf, isTrue);
        expect(removed.root, isNull);
        own.wipeRoot();
        expect(own.root, everyElement(0));
        expect(other.root, isNot(everyElement(0)));
      },
      skip: nativeCryptoSkip(),
    );

    test(
      'an add reports itself and carries no root',
      () {
        final m = threeMembers('conv_c7_add');
        final dave = bindings.createDevice('acct_dave', 'dev_dave');
        final added = m.alice.stageCommit('conv_c7_add', adds: [
          (
            keyPackage: dave.createKeyPackage(),
            accountId: 'acct_dave',
            deviceId: 'dev_dave'
          ),
        ]);
        final own = m.alice.c7MergePendingCommit('conv_c7_add');
        final other = m.bob.c7ProcessCommit('conv_c7_add', added.commit);
        for (final outcome in [own, other]) {
          expect(outcome.addedAny, isTrue);
          expect(outcome.removedAny, isFalse);
          expect(outcome.removedSelf, isFalse);
          expect(outcome.root, isNull);
          expect(outcome.newEpoch, m.alice.groupEpoch('conv_c7_add').epoch);
        }
        // Merging with nothing staged is refused, not a silent no-op.
        expect(
          () => m.alice.c7MergePendingCommit('conv_c7_add'),
          throwsA(isA<NativeCryptoException>()),
        );
      },
      skip: nativeCryptoSkip(),
    );

    test(
      'decrypt returns the epoch and the member key verifies a signature',
      () {
        final m = threeMembers('conv_c7_decrypt');
        final epoch = m.alice.groupEpoch('conv_c7_decrypt').epoch;
        final ciphertext = m.alice.encrypt('conv_c7_decrypt', [9, 8, 7]);
        final opened = m.bob.c7Decrypt(
          'conv_c7_decrypt',
          ciphertext,
          senderAccountId: 'acct_alice',
          senderDeviceId: 'dev_alice',
        );
        expect(opened.plaintext, [9, 8, 7]);
        expect(opened.epoch, epoch);

        final message = Uint8List.fromList(List<int>.generate(40, (i) => i));
        final signature =
            m.alice.c7Sign(domain: 'veritra-c7-post-sig-v1', message: message);
        final key = m.carol
            .c7MemberSignatureKey('conv_c7_decrypt', 'acct_alice', 'dev_alice');
        expect(key, hasLength(32));
        expect(
          bindings.c7Verify(
            domain: 'veritra-c7-post-sig-v1',
            publicKey: key,
            message: message,
            signature: signature,
          ),
          isTrue,
        );
        // Another domain never verifies, and another label is refused.
        expect(
          bindings.c7Verify(
            domain: 'veritra-c7-history-v1',
            publicKey: key,
            message: message,
            signature: signature,
          ),
          isFalse,
        );
        expect(
          () => m.alice.c7Sign(domain: 'mls-label', message: message),
          throwsA(isA<NativeCryptoException>()),
        );
        expect(
          () => m.carol.c7MemberSignatureKey(
              'conv_c7_decrypt', 'acct_alice', 'dev_nobody'),
          throwsA(isA<NativeCryptoException>()),
        );
      },
      skip: nativeCryptoSkip(),
    );
  });
}
