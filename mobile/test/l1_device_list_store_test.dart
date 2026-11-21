import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// L1-3 local schema 26: pins move only forward, a conflict is sticky, the
/// leaf verdicts replace a group's rows, and the tables arrive by upgrade.
DeviceListPin _pin(int version, {bool conflict = false}) => DeviceListPin(
      accountId: 'acct_a',
      version: version,
      listHash: Uint8List(32)..[0] = version,
      listId: Uint8List(32)..[0] = 1,
      headStatement: [version, 1, 2],
      conflict: conflict,
      checkedAt: 10,
      recoveryKey: Uint8List(32)..[1] = 5,
      keys: [
        DeviceListKeyRow(
          deviceId: [1, 2],
          signingKey: Uint8List(32)..[0] = 7,
          addedVersion: 1,
          removedVersion: version > 1 ? version : 0,
        ),
      ],
    );

ApprovalLeaf _leaf(String device, LeafVerdict verdict) => ApprovalLeaf(
      conversationId: 'conv_1',
      accountId: 'acct_b'.codeUnits,
      deviceId: device.codeUnits,
      signingKey: Uint8List(32)..[0] = device.length,
      verdict: verdict,
      updatedAt: 1,
    );

void main() {
  for (final kind in ['drift', 'memory']) {
    group(kind, () {
      late LocalStore store;
      late EncryptedLocalDatabase? db;

      setUp(() async {
        if (kind == 'drift') {
          final database = EncryptedLocalDatabase(NativeDatabase.memory());
          db = database;
          store = _DbStore(database);
        } else {
          db = null;
          store = MemoryLocalStore();
        }
      });
      tearDown(() async => db?.close());

      test(
        'a pin is written only from the expected version, forward',
        () async {
          expect(
            await store.saveDeviceListPin(_pin(1), expectedVersion: null),
            isTrue,
          );
          expect(
            await store.saveDeviceListPin(_pin(2), expectedVersion: null),
            isFalse,
          );
          expect(
            await store.saveDeviceListPin(_pin(3), expectedVersion: 1),
            isTrue,
          );
          expect(
            await store.saveDeviceListPin(_pin(2), expectedVersion: 3),
            isFalse,
          );
          final read = (await store.loadDeviceListPin('acct_a'))!;
          expect(read.version, 3);
          expect(read.recoveryKey![1], 5);
          expect(read.keys.single.removedVersion, 3);
          expect(read.listed, isEmpty);
        },
      );

      test('a conflict is sticky', () async {
        await store.saveDeviceListPin(_pin(1), expectedVersion: null);
        await store.saveDeviceListConflict(
          accountId: 'acct_a',
          version: 1,
          pinnedStatement: [1],
          otherStatement: [2],
          recordedAt: 3,
        );
        expect((await store.loadDeviceListPin('acct_a'))!.conflict, isTrue);
        expect(
          await store.saveDeviceListPin(_pin(2), expectedVersion: 1),
          isFalse,
        );
      });

      test('leaf verdicts replace a group and mark the hold', () async {
        await store.saveApprovalLeaves(
          ApprovalLeafChange(
            conversationId: 'conv_1',
            leaves: [
              _leaf('dev_1', LeafVerdict.approved),
              _leaf('dev_22', LeafVerdict.unapproved),
            ],
            replaceAll: true,
          ),
        );
        expect(await store.loadHeldConversations(), ['conv_1']);
        await store.saveApprovalLeaves(
          ApprovalLeafChange(
            conversationId: 'conv_1',
            leaves: [_leaf('dev_1', LeafVerdict.approved)],
            replaceAll: true,
          ),
        );
        expect(await store.loadHeldConversations(), isEmpty);
        expect(await store.loadApprovalLeaves('conv_1'), hasLength(1));
      });
    });
  }

  test('a schema 20 database gains the L1 tables on upgrade', () async {
    final dir = await Directory.systemTemp.createTemp('l1-upgrade-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/l.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    await db.readDeviceListPin('acct_a');
    for (final table in [
      'local_device_list_heads',
      'local_device_list_keys',
      'local_device_list_conflicts',
      'local_approval_leaves',
    ]) {
      await db.customStatement('DROP TABLE $table');
    }
    await db.customStatement('PRAGMA user_version = 20');
    await db.close();

    db = EncryptedLocalDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.readDeviceListPin('acct_a'), isNull);
    expect(await db.writeDeviceListPin(_pin(1), expectedVersion: null), isTrue);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    // Whatever the current schema is: later packages add tables after 26.
    expect(
      version.read<int>('user_version'),
      EncryptedLocalDatabase.currentSchemaVersion,
    );
    expect(
      EncryptedLocalDatabase.currentSchemaVersion,
      greaterThanOrEqualTo(26),
    );
  });

  // The durable trust anchors survive an upgrade: a store from before the
  // L2-3 columns (schema 42: no `frank_key`, no `pinned_at`) keeps every
  // pin, key, removal, conflict proof, leaf verdict and the activation
  // journal (a setting) across the upgrade and a second open.
  test(
      'an upgrade keeps pins, removals, conflicts, verdicts and the '
      'activation journal', () async {
    final dir = await Directory.systemTemp.createTemp('l1-upgrade-keep-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/l.db');
    var db = EncryptedLocalDatabase(NativeDatabase(file));
    expect(await db.writeDeviceListPin(_pin(1), expectedVersion: null), isTrue);
    expect(await db.writeDeviceListPin(_pin(2), expectedVersion: 1), isTrue);
    final other = DeviceListPin(
      accountId: 'acct_b',
      version: 3,
      listHash: Uint8List(32)..[0] = 3,
      listId: Uint8List(32)..[0] = 9,
      headStatement: const [3, 3],
      conflict: false,
      checkedAt: 20,
      keys: [
        DeviceListKeyRow(
          deviceId: [4],
          signingKey: Uint8List(32)..[0] = 4,
          addedVersion: 1,
          removedVersion: 0,
        ),
      ],
    );
    expect(await db.writeDeviceListPin(other, expectedVersion: null), isTrue);
    await db.writeDeviceListConflict(
      accountId: 'acct_b',
      version: 3,
      pinnedStatement: const [3, 3],
      otherStatement: const [3, 4],
      recordedAt: 30,
    );
    await db.writeApprovalLeaves(
      ApprovalLeafChange(
        conversationId: 'conv_1',
        leaves: [_leaf('dev_1', LeafVerdict.removed)],
        replaceAll: true,
      ),
    );
    await db.writeMetadata('setting:l1.activation.x', '["AQI="]');
    await db.customStatement(
      'ALTER TABLE local_device_list_keys DROP COLUMN frank_key',
    );
    await db.customStatement(
      'ALTER TABLE local_device_list_heads DROP COLUMN pinned_at',
    );
    await db.customStatement('PRAGMA user_version = 42');
    await db.close();

    for (var open = 0; open < 2; open++) {
      db = EncryptedLocalDatabase(NativeDatabase(file));
      final pin = (await db.readDeviceListPin('acct_a'))!;
      expect(pin.version, 2);
      expect(pin.conflict, isFalse);
      expect(pin.headStatement, [2, 1, 2]);
      expect(pin.recoveryKey, Uint8List(32)..[1] = 5);
      expect(pin.pinnedAt, 10);
      expect(pin.keys.single.removedVersion, 2);
      expect(pin.keys.single.frankKey, isNull);
      final conflicted = (await db.readDeviceListPin('acct_b'))!;
      expect(conflicted.conflict, isTrue);
      expect(conflicted.keys.single.listed, isTrue);
      final proofs = await db.readDeviceListConflicts('acct_b');
      expect(proofs.single.otherStatement, [3, 4]);
      expect(
        (await db.readApprovalLeaves('conv_1')).single.verdict,
        LeafVerdict.removed,
      );
      expect(await db.readMetadata('setting:l1.activation.x'), '["AQI="]');
      // Still only forward, and still sticky.
      expect(await db.writeDeviceListPin(_pin(1), expectedVersion: 2), isFalse);
      expect(
        await db.writeDeviceListPin(
          other.copyWith(checkedAt: 40),
          expectedVersion: 3,
        ),
        isFalse,
      );
      await db.close();
    }
  });

  test('sign-out clears every L1 table', () async {
    final db = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.writeDeviceListPin(_pin(1), expectedVersion: null);
    await db.writeApprovalLeaves(
      ApprovalLeafChange(
        conversationId: 'conv_1',
        leaves: [_leaf('dev_1', LeafVerdict.unapproved)],
        replaceAll: true,
      ),
    );
    await db.clearAll();
    expect(await db.readDeviceListPin('acct_a'), isNull);
    expect(await db.readHeldConversations(), isEmpty);
  });
}

