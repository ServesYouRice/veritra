import 'dart:convert';

enum OutboxDeliveryState { sending, failed, retrying, terminal }

class EnrollmentReservation {
  const EnrollmentReservation({
    required this.id,
    required this.accountId,
    required this.deviceId,
    required this.challenge,
    this.protocolVersion,
    this.linkNonce,
    this.existingDeviceId,
    this.existingSigningKey,
  });

  final String id;
  final String accountId;
  final String deviceId;
  final List<int> challenge;
  final String? protocolVersion;
  final List<int>? linkNonce;
  final String? existingDeviceId;
  final List<int>? existingSigningKey;

  factory EnrollmentReservation.fromJson(Map<String, Object?> json) =>
      EnrollmentReservation(
        id: json['id'] as String,
        accountId: json['account_id'] as String,
        deviceId: json['device_id'] as String,
        challenge: _base64(json['challenge'] as String),
        protocolVersion: json['protocol_version'] as String?,
        linkNonce: _decodeOptionalBytes(json['link_nonce']),
        existingDeviceId: json['existing_device_id'] as String?,
        existingSigningKey: _decodeOptionalBytes(json['existing_signing_key']),
      );
}

/// base64 decode whose failure does not carry the input: the dart:convert
/// [FormatException] keeps the whole source string, which may be ciphertext.
List<int> _base64(String value) {
  try {
    return base64Decode(value);
  } on FormatException {
    throw const FormatException('invalid binary field');
  }
}

List<int>? _decodeOptionalBytes(Object? value) =>
    value is String && value.isNotEmpty ? _base64(value) : null;

class EnrollmentCredential {
  const EnrollmentCredential({
    required this.deviceKeyPackage,
    required this.signingKey,
    required this.challengeSignature,
  });

  final List<int> deviceKeyPackage;
  final List<int> signingKey;
  final List<int> challengeSignature;
}

class DeviceLinkVerification {
  const DeviceLinkVerification({
    required this.transcriptHash,
    required this.sas,
    required this.claimTag,
    required this.approvalTag,
  });

  final List<int> transcriptHash;
  final String sas;
  final List<int> claimTag;
  final List<int> approvalTag;
}

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
    this.currentRole,
    this.peerAccountId,
    this.peerUsername,
    this.createdBy,
    this.postingRestricted = false,
    this.existedOnServer = false,
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
  final String? currentRole;
  // Counterpart of a two-account DM, supplied by the conversation list so the
  // chat list can name the other person instead of every DM reading the same.
  // Server-authored display metadata, never a cryptographic identity claim.
  final String? peerAccountId;
  final String? peerUsername;
  // Account that started the conversation; decides whether a DM is a request.
  final String? createdBy;
  // C2: true when only owners and admins may post in this conversation.
  final bool postingRestricted;
  // Set only on the answer to creating a conversation: the server returned a
  // DM the pair already had (200, not 201; D67), so its MLS group may exist
  // and this device must not build another. Never stored or sent.
  final bool existedOnServer;

  bool get isDm => kind == 'dm';
  bool get isGroup => kind == 'group';
  bool get isChannel => kind == 'community_channel' || isCommunityShared;

  /// The one group of a community's open and announcement channels (C0). It
  /// has no channel of its own: each post names one.
  bool get isCommunityShared => kind == 'community_shared';

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
      currentRole: json['current_role'] as String?,
      peerAccountId: _nonEmpty(json['peer_account_id']),
      peerUsername: _nonEmpty(json['peer_username']),
      createdBy: _nonEmpty(json['created_by']),
      postingRestricted: json['posting_restricted'] == true,
    );
  }

  Conversation copyWith({int? unreadCount, bool? postingRestricted}) {
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
      currentRole: currentRole,
      peerAccountId: peerAccountId,
      peerUsername: peerUsername,
      createdBy: createdBy,
      postingRestricted: postingRestricted ?? this.postingRestricted,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind,
        if (title != null) 'title': title,
        if (communityId != null) 'community_id': communityId,
        if (channelId != null) 'channel_id': channelId,
        if (retentionSeconds != null) 'retention_seconds': retentionSeconds,
        if (createdAt != null)
          'created_at': createdAt!.toUtc().toIso8601String(),
        if (lastMessageAt != null)
          'last_message_at': lastMessageAt!.toUtc().toIso8601String(),
        if (unreadCount != 0) 'unread_count': unreadCount,
        if (currentRole != null) 'current_role': currentRole,
        if (peerAccountId != null) 'peer_account_id': peerAccountId,
        if (peerUsername != null) 'peer_username': peerUsername,
        if (createdBy != null) 'created_by': createdBy,
        if (postingRestricted) 'posting_restricted': true,
      };
}

