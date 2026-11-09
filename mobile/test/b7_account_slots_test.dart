// B7 S4: slot storage (docs/designs/B7-passkeys.md). The primary slot keeps
// every name it has today; slots share no file or key; the registry is read
// back after each write; erasing a slot, the primary included, leaves every
// other slot's folder alone.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/core/report_seed_store.dart';
import 'package:private_messenger/desktop/message_notifications.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/account_slots.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/storage/profile_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('names', () {
    const release = ProfileScope();
    const demo = ProfileScope(namespace: 'demo', primaryNamespace: 'demo');

    test('the release primary keeps every name byte for byte', () {
      expect(release.isPrimary, isTrue);
      expect(release.databaseKey, 'veritra.database_key.v1');
      expect(release.legacyRecordKey, 'veritra.account_state.v2');
      expect(release.secureKey('read_receipts.v1'), 'veritra.read_receipts.v1');
      expect(release.secureKey('notifications.hide_preview.v1'),
          'veritra.notifications.hide_preview.v1');
      final support = Directory('/support');
      expect(release.directoryIn(support).path, '/support');
      expect(release.workingDirectoryIn(support).path, '/support');
      expect(release.pasteScope, 'default');
      expect(release.openedFilesFolder, 'primary');
    });

    test('the demo primary keeps its names too', () {
      expect(demo.databaseKey, 'veritra.demo.database_key.v1');
      expect(demo.secureKey('read_receipts.v1'), 'veritra.read_receipts.v1');
      expect(demo.directoryIn(Directory('/s')).path,
          '/s${Platform.pathSeparator}profiles${Platform.pathSeparator}demo');
      expect(demo.pasteScope, 'demo');
    });

    test('other slots share no name with the primary or each other', () {
      for (final primary in <ProfileScope>[release, demo]) {
        final a = primary.forNamespace(primary.primaryNamespace.isEmpty
            ? 'a-aaaaaaaaaaaa'
            : '${primary.primaryNamespace}-a-aaaaaaaaaaaa');
        final b = primary.forNamespace(primary.primaryNamespace.isEmpty
            ? 'a-bbbbbbbbbbbb'
            : '${primary.primaryNamespace}-a-bbbbbbbbbbbb');
        final support = Directory('/support');
        Set<String> names(ProfileScope s) => <String>{
              s.databaseKey,
              s.legacyRecordKey,
              s.secureKey('read_receipts.v1'),
              s.secureKey('notifications.hide_preview.v1'),
              s.directoryIn(support).path,
              s.workingDirectoryIn(support).path,
              'opened:${s.openedFilesFolder}',
              'paste:${s.pasteScope}',
            };
        final all = <Set<String>>[names(primary), names(a), names(b)];
        for (var i = 0; i < all.length; i++) {
          for (var j = i + 1; j < all.length; j++) {
            expect(all[i].intersection(all[j]), isEmpty,
                reason: 'slots $i and $j share a name');
          }
        }
      }
    });
  });

  group('registry', () {
    late MemorySlotKeyValue kv;
    late AccountRegistryStore store;
    final now = DateTime.utc(2026, 11, 8);

    setUp(() {
      kv = MemorySlotKeyValue();
      store = AccountRegistryStore(
          storage: kv, random: Random(7), clock: () => now);
    });

    test('a device that never added an account has one active primary slot',
        () async {
      final registry = await store.load();
      expect(registry.slots.single.namespace, '');
      expect(registry.active, '');
      expect(kv.values, isEmpty, reason: 'nothing is written until a change');
    });

    test('namespaces are fixed-shape and fit the store rule', () async {
      final registry = await store.load();
      final ns = store.newNamespace(registry);
      expect(ns, matches(RegExp(r'^a-[a-z2-7]{12}$')));
      expect(slotNamespacePattern.hasMatch(ns), isTrue);
      final demo = AccountRegistryStore(
          storage: kv, primaryNamespace: 'demo-x', random: Random(1));
      final dns = demo.newNamespace(AccountRegistry.initial('demo-x'));
      expect(dns, matches(RegExp(r'^demo-x-a-[a-z2-7]{12}$')));
      expect(slotNamespacePattern.hasMatch(dns), isTrue);
      expect(demo.key, 'veritra.demo-x.accounts.v1');
      expect(store.key, 'veritra.accounts.v1');
    });

    test('a write is read back; a mismatch fails', () async {
      kv.corruptNextWrite = true;
      await expectLater(
          store.addPending(), throwsA(isA<AccountRegistryException>()));
    });

    test('an unreadable entry fails closed', () async {
      kv.values[store.key] = '{not json';
      await expectLater(store.load(), throwsA(isA<AccountRegistryException>()));
      kv.values[store.key] = '{"version":2,"active":"","slots":[]}';
      await expectLater(store.load(), throwsA(isA<AccountRegistryException>()));
    });

    test('at most five accounts', () async {
      var registry = await store.load();
      for (var i = 0; i < maxAccountSlots - 1; i++) {
        registry = await store.addPending();
      }
      expect(registry.liveCount, maxAccountSlots);
      expect(registry.canAdd, isFalse);
      await expectLater(
          store.addPending(),
          throwsA(isA<SlotException>()
              .having((e) => e.refusal, 'refusal', SlotRefusal.full)));
      // A slot being removed no longer counts.
      final removing = registry.withRemoving(registry.slots.last.namespace);
      expect(removing.canAdd, isTrue);
    });

    test('cold wakes select only the protected active slot', () async {
      expect(await activeAccountSlotForWake(store), '');
      var registry = await store.addPending();
      final slot = store.newestPending(registry);
      registry = registry.withActive(slot);
      await store.save(registry);
      expect(await activeAccountSlotForWake(store), slot);
      registry = registry.withRemoving(slot);
      await store.save(registry);
      expect(await activeAccountSlotForWake(store), isNull);
      kv.values[store.key] = 'unreadable';
      expect(await activeAccountSlotForWake(store), isNull);
    });

    test('new slots copy preview privacy before the primary is removed',
        () async {
      kv.values['veritra.notifications.hide_preview.v1'] = 'true';
      final registry = await store.addPending();
      final slot = store.newestPending(registry);
      final key = ProfileScope(namespace: slot)
          .secureKey('notifications.hide_preview.v1');
      expect(kv.values[key], 'true');
      kv.values.remove('veritra.notifications.hide_preview.v1');
      expect(kv.values[key], 'true');
    });

    test('one account per slot', () async {
      var registry = await store.addPending();
      final first = store.newestPending(registry);
      registry =
          registry.withIdentity(first, 'https://a.example', 'acct_1', 'alice');
      await store.save(registry);
      registry = await store.addPending();
      final second = store.newestPending(registry);
      expect(
          () => registry.withIdentity(
              second, 'https://a.example', 'acct_1', 'alice'),
          throwsA(isA<SlotException>()
              .having((e) => e.refusal, 'refusal', SlotRefusal.duplicate)));
      // Another account on the same server is allowed, with a warning.
      final ok =
          registry.withIdentity(second, 'https://a.example', 'acct_2', 'bob');
      expect(ok.hasServer('https://a.example'), isTrue);
      expect(ok.hasServer('https://b.example'), isFalse);
    });

    test('a registry the next start could not read is never written', () async {
      // Deletes that keep failing leave `removing` slots, which do not count
      // against the cap.
      final slots = <AccountSlot>[
        for (var i = 0; i < maxAccountSlots + 3; i++)
          AccountSlot(
              namespace: 'a-${'$i'.padLeft(12, '0')}',
              state: i == 0 ? SlotState.active : SlotState.removing),
      ];
      await expectLater(
          store.save(
              AccountRegistry(active: slots.first.namespace, slots: slots)),
          throwsA(isA<AccountRegistryException>()));
      expect(kv.values[store.key], isNull);
      expect(await store.load(), AccountRegistry.initial(''));
    });

    test('a slot being removed never becomes active again', () async {
      var registry = await store.addPending();
      final pending = store.newestPending(registry);
      registry = registry.withRemoving(pending);
      expect(
          () => registry.withIdentity(
              pending, 'https://a.example', 'acct_1', 'alice'),
          throwsA(isA<SlotException>()));
      expect(() => registry.withActive(pending), throwsA(isA<SlotException>()));
    });

    test('every state survives a restart', () async {
      var registry = await store.addPending();
      final pending = store.newestPending(registry);
      registry = registry.withIdentity(
          pending, 'https://a.example', 'acct_1', 'alice');
      registry = registry.withActive(pending);
      registry = registry.withRemoving('');
      await store.save(registry);
      final again = await AccountRegistryStore(storage: kv).load();
      expect(again, registry);
      expect(again.slot('')!.state, SlotState.removing);
      expect(again.slot(pending)!.state, SlotState.active);
      expect(again.active, pending);
      expect(again.slot(pending)!.username, 'alice');
    });

    test('removing the active or primary slot picks another, never the removed',
        () async {
      var registry = await store.addPending();
      final other = store.newestPending(registry);
      registry = registry.withIdentity(other, 'https://a.example', 'a', 'x');
      final after = registry.without('', fallback: '');
      expect(after.active, other);
      expect(after.slot(''), isNull);
      final empty = after.without(other, fallback: '');
      expect(empty.slots, isEmpty);
      expect(empty.active, '');
      expect(
          () => registry.withActive('missing'), throwsA(isA<SlotException>()));
      expect(() => registry.withRemoving('missing'),
          throwsA(isA<SlotException>()));
    });

    test('no token or key ever lands in the registry', () async {
      var registry = await store.addPending();
      registry = registry.withIdentity(store.newestPending(registry),
          'https://a.example', 'acct_1', 'alice');
      await store.save(registry);
      final text = kv.values[store.key]!;
      expect(text, isNot(contains('token')));
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('key')));
    });
  });

  group('on disk', () {
    late Directory support;
    late List<EncryptedLocalDatabase> databases;
    const plain = FlutterSecureStorage();

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      support = await Directory.systemTemp.createTemp('veritra-slots-');
      databases = <EncryptedLocalDatabase>[];
    });

    tearDown(() async {
      for (final database in databases) {
        await database.close();
      }
      await SecureLocalStore.releaseInstanceLocks();
      if (await support.exists()) await support.delete(recursive: true);
    });

    SecureLocalStore open(String namespace) => SecureLocalStore(
          storage: plain,
          namespace: namespace,
          directoryProvider: () async => support,
          databaseFactory: (file, keyHex) {
            final database = openEncryptedLocalDatabase(file, keyHex);
            databases.add(database);
            return database;
          },
        );

    Future<void> closeAll() async {
      for (final database in databases) {
        await database.close();
      }
      databases.clear();
      await SecureLocalStore.releaseInstanceLocks();
    }

    SlotEraser eraser() => SlotEraser(
          storage: SecureSlotKeyValue(storage: plain),
          scope: const ProfileScope(),
          directoryProvider: () async => support,
        );

    test('two slots keep separate data, files and keys', () async {
      await open('').saveSyncCursor(11);
      await open('a-aaaaaaaaaaaa').saveSyncCursor(22);
      await closeAll();
      expect(await open('').loadSyncCursor(), 11);
      await closeAll();
      expect(await open('a-aaaaaaaaaaaa').loadSyncCursor(), 22);
      await closeAll();
      expect(File('${support.path}/veritra-local.db').existsSync(), isTrue);
      expect(
          File('${support.path}/profiles/a-aaaaaaaaaaaa/veritra-local.db')
              .existsSync(),
          isTrue);
      final a = await plain.read(key: 'veritra.database_key.v1');
      final b = await plain.read(key: 'veritra.a-aaaaaaaaaaaa.database_key.v1');
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a, isNot(b));
    });

    test('report seeds and preview choices are isolated and erased per slot',
        () async {
      const primary = ProfileScope();
      const other = ProfileScope(namespace: 'a-aaaaaaaaaaaa');
      final a = SecureReportSeedStore(storage: plain, scope: primary);
      final b = SecureReportSeedStore(storage: plain, scope: other);
      final seed = Uint8List.fromList(List.filled(32, 7));
      await a.save('https://a.example', 'acct', seed);
      expect(await b.load('https://a.example', 'acct'), isNull);
      await b.save('https://a.example', 'acct', Uint8List(32));
      final prefsA =
          SecureNotificationSettingsStore(storage: plain, scope: primary);
      final prefsB =
          SecureNotificationSettingsStore(storage: plain, scope: other);
      await prefsA.saveHidePreview(true);
      expect(await prefsB.loadHidePreview(), isTrue);
      await prefsA.saveHidePreview(false);
      expect(await prefsB.loadHidePreview(), isTrue);
      await eraser().erase('');
      expect(await a.load('https://a.example', 'acct'), isNull);
      expect(await b.load('https://a.example', 'acct'), Uint8List(32));
      expect(await prefsB.loadHidePreview(), isTrue);
      await eraser().erase(other.namespace);
      expect(await b.load('https://a.example', 'acct'), isNull);
      expect(
          await plain.read(
              key: other.secureKey('notifications.hide_preview.v1')),
          isNull);
    });

    test('erasing the primary leaves every other slot untouched', () async {
      await open('').saveSyncCursor(11);
      await open('a-aaaaaaaaaaaa').saveSyncCursor(22);
      await closeAll();
      // Leftovers of the primary: a quarantine folder, a quarantined key, a
      // partial recovery file and an unrelated file of another owner.
      Directory('${support.path}/unreadable-1').createSync();
      File('${support.path}/unreadable-1/veritra-local.db')
          .writeAsStringSync('x');
      await plain.write(
          key: 'veritra.database_key.v1.quarantined.1', value: 'k');
      File('${support.path}/.veritra-recovery.partial').writeAsStringSync('p');
      await plain.write(key: 'veritra.read_receipts.v1', value: 'off');
      // Each slot owns its preview choice.
      await plain.write(
          key: 'veritra.notifications.hide_preview.v1', value: 'true');
      final slotDir = Directory('${support.path}/profiles/a-aaaaaaaaaaaa');
      final before =
          slotDir.listSync(recursive: true).map((e) => e.path).toList()..sort();
      final slotKey =
          await plain.read(key: 'veritra.a-aaaaaaaaaaaa.database_key.v1');

      await eraser().erase('');

      expect(File('${support.path}/veritra-local.db').existsSync(), isFalse);
      expect(Directory('${support.path}/unreadable-1').existsSync(), isFalse);
      expect(File('${support.path}/.veritra-recovery.partial').existsSync(),
          isFalse);
      expect(await plain.read(key: 'veritra.database_key.v1'), isNull);
      expect(await plain.read(key: 'veritra.database_key.v1.quarantined.1'),
          isNull);
      expect(await plain.read(key: 'veritra.read_receipts.v1'), isNull);
      expect(await plain.read(key: 'veritra.notifications.hide_preview.v1'),
          isNull);
      expect(support.existsSync(), isTrue);
      final after =
          slotDir.listSync(recursive: true).map((e) => e.path).toList()..sort();
      expect(after, before);
      expect(await plain.read(key: 'veritra.a-aaaaaaaaaaaa.database_key.v1'),
          slotKey);
      expect(await open('a-aaaaaaaaaaaa').loadSyncCursor(), 22);
    });

    test('erasing a slot leaves the primary and the other slots untouched',
        () async {
      await open('').saveSyncCursor(11);
      await open('a-aaaaaaaaaaaa').saveSyncCursor(22);
      await open('a-bbbbbbbbbbbb').saveSyncCursor(33);
      await closeAll();
      await plain.write(
          key: 'veritra.a-aaaaaaaaaaaa.database_key.v1.quarantined.9',
          value: 'k');
      await plain.write(
          key: 'veritra.a-aaaaaaaaaaaa.read_receipts.v1', value: 'off');
      await plain.write(
          key: 'veritra.a-aaaaaaaaaaaa.notifications.hide_preview.v1',
          value: 'true');

      await eraser().erase('a-aaaaaaaaaaaa');

      expect(Directory('${support.path}/profiles/a-aaaaaaaaaaaa').existsSync(),
          isFalse);
      expect(await plain.read(key: 'veritra.a-aaaaaaaaaaaa.database_key.v1'),
          isNull);
      expect(
          await plain.read(
              key: 'veritra.a-aaaaaaaaaaaa.database_key.v1.quarantined.9'),
          isNull);
      expect(await plain.read(key: 'veritra.a-aaaaaaaaaaaa.read_receipts.v1'),
          isNull);
      expect(
          await plain.read(
              key: 'veritra.a-aaaaaaaaaaaa.notifications.hide_preview.v1'),
          isNull);
      expect(await open('').loadSyncCursor(), 11);
      await closeAll();
      expect(await open('a-bbbbbbbbbbbb').loadSyncCursor(), 33);
    });

    test('attachment sweeps and the store reset never reach a slot folder',
        () async {
      await open('').saveSyncCursor(11);
      await open('a-aaaaaaaaaaaa').saveSyncCursor(22);
      await closeAll();
      final slotDir = Directory('${support.path}/profiles/a-aaaaaaaaaaaa');
      // An old orphan in the slot folder must survive a sweep of the root.
      final nested = File('${slotDir.path}/${_orphanName()}')
        ..writeAsStringSync('x');
      nested.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 9)));
      await cleanupAttachmentOrphans(support, minAge: const Duration(hours: 1));
      expect(nested.existsSync(), isTrue);

      // The confirmed reset of the primary moves its fixed names only.
      await open('').quarantineUnreadableDatabase(confirmed: true);
      expect(slotDir.existsSync(), isTrue);
      expect(File('${slotDir.path}/veritra-local.db').existsSync(), isTrue);
      await closeAll();
      expect(await open('a-aaaaaaaaaaaa').loadSyncCursor(), 22);
    });

    test('a closed store never reopens or recreates its slot', () async {
      final store = open('a-dddddddddddd');
      await store.saveSyncCursor(5);
      await store.close();
      await eraser().erase('a-dddddddddddd');
      final slotDir = Directory('${support.path}/profiles/a-dddddddddddd');
      expect(slotDir.existsSync(), isFalse);
      // Late work of the torn-down account fails instead of starting over.
      await expectLater(store.saveSyncCursor(6),
          throwsA(isA<LocalStoreUnavailableException>()));
      await expectLater(
          store.loadSession(), throwsA(isA<LocalStoreUnavailableException>()));
      expect(slotDir.existsSync(), isFalse);
      expect(await plain.read(key: 'veritra.a-dddddddddddd.database_key.v1'),
          isNull);
      // The same slot opened again gets a new store.
      expect(await open('a-dddddddddddd').loadSyncCursor(), 0);
    });

    test('a pending slot with no session and no enrollment is empty', () async {
      final store = open('a-cccccccccccc');
      expect(await store.loadSession(), isNull);
      expect(await store.loadPendingEnrollment(), isNull);
      await store.saveSession(const Session(
          baseUrl: 'https://a.example', token: 't', accountId: 'a'));
      expect(await store.loadSession(), isNotNull);
    });
  });
}

String _orphanName() => '.attachment-${'0' * 32}.ciphertext';
