import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import 'encrypted_database.dart';

final Map<String, Future<void>> _databaseOpenTails = <String, Future<void>>{};
final Map<String, Future<void>> _databaseWriteTails = <String, Future<void>>{};

Future<T> _serializeDatabaseWrite<T>(
  String path,
  Future<T> Function() action,
) async {
  final previous = _databaseWriteTails[path] ?? Future<void>.value();
  final release = Completer<void>();
  final current = previous.then((_) => release.future);
  _databaseWriteTails[path] = current;
  await previous;
  try {
    return await action();
  } finally {
    release.complete();
    if (identical(_databaseWriteTails[path], current)) {
      _databaseWriteTails.remove(path);
    }
  }
}

class CachedSnapshot {
  const CachedSnapshot({
    required this.cursor,
    required this.conversations,
    required this.messagesByConversation,
  });

  final int cursor;
  final List<Conversation> conversations;
  final Map<String, List<ReceivedMessageEnvelope>> messagesByConversation;
}

class StoredCryptoState {
  StoredCryptoState({
    required this.counter,
    required this.stateKey,
    required this.sealedState,
  });

  final int counter;
  final List<int> stateKey;
  final List<int> sealedState;
}

class MlsStateTransition {
  const MlsStateTransition({
    required this.messageId,
    required this.conversationId,
    required this.expectedCounter,
    required this.expectedCursor,
    required this.state,
    required this.cursor,
    this.upsertedEnvelopes = const <ReceivedMessageEnvelope>[],
    this.deletedEnvelopeIds = const <String>[],
  });

  final String messageId;
  final String conversationId;
  final int expectedCounter;
  final int expectedCursor;
  final StoredCryptoState state;
  final int cursor;
  final List<ReceivedMessageEnvelope> upsertedEnvelopes;
  final List<String> deletedEnvelopeIds;
}

class PendingMlsMessage {
  const PendingMlsMessage({
    required this.idempotencyKey,
    required this.conversationId,
    required this.kind,
    required this.payload,
    this.recipientDeviceId,
    this.revocationDeviceId,
  });

  final String idempotencyKey;
  final String conversationId;
  final String kind;
  final String? recipientDeviceId;
  final String? revocationDeviceId;
  final List<int> payload;
}

class OutgoingMlsStateTransition {
  const OutgoingMlsStateTransition({
    required this.expectedCounter,
    required this.expectedCursor,
    required this.state,
    required this.messages,
  });

  final int expectedCounter;
  final int expectedCursor;
  final StoredCryptoState state;
  final List<PendingMlsMessage> messages;
}

class OutgoingApplicationStateTransition {
  const OutgoingApplicationStateTransition({
    required this.expectedCounter,
    required this.expectedCursor,
    required this.state,
    required this.envelope,
  });

  final int expectedCounter;
  final int expectedCursor;
  final StoredCryptoState state;
  final MessageEnvelope envelope;
}

class LocalBackupData {
  const LocalBackupData({
    required this.session,
    required this.cursor,
    required this.conversations,
    required this.messages,
    required this.outbox,
    required this.mlsOutbox,
    required this.cryptoState,
  });

  final Session session;
  final int cursor;
  final List<Conversation> conversations;
  final Map<String, List<ReceivedMessageEnvelope>> messages;
  final List<MessageEnvelope> outbox;
  final List<PendingMlsMessage> mlsOutbox;
  final StoredCryptoState cryptoState;
}

class PendingEnvelopeRecord {
  const PendingEnvelopeRecord({
    required this.envelope,
    required this.attemptCount,
    required this.terminal,
    this.nextAttemptAt,
    this.failureClass,
  });
  final MessageEnvelope envelope;
  final int attemptCount;
  final bool terminal;
  final DateTime? nextAttemptAt;
  final String? failureClass;
}

abstract class LocalStore {
  Future<void> saveSession(Session session);
  Future<Session?> loadSession();
  Future<void> saveSyncCursor(int eventId);
  Future<int> loadSyncCursor();
  Future<void> saveSnapshot(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
    int cursor,
  );
  Future<CachedSnapshot?> loadSnapshot();
  Future<void> enqueueEnvelope(MessageEnvelope envelope);
  Future<List<MessageEnvelope>> pendingEnvelopes();
  Future<List<PendingEnvelopeRecord>> pendingEnvelopeRecords();
  Future<void> recordOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  });
  Future<void> removePendingEnvelope(String idempotencyKey);
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor);
  Future<void> commitMlsTransition(MlsStateTransition transition);
  Future<bool> hasProcessedMlsMessage(String messageId);
  Future<void> commitOutgoingMlsTransition(
      OutgoingMlsStateTransition transition);
  Future<List<PendingMlsMessage>> pendingMlsMessages();
  Future<void> removePendingMlsMessage(String idempotencyKey);
  Future<void> commitOutgoingApplicationTransition(
      OutgoingApplicationStateTransition transition);
  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
  });
  Future<StoredCryptoState?> loadCryptoState();
  Future<List<int>> exportBackup();
  Future<void> restoreBackup(List<int> encoded);
  Future<void> savePeerVerification(
      String conversationId, String peerAccountId, List<int> transcriptHash);
  Future<List<int>?> loadPeerVerification(
      String conversationId, String peerAccountId);
  Future<void> clearCachedState();
  Future<void> clear();
}

class MemoryLocalStore implements LocalStore {
  Session? _session;
  int _syncCursor = 0;
  CachedSnapshot? _snapshot;
  final List<MessageEnvelope> _outbox = <MessageEnvelope>[];
  final Map<String, PendingEnvelopeRecord> _outboxRecords =
      <String, PendingEnvelopeRecord>{};
  StoredCryptoState? _cryptoState;
  final Set<String> _processedMlsMessages = <String>{};
  final Map<String, PendingMlsMessage> _mlsOutbox =
      <String, PendingMlsMessage>{};
  final Map<String, List<int>> _peerVerifications = <String, List<int>>{};