/// A conversation member as returned by the scoped roster endpoint. This is
/// server-recorded membership, which is not the same thing as the MLS group
/// roster; the UI must never present it as cryptographic proof of who can
/// decrypt.
class ConversationMember {
  ConversationMember({
    required this.accountId,
    required this.role,
    this.username,
    this.joinedAt,
  });

  final String accountId;
  final String role;
  final String? username;
  final DateTime? joinedAt;

  factory ConversationMember.fromJson(Map<String, Object?> json) {
    return ConversationMember(
      accountId: json['account_id'] as String,
      role: (json['role'] as String?) ?? 'member',
      username: _nonEmpty(json['username']),
      joinedAt: _parseOptionalTime(json['created_at']),
    );
  }
}

/// An account the signed-in user has blocked.
class BlockedAccount {
  BlockedAccount({required this.accountId, this.username, this.createdAt});

  final String accountId;
  final String? username;
  final DateTime? createdAt;

  factory BlockedAccount.fromJson(Map<String, Object?> json) {
    return BlockedAccount(
      accountId: json['account_id'] as String,
      username: _nonEmpty(json['username']),
      createdAt: _parseOptionalTime(json['created_at']),
    );
  }
}

/// One backward page of message envelopes. [nextBefore] is the cursor for the
/// next older page, or null when the server has no more history to give.
class MessagePage {
  const MessagePage({required this.messages, this.nextBefore});

  final List<ReceivedMessageEnvelope> messages;
  final String? nextBefore;
}

class Community {
  Community({
    required this.id,
    required this.name,
    this.createdBy,
    this.createdAt,
    this.sharedConversationId,
  });

  final String id;

  /// Empty from a C3 server, which keeps IDs only; the name is the
  /// encrypted community record (`communityDisplayName`).
  final String name;
  final String? createdBy;
  final DateTime? createdAt;

  /// The shared group of a community with the C0 layout; null for a legacy
  /// community, whose channels each have a conversation of their own.
  final String? sharedConversationId;

  factory Community.fromJson(Map<String, Object?> json) {
    return Community(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? '',
      createdBy: json['created_by'] as String?,
      createdAt: _parseOptionalTime(json['created_at']),
      sharedConversationId: json['shared_conversation_id'] as String?,
    );
  }
}

class Channel {
  Channel({
    required this.id,
    required this.communityId,
    required this.name,
    required this.kind,
    this.conversationId,
    this.layoutGeneration,
  });

  final String id;
  final String communityId;

  /// Empty from a C3 server; the name is the encrypted channel record
  /// (`channelDisplayName`).
  final String name;

  /// `private` or `announcement` in a legacy community; `open`,
  /// `announcement` or `private` in one with the C0 layout.
  final String kind;

  /// The group this channel's posts go to, and the layout generation they
  /// must name. Both null for a legacy channel (the conversation is found
  /// through [Conversation.channelId]).
  final String? conversationId;
  final int? layoutGeneration;

  /// Whether posts to this channel are routed inside a group of their own
  /// (the community's shared group, or the channel's private group).
  bool get isRouted => conversationId != null && layoutGeneration != null;

  factory Channel.fromJson(Map<String, Object?> json) {
    return Channel(
      id: json['id'] as String,
      communityId: json['community_id'] as String,
      name: (json['name'] as String?) ?? '',
      kind: json['kind'] as String,
      conversationId: json['conversation_id'] as String?,
      layoutGeneration: (json['layout_generation'] as num?)?.toInt(),
    );
  }
}

class ChannelCreation {
  const ChannelCreation({required this.channel, required this.conversation});

  final Channel channel;
  final Conversation conversation;

