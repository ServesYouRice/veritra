import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/encrypted_database.dart';

/// Round 8 integration: C7 numbered its columns 41 and 42, L2-3 its step 43.
/// A device that ran the sealed branch alone is at 43 without C7's columns
/// and never runs the upgrade again, so the columns come on open; a device
/// at 40 runs both steps. The sealed branch's open-time repair (draft 43
/// columns, the first pin time) still runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('veritra-s43-c7-');
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<Set<String>> columnsOf(
          EncryptedLocalDatabase db, String table) async =>
      (await db
              .customSelect("SELECT name FROM pragma_table_info('$table')")
              .get())
          .map((row) => row.read<String>('name'))
          .toSet();

  Future<int> userVersion(EncryptedLocalDatabase db) async =>
      (await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');

  DeviceListPin pin(int checkedAt) => DeviceListPin(
        accountId: 'acct_b',
        version: 1,
        listHash: List<int>.filled(32, 1),
        listId: List<int>.filled(32, 1),
        headStatement: const <int>[1],
        conflict: false,
        checkedAt: checkedAt,
        keys: <DeviceListKeyRow>[
          DeviceListKeyRow(
              deviceId: utf8.encode('dev_b'),
              signingKey: List<int>.filled(32, 2),
              addedVersion: 1,
              removedVersion: 0,
              frankKey: List<int>.filled(32, 3)),
        ],
      );

  /// A database as the current code writes it, with one received message
  /// and one device-list pin, C7's two columns dropped, then [shape]. The
  /// open under test is the next one.
  Future<File> shaped(String name, int version,
      Future<void> Function(EncryptedLocalDatabase db) shape) async {
    final file = File('${directory.path}/$name.db');
    final db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          key: 'dev_b:act1',
          conversationId: 'conv_1',
          senderAccountId: 'acct_b',
          senderDeviceId: 'dev_b',
          kind: 'text',
          createdAt: 1,
          state: 'received',
        ));
    expect(
        await db.writeDeviceListPin(pin(4242), expectedVersion: null), isTrue);
    for (final column in const ['c7_gen', 'c7_former']) {
      await db
          .customStatement('ALTER TABLE local_messages DROP COLUMN $column');
    }
    expect(await columnsOf(db, 'local_messages'),
        isNot(anyOf(contains('c7_gen'), contains('c7_former'))));
    await shape(db);
    await db.customStatement('PRAGMA user_version = $version');
    await db.close();
    return file;
  }

  Future<void> expectMerged(EncryptedLocalDatabase db) async {
    expect(await userVersion(db), EncryptedLocalDatabase.currentSchemaVersion);
    expect(EncryptedLocalDatabase.currentSchemaVersion, 43);
    expect(await columnsOf(db, 'local_messages'),
        containsAll(<String>['c7_gen', 'c7_former', 'sender_removed']));
    expect(await columnsOf(db, 'local_frank_reveals'),
        containsAll(<String>['designation', 'sender_account_id']));
    expect(
        await columnsOf(db, 'local_device_list_keys'), contains('frank_key'));
    expect(
        await columnsOf(db, 'local_device_list_heads'), contains('pinned_at'));
    // The row is kept and reads through the generated (C7) columns.
    final rows = await db.select(db.localMessages).get();
    expect(rows.map((row) => row.key), <String>['dev_b:act1']);
    expect(rows.single.c7Gen, isNull);
    expect(rows.single.c7Former, isNull);
    // The C7 former-member check still holds on the added column.
    await expectLater(
        db.customStatement(
            "UPDATE local_messages SET c7_former = 3 WHERE key = 'dev_b:act1'"),
        throwsA(anything));
  }

  test(
      'a sealed-branch 43 without C7 columns gets them on open, and the '
      'sealed repair still runs', () async {
    // The sealed branch at 43, in its draft shape, so its own open-time
    // repair has work too.
    final file = await shaped('sealed43', 43, (db) async {
      await db.customStatement(
          'ALTER TABLE local_device_list_heads DROP COLUMN pinned_at');
      await db.customStatement(
          'ALTER TABLE local_frank_reveals ADD COLUMN signature BLOB');
    });
    final db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await expectMerged(db);
    // _repairSchema43: draft column gone, first pin time backfilled.
    expect(await columnsOf(db, 'local_frank_reveals'),
        isNot(contains('signature')));
    expect((await db.readDeviceListPin('acct_b'))!.pinnedAt, 4242);
  });

  test('a store at 40 upgrades to the merged 43', () async {
    final file = await shaped('at40', 40, (db) async {
      for (final table in SealedSenderSql.tables) {
        await db.customStatement('DROP TABLE $table');
      }
      for (final column in const ['designation', 'sender_account_id']) {
        await db.customStatement(
            'ALTER TABLE local_frank_reveals DROP COLUMN $column');
      }
      await db.customStatement(
          'ALTER TABLE local_device_list_heads DROP COLUMN pinned_at');
    });
    final db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await expectMerged(db);
    final tables = (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get())
        .map((row) => row.read<String>('name'))
        .toSet();
    expect(tables, containsAll(SealedSenderSql.tables));
    expect((await db.readDeviceListPin('acct_b'))!.pinnedAt, 4242);
  });

  test('a merged 43 opens again without change', () async {
    final file = File('${directory.path}/merged.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          key: 'dev_b:act1',
          conversationId: 'conv_1',
          senderAccountId: 'acct_b',
          senderDeviceId: 'dev_b',
          kind: 'text',
          createdAt: 1,
          state: 'received',
          c7Gen: const Value('gen'),
          c7Former: const Value(1),
        ));
    await db.close();
    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = (await db.select(db.localMessages).get()).single;
    expect(row.c7Gen, 'gen');
    expect(row.c7Former, 1);
  });
}
