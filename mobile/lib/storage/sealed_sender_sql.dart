part of 'encrypted_database.dart';

// Local schema 43 (L2-3 sealed sender, D122; docs/crypto.md, "Sealed sender
// with VOPRF tokens"). Raw SQL like the other late tables, so the generated
// drift code does not change, and every step is idempotent (IF NOT EXISTS
// and a column check) so the step can be renumbered when C7's 41-42 land.
//
// - local_sealed_tokens: unspent tokens. Each is a bearer credential: it
//   lets its holder post into its conversation without a session. They live
//   only here, in the encrypted database, and never go into a backup, a
//   history snapshot, a K2 transfer or a log. A token chosen for a message
//   leaves this table and travels in that message's outbox entry.
// - local_sealed_key_pins: the server's POPRF public key, pinned per origin
//   on first use, and a changed key it served since, waiting for a person to
//   accept it in Settings.
// - local_sealed_own_posts: for each message this device chose to send
//   sealed, the SHA-256 of the exact ciphertext it encrypted, so the echo
//   of its own post is recognised by bytes no other member can produce
//   beforehand (never by the idempotency key alone, which every member
//   reads), and, while the message is queued, the plaintext needed to send
//   it identified instead after the server proved nothing sealed was stored
//   (`sealed_not_eligible`) and the person chose "Send normally". The
//   plaintext is cleared when the outbox entry goes or is replaced.
// - local_frank_reveals gains the sealed message's designation `d` (tags
//   only the designated owners can check; never a signature) and the sender
//   account MLS authenticated, so a report of a sealed message can be
//   checked. An earlier draft of this step stored a signature and a signing
//   key: both columns are dropped where they exist.
// - local_device_list_keys gains each pair's franking key (L1 format 2), so
//   an owner checks a report against the key the sender's list names, and
//   local_device_list_heads gains `pinned_at`, when this device first pinned
//   the chain (review M2: a list first pinned after the report arrived
//   gives only the weaker verdict).

/// The server's sealed sender key as this app pinned it for [origin], and a
/// different key the server served since ([seenKeyId], [seenPublicKey]),
/// which stops sealed sending until a person accepts it.
class SealedKeyPin {
  SealedKeyPin({
    required this.origin,
    required this.keyId,
    required List<int> publicKey,
    required this.pinnedAt,
    this.seenKeyId,
    List<int>? seenPublicKey,
  })  : publicKey = List<int>.unmodifiable(publicKey),
        seenPublicKey = seenPublicKey == null
            ? null
            : List<int>.unmodifiable(seenPublicKey);

  final String origin;
  final String keyId;
  final List<int> publicKey;

  /// Epoch milliseconds.
  final int pinnedAt;
  final String? seenKeyId;
  final List<int>? seenPublicKey;

  /// Whether the server now serves a key other than the pinned one.
  bool get changed => seenKeyId != null && seenKeyId != keyId;

  SealedKeyPin withSeen(String? keyId, List<int>? publicKey) => SealedKeyPin(
        origin: origin,
        keyId: this.keyId,
        publicKey: this.publicKey,
        pinnedAt: pinnedAt,
        seenKeyId: keyId,
        seenPublicKey: publicKey,
      );

  @override
  String toString() => 'SealedKeyPin($origin, $keyId)';
}

/// L2-3: one message this device encrypted to go sealed: the digest of its
/// ciphertext (how its echo is recognised as its own) and, while it is
/// queued, [fallbackJson], the payload to encrypt again identified (see
/// [SealedFallback]). Never in a backup, a snapshot or a K2 transfer.
class SealedOwnPost {
  SealedOwnPost({
    required this.conversationId,
    required this.idempotencyKey,
    required List<int> ciphertextSha256,
    this.fallbackJson,
  }) : ciphertextSha256 = List<int>.unmodifiable(ciphertextSha256) {
    if (this.ciphertextSha256.length != 32) {
      throw const FormatException('invalid sealed own post digest');
    }
  }

