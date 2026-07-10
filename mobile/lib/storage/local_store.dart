import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/models.dart';

abstract class LocalStore {
  Future<void> saveSession(Session session);
  Future<Session?> loadSession();
  Future<void> saveSyncCursor(int eventId);
  Future<int> loadSyncCursor();
  Future<void> clear();
}

class MemoryLocalStore implements LocalStore {
  Session? _session;
  int _syncCursor = 0;

  @override
  Future<void> saveSession(Session session) async {
    _session = session;
  }

  @override
  Future<Session?> loadSession() async {
    return _session;
  }

  @override
  Future<void> saveSyncCursor(int eventId) async {
    _syncCursor = eventId;
  }

  @override
  Future<int> loadSyncCursor() async {
    return _syncCursor;
  }

  @override
  Future<void> clear() async {
    _session = null;
    _syncCursor = 0;
  }
}

/// SecureLocalStore persists the Session to the platform keystore
/// (Android EncryptedSharedPreferences via Keystore, iOS Keychain).
/// The session blob never lands on disk in plaintext.
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

  static const _key = 'veritra.session.v1';
  static const _syncCursorKey = 'veritra.sync_cursor.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<void> saveSession(Session session) async {
    final encoded = jsonEncode(<String, String>{
      'base_url': session.baseUrl,
      'token': session.token,
      if (session.accountId != null) 'account_id': session.accountId!,
      if (session.deviceId != null) 'device_id': session.deviceId!,
      if (session.username != null) 'username': session.username!,
    });
    await _storage.write(key: _key, value: encoded);
  }

  @override
  Future<Session?> loadSession() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = Map<String, Object?>.from(jsonDecode(raw) as Map);
      final baseUrl = decoded['base_url'] as String?;
      final token = decoded['token'] as String?;
      if (baseUrl == null || token == null) {
        return null;
      }
      return Session(
        baseUrl: baseUrl,
        token: token,
        accountId: decoded['account_id'] as String?,
        deviceId: decoded['device_id'] as String?,
        username: decoded['username'] as String?,
      );
    } catch (_) {
      // Stored payload was tampered with or corrupt — drop it and start over
      // rather than crashing the app on launch.
      await _storage.delete(key: _key);
      return null;
    }
  }

  @override
  Future<void> saveSyncCursor(int eventId) async {
    await _storage.write(key: _syncCursorKey, value: eventId.toString());
  }

  @override
  Future<int> loadSyncCursor() async {
    final raw = await _storage.read(key: _syncCursorKey);
    return int.tryParse(raw ?? '') ?? 0;
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _key);
    await _storage.delete(key: _syncCursorKey);
  }
}
