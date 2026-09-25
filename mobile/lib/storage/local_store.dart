import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../sync/sync_recovery.dart';
import 'encrypted_database.dart';

final Map<String, Future<void>> _databaseOpenTails = <String, Future<void>>{};
final Map<String, Future<void>> _databaseWriteTails = <String, Future<void>>{};
final Map<String, RandomAccessFile> _instanceLocks =
    <String, RandomAccessFile>{};

const int maxPendingEnvelopes = 100;

class OutboxFullException implements Exception {
  const OutboxFullException();

  @override
  String toString() =>
      'The encrypted message queue is full. Send or discard a pending message first.';
}

/// Why the encrypted local database could not be opened (card I39).
enum LocalStoreFailureKind {
  /// Another window holds this profile.
  profileLocked,

  /// Secure storage could not be read (for example, the device is locked or
  /// the keystore refused). Retrying later may work.
  keyUnavailable,

  /// The database exists but its key is gone.
  keyMissing,

  /// The stored key is not a well-formed key.
  keyMalformed,

  /// The key did not open the database: it is the wrong key, or the file
  /// is damaged.
  keyRejected,

  /// Writing a new key could not be confirmed.
  keyWriteFailed,
}

/// The local database stays closed and untouched. Nothing is reset without
/// an explicit, confirmed [LocalStore.quarantineUnreadableDatabase].
class LocalStoreUnavailableException implements Exception {
  const LocalStoreUnavailableException(this.kind);

  final LocalStoreFailureKind kind;

  /// Only these may succeed on a plain retry.
  bool get retryable =>
      kind == LocalStoreFailureKind.profileLocked ||
      kind == LocalStoreFailureKind.keyUnavailable ||
      kind == LocalStoreFailureKind.keyWriteFailed;

  @override
  String toString() => 'LocalStoreUnavailableException(${kind.name})';
}

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
    this.messageEffects = const <MessageEffect>[],
    this.resolvedMlsOutboxKey,
  });

  /// An MLS outbox item that this transition settles, removed with it
  /// (card I51: this device's commit, merged when its echo arrives).
  final String? resolvedMlsOutboxKey;

  final String messageId;
  final String conversationId;
  final int expectedCounter;
  final int expectedCursor;
  final StoredCryptoState state;
  final int cursor;
  final List<ReceivedMessageEnvelope> upsertedEnvelopes;
  final List<String> deletedEnvelopeIds;

  /// Decrypted history changes, committed with [state] (D23).
  final List<MessageEffect> messageEffects;
}

class PendingMlsMessage {
  const PendingMlsMessage({
    required this.idempotencyKey,
    required this.conversationId,
    required this.kind,
    required this.payload,
    this.recipientDeviceId,
    this.revocationDeviceId,
    this.attemptCount = 0,
    this.nextAttemptAt,
    this.failureClass,
    this.terminal = false,
  });

  final String idempotencyKey;
  final String conversationId;
  final String kind;
  final String? recipientDeviceId;
  final String? revocationDeviceId;
  final List<int> payload;

  /// Delivery state (I34). A terminal item stays queued: it blocks its
  /// conversation instead of letting later MLS messages overtake it.
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? failureClass;
  final bool terminal;

  PendingMlsMessage withFailure({
    required String failureClass,
    required bool terminal,
    required DateTime? nextAttemptAt,
  }) =>
      PendingMlsMessage(
        idempotencyKey: idempotencyKey,
        conversationId: conversationId,
        kind: kind,
        payload: payload,
        recipientDeviceId: recipientDeviceId,
        revocationDeviceId: revocationDeviceId,
        attemptCount: attemptCount + 1,
        nextAttemptAt: nextAttemptAt,
        failureClass: failureClass,
        terminal: terminal,
      );
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
    this.draftText,
    this.messageEffects = const <MessageEffect>[],
  });

  final int expectedCounter;
  final int expectedCursor;
  final StoredCryptoState state;
  final MessageEnvelope envelope;
  final String? draftText;

  /// This device's own copy of what it sent, committed with [state] (D23).
  final List<MessageEffect> messageEffects;
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
    this.history = const <LocalMessage>[],
    this.reactions = const <LocalMessageReaction>[],
  });

  /// Decrypted history (D27). Empty in a version 1 backup.
  final List<LocalMessage> history;
  final List<LocalMessageReaction> reactions;

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
    this.draftText,
    this.nextAttemptAt,
    this.failureClass,
  });
  final MessageEnvelope envelope;
  final int attemptCount;
  final bool terminal;
  final DateTime? nextAttemptAt;
  final String? failureClass;
  final String? draftText;
}

