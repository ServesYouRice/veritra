import 'dart:convert';

/// Why one sync event could not be applied (card I33).
///
/// Only [transient] and [auth] are retried automatically. Every other kind
/// stops sync without moving the cursor and is kept as a durable
/// [SyncRecovery], so a bad event is never retried in a loop and never
/// skipped.
enum SyncFailureKind {
  /// Network, timeout or a retryable server status. Sync retries later.
  transient,

  /// The session token was rejected. Handled as a sign-out.
  auth,

  /// An MLS control event names a message the server no longer returns.
  mlsControlMissing,

  /// An MLS control event or its message is not well formed.
  mlsControlMalformed,

  /// The local MLS state rejected a control message or could not be saved.
  mlsState,

  /// An application message that has not expired could not be decrypted.
  applicationUndecryptable,

  /// An application event names an envelope the server no longer returns,
  /// and nothing proves that it expired.
  applicationMissing,

  /// This app version does not know the event type.
  unsupportedEvent,

  /// The server no longer keeps events after this device's cursor.
  cursorExpired,

  /// This build has no MLS service, so it cannot apply MLS events.
  cryptoUnavailable,
}

/// A typed failure raised while applying one sync event.
class SyncEventFailure implements Exception {
  const SyncEventFailure(
    this.kind, {
    this.eventId,
    this.eventType,
    this.conversationId,
  });

  final SyncFailureKind kind;
  final int? eventId;
  final String? eventType;
  final String? conversationId;

  @override
  String toString() => 'SyncEventFailure(${kind.name}, event $eventId)';
}

/// How the user can get a device out of [SyncRecovery].
enum SyncRecoveryChoice {
  /// Apply the stopped event once more. Offered only when the cause may be
  /// local and passing, such as a storage error.
  retry,

  /// Sign this device out, keep nothing, and link it again from another
  /// device.
  relink,

  /// Restore an encrypted backup taken before the failure.
  restoreBackup,
}

/// The durable record of a device that stopped syncing (card I33).
///
/// It holds no message content, key or server secret: only the failure kind,
/// the sync event it stopped at, and when.
class SyncRecovery {
  const SyncRecovery({
    required this.kind,
    required this.recordedAt,
    this.eventId,
    this.eventType,
    this.conversationId,
  });

  factory SyncRecovery.fromFailure(SyncEventFailure failure, DateTime now) =>
      SyncRecovery(
        kind: failure.kind,
        recordedAt: now.toUtc(),
        eventId: failure.eventId,
        eventType: failure.eventType,
        conversationId: failure.conversationId,
      );

  final SyncFailureKind kind;
  final DateTime recordedAt;
  final int? eventId;
  final String? eventType;
  final String? conversationId;

  /// What the recovery screen offers. A cursor jump is never one of them.
  List<SyncRecoveryChoice> get choices {
    switch (kind) {
      case SyncFailureKind.mlsState:
      case SyncFailureKind.unsupportedEvent:
      case SyncFailureKind.cryptoUnavailable:
        return const <SyncRecoveryChoice>[
          SyncRecoveryChoice.retry,
          SyncRecoveryChoice.restoreBackup,
          SyncRecoveryChoice.relink,
        ];
      case SyncFailureKind.cursorExpired:
        return const <SyncRecoveryChoice>[
          SyncRecoveryChoice.restoreBackup,
          SyncRecoveryChoice.relink,
        ];
      case SyncFailureKind.transient:
      case SyncFailureKind.auth:
      case SyncFailureKind.mlsControlMissing:
      case SyncFailureKind.mlsControlMalformed:
      case SyncFailureKind.applicationUndecryptable:
      case SyncFailureKind.applicationMissing:
        return const <SyncRecoveryChoice>[
          SyncRecoveryChoice.retry,
          SyncRecoveryChoice.relink,
        ];
    }
  }

  /// A short, content-free explanation for the recovery banner.
  String get message {
    switch (kind) {
      case SyncFailureKind.cursorExpired:
        return 'This device was away longer than the server keeps updates. '
            'Restore a backup or link this device again.';
      case SyncFailureKind.mlsControlMissing:
      case SyncFailureKind.mlsControlMalformed:
        return 'An encryption update for a conversation is missing or '
            'damaged. Messages are paused so none are skipped.';
      case SyncFailureKind.mlsState:
        return 'This device could not update its encryption state. Messages '
            'are paused so none are skipped.';
      case SyncFailureKind.applicationUndecryptable:
      case SyncFailureKind.applicationMissing:
        return 'A message could not be read on this device. Messages are '
            'paused so none are skipped.';
      case SyncFailureKind.unsupportedEvent:
        return 'The server sent an update this app version does not know. '
            'Update the app, then try again.';
      case SyncFailureKind.cryptoUnavailable:
        return 'Encryption is unavailable in this build, so encrypted '
            'updates cannot be applied.';
      case SyncFailureKind.transient:
      case SyncFailureKind.auth:
        return 'Sync stopped. Try again.';
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'recorded_at': recordedAt.toUtc().toIso8601String(),
        if (eventId != null) 'event_id': eventId,
        if (eventType != null) 'event_type': eventType,
        if (conversationId != null) 'conversation_id': conversationId,
      };

  String encode() => jsonEncode(toJson());

  /// Returns null for anything that is not a well-formed record, so a
  /// damaged value can only lead to one more sync attempt, which records it
  /// again if the cause remains.
  static SyncRecovery? decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final json = jsonDecode(encoded);
      if (json is! Map) return null;
      final kindName = json['kind'];
      final kind = SyncFailureKind.values
          .where((value) => value.name == kindName)
          .firstOrNull;
      final recordedAt = DateTime.tryParse('${json['recorded_at']}');
      if (kind == null || recordedAt == null) return null;
      final eventId = json['event_id'];
      final eventType = json['event_type'];
      final conversationId = json['conversation_id'];
      return SyncRecovery(
        kind: kind,
        recordedAt: recordedAt.toUtc(),
        eventId: eventId is int ? eventId : null,
        eventType: eventType is String ? eventType : null,
        conversationId: conversationId is String ? conversationId : null,
      );
    } on FormatException {
      return null;
    }
  }
}
