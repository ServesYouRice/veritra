// Sign-out must revoke the bearer token on the server. The local wipe used
// to close the API client first, so the revoke ran on a closed client, threw
// and was swallowed: a copied token stayed valid until it expired. These
// tests use a real ApiClient against a loopback server, because the fakes
// elsewhere have a close() that does nothing.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/client_config.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_recovery.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

void main() {
  // No test binding: it replaces HttpClient with one that answers 400.

  late HttpServer server;
  late List<String> requests;
  late bool answer;

  setUp(() async {
    requests = <String>[];
    answer = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path} '
          '${request.headers.value(HttpHeaders.authorizationHeader)}');
      await request.drain<void>();
      if (!answer) return; // Hold the reply; the client gives up.
      try {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      } catch (_) {
        // The client closed the connection.
      }
    });
  });

  tearDown(() => server.close(force: true));

  String origin() => 'http://127.0.0.1:${server.port}';

  ({AppState state, MemoryLocalStore store}) signedIn({
    Duration? revokeTimeout,
  }) {
    final store = MemoryLocalStore();
    ApiClient client() =>
        ApiClient(baseUrl: origin(), transport: TransportPolicy.demo);
    final state = AppState(
      apiClientFactory: (_) => client(),
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _IdleSyncService(),
      config: const ClientConfig(transport: TransportPolicy.demo),
    )
      ..api = client()
      ..session = Session(
        baseUrl: origin(),
        token: 'owner-token',
        accountId: 'acct_owner',
        deviceId: 'dev_owner',
      );
    if (revokeTimeout != null) state.signOutRevokeTimeout = revokeTimeout;
    return (state: state, store: store);
  }

  test('sign-out revokes the token on the server', () async {
    final (:state, :store) = signedIn();
    await store.saveSession(state.session!);
    await state.logout();

    expect(requests, contains('POST /api/v1/auth/logout Bearer owner-token'));
    expect(state.session, isNull);
    expect(state.api, isNull);
    final stored = await store.loadSession();
    expect(stored?.token, '');
    expect(stored?.deviceId, 'dev_owner');
  });

  test('relinking after a sync failure revokes the token on the server',
      () async {
    final (:state, :store) = signedIn();
    await store.saveSession(state.session!);
    state.syncRecovery = SyncRecovery(
      kind: SyncFailureKind.cursorExpired,
      recordedAt: DateTime.utc(2026, 10, 31),
    );
    await state.relinkAfterSyncRecovery(confirmed: true);

    expect(requests, contains('POST /api/v1/auth/logout Bearer owner-token'));
    expect(state.session, isNull);
    expect(await store.loadSession(), isNull);
  });

  test('a server that does not answer still lets sign-out finish', () async {
    answer = false;
    final (:state, :store) =
        signedIn(revokeTimeout: const Duration(milliseconds: 300));
    await store.saveSession(state.session!);
    final watch = Stopwatch()..start();
    await state.logout().timeout(const Duration(seconds: 10));

    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(requests, contains('POST /api/v1/auth/logout Bearer owner-token'));
    expect(state.session, isNull);
    expect((await store.loadSession())?.token, '');
  });

  test('an unreachable server still lets sign-out finish', () async {
    final (:state, :store) = signedIn();
    await store.saveSession(state.session!);
    await server.close(force: true);
    await state.logout();

    expect(state.session, isNull);
    expect((await store.loadSession())?.token, '');
  });
}

class _IdleSyncService implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