  factory ChannelCreation.fromJson(Map<String, Object?> json) =>
      ChannelCreation(
        channel: Channel.fromJson(
          Map<String, Object?>.from(json['channel']! as Map),
        ),
        conversation: Conversation.fromJson(
          Map<String, Object?>.from(json['conversation']! as Map),
        ),
      );
}

/// How long a conversation stays muted (W6).
enum MuteDuration {
  off,
  eightHours,
  oneWeek,
  always;

  /// The length of a timed mute; null for [off] and [always].
  Duration? get length => switch (this) {
        MuteDuration.eightHours => const Duration(hours: 8),
        MuteDuration.oneWeek => const Duration(days: 7),
        _ => null,
      };
}

/// A conversation's push mute. [until] is null for a mute without an end.
class ConversationMute {
  const ConversationMute({required this.muted, this.until});

  final bool muted;
  final DateTime? until;

  factory ConversationMute.fromJson(Map<String, Object?> json) {
    final until = json['muted_until'];
    return ConversationMute(
      muted: json['muted'] == true,
      until: until is String ? DateTime.tryParse(until)?.toUtc() : null,
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
    this.frankCommit,
  });

  final String conversationId;
  final String idempotencyKey;
  final List<int> ciphertext;
  final String cryptoProtocol;
  final Map<String, Object?> cryptoMetadata;
  final List<Object?> attachmentRefs;
  final String? replyToId;
  final String? threadRootId;

  /// The C6 franking commitment (32 bytes), a top-level envelope field and
  /// never part of [cryptoMetadata]. Null for an unfranked message.
  final List<int>? frankCommit;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'conversation_id': conversationId,
      'idempotency_key': idempotencyKey,
      'ciphertext': base64Encode(ciphertext),
      'crypto_protocol': cryptoProtocol,
      'crypto_metadata': cryptoMetadata,
      if (frankCommit != null) 'frank_commit': base64Encode(frankCommit!),
      'attachment_refs': attachmentRefs,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (threadRootId != null) 'thread_root_id': threadRootId,
    };
  }

  factory MessageEnvelope.fromJson(Map<String, Object?> json) {
    return MessageEnvelope(
      conversationId: json['conversation_id'] as String,
      idempotencyKey: json['idempotency_key'] as String,
      ciphertext: ReceivedMessageEnvelope._decodeBytes(json['ciphertext']),
      cryptoProtocol: json['crypto_protocol'] as String,
      cryptoMetadata: Map<String, Object?>.from(
        (json['crypto_metadata'] as Map?) ?? const <String, Object?>{},
      ),
      attachmentRefs: (json['attachment_refs'] as List?)?.cast<Object?>() ??
          const <Object?>[],
      replyToId: json['reply_to_id'] as String?,
      threadRootId: json['thread_root_id'] as String?,
      frankCommit:
          ReceivedMessageEnvelope.frankCommitFromJson(json['frank_commit']),
    );
  }
}

class DeviceKeyPackage {
  DeviceKeyPackage({
    required this.id,
    required this.deviceId,
    required this.accountId,
    required this.keyPackage,
    required this.ciphersuite,
    required this.expiresAt,
  });

  final String id;
  final String deviceId;
  final String accountId;
  final List<int> keyPackage;
  final String ciphersuite;
  final DateTime expiresAt;

  factory DeviceKeyPackage.fromJson(Map<String, Object?> json) =>
      DeviceKeyPackage(
        id: json['id'] as String,
        deviceId: json['device_id'] as String,
        accountId: json['account_id'] as String? ?? '',
        keyPackage: _decodeModelBytes(json['key_package']),
        ciphersuite: json['ciphersuite'] as String,
        expiresAt: _parseStrictTime(json['expires_at']),
      );
}

class MlsMessage {
  MlsMessage({
    required this.id,
    required this.conversationId,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.kind,
    required this.payload,
    required this.idempotencyKey,
    required this.syncEventId,
    required this.createdAt,
    this.recipientDeviceId,
    this.revocationDeviceId,
  });

  final String id;
  final String conversationId;
  final String senderAccountId;
  final String senderDeviceId;
  final String? recipientDeviceId;
  final String? revocationDeviceId;
  final String kind;
  final List<int> payload;
  final String idempotencyKey;
  final int syncEventId;
  final DateTime createdAt;

