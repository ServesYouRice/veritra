import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/client_config.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/crypto/backup_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Real clients, real OpenMLS, real server: the demo's message flow end to
/// end, including offline use. Run through `scripts/test-demo-e2e.sh`, which
/// builds the server this test starts, stops and restarts.
void main() {
  final serverPath = Platform.environment['VERITRA_DEMO_E2E_SERVER'];
  final dataDir = Platform.environment['VERITRA_DEMO_E2E_DATA'];
  final port = Platform.environment['VERITRA_DEMO_E2E_PORT'] ?? '18082';
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = serverPath == null || dataDir == null || libraryPath == null
      ? 'run scripts/test-demo-e2e.sh'
      : false;

  test('demo clients exchange every message type and work offline', () async {
    final server = _Server(serverPath!, dataDir!, port);
    addTearDown(server.stop);
    await server.start();
    final baseUrl = server.baseUrl;
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final owner = _DemoClient(bindings, baseUrl);
    addTearDown(owner.dispose);
    await owner.state.createOwner(
        baseUrl, 'owner', 'owner-password-123', 'demo-e2e-setup-token');
    owner.expectOk();

    final alice = await owner.invite('alice');
    addTearDown(alice.dispose);

    // Direct message.
    final dm = await owner.state.startConversation(
      kind: 'dm',
      memberAccountIds: <String>[alice.accountId],
    );
    owner.expectOk();
    final conv = dm!.id;
    expect(await owner.state.sendMessageTo(conv, 'hello alice'), isTrue);
    final hello = await alice.waitFor(conv, (m) => m.body == 'hello alice');
    expect(hello.senderAccountId, owner.accountId);

    expect(await alice.state.replyTo(conv, hello.key, 'hi owner'), isTrue);
    final reply = await owner.waitFor(conv, (m) => m.body == 'hi owner');
    expect(reply.replyTo, hello.key);

    expect(
        await owner.state.editMessage(conv, hello.key, 'hello, alice'), isTrue);
    await alice.waitFor(
        conv, (m) => m.key == hello.key && m.body == 'hello, alice');

    expect(await alice.state.react(conv, hello.key, '👍'), isTrue);
    await owner.waitUntil(() async =>
        (await owner.store.loadReactions(conv)).any((r) => r.reaction == '👍'));

    expect(await owner.state.deleteMessage(conv, hello.key), isTrue);
    await alice.waitFor(conv, (m) => m.key == hello.key && m.deletedAt != null);

    // A group of three.
    final bob = await owner.invite('bob');
    addTearDown(bob.dispose);
    final group = await owner.state.startConversation(
      kind: 'group',
      title: 'Demo group',
      memberAccountIds: <String>[alice.accountId, bob.accountId],
    );
    owner.expectOk();
    expect(await owner.state.sendMessageTo(group!.id, 'hello group'), isTrue);
    await alice.waitFor(group.id, (m) => m.body == 'hello group');
    await bob.waitFor(group.id, (m) => m.body == 'hello group');
    expect(await bob.state.sendMessageTo(group.id, 'bob here'), isTrue);
    await owner.waitFor(group.id, (m) => m.body == 'bob here');
    await alice.waitFor(group.id, (m) => m.body == 'bob here');

    // Membership after creation (card I51): Carol joins the group later and
    // reads what is sent from then on; Bob leaves and stops receiving.
    final carol = await owner.invite('carol');
    addTearDown(carol.dispose);
    await owner.state.addConversationMember(group.id, carol.accountId);
    owner.expectOk();
    await alice.waitUntil(() async => (await alice.epoch(group.id)) == 2,
        timeout: const Duration(seconds: 60));
    await carol.waitUntil(() async => (await carol.epoch(group.id)) == 2,
        timeout: const Duration(seconds: 60));
    expect(await alice.state.sendMessageTo(group.id, 'welcome carol'), isTrue);
    await carol.waitFor(group.id, (m) => m.body == 'welcome carol');
    await bob.waitFor(group.id, (m) => m.body == 'welcome carol');
    expect(await carol.state.sendMessageTo(group.id, 'thanks'), isTrue);
    await owner.waitFor(group.id, (m) => m.body == 'thanks');
    // Carol sees nothing from before she joined.
    expect((await carol.store.loadMessages(group.id)).map((m) => m.body),
        isNot(contains('hello group')));

    expect(await owner.state.removeConversationMember(group.id, bob.accountId),
        isTrue);
    await alice.waitUntil(() async => (await alice.epoch(group.id)) == 3,
        timeout: const Duration(seconds: 60));
    await carol.waitUntil(() async => (await carol.epoch(group.id)) == 3,
        timeout: const Duration(seconds: 60));
    expect(await alice.state.sendMessageTo(group.id, 'without bob'), isTrue);
    await carol.waitFor(group.id, (m) => m.body == 'without bob');
    await owner.waitFor(group.id, (m) => m.body == 'without bob');
    expect((await bob.store.loadMessages(group.id)).map((m) => m.body),
        isNot(contains('without bob')));

    // Restart: a new app instance on the same local data keeps history and
    // keeps decrypting.
    final restarted = await alice.restart();
    addTearDown(restarted.dispose);
    expect(
      (await restarted.store.loadMessages(conv)).map((m) => m.body),
      contains('hi owner'),
    );
    expect(await owner.state.sendMessageTo(conv, 'after restart'), isTrue);
    await restarted.waitFor(conv, (m) => m.body == 'after restart');

    // Offline (Stage 4): with the server down, an app that starts from
    // scratch still opens its chats and history, and queues what it sends.
    await server.stop();
    final offline = await restarted.restart();
    addTearDown(offline.dispose);
    expect(offline.state.session, isNotNull);
    expect(offline.state.conversations.map((c) => c.id), contains(conv));
    await offline.state.loadMessages(conv);
    final shown = offline.state
        .timelineFor(conv)
        .map((envelope) =>
            offline.state.historyFor(conv).forEnvelope(envelope)?.body)
        .toList();
    expect(shown, containsAll(<String>['hi owner', 'after restart']));
    expect(await offline.state.sendMessageTo(conv, 'sent offline'), isTrue);
    expect(offline.state.pendingFor(conv), hasLength(1));

    // Back online: the queued message goes out and arrives.
    await server.start();
    await owner.waitFor(conv, (m) => m.body == 'sent offline',
        timeout: const Duration(seconds: 90));
    await offline.waitUntil(() async => offline.state.pendingFor(conv).isEmpty,
        timeout: const Duration(seconds: 90));

    // Encrypted backup (card I45): the owner backs up, a fresh device
    // restores it and carries on with the owner's history and groups.
    final code = await owner.state.createBackup();
    owner.expectOk();
    expect(owner.state.errorFor(Ops.backup), isNull,
        reason: owner.state.errorFor(Ops.backup));
    expect(code, isNotNull);
    final ownerAccountId = owner.accountId;
    owner.dispose();
    await owner.state.logout();
    final replacement = _DemoClient(bindings, baseUrl);
    addTearDown(replacement.dispose);
    expect(await replacement.state.restoreFromBackup(code!), isTrue,
        reason: replacement.state.errorFor(Ops.restore));
    expect(replacement.state.session?.accountId, ownerAccountId);
    expect((await replacement.store.loadMessages(conv)).map((m) => m.body),
        contains('hi owner'));
    expect(await offline.state.sendMessageTo(conv, 'after restore'), isTrue);
    await replacement.waitFor(conv, (m) => m.body == 'after restore',
        timeout: const Duration(seconds: 60));
    // The code is used up.
    final again = _DemoClient(bindings, baseUrl);
    addTearDown(again.dispose);
    expect(await again.state.restoreFromBackup(code), isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 6)));
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
        'PRIVATE_MESSENGER_SETUP_TOKEN': 'demo-e2e-setup-token',
        'PRIVATE_MESSENGER_LOG_LEVEL': 'error',
      },
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
      fail('demo server did not become ready');
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

