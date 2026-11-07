import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'schema_fixtures.dart';

/// C6, local schema 19 (docs/designs/C6-reports-franking.md, D95): a receiver
/// keeps the franking key `kf` and the exact canonical payload bytes `P` of
/// each franked message it stores, so the message can be reported later, and
/// the reveal goes whenever the message does. Also the pinned report keys.

const _conversation = 'conv_1';
const _origin = 'https://chat.example.org';

List<int> _kf(int fill) => List<int>.filled(32, fill);

/// What a franked text's `P` looks like (the exact bytes are the sender's).
List<int> _payload(String text) => List<int>.unmodifiable(
    '{"v":2,"type":"text","body":{"text":"$text"}}'.codeUnits);

FrankReveal _reveal(String id, {String text = 'a franked secret'}) =>
    FrankReveal(
      messageKey: 'dev_peer:$id',
      conversationId: _conversation,
      envelopeId: 'msg_$id',
      frankKey: _kf(7),
      payload: _payload(text),
    );

InsertMessageEffect _insert(String id, {int? expiresAt}) => InsertMessageEffect(
      key: 'dev_peer:$id',
      serverMessageId: 'msg_$id',
      conversationId: _conversation,
      senderAccountId: 'acct_peer',
      senderDeviceId: 'dev_peer',
      kind: LocalMessageKind.text,
      body: 'a franked secret',
      createdAt: DateTime.utc(2026, 11, 7).millisecondsSinceEpoch,
      state: LocalMessageState.received,
      expiresAt: expiresAt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<EncryptedLocalDatabase> databases;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    directory = await Directory.systemTemp.createTemp('veritra-c6-s19-');
    databases = <EncryptedLocalDatabase>[];
  });

  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    await SecureLocalStore.releaseInstanceLocks();
    if (await directory.exists()) await directory.delete(recursive: true);
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

  Future<void> seedState(LocalStore store) => store.saveCryptoState(
        StoredCryptoState(
          counter: 1,
          stateKey: List<int>.filled(32, 1),
          sealedState: <int>[1],
        ),
        0,
      );

  /// Commits one received application message like the native service does.
  Future<void> receive(
    LocalStore store,
    String id, {
    List<MessageEffect>? effects,
    List<FrankReveal>? reveals,
  }) async {
    final counter = (await store.loadCryptoState())!.counter;
    final cursor = await store.loadSyncCursor();
    await store.commitMlsTransition(MlsStateTransition(
      messageId: 'application:${cursor + 1}:$id',
      conversationId: _conversation,
      expectedCounter: counter,
      expectedCursor: cursor,
      state: StoredCryptoState(
        counter: counter + 1,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[counter + 1],
      ),
      cursor: cursor + 1,
      messageEffects: effects ?? <MessageEffect>[_insert(id)],
      frankReveals: reveals ?? <FrankReveal>[_reveal(id)],
    ));
  }

  group('a reveal is kept with a live received message', () {
    test('kf, the exact P and the envelope id come back byte for byte',
        () async {
      final store = createStore();
      await seedState(store);
      await receive(store, 'one');
      final reveal = await store.loadFrankReveal('dev_peer:one');
      expect(reveal, isNotNull);
      expect(reveal!.frankKey, _kf(7));
      expect(reveal.payload, _payload('a franked secret'));
      expect(reveal.envelopeId, 'msg_one');
      expect(reveal.conversationId, _conversation);
      // It is still there after the database is reopened.
      for (final database in databases) {
        await database.close();
      }
      databases.clear();
      final reopened = createStore();
      expect((await reopened.loadFrankReveal('dev_peer:one'))!.payload,
          _payload('a franked secret'));
    });

    test('toString never prints the message', () {
      expect(_reveal('one').toString(), isNot(contains('secret')));
      expect(_reveal('one').toString(), 'FrankReveal(dev_peer:one)');
    });

    test(
        'an edit, a reaction or an unknown row writes nothing and the cursor '
        'still advances', () async {
      final store = createStore();
      await seedState(store);
      // No row of its own: the effect edits another message.
      await receive(store, 'edit', effects: <MessageEffect>[
        EditMessageEffect(
          targetKey: 'dev_peer:nothing',
          editorAccountId: 'acct_peer',
          body: 'new',
          at: 1,
        ),
      ], reveals: [
        _reveal('edit')
      ]);
      expect(await store.loadFrankReveal('dev_peer:edit'), isNull);
      expect(await store.loadSyncCursor(), 1);
      // Not even one effect: still consumed.
      await receive(store, 'bare',
          effects: <MessageEffect>[], reveals: [_reveal('bare')]);
      expect(await store.loadFrankReveal('dev_peer:bare'), isNull);
      expect(await store.loadSyncCursor(), 2);
    });

    test('a message that arrived already expired keeps no reveal', () async {
      final store = createStore();
      await seedState(store);
      await receive(store, 'old', effects: <MessageEffect>[
        _insert('old',
            expiresAt: DateTime.now()
                .subtract(const Duration(minutes: 1))
                .toUtc()
                .millisecondsSinceEpoch),
      ], reveals: [
        _reveal('old')
      ]);
      expect(await store.loadFrankReveal('dev_peer:old'), isNull);
      expect(await store.loadSyncCursor(), 1);
    });

    test('a reveal that the table would refuse is skipped, not a failure',
        () async {
      final store = createStore();
      await seedState(store);
      await receive(store, 'big', reveals: [
        FrankReveal(
          messageKey: 'dev_peer:big',
          conversationId: _conversation,
          envelopeId: 'msg_big',
          frankKey: _kf(1),
          payload: List<int>.filled(frankRevealMaxPayloadBytes + 1, 1),
        ),
      ]);
      expect(await store.loadFrankReveal('dev_peer:big'), isNull);
      expect(await store.loadSyncCursor(), 1);
      expect(
          (await store.loadMessages(_conversation)).single.key, 'dev_peer:big');
    });
  });

  group('the reveal goes with the message', () {
    test('delete for everyone leaves a tombstone and no text', () async {
      final store = createStore();
      await seedState(store);
      await receive(store, 'one');
      await receive(store, 'two');
      expect(await store.loadFrankReveal('dev_peer:one'), isNotNull);
      await receive(store, 'del', effects: <MessageEffect>[
        DeleteMessageEffect(
          targetKey: 'dev_peer:one',
          deleterAccountId: 'acct_peer',
          at: DateTime.now().millisecondsSinceEpoch,
        ),
      ], reveals: const <FrankReveal>[]);
      // The row stays as a tombstone, so only the trigger can drop this.
      final rows = await store.loadMessages(_conversation);
      expect(
          rows.firstWhere((m) => m.key == 'dev_peer:one').deletedAt, isNotNull);
      expect(await store.loadFrankReveal('dev_peer:one'), isNull);
      expect(await store.loadFrankReveal('dev_peer:two'), isNotNull);
    });

    test('hiding a message drops it', () async {
      final store = createStore();
      await seedState(store);
      await receive(store, 'one');
      await store.hideMessage(_conversation, 'dev_peer:one');
      expect(await store.loadFrankReveal('dev_peer:one'), isNull);
    });

    test('expiry purges it', () async {
      final store = createStore();
      await seedState(store);
      final soon = DateTime.now().toUtc().add(const Duration(minutes: 5));
      await receive(store, 'soon', effects: <MessageEffect>[
        _insert('soon', expiresAt: soon.millisecondsSinceEpoch),
      ]);
      expect(await store.loadFrankReveal('dev_peer:soon'), isNotNull);
      await store.purgeExpiredMessages(
          now: soon.add(const Duration(seconds: 1)));
      expect(await store.loadMessages(_conversation), isEmpty);
      expect(await store.loadFrankReveal('dev_peer:soon'), isNull);
    });

    test('a full reset drops reveals and pins', () async {
      final store = createStore();
      await seedState(store);
      await receive(store, 'one');
      await store.saveReportKeyPin(ReportKeyPin(
          origin: _origin,
          ownerAccountId: 'acct_owner',
          publicKey: _kf(3),
          keyRev: 1,
          pinnedAt: 1));
      await store.clear();
      expect(await store.loadFrankReveal('dev_peer:one'), isNull);
      expect(await store.loadReportKeyPins(_origin), isEmpty);
    });

    test('an identity change drops reveals but not the pins', () async {
      final store = createStore();
      await store.saveSession(const Session(
          baseUrl: _origin,
          token: 't',
          accountId: 'acct_me',
          deviceId: 'dev_me',
          username: 'me',
          deviceSecret: 's'));
      await seedState(store);
      await receive(store, 'one');
      await store.saveReportKeyPin(ReportKeyPin(
          origin: _origin,
          ownerAccountId: 'acct_owner',
          publicKey: _kf(3),
          keyRev: 1,
          pinnedAt: 1));
      await store.saveSession(const Session(
          baseUrl: _origin,
          token: 't2',
          accountId: 'acct_other',
          deviceId: 'dev_other',
          username: 'other',
          deviceSecret: 's2'));
      expect(await store.loadFrankReveal('dev_peer:one'), isNull);
      expect(await store.loadReportKeyPins(_origin), hasLength(1));
    });
  });

  group('pinned report keys', () {
    test('a pin is stored per origin and owner and replaced when pinned again',
        () async {
      final store = createStore();
      Future<void> pin(String origin, String owner, int fill, int rev) =>
          store.saveReportKeyPin(ReportKeyPin(
              origin: origin,
              ownerAccountId: owner,
              publicKey: _kf(fill),
              keyRev: rev,
              pinnedAt: 10 + rev));
      await pin(_origin, 'acct_a', 1, 1);
      await pin(_origin, 'acct_b', 2, 1);
      await pin('https://other.example.org', 'acct_a', 9, 1);
      expect(
          (await store.loadReportKeyPins(_origin)).map((p) => p.ownerAccountId),
          ['acct_a', 'acct_b']);
      await pin(_origin, 'acct_a', 5, 2);
      final replaced = (await store.loadReportKeyPin(_origin, 'acct_a'))!;
      expect(replaced.publicKey, _kf(5));
      expect(replaced.keyRev, 2);
      await store.deleteReportKeyPin(_origin, 'acct_b');
      expect(await store.loadReportKeyPin(_origin, 'acct_b'), isNull);
      expect(await store.loadReportKeyPins('https://other.example.org'),
          hasLength(1));
    });

    test('a pin that is not 32 bytes is refused', () async {
      final store = createStore();
      expect(
          () => store.saveReportKeyPin(ReportKeyPin(
              origin: _origin,
              ownerAccountId: 'acct_a',
              publicKey: const [1, 2, 3],
              keyRev: 1,
              pinnedAt: 1)),
          throwsA(anything));
    });
  });

  group('upgrade from schema 18', () {
    Future<int> version(EncryptedLocalDatabase db) async =>
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version');

    Future<Set<String>> objects(EncryptedLocalDatabase db) async => {
          for (final row in await db
              .customSelect(
                  "SELECT name FROM sqlite_master WHERE name LIKE 'local_frank%' "
                  "OR name LIKE 'local_report_key%'")
              .get())
            row.read<String>('name')
        };

    Future<void> commit(EncryptedLocalDatabase db,
        {required int counter,
        required String id,
        List<FrankReveal> reveals = const <FrankReveal>[]}) {
      return db.commitMlsTransition(
        messageId: 'application:$counter:$id',
        conversationId: _conversation,
        expectedCounter: counter - 1,
        expectedCursor: counter - 1,
        counter: counter,
        stateKey: List<int>.filled(32, 1),
        sealedState: <int>[counter],
        cursor: counter,
        upsertedEnvelopes: const [],
        deletedEnvelopeIds: const [],
        messageEffects: <MessageEffect>[_insert(id)],
        frankReveals: reveals,
      );
    }

    test('a new database has the schema 19 tables and trigger', () async {
      final db = EncryptedLocalDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      expect(EncryptedLocalDatabase.currentSchemaVersion,
          greaterThanOrEqualTo(19));
      expect(await version(db), EncryptedLocalDatabase.currentSchemaVersion);
      expect(
          await objects(db),
          containsAll(<String>{
            'local_frank_reveals',
            'local_report_key_pins',
            'local_frank_reveals_tombstone',
          }));
    });

    test('keeps every stored message, adds the tables, and then works',
        () async {
      final file = File('${directory.path}/schema18.db');
      var db = EncryptedLocalDatabase(NativeDatabase(file));
      await commit(db, counter: 1, id: 'old');
      // A schema 18 database: the same data, without schema 19.
      await stripFrankRevealSchema(db);
      await db.customStatement('PRAGMA user_version = 18');
      expect(await objects(db), isEmpty);
      await db.close();

      db = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(await version(db), EncryptedLocalDatabase.currentSchemaVersion);
      expect(db.upgradeStarted, isTrue);
      expect(await objects(db), hasLength(4));
      // The message received before the upgrade is untouched and has no
      // reveal: it cannot be reported.
      expect((await db.readAllMessages()).map((m) => m.key), ['dev_peer:old']);
      expect(await db.readFrankReveal('dev_peer:old'), isNull);

      // A later message keeps its reveal, and a hide takes only that one.
      await commit(db, counter: 2, id: 'new', reveals: [_reveal('new')]);
      final kept = await db.readFrankReveal('dev_peer:new');
      expect(kept!.payload, _payload('a franked secret'));
      expect(kept.frankKey, _kf(7));
      await db.hideMessage(_conversation, 'dev_peer:new', 5);
      expect(await db.readFrankReveal('dev_peer:new'), isNull);
      expect((await db.readAllMessages()).map((m) => m.key),
          containsAll(['dev_peer:old', 'dev_peer:new']));
    });
  });
}
