import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/room/native_call_group.dart';
import 'package:private_messenger/calls/room/room_ports.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/device_list_records.dart';

import 'native_test_env.dart';

/// B6 (ABI 22) on the real MLS core: the join message and signature against
/// testing/vectors/b6-media-v1.json (which Rust and Go check too), and two
/// devices that really share media keys through a call group.
void main() {
  final vector = jsonDecode(
    File('../testing/vectors/b6-media-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final inputs = vector['inputs'] as Map<String, dynamic>;
  final outputs = vector['outputs'] as Map<String, dynamic>;

  Uint8List hex(Object? value) {
    final text = value as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  group('B6 call group (native)', () {
    late NativeCryptoBindings bindings;
    setUp(() =>
        bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary()));

    test('the join message and signature match the shared vector', () {
      // The join nonce is text in the app and bytes in the vector; the message
      // layout is the same, so rebuild the vector's message from its parts.
      final nonce = hex(inputs['join_nonce_hex']);
      final message = Uint8List.fromList([
        0,
        32,
        ...hex(inputs['join_group_id_hex']),
        0,
        nonce.length,
        ...nonce,
        ...(ByteData(8)..setUint64(0, inputs['join_expires_at'] as int))
            .buffer
            .asUint8List(),
      ]);
      // sha256 of the key package, through the app's own helper, must give the
      // vector's message end to end.
      final full = b6JoinMessage(
        groupId: hex(inputs['join_group_id_hex']),
        nonce: nonce,
        expiresAt: inputs['join_expires_at'] as int,
        keyPackage: hex(inputs['join_key_package_hex']),
      );
      expect(toHex(full), outputs['join_message_hex']);
      expect(toHex(full.sublist(0, message.length)), toHex(message));
      expect(
        bindings.c7Verify(
          domain: b6JoinDomain,
          publicKey: hex(outputs['join_public_key_hex']),
          message: full,
          signature: hex(outputs['join_signature_hex']),
        ),
        isTrue,
      );
      expect(
        bindings.c7Verify(
          domain: 'veritra-c7-post-sig-v1',
          publicKey: hex(outputs['join_public_key_hex']),
          message: full,
          signature: hex(outputs['join_signature_hex']),
        ),
        isFalse,
      );
    });

    // Review MEDIUM (round 7): the parent's MLS tree is not the roster; only
    // leaves this device's L1 judgment approves are.
    test('the parent view lists only leaves the L1 judgment approves',
        () async {
      final alice = bindings.createDevice('acct_alice', 'dev_alice');
      final bob = bindings.createDevice('acct_bob', 'dev_bob');
      alice.createGroup('conv_parent');
      final parentAdd = alice.addMember(
          'conv_parent', bob.createKeyPackage(), 'acct_bob', 'dev_bob');
      bob.joinGroup('conv_parent', parentAdd.welcome);
      ApprovalLeaf row(LeafPair leaf, LeafVerdict verdict) => ApprovalLeaf(
            conversationId: 'conv_parent',
            accountId: leaf.accountId,
            deviceId: leaf.deviceId,
            signingKey: leaf.signingKey,
            verdict: verdict,
            updatedAt: 0,
          );
      final leaves = alice.groupMembers('conv_parent');
      bool isBob(LeafPair l) => utf8.decode(l.deviceId) == 'dev_bob';
      List<ApprovalLeaf>? judged;
      final parent = NativeParentGroupView(alice,
          judged: (_) => judged, load: (_) async => judged);
      // Not loaded yet: unknown, never empty (an empty roster would remove
      // everyone from the call), and nobody is a member.
      expect(parent.members('conv_parent'), isNull);
      expect(await parent.allApproved('conv_parent'), isFalse);
      for (final verdict in [
        LeafVerdict.checking,
        LeafVerdict.removed,
        LeafVerdict.unapproved,
      ]) {
        judged = [
          for (final leaf in leaves)
            row(leaf, isBob(leaf) ? verdict : LeafVerdict.approved),
        ];
        final listed = parent.members('conv_parent')!;
        expect(listed.map((m) => m.id), ['acct_alice/dev_alice'],
            reason: '$verdict');
        final bobLeaf = leaves.firstWhere(isBob);
        expect(
            parent.hasMember('conv_parent',
                CallMember('acct_bob', 'dev_bob', bobLeaf.signingKey)),
            isFalse,
            reason: '$verdict');
        expect(await parent.allApproved('conv_parent'), isFalse,
            reason: '$verdict');
      }
      // An approved row with another key approves nothing.
      judged = [
        for (final leaf in leaves)
          isBob(leaf)
              ? ApprovalLeaf(
                  conversationId: 'conv_parent',
                  accountId: leaf.accountId,
                  deviceId: leaf.deviceId,
                  signingKey: Uint8List(32),
                  verdict: LeafVerdict.approved,
                  updatedAt: 0)
              : row(leaf, LeafVerdict.approved),
      ];
      expect(parent.members('conv_parent')!, hasLength(1));
      expect(await parent.allApproved('conv_parent'), isFalse);
      judged = [for (final leaf in leaves) row(leaf, LeafVerdict.approved)];
      expect(parent.members('conv_parent')!, hasLength(2));
      expect(await parent.allApproved('conv_parent'), isTrue);
      alice.close();
      bob.close();
    });

    test('two devices share the same media key, a join and a removal move it',
        () async {
      final alice = bindings.createDevice('acct_alice', 'dev_alice');
      final bob = bindings.createDevice('acct_bob', 'dev_bob');
      // The parent conversation.
      alice.createGroup('conv_parent');
      final parentAdd = alice.addMember(
          'conv_parent', bob.createKeyPackage(), 'acct_bob', 'dev_bob');
      bob.joinGroup('conv_parent', parentAdd.welcome);
      // Alice's L1 judgment of the parent's leaves: both approved.
      final verdicts = <String, List<ApprovalLeaf>>{
        'conv_parent': [
          for (final leaf in alice.groupMembers('conv_parent'))
            ApprovalLeaf(
              conversationId: 'conv_parent',
              accountId: leaf.accountId,
              deviceId: leaf.deviceId,
              signingKey: leaf.signingKey,
              verdict: LeafVerdict.approved,
              updatedAt: 0,
            ),
        ],
      };
      final parent = NativeParentGroupView(alice,
          judged: (c) => verdicts[c], load: (c) async => verdicts[c]);
      expect(await parent.allApproved('conv_parent'), isTrue);
      final aliceCall = NativeCallGroupCrypto(alice, bindings);
      final bobCall = NativeCallGroupCrypto(bob, bindings);
      final groupId = Uint8List.fromList(List.generate(32, (i) => i + 1));

      aliceCall.createGroup(groupId);
      final bobMember = parent
          .members('conv_parent')!
          .firstWhere((m) => m.deviceId == 'dev_bob');
      expect(parent.hasMember('conv_parent', bobMember), isTrue);
      expect(
          parent.hasMember(
              'conv_parent', CallMember('acct_bob', 'dev_bob', Uint8List(32))),
          isFalse,
          reason: 'the signing key must match the parent leaf');

      // Bob's signed offer verifies only for bob, with this nonce and group.
      final offer = bobCall.makeJoinOffer(groupId, 'nonce-1', 1800000050);
      bool verify(CallMember who, String nonce, Uint8List group) =>
          aliceCall.verifyJoinOffer(
            groupId: group,
            member: who,
            nonce: nonce,
            expiresAt: offer.expiresAt,
            keyPackage: offer.keyPackage,
            signature: offer.signature,
          );
      expect(verify(bobMember, 'nonce-1', groupId), isTrue);
      expect(verify(bobMember, 'nonce-2', groupId), isFalse);
      expect(verify(bobMember, 'nonce-1', Uint8List(32)), isFalse);
      final aliceMember = parent
          .members('conv_parent')!
          .firstWhere((m) => m.deviceId == 'dev_alice');
      expect(verify(aliceMember, 'nonce-1', groupId), isFalse);

      final staged = aliceCall.stageCommit(groupId,
          adds: [(keyPackage: offer.keyPackage, member: bobMember)]);
      aliceCall.mergeStaged(groupId);
      final joined = bobCall.joinWithWelcome(groupId, staged.welcome!)!;
      expect(joined.map((m) => m.deviceId).toSet(), {'dev_alice', 'dev_bob'});
      expect(aliceCall.currentEpoch(groupId), 1);
      expect(bobCall.currentEpoch(groupId), 1);

      Uint8List key(NativeCallGroupCrypto who, CallMember sender, int stream) =>
          who.mediaKey(groupId, 'call_1', sender, stream);
      final k1 = key(aliceCall, bobMember, 0);
      expect(key(bobCall, bobMember, 0), k1,
          reason: 'both derive the same key');
      expect(key(aliceCall, bobMember, 1), isNot(k1), reason: 'per stream');
      expect(key(aliceCall, aliceMember, 0), isNot(k1), reason: 'per sender');
      expect(aliceCall.mediaKey(groupId, 'call_2', bobMember, 0), isNot(k1),
          reason: 'per call');
      expect(() => key(aliceCall, bobMember, 4), throwsArgumentError);

      // Bob leaves and rejoins: his old leaf goes in the same commit that
      // adds his new one, so he is in the group once, with fresh keys.
      bobCall.drop(groupId);
      final again = bobCall.makeJoinOffer(groupId, 'nonce-2', 1800000060);
      final rejoin = aliceCall.stageCommit(groupId,
          adds: [(keyPackage: again.keyPackage, member: bobMember)],
          removes: [bobMember]);
      aliceCall.mergeStaged(groupId);
      final rejoined = bobCall.joinWithWelcome(groupId, rejoin.welcome!)!;
      expect(rejoined.map((m) => m.id).toList()..sort(),
          ['acct_alice/dev_alice', 'acct_bob/dev_bob']);
      expect(aliceCall.members(groupId), hasLength(2));
      expect(key(bobCall, bobMember, 0), key(aliceCall, bobMember, 0));
      expect(key(aliceCall, bobMember, 0), isNot(k1));

      // A sealed application message (the track announcement) opens only
      // for its real sender.
      final note = Uint8List.fromList(utf8.encode('tracks'));
      final sealed = bobCall.encryptApplication(groupId, note);
      expect(aliceCall.decryptApplication(groupId, sealed, bobMember), note);
      final forged = bobCall.encryptApplication(groupId, note);
      expect(() => aliceCall.decryptApplication(groupId, forged, aliceMember),
          throwsA(anything),
          reason: 'the MLS sender must be the member named');

      // Removing bob: a new epoch with a new key; bob cannot derive it.
      final kAliceEpoch1 = key(aliceCall, aliceMember, 0);
      final removal = aliceCall.stageCommit(groupId, removes: [bobMember]);
      aliceCall.mergeStaged(groupId);
      final k2 = key(aliceCall, aliceMember, 0);
      expect(k2, isNot(kAliceEpoch1));
      expect(aliceCall.currentEpoch(groupId), 3, reason: 'after the rejoin');
      final result = bobCall.processCommit(groupId, removal.commit);
      expect(result.removedSelf, isTrue);
      expect(() => key(aliceCall, bobMember, 0), throwsA(anything),
          reason: 'a removed device has no key');
      expect(() => key(bobCall, aliceMember, 0), throwsA(anything),
          reason: 'bob left the group and cannot derive the new epoch');
      aliceCall.drop(groupId);
      bobCall.drop(groupId);
      alice.close();
      bob.close();
    });
  }, skip: nativeCryptoSkip());
}
