// The read-receipts switch when the keystore fails (TASK-046): an unread
// choice keeps read state private and is read again later, and a failed
// save is reported instead of being swallowed.

import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/receipts_state.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _FlakyStorage extends FlutterSecureStorage {
  _FlakyStorage();

  bool failReads = false;
  bool failWrites = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failReads) throw StateError('keystore locked');
    return super.read(key: key);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failWrites) throw StateError('keystore locked');
    return super.write(key: key, value: value);
  }
}

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
);

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  final List<String> reads = <String>[];

  @override
  Future<void> markRead(String token, String conversationId, String id) async {
    reads.add('public');
  }

  @override
  Future<void> markReadPrivate(
      String token, String conversationId, String id) async {
    reads.add('private');
  }
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

AppState _state(_Api api, ReceiptPreferences preferences) => AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _QuietSync(),
      receiptPreferences: preferences,
    )
      ..api = api
      ..session = _session
      ..conversations = <Conversation>[Conversation(id: 'c1', kind: 'group')]
      ..messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
        'c1': <ReceivedMessageEnvelope>[
          ReceivedMessageEnvelope.fromJson(<String, Object?>{
            'id': 'm1',
            'conversation_id': 'c1',
            'sender_account_id': 'acct_peer',
            'sender_device_id': 'dev_peer',
            'idempotency_key': 'k_m1',
            'ciphertext': '',
            'crypto_protocol': 'test',
            'created_at': '2026-06-02T12:00:00Z',
          }),
        ],
      };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('a keystore read error keeps the receipt private, then retries',
      () async {
    final storage = _FlakyStorage();
    await storage.write(key: SecureReceiptPreferenceStore.key, value: 'off');
    storage.failReads = true;
    final preferences =
        ReceiptPreferences(SecureReceiptPreferenceStore(storage: storage));
    final api = _Api();
    final state = _state(api, preferences);
    addTearDown(state.dispose);

    await state.markNewestMessageRead('c1');
    expect(api.reads, <String>['private'],
        reason: 'an unreadable "off" was treated as "on"');
    expect(preferences.shareReadReceipts, isFalse);

    // The failed read is not remembered: the next receipt reads again.
    storage.failReads = false;
    await state.markNewestMessageRead('c1');
    expect(api.reads, <String>['private', 'private']);
    expect(preferences.sendReadReceipts, isFalse);

    await storage.write(key: SecureReceiptPreferenceStore.key, value: 'on');
    final fresh =
        ReceiptPreferences(SecureReceiptPreferenceStore(storage: storage));
    storage.failReads = true;
    await fresh.loaded;
    expect(fresh.shareReadReceipts, isFalse);
    storage.failReads = false;
    await fresh.loaded;
    expect(fresh.shareReadReceipts, isTrue);
  });

  test('an absent value still means on', () async {
    final preferences = ReceiptPreferences(
        SecureReceiptPreferenceStore(storage: _FlakyStorage()));
    final api = _Api();
    final state = _state(api, preferences);
    addTearDown(state.dispose);
    await state.markNewestMessageRead('c1');
    expect(api.reads, <String>['public']);
    expect(preferences.sendReadReceipts, isTrue);
  });

  test('a choice made in this run applies at once, even before a read',
      () async {
    final storage = _FlakyStorage()..failReads = true;
    final preferences =
        ReceiptPreferences(SecureReceiptPreferenceStore(storage: storage));
    expect(await preferences.setSendReadReceipts(true), isTrue);
    await preferences.loaded;
    expect(preferences.shareReadReceipts, isTrue);
  });

  test('a failed save is reported and the choice still applies', () async {
    final storage = _FlakyStorage()..failWrites = true;
    final preferences =
        ReceiptPreferences(SecureReceiptPreferenceStore(storage: storage));
    var notified = 0;
    preferences.addListener(() => notified++);

    expect(await preferences.setSendReadReceipts(false), isFalse);
    expect(preferences.saveFailed, isTrue);
    expect(preferences.sendReadReceipts, isFalse);
    expect(preferences.shareReadReceipts, isFalse);
    expect(notified, greaterThan(0));

    storage.failWrites = false;
    expect(await preferences.setSendReadReceipts(false), isTrue);
    expect(preferences.saveFailed, isFalse);
    expect(await storage.read(key: SecureReceiptPreferenceStore.key), 'off');
  });
}
