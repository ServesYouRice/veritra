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
    return store.exportBackup();
  }

  /// A version 5 backup as the previous build wrote it: the full session,
  /// the MLS state and its key, the outboxes and the cursor.
  List<int> legacyV5(List<int> current) {
    final root =
        Map<String, Object?>.from(jsonDecode(utf8.decode(current)) as Map);
    root
      ..['version'] = 5
      ..remove('account')
      ..['account_id'] = _session.accountId
      ..['device_id'] = _deviceId
      ..['session'] = <String, Object?>{
        'base_url': _session.baseUrl,
        'token': _token,
        'account_id': _session.accountId,
        'device_id': _deviceId,
        'username': 'alice',
        'device_secret': _secret,
      }
      ..['cursor'] = 42
      ..['outbox'] = <Object?>[
        MessageEnvelope(
          conversationId: 'conv_1',
          idempotencyKey: 'plain_old',
          ciphertext: const <int>[1, 2, 3],
          cryptoProtocol: 'mls10-openmls-v1',
        ).toJson(),
      ]
      ..['mls_outbox'] = <Object?>[
        <String, Object?>{
          'idempotency_key': 'mls_old',
          'conversation_id': 'conv_1',
          'kind': 'commit',
          'payload': base64Encode(<int>[9, 9]),
          'terminal': true,
        },
      ]
      ..['pending_pins'] = <Object?>[]
      ..['crypto_state'] = <String, Object?>{
        'counter': 7,
        'state_key': base64Encode(_stateKey),
        'sealed_state': base64Encode(_sealed),
      };
    return utf8.encode(jsonEncode(root));
  }

  Future<void> expectRestoredWithoutDevice(LocalStore target) async {
    final restored = await target.loadSession();
    expect(restored, isNotNull);
    expect(isRestoredAccountSession(restored!), isTrue);
    expect(restored.baseUrl, _session.baseUrl);
    expect(restored.accountId, 'acct_1');
    expect(restored.username, 'alice');
    expect(restored.token, isEmpty);
    expect(restored.deviceId, isNull);
    expect(restored.deviceSecret, isNull);
    expect(await target.loadCryptoState(), isNull);
    expect(await target.loadSyncCursor(), 0);
    expect(await target.pendingMlsMessages(), isEmpty);
    expect(await target.pendingEnvelopeRecords(), isEmpty);
    expect((await target.loadMessages('conv_1')).single.body, 'hello');
    expect((await target.loadSnapshot())?.conversations.single.id, 'conv_1');
  }

  for (final memory in <bool>[true, false]) {
    final label = memory ? 'memory store' : 'encrypted store';

    test('the backup plaintext holds no credential or MLS state ($label)',
        () async {
      final backup =
          await seededBackup(memory ? MemoryLocalStore() : createStore());
      final text = utf8.decode(backup);
      for (final needle in _forbidden()) {
        expect(text, isNot(contains(needle)), reason: needle);
      }
      expect(text, isNot(contains('SENTINEL')));
      final root = Map<String, Object?>.from(jsonDecode(text) as Map);
      expect(root['version'], 6);
      expect(root['account'], <String, Object?>{
        'base_url': 'https://chat.example.org',
        'account_id': 'acct_1',
        'username': 'alice',
        'role': 'member',
      });
    });

    test('a restore keeps history and leaves no device ($label)', () async {
      final backup =
          await seededBackup(memory ? MemoryLocalStore() : createStore());
      final target =
          memory ? MemoryLocalStore() : createStore(namespace: 'restored');
      await target.restoreBackup(backup);
      await expectRestoredWithoutDevice(target);
    });

    test(
        'an old backup restores its history and drops its credentials '
        '($label)', () async {
      final backup = legacyV5(
          await seededBackup(memory ? MemoryLocalStore() : createStore()));
      final target =
          memory ? MemoryLocalStore() : createStore(namespace: 'legacy');
      await target.restoreBackup(backup);
      await expectRestoredWithoutDevice(target);
    });

    test('an old backup bound to another device is refused ($label)', () async {
      final root = Map<String, Object?>.from(jsonDecode(utf8.decode(legacyV5(
              await seededBackup(memory ? MemoryLocalStore() : createStore()))))
          as Map)
        ..['device_id'] = 'dev_other';
      final target =
          memory ? MemoryLocalStore() : createStore(namespace: 'bound');
      await expectLater(target.restoreBackup(utf8.encode(jsonEncode(root))),
          throwsFormatException);
      expect(await target.loadSession(), isNull);
    });

    test(
        'a restored account is marked as one, so a second restore is '
        'refused ($label)', () async {
      final backup =
          await seededBackup(memory ? MemoryLocalStore() : createStore());
      final target =
          memory ? MemoryLocalStore() : createStore(namespace: 'twice');
      await target.restoreBackup(backup);
      // BackupService.recover refuses a device holding this session.
      expect(isRestoredAccountSession((await target.loadSession())!), isTrue);
      // A device signed out with its identity kept is not a restored one.
      expect(
          isRestoredAccountSession(const Session(
              baseUrl: 'https://chat.example.org',
              token: '',
              accountId: 'acct_1',
              deviceId: 'dev_1',
              deviceSecret: 's')),
          isFalse);
    });

    test(
        'a device of the same account keeps the restored history; '
        'another account drops it ($label)', () async {
      final backup =
          await seededBackup(memory ? MemoryLocalStore() : createStore());
      final target =
          memory ? MemoryLocalStore() : createStore(namespace: 'enrolled');
      await target.restoreBackup(backup);
      const linked = Session(
        baseUrl: 'https://chat.example.org',
        token: 'new-token',
        accountId: 'acct_1',
        deviceId: 'dev_new',
        deviceSecret: 'new-secret',
      );
      await target.saveSession(linked);
      expect((await target.loadMessages('conv_1')).single.body, 'hello');
      expect(await target.loadCryptoState(), isNull);
      expect(await target.loadSyncCursor(), 0);

      final other =
          memory ? MemoryLocalStore() : createStore(namespace: 'other');
      await other.restoreBackup(backup);
      await other.saveSession(const Session(
        baseUrl: 'https://chat.example.org',
        token: 'other-token',
        accountId: 'acct_2',
        deviceId: 'dev_x',
        deviceSecret: 'x',
      ));
      expect(await other.loadMessages('conv_1'), isEmpty);
    });
  }
}
