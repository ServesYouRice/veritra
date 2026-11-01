import 'dart:async';
import 'dart:typed_data';

import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// Fakes for the K0 R3/R4 tests: a server that keeps the recovery state of
/// one account, and a crypto service whose recovery calls are recorded.

const k0Origin = 'https://chat.example.org';

/// The recovery key the fake crypto knows, in its canonical display.
const k0Display = 'ABCDEFGHJKMNPQRSTVWXYZ0123456789ABCDEFGHJKMNPQRSTVWX';

ApiException k0Error(int status, String code) =>
    ApiException(status, '{"error":"$code"}');

class K0Crypto extends TestOnlyCryptoService
    implements MlsConversationCryptoService, RecoveryCryptoService {
  /// Every entropy buffer handed out, to check that it was wiped.
  final List<Uint8List> handedOut = <Uint8List>[];
  final List<String> decodedTexts = <String>[];
  final List<String> signedOrigins = <String>[];
  final List<List<int>> signedChallenges = <List<int>>[];
  final List<Session> activated = <Session>[];
  final List<StoredCryptoState> resumed = <StoredCryptoState>[];
  int enrollments = 0;
  int seals = 0;
  int abandons = 0;
  bool pendingIdentity = false;

  static Uint8List entropy() =>
      Uint8List.fromList(List<int>.generate(30, (i) => i + 1));

  Uint8List _hand(Uint8List value) {
    handedOut.add(value);
    return value;
  }

  @override
  Future<Uint8List> generateRecoveryKey() async => _hand(entropy());

  @override
  Future<String> encodeRecoveryKey(Uint8List value) async => k0Display;

  @override
  Future<Uint8List> decodeRecoveryKey(String text) async {
    decodedTexts.add(text);
    if (text.toUpperCase() != k0Display) {
      throw const FormatException('invalid key');
    }
    return _hand(entropy());
  }

  @override
  Future<RecoveryKeyValues> deriveRecoveryKey(Uint8List value) async =>
      RecoveryKeyValues(
        rkPub: Uint8List.fromList(List<int>.filled(32, 0xC3)),
        rkId: Uint8List.fromList(List<int>.filled(16, 0xB2)),
        rkAuthPub: Uint8List.fromList(List<int>.filled(32, 0xA1)),
      );

  @override
  Future<Uint8List> signRecoveryProof({
    required Uint8List entropy,
    required List<int> challenge,
    required List<int> signingKey,
    required List<int> keyPackage,
    required String origin,
  }) async {
    signedOrigins.add(origin);
    signedChallenges.add(List<int>.of(challenge));
    return Uint8List.fromList(List<int>.filled(64, 0x5E));
  }

  @override
  Future<EnrollmentCredential> createEnrollmentCredential(
      EnrollmentReservation reservation) async {
    enrollments++;
    pendingIdentity = true;
    return super.createEnrollmentCredential(reservation);
  }

  @override
  Future<StoredCryptoState> sealPendingEnrollment() async {
    if (!pendingIdentity) throw StateError('no pending enrollment identity');
    seals++;
    return StoredCryptoState(
      counter: 1,
      stateKey: List<int>.filled(32, 9),
      sealedState: const <int>[4, 4, 4],
      changes: const <CryptoRecordChange>[
        CryptoRecordChange(
            kind: 1, recordId: <int>[1], generation: 1, sealed: <int>[5]),
      ],
    );
  }

  @override
  Future<void> resumePendingEnrollment({
    required String accountId,
    required String deviceId,
    required StoredCryptoState state,
  }) async {
    resumed.add(state);
    pendingIdentity = true;
  }

  @override
  Future<void> abandonPendingEnrollment() async {
    abandons++;
    pendingIdentity = false;
  }

  @override
  Future<void> activateSession(Session session) async {
    activated.add(session);
    pendingIdentity = false;
  }

  @override
  Future<List<List<int>>> createReplenishmentKeyPackages(
          {int count = 5}) async =>
      <List<int>>[
        for (var i = 0; i < count; i++) <int>[i]
      ];

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// One account's recovery state on the server side.
class K0Server {
  RecoveryKeyStatus status =
      const RecoveryKeyStatus(available: true, configured: false);
  bool recentAuth = false;
  bool requireRecentAuth = true;
  String reservationAccount = 'acct_me';
  Object? claimFailure;
  final List<Object> statusAnswers = <Object>[];
  final List<String> reserved = <String>[];
  final List<Map<String, Object?>> claims = <Map<String, Object?>>[];
  final List<Map<String, Object?>> logins = <Map<String, Object?>>[];
  final List<String> cancels = <String>[];
  final List<Map<String, List<int>>> puts = <Map<String, List<int>>>[];
  final List<String> passwords = <String>[];
  final List<SyncEvent> events = <SyncEvent>[];
  int statusReads = 0;
  int recoveryPolls = 0;

  Session session({String token = 'tok_new'}) => Session(
        baseUrl: k0Origin,
        token: token,
        accountId: 'acct_me',
        deviceId: 'dev_new',
        username: 'alice',
        deviceSecret: 'secret_new',
        role: 'member',
      );
}

class K0Api extends ApiClient {
  K0Api(this.server, [String baseUrl = k0Origin]) : super(baseUrl: baseUrl);

  final K0Server server;

  @override
  Future<RecoveryKeyStatus> recoveryKeyStatus(String token) async {
    server.statusReads++;
    return server.status;
  }

  @override
  Future<RecoveryKeyStatus> putRecoveryKey(String token,
      {required List<int> rkAuthPub, required List<int> rkId}) async {
    if (server.requireRecentAuth && !server.recentAuth) {
      throw k0Error(403, 'recent_auth_required');
    }
    server.puts.add(<String, List<int>>{
      'rk_auth_pub': List<int>.of(rkAuthPub),
      'rk_id': List<int>.of(rkId),
    });
    server.status = RecoveryKeyStatus(
        available: true, configured: true, setAt: DateTime.utc(2026, 11, 1));
    return server.status;
  }

  @override
  Future<String?> reauthenticate(
      String token, String password, String deviceSecret) async {
    if (password != 'pw') throw k0Error(401, 'invalid_credentials');
    server.recentAuth = true;
    return null;
  }

  @override
  Future<EnrollmentReservation> reserveAccountRecovery(String username) async {
    server.reserved.add(username);
    return EnrollmentReservation(
      id: 'res_1',
      accountId: server.reservationAccount,
      deviceId: 'dev_new',
      challenge: const <int>[9, 8, 7],
    );
  }

  @override
  Future<AccountRecoveryClaim> claimAccountRecovery({
    required EnrollmentReservation enrollment,
    required String password,
    required String deviceName,
    required EnrollmentCredential credential,
    required List<int> recoverySignature,
  }) async {
    server.claims.add(<String, Object?>{
      'enrollment_reservation_id': enrollment.id,
      'password': password,
      'device_name': deviceName,
      'recovery_signature': List<int>.of(recoverySignature),
    });
    final failure = server.claimFailure;
    if (failure != null) throw failure;
    return AccountRecoveryClaim(
      requestId: 'arr_1',
      claimToken: 'claim_tok',
      deviceSecret: 'secret_new',
      state: 'waiting',
      readyAt: DateTime.utc(2026, 11, 8, 10),
    );
  }

  @override
  Future<AccountRecoveryStatus> accountRecoveryStatus(
      String requestId, String claimToken) async {
    server.recoveryPolls++;
    if (server.statusAnswers.isEmpty) {
      return AccountRecoveryStatus(
          phase: AccountRecoveryPhase.waiting,
          readyAt: DateTime.utc(2026, 11, 8, 10));
    }
    final next = server.statusAnswers.removeAt(0);
    if (next is AccountRecoveryStatus) return next;
    throw next;
  }

  @override
  Future<void> cancelAccountRecovery(String token, String requestId) async {
    if (!server.recentAuth) throw k0Error(403, 'recent_auth_required');
    server.cancels.add(requestId);
    server.status = RecoveryKeyStatus(
        available: true, configured: server.status.configured);
  }

  @override
  Future<Session> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceSecret,
  }) async {
    server.logins.add(<String, Object?>{
      'username': username,
      'password': password,
      'device_id': deviceId,
      'device_secret': deviceSecret,
    });
    if (password != 'pw') throw k0Error(401, 'invalid_credentials');
    return server.session(token: 'tok_login');
  }

  @override
  Future<void> changePassword(String token, String newPassword) async {
    server.passwords.add(newPassword);
  }

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<void> publishDeviceKeyPackages(
    String token,
    List<List<int>> keyPackages, {
    Duration lifetime = const Duration(days: 14),
  }) async {}

  @override
  Future<List<SyncEvent>> syncEvents(String token,
          {int after = 0, int limit = 100}) async =>
      server.events
          .where((event) => event.id > after)
          .take(limit)
          .toList(growable: false);

  @override
  Future<List<MlsMessage>> mlsMessages(String token,
          {int after = 0, int limit = 100}) async =>
      const <MlsMessage>[];

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

class K0QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}

/// An app over [store] talking to [server]; [apis] collects every client
/// the app made (one per origin it connected to).
AppState k0App(K0Server server, LocalStore store, CryptoService crypto,
        {List<K0Api>? apis}) =>
    AppState(
      apiClientFactory: (url) {
        final api = K0Api(server, url);
        apis?.add(api);
        return api;
      },
      cryptoService: crypto,
      localStore: store,
      syncServiceFactory: (_, __) => K0QuietSync(),
    );

const k0SignedIn = Session(
  baseUrl: k0Origin,
  token: 'tok_old',
  accountId: 'acct_me',
  deviceId: 'dev_old',
  username: 'alice',
  deviceSecret: 'secret_old',
  role: 'member',
);
