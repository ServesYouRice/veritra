import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:drift/drift.dart'
    show CouldNotRollBackException, DriftWrappedException;
import 'package:drift/native.dart' show SqliteException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Card I33: typed per-event failures, durable recovery, bounded repair and
/// the tombstone policy for proven-expired application messages.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a missing MLS control message stops sync without a poison loop',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_gone')]
      ..mlsMissing.add('mls_gone');
    final harness = await _Harness.start(api);

    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.kind, SyncFailureKind.mlsControlMissing);
    expect(harness.state.syncRecovery!.eventId, 5);
    expect(harness.state.deviceRecoveryRequired, isTrue);
    expect(await harness.store.loadSyncCursor(), 0);
    expect((await harness.store.loadSyncRecovery())!.kind,
        SyncFailureKind.mlsControlMissing);

    // More wakes do not fetch the event again.
    final syncCalls = api.syncCalls;
    final fetches = api.mlsMessageCalls;
    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness.settle();
    expect(api.syncCalls, syncCalls);
    expect(api.mlsMessageCalls, fetches);
    expect(await harness.store.loadSyncCursor(), 0);
    harness.dispose();
  });

  test('the recovery record survives a restart', () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.saveSyncRecovery(SyncRecovery(
      kind: SyncFailureKind.mlsState,
      recordedAt: DateTime.utc(2026, 9, 24),
      eventId: 9,
    ));
    final api = _ScriptedApi();
    final harness = await _Harness.start(api, store: store);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.kind, SyncFailureKind.mlsState);
    expect(api.syncCalls, 0);
    harness.dispose();
  });

  test('a malformed MLS control event stops sync at that event', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        _projectionEvent(3),
        SyncEvent(
          id: 4,
          type: 'mls.message.created',
          conversationId: 'conv_1',
          payload: const <String, Object?>{},
          createdAt: DateTime.utc(2026, 9, 24),
        ),
        _projectionEvent(5),
      ];
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(
        harness.state.syncRecovery!.kind, SyncFailureKind.mlsControlMalformed);
    expect(await harness.store.loadSyncCursor(), 3);
    harness.dispose();
  });

  test('an MLS message for another event is treated as malformed', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(6, 'mls_1')]
      ..mlsEventIdOverride['mls_1'] = 99;
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(
        harness.state.syncRecovery!.kind, SyncFailureKind.mlsControlMalformed);
    expect(await harness.store.loadSyncCursor(), 0);
    harness.dispose();
  });

  test('a rejected MLS commit is an MLS state failure and can be retried',
      () async {
    final api = _ScriptedApi()..events = <SyncEvent>[_mlsEvent(2, 'mls_bad')];
    final harness = await _Harness.start(api);
    harness.crypto.rejectedMls.add('mls_bad');
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.kind, SyncFailureKind.mlsState);
    expect(harness.state.syncRecovery!.choices,
        contains(SyncRecoveryChoice.retry));
    expect(await harness.store.loadSyncCursor(), 0);

    harness.crypto.rejectedMls.clear();
    await harness.state.retrySyncRecovery();
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 2);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.loadSyncRecovery(), isNull);
    expect(harness.state.deviceRecoveryRequired, isFalse);
    harness.dispose();
  });

  test('an expired application message follows the tombstone policy', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        _envelopeEvent(4, 'msg_expired',
            ciphertext: _undecryptable, expiresAt: DateTime.utc(2000)),
        _envelopeEvent(5, 'msg_ok'),
      ];
    final harness = await _Harness.start(api);
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 5);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.hasProcessedMlsMessage('expired:4:msg_expired'),
        isTrue);
    expect(harness.crypto.applied, <String>['msg_ok']);
    harness.dispose();
  });

  test('a server-proven expired legacy envelope is tombstoned', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_envelopeEvent(4, 'msg_old', inline: false)]
      ..expiredEnvelopes.add('msg_old');
    final harness = await _Harness.start(api);
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 4);
    expect(harness.state.syncRecovery, isNull);
    expect(harness.crypto.applied, isEmpty);
    harness.dispose();
  });

  test('an undecryptable live message stops sync instead of being skipped',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        _envelopeEvent(4, 'msg_bad', ciphertext: _undecryptable),
        _envelopeEvent(5, 'msg_ok'),
      ];
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.kind,
        SyncFailureKind.applicationUndecryptable);
    expect(await harness.store.loadSyncCursor(), 0);
    expect(harness.crypto.applied, isEmpty);
    harness.dispose();
  });

  test('messages committed before a failure in the same page are shown',
      () async {
    // Received messages reach the UI in batches (T49C); a failure later in
    // the page must not hide the ones already committed.
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        _envelopeEvent(4, 'msg_one'),
        _envelopeEvent(5, 'msg_two'),
        _envelopeEvent(6, 'msg_bad', ciphertext: _undecryptable),
      ];
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(harness.state.syncRecovery!.eventId, 6);
    expect(await harness.store.loadSyncCursor(), 5);
    expect(
      harness.state.messagesFor('conv_1').map((message) => message.id),
      unorderedEquals(<String>['msg_one', 'msg_two']),
    );
    harness.dispose();
  });

  test('a missing legacy envelope without proof of expiry stops sync',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_envelopeEvent(4, 'msg_gone', inline: false)];
    final harness = await _Harness.start(api);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    expect(
        harness.state.syncRecovery!.kind, SyncFailureKind.applicationMissing);
    expect(await harness.store.loadSyncCursor(), 0);
    harness.dispose();
  });

  test('a network failure keeps the cursor and is retried, not recorded',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_1')]
      ..networkDown = true;
    final harness = await _Harness.start(api);
    await harness.waitFor(
        () => harness.state.connectionStatus == ConnectionStatus.offline);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.loadSyncRecovery(), isNull);
    expect(await harness.store.loadSyncCursor(), 0);

    api.networkDown = false;
    harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 5);
    expect(harness.state.connectionStatus, ConnectionStatus.online);
    harness.dispose();
  });

  test('a rate-limited catch-up is retried without waiting for a wake',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_1')]
      ..syncStatus = 429;
    final harness = await _Harness.start(api);
    await harness.waitFor(
        () => harness.state.connectionStatus == ConnectionStatus.offline);
    expect(harness.state.syncRecovery, isNull);
    final callsWhileLimited = api.syncCalls;

    // No socket event, resume or push arrives: the backoff timer alone
    // must fetch again once the limit has passed.
    api.syncStatus = null;
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 5);
    expect(api.syncCalls, greaterThan(callsWhileLimited));
    expect(harness.state.connectionStatus, ConnectionStatus.online);
    harness.dispose();
  });

  test('a rate limit with Retry-After is retried when its window resets',
      () async {
    // Without the header the backoff would wait 2, 4 and 8 s for these
    // three retries; the server's Retry-After (0 s here) brings each one
    // forward to about a second.
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_1')]
      ..syncStatus = 429
      ..syncRetryAfter = Duration.zero;
    final harness = await _Harness.start(api);
    await harness.waitFor(
        () => harness.state.connectionStatus == ConnectionStatus.offline);
    final watch = Stopwatch()..start();
    final firstCalls = api.syncCalls;
    await harness.waitFor(() => api.syncCalls >= firstCalls + 3);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));

    api.syncStatus = null;
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 5);
    expect(harness.state.connectionStatus, ConnectionStatus.online);
    harness.dispose();
  });

  test('Retry-After parses delta seconds and is bounded', () {
    expect(ApiException.parseRetryAfter('17'), const Duration(seconds: 17));
    expect(ApiException.parseRetryAfter(' 3 '), const Duration(seconds: 3));
    expect(ApiException.parseRetryAfter('86400'), ApiException.maxRetryAfter);
    expect(ApiException.parseRetryAfter(null), isNull);
    expect(ApiException.parseRetryAfter('-1'), isNull);
    expect(
        ApiException.parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), isNull);
  });

  test('a network failure while fetching MLS messages is not recorded',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_1')]
      ..mlsNetworkDown = true;
    final harness = await _Harness.start(api);
    await harness.waitFor(
        () => harness.state.connectionStatus == ConnectionStatus.offline);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.loadSyncCursor(), 0);
    harness.dispose();
  });

  test('a rejected token signs out without a recovery record', () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[_mlsEvent(5, 'mls_1')]
      ..syncStatus = 401;
    final harness = await _Harness.start(api);
    await harness.waitFor(() => !harness.state.connected);
    expect(harness.state.syncRecovery, isNull);
    expect(await harness.store.loadSyncRecovery(), isNull);
    expect((await harness.store.loadSession())!.deviceId, 'dev_me');
    harness.dispose();
  });

  test('an expired cursor asks for relink or backup, never a jump', () async {
    final store = MemoryLocalStore();
    await store.saveSession(_session);
    await store.saveSyncCursor(10);
    final api = _ScriptedApi()..syncStatus = 409;
    final harness = await _Harness.start(api, store: store);
    await harness.waitFor(() => harness.state.syncRecovery != null);
    final recovery = harness.state.syncRecovery!;
    expect(recovery.kind, SyncFailureKind.cursorExpired);
    expect(recovery.choices, isNot(contains(SyncRecoveryChoice.retry)));
    expect(recovery.choices, contains(SyncRecoveryChoice.relink));
    expect(await store.loadSyncCursor(), 10);

    // Retry is not offered, so it does nothing.
    await harness.state.retrySyncRecovery();
    expect(harness.state.syncRecovery, isNotNull);
    expect(() => harness.state.relinkAfterSyncRecovery(confirmed: false),
        throwsArgumentError);
    await harness.state.relinkAfterSyncRecovery(confirmed: true);
    expect(harness.state.connected, isFalse);
    expect(await store.loadSession(), isNull);
    expect(await store.loadSyncRecovery(), isNull);
    harness.dispose();
  });

  test('a reconnect burst fetches MLS messages in one bounded request',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        for (var id = 1; id <= 40; id++)
          if (id.isEven) _mlsEvent(id, 'mls_$id') else _projectionEvent(id),
      ];
    final harness = await _Harness.start(api);
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 40);
    expect(api.mlsListCalls, 1);
    expect(api.mlsMessageCalls, 0);
    expect(harness.crypto.processedMls, hasLength(20));
    expect(harness.crypto.processedMls.toSet(), hasLength(20));
    harness.dispose();
  });

  test('an unknown event outside mls., message. and call. is skipped (P5)',
      () async {
    final api = _ScriptedApi()
      ..events = <SyncEvent>[
        SyncEvent(
          id: 3,
          type: 'foo.bar',
          createdAt: DateTime.utc(2026, 9, 24),
        ),
        SyncEvent(
          id: 4,
          type: 'profile.updated',
          createdAt: DateTime.utc(2026, 9, 24),
        ),
      ];
    final harness = await _Harness.start(api);
    await harness
        .waitFor(() async => await harness.store.loadSyncCursor() == 4);
    expect(harness.state.syncRecovery, isNull);
    harness.dispose();
  });

  for (final type in <String>['mls.foo', 'message.foo', 'call.foo']) {
    test('an unknown $type event stops sync as unsupported (P5)', () async {
      final api = _ScriptedApi()
        ..events = <SyncEvent>[
          SyncEvent(
            id: 3,
            type: type,
            createdAt: DateTime.utc(2026, 9, 24),
          ),
        ];
      final harness = await _Harness.start(api);
      await harness.waitFor(() => harness.state.syncRecovery != null);
      expect(
          harness.state.syncRecovery!.kind, SyncFailureKind.unsupportedEvent);
      expect(await harness.store.loadSyncCursor(), 0);
      harness.dispose();
    });
  }

  // Signing in again as the same account and device keeps the sync cursor:
  // the MLS state and the cursor were committed together, so replaying from
  // event 0 only meets events this state has already consumed.
  group('signing in again as the same identity', () {
    late Directory directory;
    late List<EncryptedLocalDatabase> databases;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      directory = await Directory.systemTemp.createTemp('veritra-resign-in-');
      databases = <EncryptedLocalDatabase>[];
    });

    tearDown(() async {
      for (final database in databases) {
        await database.close();
      }
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final stores =
        <String, LocalStore Function(List<EncryptedLocalDatabase>, Directory)>{
      'memory store': (_, __) => MemoryLocalStore(),
      'encrypted store': (databases, directory) => SecureLocalStore(
            storage: const FlutterSecureStorage(),
            directoryProvider: () async => directory,
            databaseFactory: (file, keyHex) {
              final database = openEncryptedLocalDatabase(file, keyHex);
              databases.add(database);
              return database;
            },
          ),
    };

    for (final entry in stores.entries) {
      /// A device with its session and protected MLS state, at cursor 0.
      Future<LocalStore> device({bool withCryptoState = true}) async {
        final store = entry.value(databases, directory);
        await store.saveSession(_session);
        if (withCryptoState) {
          await store.saveCryptoState(
              StoredCryptoState(
                  counter: 1,
                  stateKey: List<int>.filled(32, 7),
                  sealedState: const <int>[1]),
              0);
        }
        return store;
      }

      /// The server rejects the token; the app keeps the device identity.
      Future<void> expire(_Harness harness, _ScriptedApi api) async {
        api.syncStatus = 401;
        harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
        await harness.waitFor(() => harness.state.session == null);
        api.syncStatus = null;
      }

      /// Lets the sync pass after sign-in finish before the store closes.
      Future<void> finish(_Harness harness) async {
        await harness.waitFor(() => harness.state.lastSyncedAt != null);
        await harness.settle();
        harness.dispose();
      }

      test(
          '${entry.key}: after a session expiry, sign-in resumes from the '
          'stored cursor', () async {
        // More than one page (200) of events this device has applied,
        // with a Welcome to it among them.
        final api = _ScriptedApi()
          ..welcomes.add('mls_1')
          ..events = <SyncEvent>[
            _mlsEvent(1, 'mls_1'),
            for (var id = 2; id <= 230; id++)
              if (id % 10 == 0)
                _mlsEvent(id, 'mls_$id')
              else
                _projectionEvent(id),
          ];
        final store = await device();
        final harness = await _Harness.start(api, store: store);
        await harness.waitFor(() async => await store.loadSyncCursor() == 230);
        final created = harness.crypto.keyPackagesCreated;

        await expire(harness, api);
        expect(await store.loadSyncCursor(), 230);

        api.events = <SyncEvent>[
          ...api.events,
          _mlsEvent(231, 'mls_231'),
        ];
        api.syncAfters.clear();
        await harness.state.login('https://localhost:8080', 'me', 'password');
        expect(harness.state.session?.token, 'token_again');
        await harness.waitFor(() async => await store.loadSyncCursor() == 231);

        expect(api.runaway, isFalse);
        expect(api.syncAfters.first, 230);
        expect(harness.state.syncRecovery, isNull);
        expect(await store.loadSyncRecovery(), isNull);
        expect(harness.crypto.processedMls.last, 'mls_231');
        // The old Welcome is not seen again, so no key package is replaced.
        expect(harness.crypto.keyPackagesCreated, created);
        await finish(harness);
      });

      test(
          '${entry.key}: when the server pruned events the device could see, '
          'sign-in stores the expired-cursor recovery', () async {
        final api = _ScriptedApi()
          ..events = <SyncEvent>[
            _mlsEvent(1, 'mls_1'),
            _mlsEvent(2, 'mls_2'),
            _mlsEvent(3, 'mls_3'),
          ];
        final store = await device();
        final harness = await _Harness.start(api, store: store);
        await harness.waitFor(() async => await store.loadSyncCursor() == 3);
        await expire(harness, api);

        // Away longer than event retention: the server answers the kept
        // cursor with device_recovery_required.
        api.syncStatus = 409;
        api.syncAfters.clear();
        await harness.state.login('https://localhost:8080', 'me', 'password');
        expect(harness.state.session?.token, 'token_again');
        await harness.waitFor(() => harness.state.syncRecovery != null);

        expect(api.syncAfters.first, 3);
        final recovery = harness.state.syncRecovery!;
        expect(recovery.kind, SyncFailureKind.cursorExpired);
        expect(recovery.choices, contains(SyncRecoveryChoice.relink));
        expect(recovery.choices, isNot(contains(SyncRecoveryChoice.retry)));
        expect((await store.loadSyncRecovery())?.kind,
            SyncFailureKind.cursorExpired);
        // Never a jump: the cursor stays where the device stopped.
        expect(await store.loadSyncCursor(), 3);
        expect(api.syncAfters, everyElement(3));
        await harness.settle();
        harness.dispose();
      });

      test(
          '${entry.key}: without protected MLS state, sign-in starts again '
          'from the first event', () async {
        final api = _ScriptedApi()..events = <SyncEvent>[_projectionEvent(1)];
        final store = await device(withCryptoState: false);
        await store.saveSyncCursor(1);
        final harness = await _Harness.start(api, store: store);
        await expire(harness, api);
        api.syncAfters.clear();
        await harness.state.login('https://localhost:8080', 'me', 'password');
        await harness.waitFor(() => api.syncAfters.isNotEmpty);
        expect(api.syncAfters.first, 0);
        await finish(harness);
      });

      test(
          '${entry.key}: a session for another identity starts at cursor 0 '
          'with no MLS state', () async {
        final store = await device();
        await store.saveSyncCursor(42);
        await store.saveSession(const Session(
          baseUrl: 'https://localhost:8080',
          token: 'other',
          accountId: 'acct_other',
          deviceId: 'dev_other',
        ));
        expect(await store.loadSyncCursor(), 0);
        expect(await store.loadCryptoState(), isNull);
        expect(await store.hasProcessedMlsMessage('mls:1:mls_1'), isFalse);
      });

      test('${entry.key}: wiping the store resets the cursor', () async {
        final store = await device();
        await store.saveSyncCursor(42);
        await store.clear();
        expect(await store.loadSyncCursor(), 0);
      });
    }
  });

  test('recovery records round-trip and reject damaged values', () {
    final recovery = SyncRecovery(
      kind: SyncFailureKind.applicationMissing,
      recordedAt: DateTime.utc(2026, 9, 24, 12),
      eventId: 7,
      eventType: 'message.envelope.created',
      conversationId: 'conv_1',
    );
    final decoded = SyncRecovery.decode(recovery.encode())!;
    expect(decoded.kind, recovery.kind);
    expect(decoded.eventId, 7);
    expect(decoded.conversationId, 'conv_1');
    expect(decoded.recordedAt, recovery.recordedAt);
    expect(SyncRecovery.decode('{"kind":"nope"}'), isNull);
    expect(SyncRecovery.decode('not json'), isNull);
    expect(SyncRecovery.decode(null), isNull);
  });

  group('local storage failures on the real encrypted database (B1)', () {
    late Directory directory;
    late List<EncryptedLocalDatabase> databases;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      directory = await Directory.systemTemp.createTemp('veritra-sync-store-');
      databases = <EncryptedLocalDatabase>[];
    });

    tearDown(() async {
      for (final database in databases) {
        await database.close();
      }
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('a constraint failure is durable: retry only, no relink', () async {
      final api = _ScriptedApi()..events = <SyncEvent>[_envelopeEvent(4, 'm')];
      // Open the database before the harness starts syncing.
      final store = SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );
      await store.saveSession(_session);
      await databases.last.customStatement(
          'CREATE TRIGGER fail_commit BEFORE INSERT ON local_mls_transitions '
          "BEGIN SELECT RAISE(ABORT, 'refused'); END");
      final harness = await _Harness.start(api, store: store);

      await harness.waitFor(() => harness.state.syncRecovery != null);
      final recovery = harness.state.syncRecovery!;
      expect(recovery.kind, SyncFailureKind.localStorage);
      expect(recovery.eventId, 4);
      expect(recovery.choices, <SyncRecoveryChoice>[SyncRecoveryChoice.retry]);
      expect(harness.state.syncError, harness.state.l10n.syncErrorLocalStorage);
      expect(await harness.store.loadSyncCursor(), 0);
      expect((await harness.store.loadSyncRecovery())!.kind,
          SyncFailureKind.localStorage);

      await databases.last.customStatement('DROP TRIGGER fail_commit');
      await harness.state.retrySyncRecovery();
      await harness
          .waitFor(() async => await harness.store.loadSyncCursor() == 4);
      expect(harness.state.syncRecovery, isNull);
      harness.dispose();
    });

    test('a full database is transient: storage text, no recovery record',
        () async {
      final api = _ScriptedApi()..events = <SyncEvent>[_envelopeEvent(4, 'm')];
      final store = SecureLocalStore(
        storage: const FlutterSecureStorage(),
        directoryProvider: () async => directory,
        databaseFactory: (file, keyHex) {
          final database = openEncryptedLocalDatabase(file, keyHex);
          databases.add(database);
          return database;
        },
      );
      await store.saveSession(_session);
      final database = databases.last;
      final pages =
          (await database.customSelect('PRAGMA page_count').getSingle())
              .read<int>('page_count');
      // No room to grow: the trigger's insert needs hundreds of new pages and
      // SQLite reports SQLITE_FULL from inside the background isolate.
      await database.customStatement('PRAGMA max_page_count = $pages');
      await database.customStatement(
          'CREATE TRIGGER fill_up BEFORE INSERT ON local_mls_transitions '
          "BEGIN INSERT INTO local_metadata (name, value) "
          "VALUES ('pad', hex(zeroblob(2000000))); END");
      final harness = await _Harness.start(api, store: store);

      await harness.waitFor(() =>
          harness.state.syncError == harness.state.l10n.syncErrorStorageBusy);
      expect(harness.state.syncRecovery, isNull);
      expect(await harness.store.loadSyncRecovery(), isNull);
      expect(harness.state.deviceRecoveryRequired, isFalse);
      expect(await harness.store.loadSyncCursor(), 0);

      // Room again: the next catch-up applies the same event.
      await database.customStatement('DROP TRIGGER fill_up');
      await database.customStatement('PRAGMA max_page_count = 1000000');
      harness.state.handleAppLifecycleState(AppLifecycleState.resumed);
      await harness
          .waitFor(() async => await harness.store.loadSyncCursor() == 4);
      await harness.waitFor(() => harness.state.syncError == null);
      // The resume also flushes the outbox on the database; let it finish
      // before the database closes.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      harness.dispose();
    });

    test('the unwrapped SQLite code decides: transient set only', () {
      SqliteException sqlite(int code) =>
          SqliteException(extendedResultCode: code, message: 'test');
      expect(localStorageErrorCode(sqlite(2067)), 19);
      expect(localStorageErrorCode(sqlite(1802)), 10);
      expect(localStorageErrorCode(StateError('x')), isNull);
      expect(
          localStorageErrorCode(
              DriftWrappedException(message: 'w', cause: sqlite(13))),
          13);
      expect(
          localStorageErrorCode(CouldNotRollBackException(
              StateError('step'), StackTrace.empty, sqlite(5))),
          5);
    });
  });
}

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
  deviceSecret: 'secret',
);

