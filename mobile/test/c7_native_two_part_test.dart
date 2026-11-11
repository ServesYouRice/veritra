import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/c7_two_part.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart'
    show LocalMessage;
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

// C7 step 4 (docs/designs/C7-channel-history.md, "Core idea"): the two-part
// send and receive through real OpenMLS devices and NativeCryptoService.
// MLS carries a 68-byte reference; the padded VAP1 travels as the sealed
// body beside the envelope. A missing, damaged or swapped body is an invalid
// row, and the MLS state and cursor still commit, so the next message opens.

final _community = 'comm_${'1' * 32}';
final _channel = 'chan_${'3' * 32}';
const _conversation = 'conv_private_c7';

/// A private channel's own group in the C0 layout.
class _PrivateGroup
    implements ConversationAuthority, ConversationCommunitySource {
  @override
  String? conversationKind(String conversationId) => 'community_channel';
  @override
  String? conversationChannel(String conversationId) => _channel;
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? roleOf(String conversationId, String accountId) => null;
  @override
  String? conversationCommunity(String conversationId) => _community;
  @override
  String? privateGroupChannel(String conversationId) =>
      conversationId == _conversation ? _channel : null;
}

int _serverIds = 0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = nativeCryptoSkip();

  Future<(_Client, _Client)> start() async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    addTearDown(alice.service.dispose);
    addTearDown(bob.service.dispose);
    for (final client in [alice, bob]) {
      client.service.conversationAuthority = _PrivateGroup();
      client.service.c7SealedBodies = true;
    }
    await alice.service.initializeConversation(
        _conversation, <DeviceKeyPackage>[await bob.keyPackage()]);
    final item = (await alice.store.pendingMlsMessages()).single;
    final bundle = MlsCommitBundle.decode(item.payload);
    await alice.service.completeCommitBundle(item);
    await bob.service.processMlsMessage(MlsMessage(
      id: 'mls_${++_serverIds}',
      conversationId: _conversation,
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      kind: 'welcome',
      payload: bundle.welcome,
      idempotencyKey: '${item.idempotencyKey}:welcome:${bob.deviceId}',
      syncEventId: bob.nextEvent(),
      createdAt: DateTime.now().toUtc(),
      recipientDeviceId: bob.deviceId,
    ));
    return (alice, bob);
  }

  Future<List<LocalMessage>> rows(_Client client) =>
      client.store.loadMessages(_conversation);

  test('a post goes in two parts and opens on the other device', () async {
    final (alice, bob) = await start();
    final sent = await alice.send('hello');
    // MLS carries only the reference; the body is a channel-sized blob and
    // the private group names its own channel in the clear metadata.
    final body = sent.sealedBody!;
    expect((body.length - 124) % 256, 0);
    expect(body.length, greaterThan(124));
    expect((sent.cryptoMetadata as Map)['channel_id'], _channel);
    final opened = await bob.service.processApplicationMessage(
        bob.envelopeFrom(alice, sent), bob.nextEvent());
    expect(opened, isNotNull);
    final received = await rows(bob);
    expect(received.single.kind, 'text');
    expect(received.single.senderAccountId, 'acct_alice');
  }, skip: skip);

  test('a stripped or damaged body is an invalid row and sync goes on',
      () async {
    final (alice, bob) = await start();
    final stripped = await alice.send('one');
    final damaged = await alice.send('two');
    final fine = await alice.send('three');
    expect(
        await bob.service.processApplicationMessage(
            bob.envelopeFrom(alice, stripped, body: const <int>[]),
            bob.nextEvent()),
        isNull);
    final flipped = List<int>.of(damaged.sealedBody!)..[200] ^= 1;
    expect(
        await bob.service.processApplicationMessage(
            bob.envelopeFrom(alice, damaged, body: flipped), bob.nextEvent()),
        isNull);
    // The ratchet moved for both: the next message opens.
    expect(
        await bob.service.processApplicationMessage(
            bob.envelopeFrom(alice, fine), bob.nextEvent()),
        isNotNull);
    final kinds = (await rows(bob)).map((r) => r.kind).toList();
    expect(kinds.where((k) => k == 'invalid'), hasLength(2));
    expect(kinds.where((k) => k == 'text'), hasLength(1));
  }, skip: skip);

  test('a body swapped from another message never opens', () async {
    final (alice, bob) = await start();
    final first = await alice.send('first');
    final second = await alice.send('second');
    expect(
        await bob.service.processApplicationMessage(
            bob.envelopeFrom(alice, first, body: second.sealedBody),
            bob.nextEvent()),
        isNull);
    expect((await rows(bob)).single.kind, 'invalid');
  }, skip: skip);

  test('a post the server routes as group-level is an invalid row', () async {
    final (alice, bob) = await start();
    final sent = await alice.send('looks like a sync');
    // The server sees no channel keys and serves it as group-level, where
    // only history_sync and its request may be.
    final metadata = Map<String, Object?>.of(
        (sent.cryptoMetadata as Map).cast<String, Object?>())
      ..remove('channel_id');
    expect(
        await bob.service.processApplicationMessage(
            bob.envelopeFrom(alice, sent, metadata: metadata), bob.nextEvent()),
        isNull);
    expect((await rows(bob)).single.kind, 'invalid');
  }, skip: skip);

  test('a reference never parses as a VAP1, and C7 off sends one part',
      () async {
    final (alice, bob) = await start();
    alice.service.c7SealedBodies = false;
    final sent = await alice.send('plain');
    expect(sent.sealedBody, isNull);
    expect(parseC7Reference(sent.ciphertext), isNull);
    expect(
        await bob.service.processApplicationMessage(
            bob.envelopeFrom(alice, sent), bob.nextEvent()),
        isNotNull);
    expect((await rows(bob)).single.kind, 'text');
  }, skip: skip);
}

Session _session(String accountId, String deviceId) => Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    );

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int events = 0;

  static Future<_Client> enroll(
      NativeCryptoBindings bindings, String accountId, String deviceId) async {
    final local = MemoryLocalStore();
    final service =
        TestNativeCryptoService(bindings: bindings, localStore: local);
    await service.createEnrollmentCredential(EnrollmentReservation(
      id: 'res_$deviceId',
      accountId: accountId,
      deviceId: deviceId,
      challenge: const <int>[1, 2, 3],
    ));
    await service.activateSession(_session(accountId, deviceId));
    return _Client(service, local, accountId, deviceId);
  }

  int nextEvent() => ++events;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<MessageEnvelope> send(String text) async {
    final envelope = await service.encryptPayload(
        _conversation, AppPayloadType.text, <String, Object?>{'text': text});
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  /// What the server serves: the envelope with its sealed body (or [body]
  /// in its place) and its clear metadata (or [metadata]).
  ReceivedMessageEnvelope envelopeFrom(_Client from, MessageEnvelope sent,
          {List<int>? body, Map<String, Object?>? metadata}) =>
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        cryptoMetadata: metadata ?? sent.cryptoMetadata,
        frankCommit: sent.frankCommit,
        sealedBody: body ?? sent.sealedBody,
        createdAt: DateTime.now().toUtc(),
      );
}
