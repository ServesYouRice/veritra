import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_codec.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

import 'native_test_env.dart';

/// C4 (ABI 20): the role record through the real native library, judged by
/// the real rules engine, the way the app will wire it: create with the
/// genesis, carry the record in a commit, stage a received commit, run
/// `validateCommit`, then merge or discard.
void main() {
  late NativeCryptoBindings bindings;
  final devices = <NativeCryptoDevice>[];

  setUp(() {
    // The codec-only test below needs no library; the native tests are
    // skipped (or required) by nativeCryptoSkip().
    if (nativeCryptoSkip() != false) return;
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  tearDown(() {
    for (final device in devices) {
      device.close();
    }
    devices.clear();
  });

  NativeCryptoDevice device(String name) {
    final created = bindings.createDevice('acct_$name', 'dev_$name');
    devices.add(created);
    return created;
  }

  Matcher failsWith(NativeCryptoError kind) =>
      throwsA(isA<NativeCryptoException>().having((e) => e.kind, 'kind', kind));

  ({
    List<int> keyPackage,
    List<int> accountId,
    List<int> deviceId,
    List<int> signingKey
  }) addOf(NativeCryptoDevice joiner, String name) => (
        keyPackage: joiner.createKeyPackage(),
        accountId: idBytes('acct_$name'),
        deviceId: idBytes('dev_$name'),
        signingKey: joiner.signingPublicKey(),
      );

  const group = 'conv_c4';

  /// Alice creates the group with her genesis and adds Bob and Carol with
  /// the record `requiredRecord` asks for; Bob and Carol join.
  GovernanceState threeMembers(NativeCryptoDevice alice, NativeCryptoDevice bob,
      NativeCryptoDevice carol) {
    final genesis = GovernanceState.genesis('acct_alice');
    alice.createGroupWithRoles(group, encodeGovernance(genesis));
    final created = alice.groupRoleState(group);
    expect(decodeGovernance(created.record!), genesis);
    expect(created.accounts, {'acct_alice'});

    final next = requiredRecord(genesis, 'acct_alice',
        before: {'acct_alice'},
        after: {'acct_alice', 'acct_bob', 'acct_carol'});
    final staged = alice.stageCommitWithRoles(group,
        record: encodeGovernance(next),
        adds: [addOf(bob, 'bob'), addOf(carol, 'carol')]);
    alice.mergePendingCommit(group);
    bob.joinGroup(group, staged.welcome);
    carol.joinGroup(group, staged.welcome);
    return next;
  }

  test('a joiner reads the record and a valid removal is reviewed and merged',
      () {
    final alice = device('alice');
    final bob = device('bob');
    final carol = device('carol');
    final state = threeMembers(alice, bob, carol);
    expect(state.joined.keys.toSet(), {'acct_alice', 'acct_bob', 'acct_carol'});
    for (final member in [bob, carol]) {
      final read = member.groupRoleState(group);
      expect(decodeGovernance(read.record!), state);
      expect(read.accounts, {'acct_alice', 'acct_bob', 'acct_carol'});
    }

    // Alice removes Carol and carries the pruned record.
    final pruned = requiredRecord(state, 'acct_alice',
        before: {'acct_alice', 'acct_bob', 'acct_carol'},
        after: {'acct_alice', 'acct_bob'});
    expect(pruned.joined.containsKey('acct_carol'), isFalse);
    final removal = alice.stageCommitWithRoles(group,
        record: encodeGovernance(pruned),
        removes: [
          (accountId: idBytes('acct_carol'), deviceId: idBytes('dev_carol'))
        ]);
    expect(removal.welcome, isEmpty);
    alice.mergePendingCommit(group);

    final review = bob.stageIncomingCommit(group, removal.commit);
    expect(review.removed, isTrue);
    expect(review.added, isFalse);
    expect(review.removedSelf, isFalse);
    expect(review.recordProposal, isTrue);
    expect(review.committerAccount, 'acct_alice');
    expect(review.committer.signingKey, alice.signingPublicKey());
    expect(review.accountsBefore, {'acct_alice', 'acct_bob', 'acct_carol'});
    expect(review.accountsAfter, {'acct_alice', 'acct_bob'});
    final prev = decodeGovernance(review.recordBefore!);
    final next = decodeGovernance(review.recordAfter!);
    expect(prev, state);
    final check = validateCommit(prev, next, review.committerAccount!,
        before: review.accountsBefore!, after: review.accountsAfter!);
    expect(check.ok, isTrue);
    // Staged, not merged.
    expect(bob.groupEpoch(group).epoch, 1);
    expect(decodeGovernance(bob.groupRoleState(group).record!), state);

    final merged = bob.mergeIncomingCommit(group, removal.commit);
    expect(merged.epoch, 2);
    expect(merged.removed, isTrue);
    expect(merged.root, isNotNull);
    expect(
        merged.committer,
        LeafPair(idBytes('acct_alice'), idBytes('dev_alice'),
            alice.signingPublicKey()));
    expect(bob.groupEpoch(group).epoch, 2);
    expect(decodeGovernance(bob.groupRoleState(group).record!), pruned);

    // Carol reviews her own removal and her group goes with it.
    final own = carol.stageIncomingCommit(group, removal.commit);
    expect(own.removedSelf, isTrue);
    expect(
        carol.mergeIncomingCommit(group, removal.commit).removedSelf, isTrue);
    expect(() => carol.groupRoleState(group),
        failsWith(NativeCryptoError.operationFailed));
  }, skip: nativeCryptoSkip());

  test('a member taking ownership is refused by the rules and discarded', () {
    final alice = device('alice');
    final bob = device('bob');
    final carol = device('carol');
    final state = threeMembers(alice, bob, carol);

    // Bob, a member, writes himself in as owner. Rust carries the bytes; the
    // rules engine refuses them on every receiver.
    final forged = state.copyWith(rev: state.rev + 1, owner: 'acct_bob');
    final change =
        bob.stageCommitWithRoles(group, record: encodeGovernance(forged));
    expect(change.welcome, isEmpty);

    final review = carol.stageIncomingCommit(group, change.commit);
    expect(review.recordProposal, isTrue);
    expect(review.removed || review.added, isFalse);
    expect(review.committerAccount, 'acct_bob');
    expect(review.accountsAfter, review.accountsBefore);
    final check = validateCommit(decodeGovernance(review.recordBefore!),
        decodeGovernance(review.recordAfter!), review.committerAccount!,
        before: review.accountsBefore!, after: review.accountsAfter!);
    expect(check.ok, isFalse);
    expect(carol.discardIncomingCommit(group), isTrue);
    expect(carol.discardIncomingCommit(group), isFalse);
    expect(() => carol.mergeIncomingCommit(group, change.commit),
        failsWith(NativeCryptoError.operationFailed));
    expect(carol.groupEpoch(group).epoch, 1);
    expect(decodeGovernance(carol.groupRoleState(group).record!), state);

    // The one-shot call never merges a record change.
    expect(() => alice.processCommit(group, change.commit),
        failsWith(NativeCryptoError.operationFailed));
    expect(alice.groupEpoch(group).epoch, 1);
  }, skip: nativeCryptoSkip());

  test('a merge must name the staged commit', () {
    final alice = device('alice');
    final bob = device('bob');
    final carol = device('carol');
    final state = threeMembers(alice, bob, carol);
    final fromBob = bob.stageCommitWithRoles(group,
        record: encodeGovernance(
            state.copyWith(rev: state.rev + 1, adminsOnlyPosting: true)));
    final fromAlice = alice.stageCommitWithRoles(group,
        record: encodeGovernance(
            state.copyWith(rev: state.rev + 1, adminsOnlyPosting: true)));
    expect(() => carol.mergeIncomingCommit(group, fromBob.commit),
        failsWith(NativeCryptoError.operationFailed));
    carol.stageIncomingCommit(group, fromAlice.commit);
    expect(() => carol.mergeIncomingCommit(group, fromBob.commit),
        failsWith(NativeCryptoError.operationFailed));
    // Still held: the right bytes merge.
    expect(carol.mergeIncomingCommit(group, fromAlice.commit).epoch, 2);
    expect(
        decodeGovernance(carol.groupRoleState(group).record!).adminsOnlyPosting,
        isTrue);
  }, skip: nativeCryptoSkip());

  test('records are bounded and must change; plain groups carry none', () {
    final alice = device('alice');
    expect(() => alice.createGroupWithRoles(group, const <int>[]),
        throwsArgumentError);
    expect(
        () => alice.createGroupWithRoles(
            group, Uint8List(roleRecordMaxBytes + 1)),
        throwsArgumentError);
    final genesis = encodeGovernance(GovernanceState.genesis('acct_alice'));
    alice.createGroupWithRoles(group, genesis);
    // The same record is not a change: nothing is staged.
    expect(() => alice.stageCommitWithRoles(group, record: genesis),
        failsWith(NativeCryptoError.operationFailed));
    expect(alice.groupEpoch(group).pending, isFalse);
    // A group without a record never gains one.
    alice.createGroup('conv_plain');
    final plain = alice.groupRoleState('conv_plain');
    expect(plain.record, isNull);
    expect(plain.accounts, {'acct_alice'});
    expect(() => alice.stageCommitWithRoles('conv_plain', record: genesis),
        failsWith(NativeCryptoError.operationFailed));
    // Garbage is not a commit, and nothing is held afterwards.
    expect(() => alice.stageIncomingCommit(group, const [1, 2, 3]),
        failsWith(NativeCryptoError.operationFailed));
    expect(alice.discardIncomingCommit(group), isFalse);
  }, skip: nativeCryptoSkip());

  test('an empty change list is only allowed with a record', () {
    expect(
        () => encodeKeyedMembershipChanges(adds: const [], removes: const []),
        throwsArgumentError);
    expect(
        encodeKeyedMembershipChanges(
            adds: const [], removes: const [], allowEmpty: true),
        [2, 0, 0, 0, 0]);
  });
}
