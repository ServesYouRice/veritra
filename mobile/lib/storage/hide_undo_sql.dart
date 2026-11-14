part of 'encrypted_database.dart';

// Local schema 44 (U16, D133): "Delete for me" with Undo.
//
// A hide scrubs the row at once, exactly as before: `hidden_at` is set, the
// body, format and reply go (so the search index drops the text through its
// trigger), and the reactions, pins and stars go. Every reader (the chat, the
// chat-list preview, search, notices, quotes, pins, backups and transfers)
// therefore sees the final tombstone from the first instant.
//
// What the scrub removed is kept aside in `local_hide_undo`, one row per
// hidden message, until the Undo window closes. Undo puts it back; the end of
// the window, any change that names the message (an edit, a delete for
// everyone, a reaction, a vote, a pin) and the next start of the app delete
// it for good. The row references the message, so an expiry purge (W2) or
// any other delete of the message takes it too.
//
// The C6 reveal of a hidden message stays while its row is kept aside, so an
// undone message can still be reported; it is never read while the message
// is hidden ([readFrankReveal]), and it goes when the hide is final.
//
// The table holds message text before encryption, so it lives only in this
// database, goes into no backup, snapshot or transfer, and is emptied on
// every start.

extension HideUndoSql on EncryptedLocalDatabase {
  /// The table schema 44 adds (for fixtures that build older databases).
  static const tables = ['local_hide_undo'];

  /// Creates the table and replaces the reveal tombstone trigger of schema 19
  /// with one that keeps a reveal while its message's hide can be undone.
  /// Idempotent, and after the schema 19 step, so it can be renumbered.
  Future<void> _createHideUndo() async {
    await customStatement('CREATE TABLE IF NOT EXISTS local_hide_undo ('
        'message_key TEXT PRIMARY KEY NOT NULL '
        'REFERENCES local_messages(key) ON DELETE CASCADE, '
        'hidden_at INTEGER NOT NULL, '
        'body TEXT, format_json TEXT, reply_to TEXT, '
        'extras_json TEXT NOT NULL)');
    await customStatement(
        'DROP TRIGGER IF EXISTS local_frank_reveals_tombstone');
    await customStatement('CREATE TRIGGER local_frank_reveals_tombstone '
        'AFTER UPDATE OF deleted_at, hidden_at ON local_messages '
        'WHEN NEW.deleted_at IS NOT NULL OR (NEW.hidden_at IS NOT NULL '
        'AND NOT EXISTS (SELECT 1 FROM local_hide_undo '
        'WHERE message_key = NEW.key)) '
        'BEGIN DELETE FROM local_frank_reveals WHERE message_key = NEW.key; END');
  }

  /// Whether the schema 44 table exists (a store another branch numbered
  /// past 44 without it gets it on open).
  Future<bool> _hasHideUndo() async =>
      (await customSelect("SELECT 1 FROM sqlite_master WHERE type = 'table' "
              "AND name = 'local_hide_undo'")
          .getSingleOrNull()) !=
      null;

  /// Hides [key] from every view and keeps what the hide removed aside, in
  /// one transaction. Returns false, changing nothing, when the row is not
  /// in [conversationId] or is hidden already.
  Future<bool> hideMessage(String conversationId, String key, int at) =>
      transaction(() async {
        final row = await (select(localMessages)
              ..where((t) =>
                  t.key.equals(key) & t.conversationId.equals(conversationId)))
            .getSingleOrNull();
        if (row == null || row.hiddenAt != null) return false;
        final reactions = await (select(localMessageReactions)
              ..where((t) => t.targetKey.equals(key)))
            .get();
        final pins = await (select(localPins)
              ..where((t) => t.targetKey.equals(key)))
            .get();
        final pendingPins = await (select(localPendingPins)
              ..where((t) => t.targetKey.equals(key)))
            .get();
        final starred = await (select(localStarred)
              ..where((t) => t.messageKey.equals(key)))
            .getSingleOrNull();
        // First, so the tombstone trigger below sees it and keeps the reveal.
        await customStatement(
            'INSERT OR IGNORE INTO local_hide_undo (message_key, hidden_at, '
            'body, format_json, reply_to, extras_json) VALUES (?, ?, ?, ?, ?, ?)',
            <Object?>[
              key,
              at,
              row.body,
              row.formatJson,
              row.replyTo,
              jsonEncode({
                'reactions': [for (final r in reactions) r.toJson()],
                'pins': [for (final p in pins) p.toJson()],
                'pending_pins': [for (final p in pendingPins) p.toJson()],
                'starred_at': starred?.starredAt,
              }),
            ]);
        await (update(localMessages)..where((t) => t.key.equals(key))).write(
            LocalMessagesCompanion(
                hiddenAt: Value(at),
                body: const Value(null),
                formatJson: const Value(null),
                replyTo: const Value(null)));
        await (delete(localMessageReactions)
              ..where((t) => t.targetKey.equals(key)))
            .go();
        await _removeMessageExtras(key);
        return true;
      });

