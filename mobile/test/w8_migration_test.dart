import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import 'schema_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final fail in [false, true]) {
    test(
        'schema12 to13 ${fail ? 'rolls back on failure and retries' : 'preserves existing content'}',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('veritra-w8-migration-');
      final file = File('${dir.path}/local.db');
      var database = EncryptedLocalDatabase(NativeDatabase(file));
      addTearDown(() async {
        await database.close();
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      await database.applyMessageEffects([
        const InsertMessageEffect(
            key: 'dev:t',
            conversationId: 'conv',
            senderAccountId: 'alice',
            senderDeviceId: 'dev',
            kind: LocalMessageKind.text,
            body: 'preserved words',
            createdAt: 1,
            state: LocalMessageState.received)
      ]);
      await stripW8Schema(database);
      await database.customStatement('PRAGMA user_version = 12');
      if (fail)
        await database.customStatement(
            'CREATE INDEX local_pending_pins ON local_messages(key)');
      await database.close();
      database = EncryptedLocalDatabase(NativeDatabase(file));
      if (fail) {
        await expectLater(database.readMessages('conv'), throwsA(anything));
        await database.close();
        final raw = sqlite3.open(file.path);
        try {
          expect(raw.select('PRAGMA user_version').single['user_version'], 12);
          expect(
              raw
                  .select('PRAGMA table_info(local_messages)')
                  .map((r) => r['name']),
              isNot(contains('hidden_at')));
          expect(
              raw.select(
                  "SELECT name FROM sqlite_master WHERE name = 'local_pins'"),
              isEmpty);
          expect(raw.select('SELECT body FROM local_messages').single['body'],
              'preserved words');
          raw.execute('DROP INDEX local_pending_pins');
        } finally {
          raw.close();
        }
        database = EncryptedLocalDatabase(NativeDatabase(file));
      }
      final message = (await database.readMessages('conv')).single;
      expect(message.body, 'preserved words');
      expect(message.hiddenAt, isNull);
      expect(message.senderHidden, isNull);
      expect(
          (await database.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          EncryptedLocalDatabase.currentSchemaVersion);
      await database.hideMessage('conv', message.key, 2);
      expect(await database.searchMessages('preserved'), isEmpty);
    });
  }
}
