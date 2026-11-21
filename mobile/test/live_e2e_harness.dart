import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/client_config.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Shared harness of the live end-to-end runs (`scripts/test-live-e2e.sh`):
/// real clients and real OpenMLS against a real server binary the test
/// starts, on loopback only.
///
/// Environment: VERITRA_LIVE_E2E_SERVER (the server binary),
/// VERITRA_LIVE_E2E_DATA (a scratch directory), VERITRA_CRYPTO_LIBRARY, and
/// for the L1-5 run VERITRA_LIVE_E2E_TESTHOOK_SERVER (a binary built with
/// the `veritra_testhooks` tag). VERITRA_LIVE_E2E_PORT_BASE moves the ports.
class LiveE2eEnv {
  LiveE2eEnv._(this.serverPath, this.testHookServerPath, this.dataDir,
      this.libraryPath, this.portBase);

  factory LiveE2eEnv.load() {
    final env = Platform.environment;
    return LiveE2eEnv._(
      env['VERITRA_LIVE_E2E_SERVER'],
      env['VERITRA_LIVE_E2E_TESTHOOK_SERVER'],
      env['VERITRA_LIVE_E2E_DATA'],
      env['VERITRA_CRYPTO_LIBRARY'],
      int.tryParse(env['VERITRA_LIVE_E2E_PORT_BASE'] ?? '') ?? 18100,
    );
  }

  final String? serverPath;
  final String? testHookServerPath;
  final String? dataDir;
  final String? libraryPath;
  final int portBase;

  /// The skip reason when the run is not set up, else false.
  Object get skip =>
      serverPath == null || dataDir == null || libraryPath == null
          ? 'run scripts/test-live-e2e.sh'
          : false;

  Object get skipTestHooks => skip != false
      ? skip
      : testHookServerPath == null
          ? 'run scripts/test-live-e2e.sh (needs the test-hook server)'
          : false;
}

const String liveSetupToken = 'live-e2e-setup-token';

class LiveServer {
  LiveServer(
    this.path,
    this.dataDir,
    this.port, {
    this.environment = const <String, String>{},
  });

  final String path;
  final String dataDir;
  final int port;

  /// Added to the base environment (feature switches, public origin).
  final Map<String, String> environment;
  Process? _process;

  String get baseUrl => 'http://127.0.0.1:$port';

  Map<String, String> get _environment => <String, String>{
        // An unset environment means production, which refuses this short
        // local setup token (and a test-hook binary refuses outright).
        'PRIVATE_MESSENGER_ENV': 'development',
        'PRIVATE_MESSENGER_SETUP_TOKEN': liveSetupToken,
        'PRIVATE_MESSENGER_LOG_LEVEL': 'error',
        // Every client of a run shares one loopback address and some share
        // an account, so the per-address and per-account budgets an
        // operator sets for real traffic would throttle the run itself.
        'PRIVATE_MESSENGER_RATE_LIMIT_ADDRESS_PER_MINUTE': '100000',
        'PRIVATE_MESSENGER_RATE_LIMIT_ACCOUNT_PER_MINUTE': '100000',
        'PRIVATE_MESSENGER_RATE_LIMIT_SIGNED_IN_ADDRESS_PER_MINUTE': '1000000',
        ...environment,
      };