const _undecryptable = <int>[0];

SyncEvent _mlsEvent(int id, String messageId) => SyncEvent(
      id: id,
      type: 'mls.message.created',
      conversationId: 'conv_1',
      payload: <String, Object?>{'mls_message_id': messageId},
      createdAt: DateTime.utc(2026, 9, 24),
    );

SyncEvent _projectionEvent(int id) => SyncEvent(
      id: id,
      type: 'read_receipt.updated',
      conversationId: 'conv_1',
      payload: const <String, Object?>{},
      createdAt: DateTime.utc(2026, 9, 24),
    );

SyncEvent _envelopeEvent(
  int id,
  String messageId, {
  List<int> ciphertext = const <int>[1],
  DateTime? expiresAt,
  bool inline = true,
}) =>
    SyncEvent(
      id: id,
      type: 'message.envelope.created',
      conversationId: 'conv_1',
      payload: <String, Object?>{
        'message_id': messageId,
        'conversation_id': 'conv_1',
        if (inline)
          'envelope':
              _envelope(messageId, ciphertext: ciphertext, expiresAt: expiresAt)
                  .toJson(),
      },
      createdAt: DateTime.utc(2026, 9, 24),
    );

ReceivedMessageEnvelope _envelope(
  String id, {
  List<int> ciphertext = const <int>[1],
  DateTime? expiresAt,
}) =>
    ReceivedMessageEnvelope(
      id: id,
      conversationId: 'conv_1',
      senderAccountId: 'acct_peer',
      senderDeviceId: 'dev_peer',
      idempotencyKey: 'idem_$id',
      ciphertext: ciphertext,
      cryptoProtocol: 'mls10-openmls-v1',
      createdAt: DateTime.utc(2026, 9, 24),
      expiresAt: expiresAt,
    );

