// Shared fakes for the B7 passkey tests: a fake PasskeyClient, a scripted
// API client and an AppState harness. The JSON shapes come from the Go server
// tests (test/fixtures/api/v1/passkeys.json).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/passkeys.dart';
import 'package:private_messenger/push/push_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const pkOrigin = 'https://chat.example.com';

Map<String, Object?> pkFixture() => Map<String, Object?>.from(
    jsonDecode(File('test/fixtures/api/v1/passkeys.json').readAsStringSync())
        as Map);

Map<String, Object?> pkMap(Object? value) =>
    Map<String, Object?>.from(value! as Map);

const pkInfo =
    PasskeyServerInfo(rpId: 'chat.example.com', android: true, apple: true);

class FakePasskeys implements PasskeyClient {
  FakePasskeys({this.supported = true});

  final bool supported;
  Object? failure;
  final List<Map<String, Object?>> created = <Map<String, Object?>>[];
  final List<Map<String, Object?>> asked = <Map<String, Object?>>[];

  @override
  bool get platformSupported => supported;

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> publicKey) async {
    created.add(publicKey);
    if (failure != null) throw failure!;
    return <String, Object?>{'id': 'cred', 'type': 'public-key'};
  }

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> publicKey) async {
    asked.add(publicKey);
    if (failure != null) throw failure!;
    return <String, Object?>{'id': 'cred', 'type': 'public-key'};
  }
}

class PkApi extends ApiClient with LegacySyncPageFake {
  PkApi() : super(baseUrl: pkOrigin);

  static TestOnlyCryptoService crypto() => TestOnlyCryptoService();
  static MemoryLocalStore store() => MemoryLocalStore();

  Map<String, Object?> status = <String, Object?>{
    'setup_required': false,
    'passkeys': <String, Object?>{
      'rp_id': 'chat.example.com',
      'android': true,
      'apple': true,
    },
  };
  Map<String, Object?> loginPublicKey =
      pkMap(pkMap(pkFixture()['login_options'])['public_key']);
  Map<String, Object?> registerPublicKey =
      pkMap(pkMap(pkFixture()['register_options'])['public_key']);
  Object? loginFailure;
  Object? registerFailure;
  final List<String> trace = <String>[];
  final List<SyncEvent> events = <SyncEvent>[];

  /// Holds the next sync page until completed (a late result).
  Completer<void>? syncGate;
  bool closedByHost = false;
  List<PasskeyRecord> records = <PasskeyRecord>[];
  Session signedIn = const Session(
    baseUrl: pkOrigin,
    token: 'token-passkey',
    accountId: 'acct_owner',
    deviceId: 'dev_owner',
    role: 'owner',
  );

  @override
  Future<Map<String, Object?>> setupStatus() async => status;

  @override
  Future<PasskeyCeremony> passkeyLoginOptions({
    required String deviceId,
    required String deviceSecret,
  }) async {
    trace.add('login-options:$deviceId:$deviceSecret');
    return PasskeyCeremony(id: 'cer_login', publicKey: loginPublicKey);
  }

  @override
  Future<Session> passkeyLogin({
    required String ceremonyId,
    required String deviceId,
    required String deviceSecret,
    required Map<String, Object?> credential,
    String? fallbackUsername,
  }) async {
    trace.add('login:$ceremonyId:$deviceId');
    if (loginFailure != null) throw loginFailure!;
    return Session(
      baseUrl: signedIn.baseUrl,
      token: signedIn.token,
      accountId: signedIn.accountId,
      deviceId: signedIn.deviceId,
      username: fallbackUsername,
      deviceSecret: deviceSecret,
      role: signedIn.role,
    );
  }

  @override
  Future<List<PasskeyRecord>> passkeys(String token) async {
    trace.add('list');
    return records;
  }

  @override
  Future<PasskeyCeremony> passkeyRegisterOptions(String token) async {
    trace.add('register-options');
    return PasskeyCeremony(id: 'cer_reg', publicKey: registerPublicKey);
  }

  @override
  Future<String> passkeyRegister(
    String token, {
    required String ceremonyId,
    required String name,
    required Map<String, Object?> credential,
  }) async {
    trace.add('register:$ceremonyId:$name');
    if (registerFailure != null) throw registerFailure!;
    records = <PasskeyRecord>[
      ...records,
      PasskeyRecord(id: 'pk_new', name: name, createdAt: DateTime.utc(2026)),
    ];
    return 'pk_new';
  }

