import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

void main() {
  test('failed initial create leaves no tables and the next open succeeds',
      () async {
    final dir = await Directory.systemTemp.createTemp('veritra-create-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/local.db');

    // An index that takes a history table's name makes onCreate fail after
    // createAll() has already run.
    final seed = sqlite3.open(file.path);
    seed.execute('CREATE TABLE poison (x INTEGER)');
    seed.execute('CREATE INDEX local_history_imports ON poison(x)');
    seed.close();

    var db = EncryptedLocalDatabase(NativeDatabase(file));
    await expectLater(db.readMessages('conv'), throwsA(anything));
    await db.close();

    final raw = sqlite3.open(file.path);
    try {
      expect(raw.select('PRAGMA user_version').single['user_version'], 0);
      expect(
          raw
              .select("SELECT name FROM sqlite_master WHERE type='table' "
                  "AND name <> 'poison'")
              .map((r) => r['name']),
          isEmpty);
      raw.execute('DROP INDEX local_history_imports');
      raw.execute('DROP TABLE poison');
    } finally {
      raw.close();
    }

    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.readMessages('conv'), isEmpty);
    expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        EncryptedLocalDatabase.currentSchemaVersion);
  });
}
