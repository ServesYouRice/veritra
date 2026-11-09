import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/community_info_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';
import 'l1_test_lists.dart';

// C3 send and receive against real OpenMLS devices: an info payload goes out
// unfranked and hidden, the sender keeps its own copy (MLS never decrypts a
// device's own message), and a receiver keeps it only in a community
// conversation.

class _Kinds implements ConversationAuthority {
  _Kinds(this.kind);
  String? kind;
  @override
  String? conversationKind(String conversationId) => kind;
  @override
  String? conversationChannel(String conversationId) => null;
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? roleOf(String conversationId, String accountId) => null;
}

final _channel = 'chan_${'2' * 32}';
final _key = List<int>.generate(32, (i) => i + 1);

void main() {
  final skip = nativeCryptoSkip();

  test('info announcements and requests survive the native MLS send path',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _start(alice, bob, 'conv_info');
    bob.service.conversationAuthority = _Kinds('community_channel');

    for (final (type, kind, body) in [
      (
        AppPayloadType.infoUpdate,
        CommunityInfoEventKind.update,
        infoUpdateBody(
            subjectKind: 'channel',
            subjectId: _channel,
            revision: 7,
            keyId: 'a' * 32,
            recordSha256: 'b' * 64),
      ),
      (
        AppPayloadType.infoKeyRequest,
        CommunityInfoEventKind.keyRequest,
        infoKeyRequestBody(subjectKind: 'channel', subjectId: _channel),
      ),
    ]) {
      final sent = await alice.service.encryptPayload('conv_info', type, body);
      expect(sent.frankCommit, isNull);
      await bob.service.processApplicationMessage(
          bob.envelopeFrom(alice, sent), bob.nextEvent());
      for (final client in [alice, bob]) {
        final event = (await client.store
                .loadCommunityInfoEvents(kind, 'channel', _channel))
            .single;
        expect(event.conversationId, 'conv_info');
        expect(event.senderAccountId, 'acct_alice');
        if (kind == CommunityInfoEventKind.update) {
          expect(event.revision, 7);
          expect(event.recordSha256, 'b' * 64);
        }
      }
    }
    final rows = await bob.store.loadMessages('conv_info');
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row.kind, 'action');
      expect(row.senderHidden, isTrue);
      expect(row.body, isNull);
      expect(await bob.store.loadFrankReveal(row.key), isNull);
    }
  }, skip: skip);

  test('an info key goes out unfranked and hidden, and both sides keep it',
      () async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _start(alice, bob, 'conv_p');
    final kinds = _Kinds('community_channel');
    bob.service.conversationAuthority = kinds;

    final body =
        infoKeyBody(subjectKind: 'channel', subjectId: _channel, key: _key);
    final sent = await alice.service
        .encryptPayload('conv_p', AppPayloadType.infoKey, body);
    // Never franked: a report could otherwise hand the key to its reader.
    expect(sent.frankCommit, isNull);
    // The sender's own copy: a hidden action row and the key itself.
    final own = await alice.store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, 'channel', _channel);
    expect(own.single.key, _key);
    expect(own.single.conversationId, 'conv_p');
    expect(own.single.senderAccountId, 'acct_alice');
    final row = (await alice.store.loadMessages('conv_p')).single;
    expect(row.kind, 'action');
    expect(row.senderHidden, isTrue);
    expect(row.body, isNull);
    // An info payload never carries an expiry.
    await expectLater(
        alice.service.encryptExpiringPayload(
            'conv_p', AppPayloadType.infoKey, body,
            expiresAt: DateTime.now().add(const Duration(hours: 1))),
        throwsArgumentError);

    // Bob, in a community conversation, keeps it with no reveal.
    await alice.store.removePendingEnvelope(sent.idempotencyKey);
    await bob.service.processApplicationMessage(
        bob.envelopeFrom(alice, sent), bob.nextEvent());
    final got = await bob.store.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, 'channel', _channel);
    expect(got.single.key, _key);
    expect(got.single.senderAccountId, 'acct_alice');
    final bobRow = (await bob.store.loadMessages('conv_p')).single;
    expect(bobRow.kind, 'action');
    expect(await bob.store.loadFrankReveal(bobRow.key), isNull);

    // The same payload in a conversation that is not a community's is
    // consumed and kept nowhere.
    kinds.kind = 'group';
    final again = await alice.service.encryptPayload(
        'conv_p',
        AppPayloadType.infoKey,
        infoKeyBody(
            subjectKind: 'channel',
            subjectId: _channel,
            key: List<int>.filled(32, 9)));
    await bob.service.processApplicationMessage(
        bob.envelopeFrom(alice, again), bob.nextEvent());
    expect(
        await bob.store.loadCommunityInfoEvents(
            CommunityInfoEventKind.key, 'channel', _channel),
        hasLength(1));
  }, skip: skip);
}

