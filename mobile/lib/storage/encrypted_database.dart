import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift/isolate.dart' show DriftRemoteException;

import 'message_search.dart';

part 'encrypted_database.g.dart';

enum MlsCommitStage {
  afterValidation,
  afterState,
  afterEnvelopes,
  afterMessageEffects,
  afterMarker,
  beforeCursor,
}

typedef MlsCommitFailureInjector = Future<void> Function(MlsCommitStage stage);

/// How a decrypted or locally sent application message changes local history
/// (decisions D22, D23). Effects are applied inside the same transaction as
/// the MLS state they came from, because an MLS message can be decrypted only
/// once: if the state commits without the text, the text is gone for good.
///
/// Messages are keyed by the authenticated `<sender_device_id>:<action_id>`,
/// never by a server ID, so the server cannot redirect an edit, delete,
/// reply or reaction to a different message.
sealed class MessageEffect {
  const MessageEffect();
}

/// Kinds stored in [LocalMessages.kind].
abstract final class LocalMessageKind {
  /// A visible message with [LocalMessages.body] text.
  static const text = 'text';

  /// An edit, delete or reaction envelope. It stays in history only so the
  /// timeline can hide its envelope instead of drawing an empty bubble.
  static const action = 'action';

  /// Decrypted, but its MLS sender was not the sender the server claimed
  /// (D25). Shown as a warning, never as the claimed sender's words.
  static const unverifiable = 'unverifiable';

  /// Decrypted, but the payload was malformed or its context did not match
  /// the envelope (W8 step 0, P1). Keyed by the sync event, holds no content.
  static const invalid = 'invalid';

  /// Decrypted and authentic, but from a newer app version or of a type this
  /// one does not know. [LocalMessages.body] holds the inner JSON as decrypted
  /// (encrypted database only), so a later version can read it.
  static const unsupported = 'unsupported';

  /// An attachment manifest. [LocalMessages.body] holds the JSON list of
  /// attachment entries, including their keys, never text to show.
  static const attachment = 'attachment';
}

/// Delivery states stored in [LocalMessages.state].
abstract final class LocalMessageState {
  static const pending = 'pending';
  static const sent = 'sent';
  static const received = 'received';
}

final class InsertMessageEffect extends MessageEffect {
  const InsertMessageEffect({
    required this.key,
    required this.conversationId,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.kind,
    required this.createdAt,
    required this.state,
    this.serverMessageId,
    this.body,
    this.replyTo,
    this.expiresAt,
  });

  final String key;
  final String? serverMessageId;
  final String conversationId;
  final String senderAccountId;
  final String senderDeviceId;
  final String kind;
  final String? body;
  final String? replyTo;
  final int createdAt;
  final String state;

  /// When the server's retention for this message ends (milliseconds since
  /// the epoch), if it set one (W2). A message that is already expired is not
  /// stored at all.
  final int? expiresAt;
}

/// Replaces the text of [targetKey], only if [editorAccountId] sent it.
final class EditMessageEffect extends MessageEffect {
  const EditMessageEffect({
    required this.targetKey,
    required this.editorAccountId,
    required this.body,
    required this.at,
  });

  final String targetKey;
  final String editorAccountId;
  final String body;
  final int at;
}

/// Deletes the text of [targetKey], only if [deleterAccountId] sent it.
final class DeleteMessageEffect extends MessageEffect {
  const DeleteMessageEffect({
    required this.targetKey,
    required this.deleterAccountId,
    required this.at,
  });

  final String targetKey;
  final String deleterAccountId;
  final int at;
}

/// Sets or, with an empty [reaction], clears one account's reaction.
final class ReactionEffect extends MessageEffect {
  const ReactionEffect({
    required this.targetKey,
    required this.reactorAccountId,
    required this.reaction,
    required this.at,
  });

  final String targetKey;
  final String reactorAccountId;
  final String reaction;
  final int at;
}

class LocalAccounts extends Table {
  IntColumn get singleton => integer().withDefault(const Constant(1))();
  TextColumn get sessionJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {singleton};
}

class LocalConversations extends Table {
  TextColumn get id => text()();
  IntColumn get position => integer()();
  TextColumn get payloadJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Schema 10 (W2): [expiresAt] is the envelope's `expires_at` in epoch
/// milliseconds, kept beside the JSON so the expiry sweep can use an index.
///
/// Schema 9 (T49C): the index serves the tail lookup every received message
/// commits (`WHERE conversation_id = ? ORDER BY position DESC LIMIT 1`) and
/// the ordered snapshot read, which otherwise scan and sort the whole cache.
@TableIndex.sql('CREATE INDEX IF NOT EXISTS '
    'local_ciphertext_envelopes_conversation_position '
    'ON local_ciphertext_envelopes (conversation_id, position)')
@TableIndex.sql('CREATE INDEX IF NOT EXISTS '
    'local_ciphertext_envelopes_expires_at '
    'ON local_ciphertext_envelopes (expires_at) WHERE expires_at IS NOT NULL')
class LocalCiphertextEnvelopes extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text()();
  IntColumn get position => integer()();
  TextColumn get payloadJson => text()();
  IntColumn get expiresAt => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class LocalSyncStates extends Table {
  IntColumn get singleton => integer().withDefault(const Constant(1))();
  IntColumn get cursor => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {singleton};
}

class LocalOutboxEntries extends Table {
  TextColumn get idempotencyKey => text()();
  TextColumn get conversationId => text()();
  IntColumn get queuedAt => integer()();
  TextColumn get payloadJson => text()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  IntColumn get nextAttemptAt => integer().nullable()();
  TextColumn get failureClass => text().nullable()();
  BoolColumn get terminal => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {idempotencyKey};
}

class LocalCryptoStates extends Table {
  IntColumn get singleton => integer().withDefault(const Constant(1))();
  IntColumn get counter => integer()();
  BlobColumn get stateKey => blob()();
  BlobColumn get sealedState => blob()();

  @override
  Set<Column<Object>> get primaryKey => {singleton};
}

class LocalMetadata extends Table {
  TextColumn get name => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {name};
}

class LocalMlsTransitions extends Table {
  TextColumn get messageId => text()();
  TextColumn get conversationId => text()();
  IntColumn get cursor => integer()();
  IntColumn get counter => integer()();

  @override
  Set<Column<Object>> get primaryKey => {messageId};
}

class LocalMlsOutboxEntries extends Table {
  TextColumn get idempotencyKey => text()();
  TextColumn get conversationId => text()();
  TextColumn get kind => text()();
  TextColumn get recipientDeviceId => text().nullable()();
  TextColumn get revocationDeviceId => text().nullable()();
  BlobColumn get payload => blob()();
  IntColumn get stateCounter => integer()();
  IntColumn get queuedAt => integer()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  IntColumn get nextAttemptAt => integer().nullable()();
  TextColumn get failureClass => text().nullable()();
  BoolColumn get terminal => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {idempotencyKey};
}

class LocalPeerVerifications extends Table {
  TextColumn get conversationId => text()();
  TextColumn get peerAccountId => text()();
  BlobColumn get transcriptHash => blob()();
  IntColumn get verifiedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, peerAccountId};
}

/// Decrypted history. Encrypted at rest by the database cipher, never sent
/// anywhere, and kept across cache refreshes (D23). A row with [expiresAt]
/// is deleted once that time passes (W2, schema 10).
@TableIndex.sql('CREATE INDEX IF NOT EXISTS local_messages_expires_at '
    'ON local_messages (expires_at) WHERE expires_at IS NOT NULL')
@TableIndex.sql('CREATE UNIQUE INDEX IF NOT EXISTS local_messages_search_id '
    'ON local_messages (search_id)')
class LocalMessages extends Table {
  TextColumn get key => text()();
  TextColumn get serverMessageId => text().nullable().unique()();
  TextColumn get conversationId => text()();
  TextColumn get senderAccountId => text()();
  TextColumn get senderDeviceId => text()();
  TextColumn get kind => text()();
  TextColumn get body => text().nullable()();
  TextColumn get replyTo => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get editedAt => integer().nullable()();
  IntColumn get deletedAt => integer().nullable()();
  TextColumn get state => text()();
  IntColumn get expiresAt => integer().nullable()();

  /// The row's number in the search index (W10, schema 12), set by the
  /// database's triggers for text messages and never by the app. The index
  /// cannot use `rowid`: a table keyed by text may renumber its rows when
  /// vacuumed, which would leave deleted text in the index.
  IntColumn get searchId => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

class LocalMessageReactions extends Table {
  TextColumn get targetKey => text()();
  TextColumn get reactorAccountId => text()();
  TextColumn get reaction => text()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {targetKey, reactorAccountId};
}

/// An unsent composer draft, kept so it survives a restart (W6, schema 11).
/// It is message text before encryption, so it lives only in this database,
/// goes in no backup and is deleted when the message is sent or the data is
/// wiped.
class LocalDrafts extends Table {
  TextColumn get conversationId => text()();
  TextColumn get body => text()();

