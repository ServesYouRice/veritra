import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-lease-fence-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    await SecureLocalStore.releaseInstanceLocks();
    await directory.delete(recursive: true);
  });

  SecureLocalStore createStore() => SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );

  LocalSyncLease lease(int generation) => LocalSyncLease(
        origin: 'https://example.test',
        accountId: 'acct_1',
        deviceId: 'dev_1',
        generation: generation,
      );

  ReceivedMessageEnvelope envelope(String id, String key) =>
      ReceivedMessageEnvelope(
        id: id,
        conversationId: 'conv_1',
        senderAccountId: 'acct_1',
        senderDeviceId: 'dev_1',
        idempotencyKey: key,
        ciphertext: <int>[4, 5, 6],
        cryptoProtocol: 'mls10-openmls-v1',
        createdAt: DateTime.utc(2026, 7, 29),
      );

  // The fenced writer's event differs from the holder's in every field a
  // leaked write could leave behind, and the store is checked between the
  // two commits, so a write that landed before the fence threw shows up.
  test('a fenced sync commit leaves the store untouched', () async {
    final first = createStore();
    await first.saveSnapshot(
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')],
      const <String, List<ReceivedMessageEnvelope>>{},
      0,
    );
    await first.acquireSyncLease(lease(1));
    final second = createStore();
    await second.acquireSyncLease(lease(2));

    await expectLater(
      first.commitSyncEvent(SyncEventCommit(
        eventKey: 'sync:fenced',
        conversationId: 'conv_1',
        expectedCursor: 0,
        cursor: 1,
        envelope: envelope('msg_fenced', 'received_fenced'),
      )),
      throwsStateError,
    );

    expect(await second.loadSyncCursor(), 0);
    expect(await second.hasProcessedMlsMessage('sync:fenced'), isFalse);
    expect(
        (await second.loadSnapshot())?.messagesByConversation['conv_1'] ??
            const <ReceivedMessageEnvelope>[],
        isEmpty);

    // The holder can still commit the same cursor step, and only its event
    // is stored.
    await second.commitSyncEvent(SyncEventCommit(
      eventKey: 'sync:holder',
      conversationId: 'conv_1',
      expectedCursor: 0,
      cursor: 1,
      envelope: envelope('msg_holder', 'received_holder'),
    ));
    expect(await second.loadSyncCursor(), 1);
    expect(await second.hasProcessedMlsMessage('sync:fenced'), isFalse);
    expect(await second.hasProcessedMlsMessage('sync:holder'), isTrue);
    expect(
        (await second.loadSnapshot())
            ?.messagesByConversation['conv_1']
            ?.map((m) => m.id),
        <String>['msg_holder']);
  });
}
