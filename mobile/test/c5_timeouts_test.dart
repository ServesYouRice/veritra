import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_codec.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';
import 'package:private_messenger/core/roles/timeout_verdict.dart';
import 'package:private_messenger/crypto/app_payload.dart';

// C5 timeouts in the verified C4 record (docs/crypto.md, "C5 timeouts in the
// record") and the receiver's verdict, judged as the server decides.

const owner = 'acc_owner';
const admin = 'acc_admin';
const mod = 'acc_mod';
const bob = 'acc_bob';
const carol = 'acc_carol';
final roster = {owner, admin, mod, bob, carol};

GovernanceState base() => GovernanceState(
      rev: 5,
      owner: owner,
      ownerRev: 2,
      admins: {admin: 1},
      moderators: {mod},
      joined: {owner: 0, admin: 1, mod: 2, bob: 3, carol: 4},
    );

const t0 = 1700000000000;
const tenMinutes = 600000;
const timeout = MemberTimeout(epoch: 12, fromMs: t0, untilMs: t0 + tenMinutes);

GovernanceCheck check(GovernanceState prev, GovernanceState next, String by,
        {int? epoch = 12}) =>
    validateCommit(prev, next, by, before: roster, after: roster, epoch: epoch);

GovernanceState withTimeout(GovernanceState s, String who, MemberTimeout t) =>
    s.copyWith(rev: s.rev + 1, timeouts: {...s.timeouts, who: t});