  final String conversationId;
  final String idempotencyKey;
  final List<int> ciphertextSha256;
  final String? fallbackJson;

  @override
  String toString() => 'SealedOwnPost($conversationId)';
}

/// How long the digest of an own sealed post whose outbox entry is gone is
/// kept for a late echo.
const Duration sealedOwnPostRetention = Duration(days: 30);

/// Most unspent tokens kept for one conversation: today's and tomorrow's
/// batch of 32, with room for a refill.
const int maxSealedTokensPerConversation = 128;

extension SealedSenderSql on EncryptedLocalDatabase {
  /// The tables schema 43 adds (for fixtures that build older databases).
  static const tables = [
    'local_sealed_tokens',
    'local_sealed_key_pins',
    'local_sealed_own_posts',
  ];

  /// `PRAGMA wal_checkpoint(TRUNCATE)`: true when every log frame reached
  /// the database and the log file was cut to zero (no reader held it).
  /// In-memory and rollback-journal databases have no log: true.
  Future<bool> checkpointWalTruncate() async {
    final row =
        await customSelect('PRAGMA wal_checkpoint(TRUNCATE)').getSingle();
    final busy = row.data['busy'] as int? ?? 0;
    final log = row.data['log'] as int? ?? -1;
    final done = row.data['checkpointed'] as int? ?? -1;
    return busy == 0 && (log == -1 || log == done);
  }

  Future<void> _createSealedSender() async {
    await customStatement('CREATE TABLE IF NOT EXISTS local_sealed_tokens ('
        'nonce BLOB PRIMARY KEY NOT NULL CHECK(length(nonce)=${SealedToken.nonceBytes}),'
        'conversation_id TEXT NOT NULL CHECK(length(conversation_id) BETWEEN 1 AND 128),'
        'key_id TEXT NOT NULL CHECK(length(key_id)=32),'
        'epoch INTEGER NOT NULL CHECK(epoch>=0),'
        'output BLOB NOT NULL CHECK(length(output)=${SealedToken.outputBytes}),'
        'stored_at INTEGER NOT NULL)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS local_sealed_tokens_conversation ON '
        'local_sealed_tokens (conversation_id, epoch)');
    await customStatement('CREATE TABLE IF NOT EXISTS local_sealed_key_pins ('
        'origin TEXT PRIMARY KEY NOT NULL,'
        'key_id TEXT NOT NULL CHECK(length(key_id)=32),'
        'public_key BLOB NOT NULL CHECK(length(public_key)=32),'
        'pinned_at INTEGER NOT NULL,'
        'seen_key_id TEXT CHECK(seen_key_id IS NULL OR length(seen_key_id)=32),'
        'seen_public_key BLOB CHECK(seen_public_key IS NULL OR length(seen_public_key)=32))');
    await customStatement('CREATE TABLE IF NOT EXISTS local_sealed_own_posts ('
        'conversation_id TEXT NOT NULL CHECK(length(conversation_id) BETWEEN 1 AND 128),'
        'idempotency_key TEXT NOT NULL CHECK(length(idempotency_key) BETWEEN 1 AND 128),'
        'ciphertext_sha256 BLOB NOT NULL CHECK(length(ciphertext_sha256)=32),'
        'fallback_json TEXT,'
        'created_at INTEGER NOT NULL,'
        'PRIMARY KEY (conversation_id, idempotency_key)) WITHOUT ROWID');
    // local_frank_reveals exists from schema 19 (or was just created with
    // these columns by onCreate's _createFrankReveals).
    final columns = await customSelect(
            "SELECT name FROM pragma_table_info('local_frank_reveals')")
        .get();
    final names = columns.map((row) => row.read<String>('name')).toSet();
    await _dropDraftSignatureColumns();
    if (!names.contains('designation')) {
      await customStatement(
          'ALTER TABLE local_frank_reveals ADD COLUMN designation BLOB '
          'CHECK(designation IS NULL OR (length(designation) BETWEEN 48 AND 768 '
          'AND length(designation) % 48 = 0))');
    }
    if (!names.contains('sender_account_id')) {
      await customStatement(
          'ALTER TABLE local_frank_reveals ADD COLUMN sender_account_id TEXT '
          'CHECK(sender_account_id IS NULL OR length(sender_account_id) BETWEEN 1 AND 128)');
    }
    final keyColumns = await customSelect(
            "SELECT name FROM pragma_table_info('local_device_list_keys')")
        .get();
    if (!keyColumns
        .map((row) => row.read<String>('name'))
        .contains('frank_key')) {
      await customStatement(
          'ALTER TABLE local_device_list_keys ADD COLUMN frank_key BLOB '
          'CHECK(frank_key IS NULL OR length(frank_key) = 32)');
    }
    await _addDeviceListPinnedAt();
  }