  /// The local key of the message being replied to, if any.
  TextColumn get replyTo => text().nullable()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId};
}

/// This device's copy of a conversation mute (W6, schema 11). The server holds
/// the same mute for push; the copy lets the list and the expiry work offline.
class LocalConversationMutes extends Table {
  TextColumn get conversationId => text()();

  /// When the mute ends (epoch milliseconds); null mutes without an end.
  IntColumn get mutedUntil => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId};
}

@DriftDatabase(tables: [
  LocalAccounts,
  LocalConversations,
  LocalCiphertextEnvelopes,
  LocalSyncStates,
  LocalOutboxEntries,
  LocalCryptoStates,
  LocalMetadata,
  LocalMlsTransitions,
  LocalMlsOutboxEntries,
  LocalPeerVerifications,
  LocalMessages,
  LocalMessageReactions,
  LocalDrafts,
  LocalConversationMutes,
])
class EncryptedLocalDatabase extends _$EncryptedLocalDatabase {
  EncryptedLocalDatabase(super.executor);

  static const outboxDraftPrefix = 'outbox.draft.';
  static const syncLeaseName = 'sync.owner.lease';
  static const syncRecoveryName = 'sync.recovery';
  static const lastBackupName = 'backup.last_created_at';

  @override
  int get schemaVersion => 12;

