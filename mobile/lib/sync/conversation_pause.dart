import 'sync_recovery.dart';

/// C1 prerequisite 1: one conversation's MLS failure pauses that
/// conversation, not the device.
///
/// A pause is a durable record that a conversation's events stop being
/// applied at one sync event. Sync then moves the global cursor past that
/// conversation's later crypto events without applying them (a cursor-only
/// move, no processed marker), so every other conversation keeps syncing.
/// Nothing is dropped: the conversation's own sync stream
/// (`GET /api/v1/conversations/{id}/sync-events`) still holds the events, and
/// an explicit retry replays them in order from [resumeAfter] up to the
/// global cursor, then removes the pause. No "skip this message" and no
/// automatic group reset exist (docs/designs/C1-sync-isolation.md).
///
/// The record holds no message content, key or ciphertext: ids, a failure
/// kind and a time.
class ConversationPause {
  const ConversationPause({
    required this.conversationId,
    required this.resumeAfter,
    required this.failedEventId,
    required this.kind,
    required this.recordedAt,
    this.generation = 1,
    this.failedEventType,
    this.failedRef,
  });

  /// The conversation whose events are held back.
  final String conversationId;

  /// The highest event of this conversation that was applied, or the event
  /// id just below the first failed one. A replay applies the events above
  /// it, in order, and moves it forward in the same transaction as each
  /// event's effects.
  final int resumeAfter;

  /// The event the conversation last failed at (always above [resumeAfter]).
  final int failedEventId;
  final String? failedEventType;

  /// The server id the failed event pointed at (an MLS message or message
  /// envelope id), so a replay can tell that the server now serves a
  /// different event under the same id. Not content.
  final String? failedRef;

  final SyncFailureKind kind;
  final DateTime recordedAt;

  /// Raised each time the failure is recorded again, so a late write for an
  /// older failure cannot clear or replace a newer one.
  final int generation;

  /// What a pause offers: a retry (replay), or leaving the conversation.
  /// Never a cursor jump.
  List<SyncRecoveryChoice> get choices {
    if (kind == SyncFailureKind.cursorExpired) {
      return const <SyncRecoveryChoice>[SyncRecoveryChoice.leaveConversation];
    }
    return const <SyncRecoveryChoice>[
      SyncRecoveryChoice.retry,
      SyncRecoveryChoice.leaveConversation,
    ];
  }

  /// Whether a replay may be tried again without the user changing anything.
  bool get retryable => choices.contains(SyncRecoveryChoice.retry);

  ConversationPause copyWith({
    int? resumeAfter,
    int? failedEventId,
    SyncFailureKind? kind,
    DateTime? recordedAt,
    int? generation,
    String? failedEventType,
    String? failedRef,
  }) =>
      ConversationPause(
        conversationId: conversationId,
        resumeAfter: resumeAfter ?? this.resumeAfter,
        failedEventId: failedEventId ?? this.failedEventId,
        kind: kind ?? this.kind,
        recordedAt: recordedAt ?? this.recordedAt,
        generation: generation ?? this.generation,
        failedEventType: failedEventType ?? this.failedEventType,
        failedRef: failedRef ?? this.failedRef,
      );

  @override
  String toString() {
    return 'ConversationPause(${kind.name}, event $failedEventId)';
  }
}

/// The most conversations paused at once. It follows the per-account
/// conversation limit (D38), so a hostile server cannot grow the table with
/// invented ids: past it, a further failure stops the device as before.
const int maxConversationPauses = 1000;

/// Thrown when pausing one more conversation would pass
/// [maxConversationPauses]. The caller stops the whole device instead.
class ConversationPauseLimitReached implements Exception {
  const ConversationPauseLimitReached();

  @override
  String toString() => 'too many paused conversations';
}

/// The longest conversation id a pause stores.
const int maxPausedConversationIdLength = 128;

/// Thrown when a conversation's MLS work is refused because it is paused.
/// Queued messages stay queued; nothing is discarded or sent around the
/// pause.
class ConversationSyncPausedException implements Exception {
  const ConversationSyncPausedException(this.conversationId);

  final String conversationId;

  @override
  String toString() => 'ConversationSyncPausedException';
}

/// Whether a failure at one event pauses only its conversation. Anything
/// that says the device itself cannot go on (storage, crypto unavailable,
/// an expired account cursor, a transient or auth failure) never does, and
/// neither does the D70 record limit, whose conversation may not be the
/// event's.
bool failurePausesConversation(SyncEventFailure failure) {
  final conversationId = failure.conversationId;
  if (failure.eventId == null ||
      conversationId == null ||
      conversationId.isEmpty ||
      conversationId.length > maxPausedConversationIdLength) {
    return false;
  }
  switch (failure.kind) {
    case SyncFailureKind.mlsControlMissing:
    case SyncFailureKind.mlsControlMalformed:
    case SyncFailureKind.mlsState:
    case SyncFailureKind.applicationUndecryptable:
    case SyncFailureKind.applicationMissing:
    case SyncFailureKind.unsupportedEvent:
      return true;
    case SyncFailureKind.transient:
    case SyncFailureKind.auth:
    case SyncFailureKind.cursorExpired:
    case SyncFailureKind.cryptoUnavailable:
    case SyncFailureKind.localStorage:
    case SyncFailureKind.recordLimit:
      return false;
  }
}
