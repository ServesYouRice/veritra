import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// D71, D73 (C-7121f7bb1452): a backup's plaintext holds no bearer token,
/// no device id or secret, no MLS state or its key, no outbox and no
/// cursor, so a stolen backup cannot clone the device. An older backup that
/// still holds them restores its history and drops them.

const _token = 'tok-SENTINEL-7121-bearer';
const _secret = 'sec-SENTINEL-7121-device';
const _deviceId = 'dev-SENTINEL-7121';

const _session = Session(
  baseUrl: 'https://chat.example.org',
  token: _token,
  accountId: 'acct_1',
  deviceId: _deviceId,
  username: 'alice',
  deviceSecret: _secret,
  role: 'member',
);

final List<int> _stateKey = List<int>.generate(32, (i) => 0xA0 + (i % 16));
final List<int> _sealed = utf8.encode('sealed-SENTINEL-7121-mls-state');

StoredCryptoState _state(int counter) => StoredCryptoState(
    counter: counter, stateKey: _stateKey, sealedState: _sealed);

/// Every way the sentinels could appear in the JSON plaintext.
List<String> _forbidden() => <String>[
      _token,
      _secret,
      _deviceId,
      base64Encode(_stateKey),
      base64Encode(_sealed),
      utf8.decode(_sealed),
      '"token"',
      '"device_secret"',
      '"device_id"',
      '"crypto_state"',
      '"state_key"',
      '"sealed_state"',
      '"outbox"',
      '"mls_outbox"',
      '"pending_pins"',
      '"cursor"',
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-backup-c7121-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    await SecureLocalStore.releaseInstanceLocks();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  SecureLocalStore createStore({String namespace = ''}) => SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        namespace: namespace,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );

  Future<List<int>> seededBackup(LocalStore store) async {
    await store.saveSession(_session);
    await store.saveCryptoState(_state(1), 10);
    await store.saveSnapshot(
        <Conversation>[Conversation(id: 'conv_1', kind: 'dm', title: 'Chat')],
        const <String, List<ReceivedMessageEnvelope>>{},
        10);
    await store.commitMlsTransition(MlsStateTransition(
      messageId: 'application:11:m1',
      conversationId: 'conv_1',
      expectedCounter: 1,
      expectedCursor: 10,
      state: _state(2),
      cursor: 11,
      messageEffects: <MessageEffect>[
        InsertMessageEffect(
          key: 'dev_peer:m1',
          serverMessageId: 'm1',
          conversationId: 'conv_1',
          senderAccountId: 'acct_peer',
          senderDeviceId: 'dev_peer',
          kind: LocalMessageKind.text,
          body: 'hello',
          createdAt: DateTime.utc(2026, 10, 24).millisecondsSinceEpoch,
          state: LocalMessageState.received,
        ),
      ],
    ));
    await store.commitOutgoingMlsTransition(OutgoingMlsStateTransition(
      expectedCounter: 2,
      expectedCursor: 11,
      state: _state(3),
      messages: <PendingMlsMessage>[
        PendingMlsMessage(
          idempotencyKey: 'mls_1',
          conversationId: 'conv_1',
          kind: 'commit',
          payload: utf8.encode('mls-outbox-SENTINEL'),
        ),
      ],
    ));
    await store.enqueueEnvelope(MessageEnvelope(
      conversationId: 'conv_1',
      idempotencyKey: 'plain_1',
      ciphertext: utf8.encode('plain-outbox-SENTINEL'),
      cryptoProtocol: 'mls10-openmls-v1',
    ));
    return store.exportHistorySnapshot();
  }

  for (final memory in <bool>[true, false]) {
    final label = memory ? 'memory store' : 'encrypted store';

    test('the history snapshot holds no credential or MLS state ($label)',
        () async {
      final backup =
          await seededBackup(memory ? MemoryLocalStore() : createStore());
      final text = utf8.decode(backup);
      // The snapshot names its source device by design (K2); no secret.
      for (final needle in _forbidden().where((n) => n != _deviceId)) {
        expect(text, isNot(contains(needle)), reason: needle);
      }
      expect(text, isNot(contains('mls-outbox-SENTINEL')));
      expect(text, isNot(contains('plain-outbox-SENTINEL')));
    });
  }
}
