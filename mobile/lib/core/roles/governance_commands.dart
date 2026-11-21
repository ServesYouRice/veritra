import 'governance.dart';
import 'governance_codec.dart';

/// Local observations, never server timestamps. The caller must persist these
/// with the accepted MLS transition before enabling election commands in UI.
class GovernanceObservations {
  const GovernanceObservations({
    required this.owner,
    required this.ownerRev,
    required this.lastOwnerActivity,
    this.electionOpened,
    this.electionSeen,
  });

  final String? owner;
  final int ownerRev;
  final DateTime lastOwnerActivity;
  final int? electionOpened;
  final DateTime? electionSeen;

  /// A join/restore without saved observations starts both waits now.
  factory GovernanceObservations.firstSeen(
    GovernanceState state,
    DateTime now,
  ) =>
      GovernanceObservations(
        owner: state.owner,
        ownerRev: state.ownerRev,
        lastOwnerActivity: now,
        electionOpened: state.election?.opened,
        electionSeen: state.election == null ? null : now,
      );

  /// Call only after authenticating and accepting the commit or application
  /// message. [ownerActive] means its authenticated sender is the current
  /// owner. Activity and election clocks never use envelope timestamps.
  GovernanceObservations accepted(
    GovernanceState state,
    DateTime now, {
    required bool ownerActive,
  }) {
    // Moving a wall clock backwards must not shorten an already observed wait.
    final receipt = now.isBefore(lastOwnerActivity) ? lastOwnerActivity : now;
    final ownerChanged = state.owner != owner;
    final opened = state.election?.opened;
    final sameElection = !ownerChanged && opened == electionOpened;
    final seen = opened == null
        ? null
        : sameElection && electionSeen != null
            ? electionSeen!
            : receipt;
    return GovernanceObservations(
      owner: state.owner,
      ownerRev: state.ownerRev,
      lastOwnerActivity:
          ownerActive || ownerChanged ? receipt : lastOwnerActivity,
      electionOpened: opened,
      electionSeen: seen,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GovernanceObservations &&
          runtimeType == other.runtimeType &&
          owner == other.owner &&
          ownerRev == other.ownerRev &&
          lastOwnerActivity == other.lastOwnerActivity &&
          electionOpened == other.electionOpened &&
          electionSeen == other.electionSeen;

  @override
  int get hashCode => Object.hash(
        owner,
        ownerRev,
        lastOwnerActivity,
        electionOpened,
        electionSeen,
      );

  @override
  String toString() =>
      'GovernanceObservations(owner: $owner, ownerRev: $ownerRev, lastOwnerActivity: $lastOwnerActivity, electionOpened: $electionOpened, electionSeen: $electionSeen)';
}

/// A refused local command. No record should be staged after this exception.
class GovernanceCommandException implements Exception {
  const GovernanceCommandException(this.reason);
  final String reason;

  @override
  String toString() => 'GovernanceCommandException($reason)';
}

/// Builds role-only commits from the current authenticated MLS state.
///
/// Each result passes the receiver's deterministic rules. Election commands
/// additionally enforce the honest sender's local waits. This does not stage
/// or persist anything, authorize membership changes, or trust server roles.
/// Recreate it after every epoch change; never queue a record across epochs.
class GovernanceCommands {
  GovernanceCommands({
    required this.state,
    required this.actor,
    required Set<String> members,
    this.epoch,
  }) : members = Set.unmodifiable(members);

  final GovernanceState state;
  final String actor;
  final Set<String> members;

  /// The epoch the staged commit will produce (the group's epoch + 1, from
  /// MLS). Needed only by [setTimeout].
  final int? epoch;

  Never _refuse(String reason) => throw GovernanceCommandException(reason);

  GovernanceState _finish(GovernanceState next) {
    if (!members.contains(actor)) _refuse('not_member');
    final check = validateCommit(
      state,
      next,
      actor,
      before: members,
      after: members,
      epoch: epoch,
    );
    if (!check.ok) _refuse(check.reject!.name);
    // The deterministic rules judge authority; the codec also bounds ids,
    // counters and total bytes. Never hand the staging caller an unwritable
    // record (for example a channel id containing a lone surrogate).
    try {
      encodeGovernance(next);
    } on GovernanceCodecException {
      _refuse('bad_record');
    }
    return next;
  }

  GovernanceState _base() =>
      state.copyWith(rev: state.rev + 1, clearElection: actor == state.owner);

  GovernanceState _decision(GovernanceState next) =>
      _finish(actor == state.owner ? next.copyWith(ownerRev: next.rev) : next);

  GovernanceState setRole(String account, BuiltInRole role) {
    if (!members.contains(account)) _refuse('not_member');
    if (role == BuiltInRole.owner) _refuse('use_transfer');
    if (account == state.owner) _refuse('transfer_first');
    if (state.roleOf(account) == role) _refuse('no_change');
    final next = _base();
    final admins = {...next.admins}..remove(account);
    final moderators = {...next.moderators}..remove(account);
    final electors = {...next.electors}..remove(account);
    if (role == BuiltInRole.admin) {
      admins[account] = next.rev;
      // An explicit owner promotion is an owner-chosen elector (D81).
      if (actor == state.owner) electors.add(account);
    } else if (role == BuiltInRole.moderator) {
      moderators.add(account);
    }
    return _decision(
      next.copyWith(admins: admins, moderators: moderators, electors: electors),
    );
  }

  GovernanceState setElector(String account, bool enabled) {
    if (!state.admins.containsKey(account) || !members.contains(account)) {
      _refuse('not_admin');
    }
    if (state.electors.contains(account) == enabled) _refuse('no_change');
    final electors = {...state.electors};
    enabled ? electors.add(account) : electors.remove(account);
    return _decision(_base().copyWith(electors: electors));
  }

  GovernanceState setPosting({
    required bool adminsOnly,
    required Set<String> announcementChannels,
  }) {
    if (state.adminsOnlyPosting == adminsOnly &&
        state.announcementChannels.length == announcementChannels.length &&
        state.announcementChannels.containsAll(announcementChannels)) {
      _refuse('no_change');
    }
    return _decision(
      _base().copyWith(
        adminsOnlyPosting: adminsOnly,
        announcementChannels: announcementChannels,
      ),
    );
  }

  /// C3 (record format 3): channel names and topics edited by moderators
  /// and above only ([restricted]), or by anyone. Admins and above. Not an
  /// owner role decision: it does not move `ownerRev` (D86's list).
  GovernanceState setChannelInfoRestricted(bool restricted) {
    if (state.channelInfoRestricted == restricted) _refuse('no_change');
    return _finish(_base().copyWith(channelInfoRestricted: restricted));
  }

  /// W8 (record format 3): only owners and admins pin ([adminsOnly]), or
  /// the default. Admins and above; does not move `ownerRev`.
  GovernanceState setAdminsOnlyPins(bool adminsOnly) {
    if (state.adminsOnlyPins == adminsOnly) _refuse('no_change');
    return _finish(_base().copyWith(adminsOnlyPins: adminsOnly));
  }

  /// C5 (record format 3): records the ban of [account], which must already
  /// be out of the MLS roster (a role-only commit cannot remove anyone), so
  /// this is an admin's call, as the server's ban of someone who already
  /// left. A moderator's ban goes into the removal commit itself
  /// ([recordWithBans]).
  GovernanceState ban(String account) => banAll({account});

  /// [ban] for several accounts in one commit (the server allows one
  /// role-only commit per device and conversation a minute).
  GovernanceState banAll(Set<String> accounts) {
    if (accounts.isEmpty) _refuse('no_change');
    for (final account in accounts) {
      if (members.contains(account)) _refuse('still_member');
      if (account == state.owner) _refuse('hierarchy');
      if (state.bans.contains(account)) _refuse('no_change');
    }
    if (state.rankOf(actor) < BuiltInRole.admin.rank) _refuse('notAllowed');
    if (state.bans.length + accounts.length > maxBans) {
      _refuse('too_many_bans');
    }
    return _finish(_base().copyWith(bans: {...state.bans, ...accounts}));
  }

  /// C5: lifts [account]'s ban. Admins and above. It does not add the
  /// account back.
  GovernanceState liftBan(String account) {
    if (!state.bans.contains(account)) _refuse('no_change');
    if (state.rankOf(actor) < BuiltInRole.admin.rank) _refuse('notAllowed');
    return _finish(_base().copyWith(bans: {...state.bans}..remove(account)));
  }

  GovernanceState transfer(String admin) {
    if (actor != state.owner) _refuse('not_owner');
    if (!members.contains(admin) || !state.admins.containsKey(admin)) {
      _refuse('not_admin');
    }
    return _finish(_handover(admin));
  }

  GovernanceState _handover(String winner) {
    final rev = state.rev + 1;
    final admins = {...state.admins}..remove(winner);
    final old = state.owner;
    if (old != null && members.contains(old)) admins[old] = rev;
    return state.copyWith(
      rev: rev,
      owner: winner,
      ownerRev: rev,
      admins: admins,
      moderators: {...state.moderators}..remove(winner),
      electors: {...state.electors}..remove(winner),
      clearElection: true,
    );
  }

  /// C5: records [account]'s timeout as the server set it: [fromMs] to
  /// [untilMs], the server's clock (`timeout_until` minus the length, and
  /// `timeout_until`). Replaces an earlier one.
  GovernanceState setTimeout(
    String account, {
    required int fromMs,
    required int untilMs,
  }) {
    final at = epoch;
    if (at == null) _refuse('no_epoch');
    if (!members.contains(account)) _refuse('not_member');
    if (!state.mayActOn(actor, account)) _refuse('hierarchy');
    final timeout = MemberTimeout(epoch: at, fromMs: fromMs, untilMs: untilMs);
    if (!timeout.wellFormed) _refuse('bad_timeout');
    return _finish(
      _base().copyWith(timeouts: {...state.timeouts, account: timeout}),
    );
  }

  /// C5: lifts [account]'s timeout.
  GovernanceState liftTimeout(String account) {
    if (!state.timeouts.containsKey(account)) _refuse('no_change');
    if (!state.mayActOn(actor, account)) _refuse('hierarchy');
    return _finish(
      _base().copyWith(timeouts: {...state.timeouts}..remove(account)),
    );
  }

  /// Owner cancellation and snapshot-member closure have no local wait.
  GovernanceState closeElection() {
    if (state.election == null) _refuse('no_election');
    return _finish(_base().copyWith(clearElection: true));
  }

  void _checkObservations(
    GovernanceObservations observed,
    DateTime now, {
    required bool voting,
  }) {
    if (observed.owner != state.owner || observed.ownerRev != state.ownerRev) {
      _refuse('stale_owner_observation');
    }
    if (!mayOpenElectionNow(
      now: now,
      lastOwnerActivity: observed.lastOwnerActivity,
    )) {
      _refuse('owner_active');
    }
    if (voting) {
      final seen = observed.electionSeen;
      if (seen == null || observed.electionOpened != state.election?.opened) {
        _refuse('missing_election_observation');
      }
      if (!mayVoteNow(
        now: now,
        openedSeen: seen,
        lastOwnerActivity: observed.lastOwnerActivity,
      )) {
        _refuse('election_wait');
      }
    }
  }

  GovernanceState openElection(GovernanceObservations observed, DateTime now) {
    if (state.election != null) _refuse('election_open');
    _checkObservations(observed, now, voting: false);
    final admins = state.admins.keys.where(members.contains).toSet();
    Set<String> electorate;
    if (admins.isEmpty) {
      final candidates = members.where((m) => m != state.owner).toList();
      if (candidates.isEmpty ||
          candidates.any((m) => !state.joined.containsKey(m))) {
        _refuse('missing_join_order');
      }
      candidates.sort((a, b) {
        final order = state.joined[a]!.compareTo(state.joined[b]!);
        return order == 0 ? a.compareTo(b) : order;
      });
      electorate = {candidates.first};
    } else {
      electorate = state.electors.where(members.contains).toSet();
      if (electorate.isEmpty) {
        electorate =
            admins.where((a) => state.admins[a]! <= state.ownerRev).toSet();
      }
    }
    if (!electorate.contains(actor)) _refuse('not_elector');
    return _finish(
      _base().copyWith(
        election: Election(opened: state.rev + 1, electorate: electorate),
      ),
    );
  }

  /// Includes the deciding vote's ownership change in this same commit.
  /// With no admins, the sole claimant names itself as [candidate].
  GovernanceState vote(
    String candidate,
    GovernanceObservations observed,
    DateTime now,
  ) {
    final election = state.election;
    if (election == null) _refuse('no_election');
    _checkObservations(observed, now, voting: true);
    if (!members.contains(actor) || !election.electorate.contains(actor)) {
      _refuse('not_elector');
    }
    if (election.votes.containsKey(actor)) _refuse('already_voted');
    final admins = state.admins.keys.where(members.contains).toSet();
    if (admins.isEmpty) {
      if (candidate != actor) _refuse('claim_self_only');
      return _finish(_handover(candidate));
    }
    if (!admins.contains(candidate)) _refuse('not_admin');
    final votes = {...election.votes, actor: candidate};
    if (votes.values.where((c) => c == candidate).length * 2 >
        election.electorate.length) {
      return _finish(_handover(candidate));
    }
    return _finish(
      _base().copyWith(
        election: Election(
          opened: election.opened,
          electorate: election.electorate,
          votes: votes,
        ),
      ),
    );
  }
}
