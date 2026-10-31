import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// D71, D73: a restore drops the outboxes and the MLS state, so an outgoing
/// row still `pending` in the backup could never be sent or resolve. Such
/// rows (and the reactions, pins and stars on them) are not restored, also
/// from a backup written before this rule.

const _session = Session(
  baseUrl: 'https://chat.example.org',
  token: 'tok',
  accountId: 'acct_1',
  deviceId: 'dev_own',
  username: 'alice',
  deviceSecret: 'secret',
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
    directory = await Directory.systemTemp.createTemp('veritra-backup-pend-');
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

  InsertMessageEffect row(String key, String state, String body) =>
      InsertMessageEffect(
        key: key,
        serverMessageId: state == LocalMessageState.pending ? null : 'm_$key',
        conversationId: 'conv_1',
        senderAccountId:
            state == LocalMessageState.received ? 'acct_peer' : 'acct_1',
        senderDeviceId:
            state == LocalMessageState.received ? 'dev_peer' : 'dev_own',
        kind: LocalMessageKind.text,
        body: body,
        createdAt: DateTime.utc(2026, 10, 24).millisecondsSinceEpoch,
        state: state,
      );

  /// A backup holding a received row and a pending own row, with a star
  /// and a reaction on the pending one. The pending row is written into the
  /// backup JSON, as a backup made before this rule could hold it.
  Future<List<int>> backupWithPending(LocalStore store) async {
    await store.saveSession(_session);
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
        row('dev_peer:m1', LocalMessageState.received, 'hello'),
      ],
    ));
    final root = Map<String, Object?>.from(
        jsonDecode(utf8.decode(await store.exportBackup())) as Map);
    final history = (root['history'] as List).cast<Map>();
    final received = Map<String, Object?>.from(history.single);
    root['history'] = <Object?>[
      received,
      <String, Object?>{
        ...received,
        'key': 'dev_own:a1',
        'serverMessageId': null,
        'senderAccountId': 'acct_1',
        'senderDeviceId': 'dev_own',
        'body': 'never sent',
        'state': LocalMessageState.pending,
      },
    ];
    root['reactions'] = <Object?>[
      <String, Object?>{
        'targetKey': 'dev_own:a1',
        'reactorAccountId': 'acct_peer',
        'reaction': '+1',
        'updatedAt': 1,
      },
      <String, Object?>{
        'targetKey': 'dev_peer:m1',
        'reactorAccountId': 'acct_1',
        'reaction': '+1',
        'updatedAt': 1,
      },
    ];
    root['starred'] = <String, Object?>{'dev_own:a1': 1, 'dev_peer:m1': 2};
    return utf8.encode(jsonEncode(root));
  }

  for (final memory in <bool>[true, false]) {
    final label = memory ? 'memory store' : 'encrypted store';

    test('a restore drops pending outgoing rows ($label)', () async {
      final backup =
          await backupWithPending(memory ? MemoryLocalStore() : createStore());
      final target =
          memory ? MemoryLocalStore() : createStore(namespace: 'restored');
      await target.restoreBackup(backup);
      final messages = await target.loadMessages('conv_1');
      expect(messages.map((m) => m.key), <String>['dev_peer:m1']);
      expect(messages.single.body, 'hello');
      expect(messages.any((m) => m.state == LocalMessageState.pending),
          isFalse);
      expect(await target.loadStarred(), <String>{'dev_peer:m1'});
      expect((await target.loadReactions('conv_1')).map((r) => r.targetKey),
          <String>['dev_peer:m1']);
    });
  }
}
