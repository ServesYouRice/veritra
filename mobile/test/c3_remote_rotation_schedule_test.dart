import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/community_info_book.dart';
import 'package:private_messenger/core/community_info_service.dart';
import 'package:private_messenger/core/roles/governance.dart';

// C3 remote removals: the order in which owners and admins rotate and how
// long each waits (docs/designs/C3-private-channels-and-info.md, "Remote
// removals: who rotates"). Pure functions; no native crypto.

const _home = InfoKeyHome(
    keySubjectKind: 'community',
    keySubjectId: 'comm_1',
    conversationId: 'conv_shared');

void main() {
  final rotators = [for (var i = 0; i < 12; i++) 'acct_$i'];

  test('every member computes the same distinct order for one removal', () {
    final ranks = [
      for (final a in rotators)
        remoteRotationRank(
            rotators: rotators, accountId: a, home: _home, epoch: 7),
    ];
    // The input order does not matter.
    final shuffled = rotators.reversed.toList();
    for (final a in rotators) {
      expect(
          remoteRotationRank(
              rotators: shuffled, accountId: a, home: _home, epoch: 7),
          ranks[rotators.indexOf(a)]);
    }
    // Ranks below the cap are distinct; the rest share the cap.
    final below = ranks.where((r) => r < remoteRotationMaxRank).toList();
    expect(below.toSet().length, below.length);
    expect(below.length, remoteRotationMaxRank);
    expect(ranks.every((r) => r >= 0 && r <= remoteRotationMaxRank), isTrue);
  });

  test('the order changes between removals and between key homes', () {
    String first(InfoKeyHome home, int epoch) => rotators.firstWhere((a) =>
        remoteRotationRank(
            rotators: rotators, accountId: a, home: home, epoch: epoch) ==
        0);
    final firsts = {
      for (var epoch = 1; epoch <= 20; epoch++) first(_home, epoch),
    };
    // No single admin (an often-offline owner, say) is always first.
    expect(firsts.length, greaterThan(1));
    const other = InfoKeyHome(
        keySubjectKind: 'channel',
        keySubjectId: 'chan_1',
        conversationId: 'conv_private');
    expect([for (var e = 1; e <= 20; e++) first(other, e)],
        isNot([for (var e = 1; e <= 20; e++) first(_home, e)]));
  });

  test('an account outside the verified rotators is rank 0', () {
    expect(
        remoteRotationRank(
            rotators: const ['acct_a'],
            accountId: 'acct_x',
            home: _home,
            epoch: 1),
        0);
  });

  test('waits: base plus one slot per rank plus a bounded, stable jitter', () {
    for (var rank = 0; rank <= remoteRotationMaxRank + 3; rank++) {
      for (final device in ['dev_a', 'dev_b', 'dev_c']) {
        final wait = remoteRotationDelay(
            rank: rank, deviceId: device, home: _home, epoch: 3);
        final floor = remoteRotationBase +
            remoteRotationSlot *
                (rank > remoteRotationMaxRank ? remoteRotationMaxRank : rank);
        expect(wait >= floor, isTrue);
        expect(wait < floor + remoteRotationJitter, isTrue);
        // A restart computes the same wait.
        expect(
            remoteRotationDelay(
                rank: rank, deviceId: device, home: _home, epoch: 3),
            wait);
      }
    }
    // The worst case stays a few minutes.
    expect(
        remoteRotationDelay(
                rank: 100, deviceId: 'dev_a', home: _home, epoch: 3) <
            const Duration(minutes: 5),
        isTrue);
    // A rank-1 device always waits longer than any rank-0 device.
    expect(
        remoteRotationBase + remoteRotationJitter <=
            remoteRotationBase + remoteRotationSlot,
        isTrue);
  });

  test('two devices of one account spread out', () {
    final waits = {
      for (var i = 0; i < 20; i++)
        remoteRotationDelay(rank: 0, deviceId: 'dev_$i', home: _home, epoch: 3),
    };
    expect(waits.length, greaterThan(1));
  });

  test('the owner (while in the roster) and admins rotate; moderators never',
      () {
    final roles = GovernanceState(
      rev: 3,
      owner: 'acct_owner',
      ownerRev: 3,
      admins: const {'acct_admin': 2},
      moderators: const {'acct_mod'},
      joined: const {
        'acct_owner': 0,
        'acct_admin': 1,
        'acct_mod': 1,
        'acct_member': 1,
      },
    );
    expect(verifiedRotators(roles), {'acct_owner', 'acct_admin'});
    final gone = GovernanceState(
      rev: 4,
      owner: 'acct_owner',
      ownerRev: 3,
      admins: const {'acct_admin': 2},
      moderators: const {'acct_mod'},
      joined: const {'acct_admin': 1, 'acct_mod': 1},
    );
    // An owner no longer in the roster cannot be online: it takes no turn.
    expect(verifiedRotators(gone), {'acct_admin'});
  });
}