class _DemoClient {
  _DemoClient(this.bindings, this.baseUrl, {MemoryLocalStore? store})
      : store = store ?? MemoryLocalStore() {
    final backups = Directory.systemTemp.createTempSync('veritra-e2e-backup-');
    state = AppState(
      apiClientFactory: (url) => ApiClient(baseUrl: url),
      cryptoService:
          NativeCryptoService(bindings: bindings, localStore: this.store),
      localStore: this.store,
      backupService: BackupService(
        bindings: bindings,
        localStore: this.store,
        directoryProvider: () async => backups,
      ),
      syncServiceFactory: (url, token) =>
          WebSocketSyncService(baseUrl: url, token: token),
      config: const ClientConfig(
        demo: true,
        transport: TransportPolicy.demo,
        deviceName: 'E2E test device',
      ),
    );
  }

  final NativeCryptoBindings bindings;
  final String baseUrl;
  final MemoryLocalStore store;
  late final AppState state;

  String get accountId => state.session!.accountId!;

  void expectOk() => expect(state.error, isNull, reason: state.error);

  Future<_DemoClient> invite(String username) async {
    final invite = await state.createInvite();
    expectOk();
    final client = _DemoClient(bindings, baseUrl);
    await client.state.registerWithInvite(
        baseUrl, invite!.code, username, '$username-password-123');
    client.expectOk();
    return client;
  }

  Future<_DemoClient> restart() async {
    dispose();
    final client = _DemoClient(bindings, baseUrl, store: store);
    await client.state.tryRestoreSession();
    client.expectOk();
    return client;
  }

  Future<void> waitUntil(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (state.deviceRecoveryRequired) {
        fail('sync stopped: ${state.error}');
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for sync');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<LocalMessage> waitFor(
    String conversationId,
    bool Function(LocalMessage message) matches, {
    Duration timeout = const Duration(seconds: 30),
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
      (await (state.cryptoService as NativeCryptoService)
              .groupEpoch(conversationId))
          ?.epoch;

  void dispose() {
    state.sync?.dispose();
    state.sync = null;
  }
}
