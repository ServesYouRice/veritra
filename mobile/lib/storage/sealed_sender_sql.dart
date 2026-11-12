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
// - local_frank_reveals gains the sealed message's franking signature `s`,
//   the sender leaf's signing key it verified under, and the sender account
//   MLS authenticated, so a report of a sealed message can be checked.

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

/// Most unspent tokens kept for one conversation: today's and tomorrow's
/// batch of 32, with room for a refill.
const int maxSealedTokensPerConversation = 128;

extension SealedSenderSql on EncryptedLocalDatabase {
  /// The tables schema 43 adds (for fixtures that build older databases).
  static const tables = ['local_sealed_tokens', 'local_sealed_key_pins'];

  Future<void> _createSealedSender() async {
    await customStatement('CREATE TABLE IF NOT EXISTS local_sealed_tokens ('
        'nonce BLOB PRIMARY KEY NOT NULL CHECK(length(nonce)=${SealedToken.nonceBytes}),'
        'conversation_id TEXT NOT NULL CHECK(length(conversation_id) BETWEEN 1 AND 128),'
        'key_id TEXT NOT NULL CHECK(length(key_id)=32),'
        'epoch INTEGER NOT NULL CHECK(epoch>=0),'
        'generation INTEGER NOT NULL CHECK(generation>=0),'
        'output BLOB NOT NULL CHECK(length(output)=${SealedToken.outputBytes}),'
        'stored_at INTEGER NOT NULL)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS local_sealed_tokens_conversation ON '
        'local_sealed_tokens (conversation_id, epoch, generation)');
    await customStatement('CREATE TABLE IF NOT EXISTS local_sealed_key_pins ('
        'origin TEXT PRIMARY KEY NOT NULL,'
        'key_id TEXT NOT NULL CHECK(length(key_id)=32),'
        'public_key BLOB NOT NULL CHECK(length(public_key)=32),'
        'pinned_at INTEGER NOT NULL,'
        'seen_key_id TEXT CHECK(seen_key_id IS NULL OR length(seen_key_id)=32),'
        'seen_public_key BLOB CHECK(seen_public_key IS NULL OR length(seen_public_key)=32))');
    // local_frank_reveals exists from schema 19 (or was just created with
    // these columns by onCreate's _createFrankReveals).
    final columns = await customSelect(
            "SELECT name FROM pragma_table_info('local_frank_reveals')")
        .get();
    final names = columns.map((row) => row.read<String>('name')).toSet();
    if (!names.contains('signature')) {
      await customStatement(
          'ALTER TABLE local_frank_reveals ADD COLUMN signature BLOB '
          'CHECK(signature IS NULL OR length(signature)=64)');
    }
    if (!names.contains('signing_key')) {
      await customStatement(
          'ALTER TABLE local_frank_reveals ADD COLUMN signing_key BLOB '
          'CHECK(signing_key IS NULL OR length(signing_key)=32)');
    }
    if (!names.contains('sender_account_id')) {
      await customStatement(
          'ALTER TABLE local_frank_reveals ADD COLUMN sender_account_id TEXT '
          'CHECK(sender_account_id IS NULL OR length(sender_account_id) BETWEEN 1 AND 128)');
    }
  }

  Future<void> _clearSealedTokens() =>
      customStatement('DELETE FROM local_sealed_tokens');

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
              '(nonce, conversation_id, key_id, epoch, generation, output, stored_at) '
              'VALUES (?, ?, ?, ?, ?, ?, ?)',
              <Object?>[
                Uint8List.fromList(token.nonce),
                token.conversationId,
                token.keyId,
                token.epoch,
                token.generation,
                Uint8List.fromList(token.output),
                now,
              ]);
          written++;
        }
        return written;
      });

  /// Takes one token for [conversationId] out of the table: under [keyId]
  /// and [generation], for [epoch] or the day before it (the older first,
  /// so it is used before it dies). Null when none is held.
  Future<SealedToken?> takeSealedToken(String conversationId,
          {required String keyId,
          required int generation,
          required int epoch}) =>
      transaction(() async {
        final row = await customSelect(
            'SELECT nonce, conversation_id, key_id, epoch, generation, output '
            'FROM local_sealed_tokens WHERE conversation_id = ? AND key_id = ? '
            'AND generation = ? AND epoch IN (?, ?) ORDER BY epoch ASC LIMIT 1',
            variables: [
              Variable.withString(conversationId),
              Variable.withString(keyId),
              Variable.withInt(generation),
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
          generation: row.read<int>('generation'),
          nonce: nonce,
          output: row.read<Uint8List>('output'),
        );
      });

  /// Unspent tokens held for one conversation, key, generation and epoch.
  Future<int> countSealedTokens(String conversationId,
      {required String keyId,
      required int generation,
      required int epoch}) async {
    final row = await customSelect(
        'SELECT COUNT(*) AS n FROM local_sealed_tokens WHERE conversation_id = ? '
        'AND key_id = ? AND generation = ? AND epoch = ?',
        variables: [
          Variable.withString(conversationId),
          Variable.withString(keyId),
          Variable.withInt(generation),
          Variable.withInt(epoch),
        ]).getSingle();
    return row.read<int>('n');
  }

  /// Drops tokens that can no longer be redeemed: of a day before
  /// [minEpoch], under a key other than [keyId] (null: every key), or, for
  /// [conversationId], of a generation other than [generation] (or all of
  /// that conversation's when [generation] is null).
  Future<void> dropSealedTokens(
      {int? minEpoch,
      String? keyId,
      String? conversationId,
      int? generation}) async {
    if (minEpoch != null) {
      await customStatement('DELETE FROM local_sealed_tokens WHERE epoch < ?',
          <Object?>[minEpoch]);
    }
    if (keyId != null) {
      await customStatement('DELETE FROM local_sealed_tokens WHERE key_id <> ?',
          <Object?>[keyId]);
    }
    if (conversationId != null) {
      if (generation == null) {
        await customStatement(
            'DELETE FROM local_sealed_tokens WHERE conversation_id = ?',
            <Object?>[conversationId]);
      } else {
        await customStatement(
            'DELETE FROM local_sealed_tokens WHERE conversation_id = ? AND generation <> ?',
            <Object?>[conversationId, generation]);
      }
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

  Future<bool> hasMessageRow(String conversationId, String key) async {
    final row = await (select(localMessages)
          ..where((table) =>
              table.key.equals(key) &
              table.conversationId.equals(conversationId))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
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