  factory MlsMessage.fromJson(Map<String, Object?> json) => MlsMessage(
        id: json['id'] as String,
        conversationId: json['conversation_id'] as String,
        senderAccountId: json['sender_account_id'] as String,
        senderDeviceId: json['sender_device_id'] as String,
        recipientDeviceId: json['recipient_device_id'] as String?,
        revocationDeviceId: json['revocation_device_id'] as String?,
        kind: json['kind'] as String,
        payload: _decodeModelBytes(json['payload']),
        idempotencyKey: json['idempotency_key'] as String,
        syncEventId: (json['sync_event_id'] as num).toInt(),
        createdAt: _parseStrictTime(json['created_at']),
      );
}

class MlsRevocation {
  MlsRevocation({
    required this.conversationId,
    required this.revokedDeviceId,
    required this.revokedAccountId,
    required this.coordinatorDeviceId,
    required this.state,
    required this.requestedAt,
    this.commitMessageId,
    this.completedAt,
  });

  final String conversationId;
  final String revokedDeviceId;
  final String revokedAccountId;
  final String coordinatorDeviceId;
  final String state;
  final String? commitMessageId;
  final DateTime requestedAt;
  final DateTime? completedAt;

  factory MlsRevocation.fromJson(Map<String, Object?> json) => MlsRevocation(
        conversationId: json['conversation_id'] as String,
        revokedDeviceId: json['revoked_device_id'] as String,
        revokedAccountId: json['revoked_account_id'] as String,
        coordinatorDeviceId: json['coordinator_device_id'] as String,
        state: json['state'] as String,
        commitMessageId: json['commit_message_id'] as String?,
        requestedAt: _parseStrictTime(json['requested_at']),
        completedAt: _parseStrictOptionalTime(json['completed_at']),
      );
}

class AttachmentEnvelope {
  AttachmentEnvelope({
    required this.id,
    required this.ownerAccountId,
    required this.storageKey,
    required this.ciphertextSha256,
    required this.sizeBytes,
    required this.createdAt,
    this.conversationId,
    this.cryptoMetadata,
  });

  final String id;
  final String ownerAccountId;
  final String? conversationId;
  final String storageKey;
  final String ciphertextSha256;
  final int sizeBytes;
  final Object? cryptoMetadata;
  final DateTime createdAt;

  factory AttachmentEnvelope.fromJson(Map<String, Object?> json) =>
      AttachmentEnvelope(
        id: json['id'] as String,
        ownerAccountId: json['owner_account_id'] as String,
        conversationId: json['conversation_id'] as String?,
        storageKey: json['storage_key'] as String,
        ciphertextSha256: json['ciphertext_sha256'] as String,
        sizeBytes: (json['size_bytes'] as num).toInt(),
        cryptoMetadata: json['crypto_metadata'],
        createdAt: _parseStrictTime(json['created_at']),
      );
}

class CallSession {
  CallSession({
    required this.id,
    required this.conversationId,
    required this.createdBy,
    required this.invitedAccountId,
    required this.state,
    required this.version,
    required this.metadata,
    required this.createdAt,
    this.endedAt,
    this.expiresAt,
  });

  final String id;
  final String conversationId;
  final String createdBy;
  final String invitedAccountId;
  final String state;
  final int version;
  final Map<String, Object?> metadata;
  final DateTime createdAt;
  final DateTime? endedAt;
  final DateTime? expiresAt;

  factory CallSession.fromJson(Map<String, Object?> json) => CallSession(
        id: json['id'] as String,
        conversationId: json['conversation_id'] as String,
        createdBy: json['created_by'] as String,
        invitedAccountId: json['invited_account_id'] as String,
        state: json['state'] as String,
        // Required: `version` is the optimistic-concurrency token for call
        // transitions. Defaulting it would turn a contract break into silent
        // stale-write rejections at signalling time.
        version: (json['version'] as num).toInt(),
        metadata:
            Map<String, Object?>.from(json['metadata'] as Map? ?? const {}),
        createdAt: _parseStrictTime(json['created_at']),
        endedAt: _parseStrictOptionalTime(json['ended_at']),
        expiresAt: _parseStrictOptionalTime(json['expires_at']),
      );
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
    this.frankCommit,
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

