import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';

void main() {
  const owner = 'acct_owner';
  const admin = 'acct_admin';
  const mod = 'acct_mod';
  const bob = 'acct_bob';
  const carol = 'acct_carol';
  const members = {owner, admin, mod, bob, carol};

  // rev 3: admin since rev 1, moderator since rev 2.
  GovernanceState base() => GovernanceState(
        rev: 3,
        owner: owner,
        admins: {admin: 1},
        moderators: {mod},
      );

  GovernanceCheck check(
    GovernanceState prev,
    GovernanceState next,
    String who, {
    Set<String> roster = members,
  }) =>
      validateTransition(prev, next, who, members: roster);

  GovernanceState bump(
    GovernanceState s, {
    String? owner,
    Map<String, int>? admins,
    Set<String>? moderators,
    bool? adminsOnlyPosting,
    Set<String>? announcementChannels,
  }) =>
      s.copyWith(
        rev: s.rev + 1,
        owner: owner,
        admins: admins,
        moderators: moderators,
        adminsOnlyPosting: adminsOnlyPosting,
        announcementChannels: announcementChannels,
      );

  group('roles and posting', () {
    test('genesis: the creator owns the group, nobody else has a role', () {
      final g = GovernanceState.genesis(owner);
      expect(g.rev, 0);
      expect(g.roleOf(owner), BuiltInRole.owner);
      expect(g.roleOf(bob), BuiltInRole.member);
      expect(g.isRestricted(), isFalse);
    });

    test('ranks mirror the server (owner 4 .. member 1)', () {
      final s = base();
      expect(s.rankOf(owner), 4);
      expect(s.rankOf(admin), 3);
      expect(s.rankOf(mod), 2);
      expect(s.rankOf(bob), 1);
    });

    test('restricted posting: owner and admin only, not moderators', () {
      final s = base().copyWith(announcementChannels: {'chan_news'});
      for (final who in [owner, admin, mod, bob]) {
        expect(s.mayPost(who, channelId: 'chan_talk'), isTrue);
      }
      expect(s.mayPost(owner, channelId: 'chan_news'), isTrue);
      expect(s.mayPost(admin, channelId: 'chan_news'), isTrue);
      expect(s.mayPost(mod, channelId: 'chan_news'), isFalse);
      expect(s.mayPost(bob, channelId: 'chan_news'), isFalse);

      final whole = base().copyWith(adminsOnlyPosting: true);
      expect(whole.mayPost(admin), isTrue);
      expect(whole.mayPost(mod), isFalse);
      expect(whole.mayPost(bob, channelId: 'any'), isFalse);
    });

    test('mayActOn needs moderator or above and a strictly higher rank', () {
      final s = base();
      expect(s.mayActOn(mod, bob), isTrue);
      expect(s.mayActOn(admin, mod), isTrue);
      expect(s.mayActOn(mod, admin), isFalse);
      expect(s.mayActOn(bob, carol), isFalse);
      expect(s.mayActOn(admin, admin), isFalse);
      expect(s.mayActOn(admin, owner), isFalse);
      expect(s.mayActOn(owner, admin), isTrue);
    });
  });

  group('transitions', () {
    test('rev must advance by exactly one', () {
      final s = base();
      final same = s.copyWith(moderators: {mod, bob});
      expect(check(s, same, admin).reject, GovernanceReject.badRev);
      final skip = s.copyWith(rev: s.rev + 2, moderators: {mod, bob});
      expect(check(s, skip, admin).reject, GovernanceReject.badRev);
      expect(check(s, bump(s, moderators: {mod, bob}), admin).ok, isTrue);
    });

    test('two concurrent edits from the same prev: the second is stale', () {
      final s = base();
      final first = bump(s, moderators: {mod, bob});
      final second = bump(s, moderators: {mod, carol});
      expect(check(s, first, admin).ok, isTrue);
      expect(check(first, second, admin).reject, GovernanceReject.badRev);
    });

    test('a plain member cannot give anyone a role', () {
      final s = base();
      expect(
        check(s, bump(s, moderators: {mod, carol}), bob).reject,
        GovernanceReject.notAllowed,
      );
    });

    test('an admin promotes a member; a new admin starts at this rev', () {
      final s = base();
      final ok = bump(s, admins: {admin: 1, bob: s.rev + 1});
      expect(check(s, ok, admin).ok, isTrue);
      expect(ok.roleOf(bob), BuiltInRole.admin);
      final backdated = bump(s, admins: {admin: 1, bob: 0});
      expect(check(s, backdated, admin).reject, GovernanceReject.badShape);
      final reset = bump(s, admins: {admin: s.rev + 1});
      expect(check(s, reset, owner).reject, GovernanceReject.badShape);
    });

    test('hierarchy: target strictly below, new role at most own rank', () {
      final s = base();
      // A moderator may make a moderator, as the server allows.
      expect(check(s, bump(s, moderators: {mod, bob}), mod).ok, isTrue);
      // Not an admin.
      expect(
        check(s, bump(s, admins: {admin: 1, bob: 4}), mod).reject,
        GovernanceReject.hierarchy,
      );
      // An admin may not touch another admin, nor a moderator its peer.
      final twoAdmins = s.copyWith(admins: {admin: 1, carol: 2});
      expect(
        check(twoAdmins, bump(twoAdmins, admins: {admin: 1}), admin).reject,
        GovernanceReject.hierarchy,
      );
      final twoMods = s.copyWith(moderators: {mod, carol});
      expect(
        check(twoMods, bump(twoMods, moderators: {mod}), mod).reject,
        GovernanceReject.hierarchy,
      );
      // The owner may demote an admin.
      expect(
        check(s, bump(s, admins: const {}, moderators: {mod}), owner).ok,
        isTrue,
      );
    });

    test('anyone may step down; nobody may take a role', () {
      final s = base();
      expect(check(s, bump(s, moderators: const {}), mod).ok, isTrue);
      final adminToMod = bump(s, admins: const {}, moderators: {mod, admin});
      expect(check(s, adminToMod, admin).ok, isTrue);
      final take = bump(s, admins: {admin: 1, mod: 4}, moderators: const {});
      expect(check(s, take, mod).reject, GovernanceReject.hierarchy);
      // Stepping down cannot widen posting rights either.
      final news = s.copyWith(announcementChannels: {'chan_news'});
      final down = bump(news, admins: const {});
      expect(check(news, down, admin).ok, isTrue);
      expect(down.mayPost(admin, channelId: 'chan_news'), isFalse);
    });

    test('ownership: owner only, to a current admin; it cannot be vacated', () {
      final s = base();
      final toAdmin = bump(s, owner: admin, admins: {owner: s.rev + 1});
      expect(check(s, toAdmin, owner).ok, isTrue);
      expect(toAdmin.roleOf(owner), BuiltInRole.admin);
      // The old owner may also step down to member.
      expect(
        check(s, bump(s, owner: admin, admins: const {}), owner).ok,
        isTrue,
      );
      // Not by an admin, not to a moderator or member.
      expect(
        check(s, bump(s, owner: admin, admins: const {}), admin).reject,
        GovernanceReject.ownerChange,
      );
      expect(
        check(s, bump(s, owner: mod, moderators: const {}), owner).reject,
        GovernanceReject.ownerChange,
      );
      expect(
        check(s, bump(s, owner: bob), owner).reject,
        GovernanceReject.ownerChange,
      );
      final vacate = s.copyWith(rev: s.rev + 1, clearOwner: true);
      expect(check(s, vacate, owner).reject, GovernanceReject.ownerChange);
    });

    test('the owner is never also an admin or moderator', () {
      final s = base();
      expect(
        check(s, bump(s, moderators: {mod, owner}), owner).reject,
        GovernanceReject.badShape,
      );
      expect(
        check(s, bump(s, moderators: {mod, admin}), owner).reject,
        GovernanceReject.badShape,
      );
    });

    test('roles go only to members of the MLS roster', () {
      final s = base();
      expect(
        check(s, bump(s, moderators: {mod, 'acct_stranger'}), admin).reject,
        GovernanceReject.notMember,
      );
      expect(
        check(s, bump(s, moderators: {mod, bob}), 'acct_stranger').reject,
        GovernanceReject.notMember,
      );
    });

    test('posting restrictions need admin or above', () {
      final s = base();
      expect(
        check(s, bump(s, adminsOnlyPosting: true), mod).reject,
        GovernanceReject.notAllowed,
      );
      expect(check(s, bump(s, adminsOnlyPosting: true), admin).ok, isTrue);
      expect(
        check(s, bump(s, announcementChannels: {'chan_news'}), bob).reject,
        GovernanceReject.notAllowed,
      );
      // A channel this device has not fetched yet is not an input: kept.
      expect(
        check(s, bump(s, announcementChannels: {'chan_not_synced'}), admin).ok,
        isTrue,
      );
      expect(
        check(s, bump(s, announcementChannels: {''}), admin).reject,
        GovernanceReject.badShape,
      );
    });
  });

  group('removals and succession', () {
    test('a departed admin is pruned; invited back, it is a member', () {
      final s = base().copyWith(admins: {admin: 1, carol: 2});
      const after = {owner, admin, mod, bob};
      // Without the prune every later change names carol and is refused.
      expect(
        check(s, bump(s, moderators: {mod, bob}), admin, roster: after).reject,
        GovernanceReject.notMember,
      );
      final pruned = s.removeAccount(carol, remaining: after);
      expect(pruned.rev, s.rev);
      expect(pruned.roleOf(carol), BuiltInRole.member);
      expect(
        check(
          pruned,
          bump(pruned, moderators: {mod, bob}),
          admin,
          roster: after,
        ).ok,
        isTrue,
      );
    });

    test('the oldest admin inherits; ties go to the smaller account id', () {
      final s = base().copyWith(admins: {admin: 2, 'acct_aaa': 2, carol: 1});
      // carol is oldest but left in the same commit.
      const after = {admin, 'acct_aaa', mod, bob};
      final next = s.removeAccount(owner, remaining: after);
      expect(next.owner, 'acct_aaa');
      expect(next.admins.containsKey('acct_aaa'), isFalse);
      expect(next.admins[admin], 2);
      const withCarol = {admin, 'acct_aaa', carol, mod, bob};
      expect(s.removeAccount(owner, remaining: withCarol).owner, carol);
      // A moderator never inherits, however long it has been there.
      expect(next.roleOf(mod), BuiltInRole.moderator);
    });

    test('with no admin left, nobody inherits and nobody can claim it', () {
      final s = base().copyWith(admins: const {});
      final next = s.removeAccount(owner, remaining: {mod, bob, carol});
      expect(next.owner, isNull);
      expect(next.roleOf(mod), BuiltInRole.moderator);
      final claim = bump(next, owner: mod, moderators: const {});
      expect(
        check(next, claim, mod, roster: {mod, bob, carol}).reject,
        GovernanceReject.ownerChange,
      );
      // Moderators keep working.
      expect(
        check(
          next,
          bump(next, moderators: {mod, bob}),
          mod,
          roster: {mod, bob, carol},
        ).ok,
        isTrue,
      );
    });
  });

  group('commits', () {
    test('a commit that removes a named account must prune it', () {
      final s = base();
      const after = {owner, admin, bob, carol};
      expect(
        validateCommit(s, s, bob, before: members, after: after).reject,
        GovernanceReject.notPruned,
      );
      final pruned = s.removeAccount(mod, remaining: after);
      // Pruning alone needs no role: any committer may carry it.
      expect(
        validateCommit(s, pruned, bob, before: members, after: after).ok,
        isTrue,
      );
      // Removing an unnamed member leaves the extension as it is.
      expect(
        validateCommit(
          s,
          s,
          bob,
          before: members,
          after: {owner, admin, mod, bob},
        ).ok,
        isTrue,
      );
    });

    test('removing the owner must carry the succession', () {
      final s = base();
      const after = {admin, mod, bob, carol};
      final expected = s.removeAccount(owner, remaining: after);
      expect(expected.owner, admin);
      expect(
        validateCommit(s, expected, mod, before: members, after: after).ok,
        isTrue,
      );
      // Naming anyone else as owner is a change the committer cannot make.
      final wrong = s.copyWith(owner: mod, moderators: const {});
      expect(
        validateCommit(s, wrong, mod, before: members, after: after).ok,
        isFalse,
      );
    });

    test('an add with a role is checked as a grant by the committer', () {
      final s = base();
      const after = {...members, 'acct_new'};
      final asMod = bump(s, moderators: {mod, 'acct_new'});
      expect(
        validateCommit(s, asMod, admin, before: members, after: after).ok,
        isTrue,
      );
      final asAdmin = bump(s, admins: {admin: 1, 'acct_new': s.rev + 1});
      expect(
        validateCommit(s, asAdmin, mod, before: members, after: after).reject,
        GovernanceReject.hierarchy,
      );
    });

    test('prune and change in one commit', () {
      final s = base().copyWith(admins: {admin: 1, carol: 2});
      const after = {owner, admin, mod, bob};
      final pruned = s.removeAccount(carol, remaining: after);
      final change = bump(pruned, moderators: {mod, bob});
      expect(
        validateCommit(s, change, admin, before: members, after: after).ok,
        isTrue,
      );
      // A change that still names carol is refused.
      final stale = bump(s, moderators: {mod, bob});
      expect(
        validateCommit(s, stale, admin, before: members, after: after).reject,
        GovernanceReject.notMember,
      );
    });
  });
}
