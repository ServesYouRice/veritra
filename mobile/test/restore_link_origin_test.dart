import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// D71, D77: a device link over a restored account keeps the restored
/// history when the server is the same. The link canonicalizes the server
/// origin, so the comparison does too: a restored session whose origin was
/// stored as `https://Chat.Example.org:443` matches a linked
/// `https://chat.example.org`.

const _stored = Session(
  baseUrl: 'https://Chat.Example.org:443',
  token: 'tok',
  accountId: 'acct_1',
  deviceId: 'dev_old',
  username: 'alice',
  deviceSecret: 'secret',
);

const _linked = Session(
  baseUrl: 'https://chat.example.org',
  token: 'new-token',
  accountId: 'acct_1',
  deviceId: 'dev_new',
  deviceSecret: 'new-secret',
);

StoredCryptoState _state(int counter) => StoredCryptoState(
    counter: counter,
    stateKey: List<int>.filled(32, 7),
    sealedState: utf8.encode('sealed'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-link-origin-');
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
    await store.saveSession(_stored);
    await store.saveCryptoState(_state(1), 10);
    await store.saveSnapshot(<Conversation>[
      Conversation(id: 'conv_1', kind: 'dm', title: 'Chat')
    ], const <String, List<ReceivedMessageEnvelope>>{}, 10);
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
    return store.exportBackup();
  }

  for (final memory in <bool>[true, false]) {
    final label = memory ? 'memory store' : 'encrypted store';

    test('a link to the same server in another spelling keeps the restored '
        'history ($label)', () async {
      final backup =
          await seededBackup(memory ? MemoryLocalStore() : createStore());
      final target =
          memory ? MemoryLocalStore() : createStore(namespace: 'restored');
      await target.restoreBackup(backup);
      expect(isRestoredAccountSession((await target.loadSession())!), isTrue);
      await target.saveSession(_linked);
      expect((await target.loadMessages('conv_1')).single.body, 'hello');
    });

    test('a link to another server still drops the restored history '
        '($label)', () async {
      final backup =
          await seededBackup(memory ? MemoryLocalStore() : createStore());
      final target =
          memory ? MemoryLocalStore() : createStore(namespace: 'other');
      await target.restoreBackup(backup);
      await target.saveSession(const Session(
        baseUrl: 'https://other.example.org',
        token: 'new-token',
        accountId: 'acct_1',
        deviceId: 'dev_new',
        deviceSecret: 'new-secret',
      ));
      expect(await target.loadMessages('conv_1'), isEmpty);
    });
  }
}
