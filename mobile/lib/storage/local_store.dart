import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/models.dart';

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
  Future<void> removePendingEnvelope(String idempotencyKey);
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor);
  Future<StoredCryptoState?> loadCryptoState();
  Future<void> clearCachedState();
  Future<void> clear();
}

class MemoryLocalStore implements LocalStore {
  Session? _session;
  int _syncCursor = 0;
  CachedSnapshot? _snapshot;
  final List<MessageEnvelope> _outbox = <MessageEnvelope>[];
  StoredCryptoState? _cryptoState;

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
  }

  @override
  Future<List<MessageEnvelope>> pendingEnvelopes() async =>
      List<MessageEnvelope>.from(_outbox);

  @override
  Future<void> removePendingEnvelope(String idempotencyKey) async {
    _outbox.removeWhere((item) => item.idempotencyKey == idempotencyKey);
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
  Future<StoredCryptoState?> loadCryptoState() async =>
      _cryptoState == null ? null : _copyCryptoState(_cryptoState!);

  @override
  Future<void> clearCachedState() async {
    _syncCursor = 0;
    _snapshot = null;
    _outbox.clear();
  }

  @override
  Future<void> clear() async {
    _session = null;
    _cryptoState = null;
    await clearCachedState();
  }
}

/// Persists one versioned account record in platform encrypted storage.
/// The cursor, ciphertext cache, and encrypted outbox are committed in the
/// same record so a crash cannot acknowledge state that was not persisted.
class SecureLocalStore implements LocalStore {
  SecureLocalStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: true,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  static const _key = 'veritra.account_state.v2';
  static const _maxCachedConversations = 20;
  static const _maxMessagesPerConversation = 200;
  static const _maxPendingEnvelopes = 100;
  final FlutterSecureStorage _storage;

  @override
  Future<void> saveSession(Session session) async {
    final record = await _readRecord();
    final previous = _sessionFrom(record['session']);
    if (previous != null && _identity(previous) != _identity(session)) {
      record
        ..remove('snapshot')
        ..remove('outbox')
        ..remove('crypto_state')
        ..['cursor'] = 0;
    }
    record['version'] = 3;
    record['session'] = _sessionJson(session);
    await _writeRecord(record);
  }

  @override
  Future<Session?> loadSession() async {
    final record = await _readRecord();
    return _sessionFrom(record['session']);
  }

  @override
  Future<void> saveSyncCursor(int eventId) async {
    final record = await _readRecord();
    record['cursor'] = eventId;
    await _writeRecord(record);
  }

