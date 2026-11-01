// C4: custom roles, permission switches and per-channel overrides.
//
// Pure, synchronous rules with no storage, crypto or UI. The design is
// docs/designs/C4-custom-roles.md; the wire record is docs/crypto.md,
// "Group governance record (C4)". The record is carried in the group's MLS
// application messages, so the sender of a record is the MLS-authenticated
// account (D25) and the server never sees it.

/// Permission switches. Wire names are the strings; unknown strings are kept
/// and never given meaning, so an older app does not strip a newer switch.
abstract final class Perm {
  static const administrator = 'administrator';
  static const viewChannel = 'view_channel';
  static const post = 'post';
  static const react = 'react';
  static const attach = 'attach';
  static const mentionAll = 'mention_all';
  static const pin = 'pin';
  static const manageMessages = 'manage_messages';
  static const manageChannels = 'manage_channels';
  static const manageRoles = 'manage_roles';
  static const manageMembers = 'manage_members';
  static const kick = 'kick';
  static const ban = 'ban';
  static const timeout = 'timeout';
  static const editGroupInfo = 'edit_group_info';
  static const viewAuditLog = 'view_audit_log';
  static const manageInvites = 'manage_invites';

  /// Switches that can be overridden per channel.
  static const channelScoped = {
    viewChannel,
    post,
    react,
    attach,
    mentionAll,
    pin,
    manageMessages,
  };

  /// Switches that only exist group-wide.
  static const groupScoped = {
    administrator,
    manageChannels,
    manageRoles,
    manageMembers,
    kick,
    ban,
    timeout,
    editGroupInfo,
    viewAuditLog,
    manageInvites,
  };
}

const String memberRoleId = 'member';
const int memberRank = 1000;
const int maxRoles = 32;
const int maxOverrides = 256;
const int maxRoleNameUnits = 32;

final RegExp _roleIdPattern = RegExp(r'^[a-z0-9_]{1,32}$');

