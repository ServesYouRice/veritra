import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';

/// L2-3, local schema 43: unspent sealed sender tokens, the issuer key pin,
/// and the sealed reveal columns of `local_frank_reveals`. Every step is
/// idempotent, so the step can be renumbered when C7's 41 and 42 land.

const _origin = 'https://chat.example.org';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('veritra-l2-s43-');
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<Set<String>> tables(EncryptedLocalDatabase db) async => (await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
          .get())
      .map((row) => row.read<String>('name'))
      .toSet();

  Future<Set<String>> revealColumns(EncryptedLocalDatabase db) async =>
      (await db
              .customSelect(
                  "SELECT name FROM pragma_table_info('local_frank_reveals')")
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();

  Future<Set<String>> columnsOf(
          EncryptedLocalDatabase db, String table) async =>
      (await db
              .customSelect("SELECT name FROM pragma_table_info('$table')")
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();

  SealedToken token(int seed, {int epoch = 20404}) => SealedToken(
        conversationId: 'conv_1',
        keyId: 'a' * 32,
        epoch: epoch,
        nonce: List<int>.generate(32, (i) => (seed * 13 + i) & 0xff),
        output: List<int>.filled(64, seed),
      );

  test('a new database has the tables and columns', () async {
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(EncryptedLocalDatabase.currentSchemaVersion, 43);
    expect(await tables(db), containsAll(SealedSenderSql.tables));
    expect(await revealColumns(db),
        containsAll(<String>['designation', 'sender_account_id']));
    // Owner decision (deniability): no signature over a payload is kept.
    expect(await revealColumns(db),
        isNot(anyOf(contains('signature'), contains('signing_key'))));
    expect(
        await columnsOf(db, 'local_device_list_keys'), contains('frank_key'));
  });

  test('tokens: per conversation cap, oldest day first, taken once', () async {
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
        await db.writeSealedTokens(<SealedToken>[
          token(1, epoch: 20404),
          token(2, epoch: 20403),
          token(1, epoch: 20404), // same nonce: ignored
          token(3, epoch: 20405), // tomorrow
          token(4, epoch: 20402), // past its day
        ]),
        5);
    expect(
        await db.countSealedTokens('conv_1', keyId: 'a' * 32, epoch: 20404), 1);
    final first =
        await db.takeSealedToken('conv_1', keyId: 'a' * 32, epoch: 20404);
    expect(first!.epoch, 20403);
    final second =
        await db.takeSealedToken('conv_1', keyId: 'a' * 32, epoch: 20404);
    expect(second!.epoch, 20404);
    // Tomorrow's is not spent today; one past its day never is.
    expect(await db.takeSealedToken('conv_1', keyId: 'a' * 32, epoch: 20404),
        isNull);
    await db.dropSealedTokens(minEpoch: 20403);
    expect(
        await db.countSealedTokens('conv_1', keyId: 'a' * 32, epoch: 20402), 0);
    expect(
        await db.countSealedTokens('conv_1', keyId: 'a' * 32, epoch: 20405), 1);
    await db.dropSealedTokens(conversationId: 'conv_1');
    expect(
        await db.countSealedTokens('conv_1', keyId: 'a' * 32, epoch: 20405), 0);
    await db.writeSealedTokens(<SealedToken>[
      for (var i = 0; i < maxSealedTokensPerConversation + 5; i++)
        token(100 + i),
    ]);
    final held = await db
        .customSelect('SELECT COUNT(*) AS n FROM local_sealed_tokens')
        .getSingle();
    expect(
        held.read<int>('n'), lessThanOrEqualTo(maxSealedTokensPerConversation));
  });

  test('upgrading from schema 40 keeps reveals and adds the columns', () async {
    final file = File('${directory.path}/old.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    // Shape the database as schema 40 had it.
    await db.customStatement('DROP TABLE local_sealed_tokens');
    await db.customStatement('DROP TABLE local_sealed_key_pins');
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.customStatement('DROP TABLE local_frank_reveals');
    await db.customStatement('CREATE TABLE local_frank_reveals ('
        'message_key TEXT PRIMARY KEY NOT NULL REFERENCES local_messages(key) ON DELETE CASCADE,'
        'conversation_id TEXT NOT NULL, envelope_id TEXT NOT NULL,'
        'frank_key BLOB NOT NULL CHECK(length(frank_key)=32),'
        'payload BLOB NOT NULL CHECK(length(payload) BETWEEN 1 AND 65536),'
        'stored_at INTEGER NOT NULL)');
    await db.customStatement(
        'INSERT INTO local_frank_reveals VALUES (?, ?, ?, ?, ?, ?)', <Object?>[
      'dev_b:act1',
      'conv_1',
      'msg_1',
      Uint8List(32),
      Uint8List.fromList(<int>[123, 125]),
      1
    ]);
    await db.customStatement('PRAGMA user_version = 40');
    await db.close();

    db = EncryptedLocalDatabase(NativeDatabase(file));
    final version = (await db.customSelect('PRAGMA user_version').getSingle())
        .read<int>('user_version');
    expect(version, 43);
    expect(await tables(db), containsAll(SealedSenderSql.tables));
    expect(await revealColumns(db),
        containsAll(<String>['designation', 'sender_account_id']));
    // Owner decision (deniability): no signature over a payload is kept.
    expect(await revealColumns(db),
        isNot(anyOf(contains('signature'), contains('signing_key'))));
    expect(
        await columnsOf(db, 'local_device_list_keys'), contains('frank_key'));
    final kept = (await db.readFrankReveal('dev_b:act1'))!;
    expect(kept.sealed, isFalse);
    expect(kept.envelopeId, 'msg_1');
    await db.writeSealedKeyPin(SealedKeyPin(
        origin: _origin,
        keyId: 'a' * 32,
        publicKey: List<int>.filled(32, 2),
        pinnedAt: 1));
    expect((await db.readSealedKeyPin(_origin))!.changed, isFalse);
    // The step runs again without harm (a renumbered upgrade).
    await db.customStatement('PRAGMA user_version = 42');
    await db.close();
    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect((await db.readSealedKeyPin(_origin))!.keyId, 'a' * 32);
    expect((await db.readFrankReveal('dev_b:act1'))!.envelopeId, 'msg_1');
  });

  test('an earlier draft of 43 loses its signature columns on upgrade',
      () async {
    final file = File('${directory.path}/draft.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.customStatement(
        'ALTER TABLE local_frank_reveals ADD COLUMN signature BLOB');
    await db.customStatement(
        'ALTER TABLE local_frank_reveals ADD COLUMN signing_key BLOB');
    expect(await revealColumns(db), containsAll(<String>['signature']));
    await db.customStatement('PRAGMA user_version = 42');
    await db.close();
    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        43);
    expect(await revealColumns(db),
        isNot(anyOf(contains('signature'), contains('signing_key'))));
    expect(await revealColumns(db), contains('designation'));
  });

  test('a designation is whole entries, 1 to 16, or none', () async {
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          key: 'dev_b:act1',
          conversationId: 'conv_1',
          senderAccountId: 'acct_b',
          senderDeviceId: 'dev_b',
          kind: 'text',
          createdAt: 1,
          state: 'received',
        ));
    Future<void> write(Uint8List? designation) => db.customStatement(
            'INSERT OR REPLACE INTO local_frank_reveals (message_key, '
            'conversation_id, envelope_id, frank_key, payload, stored_at, '
            'designation, sender_account_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              'dev_b:act1',
              'conv_1',
              'msg_1',
              Uint8List(32),
              Uint8List.fromList(<int>[123, 125]),
              1,
              designation,
              'acct_b',
            ]);
    await write(null);
    await write(Uint8List(48));
    await write(Uint8List(16 * 48));
    for (final bad in <int>[1, 47, 49, 64, 17 * 48]) {
      await expectLater(write(Uint8List(bad)), throwsA(anything),
          reason: '$bad bytes');
    }
  });

  // Review H1, the database half: an own echo never re-points a row that
  // is already linked to another server id, and a sealed echo settles the
  // digest of the own post.
  test('an own echo keeps a linked server id and settles the digest', () async {
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          key: 'dev_alice:key_1',
          serverMessageId: const Value('srv_1'),
          conversationId: 'conv_1',
          senderAccountId: 'acct_alice',
          senderDeviceId: 'dev_alice',
          kind: 'text',
          createdAt: 1,
          state: 'sent',
        ));
    String echo(String id, {bool sealed = false}) =>
        jsonEncode(<String, Object?>{
          'id': id,
          'conversation_id': 'conv_1',
          'idempotency_key': 'key_1',
          'crypto_metadata': <String, Object?>{},
          'created_at': '2026-11-12T00:00:00Z',
          if (sealed) 'sealed': true,
        });
    await db.commitSyncEvent(
      eventKey: 'application:1:srv_2',
      conversationId: 'conv_1',
      expectedCursor: 0,
      cursor: 1,
      envelope: (
        id: 'srv_2',
        conversationId: 'conv_1',
        payloadJson: echo('srv_2')
      ),
      ownMessageKey: 'dev_alice:key_1',
    );
    final row = await (db.select(db.localMessages)).getSingle();
    expect(row.serverMessageId, 'srv_1');
    await db.customStatement(
        'INSERT INTO local_sealed_own_posts (conversation_id, idempotency_key, '
        'ciphertext_sha256, fallback_json, created_at) VALUES (?, ?, ?, ?, ?)',
        <Object?>['conv_1', 'key_1', Uint8List(32), '{}', 1]);
    expect(await db.readSealedOwnPostDigest('conv_1', 'key_1'), hasLength(32));
    await db.commitSyncEvent(
      eventKey: 'application:2:srv_1',
      conversationId: 'conv_1',
      expectedCursor: 1,
      cursor: 2,
      envelope: (
        id: 'srv_1',
        conversationId: 'conv_1',
        payloadJson: echo('srv_1', sealed: true)
      ),
      ownMessageKey: 'dev_alice:key_1',
    );
    expect(await db.readSealedOwnPostDigest('conv_1', 'key_1'), isNull);
  });

  test('only a queued sealed entry is replaced, and its plaintext goes',
      () async {
    // Review M2: the identified re-encryption takes the sealed entry's
    // place, resets its failure, and drops the plaintext (the digest stays
    // for a late echo of an earlier attempt).
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var counter = 0;
    Future<void> commit(String payloadJson,
            {bool replace = false, SealedOwnPost? ownPost}) =>
        db.commitOutgoingApplicationTransition(
          expectedCounter: counter,
          expectedCursor: 0,
          counter: ++counter,
          stateKey: List<int>.filled(32, 1),
          sealedState: const <int>[1],
          idempotencyKey: 'key_1',
          conversationId: 'conv_1',
          payloadJson: payloadJson,
          draftText: null,
          maxEntries: 10,
          sealedOwnPost: ownPost,
          replacesSealedEntry: replace,
        );
    // Nothing queued: nothing to replace.
    await expectLater(commit('{"x":1}', replace: true), throwsStateError);
    counter = 0;
    await commit('{"identified":true}');
    // An identified entry is not replaced either.
    await expectLater(commit('{"x":2}', replace: true), throwsStateError);
    counter = 1;
    await db.deleteOutbox('key_1');
    await commit('{"l2_sealed_token":{}}',
        ownPost: SealedOwnPost(
            conversationId: 'conv_1',
            idempotencyKey: 'key_1',
            ciphertextSha256: List<int>.filled(32, 7),
            fallbackJson: '{"type":"text"}'));
    expect(await db.readSealedOwnPostFallback('conv_1', 'key_1'), isNotNull);
    await (db.update(db.localOutboxEntries)
          ..where((table) => table.idempotencyKey.equals('key_1')))
        .write(const LocalOutboxEntriesCompanion(
            attemptCount: Value(3),
            terminal: Value(true),
            failureClass: Value('terminal:409:sealed_not_eligible')));
    await commit('{"identified":2}', replace: true);
    final entry = await db.select(db.localOutboxEntries).getSingle();
    expect(entry.payloadJson, '{"identified":2}');
    expect(entry.attemptCount, 0);
    expect(entry.terminal, isFalse);
    expect(entry.failureClass, isNull);
    expect(await db.readSealedOwnPostDigest('conv_1', 'key_1'), hasLength(32));
    expect(await db.readSealedOwnPostFallback('conv_1', 'key_1'), isNull);
  });

  test('a pin refuses malformed keys', () async {
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(
        () => db.writeSealedKeyPin(SealedKeyPin(
            origin: _origin,
            keyId: 'short',
            publicKey: List<int>.filled(32, 2),
            pinnedAt: 1)),
        throwsFormatException);
    final pin = SealedKeyPin(
        origin: _origin,
        keyId: 'a' * 32,
        publicKey: List<int>.filled(32, 2),
        pinnedAt: 1);
    await db.writeSealedKeyPin(pin.withSeen('b' * 32, List<int>.filled(32, 3)));
    final read = (await db.readSealedKeyPin(_origin))!;
    expect(read.changed, isTrue);
    expect(read.seenKeyId, 'b' * 32);
  });
}
