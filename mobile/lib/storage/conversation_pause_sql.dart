part of 'encrypted_database.dart';

/// The per-conversation pause table (schema 20, C1 prerequisite 1). Raw SQL
/// like the other later tables, so no generated code changes. See
/// [ConversationPause] for the model and
/// `docs/designs/C1-sync-isolation.md` for the design.
///
/// Every write runs in one transaction and, where it can change what a
/// device applies, first checks the sync lease like the MLS transitions do.
extension ConversationPauseSql on EncryptedLocalDatabase {
  Future<void> _createConversationPauses() async {
    await customStatement(
        'CREATE TABLE IF NOT EXISTS local_conversation_pauses ('
        'conversation_id TEXT PRIMARY KEY NOT NULL '
        'CHECK(length(conversation_id) BETWEEN 1 AND 128), '
        'resume_after INTEGER NOT NULL CHECK(resume_after >= 0), '
        'failed_event_id INTEGER NOT NULL CHECK(failed_event_id > 0), '
        'failed_event_type TEXT, failed_ref TEXT, '
        'kind TEXT NOT NULL, recorded_at INTEGER NOT NULL, '
        'generation INTEGER NOT NULL CHECK(generation >= 1))');
  }

  Future<void> _clearConversationPauses() =>
      customStatement('DELETE FROM local_conversation_pauses');

  ConversationPause _pauseFromRow(QueryRow row) {
    final kindName = row.read<String>('kind');
    final kind = SyncFailureKind.values
        .where((value) => value.name == kindName)
        .firstOrNull;
    final recordedMs = row.read<int>('recorded_at');
    return ConversationPause(
      conversationId: row.read<String>('conversation_id'),
      resumeAfter: row.read<int>('resume_after'),
      failedEventId: row.read<int>('failed_event_id'),
      failedEventType: row.read<String?>('failed_event_type'),
      failedRef: row.read<String?>('failed_ref'),
      // A kind this build does not know can only come from a newer build;
      // the pause stays (never lifted) and offers leaving only.
      kind: kind ?? SyncFailureKind.cursorExpired,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(recordedMs, isUtc: true),
      generation: row.read<int>('generation'),
    );
  }

  Future<ConversationPause?> _pauseRow(String conversationId) async {
    final row = await customSelect(
        'SELECT * FROM local_conversation_pauses WHERE conversation_id = ?',
        variables: [Variable.withString(conversationId)]).getSingleOrNull();
    return row == null ? null : _pauseFromRow(row);
  }

  Future<ConversationPause?> readConversationPause(String id) => _pauseRow(id);

  Future<List<ConversationPause>> readConversationPauses() async {
    final rows = await customSelect(
            'SELECT * FROM local_conversation_pauses ORDER BY conversation_id')
        .get();
    return rows.map(_pauseFromRow).toList(growable: false);
  }

  /// Records that [conversationId] failed at [failedEventId]. A new pause
  /// resumes after the event just below it: every earlier event of the
  /// conversation was applied in order. A conversation already paused keeps
  /// its [ConversationPause.resumeAfter] (a replay that gets further moved
  /// it) and gets the new failure with a higher generation; a failure at or
  /// below what was already replayed is refused.
  Future<ConversationPause> writeConversationPause({
    required String conversationId,
    required int failedEventId,
    required SyncFailureKind kind,
    String? failedEventType,
    String? failedRef,
    String? leaseKey,
    void Function()? checkCanCommit,
  }) =>
      transaction(() async {
        checkCanCommit?.call();
        await _assertSyncLeaseInTransaction(leaseKey);
        if (conversationId.isEmpty ||
            conversationId.length > maxPausedConversationIdLength ||
            failedEventId <= 0) {
          throw const FormatException('invalid conversation pause');
        }
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        final existing = await _pauseRow(conversationId);
        if (existing == null) {
          final count = await customSelect(
                  'SELECT COUNT(*) AS n FROM local_conversation_pauses')
              .getSingle();
          if (count.read<int>('n') >= maxConversationPauses) {
            throw const ConversationPauseLimitReached();
          }
          await customStatement(
              'INSERT INTO local_conversation_pauses (conversation_id, '
              'resume_after, failed_event_id, failed_event_type, failed_ref, '
              'kind, recorded_at, generation) VALUES (?, ?, ?, ?, ?, ?, ?, 1)',
              [
                conversationId,
                failedEventId - 1,
                failedEventId,
                failedEventType,
                failedRef,
                kind.name,
                now,
              ]);
        } else {
          if (failedEventId <= existing.resumeAfter) {
            throw StateError('pause failure is behind the replayed events');
          }
          await customStatement(
              'UPDATE local_conversation_pauses SET failed_event_id = ?, '
              'failed_event_type = ?, failed_ref = ?, kind = ?, '
              'recorded_at = ?, generation = generation + 1 '
              'WHERE conversation_id = ?',
              [
                failedEventId,
                failedEventType,
                failedRef,
                kind.name,
                now,
                conversationId,
              ]);
        }
        checkCanCommit?.call();
        return (await _pauseRow(conversationId))!;
      });

