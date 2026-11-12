import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/report_models.dart';
import 'package:private_messenger/core/report_seed_store.dart';
import 'package:private_messenger/core/reports_service.dart';
import 'package:private_messenger/crypto/report_body.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/franking.dart';
import 'package:private_messenger/crypto/mls_commit_bundle.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

import 'native_test_env.dart';
import 'l1_test_lists.dart';

/// L2-3 app step on the real core: messages chosen to go sealed are signed,
/// opened with the sender MLS names, recognised when they come back to the
/// sending device, and refused when sealed and identified forms are mixed.
void main() {
  // Skipped without the library, unless VERITRA_REQUIRE_NATIVE_CRYPTO=1.
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  setUp(
      () => bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary()));

  test('a sealed message reaches the other member with the MLS sender',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());

    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'quiet'});
    expect(sent.sealed, isTrue);
    expect(bob.tokens.taken, 1);
    // The post body names no device or account.
    final post = sent.toSealedPostJson();
    expect(post.keys.toSet(), <String>{
      'conversation_id',
      'token',
      'idempotency_key',
      'ciphertext',
      'crypto_protocol',
      'crypto_metadata',
      'frank_commit',
    });
    expect(jsonEncode(post), isNot(contains('dev_bob')));
    expect(jsonEncode(post), isNot(contains('acct_bob')));
    // The local outbox copy keeps the token; the session route refuses it.
    expect(MessageEnvelope.fromJson(sent.toJson()).sealed, isTrue);

    final event = alice.nextEvent();
    final opened = await alice.service
        .processSealedApplicationMessage(alice.sealedFrom(sent), event);
    expect(opened.senderAccountId, 'acct_bob');
    expect(opened.senderDeviceId, 'dev_bob');
    expect(await alice.store.loadSyncCursor(), event);
    final row = (await alice.history()).single;
    expect(row.body, 'quiet');
    expect(row.senderAccountId, 'acct_bob');
    expect(row.senderDeviceId, 'dev_bob');
    expect(row.kind, isNot(LocalMessageKind.invalid));

    // C6: the reveal keeps s, the leaf key it verified under and the sender
    // account, so the message can still be reported.
    final reveal = (await alice.store.loadFrankReveal(row.key))!;
    expect(reveal.sealed, isTrue);
    expect(reveal.senderAccountId, 'acct_bob');
    expect(reveal.signingKey, await bob.service.currentSigningKey());
    expect(
        bindings.l2FrankVerify(
          signingKey: reveal.signingKey!,
          conversationId: 'conv_1',
          accountId: 'acct_bob',
          deviceId: 'dev_bob',
          commit: sent.frankCommit!,
          signature: reveal.signature!,
        ),
        isTrue);
  }, skip: skip);

  test('with no token the message goes identified, and stays so', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);

    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'plain'});
    expect(sent.sealed, isFalse);
    expect(bob.tokens.asked, 1);
    await alice.receive(bob, sent);
    final row = (await alice.history()).single;
    expect(row.body, 'plain');
    final reveal = (await alice.store.loadFrankReveal(row.key))!;
    expect(reveal.sealed, isFalse);
  }, skip: skip);

  test('a community or unknown conversation kind sends identified', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    bob.authority.kind = 'announcement';
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'x'});
    expect(sent.sealed, isFalse);
    expect(bob.tokens.asked, 0);
  }, skip: skip);

  test('the sending device recognises its own sealed post by its key',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'mine'});
    final envelope = bob.sealedFrom(sent);
    final event = bob.nextEvent();
    final opened =
        await bob.service.processSealedApplicationMessage(envelope, event);
    expect(opened.senderDeviceId, 'dev_bob');
    expect(opened.senderAccountId, 'acct_bob');
    expect(await bob.store.loadSyncCursor(), event);
    final row = (await bob.history()).single;
    expect(row.body, 'mine');
    expect(row.serverMessageId, envelope.id);
    expect(row.kind, isNot(LocalMessageKind.invalid));
    // The choice stays with the message after its echo: the cached
    // envelope (what read receipts and the timeline read) is marked sealed,
    // under the server id, with the sender MLS named.
    final cached = (await bob.store.loadSnapshot())!
        .messagesByConversation[envelope.conversationId]!
        .where((item) => item.id == envelope.id)
        .single;
    expect(cached.sealed, isTrue);
    expect(cached.senderDeviceId, 'dev_bob');
    final reread = ReceivedMessageEnvelope.fromJson(cached.toJson());
    expect(reread.sealed, isTrue);
  }, skip: skip);

  test('an own sealed post the device no longer holds becomes a placeholder',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'gone'});
    // A server replaying the post under a key this device never used: MLS
    // cannot open a message for its own sender, and sync moves on.
    final replayed = ReceivedMessageEnvelope(
      id: 'srv_${++_serverIds}',
      conversationId: 'conv_1',
      senderAccountId: '',
      senderDeviceId: '',
      idempotencyKey: 'another-key-aaaaaaaaaaaaaaaaaaaaaa',
      ciphertext: sent.ciphertext,
      cryptoProtocol: sent.cryptoProtocol,
      createdAt: DateTime.now().toUtc(),
      frankCommit: sent.frankCommit,
      sealed: true,
    );
    final event = bob.nextEvent();
    final opened =
        await bob.service.processSealedApplicationMessage(replayed, event);
    expect(opened.senderDeviceId, isEmpty);
    expect(await bob.store.loadSyncCursor(), event);
    final placeholder = (await bob.history())
        .firstWhere((row) => row.key.startsWith('undecryptable:'));
    expect(placeholder.kind, LocalMessageKind.invalid);
    expect(placeholder.senderAccountId, isEmpty);
  }, skip: skip);

  test('a payload signed for sealed is invalid when it comes identified',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'mixed'});
    expect(sent.sealed, isTrue);
    await alice.receive(bob, sent);
    final row = (await alice.history()).single;
    expect(row.kind, LocalMessageKind.invalid);
    expect(row.body, isNull);
    expect(await alice.store.loadFrankReveal(row.key), isNull);
  }, skip: skip);

  test('a franked payload without s is invalid when it comes sealed', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    final sent = await bob
        .send(AppPayloadType.text, <String, Object?>{'text': 'unsigned'});
    expect(sent.sealed, isFalse);
    final opened = await alice.service.processSealedApplicationMessage(
        alice.sealedFrom(sent), alice.nextEvent());
    expect(opened.senderAccountId, 'acct_bob');
    final row = (await alice.history()).single;
    expect(row.kind, LocalMessageKind.invalid);
    expect(row.body, isNull);
  }, skip: skip);

  test('the sealed and identified paths refuse each other', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    final sent =
        await bob.send(AppPayloadType.text, <String, Object?>{'text': 'y'});
    final cursor = await alice.store.loadSyncCursor();
    await expectLater(
        alice.service.processApplicationMessage(
            alice.sealedFrom(sent), alice.nextEvent()),
        throwsFormatException);
    await expectLater(
        alice.service.processSealedApplicationMessage(
            alice.envelopeFrom(bob, sent), alice.nextEvent()),
        throwsFormatException);
    expect(await alice.store.loadSyncCursor(), cursor);
    expect(await alice.history(), isEmpty);
  }, skip: skip);

  test('a token taken for a send that fails goes back', () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    await expectLater(
        bob.service.encryptPayload(
            'conv_1', AppPayloadType.text, <String, Object?>{'text': 7}),
        throwsA(anything));
    expect(bob.tokens.held, 1);
    expect(bob.tokens.taken, 1);
  }, skip: skip);

  test('a sealed message is reported and verified by its signature and key',
      () async {
    final alice = await _Client.enroll(bindings, 'acct_alice', 'dev_alice');
    final bob = await _Client.enroll(bindings, 'acct_bob', 'dev_bob');
    await _startConversation(alice, bob);
    bob.tokens.add(_token());
    final sent = await bob
        .send(AppPayloadType.text, <String, Object?>{'text': 'reportable'});
    final envelope = alice.sealedFrom(sent);
    await alice.service
        .processSealedApplicationMessage(envelope, alice.nextEvent());
    final row = (await alice.history()).single;
    final reveal = (await alice.store.loadFrankReveal(row.key))!;

    // The reporter's body is version 2 and survives the seal round trip.
    final body = ReportBody.decode(ReportBody.fromReveal(reveal).encode());
    expect(body.sealed, isTrue);
    expect(body.senderAccountId, 'acct_bob');
    expect(jsonDecode(utf8.decode(body.encode()))['v'], 2);

    final bobKey = await bob.service.currentSigningKey();
    final server = _ReportServer(ReportEnvelopeRecord.fromJson({
      'envelope_id': envelope.id,
      'conversation_id': 'conv_1',
      'frank_commit': base64Encode(sent.frankCommit!),
      'sealed': true,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }));
    Future<ReportVerification> verifyAs(ReportBody reported,
        Future<bool> Function(String, String, List<int>)? listed) async {
      final owner = ReportsService(
        api: server,
        token: 'acct_owner',
        accountId: 'acct_owner',
        crypto: alice.service,
        store: MemoryLocalStore(),
        seeds: MemoryReportSeedStore(),
        senderKeyListed: listed,
      );
      return owner.verify(OpenedReport(_row(), body: reported));
    }

    Future<bool> bobsList(String account, String device, List<int> key) async =>
        account == 'acct_bob' && device == 'dev_bob' && _sameBytes(key, bobKey);

    final verified = await verifyAs(body, bobsList);
    expect(verified.verdict, ReportVerdict.verified);
    expect(verified.record!.senderAccountId, 'acct_bob');
    expect(verified.record!.senderDeviceId, 'dev_bob');

    // No device-list check wired: never attributed (fails closed).
    expect(
        (await verifyAs(body, null)).verdict, ReportVerdict.senderUnverified);
    // The key is not on the claimed account's list.
    expect((await verifyAs(body, (a, d, k) async => false)).verdict,
        ReportVerdict.senderUnverified);

    // Framing: the reporter names another account. The signature covers
    // the account, so it no longer verifies.
    final framed = ReportBody(
      envelopeId: body.envelopeId,
      conversationId: body.conversationId,
      senderDeviceId: body.senderDeviceId,
      actionId: body.actionId,
      payload: body.payload,
      frankKey: body.frankKey,
      senderAccountId: 'acct_carol',
      signature: body.signature,
      signingKey: body.signingKey,
    );
    expect((await verifyAs(framed, (a, d, k) async => true)).verdict,
        ReportVerdict.mismatch);
    // Another key with the same signature fails too.
    final otherKey = ReportBody(
      envelopeId: body.envelopeId,
      conversationId: body.conversationId,
      senderDeviceId: body.senderDeviceId,
      actionId: body.actionId,
      payload: body.payload,
      frankKey: body.frankKey,
      senderAccountId: body.senderAccountId,
      signature: body.signature,
      signingKey: await alice.service.currentSigningKey(),
    );
    expect((await verifyAs(otherKey, (a, d, k) async => true)).verdict,
        ReportVerdict.mismatch);
    // A version-1 body about a sealed record cannot be attributed.
    final plain = ReportBody(
      envelopeId: body.envelopeId,
      conversationId: body.conversationId,
      senderDeviceId: body.senderDeviceId,
      actionId: body.actionId,
      payload: body.payload,
      frankKey: body.frankKey,
    );
    expect((await verifyAs(plain, (a, d, k) async => true)).verdict,
        ReportVerdict.mismatch);
  }, skip: skip);

  test('the frank member reads in exactly one spelling of each form', () {
    final canonical = Uint8List.fromList(utf8.encode('{"t":"x"}'));
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final signature =
        Uint8List.fromList(List<int>.generate(64, (i) => 255 - i));
    final sealed = frankWireJson(canonical, key, signature: signature);
    final plain = frankWireJson(canonical, key);
    final readSealed = splitFrank(sealed) as Franked;
    expect(readSealed.signature, signature);
    expect(readSealed.key, key);
    expect(readSealed.canonical, canonical);
    final readPlain = splitFrank(plain) as Franked;
    expect(readPlain.signature, isNull);
    // A non-canonical signature spelling is refused.
    final text = utf8.decode(sealed);
    final bent = text.replaceFirst('","s":"', '","s" :"');
    expect(splitFrank(Uint8List.fromList(utf8.encode(bent))),
        isA<MalformedFrank>());
    expect(() => frankWireJson(canonical, key, signature: Uint8List(63)),
        throwsFormatException);
  });
}

