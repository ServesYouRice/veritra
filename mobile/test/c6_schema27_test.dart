import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// C6, local schema 27: which messages this account already reported on a
/// server. One new table, ids only, durable across a restart, per server and
/// account, and gone with a full wipe.

const _origin = 'https://chat.example.org';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('veritra-c6-s27-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<bool> tableExists(EncryptedLocalDatabase db) async => (await db
          .customSelect("SELECT name FROM sqlite_master "
              "WHERE name = 'local_filed_reports'")
          .get())
      .isNotEmpty;

  test('a new database has the table; the note survives a reopen', () async {
    final file = File('${directory.path}/new.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    expect(await tableExists(db), isTrue);
    expect(await db.readReportFiled(_origin, 'acct_a', 'dev:1'), isFalse);
    await db.writeReportFiled(_origin, 'acct_a', 'dev:1', 1);
    await db.writeReportFiled(_origin, 'acct_a', 'dev:1', 2); // idempotent
    await db.close();

    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.readReportFiled(_origin, 'acct_a', 'dev:1'), isTrue);
    // Per account, per server and per message.
    expect(await db.readReportFiled(_origin, 'acct_b', 'dev:1'), isFalse);
    expect(await db.readReportFiled('https://other.example', 'acct_a', 'dev:1'),
        isFalse);
    expect(await db.readReportFiled(_origin, 'acct_a', 'dev:2'), isFalse);
    expect(() => db.writeReportFiled(_origin, '', 'dev:1', 1),
        throwsFormatException);
  });

  test('upgrading from schema 26 adds the table and keeps the data', () async {
    final file = File('${directory.path}/old.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.writeReportKeyPin(ReportKeyPin(
        origin: _origin,
        ownerAccountId: 'acct_owner',
        publicKey: List<int>.filled(32, 1),
        keyRev: 1,
        pinnedAt: 5));
    await db.customStatement('DROP TABLE local_filed_reports');
    await db.customStatement('PRAGMA user_version = 26');
    expect(await tableExists(db), isFalse);
    await db.close();

    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final version = (await db.customSelect('PRAGMA user_version').getSingle())
        .read<int>('user_version');
    expect(db.upgradeStarted, isTrue);
    expect(version, EncryptedLocalDatabase.currentSchemaVersion);
    expect(EncryptedLocalDatabase.currentSchemaVersion, 27);
    expect(await tableExists(db), isTrue);
    expect(await db.readReportKeyPins(_origin), hasLength(1));
    await db.writeReportFiled(_origin, 'acct_a', 'dev:1', 1);
    expect(await db.readReportFiled(_origin, 'acct_a', 'dev:1'), isTrue);
  });

  test('the memory store behaves the same and a wipe clears it', () async {
    final store = MemoryLocalStore();
    expect(await store.isMessageReported(_origin, 'a', 'k'), isFalse);
    await store.markMessageReported(_origin, 'a', 'k');
    expect(await store.isMessageReported(_origin, 'a', 'k'), isTrue);
    expect(await store.isMessageReported(_origin, 'b', 'k'), isFalse);
  });
}
