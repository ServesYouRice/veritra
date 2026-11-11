import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/governance_codec.dart';
import 'package:private_messenger/core/roles/governance_commands.dart';

void main() {
  final now = DateTime.utc(2026, 11, 11);
  final members = {'owner', 'alice', 'bob', 'carol', 'dave'};
  final initial = requiredRecord(
    GovernanceState.genesis('owner'),
    'owner',
    before: {'owner'},
    after: members,
  );

  GovernanceCommands commands(
    GovernanceState state,
    String actor, {
    Set<String>? roster,
  }) =>
      GovernanceCommands(
        state: state,
        actor: actor,
        members: roster ?? members,
      );

  GovernanceObservations observed(
    GovernanceState state, {
    DateTime? activity,
    DateTime? opened,
  }) =>
      GovernanceObservations(
        owner: state.owner,
        ownerRev: state.ownerRev,
        lastOwnerActivity: activity ?? now.subtract(ownerInactivityWait),
        electionOpened: state.election?.opened,
        electionSeen: opened ?? now.subtract(electionWait),
      );

  final refused = throwsA(isA<GovernanceCommandException>());

  GovernanceState admins() {
    var state = commands(initial, 'owner').setRole('alice', BuiltInRole.admin);
    state = commands(state, 'owner').setRole('bob', BuiltInRole.admin);
    return commands(state, 'owner').setRole('carol', BuiltInRole.admin);
  }

  void valid(GovernanceState before, GovernanceState after, String actor) {
    expect(
      validateCommit(before, after, actor, before: members, after: members).ok,
      isTrue,
    );
    expect(decodeGovernance(encodeGovernance(after)), after);
  }

  test(
    'owner promotion chooses elector, seniority survives other decisions',
    () {
      final first = commands(
        initial,
        'owner',
      ).setRole('alice', BuiltInRole.admin);
      valid(initial, first, 'owner');
      expect(first.admins['alice'], first.rev);
      expect(first.electors, {'alice'});
      final second = commands(
        first,
        'owner',
      ).setRole('bob', BuiltInRole.moderator);
      valid(first, second, 'owner');
      expect(second.admins['alice'], first.rev);
      expect(second.ownerRev, second.rev);
      final posting = commands(
        second,
        'alice',
      ).setPosting(adminsOnly: true, announcementChannels: {'channel'});
      valid(second, posting, 'alice');
      expect(posting.ownerRev, second.ownerRev);
      expect(posting.mayPost('bob'), isFalse);
      expect(posting.mayPost('alice'), isTrue);
    },
  );

  test(
    'hierarchy, self promotion, owner departure and no-op commands refuse',
    () {
      final state = admins();
      expect(
        () => commands(state, 'dave').setRole('dave', BuiltInRole.admin),
        refused,
      );
      expect(
        () => commands(state, 'alice').setRole('bob', BuiltInRole.member),
        refused,
      );
      expect(
        () => commands(state, 'owner').setRole('owner', BuiltInRole.member),
        refused,
      );
      expect(
        () => commands(state, 'owner').setRole('alice', BuiltInRole.owner),
        refused,
      );
      expect(
        () => commands(state, 'owner').setRole('alice', BuiltInRole.admin),
        refused,
      );
      expect(
        () => commands(state, 'owner').setRole('outsider', BuiltInRole.admin),
        refused,
      );
      expect(
        () => commands(state, 'outsider').setRole('dave', BuiltInRole.admin),
        refused,
      );
      expect(
        () => commands(
          state,
          'dave',
        ).setPosting(adminsOnly: true, announcementChannels: {}),
        refused,
      );
      expect(
        () => commands(
          state,
          'owner',
        ).setPosting(adminsOnly: false, announcementChannels: {}),
        refused,
      );
      expect(() => commands(state, 'alice').transfer('bob'), refused);
      expect(() => commands(state, 'owner').transfer('dave'), refused);
      expect(() => commands(state, 'alice').setElector('bob', false), refused);
    },
  );

  test('step-down clears elector and promotion restarts seniority', () {
    final state = admins();
    final down = commands(
      state,
      'alice',
    ).setRole('alice', BuiltInRole.moderator);
    valid(state, down, 'alice');
    expect(down.electors, isNot(contains('alice')));
    final up = commands(down, 'bob').setRole('alice', BuiltInRole.admin);
    valid(down, up, 'bob');
    expect(up.admins['alice'], up.rev);
    expect(up.electors, isNot(contains('alice')));
    final confirmed = commands(up, 'owner').setElector('alice', true);
    valid(up, confirmed, 'owner');
    expect(confirmed.admins['alice'], up.rev);
    expect(confirmed.electors, contains('alice'));
  });

  test('transfer clears election and makes old owner a fresh admin', () {
    final state = admins();
    final open = commands(state, 'alice').openElection(observed(state), now);
    final next = commands(open, 'owner').transfer('bob');
    valid(open, next, 'owner');
    expect(next.owner, 'bob');
    expect(next.admins['owner'], next.rev);
    expect(next.admins, isNot(contains('bob')));
    expect(next.electors, isNot(contains('bob')));
    expect(next.election, isNull);
  });

  test('majority is strict and deciding vote transfers in the same record', () {
    final state = admins();
    final open = commands(state, 'alice').openElection(observed(state), now);
    valid(state, open, 'alice');
    final first = commands(open, 'alice').vote('bob', observed(open), now);
    valid(open, first, 'alice');
    expect(first.owner, 'owner');
    expect(first.election!.votes, {'alice': 'bob'});
    expect(
      () => commands(first, 'alice').vote('carol', observed(first), now),
      refused,
    );
    final win = commands(first, 'carol').vote('bob', observed(first), now);
    valid(first, win, 'carol');
    expect(win.owner, 'bob');
    expect(win.election, isNull);
    expect(win.ownerRev, win.rev);
    expect(win.admins['owner'], win.rev);
  });

  test(
    'owner cancellation preserves ownerRev; any snapshot member can close',
    () {
      final state = admins();
      final open = commands(state, 'alice').openElection(observed(state), now);
      final cancel = commands(open, 'owner').closeElection();
      valid(open, cancel, 'owner');
      expect(cancel.ownerRev, state.ownerRev);
      final closed = commands(open, 'bob').closeElection();
      valid(open, closed, 'bob');
      expect(closed.owner, state.owner);
      expect(() => commands(open, 'dave').closeElection(), refused);
      expect(() => commands(state, 'owner').closeElection(), refused);
      expect(
        () => commands(open, 'bob').openElection(observed(open), now),
        refused,
      );
    },
  );

  test(
    'waits require current local observations and reject future timestamps',
    () {
      final state = admins();
      expect(
        () => commands(state, 'alice').openElection(
          observed(state, activity: now.subtract(const Duration(days: 29))),
          now,
        ),
        refused,
      );
      expect(
        () => commands(state, 'alice').openElection(
          observed(state, activity: now.add(const Duration(days: 1))),
          now,
        ),
        refused,
      );
      expect(
        () => commands(state, 'alice').openElection(observed(initial), now),
        refused,
      );
      final open = commands(state, 'alice').openElection(observed(state), now);
      expect(
        () => commands(open, 'alice').vote(
          'bob',
          observed(open, opened: now.subtract(const Duration(days: 6))),
          now,
        ),
        refused,
      );
      expect(
        () => commands(
          open,
          'alice',
        ).vote('bob', observed(open, activity: now), now),
        refused,
      );
      expect(
        () => commands(open, 'alice').vote('bob', observed(state), now),
        refused,
      );
      expect(
        () => commands(open, 'dave').vote('bob', observed(open), now),
        refused,
      );
      expect(
        () => commands(open, 'alice').vote('dave', observed(open), now),
        refused,
      );
    },
  );

  test('D82 excludes stand-ins until owner explicitly confirms', () {
    var state = admins();
    for (final admin in ['alice', 'bob', 'carol']) {
      state = commands(state, 'owner').setElector(admin, false);
    }
    state = commands(state, 'alice').setRole('dave', BuiltInRole.admin);
    expect(
      () => commands(state, 'dave').openElection(observed(state), now),
      refused,
    );
    final open = commands(state, 'alice').openElection(observed(state), now);
    expect(open.election!.electorate, {'alice', 'bob', 'carol'});
    final cancel = commands(open, 'owner').closeElection();
    expect(cancel.ownerRev, state.ownerRev);
    expect(
      () => commands(cancel, 'dave').openElection(observed(cancel), now),
      refused,
    );
  });

  test('records must fit the canonical codec before staging', () {
    expect(
        () => commands(initial, 'owner')
            .setPosting(adminsOnly: false, announcementChannels: {'x' * 256}),
        refused);
    expect(
        () => commands(initial, 'owner').setPosting(
            adminsOnly: false,
            announcementChannels: {String.fromCharCode(0xd800)}),
        refused);
    final exhausted = initial.copyWith(rev: 0x7fffffffffffffff);
    expect(
        () => commands(exhausted, 'owner').setRole('alice', BuiltInRole.admin),
        refused);
  });

  test(
      'local observations start conservatively and track authenticated activity',
      () {
    final state = admins();
    final first = GovernanceObservations.firstSeen(state, now);
    expect(() => commands(state, 'alice').openElection(first, now), refused);
    final later = now.add(ownerInactivityWait);
    final idle = first.accepted(state, later, ownerActive: false);
    expect(idle.lastOwnerActivity, now);
    final open = commands(state, 'alice').openElection(idle, later);
    final seen = idle.accepted(open, later, ownerActive: false);
    expect(seen.electionOpened, open.election!.opened);
    expect(seen.electionSeen, later);
    expect(() => commands(open, 'alice').vote('bob', seen, later), refused);
    final activity =
        seen.accepted(open, later.add(electionWait), ownerActive: true);
    expect(activity.lastOwnerActivity, later.add(electionWait));
    expect(activity.electionSeen, later);
    expect(
        () => commands(open, 'alice')
            .vote('bob', activity, later.add(electionWait)),
        refused);
    final backward = activity.accepted(open, now, ownerActive: true);
    expect(backward.lastOwnerActivity, activity.lastOwnerActivity);
    final restore = GovernanceObservations.firstSeen(open, later);
    expect(restore.lastOwnerActivity, later);
    expect(restore.electionSeen, later);
  });

  test('cancellation clears opening observation; transfer restarts owner clock',
      () {
    final state = admins();
    final open = commands(state, 'alice').openElection(observed(state), now);
    final seen = observed(state).accepted(open, now, ownerActive: false);
    final closed = commands(open, 'owner').closeElection();
    final cancel = seen.accepted(closed, now, ownerActive: true);
    expect(cancel.electionSeen, isNull);
    expect(cancel.electionOpened, isNull);
    final transfer = commands(open, 'owner').transfer('bob');
    final changed = seen.accepted(transfer, now, ownerActive: false);
    expect(changed.owner, 'bob');
    expect(changed.ownerRev, transfer.rev);
    expect(changed.lastOwnerActivity, now);
    expect(
        () => commands(transfer, 'alice').openElection(changed, now), refused);
  });

  test('no-admin claim uses joined order then id, including absent owner', () {
    final roster = {...members}..remove('owner');
    final state = initial.removeAccount('owner');
    expect(
      () => commands(
        state,
        'bob',
        roster: roster,
      ).openElection(observed(state), now),
      refused,
    );
    final open = commands(
      state,
      'alice',
      roster: roster,
    ).openElection(observed(state), now);
    expect(open.election!.electorate, {'alice'});
    expect(
      () => commands(
        open,
        'alice',
        roster: roster,
      ).vote('bob', observed(open), now),
      refused,
    );
    final win = commands(
      open,
      'alice',
      roster: roster,
    ).vote('alice', observed(open), now);
    expect(win.owner, 'alice');
    expect(win.admins, isEmpty);
    expect(win.election, isNull);
    expect(
      validateCommit(open, win, 'alice', before: roster, after: roster).ok,
      isTrue,
    );
  });

  test('no-admin claim with present inactive owner makes old owner an admin',
      () {
    // Initial has no admins and owner is in the roster.
    final open =
        commands(initial, 'alice').openElection(observed(initial), now);
    expect(open.election!.electorate, {'alice'});
    final win = commands(open, 'alice').vote('alice', observed(open), now);
    expect(win.owner, 'alice');
    expect(win.admins, {'owner': win.rev});
    expect(win.election, isNull);
    valid(open, win, 'alice');
  });

  test(
      'owner role and posting changes clear an open election and advance ownerRev',
      () {
    final state = admins();
    final open = commands(state, 'alice').openElection(observed(state), now);
    expect(open.election, isNotNull);

    final withNewRole =
        commands(open, 'owner').setRole('dave', BuiltInRole.moderator);
    valid(open, withNewRole, 'owner');
    expect(withNewRole.election, isNull);
    expect(withNewRole.ownerRev, withNewRole.rev);
    expect(withNewRole.moderators, contains('dave'));

    final openAgain =
        commands(withNewRole, 'alice').openElection(observed(withNewRole), now);
    final withPosting = commands(openAgain, 'owner').setPosting(
      adminsOnly: true,
      announcementChannels: {'announcements'},
    );
    valid(openAgain, withPosting, 'owner');
    expect(withPosting.election, isNull);
    expect(withPosting.ownerRev, withPosting.rev);
    expect(withPosting.adminsOnlyPosting, isTrue);
  });

  test('admin demotion by owner and stepping down to member work as expected',
      () {
    final state = admins();
    final demoted =
        commands(state, 'owner').setRole('alice', BuiltInRole.moderator);
    valid(state, demoted, 'owner');
    expect(demoted.admins.containsKey('alice'), isFalse);
    expect(demoted.electors.contains('alice'), isFalse);
    expect(demoted.moderators.contains('alice'), isTrue);

    final member =
        commands(demoted, 'alice').setRole('alice', BuiltInRole.member);
    valid(demoted, member, 'alice');
    expect(member.roleOf('alice'), BuiltInRole.member);
  });

  test('GovernanceObservations equality, hashCode and toString', () {
    final obs1 = observed(initial);
    final obs2 = observed(initial);
    expect(obs1, equals(obs2));
    expect(obs1.hashCode, equals(obs2.hashCode));
    expect(obs1.toString(), contains('GovernanceObservations('));

    final different = obs1.accepted(initial, now.add(const Duration(hours: 1)),
        ownerActive: true);
    expect(obs1, isNot(equals(different)));
  });
}