  /// Moves the global cursor past [eventId], an event of a paused
  /// conversation, without applying it: no processed marker, no state, no
  /// history. Fails unless the pause row exists in this same transaction, so
  /// an event can never be passed over without a durable record of it.
  Future<void> skipPausedConversationEvent({
    required String conversationId,
    required int eventId,
    required int expectedCursor,
    String? leaseKey,
    void Function()? checkCanCommit,
  }) =>
      transaction(() async {
        checkCanCommit?.call();
        await _assertSyncLeaseInTransaction(leaseKey);
        final pause = await _pauseRow(conversationId);
        if (pause == null) {
          throw StateError('conversation is not paused');
        }
        final previousCursor = await (select(localSyncStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        if ((previousCursor?.cursor ?? 0) != expectedCursor ||
            eventId <= expectedCursor ||
            eventId <= pause.resumeAfter) {
          throw StateError('stale paused sync event skip');
        }
        checkCanCommit?.call();
        await into(localSyncStates).insertOnConflictUpdate(
          LocalSyncStatesCompanion.insert(
              singleton: const Value(1), cursor: Value(eventId)),
        );
        checkCanCommit?.call();
      });

  /// Removes the pause of [conversationId]. With [generation] it removes the
  /// row only if that failure is still the recorded one. Returns whether a
  /// row was removed.
  Future<bool> clearConversationPause(
    String conversationId, {
    int? generation,
    String? leaseKey,
    void Function()? checkCanCommit,
  }) =>
      transaction(() async {
        checkCanCommit?.call();
        await _assertSyncLeaseInTransaction(leaseKey);
        final existing = await _pauseRow(conversationId);
        if (existing == null ||
            (generation != null && existing.generation != generation)) {
          return false;
        }
        await customStatement(
            'DELETE FROM local_conversation_pauses WHERE conversation_id = ?',
            [conversationId]);
        checkCanCommit?.call();
        return true;
      });

  /// Throws [ConversationSyncPausedException] if [conversationId] is paused.
  /// Called inside the transactions that write outgoing MLS or application
  /// state, so nothing is encrypted or staged for a paused conversation
  /// even if the pause landed after the caller checked.
  Future<void> _assertConversationNotPausedInTransaction(
      String conversationId) async {
    final pause = await _pauseRow(conversationId);
    if (pause != null) throw ConversationSyncPausedException(conversationId);
  }

  /// The check a transition that does not move the global cursor passes:
  /// [conversationId] must be paused, [eventId] must lie above what was
  /// replayed and at or below the global cursor [cursor] (a replay never
  /// reaches past what the global stream has already passed).
  Future<void> _assertReplayInTransaction(
      String conversationId, int eventId, int cursor) async {
    final pause = await _pauseRow(conversationId);
    if (pause == null || eventId <= pause.resumeAfter || eventId > cursor) {
      throw StateError('stale or incomplete MLS state transition');
    }
  }

  Future<void> _advancePauseResumeInTransaction(
      String conversationId, int eventId) {
    return customStatement(
        'UPDATE local_conversation_pauses SET resume_after = ? '
        'WHERE conversation_id = ? AND resume_after < ?',
        [eventId, conversationId, eventId]);
  }
}
