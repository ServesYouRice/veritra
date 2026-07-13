import 'dart:convert';

class Conversation {
  Conversation({
    required this.id,
    required this.kind,
    this.title,
    this.communityId,
    this.channelId,
    this.retentionSeconds,
    this.createdAt,
    this.lastMessageAt,
    this.unreadCount = 0,
  });

  final String id;
  final String kind;
  final String? title;
  final String? communityId;
  final String? channelId;
  final int? retentionSeconds;
  final DateTime? createdAt;
  // Populated by the conversation list endpoint so the chat list can order by
  // activity and show unread badges. Null/zero for freshly created or
  // single-conversation responses.
  final DateTime? lastMessageAt;
  final int unreadCount;

  bool get isDm => kind == 'dm';
  bool get isGroup => kind == 'group';
  bool get isChannel => kind == 'community_channel';

  /// Most recent activity for ordering/display: last message if known,
  /// otherwise creation time.
  DateTime? get lastActivityAt => lastMessageAt ?? createdAt;

  factory Conversation.fromJson(Map<String, Object?> json) {
    return Conversation(
      id: json['id'] as String,
      kind: json['kind'] as String,
      title: json['title'] as String?,
      communityId: json['community_id'] as String?,
      channelId: json['channel_id'] as String?,
      retentionSeconds: (json['retention_seconds'] as num?)?.toInt(),
      createdAt: _parseOptionalTime(json['created_at']),
      lastMessageAt: _parseOptionalTime(json['last_message_at']),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
    );
  }

  Conversation copyWith({int? unreadCount}) {
    return Conversation(
      id: id,
      kind: kind,
      title: title,
      communityId: communityId,
      channelId: channelId,
      retentionSeconds: retentionSeconds,
      createdAt: createdAt,
      lastMessageAt: lastMessageAt,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}

class Community {
  Community({required this.id, required this.name, this.createdAt});

  final String id;
  final String name;
  final DateTime? createdAt;

  factory Community.fromJson(Map<String, Object?> json) {
    return Community(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: _parseOptionalTime(json['created_at']),
    );
  }
}

class Channel {
  Channel({
    required this.id,
    required this.communityId,
    required this.name,
    required this.kind,
  });

  final String id;
  final String communityId;
  final String name;
  final String kind;

  factory Channel.fromJson(Map<String, Object?> json) {
    return Channel(
      id: json['id'] as String,
      communityId: json['community_id'] as String,
      name: json['name'] as String,
      kind: json['kind'] as String,
    );
  }
}

class Invite {
  Invite({
    required this.id,
    required this.code,
    required this.maxUses,
    required this.uses,
    this.expiresAt,
    this.createdAt,
  });

  final String id;
  final String code;
  final int maxUses;
  final int uses;
  final DateTime? expiresAt;
  final DateTime? createdAt;

  factory Invite.fromJson(Map<String, Object?> json) {
    return Invite(
      id: json['id'] as String,
      code: json['code'] as String,
      maxUses: (json['max_uses'] as num?)?.toInt() ?? 0,
      uses: (json['uses'] as num?)?.toInt() ?? 0,
      expiresAt: _parseOptionalTime(json['expires_at']),
      createdAt: _parseOptionalTime(json['created_at']),
    );
  }
}

class MessageEnvelope {
  MessageEnvelope({
    required this.conversationId,
    required this.idempotencyKey,
    required this.ciphertext,
    required this.cryptoProtocol,
    this.cryptoMetadata = const <String, Object?>{},
    this.attachmentRefs = const <Object?>[],
    this.replyToId,
    this.threadRootId,
  });

  final String conversationId;
  final String idempotencyKey;
  final List<int> ciphertext;
  final String cryptoProtocol;
  final Map<String, Object?> cryptoMetadata;
  final List<Object?> attachmentRefs;
  final String? replyToId;
  final String? threadRootId;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'conversation_id': conversationId,
      'idempotency_key': idempotencyKey,
      'ciphertext': base64Encode(ciphertext),
      'crypto_protocol': cryptoProtocol,
      'crypto_metadata': cryptoMetadata,
      'attachment_refs': attachmentRefs,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (threadRootId != null) 'thread_root_id': threadRootId,
    };
  }
}

class ReceivedMessageEnvelope {
  ReceivedMessageEnvelope({
    required this.id,
    required this.conversationId,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.idempotencyKey,
    required this.ciphertext,
    required this.cryptoProtocol,
    required this.createdAt,
    this.cryptoMetadata,
    this.attachmentRefs,
    this.replyToId,
    this.threadRootId,
    this.editedAt,
    this.deletedAt,
    this.expiresAt,
  });