  /// Undoes the hide of [key]: the row, its reactions, pins and star come
  /// back as they were. Returns false, and makes the hide final, when there
  /// is nothing to restore: the hide was already final, the message has
  /// expired since, or it is deleted for everyone (a tombstone has no text
  /// to bring back). A change during the window already made it final
  /// ([_finishHideNamedBy]).
  Future<bool> unhideMessage(String key, int nowMs) => transaction(() async {
        final kept = await customSelect(
            'SELECT body, format_json, reply_to, extras_json '
            'FROM local_hide_undo WHERE message_key = ?',
            variables: [Variable.withString(key)]).getSingleOrNull();
        if (kept == null) return false;
        final row = await (select(localMessages)
              ..where((t) => t.key.equals(key)))
            .getSingleOrNull();
        if (row == null ||
            row.hiddenAt == null ||
            row.deletedAt != null ||
            (row.expiresAt != null && row.expiresAt! <= nowMs)) {
          await _finishHidesInTransaction([key]);
          return false;
        }
        await customStatement(
            'DELETE FROM local_hide_undo WHERE message_key = ?', [key]);
        await (update(localMessages)..where((t) => t.key.equals(key))).write(
            LocalMessagesCompanion(
                hiddenAt: const Value(null),
                body: Value(kept.readNullable<String>('body')),
                formatJson: Value(kept.readNullable<String>('format_json')),
                replyTo: Value(kept.readNullable<String>('reply_to'))));
        final extras = jsonDecode(kept.read<String>('extras_json')) as Map;
        for (final r in extras['reactions'] as List) {
          await into(localMessageReactions).insert(
              LocalMessageReaction.fromJson(
                  Map<String, dynamic>.from(r as Map)),
              mode: InsertMode.insertOrIgnore);
        }
        for (final p in extras['pins'] as List) {
          final pin = LocalPin.fromJson(Map<String, dynamic>.from(p as Map));
          if (pin.expiresAt <= nowMs) continue;
          await into(localPins).insert(pin, mode: InsertMode.insertOrIgnore);
          // Pins made during the window may have filled the chat.
          await _trimPins(pin.conversationId, pin.channelId);
        }
        for (final p in extras['pending_pins'] as List) {
          await into(localPendingPins).insert(
              LocalPendingPin.fromJson(Map<String, dynamic>.from(p as Map)),
              mode: InsertMode.insertOrIgnore);
        }
        final starredAt = extras['starred_at'] as int?;
        if (starredAt != null) {
          await into(localStarred).insert(
              LocalStarredCompanion.insert(
                  messageKey: key, starredAt: starredAt),
              mode: InsertMode.insertOrIgnore);
        }
        return true;
      });

  /// Makes hides final: what they kept aside is deleted, with the reveal of
  /// each message that is still hidden. [only] limits it to those messages;
  /// [except] leaves those (an Undo window still open) as they are.
  Future<void> finishHides(
          {Set<String>? only, Set<String> except = const <String>{}}) =>
      transaction(() async {
        final keys = only?.toList() ??
            [
              for (final row in await customSelect(
                      'SELECT message_key FROM local_hide_undo')
                  .get())
                row.read<String>('message_key'),
            ];
        await _finishHidesInTransaction([
          for (final key in keys)
            if (!except.contains(key)) key
        ]);
      });

  Future<void> _finishHidesInTransaction(List<String> keys) async {
    for (final chunk in EncryptedLocalDatabase._chunks(keys)) {
      final marks = List.filled(chunk.length, '?').join(', ');
      await customStatement(
          'DELETE FROM local_frank_reveals WHERE message_key IN ($marks) '
          'AND message_key IN (SELECT key FROM local_messages '
          'WHERE hidden_at IS NOT NULL OR deleted_at IS NOT NULL)',
          chunk);
      await customStatement(
          'DELETE FROM local_hide_undo WHERE message_key IN ($marks)', chunk);
    }
  }

  /// A change that names a message whose hide can still be undone makes the
  /// hide final first, so Undo never brings back text the sender has since
  /// edited or deleted, nor misses a reaction or a vote. The caller asks
  /// [_anyHideKept] once per batch first: the table is almost always empty.
  Future<void> _finishHideNamedBy(MessageEffect effect) async {
    final key = switch (effect) {
      EditMessageEffect(:final targetKey) => targetKey,
      DeleteMessageEffect(:final targetKey) => targetKey,
      ReactionEffect(:final targetKey) => targetKey,
      PollVoteEffect(:final targetKey) => targetKey,
      PollCloseEffect(:final targetKey) => targetKey,
      PinMessageEffect(:final targetKey) => targetKey,
      _ => null,
    };
    if (key != null) await _finishHidesInTransaction([key]);
  }

  /// Whether any hide can still be undone.
  Future<bool> _anyHideKept() async =>
      (await customSelect('SELECT 1 FROM local_hide_undo LIMIT 1')
          .getSingleOrNull()) !=
      null;
}
