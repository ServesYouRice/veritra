import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'encrypted_database.g.dart';

enum MlsCommitStage {
  afterValidation,
  afterState,
  afterEnvelopes,
  afterMarker,
  beforeCursor,
}

typedef MlsCommitFailureInjector = Future<void> Function(MlsCommitStage stage);

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
])
class EncryptedLocalDatabase extends _$EncryptedLocalDatabase {
  EncryptedLocalDatabase(super.executor);

  static const outboxDraftPrefix = 'outbox.draft.';
  static const syncLeaseName = 'sync.owner.lease';

  @override
  int get schemaVersion => 6;

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
          await customStatement('DELETE FROM local_metadata WHERE name LIKE ?',
              <Object?>['$outboxDraftPrefix%']);
          await (delete(localMetadata)
                ..where((table) => table.name.equals(syncLeaseName)))
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
  }) =>
      transaction(() async {
        await delete(localMlsTransitions).go();
        await delete(localMlsOutboxEntries).go();
        await delete(localPeerVerifications).go();
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
        for (final item in mlsOutbox) {
          await into(localMlsOutboxEntries).insert(
              LocalMlsOutboxEntriesCompanion.insert(
                  idempotencyKey: item.idempotencyKey,
                  conversationId: item.conversationId,
                  kind: item.kind,
                  recipientDeviceId: Value(item.recipientDeviceId),
                  revocationDeviceId: Value(item.revocationDeviceId),
                  payload: Uint8List.fromList(item.payload),
                  stateCounter: cryptoState.counter,
                  queuedAt: queuedAt));
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
    MlsCommitFailureInjector? failureInjector,
    String? leaseKey,
  }) =>
      transaction(() async {
        await _assertSyncLeaseInTransaction(leaseKey);
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
    String? leaseKey,
  }) =>
      transaction(() async {
        await _assertSyncLeaseInTransaction(leaseKey);
        final processed = await (select(localMlsTransitions)
              ..where((table) => table.messageId.equals(eventKey)))
            .getSingleOrNull();
        if (processed != null) return;
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
        final queuedAt = DateTime.now().microsecondsSinceEpoch;
        for (final message in messages) {
          await into(localMlsOutboxEntries).insert(
            LocalMlsOutboxEntriesCompanion.insert(
              idempotencyKey: message.idempotencyKey,
              conversationId: message.conversationId,
              kind: message.kind,
              recipientDeviceId: Value(message.recipientDeviceId),
              revocationDeviceId: Value(message.revocationDeviceId),
              payload: Uint8List.fromList(message.payload),
              stateCounter: counter,
              queuedAt: queuedAt,
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
      });

  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required int counter,
    required List<int> stateKey,
    required List<int> sealedState,
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
            ))
        .toList(growable: false);
  }

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
        await into(localSyncStates).insertOnConflictUpdate(
          LocalSyncStatesCompanion.insert(singleton: const Value(1)),
        );
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
