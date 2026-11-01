// C4: the server's built-in group roles, verified by every app.
//
// Pure, synchronous rules with no storage, crypto or UI. Design:
// docs/designs/C4-custom-roles.md; wire record: docs/crypto.md, "Group role
// state (C4)". The state is meant to live in a Veritra GroupContext extension
// of the group's MLS group (proposed ABI, not built), so every member agrees
// on it in epoch order, a joiner gets it in its Welcome, and the server never
// decides it. The roles and the rules mirror the server's
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

bool _mapEq(Map<String, int> a, Map<String, int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// One group's role state. Accounts not named are members.
class GovernanceState {
  GovernanceState({
    required this.rev,
    required this.owner,
    Map<String, int> admins = const {},
    Set<String> moderators = const {},
    this.adminsOnlyPosting = false,
    Set<String> announcementChannels = const {},
  })  : admins = Map.unmodifiable(admins),
        moderators = Set.unmodifiable(moderators),
        announcementChannels = Set.unmodifiable(announcementChannels);

  /// The first state, written when the creator makes the MLS group: the
  /// creator owns it, nobody else holds a role, nothing is restricted.
  factory GovernanceState.genesis(String creator) =>
      GovernanceState(rev: 0, owner: creator);

  /// Previous + 1 on every written change. A pruning at a removal keeps it.
  final int rev;

  /// The single owner, or null when the owner left and no admin remained
  /// (design owner question 1).
  final String? owner;

  /// Admin account to the [rev] at which it became admin. The smallest is
  /// the oldest admin, who inherits ownership.
  final Map<String, int> admins;
  final Set<String> moderators;

  /// A group set to "only admins post" (C2, `posting_policy = 'admins'`).
  final bool adminsOnlyPosting;

  /// Community channels of kind `announcement` (C2), by channel id.
  final Set<String> announcementChannels;

  GovernanceState copyWith({
    int? rev,
    String? owner,
    bool clearOwner = false,
    Map<String, int>? admins,
    Set<String>? moderators,
    bool? adminsOnlyPosting,
    Set<String>? announcementChannels,
  }) =>
      GovernanceState(
        rev: rev ?? this.rev,
        owner: clearOwner ? null : (owner ?? this.owner),
        admins: admins ?? this.admins,
        moderators: moderators ?? this.moderators,
        adminsOnlyPosting: adminsOnlyPosting ?? this.adminsOnlyPosting,
        announcementChannels: announcementChannels ?? this.announcementChannels,
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
  /// a kicked admin who is invited back is a member. If the owner left, the
  /// oldest admin still in [remaining] (smallest [admins] value, then the
  /// smallest account id) becomes owner; with no admin left, nobody does.
  /// [remaining] is the roster after the commit. [rev] is kept.
  GovernanceState removeAccount(
    String account, {
    required Set<String> remaining,
  }) {
    final pruned = copyWith(
      admins: {...admins}..remove(account),
      moderators: {...moderators}..remove(account),
    );
    if (account != owner) return pruned;
    final heirs = [
      for (final e in pruned.admins.entries)
        if (remaining.contains(e.key) && e.key != account) e,
    ]..sort((a, b) {
        final r = a.value.compareTo(b.value);
        return r != 0 ? r : a.key.compareTo(b.key);
      });
    if (heirs.isEmpty) return pruned.copyWith(clearOwner: true);
    final heir = heirs.first.key;
    return pruned.copyWith(
      owner: heir,
      admins: {...pruned.admins}..remove(heir),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GovernanceState &&
      other.rev == rev &&
      other.owner == owner &&
      _mapEq(other.admins, admins) &&
      _setEq(other.moderators, moderators) &&
      other.adminsOnlyPosting == adminsOnlyPosting &&
      _setEq(other.announcementChannels, announcementChannels);

  @override
  int get hashCode => Object.hash(
        rev,
        owner,
        admins.length,
        moderators.length,
        adminsOnlyPosting,
        announcementChannels.length,
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
/// same answer.
///
/// Rules, as on the server: changing someone's role needs moderator or
/// above; the target's current role must be strictly below the actor's and
/// the new one at most the actor's. Anyone may step down (not the owner,
/// who transfers first). Only the owner moves ownership, and only to a
/// current admin. Posting restrictions need admin or above.
GovernanceCheck validateTransition(
  GovernanceState prev,
  GovernanceState next,
  String actor, {
  required Set<String> members,
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
  if (next.announcementChannels.length > maxAnnouncementChannels ||
      next.announcementChannels.any((c) => c.isEmpty)) {
    return no(GovernanceReject.badShape);
  }
  final named = {
    if (owner != null) owner,
    ...next.admins.keys,
    ...next.moderators,
  };
  if (!members.containsAll(named) || !members.contains(actor)) {
    return no(GovernanceReject.notMember);
  }
  // An admin keeps its seniority; a new admin starts at this rev.
  for (final e in next.admins.entries) {
    final since =
        prev.roleOf(e.key) == BuiltInRole.admin ? prev.admins[e.key] : next.rev;
    if (e.value != since) return no(GovernanceReject.badShape);
  }

  final actorRank = prev.rankOf(actor);

  // Posting restrictions.
  if (next.adminsOnlyPosting != prev.adminsOnlyPosting ||
      !_setEq(next.announcementChannels, prev.announcementChannels)) {
    if (actorRank < BuiltInRole.admin.rank) {
      return no(GovernanceReject.notAllowed);
    }
  }

  // Ownership.
  final transfer = next.owner != prev.owner;
  if (transfer) {
    if (prev.owner == null || actor != prev.owner || next.owner == null) {
      return no(GovernanceReject.ownerChange);
    }
    if (prev.roleOf(next.owner!) != BuiltInRole.admin) {
      return no(GovernanceReject.ownerChange);
    }
  }

  // Role changes.
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

/// The whole check for one MLS commit. [prev] is the state before it,
/// [next] the state its GroupContext carries after it ([prev] when the commit
/// does not change the extension), [before] and [after] the rosters. Every
/// account whose last device the commit removes is pruned first
/// ([GovernanceState.removeAccount]); the result must be exactly [next], or
/// [next] must be a valid change by [committer] from it.
GovernanceCheck validateCommit(
  GovernanceState prev,
  GovernanceState next,
  String committer, {
  required Set<String> before,
  required Set<String> after,
}) {
  var base = prev;
  for (final gone in before.difference(after)) {
    base = base.removeAccount(gone, remaining: after);
  }
  if (next == base) return const GovernanceCheck.ok();
  if (next == prev) return const GovernanceCheck.no(GovernanceReject.notPruned);
  return validateTransition(base, next, committer, members: after);
}