class _Harness {
  _Harness(this.state, this.store, this.crypto);

  final AppState state;
  final LocalStore store;
  final _FakeMlsCrypto crypto;

  static Future<_Harness> start(_ScriptedApi api, {LocalStore? store}) async {
    final local = store ?? MemoryLocalStore();
    if (store == null) await local.saveSession(_session);
    final crypto = _FakeMlsCrypto(local);
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: crypto,
      localStore: local,
      syncServiceFactory: (_, __) => _QuietSync(),
    );
    await state.tryRestoreSession();
    return _Harness(state, local, crypto);
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> waitFor(FutureOr<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    fail('condition not reached');
  }

  void dispose() => state.dispose();
}

class _ScriptedApi extends ApiClient {
  _ScriptedApi() : super(baseUrl: 'https://localhost:8080');

  List<SyncEvent> events = <SyncEvent>[];
  final Set<String> mlsMissing = <String>{};
  // MLS messages that are a Welcome to this device rather than a commit.
  final Set<String> welcomes = <String>{};
  // The `after` of every sync request, in order.
  final List<int> syncAfters = <int>[];
  // A sync loop that asks for more pages than this is running away: the
  // request is answered empty so the test fails instead of hanging.
  int maxSyncCalls = 1000;
  bool runaway = false;
  int keyPackagePublishes = 0;
  final Set<String> expiredEnvelopes = <String>{};
  final Map<String, int> mlsEventIdOverride = <String, int>{};
  bool networkDown = false;
  bool mlsNetworkDown = false;
  int? syncStatus;
  Duration? syncRetryAfter;
  int syncCalls = 0;
  int mlsListCalls = 0;
  int mlsMessageCalls = 0;