/// The four L1 calls of [SecureLocalStore], straight on a database.
class _DbStore extends MemoryLocalStore {
  _DbStore(this.db);
  final EncryptedLocalDatabase db;

  @override
  Future<DeviceListPin?> loadDeviceListPin(String accountId) =>
      db.readDeviceListPin(accountId);

  @override
  Future<bool> saveDeviceListPin(
    DeviceListPin pin, {
    required int? expectedVersion,
  }) =>
      db.writeDeviceListPin(pin, expectedVersion: expectedVersion);

  @override
  Future<void> saveDeviceListConflict({
    required String accountId,
    required int version,
    required List<int> pinnedStatement,
    required List<int> otherStatement,
    required int recordedAt,
  }) =>
      db.writeDeviceListConflict(
        accountId: accountId,
        version: version,
        pinnedStatement: pinnedStatement,
        otherStatement: otherStatement,
        recordedAt: recordedAt,
      );

  @override
  Future<List<ApprovalLeaf>> loadApprovalLeaves(String conversationId) =>
      db.readApprovalLeaves(conversationId);

  @override
  Future<void> saveApprovalLeaves(ApprovalLeafChange change) =>
      db.writeApprovalLeaves(change);

  @override
  Future<List<String>> loadHeldConversations() => db.readHeldConversations();
}