class SyncEventCommit {
  const SyncEventCommit({
    required this.eventKey,
    required this.conversationId,
    required this.expectedCursor,
    required this.cursor,
    this.envelope,
    this.ownMessageKey,
  });

  final String eventKey;
  final String conversationId;
  final int expectedCursor;
  final int cursor;
  final ReceivedMessageEnvelope? envelope;

  /// Set when [envelope] is the server echo of a message this device sent:
  /// the local history record with this key is linked to the envelope.
  final String? ownMessageKey;
}

class LocalSyncLease {
  const LocalSyncLease({
    required this.origin,
    required this.accountId,
    required this.deviceId,
    required this.generation,
  });

  final String origin;
  final String accountId;
  final String deviceId;
  final int generation;

  String get key => '$origin\u0000$accountId\u0000$deviceId\u0000$generation';
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
  Future<void> saveProjection(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
  );
  Future<CachedSnapshot?> loadSnapshot();
  Future<void> enqueueEnvelope(MessageEnvelope envelope, {String? draftText});
  Future<bool> hasOutboxCapacity();
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
  Future<void> commitSyncEvent(SyncEventCommit commit);

  /// The durable recovery record (card I33), or null when sync may run.
  /// Pass null to clear it. It survives restarts so a failing event is not
  /// retried in a loop, and it is removed with the device identity.
  Future<void> saveSyncRecovery(SyncRecovery? recovery);
  Future<SyncRecovery?> loadSyncRecovery();

  /// When this device last made an encrypted backup (card I45).
  Future<void> saveLastBackupAt(DateTime at);
  Future<DateTime?> loadLastBackupAt();
  Future<void> acquireSyncLease(LocalSyncLease lease);
  Future<void> releaseSyncLease(LocalSyncLease lease);
  Future<bool> hasProcessedMlsMessage(String messageId);

  /// Whether the MLS control message with server ID [mlsMessageId] has been
  /// applied, whatever sync event carried it.
  Future<bool> hasAppliedMlsControlMessage(String mlsMessageId);
  Future<void> commitOutgoingMlsTransition(
      OutgoingMlsStateTransition transition);