int _serverIds = 0;

SealedToken _token() => SealedToken(
      conversationId: 'conv_1',
      keyId: 'k' * 32,
      epoch: 20000,
      generation: 0,
      nonce: List<int>.generate(32, (i) => i + _serverIds++ % 7),
      output: List<int>.filled(64, 9),
    );

class _Tokens implements SealedTokenSource {
  final List<SealedToken> _held = <SealedToken>[];
  int asked = 0;
  int taken = 0;
  int get held => _held.length;

  void add(SealedToken token) => _held.add(token);

  @override
  Future<SealedToken?> takeFor(String conversationId) async {
    asked++;
    if (_held.isEmpty) return null;
    taken++;
    return _held.removeAt(0);
  }

  @override
  Future<void> putBack(SealedToken token) async => _held.add(token);
}

class _Authority implements ConversationAuthority {
  String kind = 'dm';
  @override
  String? conversationKind(String conversationId) => kind;
  @override
  String? conversationChannel(String conversationId) => null;
  @override
  Set<String> memberAccounts(String conversationId) =>
      const <String>{'acct_alice', 'acct_bob'};
  @override
  String? roleOf(String conversationId, String accountId) => 'member';
}

Future<void> _startConversation(_Client alice, _Client bob) async {
  await alice.service.initializeConversation(
      'conv_1', <DeviceKeyPackage>[await bob.keyPackage()]);
  final item = (await alice.store.pendingMlsMessages()).single;
  final bundle = MlsCommitBundle.decode(item.payload);
  await alice.service.completeCommitBundle(item);
  await bob.service.processMlsMessage(MlsMessage(
    id: 'mls_${++_serverIds}',
    conversationId: 'conv_1',
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
  final _Tokens tokens = _Tokens();
  final _Authority authority = _Authority();
  int _events = 0;

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
    await service.activateSession(Session(
      baseUrl: 'https://localhost:8443',
      token: 'token',
      accountId: accountId,
      deviceId: deviceId,
    ));
    final client = _Client(service, local, accountId, deviceId);
    service.conversationAuthority = client.authority;
    service.sealedTokenSource = client.tokens;
    return client;
  }

  int nextEvent() => ++_events;

  Future<DeviceKeyPackage> keyPackage() async => DeviceKeyPackage(
        id: 'kp_$deviceId${++_serverIds}',
        deviceId: deviceId,
        accountId: accountId,
        keyPackage:
            (await service.createReplenishmentKeyPackages(count: 1)).single,
        ciphersuite: 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

  Future<List<LocalMessage>> history() => store.loadMessages('conv_1');

  /// Encrypts; the outbox entry stays (as until the post is answered), so
  /// the device can recognise its own sealed post.
  Future<MessageEnvelope> send(
          AppPayloadType type, Map<String, Object?> body) =>
      service.encryptPayload('conv_1', type, body);

  ReceivedMessageEnvelope envelopeFrom(_Client from, MessageEnvelope sent) =>
      ReceivedMessageEnvelope(
        id: 'srv_${++_serverIds}',
        conversationId: sent.conversationId,
        senderAccountId: from.accountId,
        senderDeviceId: from.deviceId,
        idempotencyKey: sent.idempotencyKey,
        ciphertext: sent.ciphertext,
        cryptoProtocol: sent.cryptoProtocol,
        createdAt: DateTime.now().toUtc(),
        frankCommit: sent.frankCommit,
      );

  /// What `message.sealed.created` carries: no sender at all.
  ReceivedMessageEnvelope sealedFrom(MessageEnvelope sent) =>
      ReceivedMessageEnvelope.fromJson(<String, Object?>{
        'id': 'sealed_${++_serverIds}',
        'conversation_id': sent.conversationId,
        'idempotency_key': sent.idempotencyKey,
        'ciphertext': base64Encode(sent.ciphertext),
        'crypto_protocol': sent.cryptoProtocol,
        'crypto_metadata': sent.cryptoMetadata,
        if (sent.frankCommit != null)
          'frank_commit': base64Encode(sent.frankCommit!),
        'sealed': true,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

  Future<List<int>?> receive(_Client from, MessageEnvelope sent) =>
      service.processApplicationMessage(envelopeFrom(from, sent), nextEvent());
}

bool _sameBytes(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

ReportCopyRow _row() => ReportCopyRow(
      id: 'row_1',
      reportId: 'report_1',
      inboxKind: 'instance_owner',
      inboxId: 'acct_owner',
      keyRev: 1,
      recipientPublicKey: List<int>.filled(32, 1),
      conversationId: 'conv_1',
      reporterAccountId: 'acct_alice',
      sealed: const <int>[1],
      createdAt: DateTime.utc(2026, 11, 12),
    );

class _ReportServer extends ApiClient {
  _ReportServer(this.record) : super(baseUrl: 'https://chat.example.org');

  final ReportEnvelopeRecord record;

  @override
  Future<ReportEnvelopeRecord> getReportEnvelope(
      String token, String reportRowId, String envelopeId) async {
    if (envelopeId != record.envelopeId) {
      throw ApiException(404, '{"error":"not_found"}');
    }
    return record;
  }
}