  Future<void> start() async {
    _process = await Process.start(
      path,
      <String>['serve', '--addr', '127.0.0.1:$port', '--data-dir', dataDir],
      environment: _environment,
    );
    // Drain output so the server never blocks on a full pipe.
    _process!.stdout.drain<void>();
    _process!.stderr.drain<void>();
    final client = HttpClient();
    try {
      for (var attempt = 0; attempt < 120; attempt++) {
        try {
          final request = await client.getUrl(Uri.parse('$baseUrl/healthz'));
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode == 200) return;
        } on SocketException {
          // Not listening yet.
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      fail('server did not become ready');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill();
    await process.exitCode;
  }

  /// Runs an offline server command on the stopped server's data directory
  /// and returns its exit code and output.
  Future<ProcessResult> runOffline(List<String> arguments) => Process.run(
        path,
        <String>[arguments.first, '--data-dir', dataDir, ...arguments.skip(1)],
        environment: _environment,
      );
}

class LiveClient {
  LiveClient(this.bindings, this.baseUrl, {MemoryLocalStore? store})
      : store = store ?? MemoryLocalStore() {
    final attachments = Directory.systemTemp.createTempSync(
      'veritra-live-e2e-attachments-',
    );
    state = AppState(
      apiClientFactory: (url) =>
          ApiClient(baseUrl: url, transport: TransportPolicy.demo),
      cryptoService: NativeCryptoService(
        bindings: bindings,
        localStore: this.store,
      ),
      localStore: this.store,
      attachmentService: AttachmentCryptoService(
        bindings,
        directoryProvider: () async => attachments,
      ),
      syncServiceFactory: (url, token) =>
          WebSocketSyncService(baseUrl: url, token: token),
      config: const ClientConfig(
        demo: true,
        transport: TransportPolicy.demo,
        deviceName: 'Live E2E test device',
      ),
    );
    final transfers = Directory.systemTemp.createTempSync(
      'veritra-live-e2e-k2-',
    );
    state.historyTransferDirectory = () async => transfers.path;
  }

  final NativeCryptoBindings bindings;
  final String baseUrl;

  /// Survives [restart]: the app's data on disk.
  final MemoryLocalStore store;
  late final AppState state;

  NativeCryptoService get crypto => state.cryptoService as NativeCryptoService;

  String get accountId => state.session!.accountId!;
  String get deviceId => state.session!.deviceId!;

  void expectOk() => expect(state.error, isNull, reason: state.error);

  Future<LiveClient> invite(String username) async {
    final invite = await state.createInvite();
    expectOk();
    final client = LiveClient(bindings, baseUrl);
    await client.state.registerWithInvite(
      baseUrl,
      invite!.code,
      username,
      '$username-password-123',
    );
    client.expectOk();
    return client;
  }

  /// A new app instance on the same local data, as after the process was
  /// killed: nothing of this instance is shut down cleanly beyond its
  /// socket, and nothing in memory carries over.
  Future<LiveClient> restart() async {
    dispose();
    final client = LiveClient(bindings, baseUrl, store: store);
    await client.state.tryRestoreSession();
    client.expectOk();
    return client;
  }

  /// [joiner] joins [communityId] through a link this account makes and
  /// approves, and waits until its device is in the shared group.
  Future<void> join(
    LiveClient joiner,
    String communityId,
    String shared,
  ) async {
    final link = await state.createInviteLink(
      InviteTargetKind.community,
      communityId,
    );
    expectOk();
    final parsed = MembershipInviteLink.tryParse(
      link!,
      expectedOrigin: baseUrl,
    );
    expect(parsed, isNotNull);
    expect(await joiner.state.requestToJoin(parsed!), isNotNull);
    joiner.expectOk();
    final requests = await state.loadJoinRequests(
      InviteTargetKind.community,
      communityId,
    );
    expectOk();
    final request = requests!.singleWhere(
      (r) => r.accountId == joiner.accountId,
    );
    expect(await state.decideJoinRequest(request, approve: true), isTrue);
    expectOk();
    await joiner.waitUntil(() async {
      await joiner.state.refreshConversations();
      await joiner.state.refreshCommunities();
      return await joiner.epoch(shared) != null;
    }, timeout: const Duration(seconds: 120));
  }

  /// Every client shares one address, so the server's per-address rate
  /// limit can refuse a catch-up; the app retries after the window resets.
  Future<void> waitUntil(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    // Captured before the first await, so it names the step that waited.
    final caller =
        StackTrace.current.toString().split('\n').take(3).join(' <- ');
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (state.deviceRecoveryRequired) {
        fail('sync stopped: ${state.error}');
      }
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'timed out after ${timeout.inSeconds} s (connection '
          '${state.connectionStatus.name}, error ${state.error ?? 'none'}) '
          'at $caller',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<LocalMessage> waitFor(
    String conversationId,
    bool Function(LocalMessage message) matches, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    LocalMessage? found;
    await waitUntil(() async {
      found =
          (await store.loadMessages(conversationId)).where(matches).firstOrNull;
      return found != null;
    }, timeout: timeout);
    return found!;
  }

  Future<List<String?>> bodies(String conversationId) async => [
        for (final m in await store.loadMessages(conversationId)) m.body,
      ];

  Future<int?> epoch(String conversationId) async =>
      (await crypto.groupEpoch(conversationId))?.epoch;

  void dispose() {
    state.sync?.dispose();
    state.sync = null;
  }
}
