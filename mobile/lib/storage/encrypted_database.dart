import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

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

class LocalCiphertextEnvelopes extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text()();
  IntColumn get position => integer()();
  TextColumn get payloadJson => text()();

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
/// anywhere, and kept across cache refreshes (D23).
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
])
class EncryptedLocalDatabase extends _$EncryptedLocalDatabase {
  EncryptedLocalDatabase(super.executor);

  static const outboxDraftPrefix = 'outbox.draft.';
  static const syncLeaseName = 'sync.owner.lease';
  static const syncRecoveryName = 'sync.recovery';
  static const lastBackupName = 'backup.last_created_at';

  @override
  int get schemaVersion => 8;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) async {
          await migrator.createAll();
          await into(localSyncStates).insert(
            LocalSyncStatesCompanion.insert(singleton: const Value(1)),
          );
        },
        onUpgrade: (migrator, from, to) async {
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
        // Decrypted history travels in the backup (D27, I45); a version 1
        // backup without it restores an empty history.
        await delete(localMessages).go();
        await delete(localMessageReactions).go();
        for (final message in history) {
          await into(localMessages).insert(message);
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
                  payloadJson: item.payloadJson));
        }
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
        await delete(localCiphertextEnvelopes).go();
        await delete(localConversations).go();
        var position = 0;
        for (final conversation in conversations) {
          await into(localConversations).insert(
            LocalConversationsCompanion.insert(
              id: conversation.id,
              position: position++,
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
        for (final envelope in upsertedEnvelopes) {
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
        if (envelope != null) {
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
                    table.kind.equals(LocalMessageKind.text)))
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
