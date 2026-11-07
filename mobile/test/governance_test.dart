import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';

void main() {
  const owner = 'acct_owner';
  const admin = 'acct_admin';
  const mod = 'acct_mod';
  const bob = 'acct_bob';
  const carol = 'acct_carol';
  const dave = 'acct_dave';
  const eve = 'acct_eve';
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
  }) => validateTransition(prev, next, who, members: roster);

  GovernanceState bump(
    GovernanceState s, {
    String? owner,
    Map<String, int>? admins,
    Set<String>? moderators,
    bool? adminsOnlyPosting,
    Set<String>? announcementChannels,
    Set<String>? electors,
    Election? election,
    bool clearElection = false,
    Map<String, int>? joined,
  }) => s.copyWith(
    rev: s.rev + 1,
    owner: owner,
    admins: admins,
    moderators: moderators,
    adminsOnlyPosting: adminsOnlyPosting,
    announcementChannels: announcementChannels,
    electors: electors,
    election: election,
    clearElection: clearElection,
    joined: joined,
  );

  group('roles and posting', () {
    test('genesis: the creator owns the group, nobody else has a role', () {
      final g = GovernanceState.genesis(owner);
      expect(g.rev, 0);
      expect(g.roleOf(owner), BuiltInRole.owner);
      expect(g.roleOf(bob), BuiltInRole.member);
      expect(g.isRestricted(), isFalse);
      expect(g.joined, {owner: 0});
      expect(g.election, isNull);
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
      final pruned = s.removeAccount(carol);
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

    test('the owner is never pruned and nobody inherits (D81)', () {
      final s = base().copyWith(admins: {admin: 1, carol: 2});
      const after = {admin, carol, mod, bob};
      final next = s.removeAccount(owner);
      expect(next.owner, owner);
      expect(next.admins, s.admins);
      expect(next.moderators, s.moderators);
      // The absent owner stays valid: the others carry on without it.
      expect(
        check(
          next,
          bump(next, moderators: {mod, bob}),
          admin,
          roster: after,
        ).ok,
        isTrue,
      );
    });

    test('with no admin left, the owner stays and no record can vacate it', () {
      final s = base().copyWith(admins: const {});
      final next = s.removeAccount(owner);
      const roster = {mod, bob, carol};
      expect(next.owner, owner);
      final claim = bump(next, owner: mod, moderators: const {});
      expect(
        check(next, claim, mod, roster: roster).reject,
        GovernanceReject.ownerChange,
      );
      final vacate = next.copyWith(rev: next.rev + 1, clearOwner: true);
      expect(
        check(next, vacate, mod, roster: roster).reject,
        GovernanceReject.ownerChange,
      );
    });

    test('pruning drops roles, electors, joined, votes by and for', () {
      final s = base().copyWith(
        admins: {admin: 1, carol: 2, dave: 3},
        electors: {admin, carol},
        joined: {owner: 0, admin: 1, carol: 2, dave: 3},
        election: Election(
          opened: 4,
          electorate: {admin, carol},
          votes: {admin: carol, carol: dave},
        ),
      );
      final gone = s.removeAccount(carol);
      expect(gone.admins.containsKey(carol), isFalse);
      expect(gone.electors, {admin});
      expect(gone.joined.containsKey(carol), isFalse);
      // The snapshot keeps its size; the vote by carol and for carol go.
      expect(gone.election!.electorate, {admin, carol});
      expect(gone.election!.votes, isEmpty);
      expect(gone.rev, s.rev);
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
      final pruned = s.removeAccount(mod);
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

    test('a forced removal of the owner keeps it owner; nobody inherits', () {
      final s = base();
      const after = {admin, mod, bob, carol};
      final expected = s.removeAccount(owner);
      expect(expected.owner, owner);
      expect(
        validateCommit(s, expected, mod, before: members, after: after).ok,
        isTrue,
      );
      // Handing the owner's place to anyone is a change nobody can make.
      for (final heir in [admin, mod]) {
        final wrong = expected.copyWith(
          rev: s.rev + 1,
          owner: heir,
          admins: const {},
          moderators: const {},
        );
        expect(
          validateCommit(s, wrong, mod, before: members, after: after).ok,
          isFalse,
        );
      }
    });

    test('an add with a role is checked as a grant by the committer', () {
      final s = base();
      const after = {...members, 'acct_new'};
      final stamp = {'acct_new': s.rev + 1};
      final asMod = bump(s, moderators: {mod, 'acct_new'}, joined: stamp);
      expect(
        validateCommit(s, asMod, admin, before: members, after: after).ok,
        isTrue,
      );
      final asAdmin = bump(
        s,
        admins: {admin: 1, 'acct_new': s.rev + 1},
        joined: stamp,
      );
      expect(
        validateCommit(s, asAdmin, mod, before: members, after: after).reject,
        GovernanceReject.hierarchy,
      );
      // An add that is not stamped with its rev is refused.
      final unstamped = bump(s, moderators: {mod, 'acct_new'});
      expect(
        validateCommit(
          s,
          unstamped,
          admin,
          before: members,
          after: after,
        ).reject,
        GovernanceReject.badShape,
      );
    });

    test('prune and change in one commit', () {
      final s = base().copyWith(admins: {admin: 1, carol: 2});
      const after = {owner, admin, mod, bob};
      final pruned = s.removeAccount(carol);
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

  group('owner handover (D81, D82)', () {
    const crew = {owner, admin, carol, dave, eve, mod, bob};
    const joinedAt = {
      owner: 0,
      admin: 1,
      carol: 2,
      dave: 3,
      eve: 4,
      mod: 5,
      bob: 6,
    };

    // rev 10. Admins admin, carol, dave, eve; the owner chose the first
    // three (electors). eve was made admin by another admin.
    GovernanceState council({Set<String>? electors, Election? election}) =>
        GovernanceState(
          rev: 10,
          owner: owner,
          admins: {admin: 1, carol: 2, dave: 3, eve: 4},
          moderators: {mod},
          electors: electors ?? {admin, carol, dave},
          election: election,
          joined: joinedAt,
        );

    Election poll({
      Map<String, String> votes = const {},
      Set<String> who = const {admin, carol, dave},
    }) => Election(opened: 11, electorate: who, votes: votes);

    // The council with an election open since rev 11.
    GovernanceState opened({Map<String, String> votes = const {}}) =>
        council(election: poll(votes: votes)).copyWith(rev: 11);

    // The commit that sets [heir] as owner and clears the election.
    GovernanceState won(GovernanceState s, String heir) => s.copyWith(
      rev: s.rev + 1,
      owner: heir,
      admins: {
        for (final e in s.admins.entries)
          if (e.key != heir) e.key: e.value,
        owner: s.rev + 1,
      },
      electors: s.electors.difference({heir}),
      clearElection: true,
    );

    GovernanceCheck run(
      GovernanceState s,
      GovernanceState next,
      String who, {
      Set<String> roster = crew,
    }) => validateTransition(s, next, who, members: roster);

    test('the owner cannot leave until it transfers', () {
      expect(base().mayLeave(owner), isFalse);
      expect(base().mayLeave(admin), isTrue);
      expect(base().mayLeave(bob), isTrue);
    });

    test(
      'local waits: 30 days of owner silence, then 7 days after opening',
      () {
        final now = DateTime.utc(2026, 12, 31);
        final day30 = now.subtract(const Duration(days: 30));
        final day29 = now.subtract(const Duration(days: 29));
        expect(mayOpenElectionNow(now: now, lastOwnerActivity: day30), isTrue);
        expect(mayOpenElectionNow(now: now, lastOwnerActivity: day29), isFalse);
        final day7 = now.subtract(const Duration(days: 7));
        final day6 = now.subtract(const Duration(days: 6));
        expect(
          mayVoteNow(now: now, openedSeen: day7, lastOwnerActivity: day30),
          isTrue,
        );
        expect(
          mayVoteNow(now: now, openedSeen: day6, lastOwnerActivity: day30),
          isFalse,
        );
        // The owner spoke after the opening: no vote.
        expect(
          mayVoteNow(now: now, openedSeen: day7, lastOwnerActivity: day29),
          isFalse,
        );
      },
    );

    test(
      'open: an elector only; the snapshot is the electors in the roster',
      () {
        final s = council();
        final next = bump(s, election: poll());
        expect(run(s, next, admin).ok, isTrue);
        expect(run(s, next, carol).ok, isTrue);
        // An admin the owner did not choose, a moderator, a member.
        expect(run(s, next, eve).reject, GovernanceReject.election);
        expect(run(s, next, mod).reject, GovernanceReject.election);
        expect(run(s, next, bob).reject, GovernanceReject.election);
        // The owner never opens one against itself.
        expect(run(s, next, owner).reject, GovernanceReject.election);
        // The snapshot cannot be widened, narrowed or opened at another rev.
        final wide = bump(s, election: poll(who: {admin, carol, dave, eve}));
        expect(run(s, wide, admin).reject, GovernanceReject.election);
        final narrow = bump(s, election: poll(who: {admin}));
        expect(run(s, narrow, admin).reject, GovernanceReject.election);
        final stale = bump(
          s,
          election: Election(opened: 10, electorate: {admin}),
        );
        expect(run(s, stale, admin).reject, GovernanceReject.election);
        // An elector who has left the roster is not in the snapshot.
        final gone = council().removeAccount(dave);
        final fewer = bump(gone, election: poll(who: {admin, carol}));
        const roster = {owner, admin, carol, eve, mod, bob};
        expect(run(gone, fewer, admin, roster: roster).ok, isTrue);
      },
    );

    test('open only when no election is open', () {
      final o = opened();
      final again = bump(
        o,
        election: Election(opened: 12, electorate: {admin}),
      );
      expect(run(o, again, carol).reject, GovernanceReject.election);
    });

    test('D82: with no elector in the roster every admin is the snapshot', () {
      final s = council(electors: const {});
      final all = {admin, carol, dave, eve};
      final next = bump(s, election: poll(who: all));
      expect(run(s, next, eve).ok, isTrue);
      expect(run(s, next, admin).ok, isTrue);
      expect(run(s, next, bob).reject, GovernanceReject.election);
      expect(run(s, next, mod).reject, GovernanceReject.election);
      final narrow = bump(s, election: poll(who: {admin, carol}));
      expect(run(s, narrow, admin).reject, GovernanceReject.election);
      // Electors who have all left count as none.
      final gone = council(electors: {dave}).removeAccount(dave);
      const roster = {owner, admin, carol, eve, mod, bob};
      final open = bump(gone, election: poll(who: {admin, carol, eve}));
      expect(run(gone, open, eve, roster: roster).ok, isTrue);
    });

    test('opening changes no admin and no elector', () {
      final s = council();
      final sneaky = bump(
        s,
        election: poll(),
        admins: {...s.admins, bob: s.rev + 1},
      );
      expect(run(s, sneaky, admin).reject, GovernanceReject.election);
    });

    test('an owner commit must clear the election', () {
      final o = opened();
      final keep = bump(o, moderators: {mod, bob});
      expect(run(o, keep, owner).reject, GovernanceReject.election);
      final clear = bump(o, moderators: {mod, bob}, clearElection: true);
      expect(run(o, clear, owner).ok, isTrue);
      // An owner commit that leaves the record as it is cannot pass either.
      expect(
        validateCommit(o, o, owner, before: crew, after: crew).reject,
        GovernanceReject.election,
      );
      // An owner's add must carry the cancel and the stamp.
      const after = {...crew, 'acct_new'};
      final stamp = {...joinedAt, 'acct_new': o.rev + 1};
      final cancel = bump(o, clearElection: true, joined: stamp);
      expect(
        validateCommit(o, cancel, owner, before: crew, after: after).ok,
        isTrue,
      );
      // Anyone else's add leaves the election alone.
      final others = bump(o, joined: stamp);
      expect(
        validateCommit(o, others, admin, before: crew, after: after).ok,
        isTrue,
      );
      expect(
        validateCommit(o, cancel, admin, before: crew, after: after).ok,
        isTrue,
      );
    });

    test('close: any account in the snapshot, nobody else', () {
      final o = opened();
      final close = bump(o, clearElection: true);
      expect(run(o, close, carol).ok, isTrue);
      expect(run(o, close, eve).reject, GovernanceReject.election);
      expect(run(o, close, bob).reject, GovernanceReject.election);
    });

    test('vote: once, for an admin in the roster, from the snapshot', () {
      final o = opened();
      final one = bump(o, election: poll(votes: {admin: carol}));
      expect(run(o, one, admin).ok, isTrue);
      // Not for a member who is no admin.
      final toBob = bump(o, election: poll(votes: {admin: bob}));
      expect(run(o, toBob, admin).reject, GovernanceReject.election);
      // Not by an account outside the snapshot.
      final byEve = bump(o, election: poll(votes: {eve: carol}));
      expect(run(o, byEve, eve).reject, GovernanceReject.badShape);
      // Not in someone else's name, nor two at once.
      final forCarol = bump(o, election: poll(votes: {carol: dave}));
      expect(run(o, forCarol, admin).reject, GovernanceReject.election);
      final two = bump(o, election: poll(votes: {admin: carol, carol: dave}));
      expect(run(o, two, admin).reject, GovernanceReject.election);
      // A vote cannot be changed or repeated.
      final voted = opened(votes: {admin: carol});
      final change = bump(voted, election: poll(votes: {admin: dave}));
      expect(run(voted, change, admin).reject, GovernanceReject.election);
      // Another account votes on top of it.
      final second = bump(
        voted,
        election: poll(votes: {admin: carol, dave: dave}),
      );
      expect(run(voted, second, dave).ok, isTrue);
    });

    test('a vote that makes a majority must set the owner in that commit', () {
      final voted = opened(votes: {admin: carol});
      final stays = bump(
        voted,
        election: poll(votes: {admin: carol, carol: carol}),
      );
      expect(run(voted, stays, carol).reject, GovernanceReject.election);
    });

    test(
      'win: the deciding vote sets the owner; the old owner becomes admin',
      () {
        final voted = opened(votes: {admin: carol});
        final next = won(voted, carol);
        expect(run(voted, next, carol).ok, isTrue);
        expect(run(voted, next, dave).ok, isTrue);
        expect(next.roleOf(carol), BuiltInRole.owner);
        expect(next.roleOf(owner), BuiltInRole.admin);
        expect(next.admins[owner], next.rev);
        expect(next.election, isNull);
        expect(next.electors, {admin, dave});
        // Not by an account outside the snapshot, nor by one that voted.
        expect(run(voted, next, eve).reject, GovernanceReject.ownerChange);
        expect(run(voted, next, admin).reject, GovernanceReject.election);
        // Not for a member who is no admin.
        final toBob = won(voted, bob);
        expect(run(voted, toBob, dave).reject, GovernanceReject.ownerChange);
        // Nothing else may ride along.
        final extra = next.copyWith(moderators: {mod, bob});
        expect(run(voted, extra, dave).reject, GovernanceReject.badShape);
        final posting = next.copyWith(adminsOnlyPosting: true);
        expect(run(voted, posting, dave).reject, GovernanceReject.badShape);
        // The old owner's seniority starts at this rev.
        final keeps = next.copyWith(admins: {...next.admins, owner: 0});
        expect(run(voted, keeps, dave).reject, GovernanceReject.badShape);
      },
    );

    test(
      'win: below a majority, or with no election, ownership cannot move',
      () {
        final o = opened();
        final early = won(o, carol);
        expect(run(o, early, carol).reject, GovernanceReject.ownerChange);
        final s = council();
        final none = won(s, carol).copyWith(election: poll());
        expect(run(s, none, carol).reject, GovernanceReject.ownerChange);
        final bare = won(s, carol);
        expect(run(s, bare, carol).reject, GovernanceReject.ownerChange);
      },
    );

    test('win: an old owner out of the roster is not named', () {
      final voted = opened(votes: {admin: carol});
      const roster = {admin, carol, dave, eve, mod, bob};
      final out = voted.removeAccount(owner);
      final next = won(
        out,
        carol,
      ).copyWith(admins: {admin: 1, dave: 3, eve: 4});
      expect(run(out, next, carol, roster: roster).ok, isTrue);
      // Naming it as an admin while it is out of the roster is refused.
      final named = won(out, carol);
      expect(
        run(out, named, carol, roster: roster).reject,
        GovernanceReject.notMember,
      );
      // The owner is still the owner while it is out.
      expect(out.owner, owner);
    });

    test('removals never lower the threshold', () {
      // The snapshot is three. Dave and carol leave; admin alone is not a
      // majority of three.
      final o = opened();
      const roster = {owner, admin, eve, mod, bob};
      final pruned = o.removeAccount(dave).removeAccount(carol);
      final alone = won(pruned, admin);
      expect(
        run(pruned, alone, admin, roster: roster).reject,
        GovernanceReject.ownerChange,
      );
      // With one earlier vote, two of three still decide after dave leaves.
      final voted = opened(votes: {admin: carol}).removeAccount(dave);
      const rest = {owner, admin, carol, eve, mod, bob};
      expect(run(voted, won(voted, carol), carol, roster: rest).ok, isTrue);
    });

    test('electors: only the owner sets or clears the flag', () {
      final s = council();
      final withBob = {...s.admins, bob: s.rev + 1};
      // An admin promotes: bob is an admin, not an elector.
      final plain = bump(s, admins: withBob);
      expect(run(s, plain, carol).ok, isTrue);
      expect(plain.electors, s.electors);
      final flagged = bump(s, admins: withBob, electors: {...s.electors, bob});
      expect(run(s, flagged, carol).reject, GovernanceReject.notAllowed);
      // The owner promotes with the flag, or confirms an admin later.
      expect(run(s, flagged, owner).ok, isTrue);
      final confirm = bump(s, electors: {...s.electors, eve});
      expect(run(s, confirm, owner).ok, isTrue);
      expect(run(s, confirm, carol).reject, GovernanceReject.notAllowed);
      // The owner may withdraw it; nobody else.
      final withdraw = bump(s, electors: {admin, carol});
      expect(run(s, withdraw, owner).ok, isTrue);
      expect(run(s, withdraw, dave).reject, GovernanceReject.notAllowed);
      // It goes with the admin role, and only an admin can hold it.
      final demoted = bump(
        s,
        admins: {admin: 1, dave: 3, eve: 4},
        electors: {admin, dave},
      );
      expect(run(s, demoted, owner).ok, isTrue);
      final stale = bump(s, admins: {admin: 1, dave: 3, eve: 4});
      expect(run(s, stale, owner).reject, GovernanceReject.badShape);
      // A transfer never makes the old owner an elector.
      final handed = bump(
        s,
        owner: carol,
        admins: {admin: 1, dave: 3, eve: 4, owner: s.rev + 1},
        electors: {admin, dave, owner},
      );
      expect(run(s, handed, owner).reject, GovernanceReject.notAllowed);
      final fine = bump(
        s,
        owner: carol,
        admins: {admin: 1, dave: 3, eve: 4, owner: s.rev + 1},
        electors: {admin, dave},
      );
      expect(run(s, fine, owner).ok, isTrue);
    });

    group('no admin left: the longest-serving member claims', () {
      const four = {owner, bob, carol, mod};
      // bob joined first after the owner.
      GovernanceState solo({Map<String, int>? joined}) => GovernanceState(
        rev: 10,
        owner: owner,
        moderators: {mod},
        joined: joined ?? {owner: 0, bob: 1, carol: 2, mod: 3},
      );
      Election alone(String who) => Election(opened: 11, electorate: {who});

      test('only that member opens, with a snapshot of itself', () {
        final s = solo();
        final claim = bump(s, election: alone(bob));
        expect(run(s, claim, bob, roster: four).ok, isTrue);
        final byCarol = run(s, claim, carol, roster: four);
        expect(byCarol.reject, GovernanceReject.election);
        final byMod = run(s, claim, mod, roster: four);
        expect(byMod.reject, GovernanceReject.election);
        final other = bump(s, election: alone(carol));
        final asCarol = run(s, other, carol, roster: four);
        expect(asCarol.reject, GovernanceReject.election);
      });

      test('a tie goes to the smaller account id; the owner never claims', () {
        final s = solo(joined: {owner: 0, bob: 1, carol: 1, mod: 3});
        final claim = bump(s, election: alone(bob));
        expect(run(s, claim, bob, roster: four).ok, isTrue);
        final c = bump(s, election: alone(carol));
        expect(
          run(s, c, carol, roster: four).reject,
          GovernanceReject.election,
        );
      });

      test('a member with no joined entry blocks the claim', () {
        final s = solo();
        const roster = {...four, eve};
        final claim = bump(s, election: alone(bob));
        expect(
          run(s, claim, bob, roster: roster).reject,
          GovernanceReject.election,
        );
      });

      test('with an admin in the roster there is no claim', () {
        final s = solo().copyWith(admins: {carol: 2});
        final claim = bump(s, election: alone(bob));
        expect(
          run(s, claim, bob, roster: four).reject,
          GovernanceReject.election,
        );
      });

      test('the claimant takes ownership; the old owner becomes admin', () {
        final c = solo().copyWith(rev: 11, election: alone(bob));
        final next = c.copyWith(
          rev: 12,
          owner: bob,
          admins: {owner: 12},
          clearElection: true,
        );
        expect(run(c, next, bob, roster: four).ok, isTrue);
        expect(
          run(c, next, carol, roster: four).reject,
          GovernanceReject.ownerChange,
        );
        // An away owner is not named.
        const away = {bob, carol, mod};
        final gone = c.removeAccount(owner);
        final noOwner = gone.copyWith(
          rev: 12,
          owner: bob,
          admins: const {},
          clearElection: true,
        );
        expect(run(gone, noOwner, bob, roster: away).ok, isTrue);
      });

      test('a moderator claimant leaves the moderator list', () {
        final s = solo(joined: {owner: 0, mod: 1, bob: 2, carol: 3});
        final c = s.copyWith(rev: 11, election: alone(mod));
        final stays = c.copyWith(
          rev: 12,
          owner: mod,
          admins: {owner: 12},
          clearElection: true,
        );
        expect(
          run(c, stays, mod, roster: four).reject,
          GovernanceReject.badShape,
        );
        final next = stays.copyWith(moderators: const {});
        expect(run(c, next, mod, roster: four).ok, isTrue);
      });
    });

    test('adding an account stamps its joined rev', () {
      final s = council();
      const after = {...crew, 'acct_new'};
      final stamped = bump(s, joined: {...joinedAt, 'acct_new': s.rev + 1});
      expect(
        validateCommit(s, stamped, bob, before: crew, after: after).ok,
        isTrue,
      );
      final wrong = bump(s, joined: {...joinedAt, 'acct_new': 3});
      expect(
        validateCommit(s, wrong, bob, before: crew, after: after).reject,
        GovernanceReject.badShape,
      );
      // An existing entry cannot be rewritten.
      final rewrite = bump(s, joined: {...joinedAt, bob: 1});
      expect(run(s, rewrite, admin).reject, GovernanceReject.badShape);
      // A removal drops it, so a re-added member starts again.
      final back = s.removeAccount(bob);
      expect(back.joined.containsKey(bob), isFalse);
    });

    test('a forced removal of the owner leaves the election to the others', () {
      final voted = opened(votes: {admin: carol});
      const after = {admin, carol, dave, eve, mod, bob};
      final pruned = voted.removeAccount(owner);
      expect(
        validateCommit(voted, pruned, bob, before: crew, after: after).ok,
        isTrue,
      );
    });

    test('no commit drops another member\'s joined entry', () {
      final s = council();
      final dropped = bump(s, joined: {...joinedAt}..remove(carol));
      expect(
        validateCommit(s, dropped, bob, before: crew, after: crew).reject,
        GovernanceReject.badShape,
      );
      expect(run(s, dropped, owner).reject, GovernanceReject.badShape);
    });

    test('an election with nobody of its snapshot left is cleared', () {
      final s = opened(votes: {admin: carol});
      const after = {owner, eve, mod, bob};
      final need = requiredRecord(s, bob, before: crew, after: after);
      expect(need.election, isNull);
      expect(need.rev, s.rev);
      expect(need.admins, {eve: 4});
      expect(
        validateCommit(s, need, bob, before: crew, after: after).ok,
        isTrue,
      );
      // Keeping the dead election is refused.
      final kept = s
          .removeAccount(admin)
          .removeAccount(carol)
          .removeAccount(dave);
      expect(kept.election, isNotNull);
      expect(
        validateCommit(s, kept, bob, before: crew, after: after).ok,
        isFalse,
      );
      expect(
        validateCommit(s, s, bob, before: crew, after: after).reject,
        GovernanceReject.notPruned,
      );
      // A fresh election can open: eve is the only admin left (D82).
      final reopen = bump(
        need,
        election: Election(opened: 12, electorate: {eve}),
      );
      expect(
        validateCommit(need, reopen, eve, before: after, after: after).ok,
        isTrue,
      );
    });

    test('a claim whose claimant left is cleared; the next member claims', () {
      final c = GovernanceState(
        rev: 11,
        owner: owner,
        joined: {owner: 0, bob: 1, carol: 2},
        election: Election(opened: 11, electorate: {bob}),
      );
      const before = {owner, bob, carol};
      const after = {owner, carol};
      final need = requiredRecord(c, carol, before: before, after: after);
      expect(need.election, isNull);
      final claim = bump(
        need,
        election: Election(opened: 12, electorate: {carol}),
      );
      expect(
        validateCommit(need, claim, carol, before: after, after: after).ok,
        isTrue,
      );
    });

    // Residuals, pinned so a change to them is deliberate. Receivers cannot
    // check time, so the 30- and 7-day waits bind honest committers only.
    test('residual: with no elector, an admin\'s stand-ins win at once', () {
      const roster = {owner, admin, carol, bob, mod};
      var s = GovernanceState(
        rev: 10,
        owner: owner,
        admins: {admin: 1, carol: 2},
        joined: {owner: 0, admin: 1, carol: 2, bob: 3, mod: 4},
      );
      GovernanceState step(GovernanceState next, String who) {
        final r = validateCommit(s, next, who, before: roster, after: roster);
        expect(r.ok, isTrue, reason: '${r.reject}');
        return s = next;
      }

      const all = {admin, carol, bob, mod};
      step(bump(s, admins: {...s.admins, bob: 11, mod: 11}), admin);
      step(bump(s, election: Election(opened: 12, electorate: all)), admin);
      Election votes(Map<String, String> v) =>
          Election(opened: 12, electorate: all, votes: v);
      step(bump(s, election: votes({admin: admin})), admin);
      step(bump(s, election: votes({admin: admin, bob: admin})), bob);
      step(won(s, admin), mod);
      expect(s.owner, admin);
    });

    test('residual: a forced removal of every elector hands D82 the vote', () {
      final s = council();
      const after = {owner, eve, mod, bob};
      final open = s
          .removeAccount(admin)
          .removeAccount(carol)
          .removeAccount(dave)
          .copyWith(rev: 11, election: Election(opened: 11, electorate: {eve}));
      expect(
        validateCommit(s, open, eve, before: crew, after: after).ok,
        isTrue,
      );
    });
  });
}