  @override
  Future<int> loadSyncCursor() async {
    final record = await _readRecord();
    return (record['cursor'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> saveSnapshot(
    List<Conversation> conversations,
    Map<String, List<ReceivedMessageEnvelope>> messagesByConversation,
    int cursor,
  ) async {
    final record = await _readRecord();
    final boundedConversations = conversations.take(_maxCachedConversations);
    final conversationIds = boundedConversations.map((item) => item.id).toSet();
    record['cursor'] = cursor;
    record['snapshot'] = <String, Object?>{
      'conversations':
          boundedConversations.map((item) => item.toJson()).toList(),
      'messages': <String, Object?>{
        for (final entry in messagesByConversation.entries)
          if (conversationIds.contains(entry.key))
            entry.key: entry.value
                .take(_maxMessagesPerConversation)
                .map((item) => item.toJson())
                .toList(),
      },
    };
    await _writeRecord(record);
  }

  @override
  Future<CachedSnapshot?> loadSnapshot() async {
    final record = await _readRecord();
    final raw = record['snapshot'];
    if (raw is! Map) {
      return null;
    }
    try {
      final snapshot = Map<String, Object?>.from(raw);
      final conversations = (snapshot['conversations'] as List? ?? const [])
          .map((item) => Conversation.fromJson(
                Map<String, Object?>.from(item as Map),
              ))
          .toList();
      final messages = <String, List<ReceivedMessageEnvelope>>{};
      final rawMessages = snapshot['messages'];
      if (rawMessages is Map) {
        for (final entry in rawMessages.entries) {
          messages[entry.key.toString()] = (entry.value as List)
              .map((item) => ReceivedMessageEnvelope.fromJson(
                    Map<String, Object?>.from(item as Map),
                  ))
              .toList();
        }
      }
      return CachedSnapshot(
        cursor: (record['cursor'] as num?)?.toInt() ?? 0,
        conversations: conversations,
        messagesByConversation: messages,
      );
    } catch (_) {
      record.remove('snapshot');
      await _writeRecord(record);
      return null;
    }
  }

  @override
  Future<void> enqueueEnvelope(MessageEnvelope envelope) async {
    final record = await _readRecord();
    final outbox = _rawOutbox(record)
      ..removeWhere(
        (item) => item['idempotency_key'] == envelope.idempotencyKey,
      )
      ..add(envelope.toJson());
    if (outbox.length > _maxPendingEnvelopes) {
      outbox.removeRange(0, outbox.length - _maxPendingEnvelopes);
    }
    record['outbox'] = outbox;
    await _writeRecord(record);
  }

  @override
  Future<List<MessageEnvelope>> pendingEnvelopes() async {
    final record = await _readRecord();
    return _rawOutbox(record).map(MessageEnvelope.fromJson).toList();
  }

  @override
  Future<void> removePendingEnvelope(String idempotencyKey) async {
    final record = await _readRecord();
    final outbox = _rawOutbox(record)
      ..removeWhere((item) => item['idempotency_key'] == idempotencyKey);
    record['outbox'] = outbox;
    await _writeRecord(record);
  }

  @override
  Future<void> saveCryptoState(StoredCryptoState state, int syncCursor) async {
    _validateCryptoState(state);
    final record = await _readRecord();
    final previous = _cryptoStateFrom(record['crypto_state']);
    if (previous != null && state.counter <= previous.counter) {
      throw StateError('crypto state counter must increase');
    }
    record
      ..['crypto_state'] = <String, Object?>{
        'counter': state.counter,
        'state_key': base64Encode(state.stateKey),
        'sealed_state': base64Encode(state.sealedState),
      }
      ..['cursor'] = syncCursor;
    await _writeRecord(record);
  }

  @override
  Future<StoredCryptoState?> loadCryptoState() async {
    final record = await _readRecord();
    final state = _cryptoStateFrom(record['crypto_state']);
    if (state != null) {
      return state;
    }
    if (record.containsKey('crypto_state')) {
      record.remove('crypto_state');
      await _writeRecord(record);
    }
    return null;
  }

  @override
  Future<void> clearCachedState() async {
    final record = await _readRecord();
    record
      ..remove('snapshot')
      ..remove('outbox')
      ..['cursor'] = 0;
    await _writeRecord(record);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
  }

  Future<Map<String, Object?>> _readRecord() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) {
      return <String, Object?>{'version': 3, 'cursor': 0};
    }
    try {
      return Map<String, Object?>.from(jsonDecode(raw) as Map);
    } catch (_) {
      await _storage.delete(key: _key);
      return <String, Object?>{'version': 3, 'cursor': 0};
    }
  }

  Future<void> _writeRecord(Map<String, Object?> record) async {
    await _storage.write(key: _key, value: jsonEncode(record));
  }

  List<Map<String, Object?>> _rawOutbox(Map<String, Object?> record) {
    return (record['outbox'] as List? ?? const [])
        .map((item) => Map<String, Object?>.from(item as Map))
        .toList();
  }
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

void _validateCryptoState(StoredCryptoState state) {
  if (state.counter <= 0 ||
      state.stateKey.length != 32 ||
      state.sealedState.isEmpty ||
      state.sealedState.length > 32 * 1024 * 1024) {
    throw const FormatException('invalid protected crypto state');
  }
}