  /// Pending MLS control messages in the order they must be delivered.
  Future<List<PendingMlsMessage>> pendingMlsMessages();
  Future<void> recordMlsOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  });
  Future<void> removePendingMlsMessage(String idempotencyKey);
  Future<void> commitOutgoingApplicationTransition(
      OutgoingApplicationStateTransition transition);

  /// Stores a local MLS state change. [resolvedMlsOutboxKey] names an MLS
  /// outbox item settled by the same change (a commit bundle the server
  /// accepted or refused, card I51); it is removed atomically.
  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    String? resolvedMlsOutboxKey,
  });
  Future<StoredCryptoState?> loadCryptoState();
  Future<List<int>> exportBackup();
  Future<void> restoreBackup(List<int> encoded);
  Future<void> savePeerVerification(
      String conversationId, String peerAccountId, List<int> transcriptHash);
  Future<List<int>?> loadPeerVerification(
      String conversationId, String peerAccountId);

  /// Decrypted history for one conversation, oldest first (D23).
  Future<List<LocalMessage>> loadMessages(String conversationId);
  Future<List<LocalMessageReaction>> loadReactions(String conversationId);
  Future<void> clearCachedState({bool preserveOutbox = false});
  Future<void> clear();

  /// The confirmed destructive reset for a database that cannot be opened
  /// (I39). The unreadable database is moved aside with its key, never
  /// deleted, and the next open starts a new, empty identity.
  Future<void> quarantineUnreadableDatabase({required bool confirmed});
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
  final _MemoryMessageHistory _history = _MemoryMessageHistory();
  String? _syncLeaseKey;
  SyncRecovery? _syncRecovery;
  DateTime? _lastBackupAt;

  @override
  Future<void> saveLastBackupAt(DateTime at) async =>
      _lastBackupAt = at.toUtc();

  @override
  Future<DateTime?> loadLastBackupAt() async => _lastBackupAt;

  @override
  Future<void> saveSyncRecovery(SyncRecovery? recovery) async {
    _syncRecovery = recovery;
  }

  @override
  Future<SyncRecovery?> loadSyncRecovery() async => _syncRecovery;

  @override
  Future<void> acquireSyncLease(LocalSyncLease lease) async {
    _syncLeaseKey = lease.key;
  }

  @override
  Future<void> releaseSyncLease(LocalSyncLease lease) async {
    if (_syncLeaseKey == lease.key) _syncLeaseKey = null;
  }

  @override
  Future<void> saveSession(Session session) async {
    if (_session != null && _identity(_session!) != _identity(session)) {
      await clearCachedState();
      _cryptoState = null;
      _processedMlsMessages.clear();
      _mlsOutbox.clear();
      _peerVerifications.clear();
      _history.clear();
      _syncLeaseKey = null;
      _syncRecovery = null;
      _lastBackupAt = null;
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
    if (cursor < _syncCursor) return;
    final retainedCursor = cursor;
    _syncCursor = retainedCursor;
    _snapshot = CachedSnapshot(
      cursor: retainedCursor,
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
  Future<void> saveProjection(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
  ) async {
    final cursor = _syncCursor;
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
  Future<void> enqueueEnvelope(MessageEnvelope envelope,
      {String? draftText}) async {
    final existing = _outboxRecords[envelope.idempotencyKey];
    if (existing != null) {
      if (existing.envelope.toJson().toString() !=
              envelope.toJson().toString() ||
          (existing.draftText != null && existing.draftText != draftText)) {
        throw StateError('outbox idempotency key conflict');
      }
      if (existing.draftText == null && draftText != null) {
        _outboxRecords[envelope.idempotencyKey] = PendingEnvelopeRecord(
          envelope: existing.envelope,
          attemptCount: existing.attemptCount,
          terminal: existing.terminal,
          nextAttemptAt: existing.nextAttemptAt,
          failureClass: existing.failureClass,
          draftText: draftText,
        );
      }
      return;
    }
    if (_outbox.length >= maxPendingEnvelopes) {
      throw const OutboxFullException();
    }
    _outbox.add(envelope);
    _outboxRecords[envelope.idempotencyKey] = PendingEnvelopeRecord(
      envelope: envelope,
      attemptCount: 0,
      terminal: false,
      draftText: draftText,
    );
  }

  @override
  Future<bool> hasOutboxCapacity() async =>
      _outbox.length < maxPendingEnvelopes;

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
        failureClass: failureClass,
        draftText: existing.draftText);
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
    _history.apply(transition.messageEffects);
    _cryptoState = _copyCryptoState(transition.state);
    _processedMlsMessages.add(transition.messageId);
    final resolved = transition.resolvedMlsOutboxKey;
    if (resolved != null) _mlsOutbox.remove(resolved);
    _syncCursor = transition.cursor;
    _snapshot = CachedSnapshot(
      cursor: transition.cursor,
      conversations: _snapshot?.conversations ?? const <Conversation>[],
      messagesByConversation: nextMessages,
    );
  }

  @override
  Future<void> commitSyncEvent(SyncEventCommit commit) async {
    if (_processedMlsMessages.contains(commit.eventKey)) return;
    if (commit.expectedCursor != _syncCursor ||
        commit.cursor <= commit.expectedCursor) {
      throw StateError('stale sync event commit');
    }
    final nextMessages = <String, List<ReceivedMessageEnvelope>>{
      for (final entry in _snapshot?.messagesByConversation.entries ??
          const <MapEntry<String, List<ReceivedMessageEnvelope>>>[])
        entry.key: List<ReceivedMessageEnvelope>.from(entry.value),
    };
    final envelope = commit.envelope;
    if (envelope != null) {
      final messages =
          nextMessages[envelope.conversationId] ??= <ReceivedMessageEnvelope>[];
      messages.removeWhere((item) => item.id == envelope.id);
      messages.add(envelope);
      final ownKey = commit.ownMessageKey;
      if (ownKey != null) _history.markSent(ownKey, envelope.id);
    }
    _processedMlsMessages.add(commit.eventKey);
    _syncCursor = commit.cursor;
    _snapshot = CachedSnapshot(
      cursor: commit.cursor,
      conversations: _snapshot?.conversations ?? const <Conversation>[],
      messagesByConversation: nextMessages,
    );
  }

  @override
  Future<bool> hasProcessedMlsMessage(String messageId) async =>
      _processedMlsMessages.contains(messageId);

  @override
  Future<bool> hasAppliedMlsControlMessage(String mlsMessageId) async =>
      _processedMlsMessages.any((marker) =>
          marker.startsWith('mls:') && marker.endsWith(':$mlsMessageId'));

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
  Future<void> recordMlsOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  }) async {
    final existing = _mlsOutbox[idempotencyKey];
    if (existing == null) return;
    _mlsOutbox[idempotencyKey] = existing.withFailure(
      failureClass: failureClass,
      terminal: terminal,
      nextAttemptAt: nextAttemptAt?.toUtc(),
    );
  }

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
    final existing = _outboxRecords[transition.envelope.idempotencyKey];
    if (existing != null) {
      throw StateError('outbox idempotency key conflict');
    }
    if (_outbox.length >= maxPendingEnvelopes) {
      throw const OutboxFullException();
    }
    _cryptoState = _copyCryptoState(transition.state);
    _history.apply(transition.messageEffects);
    _outbox.add(transition.envelope);
    _outboxRecords[transition.envelope.idempotencyKey] = PendingEnvelopeRecord(
        envelope: transition.envelope,
        attemptCount: 0,
        terminal: false,
        draftText: transition.draftText);
  }

  @override
  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    String? resolvedMlsOutboxKey,
  }) async {
    _validateLocalMlsState(expectedCounter, expectedCursor, state,
        currentCounter: _cryptoState?.counter ?? 0, currentCursor: _syncCursor);
    _cryptoState = _copyCryptoState(state);
    if (resolvedMlsOutboxKey != null) _mlsOutbox.remove(resolvedMlsOutboxKey);
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
      history: _history.allMessages(),
      reactions: _history.allReactions(),
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
    _history.replace(backup.history, backup.reactions);
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
  Future<void> clearCachedState({bool preserveOutbox = false}) async {
    _syncCursor = 0;
    _snapshot = null;
    if (!preserveOutbox) {
      _outbox.clear();
      _outboxRecords.clear();
    }
  }

  @override
  Future<void> clear() async {
    _session = null;
    _cryptoState = null;
    _processedMlsMessages.clear();
    _mlsOutbox.clear();
    _peerVerifications.clear();
    _history.clear();
    _syncLeaseKey = null;
    _syncRecovery = null;
    _lastBackupAt = null;
    await clearCachedState();
  }

  @override
  Future<void> quarantineUnreadableDatabase({required bool confirmed}) async {
    if (!confirmed) {
      throw ArgumentError.value(confirmed, 'confirmed');
    }
    await clear();
  }

  @override
  Future<List<LocalMessage>> loadMessages(String conversationId) async =>
      _history.messages(conversationId);

  @override
  Future<List<LocalMessageReaction>> loadReactions(
          String conversationId) async =>
      _history.reactions(conversationId);
}

