// Session lifecycle in AppState: what runs after a sign-in, how sync comes
// up and recovers, what a restore reports, which work may hold the shared
// session queue, and how this device keeps its MLS key packages supplied.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/backup_service.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _origin = 'https://localhost:8080';

const _owner = Session(
  baseUrl: _origin,
  token: 'token-owner',
  accountId: 'acct_owner',
  deviceId: 'dev_owner',
  username: 'owner',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> waitFor(FutureOr<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    fail('condition not reached');
  }

  /// Runs [body] in a zone that collects every uncaught asynchronous error
  /// into [errors] instead of failing the test on its own.
  Future<void> guarded(List<Object> errors, Future<void> Function() body) {
    final done = Completer<void>();
    runZonedGuarded(() async {
      try {
        await body();
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    }, (error, _) => errors.add(error));
    return done.future;
  }

  group('TASK-055: sync starts after a sign-in step fails', () {
    test('createOwner: a failed device refresh still starts sync', () async {
      final h = _Harness();
      h.api.devicesFailure = const SocketException('offline');

      await h.state.createOwner(_origin, 'owner', 'password', 'setup');

      expect(h.state.session?.token, 'token-owner');
      expect(h.state.error, isNotNull);
      await settle();
      expect(h.syncStarts, 1, reason: 'a signed-in app was left without sync');
      h.dispose();
    });

    test('createOwner: a failed key-package publish still starts sync',
        () async {
      final h = _Harness(mls: true);
      h.api.publishFailures.add(ApiException(503, '{"error":"unavailable"}'));

      await h.state.createOwner(_origin, 'owner', 'password', 'setup');

      expect(h.state.session?.token, 'token-owner');
      expect(h.state.error, isNotNull);
      await settle();
      expect(h.syncStarts, 1);
      h.dispose();
    });

    test('registerWithInvite: a failed conversation refresh still starts sync',
        () async {
      final h = _Harness();
      h.api.conversationsFailure = ApiException(500, '{"error":"internal"}');

      await h.state.registerWithInvite(_origin, 'JOIN', 'owner', 'password');

      expect(h.state.session?.token, 'token-owner');
      expect(h.state.error, isNotNull);
      await settle();
      expect(h.syncStarts, 1);
      h.dispose();
    });

    test('login: a failed device refresh still starts sync', () async {
      final h = _Harness();
      await h.store.saveSession(const Session(
        baseUrl: _origin,
        token: '',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
        deviceSecret: 'secret',
      ));
      h.api.devicesFailure = const SocketException('offline');

      await h.state.login(_origin, 'owner', 'password');

      expect(h.state.session?.token, 'token-owner');
      expect(h.state.error, isNotNull);
      await settle();
      expect(h.syncStarts, 1);
      h.dispose();
    });

    test('device link: a failed device refresh still starts sync', () async {
      final h = _Harness();
      h.state
        ..api = h.api
        ..pendingDeviceLinkClaim = DeviceLinkClaim(
          serverOrigin: _origin,
          deviceLink: DeviceLink(
            id: 'link_1',
            state: 'approved',
            verificationCode: '65432101',
            expiresAt: DateTime.utc(2030),
            accountId: 'acct_owner',
            claimedDeviceId: 'dev_owner',
            transcriptHash: List<int>.filled(32, 7),
            approvalTag: List<int>.filled(32, 9),
          ),
          claimToken: 'claim',
          deviceSecret: 'secret',
        );
      h.api.devicesFailure = const SocketException('offline');

      await h.state.completeDeviceLinkClaim();

      expect(h.state.session?.token, 'token-owner');
      expect(h.state.error, isNotNull);
      await settle();
      expect(h.syncStarts, 1);
      h.dispose();
    });

    test('login: a 401 after sign-in clears the session and starts nothing',
        () async {
      final h = _Harness();
      await h.store.saveSession(const Session(
        baseUrl: _origin,
        token: '',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
        deviceSecret: 'secret',
      ));
      h.api.devicesFailure = ApiException(401, '{"error":"unauthorized"}');

      await h.state.login(_origin, 'owner', 'password');
      await settle();

      expect(h.state.session, isNull);
      expect(h.syncStarts, 0);
      h.dispose();
    });
  });

  group('TASK-037: a failed sync startup is visible and recovers', () {
    test('restore: a lease failure shows offline, and resume starts sync',
        () async {
      final errors = <Object>[];
      await guarded(errors, () async {
        final store = _FaultStore()..acquireFailures = 1;
        await store.saveSession(_owner);
        final h = _Harness(store: store);

        await h.state.tryRestoreSession();
        await settle();

        expect(errors, isEmpty);
        expect(h.state.lifecycle, SessionLifecycle.ready);
        expect(h.state.session?.token, _owner.token);
        expect(h.state.syncError, isNotNull);
        expect(h.state.connectionStatus, ConnectionStatus.offline);
        expect(h.syncStarts, 0);
        expect(h.api.syncCalls, 0);

        h.state.handleAppLifecycleState(AppLifecycleState.resumed);
        await waitFor(() => h.api.syncCalls > 0);
        expect(h.syncStarts, 1);
        await waitFor(
            () => h.state.connectionStatus == ConnectionStatus.online);
        expect(h.state.syncError, isNull);
        h.dispose();
      });
      expect(errors, isEmpty);
    });

    test('login: a lease failure is not a sign-in failure', () async {
      final errors = <Object>[];
      await guarded(errors, () async {
        final store = _FaultStore()..acquireFailures = 1;
        await store.saveSession(const Session(
          baseUrl: _origin,
          token: '',
          accountId: 'acct_owner',
          deviceId: 'dev_owner',
          deviceSecret: 'secret',
        ));
        final h = _Harness(store: store);

        await h.state.login(_origin, 'owner', 'password');
        await settle();

        expect(h.state.error, isNull);
        expect(h.state.session?.token, _owner.token);
        expect(h.state.connectionStatus, ConnectionStatus.offline);
        expect(h.state.syncError, isNotNull);

        h.state.handleAppLifecycleState(AppLifecycleState.resumed);
        await waitFor(() => h.api.syncCalls > 0);
        expect(h.syncStarts, 1);
        h.dispose();
      });
      expect(errors, isEmpty);
    });

    test('reauthenticate: a failed release of the old lease recovers',
        () async {
      final errors = <Object>[];
      await guarded(errors, () async {
        final store = _FaultStore();
        await store.saveSession(const Session(
          baseUrl: _origin,
          token: 'token-owner',
          accountId: 'acct_owner',
          deviceId: 'dev_owner',
          deviceSecret: 'secret',
        ));
        final h = _Harness(store: store);
        await h.state.tryRestoreSession();
        await waitFor(() => h.api.syncCalls > 0);
        expect(h.syncStarts, 1);

        store.releaseFailures = 1;
        h.api.rotatedToken = 'token-rotated';
        expect(await h.state.reauthenticate('password'), isTrue);
        await settle();
        expect(h.state.connectionStatus, ConnectionStatus.offline);
        expect(h.syncStarts, 1);

        h.state.handleAppLifecycleState(AppLifecycleState.resumed);
        await waitFor(() => h.api.syncTokens.contains('token-rotated'));
        expect(h.syncStarts, 2);
        h.dispose();
      });
      expect(errors, isEmpty);
    });

    test('resume never starts sync for a session that was replaced', () async {
      final errors = <Object>[];
      await guarded(errors, () async {
        final store = _FaultStore()..acquireFailures = 1;
        await store.saveSession(_owner);
        final h = _Harness(store: store);
        await h.state.tryRestoreSession();
        await settle();
        expect(h.state.connectionStatus, ConnectionStatus.offline);

        await h.state.logout();
        h.state.handleAppLifecycleState(AppLifecycleState.resumed);
        await settle();
        expect(h.state.session, isNull);
        expect(h.syncStarts, 0);
        h.dispose();
      });
      expect(errors, isEmpty);
    });

    test('resume never starts sync for a session whose MLS activation failed',
        () async {
      final h = _Harness(mls: true);
      h.crypto!.activationFailure = StateError('keystore locked');
      await h.store.saveSession(const Session(
        baseUrl: _origin,
        token: '',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
        deviceSecret: 'secret',
      ));

      await h.state.login(_origin, 'owner', 'password');
      expect(h.state.error, isNotNull);
      h.state.handleAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(h.syncStarts, 0);
      h.dispose();
    });
  });

  group('TASK-038: a restore reports a session that did not come up', () {
    Future<_Harness> restored(_BackupMode mode,
        {_FaultStore? store, _Api? api}) async {
      final faults = store ?? _FaultStore();
      final h =
          _Harness(store: faults, api: api, backups: _Backups(faults, mode));
      return h;
    }

    test('a session that comes up is a success', () async {
      final h = await restored(_BackupMode.session);
      expect(await h.state.restoreFromBackup('v1.code'), isTrue);
      expect(h.state.errorFor(Ops.restore), isNull);
      expect(h.state.session?.token, _owner.token);
      expect(h.state.lifecycle, SessionLifecycle.ready);
      h.dispose();
    });

    test('an unreachable server still restores from the cache', () async {
      final api = _Api()..conversationsFailure = const SocketException('x');
      final h = await restored(_BackupMode.session, api: api);
      expect(await h.state.restoreFromBackup('v1.code'), isTrue);
      expect(h.state.errorFor(Ops.restore), isNull);
      expect(h.state.session?.token, _owner.token);
      h.dispose();
    });

    test('a session the server rejects asks for a password sign-in', () async {
      final api = _Api()
        ..conversationsFailure = ApiException(401, '{"error":"unauthorized"}');
      final h = await restored(_BackupMode.session, api: api);
      expect(await h.state.restoreFromBackup('v1.code'), isFalse);
      expect(h.state.session, isNull);
      expect(h.state.errorFor(Ops.restore),
          contains('Sign in with your password'));
      // The identity stays for that sign-in.
      expect((await h.store.loadSession())?.deviceId, _owner.deviceId);
      h.dispose();
    });

    test('nothing stored after the restore is a failure', () async {
      final h = await restored(_BackupMode.nothing);
      expect(await h.state.restoreFromBackup('v1.code'), isFalse);
      expect(h.state.session, isNull);
      expect(h.state.errorFor(Ops.restore), isNotNull);
      h.dispose();
    });

    test('a store that cannot be read keeps the recovery screen', () async {
      final store = _FaultStore()..loadSessionFailures = 1;
      final h = await restored(_BackupMode.session, store: store);
      expect(await h.state.restoreFromBackup('v1.code'), isFalse);
      expect(h.state.lifecycle, SessionLifecycle.recoveryRequired);
      expect(h.state.recoveryMessage, isNotNull);
      expect(h.state.errorFor(Ops.restore), isNotNull);
      h.dispose();
    });
  });

  group('TASK-043: export and manual retry stay off the session queue', () {
    late Directory tempDir;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const bob = Session(
      baseUrl: _origin,
      token: 'token-bob',
      accountId: 'acct_bob',
      deviceId: 'dev_bob',
    );
    const blocked = Duration(seconds: 5);

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('session_export_test_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, (_) async => tempDir.path);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, null);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    List<String> exportFiles() => tempDir
        .listSync()
        .map((entry) => entry.path)
        .where((path) => path.contains('veritra-account-export'))
        .toList();

    _Harness signedIn() {
      final h = _Harness();
      h.state
        ..api = h.api
        ..session = _owner
        ..conversations = <Conversation>[
          Conversation(id: 'conv_1', kind: 'group'),
        ];
      return h;
    }

    test('a blocked export page holds neither a send nor sign-out', () async {
      final h = signedIn();
      final page = h.api.exportGates[0] = Completer<Object?>();
      final export = h.state.exportAccount();
      await waitFor(() => h.api.exportBefores.isNotEmpty);

      expect(
          await h.state.sendMessageTo('conv_1', 'hi').timeout(blocked), isTrue);
      expect(await h.store.pendingEnvelopes(), hasLength(1));
      await h.state.logout().timeout(blocked);
      expect(h.state.session, isNull);

      page.complete(null);
      expect(await export, isNull);
      expect(h.api.exportBefores, hasLength(1),
          reason: 'the export kept paging after sign-out');
      expect(exportFiles(), isEmpty);
      h.dispose();
    });

    test('the final page answered after an account switch is not kept',
        () async {
      final h = signedIn();
      final page = h.api.exportGates[1] = Completer<Object?>();
      final export = h.state.exportAccount();
      await waitFor(() => h.api.exportBefores.length == 2);

      await h.state.logout().timeout(blocked);
      h.state
        ..api = h.api
        ..session = bob;
      page.complete(null);

      expect(await export, isNull);
      expect(exportFiles(), isEmpty);
      expect(h.state.error, isNull);
      expect(h.state.busy, isFalse);
      expect(h.state.session?.token, bob.token);
      h.dispose();
    });

    test('a 401 for the old session leaves the new session signed in',
        () async {
      final h = signedIn();
      final page = h.api.exportGates[1] = Completer<Object?>();
      final export = h.state.exportAccount();
      await waitFor(() => h.api.exportBefores.length == 2);

      await h.state.logout().timeout(blocked);
      h.state
        ..api = h.api
        ..session = bob;
      page.complete(ApiException(401, '{"error":"unauthorized"}'));

      expect(await export, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(h.state.session?.token, bob.token);
      expect(h.state.error, isNull);
      expect(exportFiles(), isEmpty);
      h.dispose();
    });

    test('a 401 for the current session still signs it out', () async {
      final h = signedIn();
      h.api.exportGates[1] = Completer<Object?>()
        ..complete(ApiException(401, '{"error":"unauthorized"}'));

      expect(await h.state.exportAccount(), isNull);
      expect(h.state.session, isNull);
      expect(h.state.error, isNotNull);
      expect(exportFiles(), isEmpty);
      h.dispose();
    });

    test('a blocked manual retry holds neither a send nor sign-out', () async {
      final h = signedIn();
      await h.store.enqueueEnvelope(_envelope('env_1'));
      final send = h.api.sendGate = Completer<Object?>();
      final retry = h.state.retryEnvelope('env_1');
      await waitFor(() => h.api.sent.contains('env_1'));
      expect(h.state.outboxState('env_1'), OutboxDeliveryState.sending);

      expect(
          await h.state.sendMessageTo('conv_1', 'hi').timeout(blocked), isTrue);
      send.complete(null);
      await retry;
      await waitFor(() async => (await h.store.pendingEnvelopes()).isEmpty);
      expect(h.api.sent.first, 'env_1');
      h.dispose();
    });

    test('a retry 401 for the old session leaves the new session signed in',
        () async {
      final h = signedIn();
      await h.store.enqueueEnvelope(_envelope('env_1'));
      final send = h.api.sendGate = Completer<Object?>();
      final retry = h.state.retryEnvelope('env_1');
      await waitFor(() => h.api.sent.contains('env_1'));

      await h.state.logout().timeout(blocked);
      h.state
        ..api = h.api
        ..session = bob;
      send.complete(ApiException(401, '{"error":"unauthorized"}'));
      await retry;
      await Future<void>.delayed(Duration.zero);

      expect(h.state.session?.token, bob.token);
      h.dispose();
    });
  });
}

MessageEnvelope _envelope(String key) => MessageEnvelope(
      conversationId: 'conv_1',
      idempotencyKey: key,
      ciphertext: <int>[1, 2, 3],
      cryptoProtocol: 'test-only-not-production',
    );

/// A memory store whose sync-lease steps fail a set number of times.
class _FaultStore extends MemoryLocalStore {
  int acquireFailures = 0;
  int releaseFailures = 0;
  int loadSessionFailures = 0;

  @override
  Future<Session?> loadSession() async {
    if (loadSessionFailures > 0) {
      loadSessionFailures--;
      throw StateError('keystore unavailable');
    }
    return super.loadSession();
  }

  @override
  Future<void> acquireSyncLease(LocalSyncLease lease) async {
    if (acquireFailures > 0) {
      acquireFailures--;
      throw StateError('sync lease unavailable');
    }
    await super.acquireSyncLease(lease);
  }

  @override
  Future<void> releaseSyncLease(LocalSyncLease lease) async {
    if (releaseFailures > 0) {
      releaseFailures--;
      throw StateError('sync lease unavailable');
    }
    await super.releaseSyncLease(lease);
  }
}

/// One AppState over a memory store, a scripted API and a counting sync
/// factory. With [mls] it runs a minimal MLS crypto fake, so key packages
/// are created and published.
class _Harness {
  _Harness({
    bool mls = false,
    MemoryLocalStore? store,
    _Api? api,
    this.backups,
  })  : store = store ?? MemoryLocalStore(),
        api = api ?? _Api(),
        crypto = mls ? _MlsCrypto() : null {
    state = build();
  }

  final MemoryLocalStore store;
  final _Api api;
  final _MlsCrypto? crypto;
  final BackupService? backups;
  late AppState state;
  int syncStarts = 0;

  AppState build() => AppState(
        apiClientFactory: (_) => api,
        cryptoService: crypto ?? TestOnlyCryptoService(),
        localStore: store,
        syncServiceFactory: (_, __) {
          syncStarts++;
          return _QuietSync();
        },
        backupService: backups,
      );

  void dispose() => state.dispose();
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: _origin);

  Session signedIn = _owner;
  String? rotatedToken;
  Object? devicesFailure;
  Object? conversationsFailure;

  /// Failures thrown by the next key-package publishes, in order.
  final List<Object> publishFailures = <Object>[];

  /// The number of packages in each publish the server accepted.
  final List<int> published = <int>[];
  int syncCalls = 0;
  final List<String> syncTokens = <String>[];

  /// The `before` of every export page request, in order.
  final List<String?> exportBefores = <String?>[];

  /// Holds export page N (from 0) until completed; completing with an
  /// error object fails that page with it.
  final Map<int, Completer<Object?>> exportGates = <int, Completer<Object?>>{};

  /// Holds the next envelope delivery until completed, like [exportGates].
  Completer<Object?>? sendGate;
  final List<String> sent = <String>[];

  static const _reservation = EnrollmentReservation(
    id: 'enroll_1',
    accountId: 'acct_owner',
    deviceId: 'dev_owner',
    challenge: <int>[1, 2, 3],
  );

  @override
  Future<EnrollmentReservation> reserveOwnerEnrollment({
    String setupToken = '',
  }) async =>
      _reservation;

  @override
  Future<EnrollmentReservation> reserveRegistrationEnrollment(
          String inviteCode) async =>
      _reservation;

  @override
  Future<Session> createOwner({
    required String username,
    required String password,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
    String setupToken = '',
    String? instanceName,
  }) async =>
      signedIn;

  @override
  Future<Session> register({
    required String inviteCode,
    required String username,
    required String password,
    required String deviceName,
    required EnrollmentReservation enrollment,
    required EnrollmentCredential credential,
  }) async =>
      signedIn;

  @override
  Future<Session> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceSecret,
  }) async =>
      signedIn;

  @override
  Future<Session?> completeDeviceLinkClaim(
          String linkId,
          String claimToken,
          List<int> expectedTranscriptHash,
          List<int> expectedApprovalTag) async =>
      signedIn;

  @override
  Future<List<Conversation>> conversations(String token) async {
    final failure = conversationsFailure;
    if (failure != null) throw failure;
    return const <Conversation>[];
  }

  @override
  Future<List<Device>> devices(String token) async {
    final failure = devicesFailure;
    if (failure != null) throw failure;
    return const <Device>[];
  }

  @override
  Future<void> publishDeviceKeyPackages(
    String token,
    List<List<int>> keyPackages, {
    Duration lifetime = const Duration(days: 14),
  }) async {
    if (publishFailures.isNotEmpty) throw publishFailures.removeAt(0);
    published.add(keyPackages.length);
  }

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    syncCalls++;
    syncTokens.add(token);
    return const <SyncEvent>[];
  }

  @override
  Future<List<MlsRevocation>> mlsRevocations(String token) async =>
      const <MlsRevocation>[];

  @override
  Future<Map<String, Object?>> pushConfig(String token) async =>
      const <String, Object?>{'enabled': false};

  @override
  Future<List<Invite>> listInvites(String token) async => const <Invite>[];

  @override
  Future<List<Community>> listCommunities(String token) async =>
      const <Community>[];

  @override
  Future<Map<String, Object?>> exportAccountPage(
    String token, {
    int limit = 250,
    String? before,
  }) async {
    final index = exportBefores.length;
    exportBefores.add(before);
    final gate = exportGates[index];
    if (gate != null) {
      final failure = await gate.future;
      if (failure != null) throw failure;
    }
    return <String, Object?>{
      'manifest_version': 'v2',
      'messages': <Object?>[
        <String, Object?>{'id': 'msg_page_$index'},
      ],
      if (index == 0) 'next_before': 'msg_page_0',
    };
  }

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {
    sent.add(envelope.idempotencyKey);
    final gate = sendGate;
    if (gate == null) return;
    sendGate = null;
    final failure = await gate.future;
    if (failure != null) throw failure;
  }

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);

  @override
  Future<String?> reauthenticate(
          String token, String password, String deviceSecret) async =>
      rotatedToken;

  @override
  Future<void> logout(String token) async {}
}

enum _BackupMode { session, nothing }

/// Stands in for the download and decryption: a successful recover leaves
/// the backup's session in the store, or (with [_BackupMode.nothing]) none.
class _Backups implements BackupService {
  _Backups(this.store, this.mode);

  final MemoryLocalStore store;
  final _BackupMode mode;

  @override
  Future<void> recover(String recoveryCode) async {
    if (mode == _BackupMode.session) await store.saveSession(_owner);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The MLS calls the session paths make, and nothing else.
class _MlsCrypto extends TestOnlyCryptoService
    implements MlsConversationCryptoService {
  /// The count asked for in each key-package batch.
  final List<int> created = <int>[];
  Object? activationFailure;

  @override
  Future<void> activateSession(Session session) async {
    final failure = activationFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<List<List<int>>> createReplenishmentKeyPackages(
      {int count = 5}) async {
    created.add(count);
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