  /// Review M2: when this device first pinned each account's chain, so a
  /// report verdict can tell a list pinned before the report arrived from
  /// one the server could have shown first afterwards. Idempotent. Pins
  /// from before take their last check, which is no earlier than their
  /// first pin, so they err toward the weaker verdict.
  Future<bool> _addDeviceListPinnedAt() async {
    final heads = await customSelect(
            "SELECT name FROM pragma_table_info('local_device_list_heads')")
        .get();
    if (heads.map((row) => row.read<String>('name')).contains('pinned_at')) {
      return false;
    }
    await customStatement(
        'ALTER TABLE local_device_list_heads ADD COLUMN pinned_at INTEGER');
    await customStatement('UPDATE local_device_list_heads '
        'SET pinned_at = checked_at WHERE pinned_at IS NULL');
    return true;
  }

  /// A signature over the payload must never be kept (owner decision on
  /// deniability): drops the columns an earlier draft of schema 43 added to
  /// `local_frank_reveals`. Idempotent; returns whether it dropped any.
  Future<bool> _dropDraftSignatureColumns() async {
    final names = (await customSelect(
                "SELECT name FROM pragma_table_info('local_frank_reveals')")
            .get())
        .map((row) => row.read<String>('name'))
        .toSet();
    var dropped = false;
    for (final column in const ['signature', 'signing_key']) {
      if (names.contains(column)) {
        await customStatement(
            'ALTER TABLE local_frank_reveals DROP COLUMN $column');
        dropped = true;
      }
    }
    return dropped;
  }

  /// Review L2: brings a database that is already at schema 43 to the
  /// final shape of that step. A draft of it ran on development devices
  /// and wrote version 43, so the `from < 43` step never runs there again.
  /// Runs on every open at 43 or later; a no-op once the shape is right.
  /// After a drop the log is checkpointed and truncated, so the dropped
  /// values do not stay in old log frames (`secure_delete` clears the
  /// freed pages of the file itself).
  Future<void> _repairSchema43() async {
    final dropped = await transaction(() async {
      await _addDeviceListPinnedAt();
      return _dropDraftSignatureColumns();
    });
    if (dropped) await checkpointWalTruncate();
  }

  Future<void> _clearSealedTokens() async {
    await customStatement('DELETE FROM local_sealed_tokens');
    await customStatement('DELETE FROM local_sealed_own_posts');
  }

