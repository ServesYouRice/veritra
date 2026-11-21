import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/community_info_book.dart';
import 'package:private_messenger/core/roles/ban_verdict.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/core/roles/private_channel_membership.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/community_info_codec.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/message_format.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';

// C4 record format 3 (docs/crypto.md, "C4 record format 3"): the C3
// channel-info switch, the W8 admin-only pin switch and the C5 ban list.
// Each forbidden action is tried as a hostile member's client would: a
// record it built itself, checked by the receivers' `validateCommit`. The
// native sequences (real OpenMLS, the app's receive path) are in
// c4_adversarial_native_test.dart.

const owner = 'acc_owner';
const admin = 'acc_admin';
const mod = 'acc_mod';
const member = 'acc_member';
const gone = 'acc_gone';

final roster = {owner, admin, mod, member};

GovernanceState record() => GovernanceState(
      rev: 5,
      owner: owner,
      ownerRev: 2,
      admins: {admin: 2},
      electors: {admin},
      moderators: {mod},
      joined: {owner: 0, admin: 1, mod: 3, member: 4},
    );

/// [actor]'s role-only commit moving [prev] to [next].
GovernanceReject? roleOnly(
  GovernanceState prev,
  GovernanceState next,
  String actor,
) =>
    validateCommit(prev, next, actor, before: roster, after: roster).reject;

/// [actor]'s commit taking [out] out of the roster with record [next].
GovernanceReject? removing(
  GovernanceState prev,
  GovernanceState next,
  String actor,
  String out,
) =>
    validateCommit(
      prev,
      next,
      actor,
      before: roster,
      after: roster.difference({out}),
    ).reject;