  @override
  Future<void> deletePasskey(String token, String id) async {
    trace.add('delete:$id');
    records = records.where((r) => r.id != id).toList();
  }

  @override
  Future<void> renamePasskey(String token, String id, String name) async {
    trace.add('rename:$id:$name');
  }

  @override
  Future<List<Conversation>> conversations(String token) async =>
      const <Conversation>[];

  @override
  Future<List<Device>> devices(String token) async => const <Device>[];

  @override
  Future<List<SyncEvent>> syncEvents(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final gate = syncGate;
    if (gate != null) {
      syncGate = null;
      await gate.future;
    }
    return events
        .where((e) => e.id > after)
        .take(limit)
        .toList(growable: false);
  }

  @override
  void close() {
    closedByHost = true;
    super.close();
  }

  /// Offers push, so the app registers one.
  bool pushEnabled = false;
  Completer<void>? pushConfigGate;
  Completer<void>? registerPushGate;
  int pushConfigRequests = 0;
  int pushRegisterRequests = 0;
  final disabledPush = <String>[];

  @override
  Future<String> registerNativePush(String token,
      {required String provider,
      required String deviceToken,
      String? notificationMode}) async {
    pushRegisterRequests++;
    await registerPushGate?.future;
    return 'sub-late';
  }

  @override
  Future<void> disablePush(String token, String subscriptionId) async {
    disabledPush.add(subscriptionId);
  }

  @override
  Future<Map<String, Object?>> pushConfig(String token) async {
    pushConfigRequests++;
    await pushConfigGate?.future;
    return pushEnabled
        ? <String, Object?>{
            'enabled': true,
            'providers': <String>['fcm'],
          }
        : const <String, Object?>{'enabled': false};
  }

  @override
  Future<void> logout(String token) async {}

  @override
  Future<String?> reauthenticate(
    String token,
    String password,
    String deviceSecret,
  ) async {
    trace.add('reauth');
    return null;
  }
}

class PkQuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();
  bool disposed = false;

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() {
    disposed = true;
    return _controller.close();
  }
}

class PkHarness {
  PkHarness({bool supported = true, PasskeyPlatform? platform})
      : passkeys = FakePasskeys(supported: supported) {
    state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) {
        final sync = PkQuietSync();
        syncs.add(sync);
        return sync;
      },
      passkeyClient: passkeys,
      pushService: push,
      passkeyPlatform: platform ?? PasskeyPlatform.android,
      passkeyAppleDomains: const <String>['chat.example.com'],
    );
  }

  final MemoryLocalStore store = MemoryLocalStore();
  final List<PkQuietSync> syncs = <PkQuietSync>[];
  final PkApi api = PkApi();
  final FakePush push = FakePush();
  final FakePasskeys passkeys;
  late final AppState state;

  Future<void> enrolled({int cursor = 0}) async {
    await store.saveSession(const Session(
      baseUrl: pkOrigin,
      token: '',
      accountId: 'acct_owner',
      deviceId: 'dev_owner',
      username: 'owner',
      deviceSecret: 'device-secret',
    ));
    if (cursor > 0) {
      // Existing MLS state, as login's cursor rule asks for.
      await store.saveCryptoState(
        StoredCryptoState(
          counter: 1,
          stateKey: List<int>.filled(32, 7),
          sealedState: <int>[1, 2, 3],
        ),
        cursor,
      );
    }
  }

  void dispose() => state.dispose();
}

/// A push service that records registrations and can refuse to unregister.
class FakePush extends DisabledMobilePushService {
  final endpointEvents = StreamController<PushEvent>.broadcast();
  @override
  Stream<PushEvent> get events => endpointEvents.stream;
  @override
  void dispose() {
    unawaited(endpointEvents.close());
  }

  Completer<void>? registerGate;
  final registerStarted = Completer<void>();
  bool failUnregister = false;
  int unregisterAttempts = 0;
  final List<String> registered = <String>[];

  @override
  Future<void> register({
    required String instance,
    String vapid = '',
    List<String> providers = const <String>[],
  }) async {
    if (!registerStarted.isCompleted) registerStarted.complete();
    await registerGate?.future;
    registered.add(instance);
  }

  @override
  Future<void> unregister(String instance) async {
    unregisterAttempts++;
    if (failUnregister) throw StateError('native refused');
    registered.remove(instance);
  }
}