  /// Records [post] (inside the outgoing transaction), and drops digests
  /// older than [sealedOwnPostRetention] whose outbox entry is gone.
  Future<void> _writeSealedOwnPostInTransaction(SealedOwnPost post) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await customStatement(
        'DELETE FROM local_sealed_own_posts WHERE created_at < ? AND '
        'idempotency_key NOT IN (SELECT idempotency_key FROM local_outbox_entries)',
        <Object?>[now - sealedOwnPostRetention.inMilliseconds]);
    await customStatement(
        'INSERT OR REPLACE INTO local_sealed_own_posts '
        '(conversation_id, idempotency_key, ciphertext_sha256, fallback_json, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>[
          post.conversationId,
          post.idempotencyKey,
          Uint8List.fromList(post.ciphertextSha256),
          post.fallbackJson,
          now,
        ]);
  }

  /// The digest of the ciphertext this device sent sealed under
  /// ([conversationId], [idempotencyKey]), or null.
  Future<List<int>?> readSealedOwnPostDigest(
      String conversationId, String idempotencyKey) async {
    final row = await customSelect(
        'SELECT ciphertext_sha256 FROM local_sealed_own_posts '
        'WHERE conversation_id = ? AND idempotency_key = ?',
        variables: [
          Variable.withString(conversationId),
          Variable.withString(idempotencyKey),
        ]).getSingleOrNull();
    return row?.read<Uint8List>('ciphertext_sha256');
  }

  /// The identified fallback payload kept for a queued sealed message.
  Future<String?> readSealedOwnPostFallback(
      String conversationId, String idempotencyKey) async {
    final row = await customSelect(
        'SELECT fallback_json FROM local_sealed_own_posts '
        'WHERE conversation_id = ? AND idempotency_key = ?',
        variables: [
          Variable.withString(conversationId),
          Variable.withString(idempotencyKey),
        ]).getSingleOrNull();
    return row?.readNullable<String>('fallback_json');
  }

  Future<void> _clearSealedFallbackInTransaction(String idempotencyKey) =>
      customStatement(
          'UPDATE local_sealed_own_posts SET fallback_json = NULL '
          'WHERE idempotency_key = ?',
          <Object?>[idempotencyKey]);

  Future<void> _deleteSealedOwnPostInTransaction(
          String conversationId, String idempotencyKey) =>
      customStatement(
          'DELETE FROM local_sealed_own_posts '
          'WHERE conversation_id = ? AND idempotency_key = ?',
          <Object?>[conversationId, idempotencyKey]);

  /// Keeps [tokens] (ignoring any not well formed and any nonce already
  /// held), up to [maxSealedTokensPerConversation] per conversation.
  Future<int> writeSealedTokens(List<SealedToken> tokens) =>
      transaction(() async {
        var written = 0;
        final now = DateTime.now().toUtc().millisecondsSinceEpoch;
        for (final token in tokens) {
          if (!token.isWellFormed) continue;
          final held = await customSelect(
              'SELECT COUNT(*) AS n FROM local_sealed_tokens WHERE conversation_id = ?',
              variables: [
                Variable.withString(token.conversationId)
              ]).getSingle();
          if (held.read<int>('n') >= maxSealedTokensPerConversation) continue;
          await customStatement(
              'INSERT OR IGNORE INTO local_sealed_tokens '
              '(nonce, conversation_id, key_id, epoch, output, stored_at) '
              'VALUES (?, ?, ?, ?, ?, ?)',
              <Object?>[
                Uint8List.fromList(token.nonce),
                token.conversationId,
                token.keyId,
                token.epoch,
                Uint8List.fromList(token.output),
                now,
              ]);
          written++;
        }
        return written;
      });

  /// Takes one token for [conversationId] out of the table: under [keyId],
  /// for [epoch] or the day before it (the older first, so it is used
  /// before it dies). Null when none is held.
  Future<SealedToken?> takeSealedToken(String conversationId,
          {required String keyId, required int epoch}) =>
      transaction(() async {
        final row = await customSelect(
            'SELECT nonce, conversation_id, key_id, epoch, output '
            'FROM local_sealed_tokens WHERE conversation_id = ? AND key_id = ? '
            'AND epoch IN (?, ?) ORDER BY epoch ASC LIMIT 1',
            variables: [
              Variable.withString(conversationId),
              Variable.withString(keyId),
              Variable.withInt(epoch - 1),
              Variable.withInt(epoch),
            ]).getSingleOrNull();
        if (row == null) return null;
        final nonce = row.read<Uint8List>('nonce');
        await customStatement('DELETE FROM local_sealed_tokens WHERE nonce = ?',
            <Object?>[nonce]);
        return SealedToken(
          conversationId: row.read<String>('conversation_id'),
          keyId: row.read<String>('key_id'),
          epoch: row.read<int>('epoch'),
          nonce: nonce,
          output: row.read<Uint8List>('output'),
        );
      });

  /// Unspent tokens held for one conversation, key and epoch.
  Future<int> countSealedTokens(String conversationId,
      {required String keyId, required int epoch}) async {
    final row = await customSelect(
        'SELECT COUNT(*) AS n FROM local_sealed_tokens WHERE conversation_id = ? '
        'AND key_id = ? AND epoch = ?',
        variables: [
          Variable.withString(conversationId),
          Variable.withString(keyId),
          Variable.withInt(epoch),
        ]).getSingle();
    return row.read<int>('n');
  }

  /// Drops tokens that can no longer be redeemed: of a day before
  /// [minEpoch], under a key other than [keyId] (null: every key), and
  /// every token of [conversationId].
  Future<void> dropSealedTokens(
      {int? minEpoch, String? keyId, String? conversationId}) async {
    if (minEpoch != null) {
      await customStatement('DELETE FROM local_sealed_tokens WHERE epoch < ?',
          <Object?>[minEpoch]);
    }
    if (keyId != null) {
      await customStatement('DELETE FROM local_sealed_tokens WHERE key_id <> ?',
          <Object?>[keyId]);
    }
    if (conversationId != null) {
      await customStatement(
          'DELETE FROM local_sealed_tokens WHERE conversation_id = ?',
          <Object?>[conversationId]);
    }
  }

  Future<SealedKeyPin?> readSealedKeyPin(String origin) async {
    final row = await customSelect(
        'SELECT origin, key_id, public_key, pinned_at, seen_key_id, seen_public_key '
        'FROM local_sealed_key_pins WHERE origin = ?',
        variables: [Variable.withString(origin)]).getSingleOrNull();
    if (row == null) return null;
    return SealedKeyPin(
      origin: row.read<String>('origin'),
      keyId: row.read<String>('key_id'),
      publicKey: row.read<Uint8List>('public_key'),
      pinnedAt: row.read<int>('pinned_at'),
      seenKeyId: row.readNullable<String>('seen_key_id'),
      seenPublicKey: row.readNullable<Uint8List>('seen_public_key'),
    );
  }

  Future<void> writeSealedKeyPin(SealedKeyPin pin) async {
    if (pin.origin.isEmpty ||
        pin.keyId.length != 32 ||
        pin.publicKey.length != 32 ||
        (pin.seenKeyId == null) != (pin.seenPublicKey == null)) {
      throw const FormatException('invalid sealed key pin');
    }
    await customStatement(
        'INSERT OR REPLACE INTO local_sealed_key_pins '
        '(origin, key_id, public_key, pinned_at, seen_key_id, seen_public_key) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        <Object?>[
          pin.origin,
          pin.keyId,
          Uint8List.fromList(pin.publicKey),
          pin.pinnedAt,
          pin.seenKeyId,
          pin.seenPublicKey == null
              ? null
              : Uint8List.fromList(pin.seenPublicKey!),
        ]);
  }

  /// Rewrites the queued envelope [idempotencyKey] (its sealed token changed)
  /// without touching its place, attempts or failure state. Returns whether
  /// it was still queued.
  Future<bool> rewriteOutboxPayload(
      String idempotencyKey, String payloadJson) async {
    final updated = await (update(localOutboxEntries)
          ..where((table) => table.idempotencyKey.equals(idempotencyKey)))
        .write(LocalOutboxEntriesCompanion(payloadJson: Value(payloadJson)));
    return updated > 0;
  }
}
