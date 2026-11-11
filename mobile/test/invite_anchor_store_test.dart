import 'dart:io';
import 'package:private_messenger/core/models.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'schema 31 upgrades to current; anchor survives reopen and full wipe clears it',
      () async {
    final dir = await Directory.systemTemp.createTemp('invite-anchor-');
    final file = File('${dir.path}/local.db');
    final anchor = InviteAnchor(
        conversationId: 'group',
        accountId: 'alice',
        deviceId: 'phone',
        signingKey: List.filled(32, 7));
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    try {
      await db.readCursor();
      await db.customStatement('DROP TABLE local_invite_anchors');
      await db.customStatement('PRAGMA user_version = 31');
      await db.close();
      db = EncryptedLocalDatabase(NativeDatabase(file));
      expect(await db.readInviteAnchor('group'), isNull);
      await db.writeInviteAnchor(anchor);
      await db.close();
      db = EncryptedLocalDatabase(NativeDatabase(file));
      final read = (await db.readInviteAnchor('group'))!;
      expect(read.accountId, anchor.accountId);
      expect(read.deviceId, anchor.deviceId);
      expect(read.signingKey, anchor.signingKey);
      expect(
          (await db.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          EncryptedLocalDatabase.currentSchemaVersion);
      await db.clearAll();
      expect(await db.readInviteAnchor('group'), isNull);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
  test('upgrade tolerates a table retained by older-schema test fixtures',
      () async {
    final dir = await Directory.systemTemp.createTemp('invite-upgrade-');
    final file = File('${dir.path}/local.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    try {
      await db.writeInviteAnchor(InviteAnchor(
          conversationId: 'g',
          accountId: 'a',
          deviceId: 'd',
          signingKey: List.filled(32, 1)));
      await db.customStatement('PRAGMA user_version = 31');
      await db.close();
      db = EncryptedLocalDatabase(NativeDatabase(file));
      expect((await db.readInviteAnchor('g'))!.accountId, 'a');
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('memory anchors clear on identity replacement', () async {
    final store = MemoryLocalStore();
    await store.saveSession(Session(
        baseUrl: 'https://localhost',
        token: 't',
        accountId: 'old',
        deviceId: 'old'));
    await store.saveInviteAnchor(InviteAnchor(
        conversationId: 'g',
        accountId: 'a',
        deviceId: 'd',
        signingKey: List.filled(32, 1)));
    await store.saveSession(Session(
        baseUrl: 'https://localhost',
        token: 't',
        accountId: 'new',
        deviceId: 'new'));
    expect(await store.loadInviteAnchor('g'), isNull);
  });
}