int _serverIds = 0;

Session _session(String accountId, String deviceId) => Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    );

Future<void> _start(_Client alice, _Client bob, String conversationId) async {
  await alice.service.initializeConversation(
      conversationId, <DeviceKeyPackage>[await bob.keyPackage()]);
  final item = (await alice.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await alice.service.completeCommitBundle(item);
  await bob.service.processMlsMessage(MlsMessage(
    id: 'mls_${++_serverIds}',
    conversationId: conversationId,
    senderAccountId: alice.accountId,
    senderDeviceId: alice.deviceId,
    kind: 'welcome',
    payload: bundle.welcome,
    idempotencyKey: '${item.idempotencyKey}:welcome:${bob.deviceId}',
    syncEventId: bob.nextEvent(),
    createdAt: DateTime.now().toUtc(),
    recipientDeviceId: bob.deviceId,
  ));
}

class _Client {
  _Client(this.service, this.store, this.accountId, this.deviceId, this.events);

  final NativeCryptoService service;
  final MemoryLocalStore store;
  final String accountId;
  final String deviceId;
  int events;

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
    return _Client(service, local, accountId, deviceId, 0);
  }

  /// A new service over the same store, as after an app restart.
  Future<_Client> restart(NativeCryptoBindings bindings) async {
    await service.dispose();
    final next = TestNativeCryptoService(bindings: bindings, localStore: store);
    await next.activateSession(_session(accountId, deviceId));
    return _Client(next, store, accountId, deviceId, events);
  }

  int nextEvent() => ++events;

  Future<int> epoch(String conversationId) async =>
      (await service.groupEpoch(conversationId))!.epoch;

  /// Stages a self-update commit and merges it, as after the server accepts
  /// it. Returns the accepted outbox item, so its commit can be delivered.
  Future<PendingMlsMessage> selfUpdate(String conversationId) async {
    await service.stageSelfUpdate(conversationId);
    final item = (await store.pendingMlsMessages())
        .singleWhere((pending) => pending.conversationId == conversationId);
    await service.completeCommitBundle(item);
    return item;
  }

  /// The sync event that delivers [payload], a copy of [item]'s commit, from
  /// [from] to this device.
  MlsMessage commitFrom(
      _Client from, PendingMlsMessage item, int eventId, List<int> payload) {
    return MlsMessage(
      id: 'mls_${item.conversationId}',
      conversationId: item.conversationId,
      senderAccountId: from.accountId,
      senderDeviceId: from.deviceId,
      kind: 'commit',
      payload: payload,
      idempotencyKey: item.idempotencyKey,
      syncEventId: eventId,
      createdAt: DateTime.now().toUtc(),
    );
  }

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<MessageEnvelope> send(String conversationId, String text) async {
    final envelope = await service.encryptPayload(
        conversationId, AppPayloadType.text, <String, Object?>{'text': text});
    await store.removePendingEnvelope(envelope.idempotencyKey);
    return envelope;
  }

  ReceivedMessageEnvelope envelopeFrom(_Client from, MessageEnvelope sent) =>
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        frankCommit: sent.frankCommit,
        createdAt: DateTime.now().toUtc(),
      );
}