  @override
  Future<void> saveSession(Session session) async {
    if (_session != null && _identity(_session!) != _identity(session)) {
      await clearCachedState();
      _cryptoState = null;
    }
    _session = session;
  }

  @override
  Future<Session?> loadSession() async => _session;

  @override
  Future<void> saveSyncCursor(int eventId) async {
    _syncCursor = eventId;
  }

  @override
  Future<int> loadSyncCursor() async => _syncCursor;

  @override
  Future<void> saveSnapshot(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
    int cursor,
  ) async {
    _syncCursor = cursor;
    _snapshot = CachedSnapshot(
      cursor: cursor,
      conversations: List<Conversation>.from(conversations),
      messagesByConversation: messagesByConversation.map(
        (key, value) =>
            MapEntry(key, List<ReceivedMessageEnvelope>.from(value)),
      ),
    );
  }

  @override
  Future<CachedSnapshot?> loadSnapshot() async => _snapshot;

  @override
  Future<void> enqueueEnvelope(MessageEnvelope envelope) async {
    _outbox.removeWhere(
      (item) => item.idempotencyKey == envelope.idempotencyKey,
    );
    _outbox.add(envelope);
    _outboxRecords.putIfAbsent(
        envelope.idempotencyKey,
        () => PendingEnvelopeRecord(
            envelope: envelope, attemptCount: 0, terminal: false));
  }

  @override
  Future<List<MessageEnvelope>> pendingEnvelopes() async =>
      List<MessageEnvelope>.from(_outbox);

  @override
  Future<List<PendingEnvelopeRecord>> pendingEnvelopeRecords() async => _outbox
      .map((item) =>
          _outboxRecords[item.idempotencyKey] ??
          PendingEnvelopeRecord(
              envelope: item, attemptCount: 0, terminal: false))
      .toList(growable: false);

  @override
  Future<void> recordOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  }) async {
    final existing = _outboxRecords[idempotencyKey];
    if (existing == null) return;
    _outboxRecords[idempotencyKey] = PendingEnvelopeRecord(
        envelope: existing.envelope,
        attemptCount: existing.attemptCount + 1,
        terminal: terminal,
        nextAttemptAt: nextAttemptAt,
        failureClass: failureClass);
  }

  @override
  Future<void> removePendingEnvelope(String idempotencyKey) async {
    _outbox.removeWhere((item) => item.idempotencyKey == idempotencyKey);
    _outboxRecords.remove(idempotencyKey);
  }

  @override
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor) async {
    _validateCryptoState(state);
    if (_cryptoState != null && state.counter <= _cryptoState!.counter) {
      throw StateError('crypto state counter must increase');
    }
    _cryptoState = _copyCryptoState(state);
    _syncCursor = syncCursor;
  }

  @override
  Future<void> commitMlsTransition(MlsStateTransition transition) async {
    if (_processedMlsMessages.contains(transition.messageId)) {
      throw StateError('MLS message was already processed');
    }
    _validateMlsTransition(
      transition,
      currentCounter: _cryptoState?.counter ?? 0,
      currentCursor: _syncCursor,
    );
    final nextMessages = <String, List<ReceivedMessageEnvelope>>{
      for (final entry in _snapshot?.messagesByConversation.entries ??
          const <MapEntry<String, List<ReceivedMessageEnvelope>>>[])
        entry.key: List<ReceivedMessageEnvelope>.from(entry.value),
    };
    final deletedIds = transition.deletedEnvelopeIds.toSet();
    for (final entry in nextMessages.entries) {
      entry.value.removeWhere((message) => deletedIds.contains(message.id));
    }
    for (final envelope in transition.upsertedEnvelopes) {
      final messages =
          nextMessages[envelope.conversationId] ??= <ReceivedMessageEnvelope>[];
      messages.removeWhere((message) => message.id == envelope.id);
      messages.add(envelope);
    }
    _cryptoState = _copyCryptoState(transition.state);
    _processedMlsMessages.add(transition.messageId);
    _syncCursor = transition.cursor;
    _snapshot = CachedSnapshot(
      cursor: transition.cursor,
      conversations: _snapshot?.conversations ?? const <Conversation>[],
      messagesByConversation: nextMessages,
    );
  }

  @override
  Future<bool> hasProcessedMlsMessage(String messageId) async =>
      _processedMlsMessages.contains(messageId);

  @override
  Future<void> commitOutgoingMlsTransition(
      OutgoingMlsStateTransition transition) async {
    _validateOutgoingMlsTransition(
      transition,
      currentCounter: _cryptoState?.counter ?? 0,
      currentCursor: _syncCursor,
    );
    if (transition.messages
        .any((message) => _mlsOutbox.containsKey(message.idempotencyKey))) {
      throw StateError('duplicate MLS outbox idempotency key');
    }
    _cryptoState = _copyCryptoState(transition.state);
    for (final message in transition.messages) {
      _mlsOutbox[message.idempotencyKey] = message;
    }
  }

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async =>
      _mlsOutbox.values.toList(growable: false);

  @override
  Future<void> removePendingMlsMessage(String idempotencyKey) async {
    _mlsOutbox.remove(idempotencyKey);
  }

  @override
  Future<void> commitOutgoingApplicationTransition(
      OutgoingApplicationStateTransition transition) async {
    _validateOutgoingApplicationTransition(
      transition,
      currentCounter: _cryptoState?.counter ?? 0,
      currentCursor: _syncCursor,
    );
    _cryptoState = _copyCryptoState(transition.state);
    _outbox.removeWhere(
        (item) => item.idempotencyKey == transition.envelope.idempotencyKey);
    _outbox.add(transition.envelope);
    _outboxRecords[transition.envelope.idempotencyKey] = PendingEnvelopeRecord(
        envelope: transition.envelope, attemptCount: 0, terminal: false);
  }

  @override
  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
  }) async {
    _validateLocalMlsState(expectedCounter, expectedCursor, state,
        currentCounter: _cryptoState?.counter ?? 0, currentCursor: _syncCursor);
    _cryptoState = _copyCryptoState(state);
  }

  @override
  Future<StoredCryptoState?> loadCryptoState() async =>
      _cryptoState == null ? null : _copyCryptoState(_cryptoState!);

  @override
  Future<List<int>> exportBackup() async {
    final activeSession = _session;
    final state = _cryptoState;
    if (activeSession == null || state == null) {
      throw StateError('complete authenticated crypto state is required');
    }
    return _encodeBackup(LocalBackupData(
      session: activeSession,
      cursor: _syncCursor,
      conversations: _snapshot?.conversations ?? const <Conversation>[],
      messages: _snapshot?.messagesByConversation ??
          const <String, List<ReceivedMessageEnvelope>>{},
      outbox: List<MessageEnvelope>.from(_outbox),
      mlsOutbox: _mlsOutbox.values.toList(growable: false),
      cryptoState: _copyCryptoState(state),
    ));
  }

  @override
  Future<void> restoreBackup(List<int> encoded) async {
    final backup = _decodeBackup(encoded);
    if (_cryptoState != null &&
        backup.cryptoState.counter < _cryptoState!.counter) {
      throw StateError('backup would roll MLS state backward');
    }
    _session = backup.session;
    _syncCursor = backup.cursor;
    _snapshot = CachedSnapshot(
        cursor: backup.cursor,
        conversations: backup.conversations,
        messagesByConversation: backup.messages);
    _outbox
      ..clear()
      ..addAll(backup.outbox);
    _outboxRecords
      ..clear()
      ..addEntries(backup.outbox.map((item) => MapEntry(
          item.idempotencyKey,
          PendingEnvelopeRecord(
              envelope: item, attemptCount: 0, terminal: false))));
    _mlsOutbox
      ..clear()
      ..addEntries(
          backup.mlsOutbox.map((item) => MapEntry(item.idempotencyKey, item)));
    _cryptoState = _copyCryptoState(backup.cryptoState);
    _processedMlsMessages.clear();
  }

  @override
  Future<void> savePeerVerification(String conversationId, String peerAccountId,
      List<int> transcriptHash) async {
    _validatePeerVerification(conversationId, peerAccountId, transcriptHash);
    _peerVerifications['$conversationId\u0000$peerAccountId'] =
        List<int>.from(transcriptHash);
  }

  @override
  Future<List<int>?> loadPeerVerification(
      String conversationId, String peerAccountId) async {
    final value = _peerVerifications['$conversationId\u0000$peerAccountId'];
    return value == null ? null : List<int>.from(value);
  }

  @override
  Future<void> clearCachedState() async {
    _syncCursor = 0;
    _snapshot = null;
    _outbox.clear();
    _outboxRecords.clear();
  }

  @override
  Future<void> clear() async {
    _session = null;
    _cryptoState = null;
    _processedMlsMessages.clear();
    _mlsOutbox.clear();
    _peerVerifications.clear();
    await clearCachedState();
  }
}