  /// The server's copy of the sender's franking commitment (C6), or null
  /// when the server holds none. Untrusted until a franked payload's own
  /// commitment is recomputed against it.
  final List<int>? frankCommit;

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
      frankCommit: frankCommitFromJson(json['frank_commit']),
    );
  }

  /// Reads a `frank_commit` field leniently: the server is not trusted, and
  /// a bad value must not stop sync. Anything that is not standard base64
  /// reads as absent, which a franked payload then refuses.
  static List<int>? frankCommitFromJson(Object? value) {
    if (value is! String || value.isEmpty) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'conversation_id': conversationId,
        'sender_account_id': senderAccountId,
        'sender_device_id': senderDeviceId,
        'idempotency_key': idempotencyKey,
        'ciphertext': base64Encode(ciphertext),
        'crypto_protocol': cryptoProtocol,
        if (cryptoMetadata != null) 'crypto_metadata': cryptoMetadata,
        if (frankCommit != null) 'frank_commit': base64Encode(frankCommit!),
        if (attachmentRefs != null) 'attachment_refs': attachmentRefs,
        if (replyToId != null) 'reply_to_id': replyToId,
        if (threadRootId != null) 'thread_root_id': threadRootId,
        'created_at': createdAt.toUtc().toIso8601String(),
        if (editedAt != null) 'edited_at': editedAt!.toUtc().toIso8601String(),
        if (deletedAt != null)
          'deleted_at': deletedAt!.toUtc().toIso8601String(),
        if (expiresAt != null)
          'expires_at': expiresAt!.toUtc().toIso8601String(),
      };

  static List<int> _decodeBytes(Object? value) {
    if (value is String) {
      return _base64(value);
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
    this.accountId,
    this.createdByDeviceId,
    this.protocolVersion,
    this.linkNonce,
    this.existingSigningKey,
    this.claimedDeviceId,
    this.claimedSigningKey,
    this.transcriptHash,
    this.claimTag,
    this.approvalTag,
  });

  final String id;
  final String state;
  final String verificationCode;
  final DateTime expiresAt;
  final String? code;
  final String? linkUri;
  final String? claimedDeviceName;
  final String? approvedDeviceId;
  final String? accountId;
  final String? createdByDeviceId;
  final String? protocolVersion;
  final List<int>? linkNonce;
  final List<int>? existingSigningKey;
  final String? claimedDeviceId;
  final List<int>? claimedSigningKey;
  final List<int>? transcriptHash;
  final List<int>? claimTag;
  final List<int>? approvalTag;

  factory DeviceLink.fromJson(Map<String, Object?> json) {
    return DeviceLink(
      id: json['id'] as String,
      state: json['state'] as String,
      // The server never supplies a code; it is derived locally from the
      // verified transcript, so any server-sent value is ignored.
      verificationCode: '',
      expiresAt: _parseRequiredTime(json['expires_at']),
      code: json['code'] as String?,
      linkUri: json['link_uri'] as String?,
      claimedDeviceName: json['claimed_device_name'] as String?,
      approvedDeviceId: json['approved_device_id'] as String?,
      accountId: json['account_id'] as String?,
      createdByDeviceId: json['created_by_device_id'] as String?,
      protocolVersion: json['protocol_version'] as String?,
      linkNonce: _decodeOptionalBytes(json['link_nonce']),
      existingSigningKey: _decodeOptionalBytes(json['existing_signing_key']),
      claimedDeviceId: json['claimed_device_id'] as String?,
      claimedSigningKey: _decodeOptionalBytes(json['claimed_signing_key']),
      transcriptHash: _decodeOptionalBytes(json['transcript_hash']),
      claimTag: _decodeOptionalBytes(json['claim_tag']),
      approvalTag: _decodeOptionalBytes(json['approval_tag']),
    );
  }
}

class DeviceLinkClaim {
  DeviceLinkClaim({
    required this.serverOrigin,
    required this.deviceLink,
    required this.claimToken,
    required this.deviceSecret,
  });

  final String serverOrigin;
  final DeviceLink deviceLink;
  final String claimToken;
  final String deviceSecret;
}