bool _setEq(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

class Role {
  const Role(this.id, this.name, this.rank, this.perms);
  final String id;
  final String name;

  /// Lower is more powerful. Unique per record. `member` is always 1000.
  final int rank;
  final Set<String> perms;

  @override
  bool operator ==(Object other) =>
      other is Role &&
      other.id == id &&
      other.name == name &&
      other.rank == rank &&
      _setEq(other.perms, perms);
  @override
  int get hashCode => Object.hash(id, name, rank, perms.length);
}

/// An override of one role or one account in one channel.
class ChannelOverride {
  const ChannelOverride({
    required this.channelId,
    required this.targetIsRole,
    required this.targetId,
    this.allow = const {},
    this.deny = const {},
  });
  final String channelId;
  final bool targetIsRole;
  final String targetId;
  final Set<String> allow;
  final Set<String> deny;

  String get key => '$channelId|${targetIsRole ? 'r' : 'a'}|$targetId';

  @override
  bool operator ==(Object other) =>
      other is ChannelOverride &&
      other.key == key &&
      _setEq(other.allow, allow) &&
      _setEq(other.deny, deny);
  @override
  int get hashCode => Object.hash(key, allow.length, deny.length);
}

class GovernanceState {
  GovernanceState({
    required this.rev,
    required this.owner,
    required this.roles,
    required this.assignments,
    required this.overrides,
  });

  /// The first record: the creator owns the group, `member` has the open
  /// defaults of D58 and D59, and `admin` and `moderator` are ordinary roles.
  factory GovernanceState.genesis(String owner) => GovernanceState(
        rev: 0,
        owner: owner,
        roles: {
          'admin': const Role('admin', 'Admin', 10, {Perm.administrator}),
          'moderator': const Role('moderator', 'Moderator', 20, {
            Perm.viewChannel,
            Perm.post,
            Perm.react,
            Perm.attach,
            Perm.mentionAll,
            Perm.pin,
            Perm.manageMessages,
            Perm.kick,
            Perm.timeout,
            Perm.viewAuditLog,
            Perm.editGroupInfo,
          }),
          memberRoleId: const Role(memberRoleId, 'Member', memberRank, {
            Perm.viewChannel,
            Perm.post,
            Perm.react,
            Perm.attach,
            Perm.pin,
            Perm.editGroupInfo,
          }),
        },
        assignments: {},
        overrides: {},
      );

  final int rev;
  final String owner;
  final Map<String, Role> roles;

  /// Account to extra role ids (never `member`, never the owner).
  final Map<String, Set<String>> assignments;

  /// Keyed by [ChannelOverride.key].
  final Map<String, ChannelOverride> overrides;

  GovernanceState copyWith({
    int? rev,
    String? owner,
    Map<String, Role>? roles,
    Map<String, Set<String>>? assignments,
    Map<String, ChannelOverride>? overrides,
  }) =>
      GovernanceState(
        rev: rev ?? this.rev,
        owner: owner ?? this.owner,
        roles: roles ?? Map.of(this.roles),
        assignments: assignments ??
            {
              for (final e in this.assignments.entries) e.key: {...e.value},
            },
        overrides: overrides ?? Map.of(this.overrides),
      );

  /// The account's roles, always including `member`. Unknown ids are skipped.
  List<Role> rolesOf(String account) => [
        for (final id in assignments[account] ?? const <String>{})
          if (roles[id] case final r?) r,
        roles[memberRoleId]!,
      ];

  /// Lowest rank number held. The owner is -1, above every role.
  int topRank(String account) => account == owner
      ? -1
      : rolesOf(account).map((r) => r.rank).reduce((a, b) => a < b ? a : b);

  bool isAdmin(String account) =>
      account == owner ||
      rolesOf(account).any((r) => r.perms.contains(Perm.administrator));

  /// Effective switches for [account], in [channelId] when given. Order, as
  /// in Discord: role union, then the `member` override, then the union of
  /// the account's other role overrides (denies first, then allows), then the
  /// account's own override. Owner and administrators skip overrides.
  /// Without `view_channel`, no channel-scoped switch is granted.
  Set<String> permissionsIn(String account, {String? channelId}) {
    if (isAdmin(account)) {
      return {...Perm.channelScoped, ...Perm.groupScoped};
    }
    final held = rolesOf(account);
    final perms = <String>{for (final r in held) ...r.perms};
    if (channelId == null) return perms;

    ChannelOverride? ov(bool role, String id) =>
        overrides['$channelId|${role ? 'r' : 'a'}|$id'];

    final base = ov(true, memberRoleId);
    if (base != null) {
      perms
        ..removeAll(base.deny)
        ..addAll(base.allow);
    }
    final denies = <String>{};
    final allows = <String>{};
    for (final r in held) {
      if (r.id == memberRoleId) continue;
      final o = ov(true, r.id);
      if (o == null) continue;
      denies.addAll(o.deny);
      allows.addAll(o.allow);
    }
    perms
      ..removeAll(denies)
      ..addAll(allows);
    final own = ov(false, account);
    if (own != null) {
      perms
        ..removeAll(own.deny)
        ..addAll(own.allow);
    }
    if (!perms.contains(Perm.viewChannel)) {
      perms.removeAll(Perm.channelScoped);
    }
    return perms;
  }

  bool can(String account, String perm, {String? channelId}) =>
      permissionsIn(account, channelId: channelId).contains(perm);

  /// Whether [actor] may use [perm] against [target] (C5 kick, ban and
  /// timeout; C1 removals): it holds the switch and strictly outranks the
  /// target. Nobody acts on the owner or on itself through this.
  bool mayActOn(
    String actor,
    String target,
    String perm, {
    String? channelId,
  }) =>
      actor != target &&
      can(actor, perm, channelId: channelId) &&
      topRank(actor) < topRank(target);

  /// The state after [account] left the group (its last device removed by
  /// an MLS commit). Every device applies this at that commit's place in
  /// sync order, so it needs no record and keeps [rev]. Dropping the
  /// account's assignments and own overrides means a kicked admin who is
  /// invited back is a plain member, and later records are not refused for
  /// naming a departed account. If the owner left, ownership passes to the
  /// strongest remaining account ([topRank], then the smallest account id),
  /// which gives up its assignments and own overrides. [remaining] is the
  /// MLS roster after the commit.
  GovernanceState removeAccount(
    String account, {
    required Set<String> remaining,
  }) {
    Map<String, ChannelOverride> withoutOwn(
      Map<String, ChannelOverride> from,
      String who,
    ) =>
        {
          for (final e in from.entries)
            if (e.value.targetIsRole || e.value.targetId != who) e.key: e.value,
        };
    final pruned = copyWith(
      assignments: {
        for (final e in assignments.entries)
          if (e.key != account) e.key: {...e.value},
      },
      overrides: withoutOwn(overrides, account),
    );
    if (account != owner) return pruned;
    final heirs = remaining.where((a) => a != account).toList();
    if (heirs.isEmpty) return pruned;
    heirs.sort((a, b) {
      final r = pruned.topRank(a).compareTo(pruned.topRank(b));
      return r != 0 ? r : a.compareTo(b);
    });
    final heir = heirs.first;
    return pruned.copyWith(
      owner: heir,
      assignments: {
        for (final e in pruned.assignments.entries)
          if (e.key != heir) e.key: e.value,
      },
      overrides: withoutOwn(pruned.overrides, heir),
    );
  }
}

/// Why [validateTransition] refused a record. Stable codes for logs and tests.
enum GovernanceReject {
  badRev,
  badShape,
  limits,
  ownerChange,
  notAllowed,
  hierarchy,
  grantsMore,
  unknownRole,
  notMember,
}

class GovernanceCheck {
  const GovernanceCheck.ok() : reject = null;
  const GovernanceCheck.no(GovernanceReject this.reject);
  final GovernanceReject? reject;
  bool get ok => reject == null;
}

/// Decides whether [actor], the MLS-authenticated sender of [next], may move
/// the group from [prev] to [next]. [members] are the accounts in the MLS
/// roster at the record's place in sync order, never the server's cached
/// roster, so every honest device with the same [prev] reaches the same
/// answer. Channel existence is server metadata that devices can see
/// differently, so it is not an input: an override for an unknown channel is
/// kept and has no effect.
GovernanceCheck validateTransition(
  GovernanceState prev,
  GovernanceState next,
  String actor, {
  required Set<String> members,
}) {
  GovernanceCheck no(GovernanceReject r) => GovernanceCheck.no(r);
  if (next.rev != prev.rev + 1) return no(GovernanceReject.badRev);

  // Shape and limits.
  final member = next.roles[memberRoleId];
  if (member == null || member.rank != memberRank) {
    return no(GovernanceReject.badShape);
  }
  if (next.roles.length > maxRoles || next.overrides.length > maxOverrides) {
    return no(GovernanceReject.limits);
  }
  final ranks = <int>{};
  for (final e in next.roles.entries) {
    final r = e.value;
    if (e.key != r.id || !_roleIdPattern.hasMatch(r.id)) {
      return no(GovernanceReject.badShape);
    }
    if (r.name.isEmpty || r.name.length > maxRoleNameUnits) {
      return no(GovernanceReject.badShape);
    }
    if (r.rank < 0 || r.rank > memberRank || !ranks.add(r.rank)) {
      return no(GovernanceReject.badShape);
    }
  }
  for (final e in next.assignments.entries) {
    if (e.key == next.owner || e.value.isEmpty) {
      return no(GovernanceReject.badShape);
    }
    if (!members.contains(e.key)) return no(GovernanceReject.notMember);
    for (final id in e.value) {
      if (id == memberRoleId) return no(GovernanceReject.badShape);
      if (!next.roles.containsKey(id)) return no(GovernanceReject.unknownRole);
    }
  }
  if (!members.contains(next.owner)) return no(GovernanceReject.notMember);
  for (final e in next.overrides.entries) {
    final o = e.value;
    if (e.key != o.key || o.channelId.isEmpty || o.targetId.isEmpty) {
      return no(GovernanceReject.badShape);
    }
    if (o.allow.intersection(o.deny).isNotEmpty) {
      return no(GovernanceReject.badShape);
    }
    final targetExists = o.targetIsRole
        ? next.roles.containsKey(o.targetId)
        : members.contains(o.targetId);
    if (!targetExists) return no(GovernanceReject.badShape);
  }

  final isOwner = actor == prev.owner;
  if (next.owner != prev.owner && !isOwner) {
    return no(GovernanceReject.ownerChange);
  }
  if (!members.contains(actor)) return no(GovernanceReject.notMember);
  final actorRank = prev.topRank(actor);
  final actorAdmin = prev.isAdmin(actor);

  bool holds(Set<String> perms, {String? channelId}) {
    if (actorAdmin) return true;
    final mine = prev.permissionsIn(actor, channelId: channelId);
    return perms.every(mine.contains);
  }

  // Role definitions.
  final changedRoleIds = [
    for (final id in {...prev.roles.keys, ...next.roles.keys})
      if (prev.roles[id] != next.roles[id]) id,
  ];
  if (changedRoleIds.isNotEmpty && !prev.can(actor, Perm.manageRoles)) {
    return no(GovernanceReject.notAllowed);
  }
  for (final id in changedRoleIds) {
    final a = prev.roles[id];
    final b = next.roles[id];
    if (a != null && a.rank <= actorRank) {
      return no(GovernanceReject.hierarchy);
    }
    if (b != null && b.rank <= actorRank) {
      return no(GovernanceReject.hierarchy);
    }
    final changed = {
      ...?a?.perms.difference(b?.perms ?? const {}),
      ...?b?.perms.difference(a?.perms ?? const {}),
    };
    if (!holds(changed)) return no(GovernanceReject.grantsMore);
  }

  // Assignments.
  for (final acct in {...prev.assignments.keys, ...next.assignments.keys}) {
    final a = prev.assignments[acct] ?? const <String>{};
    final b = next.assignments[acct] ?? const <String>{};
    if (_setEq(a, b)) continue;
    // Giving up your own roles needs no permission.
    if (acct == actor && b.difference(a).isEmpty && !isOwner) continue;
    if (!prev.can(actor, Perm.manageRoles)) {
      return no(GovernanceReject.notAllowed);
    }
    if (acct != actor && prev.topRank(acct) <= actorRank) {
      return no(GovernanceReject.hierarchy);
    }
    for (final id in {...a.difference(b), ...b.difference(a)}) {
      final r = next.roles[id] ?? prev.roles[id]!;
      if (r.rank <= actorRank) return no(GovernanceReject.hierarchy);
      if (!holds(r.perms)) return no(GovernanceReject.grantsMore);
    }
  }

  // Channel overrides.
  for (final key in {...prev.overrides.keys, ...next.overrides.keys}) {
    final a = prev.overrides[key];
    final b = next.overrides[key];
    if (a == b) continue;
    final o = (b ?? a)!;
    if (!prev.can(actor, Perm.manageChannels)) {
      return no(GovernanceReject.notAllowed);
    }
    if (o.targetIsRole) {
      final r = next.roles[o.targetId] ?? prev.roles[o.targetId];
      if (r == null || r.rank <= actorRank) {
        return no(GovernanceReject.hierarchy);
      }
    } else if (prev.topRank(o.targetId) <= actorRank) {
      // Includes the actor itself: an allow it writes for itself now would
      // outlive a later restriction of its roles.
      return no(GovernanceReject.hierarchy);
    }
    final touched = {...?a?.allow, ...?a?.deny, ...?b?.allow, ...?b?.deny};
    // Group-wide switches have no channel meaning. Unknown strings are kept
    // (a newer app may define them), so app versions do not disagree.
    if (touched.any(Perm.groupScoped.contains)) {
      return no(GovernanceReject.badShape);
    }
    if (!holds(touched, channelId: o.channelId)) {
      return no(GovernanceReject.grantsMore);
    }
  }

  // No escalation, measured on effective switches: every switch any member
  // gains, group-wide or in a channel, the actor already held there. This
  // catches what the per-entry checks cannot see, such as dropping one's own
  // role that carries a channel deny, or taking a role that carries a
  // channel allow. The actor itself can therefore never gain a switch.
  if (!actorAdmin) {
    final scopes = <String?>{
      null,
      for (final o in prev.overrides.values) o.channelId,
      for (final o in next.overrides.values) o.channelId,
    };
    for (final scope in scopes) {
      final mine = prev.permissionsIn(actor, channelId: scope);
      for (final m in members) {
        final gained = next
            .permissionsIn(m, channelId: scope)
            .difference(prev.permissionsIn(m, channelId: scope));
        if (!mine.containsAll(gained)) return no(GovernanceReject.grantsMore);
      }
    }
  }
  return const GovernanceCheck.ok();
}