  /// Whether opening this database started a schema upgrade. Upgrades run
  /// only after the key has opened the file, so an open that fails after
  /// this is set (for example, because the disk is full) failed in the
  /// upgrade, not on a wrong key. The upgrade then rolls back and the next
  /// open runs it again.
  bool get upgradeStarted => _upgradeStarted;
  bool _upgradeStarted = false;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) async {
          await migrator.createAll();
          await _createSearchIndex();
          await into(localSyncStates).insert(
            LocalSyncStatesCompanion.insert(singleton: const Value(1)),
          );
        },
        // One transaction for every step and the new version number: a failed
        // upgrade leaves the old schema and version untouched and the next
        // open retries it; a committed one is never rerun. PRAGMA foreign_keys
        // has no effect inside it, so a future table rebuild that needs it off
        // must set it before the transaction.
        onUpgrade: (migrator, from, to) async {
          _upgradeStarted = true;
          await transaction(() async {
            if (from < 2) {
              await migrator.createTable(localMlsTransitions);
            }
            if (from < 3) {
              await migrator.createTable(localMlsOutboxEntries);
            }
            if (from < 4) {
              await migrator.addColumn(
                localMlsOutboxEntries,
                localMlsOutboxEntries.revocationDeviceId,
              );
            }
            if (from < 5) {
              await migrator.addColumn(
                  localOutboxEntries, localOutboxEntries.attemptCount);
              await migrator.addColumn(
                  localOutboxEntries, localOutboxEntries.nextAttemptAt);
              await migrator.addColumn(
                  localOutboxEntries, localOutboxEntries.failureClass);
              await migrator.addColumn(
                  localOutboxEntries, localOutboxEntries.terminal);
            }
            if (from < 6) {
              await migrator.createTable(localPeerVerifications);
            }
            if (from < 7) {
              await migrator.createTable(localMessages);
              await migrator.createTable(localMessageReactions);
            }
            if (from < 8) {
              // Durable delivery state for MLS control messages (I34).
              await migrator.addColumn(
                  localMlsOutboxEntries, localMlsOutboxEntries.attemptCount);
              await migrator.addColumn(
                  localMlsOutboxEntries, localMlsOutboxEntries.nextAttemptAt);
              await migrator.addColumn(
                  localMlsOutboxEntries, localMlsOutboxEntries.failureClass);
              await migrator.addColumn(
                  localMlsOutboxEntries, localMlsOutboxEntries.terminal);
            }
            if (from < 9) {
              // Index only (T49C): no table or row changes, and code for
              // schema 8 never names it.
              await migrator
                  .createIndex(localCiphertextEnvelopesConversationPosition);
            }
            if (from < 10) {
              // W2: expiry beside the ciphertext envelopes and the decrypted
              // messages, so expired rows can be found and deleted.
              await migrator.addColumn(
                  localCiphertextEnvelopes, localCiphertextEnvelopes.expiresAt);
              await migrator.addColumn(localMessages, localMessages.expiresAt);
              await migrator.createIndex(localCiphertextEnvelopesExpiresAt);
              await migrator.createIndex(localMessagesExpiresAt);
              await _backfillExpiry();
              await _purgeExpiredInTransaction(
                  DateTime.now().toUtc().millisecondsSinceEpoch);
            }
            if (from < 11) {
              // W6: drafts and conversation mutes. New tables only.
              await migrator.createTable(localDrafts);
              await migrator.createTable(localConversationMutes);
            }
            if (from < 12) {
              // W10: the on-device message search index.
              await migrator.addColumn(localMessages, localMessages.searchId);
              await migrator.createIndex(localMessagesSearchId);
              if (await _createSearchIndex()) await _rebuildSearchIndex();
            }
            // Drift writes the version again after this returns, outside the
            // transaction; writing it here too closes that gap.
            await customStatement('PRAGMA user_version = $to');
          });
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await customStatement('PRAGMA secure_delete = ON');
        },
      );

  Future<void> writeSessionJson(
    String? sessionJson, {
    bool clearIdentityState = false,
  }) =>
      transaction(() async {
        if (clearIdentityState) {
          await delete(localCiphertextEnvelopes).go();
          await delete(localConversations).go();
          await delete(localOutboxEntries).go();
          await delete(localMlsTransitions).go();
          await delete(localMlsOutboxEntries).go();
          await delete(localPeerVerifications).go();
          await delete(localMessages).go();
          await delete(localMessageReactions).go();
          await customStatement('DELETE FROM local_metadata WHERE name LIKE ?',
              <Object?>['$outboxDraftPrefix%']);
          await (delete(localMetadata)
                ..where((table) => table.name.isIn(<String>[
                      syncLeaseName,
                      syncRecoveryName,
                      lastBackupName,
                    ])))
              .go();
          await delete(localCryptoStates).go();
          await into(localSyncStates).insertOnConflictUpdate(
            LocalSyncStatesCompanion.insert(singleton: const Value(1)),
          );
        }
        await into(localAccounts).insertOnConflictUpdate(
          LocalAccountsCompanion.insert(
            singleton: const Value(1),
            sessionJson: Value(sessionJson),
          ),
        );
      });

  Future<void> importLegacy({
    required String? sessionJson,
    required Iterable<({String id, String payloadJson})> conversations,
    required Iterable<
            ({
              String id,
              String conversationId,
              int position,
              String payloadJson
            })>
        envelopes,
    required Iterable<
            ({
              String idempotencyKey,
              String conversationId,
              int queuedAt,
              String payloadJson,
            })>
        outbox,
    required ({
      int counter,
      List<int> stateKey,
      List<int> sealedState
    })? cryptoState,
    required int cursor,
  }) =>
      transaction(() async {
        await delete(localCiphertextEnvelopes).go();
        await delete(localConversations).go();
        await delete(localOutboxEntries).go();
        await delete(localCryptoStates).go();
        await delete(localAccounts).go();
        if (sessionJson != null) {
          await into(localAccounts).insert(
            LocalAccountsCompanion.insert(
              singleton: const Value(1),
              sessionJson: Value(sessionJson),
            ),
          );
        }
        var conversationPosition = 0;
        for (final conversation in conversations) {
          await into(localConversations).insert(
            LocalConversationsCompanion.insert(
              id: conversation.id,
              position: conversationPosition++,
              payloadJson: conversation.payloadJson,
            ),
          );
        }
        for (final envelope in envelopes) {
          await into(localCiphertextEnvelopes).insert(
            LocalCiphertextEnvelopesCompanion.insert(
              id: envelope.id,
              conversationId: envelope.conversationId,
              position: envelope.position,
              payloadJson: envelope.payloadJson,
            ),
          );
        }
        for (final entry in outbox) {
          await into(localOutboxEntries).insert(
            LocalOutboxEntriesCompanion.insert(
              idempotencyKey: entry.idempotencyKey,
              conversationId: entry.conversationId,
              queuedAt: entry.queuedAt,
              payloadJson: entry.payloadJson,
            ),
          );
        }
        if (cryptoState != null) {
          await into(localCryptoStates).insert(
            LocalCryptoStatesCompanion.insert(
              singleton: const Value(1),
              counter: cryptoState.counter,
              stateKey: Uint8List.fromList(cryptoState.stateKey),
              sealedState: Uint8List.fromList(cryptoState.sealedState),
            ),
          );
        }
        await into(localSyncStates).insertOnConflictUpdate(
          LocalSyncStatesCompanion.insert(
              singleton: const Value(1), cursor: Value(cursor)),
        );
      });

  Future<String?> readSessionJson() async {
    final row = await (select(localAccounts)
          ..where((table) => table.singleton.equals(1)))
        .getSingleOrNull();
    return row?.sessionJson;
  }

  Future<void> restoreBackupState({
    required String sessionJson,
    required List<({String id, String payloadJson})> conversations,
    required List<
            ({
              String id,
              String conversationId,
              int position,
              String payloadJson
            })>
        envelopes,
    required List<
            ({
              String idempotencyKey,
              String conversationId,
              String payloadJson
            })>
        outbox,
    required List<
            ({
              String idempotencyKey,
              String conversationId,
              String kind,
              String? recipientDeviceId,
              String? revocationDeviceId,
              List<int> payload
            })>
        mlsOutbox,
    required ({
      int counter,
      List<int> stateKey,
      List<int> sealedState
    }) cryptoState,
    required int cursor,
    List<LocalMessage> history = const <LocalMessage>[],
    List<LocalMessageReaction> reactions = const <LocalMessageReaction>[],
  }) =>
      transaction(() async {
        await delete(localMlsTransitions).go();
        await delete(localMlsOutboxEntries).go();
        await delete(localPeerVerifications).go();
        await delete(localDrafts).go();
        await delete(localConversationMutes).go();
        // Decrypted history travels in the backup (D27, I45); a version 1
        // backup without it restores an empty history.
        await delete(localMessages).go();
        await delete(localMessageReactions).go();
        for (final message in history) {
          // The index numbers are this database's own (W10): the insert
          // trigger assigns them, and a backup's would collide.
          await into(localMessages).insert(
              message.toCompanion(false).copyWith(searchId: const Value(null)));
        }
        for (final reaction in reactions) {
          await into(localMessageReactions).insert(reaction);
        }
        await delete(localOutboxEntries).go();
        await delete(localCiphertextEnvelopes).go();
        await delete(localConversations).go();
        await delete(localCryptoStates).go();
        await delete(localAccounts).go();
        await into(localAccounts).insert(
          LocalAccountsCompanion.insert(
              singleton: const Value(1), sessionJson: Value(sessionJson)),
        );
        for (var index = 0; index < conversations.length; index++) {
          final item = conversations[index];
          await into(localConversations).insert(
              LocalConversationsCompanion.insert(
                  id: item.id, position: index, payloadJson: item.payloadJson));
        }
        for (final item in envelopes) {
          await into(localCiphertextEnvelopes).insert(
              LocalCiphertextEnvelopesCompanion.insert(
                  id: item.id,
                  conversationId: item.conversationId,
                  position: item.position,
                  payloadJson: item.payloadJson,
                  expiresAt: Value(envelopeExpiryMillis(item.payloadJson))));
        }
        // A backup from before schema 10 has no message expiry; take it from
        // the backup's own envelopes, then purge.
        await _backfillExpiry();
        await _purgeExpiredInTransaction(
            DateTime.now().toUtc().millisecondsSinceEpoch);
        final queuedAt = DateTime.now().microsecondsSinceEpoch;
        for (final item in outbox) {
          await into(localOutboxEntries).insert(
              LocalOutboxEntriesCompanion.insert(
                  idempotencyKey: item.idempotencyKey,
                  conversationId: item.conversationId,
                  queuedAt: queuedAt,
                  payloadJson: item.payloadJson));
        }
        await into(localCryptoStates).insert(LocalCryptoStatesCompanion.insert(
            singleton: const Value(1),
            counter: cryptoState.counter,
            stateKey: Uint8List.fromList(cryptoState.stateKey),
            sealedState: Uint8List.fromList(cryptoState.sealedState)));
        for (final (index, item) in mlsOutbox.indexed) {
          await into(localMlsOutboxEntries).insert(
              LocalMlsOutboxEntriesCompanion.insert(
                  idempotencyKey: item.idempotencyKey,
                  conversationId: item.conversationId,
                  kind: item.kind,
                  recipientDeviceId: Value(item.recipientDeviceId),
                  revocationDeviceId: Value(item.revocationDeviceId),
                  payload: Uint8List.fromList(item.payload),
                  stateCounter: cryptoState.counter,
                  queuedAt: queuedAt + index));
        }
        await into(localSyncStates).insertOnConflictUpdate(
            LocalSyncStatesCompanion.insert(
                singleton: const Value(1), cursor: Value(cursor)));
      });

  Future<int> readCursor() async {
    final row = await (select(localSyncStates)
          ..where((table) => table.singleton.equals(1)))
        .getSingleOrNull();
    return row?.cursor ?? 0;
  }

  Future<void> writeCursor(int cursor) => transaction(() async {
        await into(localSyncStates).insertOnConflictUpdate(
          LocalSyncStatesCompanion.insert(
              singleton: const Value(1), cursor: Value(cursor)),
        );
      });

  static const _deleteCachedConversation =
      'DELETE FROM local_conversations WHERE id = ?';
  static const _deleteCachedEnvelope =
      'DELETE FROM local_ciphertext_envelopes WHERE id = ?';
  static const _upsertCachedConversation =
      'INSERT INTO local_conversations (id, position, payload_json) '
      'VALUES (?, ?, ?) ON CONFLICT (id) DO UPDATE SET '
      'position = excluded.position, payload_json = excluded.payload_json '
      'WHERE position IS NOT excluded.position '
      'OR payload_json IS NOT excluded.payload_json';
  static const _upsertCachedEnvelope = 'INSERT INTO local_ciphertext_envelopes '
      '(id, conversation_id, position, payload_json, expires_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT (id) DO UPDATE SET '
      'conversation_id = excluded.conversation_id, '
      'position = excluded.position, payload_json = excluded.payload_json, '
      'expires_at = excluded.expires_at '
      'WHERE conversation_id IS NOT excluded.conversation_id '
      'OR position IS NOT excluded.position '
      'OR payload_json IS NOT excluded.payload_json';

  /// Makes the cached conversation list and ciphertext snapshot exactly
  /// [conversations] (positioned in order) and [envelopes], in one
  /// transaction. The rows are the same as deleting both tables and
  /// inserting everything, but only rows that are new, changed or gone are
  /// written (T49C-3): restoring, refreshing or opening a conversation
  /// otherwise rewrote the whole cache each time. A repeated ID is refused
  /// and the transaction writes nothing.
  Future<void> replaceSnapshot({
    required Iterable<({String id, String payloadJson})> conversations,
    required Iterable<
            ({
              String id,
              String conversationId,
              int position,
              String payloadJson
            })>
        envelopes,
    required int? cursor,
  }) =>
      transaction(() async {
        final previousCursor = cursor == null
            ? null
            : await (select(localSyncStates)
                  ..where((table) => table.singleton.equals(1)))
                .getSingleOrNull();
        if (cursor != null && (previousCursor?.cursor ?? 0) > cursor) return;
        var position = 0;
        final conversationRows = <String, List<Object>>{};
        for (final conversation in conversations) {
          if (conversationRows.containsKey(conversation.id)) {
            throw StateError('duplicate cached conversation');
          }
          conversationRows[conversation.id] = <Object>[
            conversation.id,
            position++,
            conversation.payloadJson,
          ];
        }
        final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        final envelopeRows = <String, List<Object?>>{};
        for (final envelope in envelopes) {
          if (envelopeRows.containsKey(envelope.id)) {
            throw StateError('duplicate cached envelope');
          }
          // An expired envelope is not cached (W2); the delete pass below
          // removes any stored copy.
          final expiresAt = envelopeExpiryMillis(envelope.payloadJson);
          if (expiresAt != null && expiresAt <= nowMs) continue;
          envelopeRows[envelope.id] = <Object?>[
            envelope.id,
            envelope.conversationId,
            envelope.position,
            envelope.payloadJson,
            expiresAt,
          ];
        }
        final storedConversations = await (selectOnly(localConversations)
              ..addColumns([localConversations.id]))
            .map((row) => row.read(localConversations.id)!)
            .get();
        final storedEnvelopes = await (selectOnly(localCiphertextEnvelopes)
              ..addColumns([localCiphertextEnvelopes.id]))
            .map((row) => row.read(localCiphertextEnvelopes.id)!)
            .get();
        final conversationUpdates = <TableUpdate>[
          TableUpdate.onTable(localConversations),
        ];
        final envelopeUpdates = <TableUpdate>[
          TableUpdate.onTable(localCiphertextEnvelopes),
        ];
        // One batch of prepared statements: no round trip to the database
        // isolate per row (T49C). An unchanged row fails the upsert's WHERE
        // and is not written.
        await batch((batch) {
          for (final id in storedConversations) {
            if (conversationRows.containsKey(id)) continue;
            batch.customStatement(
                _deleteCachedConversation, <Object>[id], conversationUpdates);
          }
          for (final id in storedEnvelopes) {
            if (envelopeRows.containsKey(id)) continue;
            batch.customStatement(
                _deleteCachedEnvelope, <Object>[id], envelopeUpdates);
          }
          for (final row in conversationRows.values) {
            batch.customStatement(
                _upsertCachedConversation, row, conversationUpdates);
          }
          for (final row in envelopeRows.values) {
            batch.customStatement(_upsertCachedEnvelope, row, envelopeUpdates);
          }
        });
        if (cursor != null) {
          await into(localSyncStates).insertOnConflictUpdate(
            LocalSyncStatesCompanion.insert(
                singleton: const Value(1), cursor: Value(cursor)),
          );
        }
      });

  Future<
      ({
        int cursor,
        List<String> conversationJson,
        Map<String, List<String>> envelopeJson,
      })> readSnapshotJson() async {
    final conversationRows = await (select(localConversations)
          ..orderBy([(table) => OrderingTerm.asc(table.position)]))
        .get();
    if (conversationRows.isEmpty) {
      return (
        cursor: await readCursor(),
        conversationJson: <String>[],
        envelopeJson: <String, List<String>>{},
      );
    }
    final envelopeRows = await (select(localCiphertextEnvelopes)
          ..orderBy([
            (table) => OrderingTerm.asc(table.conversationId),
            (table) => OrderingTerm.asc(table.position),
          ]))
        .get();
    final envelopes = <String, List<String>>{};
    for (final row in envelopeRows) {
      (envelopes[row.conversationId] ??= <String>[]).add(row.payloadJson);
    }
    return (
      cursor: await readCursor(),
      conversationJson: conversationRows.map((row) => row.payloadJson).toList(),
      envelopeJson: envelopes,
    );
  }

  Future<void> upsertOutbox({
    required String idempotencyKey,
    required String conversationId,
    required String payloadJson,
    required String? draftText,
    required int queuedAt,
    required int maxEntries,
  }) =>
      transaction(() async {
        final existing = await (select(localOutboxEntries)
              ..where((table) => table.idempotencyKey.equals(idempotencyKey)))
            .getSingleOrNull();
        if (existing != null) {
          final existingDraft = await _readMetadataInTransaction(
              _outboxDraftName(idempotencyKey));
          if (existing.payloadJson != payloadJson ||
              (existingDraft != null && existingDraft != draftText)) {
            throw StateError('outbox idempotency key conflict');
          }
          if (existingDraft == null && draftText != null) {
            await _writeMetadataInTransaction(
                _outboxDraftName(idempotencyKey), draftText);
          }
          return;
        }
        final count = await outboxCount();
        if (count >= maxEntries) {
          throw StateError('outbox_full');
        }
        await into(localOutboxEntries).insert(
          LocalOutboxEntriesCompanion.insert(
            idempotencyKey: idempotencyKey,
            conversationId: conversationId,
            queuedAt: queuedAt,
            payloadJson: payloadJson,
          ),
        );
        if (draftText != null) {
          await _writeMetadataInTransaction(
              _outboxDraftName(idempotencyKey), draftText);
        }
      });

  String _outboxDraftName(String idempotencyKey) =>
      '$outboxDraftPrefix$idempotencyKey';

  Future<int> outboxCount() async {
    final row = await customSelect(
      'SELECT COUNT(*) AS count FROM local_outbox_entries',
      readsFrom: {localOutboxEntries},
    ).getSingle();
    return row.read<int>('count');
  }

  Future<List<String>> readOutboxJson() async {
    final rows = await (select(localOutboxEntries)
          ..orderBy([
            (table) => OrderingTerm.asc(table.queuedAt),
            (table) => OrderingTerm.asc(table.idempotencyKey),
          ]))
        .get();
    return rows.map((row) => row.payloadJson).toList();
  }

  Future<
      List<
          ({
            String payloadJson,
            int attemptCount,
            int? nextAttemptAt,
            String? failureClass,
            bool terminal,
            String? draftText
          })>> readOutboxRecords() async {
    final rows = await (select(localOutboxEntries)
          ..orderBy([
            (table) => OrderingTerm.asc(table.queuedAt),
            (table) => OrderingTerm.asc(table.idempotencyKey)
          ]))
        .get();
    return Future.wait(rows.map((row) async => (
          payloadJson: row.payloadJson,
          attemptCount: row.attemptCount,
          nextAttemptAt: row.nextAttemptAt,
          failureClass: row.failureClass,
          terminal: row.terminal,
          draftText: await readMetadata(_outboxDraftName(row.idempotencyKey))
        )));
  }

  Future<void> markOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    int? nextAttemptAt,
  }) =>
      transaction(() async {
        await (update(localOutboxEntries)
              ..where((table) => table.idempotencyKey.equals(idempotencyKey)))
            .write(LocalOutboxEntriesCompanion(
          attemptCount: const Value.absent(),
          failureClass: Value(failureClass),
          terminal: Value(terminal),
          nextAttemptAt: Value(nextAttemptAt),
        ));
        await customStatement(
            'UPDATE local_outbox_entries '
            'SET attempt_count = attempt_count + 1 WHERE idempotency_key = ?',
            <Object?>[idempotencyKey]);
      });

  Future<void> deleteOutbox(String idempotencyKey) => transaction(() async {
        await (delete(localOutboxEntries)
              ..where((table) => table.idempotencyKey.equals(idempotencyKey)))
            .go();
        await (delete(localMetadata)
              ..where((table) =>
                  table.name.equals(_outboxDraftName(idempotencyKey))))
            .go();
      });

  Future<void> writeCryptoState({
    required int counter,
    required List<int> stateKey,
    required List<int> sealedState,
    required int cursor,
  }) =>
      transaction(() async {
        final previous = await (select(localCryptoStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        if (previous != null && counter <= previous.counter) {
          throw StateError('crypto state counter must increase');
        }
        await into(localCryptoStates).insertOnConflictUpdate(
          LocalCryptoStatesCompanion.insert(
            singleton: const Value(1),
            counter: counter,
            stateKey: Uint8List.fromList(stateKey),
            sealedState: Uint8List.fromList(sealedState),
          ),
        );
        await into(localSyncStates).insertOnConflictUpdate(
          LocalSyncStatesCompanion.insert(
              singleton: const Value(1), cursor: Value(cursor)),
        );
      });

  Future<void> commitMlsTransition({
    required String messageId,
    required String conversationId,
    required int expectedCounter,
    required int expectedCursor,
    required int counter,
    required List<int> stateKey,
    required List<int> sealedState,
    required int cursor,
    required List<({String id, String conversationId, String payloadJson})>
        upsertedEnvelopes,
    required List<String> deletedEnvelopeIds,
    List<MessageEffect> messageEffects = const <MessageEffect>[],
    MlsCommitFailureInjector? failureInjector,
    String? leaseKey,
    String? resolvedMlsOutboxKey,
  }) =>
      transaction(() async {
        await _assertSyncLeaseInTransaction(leaseKey);
        if (resolvedMlsOutboxKey != null) {
          await (delete(localMlsOutboxEntries)
                ..where((table) =>
                    table.idempotencyKey.equals(resolvedMlsOutboxKey)))
              .go();
        }
        final processed = await (select(localMlsTransitions)
              ..where((table) => table.messageId.equals(messageId)))
            .getSingleOrNull();
        if (processed != null) {
          throw StateError('MLS message was already processed');
        }
        final previousState = await (select(localCryptoStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        final previousCursor = await (select(localSyncStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        if ((previousState?.counter ?? 0) != expectedCounter ||
            (previousCursor?.cursor ?? 0) != expectedCursor ||
            counter != expectedCounter + 1 ||
            cursor <= expectedCursor) {
          throw StateError('stale or incomplete MLS state transition');
        }
        await failureInjector?.call(MlsCommitStage.afterValidation);
        await into(localCryptoStates).insertOnConflictUpdate(
          LocalCryptoStatesCompanion.insert(
            singleton: const Value(1),
            counter: counter,
            stateKey: Uint8List.fromList(stateKey),
            sealedState: Uint8List.fromList(sealedState),
          ),
        );
        await failureInjector?.call(MlsCommitStage.afterState);

        for (final id in deletedEnvelopeIds) {
          await (delete(localCiphertextEnvelopes)
                ..where((table) => table.id.equals(id)))
              .go();
        }
        final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        for (final envelope in upsertedEnvelopes) {
          final expiresAt = envelopeExpiryMillis(envelope.payloadJson);
          if (expiresAt != null && expiresAt <= nowMs) {
            // Arrived already expired (W2): never stored. The MLS state above
            // still advances, because the message was consumed.
            await (delete(localCiphertextEnvelopes)
                  ..where((table) => table.id.equals(envelope.id)))
                .go();
            continue;
          }
          final existing = await (select(localCiphertextEnvelopes)
                ..where((table) => table.id.equals(envelope.id)))
              .getSingleOrNull();
          var position = existing?.position;
          if (position == null) {
            final tail = await (select(localCiphertextEnvelopes)
                  ..where((table) =>
                      table.conversationId.equals(envelope.conversationId))
                  ..orderBy([(table) => OrderingTerm.desc(table.position)])
                  ..limit(1))
                .getSingleOrNull();
            position = (tail?.position ?? -1) + 1;
          }
          await into(localCiphertextEnvelopes).insertOnConflictUpdate(
            LocalCiphertextEnvelopesCompanion.insert(
              id: envelope.id,
              conversationId: envelope.conversationId,
              position: position,
              payloadJson: envelope.payloadJson,
              expiresAt: Value(expiresAt),
            ),
          );
        }
        await failureInjector?.call(MlsCommitStage.afterEnvelopes);
        await _applyMessageEffects(messageEffects);
        await failureInjector?.call(MlsCommitStage.afterMessageEffects);
        await into(localMlsTransitions).insert(
          LocalMlsTransitionsCompanion.insert(
            messageId: messageId,
            conversationId: conversationId,
            cursor: cursor,
            counter: counter,
          ),
        );
        await failureInjector?.call(MlsCommitStage.afterMarker);
        await failureInjector?.call(MlsCommitStage.beforeCursor);
        await into(localSyncStates).insertOnConflictUpdate(
          LocalSyncStatesCompanion.insert(
              singleton: const Value(1), cursor: Value(cursor)),
        );
      });

  Future<void> commitSyncEvent({
    required String eventKey,
    required String conversationId,
    required int expectedCursor,
    required int cursor,
    ({String id, String conversationId, String payloadJson})? envelope,
    String? ownMessageKey,
    String? leaseKey,
  }) =>
      transaction(() async {
        await _assertSyncLeaseInTransaction(leaseKey);
        final processed = await (select(localMlsTransitions)
              ..where((table) => table.messageId.equals(eventKey)))
            .getSingleOrNull();
        if (processed != null) return;
        if (ownMessageKey != null && envelope != null) {
          // The server echoed a message this device sent: link the local
          // record to its server ID and mark it delivered.
          // The server stamps the expiry when it accepts the message, so the
          // sender learns it from the first echo only (W2). Later echoes
          // cannot add, move or clear it.
          await (update(localMessages)
                ..where((table) =>
                    table.key.equals(ownMessageKey) &
                    table.serverMessageId.isNull() &
                    table.expiresAt.isNull()))
              .write(LocalMessagesCompanion(
            expiresAt: Value(envelopeExpiryMillis(envelope.payloadJson)),
          ));
          await (update(localMessages)
                ..where((table) => table.key.equals(ownMessageKey)))
              .write(LocalMessagesCompanion(
            serverMessageId: Value(envelope.id),
            state: const Value(LocalMessageState.sent),
          ));
        }
        final previousCursor = await (select(localSyncStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        if ((previousCursor?.cursor ?? 0) != expectedCursor ||
            cursor <= expectedCursor) {
          throw StateError('stale sync event commit');
        }
        final envelopeExpiry = envelope == null
            ? null
            : envelopeExpiryMillis(envelope.payloadJson);
        if (envelope != null &&
            envelopeExpiry != null &&
            envelopeExpiry <= DateTime.now().toUtc().millisecondsSinceEpoch) {
          await (delete(localCiphertextEnvelopes)
                ..where((table) => table.id.equals(envelope.id)))
              .go();
        } else if (envelope != null) {
          final existing = await (select(localCiphertextEnvelopes)
                ..where((table) => table.id.equals(envelope.id)))
              .getSingleOrNull();
          var position = existing?.position;
          if (position == null) {
            final tail = await (select(localCiphertextEnvelopes)
                  ..where((table) =>
                      table.conversationId.equals(envelope.conversationId))
                  ..orderBy([(table) => OrderingTerm.desc(table.position)])
                  ..limit(1))
                .getSingleOrNull();
            position = (tail?.position ?? -1) + 1;
          }
          await into(localCiphertextEnvelopes).insertOnConflictUpdate(
            LocalCiphertextEnvelopesCompanion.insert(
              id: envelope.id,
              conversationId: envelope.conversationId,
              position: position,
              payloadJson: envelope.payloadJson,
              expiresAt: Value(envelopeExpiry),
            ),
          );
        }
        final state = await (select(localCryptoStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        await into(localMlsTransitions).insert(
          LocalMlsTransitionsCompanion.insert(
            messageId: eventKey,
            conversationId: conversationId,
            cursor: cursor,
            counter: state?.counter ?? 0,
          ),
        );
        await into(localSyncStates).insertOnConflictUpdate(
          LocalSyncStatesCompanion.insert(
              singleton: const Value(1), cursor: Value(cursor)),
        );
      });

  Future<bool> hasProcessedMlsMessage(String messageId) async {
    final row = await (select(localMlsTransitions)
          ..where((table) => table.messageId.equals(messageId)))
        .getSingleOrNull();
    return row != null;
  }

  /// Control message markers are `mls:<sync event id>:<message id>`.
  Future<bool> hasAppliedMlsControlMessage(String mlsMessageId) async {
    final suffix = ':$mlsMessageId';
    final row = await customSelect(
      'SELECT 1 FROM local_mls_transitions '
      "WHERE substr(message_id, 1, 4) = 'mls:' "
      'AND substr(message_id, -length(?1)) = ?1 LIMIT 1',
      variables: <Variable<Object>>[Variable<String>(suffix)],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        localMlsTransitions
      },
    ).getSingleOrNull();
    return row != null;
  }

  Future<void> commitOutgoingMlsTransition({
    required int expectedCounter,
    required int expectedCursor,
    required int counter,
    required List<int> stateKey,
    required List<int> sealedState,
    required List<
            ({
              String idempotencyKey,
              String conversationId,
              String kind,
              String? recipientDeviceId,
              String? revocationDeviceId,
              List<int> payload,
            })>
        messages,
    String? leaseKey,
  }) =>
      transaction(() async {
        await _assertSyncLeaseInTransaction(leaseKey);
        final previousState = await (select(localCryptoStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        final previousCursor = await (select(localSyncStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        if ((previousState?.counter ?? 0) != expectedCounter ||
            (previousCursor?.cursor ?? 0) != expectedCursor ||
            counter != expectedCounter + 1 ||
            messages.isEmpty) {
          throw StateError('stale or incomplete outgoing MLS transition');
        }
        await into(localCryptoStates).insertOnConflictUpdate(
          LocalCryptoStatesCompanion.insert(
            singleton: const Value(1),
            counter: counter,
            stateKey: Uint8List.fromList(stateKey),
            sealedState: Uint8List.fromList(sealedState),
          ),
        );
        // One transition's messages keep their order: a commit sent after
        // the one it follows would fork the group (I34).
        final queuedAt = DateTime.now().microsecondsSinceEpoch;
        for (final (index, message) in messages.indexed) {
          await into(localMlsOutboxEntries).insert(
            LocalMlsOutboxEntriesCompanion.insert(
              idempotencyKey: message.idempotencyKey,
              conversationId: message.conversationId,
              kind: message.kind,
              recipientDeviceId: Value(message.recipientDeviceId),
              revocationDeviceId: Value(message.revocationDeviceId),
              payload: Uint8List.fromList(message.payload),
              stateCounter: counter,
              queuedAt: queuedAt + index,
            ),
          );
        }
      });

  Future<void> commitOutgoingApplicationTransition({
    required int expectedCounter,
    required int expectedCursor,
    required int counter,
    required List<int> stateKey,
    required List<int> sealedState,
    required String idempotencyKey,
    required String conversationId,
    required String payloadJson,
    required String? draftText,
    required int maxEntries,
    List<MessageEffect> messageEffects = const <MessageEffect>[],
    String? leaseKey,
  }) =>
      transaction(() async {
        await _assertSyncLeaseInTransaction(leaseKey);
        final previousState = await (select(localCryptoStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        final previousCursor = await (select(localSyncStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        if ((previousState?.counter ?? 0) != expectedCounter ||
            (previousCursor?.cursor ?? 0) != expectedCursor ||
            counter != expectedCounter + 1) {
          throw StateError('stale outgoing application MLS transition');
        }
        if (await (select(localOutboxEntries)
                  ..where(
                      (table) => table.idempotencyKey.equals(idempotencyKey)))
                .getSingleOrNull() !=
            null) {
          throw StateError('outbox idempotency key conflict');
        }
        if (await outboxCount() >= maxEntries) {
          throw StateError('outbox_full');
        }
        await into(localCryptoStates).insertOnConflictUpdate(
          LocalCryptoStatesCompanion.insert(
            singleton: const Value(1),
            counter: counter,
            stateKey: Uint8List.fromList(stateKey),
            sealedState: Uint8List.fromList(sealedState),
          ),
        );
        await into(localOutboxEntries).insert(
          LocalOutboxEntriesCompanion.insert(
            idempotencyKey: idempotencyKey,
            conversationId: conversationId,
            queuedAt: DateTime.now().microsecondsSinceEpoch,
            payloadJson: payloadJson,
          ),
        );
        if (draftText != null) {
          await _writeMetadataInTransaction(
              _outboxDraftName(idempotencyKey), draftText);
          // The composer draft this message was sent from goes in the same
          // transaction, so a crash cannot leave a sent message and its draft
          // (W6). A draft edited since is a different draft and stays.
          final draft = await (select(localDrafts)
                ..where((table) => table.conversationId.equals(conversationId)))
              .getSingleOrNull();
          if (draft != null && draft.body.trim() == draftText.trim()) {
            await (delete(localDrafts)
                  ..where(
                      (table) => table.conversationId.equals(conversationId)))
                .go();
          }
        }
        await _applyMessageEffects(messageEffects);
      });

  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required int counter,
    required List<int> stateKey,
    required List<int> sealedState,
    String? leaseKey,
    String? resolvedMlsOutboxKey,
  }) =>
      transaction(() async {
        await _assertSyncLeaseInTransaction(leaseKey);
        final previousState = await (select(localCryptoStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        final previousCursor = await (select(localSyncStates)
              ..where((table) => table.singleton.equals(1)))
            .getSingleOrNull();
        if ((previousState?.counter ?? 0) != expectedCounter ||
            (previousCursor?.cursor ?? 0) != expectedCursor ||
            counter != expectedCounter + 1) {
          throw StateError('stale local MLS transition');
        }
        await into(localCryptoStates).insertOnConflictUpdate(
          LocalCryptoStatesCompanion.insert(
            singleton: const Value(1),
            counter: counter,
            stateKey: Uint8List.fromList(stateKey),
            sealedState: Uint8List.fromList(sealedState),
          ),
        );
        if (resolvedMlsOutboxKey != null) {
          await (delete(localMlsOutboxEntries)
                ..where((table) =>
                    table.idempotencyKey.equals(resolvedMlsOutboxKey)))
              .go();
        }
      });

  Future<
      List<
          ({
            String idempotencyKey,
            String conversationId,
            String kind,
            String? recipientDeviceId,
            String? revocationDeviceId,
            List<int> payload,
            int attemptCount,
            int? nextAttemptAt,
            String? failureClass,
            bool terminal,
          })>> readMlsOutbox() async {
    final rows = await (select(localMlsOutboxEntries)
          ..orderBy([
            (table) => OrderingTerm.asc(table.queuedAt),
            (table) => OrderingTerm.asc(table.idempotencyKey),
          ]))
        .get();
    return rows
        .map((row) => (
              idempotencyKey: row.idempotencyKey,
              conversationId: row.conversationId,
              kind: row.kind,
              recipientDeviceId: row.recipientDeviceId,
              revocationDeviceId: row.revocationDeviceId,
              payload: List<int>.from(row.payload),
              attemptCount: row.attemptCount,
              nextAttemptAt: row.nextAttemptAt,
              failureClass: row.failureClass,
              terminal: row.terminal,
            ))
        .toList(growable: false);
  }

  Future<void> recordMlsOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    required int? nextAttemptAt,
  }) =>
      transaction(() async {
        await (update(localMlsOutboxEntries)
              ..where((table) => table.idempotencyKey.equals(idempotencyKey)))
            .write(LocalMlsOutboxEntriesCompanion(
          failureClass: Value(failureClass),
          terminal: Value(terminal),
          nextAttemptAt: Value(nextAttemptAt),
        ));
        await customStatement(
            'UPDATE local_mls_outbox_entries '
            'SET attempt_count = attempt_count + 1 WHERE idempotency_key = ?',
            <Object?>[idempotencyKey]);
      });

  Future<void> deleteMlsOutbox(String idempotencyKey) => transaction(() async {
        await (delete(localMlsOutboxEntries)
              ..where((table) => table.idempotencyKey.equals(idempotencyKey)))
            .go();
      });

  Future<void> savePeerVerification(String conversationId, String peerAccountId,
      List<int> transcriptHash, int verifiedAt) async {
    await into(localPeerVerifications).insertOnConflictUpdate(
      LocalPeerVerificationsCompanion.insert(
        conversationId: conversationId,
        peerAccountId: peerAccountId,
        transcriptHash: Uint8List.fromList(transcriptHash),
        verifiedAt: verifiedAt,
      ),
    );
  }

  Future<List<int>?> readPeerVerification(
      String conversationId, String peerAccountId) async {
    final row = await (select(localPeerVerifications)
          ..where((table) =>
              table.conversationId.equals(conversationId) &
              table.peerAccountId.equals(peerAccountId)))
        .getSingleOrNull();
    return row == null ? null : List<int>.from(row.transcriptHash);
  }

  Future<({int counter, List<int> stateKey, List<int> sealedState})?>
      readCryptoState() async {
    final row = await (select(localCryptoStates)
          ..where((table) => table.singleton.equals(1)))
        .getSingleOrNull();
    if (row == null) return null;
    return (
      counter: row.counter,
      stateKey: List<int>.from(row.stateKey),
      sealedState: List<int>.from(row.sealedState),
    );
  }

  Future<void> clearCachedState({bool preserveOutbox = false}) =>
      transaction(() async {
        await delete(localCiphertextEnvelopes).go();
        await delete(localConversations).go();
        await delete(localDrafts).go();
        await delete(localConversationMutes).go();
        if (!preserveOutbox) {
          await delete(localOutboxEntries).go();
          await customStatement('DELETE FROM local_metadata WHERE name LIKE ?',
              <Object?>['$outboxDraftPrefix%']);
        }
        await into(localSyncStates).insertOnConflictUpdate(
          LocalSyncStatesCompanion.insert(singleton: const Value(1)),
        );
      });

  Future<void> clearAll() => transaction(() async {
        await delete(localCiphertextEnvelopes).go();
        await delete(localConversations).go();
        await delete(localOutboxEntries).go();
        await delete(localCryptoStates).go();
        await delete(localAccounts).go();
        await delete(localMetadata).go();
        await delete(localMlsTransitions).go();
        await delete(localMlsOutboxEntries).go();
        await delete(localPeerVerifications).go();
        await delete(localMessages).go();
        await delete(localMessageReactions).go();
        await delete(localDrafts).go();
        await delete(localConversationMutes).go();
        await into(localSyncStates).insertOnConflictUpdate(
          LocalSyncStatesCompanion.insert(singleton: const Value(1)),
        );
      });

  /// Decrypted history for one conversation, oldest first. Action rows
  /// (edits, deletes, reactions) are included so callers can hide their
  /// envelopes.
  Future<List<LocalMessage>> readAllMessages() => select(localMessages).get();

  Future<List<LocalMessageReaction>> readAllReactions() =>
      select(localMessageReactions).get();

  Future<List<LocalMessage>> readMessages(String conversationId) =>
      (select(localMessages)
            ..where((table) => table.conversationId.equals(conversationId))
            ..orderBy([
              (table) => OrderingTerm.asc(table.createdAt),
              (table) => OrderingTerm.asc(table.key),
            ]))
          .get();

  Future<List<LocalMessageReaction>> readReactions(String conversationId) {
    final query = select(localMessageReactions).join([
      innerJoin(localMessages,
          localMessages.key.equalsExp(localMessageReactions.targetKey)),
    ])
      ..where(localMessages.conversationId.equals(conversationId));
    return query.map((row) => row.readTable(localMessageReactions)).get();
  }

  Future<void> applyMessageEffects(List<MessageEffect> effects) =>
      transaction(() => _applyMessageEffects(effects));

  Future<void> _applyMessageEffects(List<MessageEffect> effects) async {
    for (final effect in effects) {
      switch (effect) {
        case InsertMessageEffect():
          final expiresAt = effect.expiresAt;
          if (expiresAt != null &&
              expiresAt <= DateTime.now().toUtc().millisecondsSinceEpoch) {
            // Already expired when it arrived (W2): never stored.
            continue;
          }
          await into(localMessages).insert(
            LocalMessagesCompanion.insert(
              key: effect.key,
              serverMessageId: Value(effect.serverMessageId),
              conversationId: effect.conversationId,
              senderAccountId: effect.senderAccountId,
              senderDeviceId: effect.senderDeviceId,
              kind: effect.kind,
              body: Value(effect.body),
              replyTo: Value(effect.replyTo),
              createdAt: effect.createdAt,
              state: effect.state,
              expiresAt: Value(effect.expiresAt),
            ),
            mode: InsertMode.insertOrIgnore,
          );
        case EditMessageEffect():
          await (update(localMessages)
                ..where((table) =>
                    table.key.equals(effect.targetKey) &
                    table.senderAccountId.equals(effect.editorAccountId) &
                    table.kind.equals(LocalMessageKind.text) &
                    table.deletedAt.isNull()))
              .write(LocalMessagesCompanion(
            body: Value(effect.body),
            editedAt: Value(effect.at),
          ));
        case DeleteMessageEffect():
          final deleted = await (update(localMessages)
                ..where((table) =>
                    table.key.equals(effect.targetKey) &
                    table.senderAccountId.equals(effect.deleterAccountId) &
                    // The author may also delete an unsupported row, which
                    // clears its raw JSON (S3).
                    table.kind.isIn(const <String>[
                      LocalMessageKind.text,
                      LocalMessageKind.unsupported,
                    ])))
              .write(LocalMessagesCompanion(
            body: const Value(null),
            deletedAt: Value(effect.at),
          ));
          if (deleted > 0) {
            await (delete(localMessageReactions)
                  ..where((table) => table.targetKey.equals(effect.targetKey)))
                .go();
          }
        case ReactionEffect():
          if (effect.reaction.isEmpty) {
            await (delete(localMessageReactions)
                  ..where((table) =>
                      table.targetKey.equals(effect.targetKey) &
                      table.reactorAccountId.equals(effect.reactorAccountId)))
                .go();
          } else {
            await into(localMessageReactions).insertOnConflictUpdate(
              LocalMessageReactionsCompanion.insert(
                targetKey: effect.targetKey,
                reactorAccountId: effect.reactorAccountId,
                reaction: effect.reaction,
                updatedAt: effect.at,
              ),
            );
          }
      }
    }
  }

  /// Deletes every message, reaction and cached envelope whose expiry has
  /// passed, in one transaction (W2). Returns the conversations that lost a
  /// row.
  Future<Set<String>> purgeExpired({DateTime? now}) => transaction(
        () => _purgeExpiredInTransaction(
            (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch),
      );

  /// The earliest expiry still stored (epoch milliseconds), if any.
  Future<int?> nextExpiry() async {
    final envelopeExpiry = localCiphertextEnvelopes.expiresAt.min();
    final messageExpiry = localMessages.expiresAt.min();
    final fromEnvelopes = await (selectOnly(localCiphertextEnvelopes)
          ..addColumns([envelopeExpiry]))
        .map((row) => row.read(envelopeExpiry))
        .getSingle();
    final fromMessages = await (selectOnly(localMessages)
          ..addColumns([messageExpiry]))
        .map((row) => row.read(messageExpiry))
        .getSingle();
    if (fromEnvelopes == null) return fromMessages;
    if (fromMessages == null) return fromEnvelopes;
    return fromEnvelopes < fromMessages ? fromEnvelopes : fromMessages;
  }

  /// Deletes what has expired. Decrypted rows go only by their own expiry,
  /// which was set when the message was decrypted or, for this device's own
  /// message, by its first server echo. A cached envelope is only a copy of
  /// what the server listed and was never authenticated, so an expired one
  /// removes just itself: a server cannot erase older history by listing a
  /// message again with a short expiry.
  Future<Set<String>> _purgeExpiredInTransaction(int nowMs) async {
    final conversations = <String>{};
    final expiredEnvelopes = await (select(localCiphertextEnvelopes)
          ..where((table) =>
              table.expiresAt.isNotNull() &
              table.expiresAt.isSmallerOrEqualValue(nowMs)))
        .get();
    for (final chunk in _chunks([for (final row in expiredEnvelopes) row.id])) {
      await (delete(localCiphertextEnvelopes)
            ..where((table) => table.id.isIn(chunk)))
          .go();
    }
    for (final row in expiredEnvelopes) {
      conversations.add(row.conversationId);
    }
    final expiredMessages = await (select(localMessages)
          ..where((table) =>
              table.expiresAt.isNotNull() &
              table.expiresAt.isSmallerOrEqualValue(nowMs)))
        .get();
    final keys = <String>[];
    for (final row in expiredMessages) {
      conversations.add(row.conversationId);
      keys.add(row.key);
    }
    for (final chunk in _chunks(keys)) {
      await (delete(localMessageReactions)
            ..where((table) => table.targetKey.isIn(chunk)))
          .go();
      await (delete(localMessages)..where((table) => table.key.isIn(chunk)))
          .go();
    }
    return conversations;
  }

  static Iterable<List<String>> _chunks(List<String> values) sync* {
    // SQLite caps bound variables; stay well below the old 999 limit.
    for (var start = 0; start < values.length; start += 500) {
      yield values.sublist(
          start, start + 500 > values.length ? values.length : start + 500);
    }
  }

  /// Fills the schema 10 expiry columns from what older versions stored.
  /// Messages whose envelope already left the cache keep no expiry.
  Future<void> _backfillExpiry() async {
    final rows = await customSelect(
      'SELECT id, payload_json FROM local_ciphertext_envelopes '
      "WHERE payload_json LIKE '%\"expires_at\"%'",
    ).get();
    for (final row in rows) {
      final expiresAt = envelopeExpiryMillis(row.read<String>('payload_json'));
      if (expiresAt == null) continue;
      final id = row.read<String>('id');
      await customStatement(
        'UPDATE local_ciphertext_envelopes SET expires_at = ? WHERE id = ?',
        <Object?>[expiresAt, id],
      );
      await customStatement(
        'UPDATE local_messages SET expires_at = ? '
        'WHERE server_message_id = ? AND expires_at IS NULL',
        <Object?>[expiresAt, id],
      );
    }
  }

  // ---- on-device message search (W10) ----------------------------------

  static const _searchTable = 'local_message_search';

  /// Creates the full-text index and the triggers that keep it equal to the
  /// text of `local_messages` through every insert, edit, delete, expiry
  /// purge and wipe. Returns false, leaving search to the plain scan in
  /// [searchMessages], when this SQLite build has no FTS5.
  Future<bool> _createSearchIndex() async {
    try {
      await customStatement('CREATE VIRTUAL TABLE IF NOT EXISTS $_searchTable '
          "USING fts5(body, tokenize = 'unicode61 remove_diacritics 2')");
    } catch (_) {
      // No FTS5 in this build; the app searches by scanning instead.
      return false;
    }
    // Deleted text is erased from the index at once, not at the next merge.
    await customStatement(
        "INSERT INTO $_searchTable($_searchTable, rank) VALUES('secure-delete', 1)");
    await customStatement('''
CREATE TRIGGER IF NOT EXISTS local_messages_search_ai
AFTER INSERT ON local_messages
WHEN new.kind = 'text' AND new.body IS NOT NULL
BEGIN
  UPDATE local_messages
    SET search_id = (SELECT COALESCE(MAX(search_id), 0) + 1 FROM local_messages)
    WHERE key = new.key;
  INSERT INTO $_searchTable(rowid, body)
    SELECT search_id, body FROM local_messages WHERE key = new.key;
END''');
    await customStatement('''
CREATE TRIGGER IF NOT EXISTS local_messages_search_au
AFTER UPDATE OF body, kind ON local_messages
BEGIN
  DELETE FROM $_searchTable WHERE rowid = old.search_id;
  UPDATE local_messages
    SET search_id = (SELECT COALESCE(MAX(search_id), 0) + 1 FROM local_messages)
    WHERE key = new.key AND search_id IS NULL
      AND new.kind = 'text' AND new.body IS NOT NULL;
  INSERT INTO $_searchTable(rowid, body)
    SELECT search_id, body FROM local_messages
    WHERE key = new.key AND kind = 'text' AND body IS NOT NULL
      AND search_id IS NOT NULL;
END''');
    await customStatement('''
CREATE TRIGGER IF NOT EXISTS local_messages_search_ad
AFTER DELETE ON local_messages
BEGIN
  DELETE FROM $_searchTable WHERE rowid = old.search_id;
END''');
    return true;
  }

  /// Indexes every text message already stored (the upgrade to schema 12).
  Future<void> _rebuildSearchIndex() async {
    await customStatement("DELETE FROM $_searchTable");
    await customStatement('UPDATE local_messages SET search_id = NULL');
    await customStatement("UPDATE local_messages SET search_id = rowid "
        "WHERE kind = 'text' AND body IS NOT NULL");
    await customStatement('INSERT INTO $_searchTable(rowid, body) '
        'SELECT search_id, body FROM local_messages '
        'WHERE search_id IS NOT NULL');
  }

  Future<bool> get _hasSearchIndex async => (await customSelect(
        "SELECT 1 FROM sqlite_master WHERE name = '$_searchTable'",
      ).get())
          .isNotEmpty;

  /// Messages whose text contains every word of [query] (the last word may be
  /// the start of a longer one), newest first, at most [limit]. Words match
  /// without regard to case and accents. Nothing leaves the database.
  Future<List<MessageSearchHit>> searchMessages(String query,
      {int limit = 50}) async {
    final terms = searchTerms(query);
    if (terms.isEmpty) return const <MessageSearchHit>[];
    if (await _hasSearchIndex) {
      final rows = await customSelect(
        'SELECT m.key AS key, m.conversation_id AS conversation_id, '
        'm.sender_account_id AS sender, m.created_at AS created_at, '
        "snippet($_searchTable, 0, '$snippetMatchStart', '$snippetMatchEnd', "
        "'…', 16) AS snippet "
        'FROM $_searchTable JOIN local_messages m ON m.search_id = '
        '$_searchTable.rowid '
        'WHERE $_searchTable MATCH ? AND m.kind = \'text\' '
        'AND m.deleted_at IS NULL '
        'ORDER BY m.created_at DESC, m.key DESC LIMIT ?',
        variables: [Variable<String>(ftsQueryFor(terms)), Variable<int>(limit)],
      ).get();
      return [
        for (final row in rows)
          MessageSearchHit(
            key: row.read<String>('key'),
            conversationId: row.read<String>('conversation_id'),
            senderAccountId: row.read<String>('sender'),
            createdAt: row.read<int>('created_at'),
            snippet: row.read<String>('snippet'),
          ),
      ];
    }
    // No FTS5: scan the decrypted rows inside the encrypted database.
    final rows = await (select(localMessages)
          ..where((table) =>
              table.kind.equals(LocalMessageKind.text) &
              table.body.isNotNull() &
              table.deletedAt.isNull())
          ..orderBy([
            (table) => OrderingTerm.desc(table.createdAt),
            (table) => OrderingTerm.desc(table.key),
          ]))
        .get();
    final hits = <MessageSearchHit>[];
    for (final row in rows) {
      final text = row.body!.toLowerCase();
      if (!terms.every(text.contains)) continue;
      hits.add(MessageSearchHit(
        key: row.key,
        conversationId: row.conversationId,
        senderAccountId: row.senderAccountId,
        createdAt: row.createdAt,
        snippet: snippetFor(row.body!, terms),
      ));
      if (hits.length == limit) break;
    }
    return hits;
  }

  Future<void> saveDraft({
    required String conversationId,
    required String body,
    required String? replyTo,
  }) =>
      into(localDrafts).insertOnConflictUpdate(
        LocalDraftsCompanion.insert(
          conversationId: conversationId,
          body: body,
          replyTo: Value(replyTo),
          updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
        ),
      );

  Future<void> deleteDraft(String conversationId) => (delete(localDrafts)
        ..where((table) => table.conversationId.equals(conversationId)))
      .go();

  Future<List<LocalDraft>> readDrafts() => select(localDrafts).get();

  /// Remembers a mute until [mutedUntil] (epoch milliseconds), or without an
  /// end when it is null. [muted] false forgets it.
  Future<void> saveMute(String conversationId,
      {required bool muted, int? mutedUntil}) async {
    if (!muted) {
      await (delete(localConversationMutes)
            ..where((table) => table.conversationId.equals(conversationId)))
          .go();
      return;
    }
    await into(localConversationMutes).insertOnConflictUpdate(
      LocalConversationMutesCompanion.insert(
        conversationId: conversationId,
        mutedUntil: Value(mutedUntil),
      ),
    );
  }

  /// Mutes still in force at [nowMs]; ended ones are deleted on the way.
  Future<List<LocalConversationMute>> readMutes(int nowMs) =>
      transaction(() async {
        await (delete(localConversationMutes)
              ..where((table) =>
                  table.mutedUntil.isNotNull() &
                  table.mutedUntil.isSmallerOrEqualValue(nowMs)))
            .go();
        return select(localConversationMutes).get();
      });

  Future<String?> readMetadata(String name) async {
    final row = await (select(localMetadata)
          ..where((table) => table.name.equals(name)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<String?> _readMetadataInTransaction(String name) async {
    final row = await (select(localMetadata)
          ..where((table) => table.name.equals(name)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> _assertSyncLeaseInTransaction(String? leaseKey) async {
    if (leaseKey == null) return;
    final stored = await _readMetadataInTransaction(syncLeaseName);
    if (stored != leaseKey) {
      throw StateError('sync owner lease is no longer active');
    }
  }

  Future<void> acquireSyncLease(String leaseKey) => transaction(() async {
        await _writeMetadataInTransaction(syncLeaseName, leaseKey);
      });

  Future<void> releaseSyncLease(String leaseKey) => transaction(() async {
        final stored = await _readMetadataInTransaction(syncLeaseName);
        if (stored == leaseKey) {
          await (delete(localMetadata)
                ..where((table) => table.name.equals(syncLeaseName)))
              .go();
        }
      });

  Future<void> _writeMetadataInTransaction(String name, String value) async {
    await into(localMetadata).insertOnConflictUpdate(
      LocalMetadataCompanion.insert(name: name, value: value),
    );
  }

  Future<void> deleteMetadata(String name) => transaction(() async {
        await (delete(localMetadata)..where((table) => table.name.equals(name)))
            .go();
      });

  Future<void> writeMetadata(String name, String value) =>
      transaction(() async {
        await into(localMetadata).insertOnConflictUpdate(
          LocalMetadataCompanion.insert(name: name, value: value),
        );
      });
}

EncryptedLocalDatabase openEncryptedLocalDatabase(File file, String keyHex) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(keyHex)) {
    throw StateError('invalid encrypted database key');
  }
  return EncryptedLocalDatabase(
    NativeDatabase.createInBackground(
      file,
      setup: (rawDatabase) {
        rawDatabase.execute("PRAGMA cipher = 'chacha20'");
        rawDatabase.execute("PRAGMA hexkey = '$keyHex'");
        rawDatabase.execute('PRAGMA busy_timeout = 5000');
        final cipherRows = rawDatabase.select('PRAGMA cipher');
        final cipher = cipherRows.isEmpty
            ? null
            : cipherRows.first.values.first.toString();
        if (cipher != 'chacha20') {
          throw StateError('SQLite encryption cipher is unavailable');
        }
        // PRAGMA key accepts any input. The first schema read proves that the
        // key can authenticate the encrypted database before Drift uses it.
        rawDatabase.select('SELECT count(*) FROM sqlite_master');
        rawDatabase.execute('PRAGMA journal_mode = WAL');
      },
    ),
  );
}

/// Whether [error], or an error it wraps, is SQLite reporting a full device
/// (`SQLITE_FULL`) or a failed read or write (`SQLITE_IOERR`). Errors from
/// the background isolate arrive wrapped, several layers deep.
bool isStorageFullError(Object error) => _isStorageFull(error, 0);

const _sqliteIoErr = 10;
const _sqliteFull = 13;

bool _isStorageFull(Object? error, int depth) {
  if (error == null || depth > 8) return false;
  return switch (error) {
    SqliteException(:final resultCode) =>
      resultCode == _sqliteFull || resultCode == _sqliteIoErr,
    DriftRemoteException(:final remoteCause) =>
      _isStorageFull(remoteCause, depth + 1),
    DriftWrappedException(:final cause) => _isStorageFull(cause, depth + 1),
    CouldNotRollBackException(:final cause, :final exception) =>
      _isStorageFull(cause, depth + 1) || _isStorageFull(exception, depth + 1),
    _ => false,
  };
}

/// The `expires_at` of a cached envelope's JSON, in epoch milliseconds, or
/// null when it has none or cannot be read (W2).
int? envelopeExpiryMillis(String payloadJson) {
  try {
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map) return null;
    final raw = decoded['expires_at'];
    if (raw is! String) return null;
    return DateTime.tryParse(raw)?.toUtc().millisecondsSinceEpoch;
  } on FormatException {
    return null;
  }
}