class Device {
  Device({
    required this.id,
    required this.accountId,
    required this.name,
    required this.createdAt,
    this.lastSeenAt,
    this.revokedAt,
    this.signingKey,
  });

  final String id;
  final String accountId;
  final String name;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;

  /// The device's MLS signing key as the server holds it (32 bytes), for
  /// the user's review in a migration genesis (L1); null when absent.
  final List<int>? signingKey;

  factory Device.fromJson(Map<String, Object?> json) {
    final key = json['signing_key'];
    List<int>? signingKey;
    if (key is String && key.isNotEmpty) {
      try {
        final decoded = base64Decode(key);
        if (decoded.length == 32) signingKey = decoded;
      } on FormatException {
        signingKey = null;
      }
    }
    return Device(
      id: json['id'] as String,
      accountId: json['account_id'] as String,
      name: json['name'] as String,
      createdAt: _parseRequiredTime(json['created_at']),
      lastSeenAt: _parseOptionalTime(json['last_seen_at']),
      revokedAt: _parseOptionalTime(json['revoked_at']),
      signingKey: signingKey,
    );
  }
}

/// Treats an absent, non-string, or empty JSON value as null. The server
/// omits optional display fields, but a defensive empty string must not
/// become a blank username in the UI.
String? _nonEmpty(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

/// Longest timestamp text accepted; RFC 3339 with nanoseconds and an offset
/// fits in 35 characters.
const int _maxTimestampLength = 40;

/// Parses a server timestamp into UTC, or null when it is absent, not a
/// string, too long, or outside years 1970-9999 (card T44A).
DateTime? _boundedTime(Object? value) {
  if (value is! String || value.isEmpty || value.length > _maxTimestampLength) {
    return null;
  }
  final parsed = DateTime.tryParse(value)?.toUtc();
  if (parsed == null || parsed.year < 1970 || parsed.year > 9999) {
    return null;
  }
  return parsed;
}

DateTime? _parseOptionalTime(Object? value) => _boundedTime(value);

/// A timestamp the protocol requires; a missing or malformed one fails the
/// row with a [FormatException] that does not echo the value.
DateTime _parseStrictTime(Object? value) =>
    _boundedTime(value) ?? (throw const FormatException('invalid timestamp'));

/// Optional, but when present it must be valid.
DateTime? _parseStrictOptionalTime(Object? value) =>
    value == null ? null : _parseStrictTime(value);

List<int> _decodeModelBytes(Object? value) {
  if (value is String) return _base64(value);
  if (value is List) return value.whereType<int>().toList(growable: false);
  throw const FormatException('invalid binary field');
}

/// Defensive parse for timestamps the models treat as required. One
/// malformed row from the server must not throw during model construction
/// and blank an entire list; fall back to the Unix epoch as an obviously
/// wrong sentinel instead.
DateTime _parseRequiredTime(Object? value) =>
    _boundedTime(value) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

class Session {
  const Session({
    required this.baseUrl,
    required this.token,
    this.accountId,
    this.deviceId,
    this.username,
    this.deviceSecret,
    this.role,
  });

  final String baseUrl;
  final String token;
  final String? accountId;
  final String? deviceId;
  final String? username;
  final String? deviceSecret;
  final String? role;
}

/// What one other member's delivery and read cursors cover in a conversation
/// (W5). Each time is the `created_at` of the newest message the cursor
/// reaches, so a message is covered when its own time is not later. Null means
/// no such cursor, or, for [readThrough], that the member keeps read receipts
/// off.
class MemberReceipt {
  MemberReceipt({
    required this.accountId,
    this.memberSince,
    this.deliveredThrough,
    this.readThrough,
  });

  final String accountId;

  /// When the member joined. Messages sent before it were not theirs to
  /// receive, so a tick ignores the member for them.
  final DateTime? memberSince;
  final DateTime? deliveredThrough;
  final DateTime? readThrough;

  factory MemberReceipt.fromJson(Map<String, Object?> json) {
    return MemberReceipt(
      accountId: json['account_id'] as String,
      memberSince: _parseStrictOptionalTime(json['member_since']),
      deliveredThrough: _parseStrictOptionalTime(json['delivered_through']),
      readThrough: _parseStrictOptionalTime(json['read_through']),
    );
  }
}