void main() {
  group('record rules', () {
    test('a moderator who outranks the member sets and lifts a timeout', () {
      final prev = base();
      final set = withTimeout(prev, bob, timeout);
      expect(check(prev, set, mod).ok, isTrue);
      final lifted = set.copyWith(rev: set.rev + 1, timeouts: const {});
      expect(check(set, lifted, mod).ok, isTrue);
      // The owner's last role decision does not move.
      expect(set.ownerRev, prev.ownerRev);
    });

    test('nobody times out an equal, a superior, themselves or the owner', () {
      final prev = base();
      expect(check(prev, withTimeout(prev, admin, timeout), mod).reject,
          GovernanceReject.hierarchy);
      expect(check(prev, withTimeout(prev, mod, timeout), mod).reject,
          GovernanceReject.notAllowed);
      expect(check(prev, withTimeout(prev, owner, timeout), admin).reject,
          GovernanceReject.hierarchy);
      expect(check(prev, withTimeout(prev, carol, timeout), bob).reject,
          GovernanceReject.notAllowed);
    });

    test('a member cannot lift its own timeout or another', () {
      final set = withTimeout(base(), bob, timeout);
      final lifted = set.copyWith(rev: set.rev + 1, timeouts: const {});
      expect(check(set, lifted, bob).ok, isFalse);
      expect(check(set, lifted, carol).ok, isFalse);
    });

    test('a set timeout names the epoch this commit produces', () {
      final prev = base();
      final set = withTimeout(prev, bob, timeout);
      expect(
          check(prev, set, mod, epoch: 13).reject, GovernanceReject.badShape);
      expect(
          check(prev, set, mod, epoch: null).reject, GovernanceReject.badShape);
    });

    test('a timeout longer than 28 days or ending before it starts is refused',
        () {
      final prev = base();
      final long = MemberTimeout(
          epoch: 12, fromMs: t0, untilMs: t0 + maxTimeoutMillis + 1);
      final backwards = MemberTimeout(epoch: 12, fromMs: t0, untilMs: t0);
      expect(check(prev, withTimeout(prev, bob, long), mod).reject,
          GovernanceReject.badShape);
      expect(check(prev, withTimeout(prev, bob, backwards), mod).reject,
          GovernanceReject.badShape);
    });

    test('equality sees a timeout-only edit, so it is never waved through', () {
      final set = withTimeout(base(), bob, timeout);
      final edited = set.copyWith(timeouts: {
        bob: const MemberTimeout(epoch: 12, fromMs: t0, untilMs: t0 + 1)
      });
      expect(edited == set, isFalse);
      // The same rev with a changed timeout is neither required nor a change.
      expect(check(set, edited, bob).ok, isFalse);
    });

    test('a removal prunes the leaver\'s timeout', () {
      final set = withTimeout(base(), bob, timeout);
      final after = roster.difference({bob});
      final required = requiredRecord(set, carol, before: roster, after: after);
      expect(required.timeouts, isEmpty);
      expect(
          validateCommit(set, set, carol, before: roster, after: after).reject,
          GovernanceReject.notPruned);
    });

    test('a timeout entry for an account outside the roster is refused', () {
      final prev = base();
      final next = withTimeout(prev, 'acc_stranger', timeout);
      expect(check(prev, next, mod).reject, GovernanceReject.notMember);
    });
  });

  group('codec', () {
    test('round-trips timeouts and keeps records without them unchanged', () {
      final set = withTimeout(base(), bob, timeout);
      expect(decodeGovernance(encodeGovernance(set)), set);
      final plain = base();
      final bytes = encodeGovernance(plain);
      expect(bytes[17] & 4, 0, reason: 'no timeouts flag');
      expect(decodeGovernance(bytes), plain);
    });
  });

  group('commands', () {
    test('setTimeout records the server times at the next epoch', () {
      final commands = GovernanceCommands(
          state: base(), actor: mod, members: roster, epoch: 12);
      final next =
          commands.setTimeout(bob, fromMs: t0, untilMs: t0 + tenMinutes);
      expect(next.timeouts[bob], timeout);
      expect(next.rev, base().rev + 1);
      final lifted = GovernanceCommands(
              state: next, actor: mod, members: roster, epoch: 13)
          .liftTimeout(bob);
      expect(lifted.timeouts, isEmpty);
    });

    test('refuses without an epoch, against a superior, or with no entry', () {
      expect(
          () => GovernanceCommands(state: base(), actor: mod, members: roster)
              .setTimeout(bob, fromMs: t0, untilMs: t0 + 1),
          throwsA(isA<GovernanceCommandException>()
              .having((e) => e.reason, 'reason', 'no_epoch')));
      expect(
          () => GovernanceCommands(
                  state: base(), actor: mod, members: roster, epoch: 12)
              .setTimeout(admin, fromMs: t0, untilMs: t0 + 1),
          throwsA(isA<GovernanceCommandException>()));
      expect(
          () => GovernanceCommands(
                  state: base(), actor: mod, members: roster, epoch: 12)
              .liftTimeout(bob),
          throwsA(isA<GovernanceCommandException>()
              .having((e) => e.reason, 'reason', 'no_change')));
    });
  });

  group('receiver verdict', () {
    final record = withTimeout(base(), bob, timeout);
    DateTime at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    bool drop(int serverMs, {int? receivedMs, int? epoch, String who = bob}) =>
        shouldDropTimedOutPost(
          record: record,
          sender: who,
          serverTime: at(serverMs),
          receivedAt: at(receivedMs ?? serverMs),
          postEpoch: epoch,
        );

    test('hides a post the server stamped inside the timeout', () {
      expect(drop(t0), isTrue);
      expect(drop(t0 + tenMinutes - 1), isTrue);
    });

    test('shows a post at or after the end, and from anyone else', () {
      expect(drop(t0 + tenMinutes), isFalse);
      expect(drop(t0 + 1, who: carol), isFalse);
      expect(
          shouldDropTimedOutPost(
              record: null,
              sender: bob,
              serverTime: at(t0),
              receivedAt: at(t0)),
          isFalse);
    });

    test('a post made before the timeout began is not hidden when read later',
        () {
      // An older post, fetched long after: its epoch is before the timeout's.
      expect(drop(t0 - 1, receivedMs: t0 + 5000, epoch: 11), isFalse);
      // A private channel post (no comparable epoch) before the start too.
      expect(drop(t0 - 1, receivedMs: t0 + 5000), isFalse);
    });

    test('a post backdated before the start is hidden by its epoch', () {
      expect(drop(t0 - 60000, receivedMs: t0 + 1000, epoch: 12), isTrue);
      expect(drop(t0 - 60000, receivedMs: t0 + 1000, epoch: 13), isTrue);
    });

    test('a server time far after this device\'s clock is not believed', () {
      // A day-long timeout, a post stamped after its end but delivered at
      // its start: judged at this device's time plus the tolerance, inside.
      const day = 24 * 60 * 60 * 1000;
      final long = withTimeout(base(), bob,
          const MemberTimeout(epoch: 12, fromMs: t0, untilMs: t0 + day));
      expect(
          shouldDropTimedOutPost(
              record: long,
              sender: bob,
              serverTime: at(t0 + day + 1),
              receivedAt: at(t0)),
          isTrue);
      // Delivered after the end, it shows (the residual: a server may hold a
      // timed-out post back until the timeout is over).
      expect(
          shouldDropTimedOutPost(
              record: long,
              sender: bob,
              serverTime: at(t0 + day + 1),
              receivedAt: at(t0 + day + 1)),
          isFalse);
      // A modest skew within the tolerance near the end keeps honest posts.
      final skew = timeoutClockTolerance.inMilliseconds - 1000;
      expect(
          drop(t0 + tenMinutes, receivedMs: t0 + tenMinutes - skew), isFalse);
    });

    test('control payloads are never judged by a timeout', () {
      for (final type in <AppPayloadType>[
        AppPayloadType.memberLeave,
        AppPayloadType.infoKey,
        AppPayloadType.infoKeyRequest,
        AppPayloadType.infoUpdate,
        AppPayloadType.profileKey,
        AppPayloadType.groupProfileKey,
        AppPayloadType.historyChange,
        AppPayloadType.historySync,
        AppPayloadType.historySyncRequest,
        AppPayloadType.callSignal,
        AppPayloadType.delete,
      ]) {
        expect(timeoutRefusedTypes.contains(type), isFalse, reason: '$type');
      }
      for (final type in <AppPayloadType>[
        AppPayloadType.text,
        AppPayloadType.reply,
        AppPayloadType.edit,
        AppPayloadType.reaction,
        AppPayloadType.attachmentManifest,
      ]) {
        expect(timeoutRefusedTypes.contains(type), isTrue, reason: '$type');
      }
    });
  });
}
