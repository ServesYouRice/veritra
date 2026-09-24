import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/client_config.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Real clients, real OpenMLS, real server: the demo's message flow end to
/// end. Run through `scripts/test-demo-e2e.sh`, which starts the server.
void main() {
  final baseUrl = Platform.environment['VERITRA_DEMO_E2E_BASE_URL'];
  final libraryPath = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final skip = baseUrl == null || libraryPath == null
      ? 'run scripts/test-demo-e2e.sh'
      : false;

  test('two and three demo clients exchange every message type', () async {
    final bindings = NativeCryptoBindings.open(libraryPath!);
    final owner = _DemoClient(bindings, baseUrl!);
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

    expect(await owner.state.editMessage(conv, hello.key, 'hello, alice'),
        isTrue);
    await alice.waitFor(
        conv, (m) => m.key == hello.key && m.body == 'hello, alice');

    expect(await alice.state.react(conv, hello.key, '👍'), isTrue);
    await owner.waitUntil(() async =>
        (await owner.store.loadReactions(conv)).any((r) => r.reaction == '👍'));

    expect(await owner.state.deleteMessage(conv, hello.key), isTrue);
    await alice.waitFor(
        conv, (m) => m.key == hello.key && m.deletedAt != null);

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
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}

class _DemoClient {
  _DemoClient(this.bindings, this.baseUrl, {MemoryLocalStore? store})
      : store = store ?? MemoryLocalStore() {
    state = AppState(
      apiClientFactory: (url) => ApiClient(baseUrl: url),
      cryptoService:
          NativeCryptoService(bindings: bindings, localStore: this.store),
      localStore: this.store,
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

  Future<void> waitUntil(Future<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
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
    bool Function(LocalMessage message) matches,
  ) async {
    LocalMessage? found;
    await waitUntil(() async {
      found = (await store.loadMessages(conversationId))
          .where(matches)
          .firstOrNull;
      return found != null;
    });
    return found!;
  }

  void dispose() {
    state.sync?.dispose();
    state.sync = null;
  }
}