void main() {
  group('switches (C3 channel info, W8 pins)', () {
    final s = record();
    final next = s.rev + 1;

    test('an admin or the owner switches them; ownerRev stays', () {
      for (final actor in [owner, admin]) {
        for (final changed in [
          s.copyWith(rev: next, channelInfoRestricted: true),
          s.copyWith(rev: next, adminsOnlyPins: true),
        ]) {
          expect(roleOnly(s, changed, actor), isNull, reason: actor);
        }
      }
      // Not an owner role decision (D86's list is unchanged): an owner
      // commit that stamps ownerRev for a switch alone is refused.
      expect(
        roleOnly(
          s,
          s.copyWith(rev: next, ownerRev: next, adminsOnlyPins: true),
          owner,
        ),
        GovernanceReject.badShape,
      );
    });

    test('a hostile moderator or member cannot switch them on or off', () {
      final on = s.copyWith(channelInfoRestricted: true, adminsOnlyPins: true);
      for (final actor in [mod, member]) {
        for (final (from, to) in [
          (s, s.copyWith(rev: next, channelInfoRestricted: true)),
          (s, s.copyWith(rev: next, adminsOnlyPins: true)),
          (on, on.copyWith(rev: next, channelInfoRestricted: false)),
          (on, on.copyWith(rev: next, adminsOnlyPins: false)),
        ]) {
          expect(
            roleOnly(from, to, actor),
            GovernanceReject.notAllowed,
            reason: actor,
          );
        }
      }
    });

    test('a won election cannot carry a switch or a ban change', () {
      final open = s.copyWith(
        rev: next,
        election: Election(opened: next, electorate: {admin}),
      );
      final win = open.copyWith(
        rev: next + 1,
        owner: admin,
        ownerRev: next + 1,
        admins: {owner: next + 1},
        electors: const <String>{},
        clearElection: true,
      );
      expect(roleOnly(open, win, admin), isNull);
      for (final extra in [
        win.copyWith(adminsOnlyPins: true),
        win.copyWith(channelInfoRestricted: true),
        win.copyWith(bans: {gone}),
      ]) {
        expect(roleOnly(open, extra, admin), GovernanceReject.badShape);
      }
    });

    test('commands: admins only, never a no-op', () {
      expect(
        GovernanceCommands(state: s, actor: admin, members: roster)
            .setAdminsOnlyPins(true)
            .adminsOnlyPins,
        isTrue,
      );
      expect(
        GovernanceCommands(state: s, actor: owner, members: roster)
            .setChannelInfoRestricted(true)
            .ownerRev,
        s.ownerRev,
      );
      for (final actor in [mod, member]) {
        final c = GovernanceCommands(state: s, actor: actor, members: roster);
        expect(
          () => c.setAdminsOnlyPins(true),
          throwsA(isA<GovernanceCommandException>()),
        );
        expect(
          () => c.setChannelInfoRestricted(true),
          throwsA(isA<GovernanceCommandException>()),
        );
      }
      expect(
        () => GovernanceCommands(state: s, actor: admin, members: roster)
            .setAdminsOnlyPins(false),
        throwsA(
          isA<GovernanceCommandException>()
              .having((e) => e.reason, 'reason', 'no_change'),
        ),
      );
    });
  });

  group('bans (C5)', () {
    final s = record();
    final next = s.rev + 1;

    test('a moderator bans a member in the commit that removes it', () {
      final pruned = s.removeAccount(member);
      final banned = pruned.copyWith(rev: next, bans: {member});
      expect(removing(s, banned, mod, member), isNull);
      // recordWithBans builds exactly that for the producer.
      expect(
        recordWithBans(
          s,
          mod,
          before: roster,
          after: roster.difference({member}),
          banned: {member},
        ),
        banned,
      );
    });

    test('a hostile moderator cannot ban the admin above it', () {
      final banned = s.removeAccount(admin).copyWith(rev: next, bans: {admin});
      expect(removing(s, banned, mod, admin), GovernanceReject.hierarchy);
      expect(
        recordWithBans(
          s,
          mod,
          before: roster,
          after: roster.difference({admin}),
          banned: {admin},
        ),
        isNull,
      );
    });

    test('a hostile member cannot ban anyone', () {
      final banned = s.removeAccount(mod).copyWith(rev: next, bans: {mod});
      expect(removing(s, banned, member, mod), GovernanceReject.notAllowed);
      // Nor someone already gone.
      expect(
        roleOnly(s, s.copyWith(rev: next, bans: {gone}), member),
        GovernanceReject.notAllowed,
      );
    });

    test('banning someone already gone is an admin\'s call', () {
      expect(
        roleOnly(s, s.copyWith(rev: next, bans: {gone}), mod),
        GovernanceReject.notAllowed,
      );
      expect(roleOnly(s, s.copyWith(rev: next, bans: {gone}), admin), isNull);
    });

    test('a ban never keeps its account in the roster', () {
      // The admin "bans" a member but leaves it in: every app refuses.
      expect(
        roleOnly(s, s.copyWith(rev: next, bans: {member}), admin),
        GovernanceReject.banned,
      );
      // Nobody bans itself (it is in the roster) or the owner (shape).
      expect(
        roleOnly(s, s.copyWith(rev: next, bans: {admin}), admin),
        GovernanceReject.banned,
      );
      // The owner out of the roster stays owner (D81) and is never banned.
      final ownerGone = {admin, mod, member};
      final away = s.removeAccount(owner);
      expect(away.owner, owner);
      expect(
        validateCommit(
          away,
          away.copyWith(rev: next, bans: {owner}),
          admin,
          before: ownerGone,
          after: ownerGone,
        ).reject,
        GovernanceReject.badShape,
      );
    });

    test('nobody adds a banned account back, with or without a record', () {
      final b = s.copyWith(bans: {gone});
      final withGone = {...roster, gone};
      // A hostile member's add that stamps `joined` as required.
      final stamped =
          requiredRecord(b, member, before: roster, after: withGone);
      expect(
        validateCommit(b, stamped, member, before: roster, after: withGone)
            .reject,
        GovernanceReject.banned,
      );
      // An add that leaves the record as it was.
      expect(
        validateCommit(b, b, member, before: roster, after: withGone).reject,
        GovernanceReject.banned,
      );
      // Even the owner's add, unless it lifts the ban in the same commit.
      expect(
        validateCommit(b, stamped, owner, before: roster, after: withGone)
            .reject,
        GovernanceReject.banned,
      );
      final lifted = stamped.copyWith(bans: const <String>{});
      expect(
        validateCommit(b, lifted, owner, before: roster, after: withGone).ok,
        isTrue,
      );
      // A member cannot lift it to sneak the add through.
      expect(
        validateCommit(b, lifted, member, before: roster, after: withGone)
            .reject,
        GovernanceReject.notAllowed,
      );
    });

    test('only an admin or above lifts a ban', () {
      final b = s.copyWith(bans: {gone});
      final lifted = b.copyWith(rev: next, bans: const <String>{});
      expect(roleOnly(b, lifted, mod), GovernanceReject.notAllowed);
      expect(roleOnly(b, lifted, member), GovernanceReject.notAllowed);
      expect(roleOnly(b, lifted, admin), isNull);
    });

    test('a removal keeps every ban (pruning never drops one)', () {
      final b = s.copyWith(bans: {gone});
      final pruned = requiredRecord(
        b,
        mod,
        before: roster,
        after: roster.difference({member}),
      );
      expect(pruned.bans, {gone});
      expect(removing(b, pruned, mod, member), isNull);
      final dropped = pruned.copyWith(bans: const <String>{});
      expect(removing(b, dropped, mod, member), isNot(isNull));
    });

    test('commands: ban only who is gone, admins only; lift admins only', () {
      final c = GovernanceCommands(state: s, actor: admin, members: roster);
      expect(c.ban(gone).bans, {gone});
      expect(c.banAll({gone, 'acc_gone2'}).bans, {gone, 'acc_gone2'});
      expect(
        () => c.ban(member),
        throwsA(
          isA<GovernanceCommandException>()
              .having((e) => e.reason, 'reason', 'still_member'),
        ),
      );
      expect(
        () =>
            GovernanceCommands(state: s, actor: mod, members: roster).ban(gone),
        throwsA(isA<GovernanceCommandException>()),
      );
      final b = s.copyWith(bans: {gone});
      expect(
        GovernanceCommands(state: b, actor: admin, members: roster)
            .liftBan(gone)
            .bans,
        isEmpty,
      );
      expect(
        () => GovernanceCommands(state: b, actor: mod, members: roster)
            .liftBan(gone),
        throwsA(isA<GovernanceCommandException>()),
      );
    });

    test('private channels: no banned newcomer, from any committer', () {
      final b = s.copyWith(bans: {gone});
      expect(
        privateChannelAddAccepted(
          record: b,
          committer: owner,
          before: {owner},
          after: {owner, gone},
        ),
        isFalse,
      );
      expect(
        privateChannelAddAccepted(
          record: b,
          committer: owner,
          before: {owner},
          after: {owner, member},
        ),
        isTrue,
      );
      expect(
        privateChannelAddableAccounts(
          record: b,
          self: owner,
          inGroup: {gone},
          picked: {gone, member},
          candidates: {gone, member},
        ),
        {member},
      );
    });

    test('content from a banned sender is hidden, control payloads kept', () {
      final b = s.copyWith(bans: {gone});
      expect(
        shouldDropBannedPost(
          record: b,
          sender: gone,
          type: AppPayloadType.text,
        ),
        isTrue,
      );
      expect(
        shouldDropBannedPost(
          record: b,
          sender: gone,
          type: AppPayloadType.pin,
        ),
        isTrue,
      );
      expect(
        shouldDropBannedPost(
          record: b,
          sender: gone,
          type: AppPayloadType.memberLeave,
        ),
        isFalse,
      );
      expect(
        shouldDropBannedPost(
          record: b,
          sender: member,
          type: AppPayloadType.text,
        ),
        isFalse,
      );
      expect(
        shouldDropBannedPost(
          record: null,
          sender: gone,
          type: AppPayloadType.text,
        ),
        isFalse,
      );
    });

    test('owed bans lapse and round-trip', () {
      final now = DateTime.utc(2026, 11, 21);
      final later = now.add(banRecordOwedLifetime).millisecondsSinceEpoch;
      final stored = encodeOwedBans({gone: later, member: 1});
      expect(decodeOwedBans(stored, now), {gone: later});
      expect(banRecordOwedSetting('g1'), 'c5.ban_record.g1');
    });
  });

  group('W8 admin-only pins', () {
    test('pinAllowed: the switch narrows groups and communities', () {
      expect(pinAllowed(kind: 'group', role: 'member'), isTrue);
      expect(
        pinAllowed(kind: 'group', role: 'member', adminsOnly: true),
        isFalse,
      );
      expect(
        pinAllowed(kind: 'group', role: 'moderator', adminsOnly: true),
        isFalse,
      );
      expect(
        pinAllowed(kind: 'group', role: 'admin', adminsOnly: true),
        isTrue,
      );
      expect(
        pinAllowed(kind: 'group', role: 'owner', adminsOnly: true),
        isTrue,
      );
      // A removed leaf (D120) has no role.
      expect(pinAllowed(kind: 'group', role: null, adminsOnly: true), isFalse);
      expect(
        pinAllowed(kind: 'community_shared', role: 'moderator'),
        isTrue,
      );
      expect(
        pinAllowed(
          kind: 'community_shared',
          role: 'moderator',
          adminsOnly: true,
        ),
        isFalse,
      );
      expect(pinAllowed(kind: 'dm', role: null, adminsOnly: true), isTrue);
    });

    test('GovernanceState.mayPin mirrors it', () {
      final s = record();
      final on = s.copyWith(adminsOnlyPins: true);
      expect(s.mayPin(member, community: false), isTrue);
      expect(s.mayPin(member, community: true), isFalse);
      expect(s.mayPin(mod, community: true), isTrue);
      expect(on.mayPin(mod, community: false), isFalse);
      expect(on.mayPin(admin, community: true), isTrue);
    });

    List<MessageEffect> pinFrom(
      String sender,
      String role,
      GovernanceState state,
    ) =>
        messageEffectsFor(
          const DecryptedAppPayload(
            type: AppPayloadType.pin,
            actionId: 'p1',
            body: {
              'message_id': 'dev_x:m1',
              'pinned': true,
              'duration_seconds': 86400,
            },
          ),
          conversationId: 'conv',
          senderAccountId: sender,
          senderDeviceId: 'dev_$sender',
          createdAt: 1,
          state: LocalMessageState.received,
          authority: _Roles(state, role: role),
        );

    test('a member\'s pin applies until admins switch pins off for it', () {
      final s = record();
      expect(
        pinFrom(member, 'member', s).whereType<PinMessageEffect>(),
        hasLength(1),
      );
      final on = s.copyWith(adminsOnlyPins: true);
      // The hostile member's pin (or unpin) still arrives as a row, but no
      // app applies it.
      expect(
        pinFrom(member, 'member', on).whereType<PinMessageEffect>(),
        isEmpty,
      );
      expect(
        pinFrom(mod, 'moderator', on).whereType<PinMessageEffect>(),
        isEmpty,
      );
      expect(
        pinFrom(admin, 'admin', on).whereType<PinMessageEffect>(),
        hasLength(1),
      );
    });
  });

  group('C3 channel info switch', () {
    test('restricted: moderators and above edit channel info', () {
      final s = record();
      final on = s.copyWith(channelInfoRestricted: true);
      final open = GovernanceInfoEditPolicy(s);
      final closed = GovernanceInfoEditPolicy(on);
      for (final editor in [owner, admin, mod, member]) {
        expect(open.mayEdit(editor, infoKindChannel), isTrue, reason: editor);
      }
      expect(closed.mayEdit(owner, infoKindChannel), isTrue);
      expect(closed.mayEdit(admin, infoKindChannel), isTrue);
      expect(closed.mayEdit(mod, infoKindChannel), isTrue);
      expect(closed.mayEdit(member, infoKindChannel), isFalse);
      // Community and category stay owner and admins either way.
      for (final policy in [open, closed]) {
        expect(policy.mayEdit(mod, infoKindCommunity), isFalse);
        expect(policy.mayEdit(admin, infoKindCategory), isTrue);
      }
      // The test override can only narrow, never widen the record.
      expect(
        GovernanceInfoEditPolicy(on, channelInfoRestricted: false)
            .mayEdit(member, infoKindChannel),
        isFalse,
      );
    });
  });
}

class _Roles implements ConversationAuthority, VerifiedRoleSource {
  _Roles(this.state, {this.role});
  final GovernanceState? state;
  final String? role;
  @override
  GovernanceState? governanceOf(String conversationId) => state;
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
  @override
  String? roleOf(String conversationId, String accountId) => role;
  @override
  Set<String> memberAccounts(String conversationId) => roster;
  @override
  String? conversationKind(String conversationId) => 'group';
  @override
  String? conversationChannel(String conversationId) => null;
}
