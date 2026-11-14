import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

/// U16, local schema 44: the "Delete for me" Undo table and the reveal
/// trigger that keeps a reveal while a hide can still be undone.
const _oldTrigger = 'CREATE TRIGGER local_frank_reveals_tombstone '
    'AFTER UPDATE OF deleted_at, hidden_at ON local_messages '
    'WHEN NEW.deleted_at IS NOT NULL OR NEW.hidden_at IS NOT NULL '
    'BEGIN DELETE FROM local_frank_reveals WHERE message_key = NEW.key; END';

/// Fails the upgrade right after it created the schema 44 table.
class _FailAfterTable extends EncryptedLocalDatabase {
  _FailAfterTable(super.executor);

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    await super.customStatement(statement, args);
    if (statement.startsWith('CREATE TABLE IF NOT EXISTS local_hide_undo')) {
      throw StateError('crash in the middle of the schema 44 step');
    }
  }
}

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('veritra-u16-s44-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<int> version(EncryptedLocalDatabase db) async =>
      (await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');

  Future<bool> hasTable(EncryptedLocalDatabase db) async =>
      (await db
          .customSelect("SELECT 1 FROM sqlite_master WHERE type = 'table' "
              "AND name = 'local_hide_undo'")
          .getSingleOrNull()) !=
      null;

  Future<String> triggerSql(EncryptedLocalDatabase db) async => (await db
          .customSelect("SELECT sql FROM sqlite_master WHERE type = 'trigger' "
              "AND name = 'local_frank_reveals_tombstone'")
          .getSingle())
      .read<String>('sql');

  /// A schema 43 database with one message and its reveal.
  Future<File> schema43() async {
    final file = File('${directory.path}/s43.db');
    final db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          key: 'dev_b:m1',
          conversationId: 'conv_1',
          senderAccountId: 'acct_b',
          senderDeviceId: 'dev_b',
          kind: 'text',
          body: const Value('kept words'),
          createdAt: 1,
          state: 'received',
        ));
    await db.customStatement(
        'INSERT INTO local_frank_reveals (message_key, conversation_id, '
        'envelope_id, frank_key, payload, stored_at) VALUES (?, ?, ?, ?, ?, ?)',
        <Object?>[
          'dev_b:m1',
          'conv_1',
          'msg_1',
          Uint8List(32),
          Uint8List.fromList(<int>[123, 125]),
          1,
        ]);
    // The shape schema 43 had: the old trigger, no Undo table.
    await db.customStatement('DROP TRIGGER local_frank_reveals_tombstone');
    await db.customStatement('DROP TABLE local_hide_undo');
    await db.customStatement(_oldTrigger);
    await db.customStatement('PRAGMA user_version = 43');
    await db.close();
    return file;
  }

  test('a new database has the table and the new trigger', () async {
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(EncryptedLocalDatabase.currentSchemaVersion, 44);
    expect(await version(db), 44);
    expect(await hasTable(db), isTrue);
    expect(await triggerSql(db), contains('local_hide_undo'));
  });

  test('upgrading from 43 keeps every row and Undo keeps the reveal', () async {
    final file = await schema43();
    final db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await version(db), 44);
    expect(await hasTable(db), isTrue);
    expect(await triggerSql(db), contains('local_hide_undo'));
    expect((await db.readMessage('dev_b:m1'))!.body, 'kept words');
    expect((await db.readFrankReveal('dev_b:m1'))!.envelopeId, 'msg_1');

    expect(await db.hideMessage('conv_1', 'dev_b:m1', 5), isTrue);
    expect(await db.readFrankReveal('dev_b:m1'), isNull);
    expect(await db.unhideMessage('dev_b:m1', 6), isTrue);
    expect((await db.readMessage('dev_b:m1'))!.body, 'kept words');
    expect((await db.readFrankReveal('dev_b:m1'))!.envelopeId, 'msg_1');

    // A final hide takes the reveal, as schema 19 always did.
    await db.hideMessage('conv_1', 'dev_b:m1', 7);
    await db.finishHides();
    final reveals = await db
        .customSelect('SELECT COUNT(*) AS n FROM local_frank_reveals')
        .getSingle();
    expect(reveals.read<int>('n'), 0);
  });

  test('a crash in the step keeps schema 43 whole; the next open upgrades',
      () async {
    final file = await schema43();
    final failing = _FailAfterTable(NativeDatabase(file));
    await expectLater(failing.readMessages('conv_1'), throwsA(anything));
    await failing.close();

    // The file as the crash left it, read without any migration.
    final raw = sqlite3.open(file.path);
    try {
      expect(raw.select('PRAGMA user_version').single['user_version'], 43);
      expect(
          raw.select("SELECT 1 FROM sqlite_master WHERE type = 'table' "
              "AND name = 'local_hide_undo'"),
          isEmpty);
      expect(
          raw
              .select("SELECT sql FROM sqlite_master "
                  "WHERE name = 'local_frank_reveals_tombstone'")
              .single['sql'],
          isNot(contains('local_hide_undo')));
    } finally {
      raw.close();
    }

    final db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await version(db), 44);
    expect(await hasTable(db), isTrue);
    expect((await db.readMessage('dev_b:m1'))!.body, 'kept words');
  });

  test('a database at 44 without the table gets it on open', () async {
    final file = await schema43();
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    expect(await hasTable(db), isTrue);
    // Another branch numbered 44 without this step.
    await db.customStatement('DROP TRIGGER local_frank_reveals_tombstone');
    await db.customStatement('DROP TABLE local_hide_undo');
    await db.customStatement(_oldTrigger);
    await db.close();

    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await version(db), 44);
    expect(await hasTable(db), isTrue);
    expect(await triggerSql(db), contains('local_hide_undo'));
  });
}
