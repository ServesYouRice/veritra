import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'l1_test_lists.dart';

/// D70 evidence, Dart side (testing/evidence/D70-dart-side-cost.md): what the
/// Rust-only measurement (crypto/rust/tests/d70_seal_cost.rs) leaves out. One
/// device with N two-member groups on the REAL encrypted SQLite store and the
/// real native library: the time of one sent message (seal plus the SQLite
/// write of its change set), the bytes it writes, and activation from SQLite
/// (read every record, then the Rust restore), plus the one-time migration of
/// a format-3 state.
///
/// Default (no environment): N = 3, a smoke check that the numbers hang
/// together. Measuring: `D70_GROUPS=100 VERITRA_CRYPTO_LIBRARY=... flutter test
/// test/d70_dart_cost_native_test.dart` prints one result line per run.
void main() {
  final configured = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final libraryPath =
      configured == null || configured.isEmpty ? null : configured;
  if (libraryPath == null && Platform.environment['CI'] == 'true') {
    test('CI provides the native crypto library', () {
      fail('VERITRA_CRYPTO_LIBRARY is required when CI=true');
    });
  }
  final skip = libraryPath == null ? 'VERITRA_CRYPTO_LIBRARY not set' : false;
  final groups = int.tryParse(Platform.environment['D70_GROUPS'] ?? '') ?? 3;

  test(
    'seal and activation cost with $groups groups on the real SQLite store',
    () async {
      final bindings = NativeCryptoBindings.open(libraryPath!);
      FlutterSecureStorage.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp('d70-dart-cost-');
      final databases = <EncryptedLocalDatabase>[];
      addTearDown(() async {
        for (final database in databases) {
          await database.close();
        }
        await SecureLocalStore.releaseInstanceLocks();
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      SecureLocalStore open() => SecureLocalStore(
            storage: const FlutterSecureStorage(),
            directoryProvider: () async => directory,
            databaseFactory: (file, keyHex) {
              final database = openEncryptedLocalDatabase(file, keyHex);
              databases.add(database);
              return database;
            },
          );

      final aliceStore = open();
      final alice = TestNativeCryptoService(
        bindings: bindings,
        localStore: aliceStore,
      );
      final bobStore = MemoryLocalStore();
      final bob = TestNativeCryptoService(
        bindings: bindings,
        localStore: bobStore,
      );
      await alice.createEnrollmentCredential(_reservation('acct_a', 'dev_a'));
      await alice.activateSession(_session('acct_a', 'dev_a'));
      await bob.createEnrollmentCredential(_reservation('acct_b', 'dev_b'));
      await bob.activateSession(_session('acct_b', 'dev_b'));

      var bobEvent = 0;
      var serverId = 0;
      final built = Stopwatch()..start();
      for (var i = 0; i < groups; i++) {
        final conversation = 'conv_$i';
        final package = DeviceKeyPackage(
          id: 'kp_$i',
          deviceId: 'dev_b',
          accountId: 'acct_b',
          keyPackage:
              (await bob.createReplenishmentKeyPackages(count: 1)).single,
          ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
          expiresAt: DateTime.now().add(const Duration(days: 1)),
        );
        await alice.initializeConversation(conversation, [package]);
        final item = (await aliceStore.pendingMlsMessages()).single;
        await alice.completeCommitBundle(item);
        await bob.processMlsMessage(
          MlsMessage(
            id: 'mls_${++serverId}',
            conversationId: conversation,
            senderAccountId: 'acct_a',
            senderDeviceId: 'dev_a',
            kind: 'welcome',
            payload: MlsCommitBundle.decode(item.payload).welcome,
            idempotencyKey: '${item.idempotencyKey}:welcome:dev_b',
            syncEventId: ++bobEvent,
            createdAt: DateTime.now().toUtc(),
            recipientDeviceId: 'dev_b',
          ),
        );
      }
      built.stop();

      Future<(int, int)> stateBytes() async {
        final snapshot = await aliceStore.loadCryptoSnapshot();
        var total = snapshot.state!.sealedState.length;
        for (final record in snapshot.records) {
          total += record.sealed.length;
        }
        return (total, snapshot.records.length);
      }

      final (totalBytes, records) = await stateBytes();

      // Bytes one message writes: the records whose generation moved.
      Future<int> changedBytes(Future<void> Function() action) async {
        final before = await aliceStore.loadCryptoSnapshot();
        await action();
        final after = await aliceStore.loadCryptoSnapshot();
        final old = {
          for (final r in before.records)
            '${r.kind}/${String.fromCharCodes(r.recordId)}': r.generation,
        };
        var bytes = after.state!.sealedState.length;
        for (final r in after.records) {
          final key = '${r.kind}/${String.fromCharCodes(r.recordId)}';
          if (old[key] != r.generation) bytes += r.sealed.length;
        }
        return bytes;
      }

      Future<void> sendTo(int index) async {
        final envelope = await alice.encryptPayload(
          'conv_${index % groups}',
          AppPayloadType.text,
          <String, Object?>{'text': 'hi'},
        );
        await aliceStore.removePendingEnvelope(envelope.idempotencyKey);
      }

      final bytesPerMessage = await changedBytes(() => sendTo(0));
      final times = <double>[];
      for (var i = 0; i < 20; i++) {
        final watch = Stopwatch()..start();
        await sendTo(i);
        watch.stop();
        times.add(watch.elapsedMicroseconds / 1000);
      }
      times.sort();

      // Activation: a new service over the same SQLite store reads every
      // record and restores them in Rust.
      await alice.dispose();
      final activation = Stopwatch()..start();
      final restarted = TestNativeCryptoService(
        bindings: bindings,
        localStore: aliceStore,
      );
      await restarted.activateSession(_session('acct_a', 'dev_a'));
      activation.stop();
      final readOnly = Stopwatch()..start();
      await aliceStore.loadCryptoSnapshot();
      readOnly.stop();
      expect(await restarted.groupEpoch('conv_0'), isNotNull);
      final rssMiB = ProcessInfo.currentRss / (1024 * 1024);
      final dbBytes = directory
          .listSync(recursive: true)
          .whereType<File>()
          .fold<int>(0, (sum, f) => sum + f.lengthSync());

      // A format-3 state migrates once at activation (the one-time cost).
      final blob = File(
        '../crypto/rust/tests/fixtures/state-v3/source.bin',
      ).readAsBytesSync();
      final v3Store = MemoryLocalStore();
      await v3Store.saveCryptoState(
        StoredCryptoState(
          counter: 51,
          stateKey: List<int>.filled(32, 0x73),
          sealedState: blob,
        ),
        7,
      );
      final migration = Stopwatch()..start();
      final migrated = TestNativeCryptoService(
        bindings: bindings,
        localStore: v3Store,
      );
      await migrated.activateSession(_session('acct_fixture3', 'dev_src'));
      migration.stop();

      // ignore: avoid_print
      print(
        'D70_DART groups=$groups records=$records state_bytes=$totalBytes '
        'bytes_per_message=$bytesPerMessage '
        'send_ms_median=${times[times.length ~/ 2].toStringAsFixed(2)} '
        'send_ms_max=${times.last.toStringAsFixed(2)} '
        'activation_ms=${activation.elapsedMilliseconds} '
        'sqlite_read_ms=${readOnly.elapsedMilliseconds} '
        'build_s=${(built.elapsedMilliseconds / 1000).toStringAsFixed(1)} '
        'rss_mib=${rssMiB.toStringAsFixed(0)} db_bytes=$dbBytes '
        'v3_migration_ms=${migration.elapsedMilliseconds} '
        'v3_blob_bytes=${blob.length}',
      );
      expect(records, greaterThanOrEqualTo(groups));
      expect(bytesPerMessage, lessThan(totalBytes));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

EnrollmentReservation _reservation(String accountId, String deviceId) =>
    EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    );

Session _session(String accountId, String deviceId) => Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    );
