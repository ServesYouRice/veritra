// C4: the server's built-in group roles, verified by every app.
//
// Pure, synchronous rules with no storage, crypto or UI. Design:
// docs/designs/C4-custom-roles.md; wire record: docs/crypto.md, "Group role
// state (C4)". The state is meant to live in a Veritra GroupContext extension
// of the group's MLS group (proposed ABI, not built), so every member agrees
// on it in epoch order, a joiner gets it in its Welcome, and the server never
// decides it. Owner handover (D81, D82) is a challenge, a wait and an admin
// vote, all as commits; the clocks stay local (see the helpers below). The
// roles and the rules mirror the server's
// (server/internal/domain/types.go `RoleRank`, `CanManageMembers`,
// `CanPostRestricted`, `CanModerate`; storage/community_store.go
// `ManageConversationMember`), so the two layers agree. Apps never trust the
// server-reported role (D80).

/// The four built-in roles. [rank] equals the server's `domain.RoleRank`.
enum BuiltInRole {
  member,
  moderator,
  admin,
  owner;

  int get rank => index + 1;
}

/// At most this many announcement channels (C3's channel limit).
const int maxAnnouncementChannels = 500;

bool _setEq(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

bool _mapEq<V>(Map<String, V> a, Map<String, V> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// D81: an honest app opens an election only after it has seen this long
/// with no owner activity, and votes only after the same.
const Duration ownerInactivityWait = Duration(days: 30);

/// D81: and a vote needs this long since the election opened.
const Duration electionWait = Duration(days: 7);

/// Local clock rule (not in [validateCommit]): may this app open an election
/// now? [lastOwnerActivity] is the last owner commit or application message
/// the app received in the group, or when the app first saw the group.
bool mayOpenElectionNow({
  required DateTime now,
  required DateTime lastOwnerActivity,
}) =>
    now.difference(lastOwnerActivity) >= ownerInactivityWait;

/// Local clock rule: may this app vote (or, in a claim, take ownership) now?
/// [openedSeen] is when this app saw the election open.
bool mayVoteNow({
  required DateTime now,
  required DateTime openedSeen,
  required DateTime lastOwnerActivity,
}) =>
    now.difference(openedSeen) >= electionWait &&
    now.difference(lastOwnerActivity) >= ownerInactivityWait;

/// An open owner election (D81). [electorate] is the snapshot of who may vote
/// when it opened; it never grows, and removals never shrink it, so the
/// majority threshold stays fixed. [votes] maps voter to the admin voted for.
/// A claim by the longest-serving member (no admin in the roster) is an
/// election whose electorate is just that member.
class Election {
  Election({
    required this.opened,
    required Set<String> electorate,
    Map<String, String> votes = const {},
  })  : electorate = Set.unmodifiable(electorate),
        votes = Map.unmodifiable(votes);

  /// The record `rev` that opened it.
  final int opened;
  final Set<String> electorate;
  final Map<String, String> votes;

  @override
  bool operator ==(Object other) =>
      other is Election &&
      other.opened == opened &&
      _setEq(other.electorate, electorate) &&
      _mapEq(other.votes, votes);

  @override
  int get hashCode => Object.hash(opened, electorate.length, votes.length);
}

/// The longest-serving roster member other than [owner]: smallest `joined`,
/// then smallest account id. Null when nobody qualifies or any such member has
/// no `joined` entry (refused, never guessed).
String? _longestServing(
  Map<String, int> joined,
  Set<String> members,
  String? owner,
) {
  final candidates = [
    for (final m in members)
      if (m != owner) m,
  ];
  if (candidates.isEmpty || candidates.any((m) => !joined.containsKey(m))) {
    return null;
  }
  candidates.sort((a, b) {
    final r = joined[a]!.compareTo(joined[b]!);
    return r != 0 ? r : a.compareTo(b);
  });
  return candidates.first;
}

/// One group's role state. Accounts not named are members.
class GovernanceState {
  GovernanceState({
    required this.rev,
    required this.owner,
    required this.ownerRev,
    Map<String, int> admins = const {},
    Set<String> moderators = const {},
    this.adminsOnlyPosting = false,
    Set<String> announcementChannels = const {},
    Set<String> electors = const {},
    this.election,
    Map<String, int> joined = const {},
  })  : admins = Map.unmodifiable(admins),
        moderators = Set.unmodifiable(moderators),
        announcementChannels = Set.unmodifiable(announcementChannels),
        electors = Set.unmodifiable(electors),
        joined = Map.unmodifiable(joined);

  /// The first state, written when the creator makes the MLS group: the
  /// creator owns it, nobody else holds a role, nothing is restricted.
  factory GovernanceState.genesis(String creator) => GovernanceState(
      rev: 0, owner: creator, ownerRev: 0, joined: {creator: 0});

  /// Previous + 1 on every written change. A pruning at a removal keeps it.
  final int rev;

  /// The single owner. It is never pruned (D81): it may name an account that
  /// is no longer in the roster, which counts as inactivity and nothing more.
  /// Null only in a malformed or legacy state; no rule here produces it.
  final String? owner;

  /// The [rev] of the owner's last role decision: its last commit that itself
  /// changed the owner, admins, moderators, electors or a posting field.
  /// Pruning, the dead-election clear, an add's `joined` stamp and the forced
  /// cancel never move it, so [requiredRecord] never stamps it; a win or a
  /// claim stamps its own rev, because the new owner's tenure starts there.
  /// It never moves backwards. Owner decision 2026-11-07: an election opened
  /// from the D82 fallback (no elector present) lets only admins vote whose
  /// `since` is at or before it. Whoever the owner left in place at its last
  /// role decision still counts; admins put in power afterwards, while it
  /// made none, never do. Receivers can check this without a clock.
  final int ownerRev;

  /// Admin account to the [rev] at which it became admin (seniority).
  final Map<String, int> admins;
  final Set<String> moderators;

  /// A group set to "only admins post" (C2, `posting_policy = 'admins'`).
  final bool adminsOnlyPosting;

  /// Community channels of kind `announcement` (C2), by channel id.
  final Set<String> announcementChannels;

  /// The admins the owner chose (D81): promoted by the owner, or confirmed by
  /// an owner commit. Only they vote, unless none is in the roster (D82).
  /// Always a subset of [admins]; cleared when an account stops being admin.
  final Set<String> electors;

  /// The open owner election, or null.
  final Election? election;

  /// Account to the [rev] at which its first device was added; a removal
  /// drops it. Orders the longest-serving member when no admin is left.
  final Map<String, int> joined;

  /// D81: the owner cannot leave without transferring ownership first. An app
  /// rule: it refuses to commit such a leave. [validateCommit] still accepts a
  /// forced removal of the owner (the server can force one) and keeps it owner.
  bool mayLeave(String account) => account != owner;

  GovernanceState copyWith({
    int? rev,
    String? owner,
    bool clearOwner = false,
    int? ownerRev,
    Map<String, int>? admins,
    Set<String>? moderators,
    bool? adminsOnlyPosting,
    Set<String>? announcementChannels,
    Set<String>? electors,
    Election? election,
    bool clearElection = false,
    Map<String, int>? joined,
  }) =>
      GovernanceState(
        rev: rev ?? this.rev,
        owner: clearOwner ? null : (owner ?? this.owner),
        ownerRev: ownerRev ?? this.ownerRev,
        admins: admins ?? this.admins,
        moderators: moderators ?? this.moderators,
        adminsOnlyPosting: adminsOnlyPosting ?? this.adminsOnlyPosting,
        announcementChannels: announcementChannels ?? this.announcementChannels,
        electors: electors ?? this.electors,
        election: clearElection ? null : (election ?? this.election),
        joined: joined ?? this.joined,
      );

  /// The account's role. Meaningful only for an account in the MLS roster.
  BuiltInRole roleOf(String account) {
    if (account == owner) return BuiltInRole.owner;
    if (admins.containsKey(account)) return BuiltInRole.admin;
    if (moderators.contains(account)) return BuiltInRole.moderator;
    return BuiltInRole.member;
  }

  int rankOf(String account) => roleOf(account).rank;

  /// Whether posting is limited to admins: the whole group, or the channel.
  bool isRestricted({String? channelId}) =>
      adminsOnlyPosting ||
      (channelId != null && announcementChannels.contains(channelId));

  /// C2: may [sender] post here? Owners and admins only where restricted
  /// (the server's `CanPostRestricted`).
  bool mayPost(String sender, {String? channelId}) =>
      !isRestricted(channelId: channelId) ||
      rankOf(sender) >= BuiltInRole.admin.rank;

  /// C1/C5 kick, ban, timeout, delete-others: [actor] is a moderator or
  /// above and strictly outranks [target]; never itself (`CanModerate`).
  bool mayActOn(String actor, String target) =>
      actor != target &&
      rankOf(actor) >= BuiltInRole.moderator.rank &&
      rankOf(target) < rankOf(actor);

  /// The state after [account]'s last device left the MLS group. The
  /// removing commit must carry exactly this (or a valid change from it), so
  /// a kicked admin who is invited back is a member. The account loses its
  /// admin, elector and moderator roles, its `joined` entry, and its votes and
  /// votes for it. The owner is never pruned and nobody inherits (D81); the
  /// election's electorate is kept, so a removal can never decide a win.
  /// [rev] is kept.
  GovernanceState removeAccount(String account) {
    final e = election;
    return copyWith(
      admins: {...admins}..remove(account),
      moderators: {...moderators}..remove(account),
      electors: {...electors}..remove(account),
      joined: {...joined}..remove(account),
      election: e == null
          ? null
          : Election(
              opened: e.opened,
              electorate: e.electorate,
              votes: {
                for (final v in e.votes.entries)
                  if (v.key != account && v.value != account) v.key: v.value,
              },
            ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GovernanceState &&
      other.rev == rev &&
      other.owner == owner &&
      other.ownerRev == ownerRev &&
      _mapEq(other.admins, admins) &&
      _setEq(other.moderators, moderators) &&
      other.adminsOnlyPosting == adminsOnlyPosting &&
      _setEq(other.announcementChannels, announcementChannels) &&
      _setEq(other.electors, electors) &&
      other.election == election &&
      _mapEq(other.joined, joined);

  @override
  int get hashCode => Object.hash(
        rev,
        owner,
        ownerRev,
        admins.length,
        moderators.length,
        adminsOnlyPosting,
        announcementChannels.length,
        electors.length,
        election,
        joined.length,
      );
}

/// Why a change was refused. Stable codes for logs and tests.
enum GovernanceReject {
  badRev,
  badShape,
  notMember,
  notAllowed,
  hierarchy,
  ownerChange,

  /// An election opened, voted in, closed or left open against the rules.
  election,

  /// A commit removed a named account but did not prune it.
  notPruned,
}

class GovernanceCheck {
  const GovernanceCheck.ok() : reject = null;
  const GovernanceCheck.no(GovernanceReject this.reject);
  final GovernanceReject? reject;
  bool get ok => reject == null;
}

/// Decides whether [actor], the MLS-authenticated committer, may move the
/// group from [prev] to [next]. [members] is the MLS roster (accounts) after
/// the commit, never the server's roster, so every honest device reaches the
/// same answer. [added] is the accounts the commit newly adds to the roster:
/// each must be stamped in `joined` with [next]'s `rev`.
///
/// Rules, as on the server: changing someone's role needs moderator or
/// above; the target's current role must be strictly below the actor's and
/// the new one at most the actor's. Anyone may step down (not the owner,
/// who transfers first). Posting restrictions need admin or above.
///
/// Ownership (D81, D82) moves in two ways. The owner transfers it to a
/// current admin. Or an election wins: any commit by the owner while one is
/// open must clear it; an account may open one (an elector, else every admin
/// who was admin by `ownerRev`; with no admin in the roster the
/// longest-serving member claims), vote once for an admin in the roster, or
/// close it if it is in the snapshot; the commit holding the vote of more
/// than half of the snapshot must itself set the owner and clear the
/// election. Waiting periods are local ([mayOpenElectionNow],
/// [mayVoteNow]); what receivers can check instead is `ownerRev`: the D82
/// snapshot holds only admins who were admin by then. An owner commit that
/// changes roles or posting sets it to its own rev, a win sets it to the
/// winning rev, nothing else moves it.
GovernanceCheck validateTransition(
  GovernanceState prev,
  GovernanceState next,
  String actor, {
  required Set<String> members,
  Set<String> added = const {},
}) {
  GovernanceCheck no(GovernanceReject r) => GovernanceCheck.no(r);
  if (next.rev != prev.rev + 1) return no(GovernanceReject.badRev);

  // Shape.
  final owner = next.owner;
  if (owner != null &&
      (next.admins.containsKey(owner) || next.moderators.contains(owner))) {
    return no(GovernanceReject.badShape);
  }
  if (next.moderators.any(next.admins.containsKey)) {
    return no(GovernanceReject.badShape);
  }
  if (!next.electors.every(next.admins.containsKey)) {
    return no(GovernanceReject.badShape);
  }
  if (next.ownerRev > next.rev) {
    return no(GovernanceReject.badShape);
  }
  if (next.announcementChannels.length > maxAnnouncementChannels ||
      next.announcementChannels.any((c) => c.isEmpty)) {
    return no(GovernanceReject.badShape);
  }
  // The owner is not named here: it may be out of the roster (D81).
  final named = {...next.admins.keys, ...next.moderators};
  if (!members.containsAll(named) ||
      !members.contains(actor) ||
      !members.containsAll(next.joined.keys)) {
    return no(GovernanceReject.notMember);
  }
  // An admin keeps its seniority; a new admin starts at this rev.
  for (final e in next.admins.entries) {
    final since =
        prev.roleOf(e.key) == BuiltInRole.admin ? prev.admins[e.key] : next.rev;
    if (e.value != since) return no(GovernanceReject.badShape);
  }
  // `joined` is written once, when an account is added, and only a removal
  // (already pruned in [prev]) drops it. Dropping another member's entry
  // would disable the no-admin claim for good.
  if (!next.joined.keys.toSet().containsAll(prev.joined.keys)) {
    return no(GovernanceReject.badShape);
  }
  for (final e in next.joined.entries) {
    final was = prev.joined[e.key];
    final ok = was != null
        ? e.value == was
        : added.contains(e.key) && e.value == next.rev;
    if (!ok) return no(GovernanceReject.badShape);
  }
  if (added.any((a) => next.joined[a] != next.rev)) {
    return no(GovernanceReject.badShape);
  }
  final poll = next.election;
  if (poll != null) {
    if (poll.opened > next.rev || poll.electorate.isEmpty) {
      return no(GovernanceReject.badShape);
    }
    if (!poll.votes.keys.every(poll.electorate.contains)) {
      return no(GovernanceReject.badShape);
    }
    if (!members.containsAll(poll.votes.keys)) {
      return no(GovernanceReject.notMember);
    }
    // A vote names an admin in the roster.
    if (!poll.votes.values.every(
      (c) => next.admins.containsKey(c) && members.contains(c),
    )) {
      return no(GovernanceReject.election);
    }
  }

  final actorRank = prev.rankOf(actor);
  final ownerActs = prev.owner != null && actor == prev.owner;
  final transfer = next.owner != prev.owner;

  // Posting restrictions.
  if (next.adminsOnlyPosting != prev.adminsOnlyPosting ||
      !_setEq(next.announcementChannels, prev.announcementChannels)) {
    if (actorRank < BuiltInRole.admin.rank) {
      return no(GovernanceReject.notAllowed);
    }
  }

  // Electors: only an owner commit sets or clears the flag of an admin that
  // stays admin (never in a transfer). Nothing else, an automatic cancel
  // included, makes an elector.
  for (final a in next.electors.difference(prev.electors)) {
    if (!ownerActs || transfer || a == actor) {
      return no(GovernanceReject.notAllowed);
    }
  }
  for (final a in prev.electors.difference(next.electors)) {
    if (next.admins.containsKey(a) && !ownerActs) {
      return no(GovernanceReject.notAllowed);
    }
  }

  // Ownership.
  var handover = false;
  if (transfer) {
    final heir = next.owner;
    if (heir == null) return no(GovernanceReject.ownerChange);
    if (ownerActs) {
      if (prev.roleOf(heir) != BuiltInRole.admin || !members.contains(heir)) {
        return no(GovernanceReject.ownerChange);
      }
    } else {
      final r = _checkWin(prev, next, actor, members);
      if (r != null) return no(r);
      handover = true;
    }
  }

  // The election.
  if (ownerActs) {
    if (next.election != null) return no(GovernanceReject.election);
  } else if (!handover) {
    final r = _checkElection(prev, next, actor, members);
    if (r != null) return no(r);
  }

  // The owner's last role decision. Only an owner commit that itself changes
  // the owner, admins, moderators, electors or a posting field (and a win,
  // which starts a new owner's tenure) moves it, and then to this rev.
  // Pruning, the dead-election clear, an add's `joined` stamp and the
  // forced cancel are not the owner's decisions and leave it. Else a rogue
  // admin would stamp it itself and make its stand-ins old enough to vote, or
  // an automatic owner commit would do it for the rogue.
  final ownChange = transfer ||
      !_mapEq(next.admins, prev.admins) ||
      !_setEq(next.moderators, prev.moderators) ||
      !_setEq(next.electors, prev.electors) ||
      next.adminsOnlyPosting != prev.adminsOnlyPosting ||
      !_setEq(next.announcementChannels, prev.announcementChannels);
  final expectedOwnerRev =
      handover || (ownerActs && ownChange) ? next.rev : prev.ownerRev;
  if (next.ownerRev != expectedOwnerRev) return no(GovernanceReject.badShape);

  // Role changes. A won election moves exactly the roles `_checkWin` fixed.
  if (handover) return const GovernanceCheck.ok();
  final accounts = {
    if (prev.owner case final o?) o,
    ...prev.admins.keys,
    ...prev.moderators,
    ...named,
  };
  for (final a in accounts) {
    final was = prev.roleOf(a);
    final now = next.roleOf(a);
    if (was == now) continue;
    if (transfer && a == next.owner) continue; // checked above
    if (a == actor) {
      // Stepping down gains nothing; taking a role is never allowed.
      if (now.rank < was.rank) continue;
      return no(GovernanceReject.hierarchy);
    }
    if (actorRank < BuiltInRole.moderator.rank) {
      return no(GovernanceReject.notAllowed);
    }
    if (was.rank >= actorRank || now.rank > actorRank) {
      return no(GovernanceReject.hierarchy);
    }
  }
  return const GovernanceCheck.ok();
}

/// A non-owner commit that sets the owner: it must be the deciding vote of an
/// open election (or the claim in one), and change nothing else but the roles
/// of the old and new owner. Null when valid.
GovernanceReject? _checkWin(
  GovernanceState prev,
  GovernanceState next,
  String actor,
  Set<String> members,
) {
  final el = prev.election;
  final winner = next.owner;
  if (el == null ||
      next.election != null ||
      winner == null ||
      !el.electorate.contains(actor)) {
    return GovernanceReject.ownerChange;
  }
  final live = {
    for (final a in prev.admins.keys)
      if (members.contains(a)) a,
  };
  if (live.isNotEmpty) {
    if (el.votes.containsKey(actor)) return GovernanceReject.election;
    if (!live.contains(winner)) return GovernanceReject.ownerChange;
    final tally = el.votes.values.where((c) => c == winner).length + 1;
    if (tally * 2 <= el.electorate.length) return GovernanceReject.ownerChange;
  } else if (el.electorate.length != 1 ||
      winner != actor ||
      el.votes.isNotEmpty ||
      _longestServing(next.joined, members, prev.owner) != actor) {
    // A claim: no admin in the roster and the sole claimant takes it itself.
    return GovernanceReject.ownerChange;
  }
  // The old owner, if still a member, becomes an admin from this rev.
  final old = prev.owner;
  final admins = {...prev.admins}..remove(winner);
  if (old != null && members.contains(old)) admins[old] = next.rev;
  final ok = _mapEq(next.admins, admins) &&
      _setEq(next.electors, prev.electors.difference({winner})) &&
      _setEq(next.moderators, prev.moderators.difference({winner})) &&
      next.adminsOnlyPosting == prev.adminsOnlyPosting &&
      _setEq(next.announcementChannels, prev.announcementChannels);
  return ok ? null : GovernanceReject.badShape;
}

/// Open, close and vote by someone other than the owner, without a transfer.
/// Null when valid or when no election is involved.
GovernanceReject? _checkElection(
  GovernanceState prev,
  GovernanceState next,
  String actor,
  Set<String> members,
) {
  final was = prev.election;
  final now = next.election;
  if (was == null && now == null) return null;
  if (now == null) {
    // Close: any account in the snapshot. Nobody gains anything.
    return was!.electorate.contains(actor) ? null : GovernanceReject.election;
  }
  if (was == null) {
    // Open: nothing about the admins changes, and no votes yet.
    if (now.opened != next.rev ||
        now.votes.isNotEmpty ||
        !_mapEq(next.admins, prev.admins) ||
        !_setEq(next.electors, prev.electors)) {
      return GovernanceReject.election;
    }
    final admins = {
      for (final a in prev.admins.keys)
        if (members.contains(a)) a,
    };
    final Set<String> electorate;
    if (admins.isEmpty) {
      final claimant = _longestServing(next.joined, members, prev.owner);
      if (claimant == null || claimant != actor) {
        return GovernanceReject.election;
      }
      electorate = {claimant};
    } else {
      final electors = {
        for (final a in prev.electors)
          if (members.contains(a)) a,
      };
      // D82: with no elector present every admin in the roster votes, but only
      // those already admin when the owner last committed (`ownerRev`). The
      // admins put in power since then, while the owner was silent, never do.
      electorate = electors.isNotEmpty
          ? electors
          : {
              for (final a in admins)
                if (prev.admins[a]! <= prev.ownerRev) a,
            };
      if (!electorate.contains(actor)) return GovernanceReject.election;
    }
    return _setEq(now.electorate, electorate)
        ? null
        : GovernanceReject.election;
  }
  // Vote: the same election, old votes kept, at most the actor's own added.
  if (now.opened != was.opened || !_setEq(now.electorate, was.electorate)) {
    return GovernanceReject.election;
  }
  for (final e in was.votes.entries) {
    if (now.votes[e.key] != e.value) return GovernanceReject.election;
  }
  final fresh = now.votes.keys.where((k) => !was.votes.containsKey(k));
  if (fresh.length > 1 || (fresh.isNotEmpty && fresh.single != actor)) {
    return GovernanceReject.election;
  }
  // A deciding vote must set the owner in the same commit (see _checkWin).
  final tally = <String, int>{};
  for (final c in now.votes.values) {
    tally[c] = (tally[c] ?? 0) + 1;
  }
  if (tally.values.any((n) => n * 2 > now.electorate.length)) {
    return GovernanceReject.election;
  }
  return null;
}

/// The record a commit must carry when the committer changes nothing itself:
/// every account whose last device the commit removes is pruned
/// ([GovernanceState.removeAccount]); an election with nobody from its
/// snapshot left in the roster is cleared (nobody could close it, and no new
/// one could open); both keep `rev`. Then an add stamps `joined`, and an
/// owner commit clears an open election; each of those rewrites the record at
/// `rev + 1`. It never stamps `ownerRev`: only the owner's own role or
/// posting change does, and that is a change by the committer. A bare owner
/// commit (self-update, reconcile, revocation) carries no record. Commit
/// producers use this to build their record, and [validateCommit] checks
/// against it, so the two cannot drift.
GovernanceState requiredRecord(
  GovernanceState prev,
  String committer, {
  required Set<String> before,
  required Set<String> after,
}) =>
    _required(prev, committer, before: before, after: after).record;

({GovernanceState base, GovernanceState record, bool cancel}) _required(
  GovernanceState prev,
  String committer, {
  required Set<String> before,
  required Set<String> after,
}) {
  var base = prev;
  for (final gone in before.difference(after)) {
    base = base.removeAccount(gone);
  }
  final el = base.election;
  if (el != null && !el.electorate.any(after.contains)) {
    base = base.copyWith(clearElection: true);
  }
  final added = after.difference(before);
  final cancel =
      prev.owner != null && committer == prev.owner && base.election != null;
  var record = base;
  if (added.isNotEmpty || cancel) {
    record = base.copyWith(
      rev: base.rev + 1,
      clearElection: cancel,
      joined: {...base.joined, for (final a in added) a: base.rev + 1},
    );
  }
  return (base: base, record: record, cancel: cancel);
}

/// The whole check for one MLS commit. [prev] is the state before it,
/// [next] the state its GroupContext carries after it ([prev] when the commit
/// does not change the extension), [before] and [after] the rosters.
/// [next] must be exactly [requiredRecord], or a valid change by [committer]
/// from the pruned record.
GovernanceCheck validateCommit(
  GovernanceState prev,
  GovernanceState next,
  String committer, {
  required Set<String> before,
  required Set<String> after,
}) {
  final (:base, record: expected, :cancel) = _required(
    prev,
    committer,
    before: before,
    after: after,
  );
  if (next == expected) return const GovernanceCheck.ok();
  if (next == prev) {
    return GovernanceCheck.no(
      cancel
          ? GovernanceReject.election
          : base != prev
              ? GovernanceReject.notPruned
              : GovernanceReject.badRev,
    );
  }
  return validateTransition(
    base,
    next,
    committer,
    members: after,
    added: after.difference(before),
  );
}

/// C4 removal proofs (docs/crypto.md, "C4 app wiring"): whether a commit that
/// takes [account]'s last device out of the group must be justified, because
/// pruning the account changes who governs. True for an admin, moderator or
/// elector, and for an account in an open election's electorate, a voter or
/// a candidate with a vote. Never for the owner, who is never pruned and may
/// be out of the roster (D81), nor for a plain member, whose removal moves
/// only its `joined` entry. Receivers and producers both use this.
bool removalNeedsProof(GovernanceState state, String account) {
  if (account == state.owner) return false;
  final election = state.election;
  return state.admins.containsKey(account) ||
      state.moderators.contains(account) ||
      state.electors.contains(account) ||
      (election != null &&
          (election.electorate.contains(account) ||
              election.votes.containsKey(account) ||
              election.votes.containsValue(account)));
}
