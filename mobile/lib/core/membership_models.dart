import 'dart:convert';
import 'dart:typed_data';

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

/// What the creating device bound an invitation to (D90): the target, the
/// inviting account and device, and that device's signing key. [tag] is the
/// HMAC the creating app derived from the link secret over these fields and
/// the server's origin. The server cannot make or check it; the joiner
/// recomputes it from the link (`MembershipInviteLink.verifies`) and refuses
/// the invitation when it does not match.
class InviteBinding {
  const InviteBinding({
    required this.kind,
    required this.targetId,
    required this.inviterAccountId,
    required this.inviterDeviceId,
    required this.inviterSigningKey,
    required this.tag,
  });

  final InviteTargetKind kind;
  final String targetId;
  final String inviterAccountId;
  final String inviterDeviceId;
  final Uint8List inviterSigningKey;

  /// 64 lowercase hex characters.
  final String tag;

  factory InviteBinding.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('no invitation binding');
    final kind = InviteTargetKind.fromWire(json['target_kind']);
    final targetId = json['target_id'];
    final accountId = json['inviter_account_id'];
    final deviceId = json['inviter_device_id'];
    final key = json['inviter_signing_key'];
    final tag = json['tag'];
    if (kind == null ||
        targetId is! String ||
        targetId.isEmpty ||
        accountId is! String ||
        accountId.isEmpty ||
        deviceId is! String ||
        deviceId.isEmpty ||
        key is! String ||
        tag is! String) {
      throw const FormatException('bad invitation binding');
    }
    return InviteBinding(
      kind: kind,
      targetId: targetId,
      inviterAccountId: accountId,
      inviterDeviceId: deviceId,
      inviterSigningKey: Uint8List.fromList(base64.decode(key)),
      tag: tag,
    );
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
    required this.binding,
  });

  final InviteTargetKind kind;

  /// Empty for a group without a title.
  final String targetName;
  final String inviterUsername;
  final DateTime expiresAt;
  final bool alreadyMember;

  /// What the creating device bound the link to. Not trusted until
  /// `MembershipInviteLink.verifies` accepts it.
  final InviteBinding binding;

  factory InvitePreview.fromJson(Map<String, Object?> json) {
    final kind = InviteTargetKind.fromWire(json['target_kind']);
    if (kind == null) throw const FormatException('unknown target kind');
    return InvitePreview(
      kind: kind,
      targetName: (json['target_name'] as String?) ?? '',
      inviterUsername: (json['inviter_username'] as String?) ?? '',
      expiresAt: DateTime.parse(json['expires_at']! as String),
      alreadyMember: json['already_member'] == true,
      binding: InviteBinding.fromJson(json['binding']),
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
    this.binding,
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

  /// Only on the answer to a request to join: what the invitation it went
  /// through was bound to. Not trusted until
  /// `MembershipInviteLink.verifies` accepts it.
  final InviteBinding? binding;

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
      binding: json['binding'] == null
          ? null
          : InviteBinding.fromJson(json['binding']),
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

/// One ban in a community (C5).
class CommunityBan {
  const CommunityBan({
    required this.accountId,
    required this.username,
    required this.bannedBy,
    required this.createdAt,
  });

  final String accountId;
  final String? username;
  final String bannedBy;
  final DateTime createdAt;

  factory CommunityBan.fromJson(Map<String, Object?> json) {
    final username = json['username'];
    return CommunityBan(
      accountId: json['account_id']! as String,
      username: username is String && username.isNotEmpty ? username : null,
      bannedBy: json['banned_by']! as String,
      createdAt: DateTime.parse(json['created_at']! as String),
    );
  }
}

/// One audit row (C5): ids and an action kind, never a reason.
class ModerationEvent {
  const ModerationEvent({
    required this.id,
    required this.actor,
    required this.target,
    required this.channelId,
    required this.action,
    required this.createdAt,
  });

  final String id;
  final String actor;
  final String? target;
  final String? channelId;

  /// `kick`, `ban`, `unban`, `timeout`, `timeout_cleared`, `slow_mode`,
  /// `invites_paused` or `invites_resumed`.
  final String action;
  final DateTime createdAt;

  factory ModerationEvent.fromJson(Map<String, Object?> json) {
    String? optional(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return ModerationEvent(
      id: json['id']! as String,
      actor: json['actor_account_id']! as String,
      target: optional('target_account_id'),
      channelId: optional('channel_id'),
      action: json['action']! as String,
      createdAt: DateTime.parse(json['created_at']! as String),
    );
  }
}

/// What a moderation screen shows besides the lists: whether invitations are
/// paused and each channel's slow mode, in seconds (0 is off).
class ModerationState {
  const ModerationState({
    required this.invitesPausedUntil,
    required this.slowModeSeconds,
  });

  final DateTime? invitesPausedUntil;
  final Map<String, int> slowModeSeconds;

  factory ModerationState.fromJson(Map<String, Object?> json) {
    final paused = json['invites_paused_until'];
    final channels = json['channels'];
    return ModerationState(
      invitesPausedUntil: paused is String ? DateTime.parse(paused) : null,
      slowModeSeconds: <String, int>{
        if (channels is List)
          for (final row in channels)
            if (row is Map)
              row['channel_id']! as String: row['slow_mode_seconds']! as int,
      },
    );
  }
}