typedef LocalDatabaseFactory = EncryptedLocalDatabase Function(
  File file,
  String keyHex,
);

/// Stores growing local state in an encrypted transactional database. Secure
/// storage contains only the device-bound database key and a one-time legacy
/// record during migration.
class SecureLocalStore implements LocalStore {
  SecureLocalStore({
    FlutterSecureStorage? storage,
    Future<Directory> Function()? directoryProvider,
    LocalDatabaseFactory? databaseFactory,
    MlsCommitFailureInjector? mlsCommitFailureInjector,
  })  : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                resetOnError: true,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            ),
        _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory,
        _databaseFactory = databaseFactory ?? openEncryptedLocalDatabase,
        _mlsCommitFailureInjector = mlsCommitFailureInjector;

  static const _legacyRecordKey = 'veritra.account_state.v2';
  static const _databaseKey = 'veritra.database_key.v1';
  static const _migrationMarker = 'legacy_secure_record_migrated';
  static const _maxCachedConversations = 20;
  static const _maxMessagesPerConversation = 200;
  static const _maxPendingEnvelopes = 100;
  final FlutterSecureStorage _storage;
  final Future<Directory> Function() _directoryProvider;
  final LocalDatabaseFactory _databaseFactory;
  final MlsCommitFailureInjector? _mlsCommitFailureInjector;
  Future<EncryptedLocalDatabase>? _openingDatabase;
  String? _databasePath;

  @override
  Future<void> saveSession(Session session) async {
    final database = await _database();
    final previous = _sessionFromJson(await database.readSessionJson());
    await database.writeSessionJson(
      jsonEncode(_sessionJson(session)),
      clearIdentityState:
          previous != null && _identity(previous) != _identity(session),
    );
  }

  @override
  Future<Session?> loadSession() async {
    return _sessionFromJson(await (await _database()).readSessionJson());
  }

  @override
  Future<void> saveSyncCursor(int eventId) async {
    if (eventId < 0) throw const FormatException('invalid sync cursor');
    await (await _database()).writeCursor(eventId);
  }

  @override
  Future<int> loadSyncCursor() async => (await _database()).readCursor();

  @override
  Future<void> saveSnapshot(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
    int cursor,
  ) async {
    if (cursor < 0) throw const FormatException('invalid sync cursor');
    final boundedConversations =
        conversations.take(_maxCachedConversations).toList(growable: false);
    final conversationIds = boundedConversations.map((item) => item.id).toSet();
    await (await _database()).replaceSnapshot(
      conversations: boundedConversations.map(
        (item) => (id: item.id, payloadJson: jsonEncode(item.toJson())),
      ),
      envelopes: <({
        String id,
        String conversationId,
        int position,
        String payloadJson,
      })>[
        for (final entry in messagesByConversation.entries)
          if (conversationIds.contains(entry.key))
            for (final indexed in entry.value
                .take(_maxMessagesPerConversation)
                .toList(growable: false)
                .indexed)
              (
                id: indexed.$2.id,
                conversationId: entry.key,
                position: indexed.$1,
                payloadJson: jsonEncode(indexed.$2.toJson()),
              ),
      ],
      cursor: cursor,
    );
  }

  @override
  Future<CachedSnapshot?> loadSnapshot() async {
    final raw = await (await _database()).readSnapshotJson();
    if (raw.conversationJson.isEmpty) return null;
    try {
      final conversations = raw.conversationJson
          .map((item) => Conversation.fromJson(_decodeJsonMap(item)))
          .toList();
      final messages = <String, List<ReceivedMessageEnvelope>>{};
      for (final entry in raw.envelopeJson.entries) {
        messages[entry.key] = entry.value
            .map((item) =>
                ReceivedMessageEnvelope.fromJson(_decodeJsonMap(item)))
            .toList();
      }
      return CachedSnapshot(
        cursor: raw.cursor,
        conversations: conversations,
        messagesByConversation: messages,
      );
    } catch (_) {
      throw StateError('encrypted local snapshot is corrupt');
    }
  }

  @override
  Future<void> enqueueEnvelope(MessageEnvelope envelope) async {
    final database = await _database();
    final path = _databasePath;
    if (path == null) throw StateError('encrypted database path unavailable');
    await _serializeDatabaseWrite(path, () async {
      await database.upsertOutbox(
        idempotencyKey: envelope.idempotencyKey,
        conversationId: envelope.conversationId,
        payloadJson: jsonEncode(envelope.toJson()),
        queuedAt: DateTime.now().microsecondsSinceEpoch,
        maxEntries: _maxPendingEnvelopes,
      );
    });
  }

  @override
  Future<List<MessageEnvelope>> pendingEnvelopes() async =>
      (await (await _database()).readOutboxJson())
          .map((item) => MessageEnvelope.fromJson(_decodeJsonMap(item)))
          .toList();

  @override
  Future<List<PendingEnvelopeRecord>> pendingEnvelopeRecords() async =>
      (await (await _database()).readOutboxRecords())
          .map((item) => PendingEnvelopeRecord(
                envelope:
                    MessageEnvelope.fromJson(_decodeJsonMap(item.payloadJson)),
                attemptCount: item.attemptCount,
                terminal: item.terminal,
                nextAttemptAt: item.nextAttemptAt == null
                    ? null
                    : DateTime.fromMicrosecondsSinceEpoch(item.nextAttemptAt!,
                        isUtc: true),
                failureClass: item.failureClass,
              ))
          .toList(growable: false);

  @override
  Future<void> recordOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  }) async {
    await (await _database()).markOutboxFailure(idempotencyKey,
        failureClass: failureClass,
        terminal: terminal,
        nextAttemptAt: nextAttemptAt?.toUtc().microsecondsSinceEpoch);
  }

  @override
  Future<void> removePendingEnvelope(String idempotencyKey) async {
    await (await _database()).deleteOutbox(idempotencyKey);
  }

  @override
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor) async {
    _validateCryptoState(state);
    if (syncCursor < 0) throw const FormatException('invalid sync cursor');
    await (await _database()).writeCryptoState(
      counter: state.counter,
      stateKey: state.stateKey,
      sealedState: state.sealedState,
      cursor: syncCursor,
    );
  }

  @override
  Future<void> commitMlsTransition(MlsStateTransition transition) async {
    _validateCryptoState(transition.state);
    _validateMlsTransition(
      transition,
      currentCounter: transition.expectedCounter,
      currentCursor: transition.expectedCursor,
    );
    await (await _database()).commitMlsTransition(
      messageId: transition.messageId,
      conversationId: transition.conversationId,
      expectedCounter: transition.expectedCounter,
      expectedCursor: transition.expectedCursor,
      counter: transition.state.counter,
      stateKey: transition.state.stateKey,
      sealedState: transition.state.sealedState,
      cursor: transition.cursor,
      upsertedEnvelopes: transition.upsertedEnvelopes
          .map((envelope) => (
                id: envelope.id,
                conversationId: envelope.conversationId,
                payloadJson: jsonEncode(envelope.toJson()),
              ))
          .toList(growable: false),
      deletedEnvelopeIds: transition.deletedEnvelopeIds,
      failureInjector: _mlsCommitFailureInjector,
    );
  }

  @override
  Future<bool> hasProcessedMlsMessage(String messageId) async =>
      (await _database()).hasProcessedMlsMessage(messageId);

  @override
  Future<void> commitOutgoingMlsTransition(
      OutgoingMlsStateTransition transition) async {
    _validateOutgoingMlsTransition(
      transition,
      currentCounter: transition.expectedCounter,
      currentCursor: transition.expectedCursor,
    );
    await (await _database()).commitOutgoingMlsTransition(
      expectedCounter: transition.expectedCounter,
      expectedCursor: transition.expectedCursor,
      counter: transition.state.counter,
      stateKey: transition.state.stateKey,
      sealedState: transition.state.sealedState,
      messages: transition.messages
          .map((message) => (
                idempotencyKey: message.idempotencyKey,
                conversationId: message.conversationId,
                kind: message.kind,
                recipientDeviceId: message.recipientDeviceId,
                revocationDeviceId: message.revocationDeviceId,
                payload: message.payload,
              ))
          .toList(growable: false),
    );
  }

  @override
  Future<List<PendingMlsMessage>> pendingMlsMessages() async =>
      (await (await _database()).readMlsOutbox())
          .map((message) => PendingMlsMessage(
                idempotencyKey: message.idempotencyKey,
                conversationId: message.conversationId,
                kind: message.kind,
                recipientDeviceId: message.recipientDeviceId,
                revocationDeviceId: message.revocationDeviceId,
                payload: message.payload,
              ))
          .toList(growable: false);

  @override
  Future<void> removePendingMlsMessage(String idempotencyKey) async {
    await (await _database()).deleteMlsOutbox(idempotencyKey);
  }

  @override
  Future<void> commitOutgoingApplicationTransition(
      OutgoingApplicationStateTransition transition) async {
    _validateOutgoingApplicationTransition(
      transition,
      currentCounter: transition.expectedCounter,
      currentCursor: transition.expectedCursor,
    );
    await (await _database()).commitOutgoingApplicationTransition(
      expectedCounter: transition.expectedCounter,
      expectedCursor: transition.expectedCursor,
      counter: transition.state.counter,
      stateKey: transition.state.stateKey,
      sealedState: transition.state.sealedState,
      idempotencyKey: transition.envelope.idempotencyKey,
      conversationId: transition.envelope.conversationId,
      payloadJson: jsonEncode(transition.envelope.toJson()),
      maxEntries: _maxPendingEnvelopes,
    );
  }

  @override
  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
  }) async {
    _validateLocalMlsState(expectedCounter, expectedCursor, state,
        currentCounter: expectedCounter, currentCursor: expectedCursor);
    await (await _database()).commitLocalMlsState(
      expectedCounter: expectedCounter,
      expectedCursor: expectedCursor,
      counter: state.counter,
      stateKey: state.stateKey,
      sealedState: state.sealedState,
    );
  }

  @override
  Future<StoredCryptoState?> loadCryptoState() async {
    final row = await (await _database()).readCryptoState();
    if (row == null) return null;
    final state = StoredCryptoState(
      counter: row.counter,
      stateKey: row.stateKey,
      sealedState: row.sealedState,
    );
    _validateCryptoState(state);
    return state;
  }

  @override
  Future<List<int>> exportBackup() async {
    final activeSession = await loadSession();
    final snapshot = await loadSnapshot();
    final state = await loadCryptoState();
    if (activeSession == null || state == null) {
      throw StateError('complete authenticated crypto state is required');
    }
    return _encodeBackup(LocalBackupData(
      session: activeSession,
      cursor: await loadSyncCursor(),
      conversations: snapshot?.conversations ?? const <Conversation>[],
      messages: snapshot?.messagesByConversation ??
          const <String, List<ReceivedMessageEnvelope>>{},
      outbox: await pendingEnvelopes(),
      mlsOutbox: await pendingMlsMessages(),
      cryptoState: state,
    ));
  }

  @override
  Future<void> restoreBackup(List<int> encoded) async {
    final backup = _decodeBackup(encoded);
    final current = await loadCryptoState();
    if (current != null && backup.cryptoState.counter < current.counter) {
      throw StateError('backup would roll MLS state backward');
    }
    await (await _database()).restoreBackupState(
      sessionJson: jsonEncode(_sessionJson(backup.session)),
      conversations: backup.conversations
          .map((item) => (id: item.id, payloadJson: jsonEncode(item.toJson())))
          .toList(),
      envelopes: <({
        String id,
        String conversationId,
        int position,
        String payloadJson
      })>[
        for (final entry in backup.messages.entries)
          for (var index = 0; index < entry.value.length; index++)
            (
              id: entry.value[index].id,
              conversationId: entry.key,
              position: index,
              payloadJson: jsonEncode(entry.value[index].toJson())
            ),
      ],
      outbox: backup.outbox
          .map((item) => (
                idempotencyKey: item.idempotencyKey,
                conversationId: item.conversationId,
                payloadJson: jsonEncode(item.toJson()),
              ))
          .toList(),
      mlsOutbox: backup.mlsOutbox
          .map((item) => (
                idempotencyKey: item.idempotencyKey,
                conversationId: item.conversationId,
                kind: item.kind,
                recipientDeviceId: item.recipientDeviceId,
                revocationDeviceId: item.revocationDeviceId,
                payload: item.payload,
              ))
          .toList(),
      cryptoState: (
        counter: backup.cryptoState.counter,
        stateKey: backup.cryptoState.stateKey,
        sealedState: backup.cryptoState.sealedState
      ),
      cursor: backup.cursor,
    );
  }

  @override
  Future<void> savePeerVerification(String conversationId, String peerAccountId,
      List<int> transcriptHash) async {
    _validatePeerVerification(conversationId, peerAccountId, transcriptHash);
    await (await _database()).savePeerVerification(
        conversationId,
        peerAccountId,
        transcriptHash,
        DateTime.now().toUtc().microsecondsSinceEpoch);
  }

  @override
  Future<List<int>?> loadPeerVerification(
          String conversationId, String peerAccountId) =>
      _database().then((database) =>
          database.readPeerVerification(conversationId, peerAccountId));

  @override
  Future<void> clearCachedState() async {
    await (await _database()).clearCachedState();
  }

  @override
  Future<void> clear() async {
    await (await _database()).clearAll();
    await _storage.delete(key: _legacyRecordKey);
  }

  Future<EncryptedLocalDatabase> _database() =>
      _openingDatabase ??= _openDatabase();

  Future<EncryptedLocalDatabase> _openDatabase() async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final databaseFile =
        File('${directory.path}${Platform.pathSeparator}veritra-local.db');
    final path = databaseFile.absolute.path;
    _databasePath = path;
    final previous = _databaseOpenTails[path] ?? Future<void>.value();
    final release = Completer<void>();
    final current = previous.then((_) => release.future);
    _databaseOpenTails[path] = current;
    await previous;
    try {
      return await _openDatabaseLocked(directory, databaseFile);
    } finally {
      release.complete();
      if (identical(_databaseOpenTails[path], current)) {
        _databaseOpenTails.remove(path);
      }
    }
  }

  Future<EncryptedLocalDatabase> _openDatabaseLocked(
      Directory directory, File databaseFile) async {
    final lockFile =
        File('${directory.path}${Platform.pathSeparator}veritra-local.lock');
    final lock = await lockFile.open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    try {
      var keyHex = await _storage.read(key: _databaseKey);
      if (keyHex == null) {
        keyHex = _randomHexKey();
        await _storage.write(key: _databaseKey, value: keyHex);
      }
      final storedKey = await _storage.read(key: _databaseKey);
      if (storedKey != keyHex ||
          storedKey == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(storedKey)) {
        throw StateError('encrypted database key verification failed');
      }
      final database = _databaseFactory(databaseFile, storedKey);
      await database.readCursor();
      await _migrateLegacyRecord(database);
      return database;
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  Future<void> _migrateLegacyRecord(EncryptedLocalDatabase database) async {
    final raw = await _storage.read(key: _legacyRecordKey);
    if (await database.readMetadata(_migrationMarker) == '1') {
      if (raw != null) await _storage.delete(key: _legacyRecordKey);
      return;
    }
    if (raw == null || raw.isEmpty) {
      await database.writeMetadata(_migrationMarker, '1');
      return;
    }

    final legacy = _parseLegacyRecord(raw);
    await database.importLegacy(
      sessionJson: legacy.sessionJson,
      conversations: legacy.conversations,
      envelopes: legacy.envelopes,
      outbox: legacy.outbox,
      cryptoState: legacy.cryptoState,
      cursor: legacy.cursor,
    );
    await _verifyLegacyMigration(database, legacy);
    await database.writeMetadata(_migrationMarker, '1');
    await _storage.delete(key: _legacyRecordKey);
  }

  Future<void> _verifyLegacyMigration(
    EncryptedLocalDatabase database,
    _LegacyDatabasePayload legacy,
  ) async {
    if (await database.readSessionJson() != legacy.sessionJson ||
        await database.readCursor() != legacy.cursor) {
      throw StateError('legacy local-state migration verification failed');
    }
    final snapshot = await database.readSnapshotJson();
    if (!_stringListsEqual(
          snapshot.conversationJson,
          legacy.conversations.map((item) => item.payloadJson).toList(),
        ) ||
        !_stringMapListsEqual(
          snapshot.envelopeJson,
          _legacyEnvelopeMap(legacy.envelopes),
        ) ||
        !_stringListsEqual(
          await database.readOutboxJson(),
          legacy.outbox.map((item) => item.payloadJson).toList(),
        )) {
      throw StateError('legacy local-state migration verification failed');
    }
    final crypto = await database.readCryptoState();
    if (!_cryptoRecordsEqual(crypto, legacy.cryptoState)) {
      throw StateError('legacy local-state migration verification failed');
    }
  }
}

typedef _StoredConversation = ({String id, String payloadJson});
typedef _StoredEnvelope = ({
  String id,
  String conversationId,
  int position,
  String payloadJson,
});
typedef _StoredOutboxEntry = ({
  String idempotencyKey,
  String conversationId,
  int queuedAt,
  String payloadJson,
});
typedef _StoredCryptoRecord = ({
  int counter,
  List<int> stateKey,
  List<int> sealedState,
});

class _LegacyDatabasePayload {
  const _LegacyDatabasePayload({
    required this.sessionJson,
    required this.conversations,
    required this.envelopes,
    required this.outbox,
    required this.cryptoState,
    required this.cursor,
  });

  final String? sessionJson;
  final List<_StoredConversation> conversations;
  final List<_StoredEnvelope> envelopes;
  final List<_StoredOutboxEntry> outbox;
  final _StoredCryptoRecord? cryptoState;
  final int cursor;
}

_LegacyDatabasePayload _parseLegacyRecord(String raw) {
  try {
    final record = Map<String, Object?>.from(jsonDecode(raw) as Map);
    final cursor = (record['cursor'] as num?)?.toInt() ?? 0;
    if (cursor < 0) throw const FormatException('invalid cursor');

    String? sessionJson;
    final rawSession = record['session'];
    if (rawSession != null) {
      final sessionMap = Map<String, Object?>.from(rawSession as Map);
      if (_sessionFrom(sessionMap) == null) {
        throw const FormatException('invalid session');
      }
      sessionJson = jsonEncode(sessionMap);
    }

    final conversations = <_StoredConversation>[];
    final envelopes = <_StoredEnvelope>[];
    final rawSnapshot = record['snapshot'];
    if (rawSnapshot != null) {
      final snapshot = Map<String, Object?>.from(rawSnapshot as Map);
      for (final item in snapshot['conversations'] as List? ?? const []) {
        final payload = Map<String, Object?>.from(item as Map);
        final conversation = Conversation.fromJson(payload);
        conversations.add((
          id: conversation.id,
          payloadJson: jsonEncode(payload),
        ));
      }
      final rawMessages = snapshot['messages'];
      if (rawMessages != null) {
        final messages = Map<Object?, Object?>.from(rawMessages as Map);
        for (final entry in messages.entries) {
          final conversationId = entry.key.toString();
          var position = 0;
          for (final item in entry.value as List) {
            final payload = Map<String, Object?>.from(item as Map);
            final envelope = ReceivedMessageEnvelope.fromJson(payload);
            envelopes.add((
              id: envelope.id,
              conversationId: conversationId,
              position: position++,
              payloadJson: jsonEncode(payload),
            ));
          }
        }
      }
    }

    final outbox = <_StoredOutboxEntry>[];
    var queuedAt = 0;
    for (final item in record['outbox'] as List? ?? const []) {
      final payload = Map<String, Object?>.from(item as Map);
      final envelope = MessageEnvelope.fromJson(payload);
      outbox.add((
        idempotencyKey: envelope.idempotencyKey,
        conversationId: envelope.conversationId,
        queuedAt: queuedAt++,
        payloadJson: jsonEncode(payload),
      ));
    }

    _StoredCryptoRecord? cryptoState;
    if (record.containsKey('crypto_state')) {
      final parsed = _cryptoStateFrom(record['crypto_state']);
      if (parsed == null) throw const FormatException('invalid crypto state');
      cryptoState = (
        counter: parsed.counter,
        stateKey: parsed.stateKey,
        sealedState: parsed.sealedState,
      );
    }
    return _LegacyDatabasePayload(
      sessionJson: sessionJson,
      conversations: conversations,
      envelopes: envelopes,
      outbox: outbox,
      cryptoState: cryptoState,
      cursor: cursor,
    );
  } catch (_) {
    throw StateError('legacy local state is corrupt');
  }
}

Session? _sessionFromJson(String? raw) {
  if (raw == null) return null;
  return _sessionFrom(_decodeJsonMap(raw));
}

Map<String, Object?> _decodeJsonMap(String raw) =>
    Map<String, Object?>.from(jsonDecode(raw) as Map);

String _randomHexKey() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var index = 0; index < 32; index++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Map<String, List<String>> _legacyEnvelopeMap(
  Iterable<_StoredEnvelope> envelopes,
) {
  final result = <String, List<String>>{};
  for (final envelope in envelopes) {
    (result[envelope.conversationId] ??= <String>[]).add(envelope.payloadJson);
  }
  return result;
}

bool _stringListsEqual(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _stringMapListsEqual(
  Map<String, List<String>> left,
  Map<String, List<String>> right,
) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    final expected = right[entry.key];
    if (expected == null || !_stringListsEqual(entry.value, expected)) {
      return false;
    }
  }
  return true;
}