  final String id;
  final String conversationId;
  final String senderAccountId;
  final String senderDeviceId;
  final String idempotencyKey;
  final List<int> ciphertext;
  final String cryptoProtocol;
  final Object? cryptoMetadata;
  final Object? attachmentRefs;
  final String? replyToId;
  final String? threadRootId;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final DateTime? expiresAt;

  factory ReceivedMessageEnvelope.fromJson(Map<String, Object?> json) {
    return ReceivedMessageEnvelope(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderAccountId: json['sender_account_id'] as String,
      senderDeviceId: json['sender_device_id'] as String,
      idempotencyKey: json['idempotency_key'] as String,
      ciphertext: _decodeBytes(json['ciphertext']),
      cryptoProtocol: json['crypto_protocol'] as String,
      cryptoMetadata: json['crypto_metadata'],
      attachmentRefs: json['attachment_refs'],
      replyToId: json['reply_to_id'] as String?,
      threadRootId: json['thread_root_id'] as String?,
      createdAt: _parseRequiredTime(json['created_at']),
      editedAt: _parseOptionalTime(json['edited_at']),
      deletedAt: _parseOptionalTime(json['deleted_at']),
      expiresAt: _parseOptionalTime(json['expires_at']),
    );
  }

  static List<int> _decodeBytes(Object? value) {
    if (value is String) {
      return base64Decode(value);
    }
    if (value is List) {
      return value.whereType<int>().toList();
    }
    return <int>[];
  }
}

class MetadataSearchResult {
  MetadataSearchResult({
    required this.type,
    required this.id,
    required this.label,
  });

  final String type;
  final String id;
  final String label;

  factory MetadataSearchResult.fromJson(Map<String, Object?> json) {
    return MetadataSearchResult(
      type: json['type'] as String,
      id: json['id'] as String,
      label: json['label'] as String,
    );
  }
}

class SyncEvent {
  SyncEvent({
    required this.id,
    required this.type,
    required this.createdAt,
    this.accountId,
    this.conversationId,
    this.payload,
  });

  final int id;
  final String type;
  final String? accountId;
  final String? conversationId;
  final Object? payload;
  final DateTime createdAt;

  factory SyncEvent.fromJson(Map<String, Object?> json) {
    return SyncEvent(
      id: (json['id'] as num).toInt(),
      type: json['type'] as String,
      accountId: json['account_id'] as String?,
      conversationId: json['conversation_id'] as String?,
      payload: json['payload'],
      createdAt: _parseRequiredTime(json['created_at']),
    );
  }
}

class DeviceLink {
  DeviceLink({
    required this.id,
    required this.state,
    required this.verificationCode,
    required this.expiresAt,
    this.code,
    this.linkUri,
    this.claimedDeviceName,
    this.approvedDeviceId,
  });

  final String id;
  final String state;
  final String verificationCode;
  final DateTime expiresAt;
  final String? code;
  final String? linkUri;
  final String? claimedDeviceName;
  final String? approvedDeviceId;

  factory DeviceLink.fromJson(Map<String, Object?> json) {
    return DeviceLink(
      id: json['id'] as String,
      state: json['state'] as String,
      verificationCode: json['verification_code'] as String,
      expiresAt: _parseRequiredTime(json['expires_at']),
      code: json['code'] as String?,
      linkUri: json['link_uri'] as String?,
      claimedDeviceName: json['claimed_device_name'] as String?,
      approvedDeviceId: json['approved_device_id'] as String?,
    );
  }
}

class DeviceLinkClaim {
  DeviceLinkClaim({required this.deviceLink, required this.claimToken});

  final DeviceLink deviceLink;
  final String claimToken;
}

class Device {
  Device({
    required this.id,
    required this.accountId,
    required this.name,
    required this.createdAt,
    this.lastSeenAt,
    this.revokedAt,
  });

  final String id;
  final String accountId;
  final String name;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;

  factory Device.fromJson(Map<String, Object?> json) {
    return Device(
      id: json['id'] as String,
      accountId: json['account_id'] as String,
      name: json['name'] as String,
      createdAt: _parseRequiredTime(json['created_at']),
      lastSeenAt: _parseOptionalTime(json['last_seen_at']),
      revokedAt: _parseOptionalTime(json['revoked_at']),
    );
  }
}

DateTime? _parseOptionalTime(Object? value) {
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}

/// Defensive parse for timestamps the models treat as required. One
/// malformed row from the server must not throw during model construction
/// and blank an entire list; fall back to the Unix epoch as an obviously
/// wrong sentinel instead.
DateTime _parseRequiredTime(Object? value) {
  if (value is String && value.isNotEmpty) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
  }
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

class Session {
  const Session({
    required this.baseUrl,
    required this.token,
    this.accountId,
    this.deviceId,
    this.username,
  });

  final String baseUrl;
  final String token;
  final String? accountId;
  final String? deviceId;
  final String? username;
}
