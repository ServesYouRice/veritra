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

/// C7 full mode end to end: real clients, real OpenMLS and a real server
/// with `PRIVATE_MESSENGER_C7_HISTORY=1`. A channel made with full history
/// gets posts; a newcomer who joins later reads them; a member removed
/// afterwards never receives a post sent after the removal.
///
/// Run with the server binary and the crypto library named in the
/// environment (as `scripts/test-demo-e2e.sh` does for the demo test):
/// VERITRA_C7_E2E_SERVER, VERITRA_C7_E2E_DATA, VERITRA_CRYPTO_LIBRARY and
/// optionally VERITRA_C7_E2E_PORT.
void main() {
  final serverPath = Platform.environment['VERITRA_C7_E2E_SERVER'];
  final dataDir = Platform.environment['VERITRA_C7_E2E_DATA'];
  final port = Platform.environment['VERITRA_C7_E2E_PORT'] ?? '18093';
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = serverPath == null || dataDir == null || libraryPath == null
      ? 'set VERITRA_C7_E2E_SERVER, VERITRA_C7_E2E_DATA and '
          'VERITRA_CRYPTO_LIBRARY'
      : false;

  Future<void> run({required bool full}) async {
    final server = _Server(
      serverPath!,
      '$dataDir/c7-${full ? 'full' : 'from-join'}',
      port,
    );
    addTearDown(server.stop);
    await server.start();
    final baseUrl = server.baseUrl;
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final owner = _Client(bindings, baseUrl);
    addTearDown(owner.dispose);
    await owner.state.createOwner(
      baseUrl,
      'c7owner',
      'owner-password-123',
      'c7-e2e-setup-token',
    );
    owner.expectOk();
    final carol = await owner.invite('c7carol');
    addTearDown(carol.dispose);
    final bob = await owner.invite('c7bob');
    addTearDown(bob.dispose);

    final community = await owner.state.createCommunity('history');
    owner.expectOk();
    final shared = community!.sharedConversationId;
    expect(shared, isNotNull, reason: 'C0 layout: one shared group');
    await owner.waitUntil(() async => await owner.epoch(shared!) != null);

    // Carol joins before the channel exists.
    await owner.join(carol, community.id, shared!);

    final channel = await owner.state.createChannel(
      community.id,
      'rules',
      kind: 'open',
      fullHistory: full,
    );
    owner.expectOk();
    expect(channel, isNotNull);
    await owner.waitUntil(() async {
      await owner.state.c7WorkPassForTesting();
      final view = await owner.state.channelHistory(channel!);
      return view != null && view.full == full && !view.pending;
    });
    await carol.waitUntil(() async {
      await carol.state.refreshCommunities();
      final known = carol.state.channelsByCommunity[community.id]
          ?.where((c) => c.id == channel!.id)
          .firstOrNull;
      if (known == null) return false;
      final view = await carol.state.channelHistory(known);
      return view != null && view.full == full;
    });

    // The server's switch reached the app: posts go in two parts.
    expect(
      (owner.state.cryptoService as NativeCryptoService).c7SealedBodies,
      isTrue,
    );
    owner.state.selectChannel(shared, channel!.id);
    for (final text in <String>['rule one', 'rule two']) {
      expect(await owner.state.sendMessageTo(shared, text), isTrue);
      owner.expectOk();
    }
    await carol.waitFor(shared, (m) => m.body == 'rule two');

    // Bob joins after the posts. Full history hands them over; without it
    // (the control) MLS withholding keeps them from him.
    await owner.join(bob, community.id, shared);
    if (full) {
      await bob.waitUntil(() async {
        await bob.state.c7WorkPassForTesting();
        await owner.state.c7WorkPassForTesting();
        final bodies = {
          for (final m in await bob.store.loadMessages(shared)) m.body,
        };
        return bodies.containsAll(<String>['rule one', 'rule two']);
      }, timeout: const Duration(seconds: 120));
      for (final message in await bob.store.loadMessages(shared)) {
        if (message.body == 'rule one' || message.body == 'rule two') {
          expect(message.channelId, channel.id);
          // Imported through C7: the row names the generation that
          // sealed it.
          expect(message.c7Gen, isNotNull);
        }
      }
    } else {
      // Same passes and time as the full run would get.
      for (var i = 0; i < 10; i++) {
        await bob.state.c7WorkPassForTesting();
        await owner.state.c7WorkPassForTesting();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final bodies = [
        for (final m in await bob.store.loadMessages(shared)) m.body,
      ];
      expect(bodies, isNot(contains('rule one')));
      expect(bodies, isNot(contains('rule two')));
    }

    // Carol is removed; a post after that never reaches her.
    final before = (await owner.epoch(shared))!;
    expect(
      await owner.state.removeCommunityMember(
        community.id,
        carol.accountId,
      ),
      isTrue,
    );
    owner.expectOk();
    await owner.waitUntil(
      () async => ((await owner.epoch(shared)) ?? 0) > before,
    );
    // The removal commits before the next send goes out (D68).
    expect(await owner.state.sendMessageTo(shared, 'after carol'), isTrue);
    await bob.waitFor(shared, (m) => m.body == 'after carol');
    // Give Carol's device every chance to sync, then check.
    await Future<void>.delayed(const Duration(seconds: 3));
    try {
      await carol.state.refreshHistory(shared);
    } on Object {
      // A refused read is the expected outcome for a former member.
    }
    final carolBodies = [
      for (final m in await carol.store.loadMessages(shared)) m.body,
    ];
    expect(carolBodies, contains('rule two'));
    expect(carolBodies, isNot(contains('after carol')));
  }

  test(
    'C7 full history: a newcomer reads earlier posts, a removed member '
    'gets nothing after its removal',
    () => run(full: true),
    skip: skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'C7 control: in a members-from-join channel a newcomer gets no earlier '
    'posts',
    () => run(full: false),
    skip: skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

class _Server {
  _Server(this.path, this.dataDir, this.port);

  final String path;
  final String dataDir;
  final String port;
  Process? _process;

  String get baseUrl => 'http://127.0.0.1:$port';

  Future<void> start() async {
    _process = await Process.start(
      path,
      <String>['serve', '--addr', '127.0.0.1:$port', '--data-dir', dataDir],
      environment: <String, String>{
        'PRIVATE_MESSENGER_ENV': 'development',
        'PRIVATE_MESSENGER_SETUP_TOKEN': 'c7-e2e-setup-token',
        'PRIVATE_MESSENGER_LOG_LEVEL': 'error',
        'PRIVATE_MESSENGER_C7_HISTORY': '1',
      },
    );
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
}

class _Client {
  _Client(this.bindings, this.baseUrl) : store = MemoryLocalStore() {
    final attachments = Directory.systemTemp.createTempSync(
      'veritra-c7-e2e-attachments-',
    );
    state = AppState(
      apiClientFactory: (url) =>
          ApiClient(baseUrl: url, transport: TransportPolicy.demo),
      cryptoService: NativeCryptoService(bindings: bindings, localStore: store),
      localStore: store,
      attachmentService: AttachmentCryptoService(
        bindings,
        directoryProvider: () async => attachments,
      ),
      syncServiceFactory: (url, token) =>
          WebSocketSyncService(baseUrl: url, token: token),
      config: const ClientConfig(
        demo: true,
        transport: TransportPolicy.demo,
        deviceName: 'C7 E2E test device',
      ),
    );
  }

  final NativeCryptoBindings bindings;
  final String baseUrl;
  final MemoryLocalStore store;
  late final AppState state;

  String get accountId => state.session!.accountId!;

  void expectOk() => expect(state.error, isNull, reason: state.error);

  Future<_Client> invite(String username) async {
    final invite = await state.createInvite();
    expectOk();
    final client = _Client(bindings, baseUrl);
    await client.state.registerWithInvite(
      baseUrl,
      invite!.code,
      username,
      '$username-password-123',
    );
    client.expectOk();
    return client;
  }

  /// [joiner] joins [communityId] through a link this account makes and
  /// approves, and waits until its device is in the shared group.
  Future<void> join(_Client joiner, String communityId, String shared) async {
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

  Future<void> waitUntil(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
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

  Future<int?> epoch(String conversationId) async =>
      (await (state.cryptoService as NativeCryptoService).groupEpoch(
        conversationId,
      ))
          ?.epoch;

  void dispose() {
    state.sync?.dispose();
    state.sync = null;
  }
}
