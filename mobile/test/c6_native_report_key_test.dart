import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/report_key_announcement.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'l1_test_lists.dart';
import 'native_test_env.dart';

// C6 moderator keys over MLS, against real OpenMLS devices: a `report_key`
// goes out hidden and unfranked, and a receiver keeps the key under the
// MLS-authenticated sender only in a group whose MLS state holds a C4
// record. A request is kept only when it names the receiver.

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

int _serverIds = 0;
final _key = base64Encode(List<int>.generate(32, (i) => i + 1));

void main() {
  final skip = nativeCryptoSkip();

  Future<(_Client, _Client)> pair(String conversation, String? kind) async {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    addTearDown(alice.service.dispose);
    addTearDown(bob.service.dispose);
    // A plain group carries a C4 record from its genesis; a DM none.
    alice.service.conversationAuthority = _Kinds(kind);
    bob.service.conversationAuthority = _Kinds(kind);
    await _start(alice, bob, conversation);
    return (alice, bob);
  }

  test('a report key is kept under its MLS sender in a record group', () async {
    final (alice, bob) = await pair('conv_g', 'group');
    expect(bob.service.governanceOf('conv_g'), isNotNull);

    final sent = await alice.service.encryptPayload(
        'conv_g', AppPayloadType.reportKey, <String, Object?>{'key': _key});
    // Never franked: an announcement is never reportable.
    expect(sent.frankCommit, isNull);
    await bob.service.processApplicationMessage(
        bob.envelopeFrom(alice, sent), bob.nextEvent());
    expect(
        await bob.store
            .loadSetting(reportKeyAnnouncementSetting('conv_g', 'acct_alice')),
        _key);
    final row = (await bob.store.loadMessages('conv_g')).single;
    expect(row.kind, 'action');
    expect(row.senderHidden, isTrue);
    expect(row.body, isNull);
    expect(await bob.store.loadFrankReveal(row.key), isNull);

    // An announcement never expires.
    await expectLater(
        alice.service.encryptExpiringPayload(
            'conv_g', AppPayloadType.reportKey, <String, Object?>{'key': _key},
            expiresAt: DateTime.now().add(const Duration(hours: 1))),
        throwsArgumentError);

    // A request naming Bob is kept with its sync event; one naming only
    // someone else is not.
    final other = await alice.service.encryptPayload(
        'conv_g', AppPayloadType.reportKeyRequest, <String, Object?>{
      'accounts': ['acct_carol']
    });
    await bob.service.processApplicationMessage(
        bob.envelopeFrom(alice, other), bob.nextEvent());
    expect(
        await bob.store.loadSetting(reportKeyRequestSetting('conv_g')), isNull);
    final asked = await alice.service.encryptPayload(
        'conv_g', AppPayloadType.reportKeyRequest, <String, Object?>{
      'accounts': ['acct_carol', 'acct_bob']
    });
    final event = bob.nextEvent();
    await bob.service
        .processApplicationMessage(bob.envelopeFrom(alice, asked), event);
    expect(await bob.store.loadSetting(reportKeyRequestSetting('conv_g')),
        '$event');
  }, skip: skip);

  test('a group without a C4 record keeps no report key', () async {
    final (alice, bob) = await pair('conv_dm', null);
    expect(bob.service.governanceOf('conv_dm'), isNull);
    final sent = await alice.service.encryptPayload(
        'conv_dm', AppPayloadType.reportKey, <String, Object?>{'key': _key});
    await bob.service.processApplicationMessage(
        bob.envelopeFrom(alice, sent), bob.nextEvent());
    expect(
        await bob.store
            .loadSetting(reportKeyAnnouncementSetting('conv_dm', 'acct_alice')),
        isNull);
    expect(
        (await bob.store.loadMessages('conv_dm')).single.senderHidden, isTrue);
  }, skip: skip);
}

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
