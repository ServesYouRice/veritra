import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// D70 S5 under D73: with per-record sealed state (schema 16, format 4) a
/// backup still carries no MLS state. Neither the root nor any
/// `local_crypto_records` row reaches the plaintext, and a restore into a
/// store that holds its own root and records leaves none of them, so a
/// restored device never mixes records from two states.

const _source = Session(
  baseUrl: 'https://chat.example.org',
  token: 'tok',
  accountId: 'acct_1',
  deviceId: 'dev_source',
  username: 'alice',
);

const _target = Session(
  baseUrl: 'https://chat.example.org',
  token: 'tok2',
  accountId: 'acct_1',
  deviceId: 'dev_target',
  username: 'alice',
);

final List<int> _stateKey = List<int>.generate(32, (i) => 0xB0 + (i % 16));
final List<int> _root = utf8.encode('root-SENTINEL-D70-format4');
final List<int> _groupId = utf8.encode('grp-SENTINEL-D70-id');
final List<int> _kpId = utf8.encode('kp-SENTINEL-D70-ref');

List<int> _sealed(String what) => utf8.encode('$what-SENTINEL-D70-sealed');

/// A first state with a device, group and key-package record, as the
/// native service seals it.
StoredCryptoState _first() => StoredCryptoState(
      counter: 1,
      stateKey: _stateKey,
      sealedState: _root,
      changes: <CryptoRecordChange>[
        CryptoRecordChange(
            kind: cryptoRecordKindDevice,
            recordId: const <int>[],
            generation: 1,
            sealed: _sealed('device')),
        CryptoRecordChange(
            kind: cryptoRecordKindGroup,
            recordId: _groupId,
            generation: 1,
            sealed: _sealed('group')),
        CryptoRecordChange(
            kind: cryptoRecordKindKeyPackage,
            recordId: _kpId,
            generation: 1,
            sealed: _sealed('kp')),
      ],
    );

/// The next state: the group resealed, the key package consumed.
StoredCryptoState _second() => StoredCryptoState(
      counter: 2,
      stateKey: _stateKey,
      sealedState: [..._root, 2],
      changes: <CryptoRecordChange>[
        CryptoRecordChange(
            kind: cryptoRecordKindGroup,
            recordId: _groupId,
            generation: 2,
            sealed: _sealed('group2')),
        CryptoRecordChange(
            kind: cryptoRecordKindKeyPackage,
            recordId: _kpId,
            generation: 2,
            sealed: null),
      ],
    );

List<String> _forbidden() => <String>[
      for (final bytes in <List<int>>[
        _stateKey,
        _root,
        _groupId,
        _kpId,
        _sealed('device'),
        _sealed('group'),
        _sealed('group2'),
        _sealed('kp'),
      ])
        base64Encode(bytes),
      'SENTINEL',
      '"crypto_state"',
      '"crypto_records"',
      '"records"',
      '"state_key"',
      '"sealed_state"',
    ];

/// The keys a version 6 backup holds, and nothing else.
const _v6Keys = <String>{
  'version',
  'history_namespace',
  'history',
  'reactions',
  'pins',
  'starred',
  'conversation_prefs',
  'account',
  'conversations',
  'messages',
};

Future<void> _seedDevice(LocalStore store, Session session) async {
  await store.saveSession(session);
  await store.saveCryptoState(_first(), 10);
  await store.commitLocalMlsState(
      expectedCounter: 1, expectedCursor: 10, state: _second());
  expect(await store.loadCryptoRecords(), hasLength(2));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-d70-backup-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    await SecureLocalStore.releaseInstanceLocks();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  SecureLocalStore createStore(String namespace) => SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        namespace: namespace,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );

  Future<List<int>> sourceBackup(LocalStore store) async {
    await _seedDevice(store, _source);
    await store.saveSnapshot(
        <Conversation>[Conversation(id: 'conv_1', kind: 'dm', title: 'Chat')],
        const <String, List<ReceivedMessageEnvelope>>{},
        10);
    await store.commitMlsTransition(MlsStateTransition(
      messageId: 'application:11:m1',
      conversationId: 'conv_1',
      expectedCounter: 2,
      expectedCursor: 10,
      state: StoredCryptoState(counter: 3, stateKey: _stateKey, sealedState: [
        ..._root,
        3
      ], changes: <CryptoRecordChange>[
        CryptoRecordChange(
            kind: cryptoRecordKindGroup,
            recordId: _groupId,
            generation: 3,
            sealed: _sealed('group3')),
      ]),
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
    expect(await store.loadCryptoRecords(), hasLength(2));
    return store.exportBackup();
  }

  /// [current] as a version 5 backup that still holds a crypto state.
  List<int> legacyV5(List<int> current) {
    final root =
        Map<String, Object?>.from(jsonDecode(utf8.decode(current)) as Map);
    root
      ..['version'] = 5
      ..remove('account')
      ..['account_id'] = _source.accountId
      ..['device_id'] = _source.deviceId
      ..['session'] = <String, Object?>{
        'base_url': _source.baseUrl,
        'token': _source.token,
        'account_id': _source.accountId,
        'device_id': _source.deviceId,
      }
      ..['cursor'] = 11
      ..['crypto_state'] = <String, Object?>{
        'counter': 3,
        'state_key': base64Encode(_stateKey),
        'sealed_state': base64Encode(_root),
      };
    return utf8.encode(jsonEncode(root));
  }

  Future<void> expectNoCryptoState(LocalStore store) async {
    expect(await store.loadCryptoState(), isNull);
    expect(await store.loadCryptoRecords(), isEmpty);
    expect(await store.loadSyncCursor(), 0);
    final session = await store.loadSession();
    expect(session, isNotNull);
    expect(isRestoredAccountSession(session!), isTrue);
    expect((await store.loadMessages('conv_1')).single.body, 'hello');
  }

  for (final memory in <bool>[true, false]) {
    final label = memory ? 'memory store' : 'encrypted store';
    LocalStore store(String namespace) =>
        memory ? MemoryLocalStore() : createStore(namespace);

    test('the backup holds no root, record or state key ($label)', () async {
      final text = utf8.decode(await sourceBackup(store('source')));
      for (final needle in _forbidden()) {
        expect(text, isNot(contains(needle)), reason: needle);
      }
      final root = Map<String, Object?>.from(jsonDecode(text) as Map);
      expect(root['version'], 6);
      expect(root.keys.toSet(), _v6Keys);
    });

    test('a restore over a device with records leaves none ($label)', () async {
      final backup = await sourceBackup(store('source'));
      final target = store('target');
      await _seedDevice(target, _target);
      await target.restoreBackup(backup);
      await expectNoCryptoState(target);
    });

    test(
        'an old backup with a crypto state restores none over a device '
        'with records ($label)', () async {
      final backup = legacyV5(await sourceBackup(store('source')));
      final target = store('legacy');
      await _seedDevice(target, _target);
      await target.restoreBackup(backup);
      await expectNoCryptoState(target);
    });
  }
}