  MlsMessage _message(String id, int eventId) => MlsMessage(
        id: id,
        conversationId: 'conv_1',
        senderAccountId: 'acct_peer',
        senderDeviceId: 'dev_peer',
        kind: welcomes.contains(id) ? 'welcome' : 'commit',
        recipientDeviceId: welcomes.contains(id) ? 'dev_me' : null,
        payload: const <int>[1],
        idempotencyKey: 'idem_$id',
        syncEventId: mlsEventIdOverride[id] ?? eventId,
        createdAt: DateTime.utc(2026, 9, 24),
      );

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[Conversation(id: 'conv_1', kind: 'group')];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    syncCalls++;
    syncAfters.add(after);
    if (syncCalls > maxSyncCalls) {
      runaway = true;
      return const <SyncEvent>[];
    }
    if (networkDown) throw const SocketException('offline');
    final status = syncStatus;
    if (status == 401) throw ApiException(401, '{"error":"unauthorized"}');
    if (status == 429) {
      throw ApiException(429, 'rate limited', syncRetryAfter);
    }
    if (status == 409) {
      throw ApiException(409, '{"error":"device_recovery_required"}');
    }
    return events
        .where((event) => event.id > after)
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<Session> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceSecret,
  }) async =>
      Session(
        baseUrl: baseUrl,
        token: 'token_again',
        accountId: loginAccountId,
        deviceId: deviceId,
        username: username,
      );

  /// The account the server names on a password sign-in.
  String loginAccountId = 'acct_me';

  @override
  Future<void> publishDeviceKeyPackages(
    String token,
    List<List<int>> keyPackages, {
    Duration lifetime = const Duration(days: 14),
  }) async {
    keyPackagePublishes++;
  }

  @override
  Future<List<MlsMessage>> mlsMessages(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    mlsListCalls++;
    if (mlsNetworkDown) throw const SocketException('offline');
    return <MlsMessage>[
      for (final event in events)
        if (event.type == 'mls.message.created' && event.id > after)
          if ((event.payload as Map)['mls_message_id'] case final String id
              when !mlsMissing.contains(id))
            _message(id, event.id),
    ].take(limit).toList(growable: false);
  }

  @override
  Future<MlsMessage> mlsMessage(String token, String messageId) async {
    mlsMessageCalls++;
    if (mlsNetworkDown) throw const SocketException('offline');
    if (mlsMissing.contains(messageId)) {
      throw ApiException(404, '{"error":"not_found"}');
    }
    final event = events.firstWhere((event) =>
        event.type == 'mls.message.created' &&
        (event.payload as Map)['mls_message_id'] == messageId);
    return _message(messageId, event.id);
  }

  @override
  Future<ReceivedMessageEnvelope> message(
      String token, String messageId) async {
    if (expiredEnvelopes.contains(messageId)) {
      throw ApiException(410, '{"error":"message_expired"}');
    }
    throw ApiException(404, '{"error":"not_found"}');
  }
}