bool _cryptoRecordsEqual(
  ({int counter, List<int> stateKey, List<int> sealedState})? left,
  _StoredCryptoRecord? right,
) {
  if (left == null || right == null) return left == null && right == null;
  return left.counter == right.counter &&
      _bytesEqual(left.stateKey, right.stateKey) &&
      _bytesEqual(left.sealedState, right.sealedState);
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

String _identity(Session session) =>
    '${session.baseUrl}|${session.accountId ?? ''}|${session.deviceId ?? ''}';

Map<String, Object?> _sessionJson(Session session) => <String, Object?>{
      'base_url': session.baseUrl,
      'token': session.token,
      if (session.accountId != null) 'account_id': session.accountId,
      if (session.deviceId != null) 'device_id': session.deviceId,
      if (session.username != null) 'username': session.username,
      if (session.deviceSecret != null) 'device_secret': session.deviceSecret,
      if (session.role != null) 'role': session.role,
    };

Session? _sessionFrom(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  final session = Map<String, Object?>.from(raw);
  final baseUrl = session['base_url'] as String?;
  final token = session['token'] as String?;
  if (baseUrl == null || token == null) {
    return null;
  }
  return Session(
    baseUrl: baseUrl,
    token: token,
    accountId: session['account_id'] as String?,
    deviceId: session['device_id'] as String?,
    username: session['username'] as String?,
    deviceSecret: session['device_secret'] as String?,
    role: session['role'] as String?,
  );
}

StoredCryptoState? _cryptoStateFrom(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  try {
    final json = Map<String, Object?>.from(raw);
    final state = StoredCryptoState(
      counter: (json['counter'] as num).toInt(),
      stateKey: base64Decode(json['state_key'] as String),
      sealedState: base64Decode(json['sealed_state'] as String),
    );
    _validateCryptoState(state);
    return state;
  } catch (_) {
    return null;
  }
}

StoredCryptoState _copyCryptoState(StoredCryptoState state) =>
    StoredCryptoState(
      counter: state.counter,
      stateKey: List<int>.from(state.stateKey),
      sealedState: List<int>.from(state.sealedState),
    );

List<int> _encodeBackup(LocalBackupData data) => utf8.encode(jsonEncode(
      <String, Object?>{
        'version': 1,
        'account_id': data.session.accountId,
        'device_id': data.session.deviceId,
        'session': _sessionJson(data.session),
        'cursor': data.cursor,
        'conversations':
            data.conversations.map((item) => item.toJson()).toList(),
        'messages': <String, Object?>{
          for (final entry in data.messages.entries)
            entry.key: entry.value.map((item) => item.toJson()).toList(),
        },
        'outbox': data.outbox.map((item) => item.toJson()).toList(),
        'mls_outbox': data.mlsOutbox
            .map((item) => <String, Object?>{
                  'idempotency_key': item.idempotencyKey,
                  'conversation_id': item.conversationId,
                  'kind': item.kind,
                  if (item.recipientDeviceId != null)
                    'recipient_device_id': item.recipientDeviceId,
                  if (item.revocationDeviceId != null)
                    'revocation_device_id': item.revocationDeviceId,
                  'payload': base64Encode(item.payload),
                })
            .toList(),
        'crypto_state': <String, Object?>{
          'counter': data.cryptoState.counter,
          'state_key': base64Encode(data.cryptoState.stateKey),
          'sealed_state': base64Encode(data.cryptoState.sealedState),
        },
      },
    ));

LocalBackupData _decodeBackup(List<int> encoded) {
  if (encoded.isEmpty || encoded.length > 64 * 1024 * 1024) {
    throw const FormatException('invalid backup size');
  }
  try {
    final root = Map<String, Object?>.from(
        jsonDecode(utf8.decode(encoded, allowMalformed: false)) as Map);
    if (root['version'] != 1)
      throw const FormatException('unsupported backup version');
    final session = _sessionFrom(root['session']);
    final crypto = _cryptoStateFrom(root['crypto_state']);
    if (session == null ||
        crypto == null ||
        session.accountId == null ||
        session.deviceId == null ||
        root['account_id'] != session.accountId ||
        root['device_id'] != session.deviceId) {
      throw const FormatException('backup identity binding mismatch');
    }
    final conversations = (root['conversations'] as List)
        .map((item) =>
            Conversation.fromJson(Map<String, Object?>.from(item as Map)))
        .toList(growable: false);
    final messages = <String, List<ReceivedMessageEnvelope>>{};
    for (final entry
        in Map<String, Object?>.from(root['messages'] as Map).entries) {
      messages[entry.key] = (entry.value as List)
          .map((item) => ReceivedMessageEnvelope.fromJson(
              Map<String, Object?>.from(item as Map)))
          .toList(growable: false);
    }
    final outbox = (root['outbox'] as List)
        .map((item) =>
            MessageEnvelope.fromJson(Map<String, Object?>.from(item as Map)))
        .toList(growable: false);
    final mlsOutbox = (root['mls_outbox'] as List).map((item) {
      final value = Map<String, Object?>.from(item as Map);
      return PendingMlsMessage(
        idempotencyKey: value['idempotency_key'] as String,
        conversationId: value['conversation_id'] as String,
        kind: value['kind'] as String,
        recipientDeviceId: value['recipient_device_id'] as String?,
        revocationDeviceId: value['revocation_device_id'] as String?,
        payload: base64Decode(value['payload'] as String),
      );
    }).toList(growable: false);
    final cursor = (root['cursor'] as num).toInt();
    if (cursor < 0) throw const FormatException('invalid backup cursor');
    return LocalBackupData(
        session: session,
        cursor: cursor,
        conversations: conversations,
        messages: messages,
        outbox: outbox,
        mlsOutbox: mlsOutbox,
        cryptoState: crypto);
  } catch (error) {
    if (error is FormatException) rethrow;
    throw const FormatException('invalid backup encoding');
  }
}

void _validateCryptoState(StoredCryptoState state) {
  if (state.counter <= 0 ||
      state.stateKey.length != 32 ||
      state.sealedState.isEmpty ||
      state.sealedState.length > 32 * 1024 * 1024) {
    throw const FormatException('invalid protected crypto state');
  }
}

void _validatePeerVerification(
    String conversationId, String peerAccountId, List<int> transcriptHash) {
  if (conversationId.isEmpty ||
      peerAccountId.isEmpty ||
      conversationId.length > 128 ||
      peerAccountId.length > 128 ||
      transcriptHash.length != 32) {
    throw const FormatException('invalid peer verification state');
  }
}

void _validateMlsTransition(
  MlsStateTransition transition, {
  required int currentCounter,
  required int currentCursor,
}) {
  _validateCryptoState(transition.state);
  if (transition.expectedCounter != currentCounter ||
      transition.expectedCursor != currentCursor ||
      transition.state.counter != currentCounter + 1 ||
      transition.cursor <= currentCursor) {
    throw StateError('stale or incomplete MLS state transition');
  }
  if (transition.messageId.isEmpty || transition.conversationId.isEmpty) {
    throw const FormatException('invalid MLS transition binding');
  }
  final deleted = transition.deletedEnvelopeIds.toSet();
  if (deleted.length != transition.deletedEnvelopeIds.length ||
      deleted.any((id) => id.isEmpty) ||
      transition.upsertedEnvelopes.any(
        (envelope) => envelope.id.isEmpty || deleted.contains(envelope.id),
      )) {
    throw const FormatException('invalid MLS ciphertext transition');
  }
}

void _validateOutgoingMlsTransition(
  OutgoingMlsStateTransition transition, {
  required int currentCounter,
  required int currentCursor,
}) {
  _validateCryptoState(transition.state);
  if (transition.expectedCounter != currentCounter ||
      transition.expectedCursor != currentCursor ||
      transition.state.counter != currentCounter + 1 ||
      transition.messages.isEmpty) {
    throw StateError('stale or incomplete outgoing MLS transition');
  }
  final keys = <String>{};
  for (final message in transition.messages) {
    if (message.idempotencyKey.isEmpty ||
        !keys.add(message.idempotencyKey) ||
        message.conversationId.isEmpty ||
        (message.kind != 'welcome' && message.kind != 'commit') ||
        (message.kind == 'welcome' &&
            (message.recipientDeviceId?.isEmpty ?? true)) ||
        message.payload.isEmpty ||
        message.payload.length > 4 * 1024 * 1024) {
      throw const FormatException('invalid MLS outbox transition');
    }
  }
}

void _validateOutgoingApplicationTransition(
  OutgoingApplicationStateTransition transition, {
  required int currentCounter,
  required int currentCursor,
}) {
  _validateCryptoState(transition.state);
  if (transition.expectedCounter != currentCounter ||
      transition.expectedCursor != currentCursor ||
      transition.state.counter != currentCounter + 1 ||
      transition.envelope.idempotencyKey.isEmpty ||
      transition.envelope.conversationId.isEmpty ||
      transition.envelope.ciphertext.isEmpty) {
    throw StateError('stale or incomplete outgoing application transition');
  }
}

void _validateLocalMlsState(
  int expectedCounter,
  int expectedCursor,
  StoredCryptoState state, {
  required int currentCounter,
  required int currentCursor,
}) {
  _validateCryptoState(state);
  if (expectedCounter != currentCounter ||
      expectedCursor != currentCursor ||
      state.counter != currentCounter + 1) {
    throw StateError('stale local MLS transition');
  }
}