/// In-memory twin of the database's decrypted history, with the same effect
/// rules as `EncryptedLocalDatabase._applyMessageEffects`.
class _MemoryMessageHistory {
  final Map<String, LocalMessage> _messages = <String, LocalMessage>{};
  final Map<String, LocalMessageReaction> _reactions =
      <String, LocalMessageReaction>{};

  List<LocalMessage> allMessages() => _messages.values.toList(growable: false);

  List<LocalMessageReaction> allReactions() =>
      _reactions.values.toList(growable: false);

  void replace(
      List<LocalMessage> messages, List<LocalMessageReaction> reactions) {
    clear();
    for (final message in messages) {
      _messages[message.key] = message;
    }
    for (final reaction in reactions) {
      _reactions['${reaction.targetKey}\u0000${reaction.reactorAccountId}'] =
          reaction;
    }
  }

  void clear() {
    _messages.clear();
    _reactions.clear();
  }

  void apply(List<MessageEffect> effects) {
    for (final effect in effects) {
      switch (effect) {
        case InsertMessageEffect():
          if (_messages.containsKey(effect.key)) continue;
          if (effect.serverMessageId != null &&
              _messages.values.any(
                  (item) => item.serverMessageId == effect.serverMessageId)) {
            continue;
          }
          _messages[effect.key] = LocalMessage(
            key: effect.key,
            serverMessageId: effect.serverMessageId,
            conversationId: effect.conversationId,
            senderAccountId: effect.senderAccountId,
            senderDeviceId: effect.senderDeviceId,
            kind: effect.kind,
            body: effect.body,
            replyTo: effect.replyTo,
            createdAt: effect.createdAt,
            state: effect.state,
          );
        case EditMessageEffect():
          final target = _messages[effect.targetKey];
          if (target == null ||
              target.senderAccountId != effect.editorAccountId ||
              target.kind != LocalMessageKind.text ||
              target.deletedAt != null) {
            continue;
          }
          _messages[effect.targetKey] = target.copyWith(
            body: Value(effect.body),
            editedAt: Value(effect.at),
          );
        case DeleteMessageEffect():
          final target = _messages[effect.targetKey];
          if (target == null ||
              target.senderAccountId != effect.deleterAccountId ||
              target.kind != LocalMessageKind.text) {
            continue;
          }
          _messages[effect.targetKey] = target.copyWith(
            body: const Value(null),
            deletedAt: Value(effect.at),
          );
          _reactions
              .removeWhere((_, item) => item.targetKey == effect.targetKey);
        case ReactionEffect():
          final id = '${effect.targetKey}\u0000${effect.reactorAccountId}';
          if (effect.reaction.isEmpty) {
            _reactions.remove(id);
          } else {
            _reactions[id] = LocalMessageReaction(
              targetKey: effect.targetKey,
              reactorAccountId: effect.reactorAccountId,
              reaction: effect.reaction,
              updatedAt: effect.at,
            );
          }
      }
    }
  }

