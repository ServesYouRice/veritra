/// What a membership invitation leads to: a group or a whole community.
enum InviteTargetKind {
  group('group'),
  community('community');

  const InviteTargetKind(this.wire);

  /// The server's `target_kind`.
  final String wire;

  static InviteTargetKind? fromWire(Object? value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// An invitation an owner or admin created (`GET .../invites`). The server
/// keeps no link and no secret, so this holds only the bookkeeping.
class MembershipInvite {
  const MembershipInvite({
    required this.id,
    required this.maxUses,
    required this.uses,
    required this.expiresAt,
  });

  final String id;
  final int maxUses;
  final int uses;
  final DateTime expiresAt;

  factory MembershipInvite.fromJson(Map<String, Object?> json) =>
      MembershipInvite(
        id: json['id']! as String,
        maxUses: json['max_uses']! as int,
        uses: (json['uses'] as int?) ?? 0,
        expiresAt: DateTime.parse(json['expires_at']! as String),
      );
}

/// What the holder of a link sees before asking to join. It names the target
/// and the inviter and no other member.
class InvitePreview {
  const InvitePreview({
    required this.kind,
    required this.targetName,
    required this.inviterUsername,
    required this.expiresAt,
    required this.alreadyMember,
  });

  final InviteTargetKind kind;

  /// Empty for a group without a title.
  final String targetName;
  final String inviterUsername;
  final DateTime expiresAt;
  final bool alreadyMember;

  factory InvitePreview.fromJson(Map<String, Object?> json) {
    final kind = InviteTargetKind.fromWire(json['target_kind']);
    if (kind == null) throw const FormatException('unknown target kind');
    return InvitePreview(
      kind: kind,
      targetName: (json['target_name'] as String?) ?? '',
      inviterUsername: (json['inviter_username'] as String?) ?? '',
      expiresAt: DateTime.parse(json['expires_at']! as String),
      alreadyMember: json['already_member'] == true,
    );
  }
}

/// How far a join request has got.
enum JoinRequestStatus {
  pending,
  approved,
  rejected,
  cancelled;

  static JoinRequestStatus? fromWire(Object? value) {
    for (final status in values) {
      if (status.name == value) return status;
    }
    return null;
  }
}

/// A request to join through an invitation. It grants nothing until an
/// owner or admin approves it. As an admin sees it, [accountId] and
/// [username] name the requester; as the requester sees it, [targetName]
/// names the target.
class JoinRequest {
  const JoinRequest({
    required this.id,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.targetId,
    this.targetName,
    this.accountId,
    this.username,
    this.decidedAt,
  });

  final String id;
  final InviteTargetKind kind;
  final JoinRequestStatus status;
  final DateTime createdAt;
  final String? targetId;
  final String? targetName;
  final String? accountId;
  final String? username;
  final DateTime? decidedAt;

  factory JoinRequest.fromJson(Map<String, Object?> json) {
    final kind = InviteTargetKind.fromWire(json['target_kind']);
    final status = JoinRequestStatus.fromWire(json['status']);
    if (kind == null || status == null) {
      throw const FormatException('unknown join request');
    }
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final decided = text('decided_at');
    return JoinRequest(
      id: json['id']! as String,
      kind: kind,
      status: status,
      createdAt: DateTime.parse(json['created_at']! as String),
      targetId: text('target_id'),
      targetName: text('target_name'),
      accountId: text('account_id'),
      username: text('username'),
      decidedAt: decided == null ? null : DateTime.parse(decided),
    );
  }
}

/// The result of leaving or removing someone from a community: the channel
/// conversations the account was taken out of, with the removed account's own
/// event id for each (the app dates a leave by it).
class CommunityRemoval {
  const CommunityRemoval(this.channels);

  final List<({String conversationId, int? eventId})> channels;

  factory CommunityRemoval.fromJson(Map<String, Object?> json) {
    final rows = json['channels'];
    final channels = <({String conversationId, int? eventId})>[];
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) throw const FormatException('bad channel row');
        final id = row['conversation_id'];
        final event = row['event_id'];
        if (id is! String || id.isEmpty) {
          throw const FormatException('bad channel row');
        }
        channels.add((
          conversationId: id,
          eventId: event is int && event > 0 ? event : null,
        ));
      }
    }
    return CommunityRemoval(channels);
  }
}
