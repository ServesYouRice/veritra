// Session lifecycle in AppState: what runs after a sign-in, how sync comes
// up and recovers, what a restore reports, which work may hold the shared
// session queue, and how this device keeps its MLS key packages supplied.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
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
}

/// One AppState over a memory store, a scripted API and a counting sync
/// factory. With [mls] it runs a minimal MLS crypto fake, so key packages
/// are created and published.
class _Harness {
  _Harness({bool mls = false, MemoryLocalStore? store, _Api? api})
      : store = store ?? MemoryLocalStore(),
        api = api ?? _Api(),
        crypto = mls ? _MlsCrypto() : null {
    state = build();
  }

  final MemoryLocalStore store;
  final _Api api;
  final _MlsCrypto? crypto;
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
      );

  void dispose() => state.dispose();
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: _origin);

  Session signedIn = _owner;
  Object? devicesFailure;
  Object? conversationsFailure;

  /// Failures thrown by the next key-package publishes, in order.
  final List<Object> publishFailures = <Object>[];

  /// The number of packages in each publish the server accepted.
  final List<int> published = <int>[];
  int syncCalls = 0;

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
  Future<void> logout(String token) async {}
}

/// The MLS calls the session paths make, and nothing else.
class _MlsCrypto extends TestOnlyCryptoService
    implements MlsConversationCryptoService {
  /// The count asked for in each key-package batch.
  final List<int> created = <int>[];

  @override
  Future<void> activateSession(Session session) async {}

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