  void markSent(String key, String serverMessageId) {
    final target = _messages[key];
    if (target == null) return;
    _messages[key] = target.copyWith(
      serverMessageId: Value(serverMessageId),
      state: LocalMessageState.sent,
    );
  }

  List<LocalMessage> messages(String conversationId) {
    final result = _messages.values
        .where((item) => item.conversationId == conversationId)
        .toList();
    result.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    return result;
  }

  List<LocalMessageReaction> reactions(String conversationId) => _reactions
      .values
      .where(
          (item) => _messages[item.targetKey]?.conversationId == conversationId)
      .toList(growable: false);
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
    String namespace = '',
  })  : assert(RegExp(r'^[a-z0-9-]{0,40}$').hasMatch(namespace)),
        _namespace = namespace,
        _storage = storage ??
            const FlutterSecureStorage(
              // Fail closed (I39): resetting on a keystore error would wipe
              // the database key and with it every message on the device.
              aOptions: AndroidOptions(
                resetOnError: false,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              // The data protection keychain needs a keychain-access-groups
              // entitlement, which only a team-signed build can carry. macOS
              // builds are unsigned demos for now, so they use the login
              // keychain. Revisit when macOS builds are signed.
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            ),
        _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory,
        _databaseFactory = databaseFactory ?? openEncryptedLocalDatabase,
        _mlsCommitFailureInjector = mlsCommitFailureInjector;

  static const _legacyRecordKey = 'veritra.account_state.v2';
  static const _databaseKey = 'veritra.database_key.v1';
  static const _migrationMarker = 'legacy_secure_record_migrated';
  // Every conversation is cached so the full chat list opens offline
  // (Stage 4); the bound only stops a runaway server list. Envelopes stay
  // capped: decrypted history lives in local_messages, which has no cap.
  static const _maxCachedConversations = 1000;
  static const _maxMessagesPerConversation = 200;

  /// Separates independent local identities on one device: demo builds use
  /// `demo`, and desktop profiles extend it. The empty default keeps the
  /// release layout (database in the support directory, key
  /// `veritra.database_key.v1`) byte for byte.
  final String _namespace;
  String get _databaseKeyName =>
      _namespace.isEmpty ? _databaseKey : 'veritra.$_namespace.database_key.v1';
  String get _legacyRecordKeyName => _namespace.isEmpty
      ? _legacyRecordKey
      : 'veritra.$_namespace.account_state.v2';
  final FlutterSecureStorage _storage;
  final Future<Directory> Function() _directoryProvider;
  final LocalDatabaseFactory _databaseFactory;
  final MlsCommitFailureInjector? _mlsCommitFailureInjector;
  Future<EncryptedLocalDatabase>? _openingDatabase;
  String? _databasePath;
  String? _syncLeaseKey;

  @override
  Future<void> saveSyncRecovery(SyncRecovery? recovery) async {
    final database = await _database();
    if (recovery == null) {
      await database.deleteMetadata(EncryptedLocalDatabase.syncRecoveryName);
    } else {
      await database.writeMetadata(
          EncryptedLocalDatabase.syncRecoveryName, recovery.encode());
    }
  }

  @override
  Future<void> saveLastBackupAt(DateTime at) async =>
      (await _database()).writeMetadata(
          EncryptedLocalDatabase.lastBackupName, at.toUtc().toIso8601String());

  @override
  Future<DateTime?> loadLastBackupAt() async =>
      DateTime.tryParse(await (await _database())
                  .readMetadata(EncryptedLocalDatabase.lastBackupName) ??
              '')
          ?.toUtc();

  @override
  Future<SyncRecovery?> loadSyncRecovery() async =>
      SyncRecovery.decode(await (await _database())
          .readMetadata(EncryptedLocalDatabase.syncRecoveryName));

  @override
  Future<void> acquireSyncLease(LocalSyncLease lease) async {
    final database = await _database();
    await database.acquireSyncLease(lease.key);
    _syncLeaseKey = lease.key;
  }

  @override
  Future<void> releaseSyncLease(LocalSyncLease lease) async {
    final key = _syncLeaseKey;
    if (key == null || key != lease.key) return;
    await (await _database()).releaseSyncLease(key);
    _syncLeaseKey = null;
  }

  @override
  Future<void> saveSession(Session session) async {
    final database = await _database();
    final previous = _sessionFromJson(await database.readSessionJson());
    final changed =
        previous != null && _identity(previous) != _identity(session);
    await database.writeSessionJson(
      jsonEncode(_sessionJson(session)),
      clearIdentityState: changed,
    );
    if (changed) _syncLeaseKey = null;
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
    await _replaceProjection(conversations, messagesByConversation, cursor);
  }

  @override
  Future<void> saveProjection(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
  ) =>
      _replaceProjection(conversations, messagesByConversation, null);

  Future<void> _replaceProjection(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
    int? cursor,
  ) async {
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
  Future<void> enqueueEnvelope(MessageEnvelope envelope,
      {String? draftText}) async {
    final database = await _database();
    final path = _databasePath;
    if (path == null) throw StateError('encrypted database path unavailable');
    await _serializeDatabaseWrite(path, () async {
      try {
        await database.upsertOutbox(
          idempotencyKey: envelope.idempotencyKey,
          conversationId: envelope.conversationId,
          payloadJson: jsonEncode(envelope.toJson()),
          draftText: draftText,
          queuedAt: DateTime.now().microsecondsSinceEpoch,
          maxEntries: maxPendingEnvelopes,
        );
      } on StateError catch (error) {
        if (error.message == 'outbox_full') {
          throw const OutboxFullException();
        }
        rethrow;
      }
    });
  }

  @override
  Future<bool> hasOutboxCapacity() async =>
      (await (await _database()).outboxCount()) < maxPendingEnvelopes;

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
                draftText: item.draftText,
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
      messageEffects: transition.messageEffects,
      failureInjector: _mlsCommitFailureInjector,
      leaseKey: _syncLeaseKey,
      resolvedMlsOutboxKey: transition.resolvedMlsOutboxKey,
    );
  }

  @override
  Future<void> commitSyncEvent(SyncEventCommit commit) async {
    await (await _database()).commitSyncEvent(
      eventKey: commit.eventKey,
      conversationId: commit.conversationId,
      expectedCursor: commit.expectedCursor,
      cursor: commit.cursor,
      envelope: commit.envelope == null
          ? null
          : (
              id: commit.envelope!.id,
              conversationId: commit.envelope!.conversationId,
              payloadJson: jsonEncode(commit.envelope!.toJson()),
            ),
      ownMessageKey: commit.ownMessageKey,
      leaseKey: _syncLeaseKey,
    );
  }

  @override
  Future<bool> hasProcessedMlsMessage(String messageId) async =>
      (await _database()).hasProcessedMlsMessage(messageId);

  @override
  Future<bool> hasAppliedMlsControlMessage(String mlsMessageId) async =>
      (await _database()).hasAppliedMlsControlMessage(mlsMessageId);

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
      leaseKey: _syncLeaseKey,
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
                attemptCount: message.attemptCount,
                nextAttemptAt: message.nextAttemptAt == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(
                        message.nextAttemptAt!,
                        isUtc: true),
                failureClass: message.failureClass,
                terminal: message.terminal,
              ))
          .toList(growable: false);

  @override
  Future<void> recordMlsOutboxFailure(
    String idempotencyKey, {
    required String failureClass,
    required bool terminal,
    DateTime? nextAttemptAt,
  }) async {
    await (await _database()).recordMlsOutboxFailure(
      idempotencyKey,
      failureClass: failureClass,
      terminal: terminal,
      nextAttemptAt: nextAttemptAt?.toUtc().millisecondsSinceEpoch,
    );
  }

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
    try {
      await (await _database()).commitOutgoingApplicationTransition(
        expectedCounter: transition.expectedCounter,
        expectedCursor: transition.expectedCursor,
        counter: transition.state.counter,
        stateKey: transition.state.stateKey,
        sealedState: transition.state.sealedState,
        idempotencyKey: transition.envelope.idempotencyKey,
        conversationId: transition.envelope.conversationId,
        payloadJson: jsonEncode(transition.envelope.toJson()),
        maxEntries: maxPendingEnvelopes,
        draftText: transition.draftText,
        messageEffects: transition.messageEffects,
        leaseKey: _syncLeaseKey,
      );
    } on StateError catch (error) {
      if (error.message == 'outbox_full') {
        throw const OutboxFullException();
      }
      rethrow;
    }
  }

  @override
  Future<void> commitLocalMlsState({
    required int expectedCounter,
    required int expectedCursor,
    required StoredCryptoState state,
    String? resolvedMlsOutboxKey,
  }) async {
    _validateLocalMlsState(expectedCounter, expectedCursor, state,
        currentCounter: expectedCounter, currentCursor: expectedCursor);
    await (await _database()).commitLocalMlsState(
      expectedCounter: expectedCounter,
      expectedCursor: expectedCursor,
      counter: state.counter,
      stateKey: state.stateKey,
      sealedState: state.sealedState,
      leaseKey: _syncLeaseKey,
      resolvedMlsOutboxKey: resolvedMlsOutboxKey,
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
      history: await (await _database()).readAllMessages(),
      reactions: await (await _database()).readAllReactions(),
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
      history: backup.history,
      reactions: backup.reactions,
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
  Future<List<LocalMessage>> loadMessages(String conversationId) async =>
      (await _database()).readMessages(conversationId);

  @override
  Future<List<LocalMessageReaction>> loadReactions(
          String conversationId) async =>
      (await _database()).readReactions(conversationId);

  @override
  Future<void> clearCachedState({bool preserveOutbox = false}) async {
    await (await _database()).clearCachedState(preserveOutbox: preserveOutbox);
  }

  @override
  Future<void> clear() async {
    await (await _database()).clearAll();
    await _storage.delete(key: _legacyRecordKeyName);
    _syncLeaseKey = null;
  }

  @override
  Future<void> quarantineUnreadableDatabase({required bool confirmed}) async {
    if (!confirmed) {
      throw ArgumentError.value(confirmed, 'confirmed',
          'resetting the local database needs explicit confirmation');
    }
    final opening = _openingDatabase;
    _openingDatabase = null;
    if (opening != null) {
      try {
        await (await opening).close();
      } catch (_) {
        // It never opened; there is nothing to close.
      }
    }
    final directory = await _profileDirectory();
    await _writeResetIntent(directory);
    await _completeReset(directory);
    _syncLeaseKey = null;
  }

  /// A failed open is not cached: the next call opens again, so a key that
  /// becomes readable later (after unlock, say) is picked up by a retry.
  Future<EncryptedLocalDatabase> _database() {
    final existing = _openingDatabase;
    if (existing != null) return existing;
    final opening = _openDatabase();
    _openingDatabase = opening;
    unawaited(opening.then<void>((_) {}, onError: (Object error) {
      if (identical(_openingDatabase, opening)) _openingDatabase = null;
    }));
    return opening;
  }

  Future<Directory> _profileDirectory() async {
    final base = await _directoryProvider();
    final directory = _namespace.isEmpty
        ? base
        : Directory('${base.path}${Platform.pathSeparator}profiles'
            '${Platform.pathSeparator}$_namespace');
    await directory.create(recursive: true);
    return directory;
  }

  static const _resetIntentName = 'veritra-local.reset-intent';
  static const _databaseFileNames = <String>[
    'veritra-local.db-wal',
    'veritra-local.db-shm',
    'veritra-local.db',
  ];

  String get _quarantinedKeyPrefix => '$_databaseKeyName.quarantined.';

  /// The reset is journaled so that a crash part-way leaves either the
  /// original database in place or a complete quarantined copy with its
  /// key, never a database separated from its WAL or its key.
  Future<void> _writeResetIntent(Directory directory) async {
    final intent = File('${directory.path}${Platform.pathSeparator}'
        '$_resetIntentName');
    if (await intent.exists()) return;
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
    final temporary = File('${intent.path}.tmp');
    await temporary.writeAsString(stamp, flush: true);
    await temporary.rename(intent.path);
  }

  Future<void> _completeReset(Directory directory) async {
    final intent = File('${directory.path}${Platform.pathSeparator}'
        '$_resetIntentName');
    if (!await intent.exists()) return;
    final stamp = (await intent.readAsString()).trim();
    if (!RegExp(r'^[0-9]{1,20}$').hasMatch(stamp)) {
      throw const LocalStoreUnavailableException(
          LocalStoreFailureKind.keyRejected);
    }
    final quarantine = Directory('${directory.path}${Platform.pathSeparator}'
        'unreadable-$stamp');
    await quarantine.create(recursive: true);
    // Keep the key with the files so the copy stays readable if the key was
    // only temporarily unreadable. Copy before moving any file.
    String? key;
    try {
      key = await _storage.read(key: _databaseKeyName);
    } catch (_) {
      key = null;
    }
    if (key != null) {
      await _storage.write(key: '$_quarantinedKeyPrefix$stamp', value: key);
    }
    for (final name in _databaseFileNames) {
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      if (await file.exists()) {
        await file.rename('${quarantine.path}${Platform.pathSeparator}$name');
      }
    }
    await _storage.delete(key: _databaseKeyName);
    await _storage.delete(key: _legacyRecordKeyName);
    await intent.delete();
  }

  Future<EncryptedLocalDatabase> _openDatabase() async {
    final directory = await _profileDirectory();
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
    try {
      await _holdInstanceLock(directory);
    } on StateError {
      throw const LocalStoreUnavailableException(
          LocalStoreFailureKind.profileLocked);
    }
    final lockFile =
        File('${directory.path}${Platform.pathSeparator}veritra-local.lock');
    final lock = await lockFile.open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    try {
      // A reset interrupted by a crash is finished before anything else.
      await _completeReset(directory);
      final String? keyHex;
      try {
        keyHex = await _storage.read(key: _databaseKeyName);
      } catch (_) {
        throw const LocalStoreUnavailableException(
            LocalStoreFailureKind.keyUnavailable);
      }
      final databaseExists = await databaseFile.exists();
      if (keyHex == null && databaseExists) {
        // A database without its key is unreadable. Writing a fresh key
        // would hide that behind a new, empty identity (D26), so stop and
        // let the recovery screen explain it.
        throw const LocalStoreUnavailableException(
            LocalStoreFailureKind.keyMissing);
      }
      if (keyHex != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(keyHex)) {
        throw const LocalStoreUnavailableException(
            LocalStoreFailureKind.keyMalformed);
      }
      final key = keyHex ?? await _createKey();
      final EncryptedLocalDatabase database;
      try {
        database = _databaseFactory(databaseFile, key);
        await database.readCursor();
      } catch (_) {
        if (!databaseExists) rethrow;
        // SQLite cannot tell a wrong key from a damaged file. Either way the
        // file is left exactly as it is.
        throw const LocalStoreUnavailableException(
            LocalStoreFailureKind.keyRejected);
      }
      await _migrateLegacyRecord(database);
      return database;
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  /// Writes a new key for a profile that has no database yet and reads it
  /// back; the database is created only after the key is confirmed stored.
  Future<String> _createKey() async {
    final keyHex = _randomHexKey();
    try {
      await _storage.write(key: _databaseKeyName, value: keyHex);
      if (await _storage.read(key: _databaseKeyName) != keyHex) {
        throw StateError('key write not confirmed');
      }
    } catch (_) {
      throw const LocalStoreUnavailableException(
          LocalStoreFailureKind.keyWriteFailed);
    }
    return keyHex;
  }

  /// Holds an OS lock on the profile directory for the life of the process,
  /// so a second window on the same profile fails at open instead of both
  /// advancing the same MLS state.
  static Future<void> _holdInstanceLock(Directory directory) async {
    final path =
        '${directory.path}${Platform.pathSeparator}veritra-instance.lock';
    if (_instanceLocks.containsKey(path)) return;
    final handle = await File(path).open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      throw StateError('another Veritra window is using this profile');
    }
    _instanceLocks[path] = handle;
  }

  Future<void> _migrateLegacyRecord(EncryptedLocalDatabase database) async {
    final raw = await _storage.read(key: _legacyRecordKeyName);
    if (await database.readMetadata(_migrationMarker) == '1') {
      if (raw != null) await _storage.delete(key: _legacyRecordKeyName);
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
    await _storage.delete(key: _legacyRecordKeyName);
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
        'version': 2,
        // Decrypted history (D27). Local only: the backup is encrypted with
        // a key the server never sees.
        'history': data.history.map((item) => item.toJson()).toList(),
        'reactions': data.reactions.map((item) => item.toJson()).toList(),
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
    final version = root['version'];
    if (version != 1 && version != 2) {
      throw const FormatException('unsupported backup version');
    }
    final history = version == 1
        ? const <LocalMessage>[]
        : (root['history'] as List)
            .map((item) =>
                LocalMessage.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(growable: false);
    final reactions = version == 1
        ? const <LocalMessageReaction>[]
        : (root['reactions'] as List)
            .map((item) => LocalMessageReaction.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(growable: false);
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
        cryptoState: crypto,
        history: history,
        reactions: reactions);
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
        (message.kind != 'welcome' &&
            message.kind != 'commit' &&
            message.kind != 'bundle') ||
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