class _FakeMlsCrypto implements MlsConversationCryptoService {
  _FakeMlsCrypto(this.store);

  final LocalStore store;
  final Set<String> rejectedMls = <String>{};
  final List<String> processedMls = <String>[];
  final List<String> applied = <String>[];

  @override
  Future<void> activateSession(Session session) async {}

  @override
  Future<void> processMlsMessage(MlsMessage message) async {
    final marker = 'mls:${message.syncEventId}:${message.id}';
    if (await store.hasProcessedMlsMessage(marker)) return;
    if (rejectedMls.contains(message.id)) {
      throw StateError('commit rejected');
    }
    // Like a real group: a commit this state has already applied belongs
    // to a past epoch and is refused.
    if (processedMls.contains(message.id)) {
      throw StateError('commit is for a past epoch');
    }
    processedMls.add(message.id);
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: marker,
      conversationId: message.conversationId,
      expectedCursor: await store.loadSyncCursor(),
      cursor: message.syncEventId,
    ));
  }

  @override
  Future<List<int>?> processApplicationMessage(
      ReceivedMessageEnvelope envelope, int syncEventId) async {
    if (envelope.ciphertext.length == 1 && envelope.ciphertext.first == 0) {
      throw StateError('decryption failed');
    }
    applied.add(envelope.id);
    await store.commitSyncEvent(SyncEventCommit(
      eventKey: 'application:$syncEventId:${envelope.id}',
      conversationId: envelope.conversationId,
      expectedCursor: await store.loadSyncCursor(),
      cursor: syncEventId,
    ));
    return null;
  }

  int keyPackagesCreated = 0;

  @override
  Future<List<List<int>>> createReplenishmentKeyPackages(
      {int count = 5}) async {
    keyPackagesCreated++;
    return <List<int>>[
      for (var i = 0; i < count; i++) <int>[i]
    ];
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
