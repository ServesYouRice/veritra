import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';

const _conversation = 'conv_notice';
const _session = Session(
    baseUrl: 'https://example.test',
    token: 'test-token',
    accountId: 'acct_bob',
    deviceId: 'dev_bob');

class _Store extends MemoryLocalStore {
  final references = <LocalNoticeReference>[];
  void Function()? beforeNextMlsCommit;
  void Function()? beforeNextSyncCommit;
  Future<void> Function()? beforeNextLookup;

  @override
  Future<bool> hasProcessedMlsMessage(String messageId) async {
    final callback = beforeNextLookup;
    beforeNextLookup = null;
    await callback?.call();
    return super.hasProcessedMlsMessage(messageId);
  }

  @override
  Future<void> commitMlsTransition(MlsStateTransition transition) async {
    final callback = beforeNextMlsCommit;
    beforeNextMlsCommit = null;
    callback?.call();
    await super.commitMlsTransition(transition);
    references.addAll(transition.noticeReferences);
  }

  @override
  Future<void> commitSyncEvent(SyncEventCommit commit) async {
    final callback = beforeNextSyncCommit;
    beforeNextSyncCommit = null;
    callback?.call();
    await super.commitSyncEvent(commit);
  }
}

class _Pair {
  _Pair(this.bindings, this.alice, this.bob, this.store, this.senderAccount,
      this.welcome);
  final NativeCryptoBindings bindings;
  final NativeCryptoDevice alice;
  final NativeCryptoService bob;
  final _Store store;
  final String senderAccount;
  final MlsMessage welcome;
  int sequence = 0;

  static Future<_Pair> start(String library,
      {bool join = true, String senderAccount = 'acct_alice'}) async {
    final bindings = NativeCryptoBindings.open(library);
    final store = _Store();
    await store.saveSession(_session);
    final bob = NativeCryptoService(bindings: bindings, localStore: store);
    await bob.createEnrollmentCredential(const EnrollmentReservation(
        id: 'res_bob',
        accountId: 'acct_bob',
        deviceId: 'dev_bob',
        challenge: [1, 2, 3]));
    await bob.activateSession(_session);
    final alice = bindings.createDevice(senderAccount, 'dev_alice');
    alice.createGroup(_conversation);
    final staged = alice.stageCommit(_conversation, adds: [
      (
        keyPackage: (await bob.createReplenishmentKeyPackages(count: 1)).single,
        accountId: 'acct_bob',
        deviceId: 'dev_bob',
      )
    ]);
    alice.mergePendingCommit(_conversation);
    final welcome = MlsMessage(
        id: 'welcome_notice',
        conversationId: _conversation,
        senderAccountId: senderAccount,
        senderDeviceId: 'dev_alice',
        kind: 'welcome',
        payload: staged.welcome,
        idempotencyKey: 'welcome',
        syncEventId: 1,
        createdAt: DateTime.now().toUtc(),
        recipientDeviceId: 'dev_bob');
    final pair = _Pair(bindings, alice, bob, store, senderAccount, welcome);
    if (join) await bob.processMlsMessage(welcome);
    return pair;
  }

  ReceivedMessageEnvelope envelope(
      AppPayloadType type, Map<String, Object?> body,
      {String? senderAccount, DateTime? expiresAt}) {
    final action = 'action_${++sequence}';
    return encrypted(
        AppPayloadCodec().encode(
            type: type,
            conversationId: _conversation,
            senderDeviceId: 'dev_alice',
            actionId: action,
            body: body),
        action,
        senderAccount: senderAccount,
        expiresAt: expiresAt);
  }

  ReceivedMessageEnvelope encrypted(List<int> payload, String action,
          {String? senderAccount, DateTime? expiresAt}) =>
      ReceivedMessageEnvelope(
          id: 'server_$action',
          conversationId: _conversation,
          senderAccountId: senderAccount ?? this.senderAccount,
          senderDeviceId: 'dev_alice',
          idempotencyKey: action,
          ciphertext: alice.encrypt(_conversation, payload),
          cryptoProtocol: 'mls10-openmls-v1',
          createdAt: DateTime.now().toUtc(),
          expiresAt: expiresAt);

  Future<void> receive(ReceivedMessageEnvelope message) async {
    await bob.processApplicationMessage(
        message, (await store.loadSyncCursor()) + 1);
  }

  Future<void> close() async {
    alice.close();
    await bob.dispose();
  }
}

void main() {
  final configured = Platform.environment['VERITRA_CRYPTO_LIBRARY'];
  final inCi = Platform.environment['CI'] == 'true';
  final skip = configured == null && !inCi
      ? 'real native crypto library required'
      : false;
  String library() => configured ?? fail('CI must set VERITRA_CRYPTO_LIBRARY');

  test(
      'capture defaults off; enabled text/reply/attachment refs contain metadata only',
      () async {
    final pair = await _Pair.start(library());
    addTearDown(pair.close);
    expect(pair.bob.noticeCaptureEnabled, isFalse);
    await pair.receive(
        pair.envelope(AppPayloadType.text, {'text': 'legacy plaintext'}));
    expect(pair.store.references, isEmpty);
    pair.bob.noticeCaptureEnabled = true;
    final text =
        pair.envelope(AppPayloadType.text, {'text': 'private message body'});
    await pair.receive(text);
    await pair.receive(pair.envelope(AppPayloadType.reply, {
      'text': 'private reply',
      'reply_to_id': messageKey('dev_alice', text.idempotencyKey)
    }));
    await pair.receive(pair.envelope(AppPayloadType.attachmentManifest, {
      'attachments': [
        {
          'id': 'attachment_id',
          'file_name': 'secret-file-name.txt',
          'media_type': 'text/plain',
          'plaintext_size': 1,
          'ciphertext_size': 21,
          'conversation_id': _conversation
        },
      ]
    }));
    expect(pair.store.references, hasLength(3));
    final ref = pair.store.references.first;
    expect(
        ref.owner,
        const LocalNoticeOwner(
            origin: 'https://example.test',
            accountId: 'acct_bob',
            deviceId: 'dev_bob'));
    expect(ref.eventId, 3);
    expect(ref.messageKey, messageKey('dev_alice', text.idempotencyKey));
    expect(ref.serverMessageId, text.id);
    expect(ref.conversationId, _conversation);
    expect(ref.senderAccountId, 'acct_alice');
    expect(ref.senderDeviceId, 'dev_alice');
    expect(ref.createdAt, text.createdAt.millisecondsSinceEpoch);
    final encoded =
        jsonEncode(pair.store.references.map((r) => r.toJson()).toList());
    for (final private in [
      'private message body',
      'private reply',
      'secret-file-name.txt',
      'test-token',
      base64Encode(text.ciphertext)
    ]) {
      expect(encoded, isNot(contains(private)));
    }
    // Already processed sync events must not create another reference.
    await pair.bob.processApplicationMessage(text, ref.eventId);
    expect(pair.store.references, hasLength(3));
  }, skip: skip);

  test(
      'enabling capture cannot retroactively capture an in-flight legacy message',
      () async {
    final pair = await _Pair.start(library());
    addTearDown(pair.close);
    final entered = Completer<void>(), release = Completer<void>();
    pair.store.beforeNextLookup = () async {
      entered.complete();
      await release.future;
    };
    final message =
        pair.envelope(AppPayloadType.text, {'text': 'already in flight'});
    final operation = pair.receive(message);
    await entered.future;
    pair.bob.noticeCaptureEnabled = true;
    release.complete();
    await operation;
    expect(pair.store.references, isEmpty);
    await pair.receive(
        pair.envelope(AppPayloadType.text, {'text': 'newly authorized'}));
    expect(pair.store.references, hasLength(1));
  }, skip: skip);

  test(
      'disabling a queued capture aborts without losing the required candidate',
      () async {
    final pair = await _Pair.start(library());
    addTearDown(pair.close);
    pair.bob.noticeCaptureEnabled = true;
    final before = (await pair.store.loadCryptoState())!;
    final cursor = await pair.store.loadSyncCursor();
    final message =
        pair.envelope(AppPayloadType.text, {'text': 'queued message'});
    final operation = pair.bob.processApplicationMessage(message, cursor + 1);
    pair.bob.noticeCaptureEnabled = false;
    await expectLater(operation, throwsA(isA<CryptoOperationCancelled>()));
    expect(
        (await pair.store.loadCryptoState())!.sealedState, before.sealedState);
    expect(await pair.store.loadSyncCursor(), cursor);
    expect(pair.store.references, isEmpty);
    pair.bob.noticeCaptureEnabled = true;
    await pair.bob.processApplicationMessage(message, cursor + 1);
    expect(pair.store.references, hasLength(1));
  }, skip: skip);

  test(
      'capture revocation at atomic commit rolls back ratchet and retries once',
      () async {
    final pair = await _Pair.start(library());
    addTearDown(pair.close);
    pair.bob.noticeCaptureEnabled = true;
    final before = (await pair.store.loadCryptoState())!;
    final cursor = await pair.store.loadSyncCursor();
    final message = pair.envelope(AppPayloadType.text, {'text': 'retry me'});
    pair.store.beforeNextMlsCommit =
        () => pair.bob.noticeCaptureEnabled = false;
    await expectLater(pair.bob.processApplicationMessage(message, cursor + 1),
        throwsA(isA<CryptoOperationCancelled>()));
    expect(
        (await pair.store.loadCryptoState())!.sealedState, before.sealedState);
    expect(await pair.store.loadSyncCursor(), cursor);
    expect(await pair.store.loadMessages(_conversation), isEmpty);
    expect(pair.store.references, isEmpty);
    pair.bob.noticeCaptureEnabled = true;
    await pair.bob.processApplicationMessage(message, cursor + 1);
    expect(pair.store.references, hasLength(1));
  }, skip: skip);

  test(
      'own account, actions, invalid, hidden unsupported and sender mismatch never capture',
      () async {
    final own = await _Pair.start(library(), senderAccount: 'acct_bob');
    addTearDown(own.close);
    own.bob.noticeCaptureEnabled = true;
    await own.receive(
        own.envelope(AppPayloadType.text, {'text': 'from my other device'}));
    expect(own.store.references, isEmpty);
    final pair = await _Pair.start(library());
    addTearDown(pair.close);
    pair.bob.noticeCaptureEnabled = true;
    await pair.receive(pair.envelope(AppPayloadType.reaction,
        {'message_id': 'dev_alice:absent', 'reaction': ''}));
    await pair.receive(pair.encrypted(Uint8List(256), 'invalid'));
    final hidden = jsonEncode({
      'v': 2,
      'conversation_id': _conversation,
      'sender_device_id': 'dev_alice',
      'action_id': 'hidden',
      'type': 'future_type',
      'hidden': true,
      'body': {'private': 'unsupported text'}
    });
    final content = utf8.encode(hidden);
    final frame = Uint8List(((content.length + 8 + 255) ~/ 256) * 256)
      ..setRange(0, 4, 'VAP1'.codeUnits)
      ..setRange(8, content.length + 8, content);
    ByteData.sublistView(frame).setUint32(4, content.length);
    await pair.receive(pair.encrypted(frame, 'hidden'));
    await pair.receive(pair.envelope(
        AppPayloadType.text, {'text': 'mismatched'},
        senderAccount: 'acct_wrong'));
    await pair.receive(pair.envelope(AppPayloadType.text, {'text': 'expired'},
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1))));
    expect(pair.store.references, isEmpty);
  }, skip: skip);

  test(
      'bounded control cancellation preserves Welcome and own-echo cursor for retry',
      () async {
    final pair = await _Pair.start(library(), join: false);
    addTearDown(pair.close);
    var active = true;
    void fence() {
      if (!active) throw StateError('permit revoked');
    }

    final before = (await pair.store.loadCryptoState())!;
    pair.store.beforeNextMlsCommit = () => active = false;
    await expectLater(
        pair.bob.processMlsMessageBounded(pair.welcome, checkCanCommit: fence),
        throwsStateError);
    expect(
        (await pair.store.loadCryptoState())!.sealedState, before.sealedState);
    expect(await pair.store.loadSyncCursor(), 0);
    active = true;
    await pair.bob
        .processMlsMessageBounded(pair.welcome, checkCanCommit: fence);
    final echo = MlsMessage(
        id: 'own_control',
        conversationId: _conversation,
        senderAccountId: 'acct_bob',
        senderDeviceId: 'dev_bob',
        kind: 'commit',
        payload: const [],
        idempotencyKey: 'own_control',
        syncEventId: 2,
        createdAt: DateTime.now().toUtc());
    pair.store.beforeNextSyncCommit = () => active = false;
    await expectLater(
        pair.bob.processMlsMessageBounded(echo, checkCanCommit: fence),
        throwsStateError);
    expect(await pair.store.loadSyncCursor(), 1);
    active = true;
    await pair.bob.processMlsMessageBounded(echo, checkCanCommit: fence);
    expect(await pair.store.loadSyncCursor(), 2);
  }, skip: skip);

  test('bounded sender-mismatch cancellation rolls back the consumed ratchet',
      () async {
    final pair = await _Pair.start(library());
    addTearDown(pair.close);
    pair.bob.noticeCaptureEnabled = true;
    var active = true;
    void fence() {
      if (!active) throw StateError('permit revoked');
    }

    final before = (await pair.store.loadCryptoState())!;
    final message = pair.envelope(
        AppPayloadType.text, {'text': 'untrusted label'},
        senderAccount: 'acct_wrong');
    pair.store.beforeNextMlsCommit = () => active = false;
    await expectLater(
        pair.bob.processApplicationMessageBounded(message, 2,
            checkCanCommit: fence),
        throwsStateError);
    expect(
        (await pair.store.loadCryptoState())!.sealedState, before.sealedState);
    expect(await pair.store.loadSyncCursor(), 1);
    active = true;
    expect(
        await pair.bob.processApplicationMessageBounded(message, 2,
            checkCanCommit: fence),
        isNull);
    expect(await pair.store.loadSyncCursor(), 2);
    expect(pair.store.references, isEmpty);
  }, skip: skip);

  test(
      'bounded call and application own-echo cancellation retries without ratchet loss',
      () async {
    final pair = await _Pair.start(library());
    addTearDown(pair.close);
    var active = true;
    void fence() {
      if (!active) throw StateError('permit revoked');
    }

    final action = 'call_signal';
    final payload = AppPayloadCodec().encode(
        type: AppPayloadType.callSignal,
        conversationId: _conversation,
        senderDeviceId: 'dev_alice',
        actionId: action,
        body: {
          'signal': {'type': 'offer', 'sdp': 'private call data'}
        });
    final call = CallSession(
        id: 'call_notice',
        conversationId: _conversation,
        createdBy: 'acct_alice',
        invitedAccountId: 'acct_bob',
        state: 'ringing',
        version: 1,
        metadata: {
          'version': 1,
          'protocol': 'mls10-openmls-v1',
          'sender_device_id': 'dev_alice',
          'action_id': action,
          'ciphertext': base64Encode(pair.alice.encrypt(_conversation, payload))
        },
        createdAt: DateTime.now().toUtc());
    final before = (await pair.store.loadCryptoState())!;
    pair.store.beforeNextMlsCommit = () => active = false;
    await expectLater(
        pair.bob.processCallSignalBounded(call, 2, checkCanCommit: fence),
        throwsStateError);
    expect(
        (await pair.store.loadCryptoState())!.sealedState, before.sealedState);
    expect(await pair.store.loadSyncCursor(), 1);
    active = true;
    expect(
        await pair.bob.processCallSignalBounded(call, 2, checkCanCommit: fence),
        {'type': 'offer', 'sdp': 'private call data'});
    pair.bob.noticeCaptureEnabled = true;
    final ownSignal = await pair.bob.encryptCallSignal(
        _conversation, {'type': 'ice', 'candidate': 'private candidate'});
    final ownCall = CallSession(
        id: 'own_call',
        conversationId: _conversation,
        createdBy: 'acct_bob',
        invitedAccountId: 'acct_alice',
        state: 'ringing',
        version: 1,
        metadata: ownSignal.metadata,
        createdAt: DateTime.now().toUtc());
    pair.store.beforeNextSyncCommit = () => active = false;
    await expectLater(
        pair.bob.processCallSignalBounded(ownCall, 3, checkCanCommit: fence),
        throwsStateError);
    expect(await pair.store.loadSyncCursor(), 2);
    active = true;
    expect(
        await pair.bob
            .processCallSignalBounded(ownCall, 3, checkCanCommit: fence),
        isNull);
    final outgoing = await pair.bob.encrypt(_conversation, 'own message');
    final echo = ReceivedMessageEnvelope(
        id: 'own_application',
        conversationId: _conversation,
        senderAccountId: 'acct_bob',
        senderDeviceId: 'dev_bob',
        idempotencyKey: outgoing.idempotencyKey,
        ciphertext: outgoing.ciphertext,
        cryptoProtocol: outgoing.cryptoProtocol,
        cryptoMetadata: outgoing.cryptoMetadata,
        createdAt: DateTime.now().toUtc());
    pair.store.beforeNextSyncCommit = () => active = false;
    await expectLater(
        pair.bob
            .processApplicationMessageBounded(echo, 4, checkCanCommit: fence),
        throwsStateError);
    expect(await pair.store.loadSyncCursor(), 3);
    active = true;
    await pair.bob
        .processApplicationMessageBounded(echo, 4, checkCanCommit: fence);
    expect(await pair.store.loadSyncCursor(), 4);
    expect(pair.store.references, isEmpty);
  }, skip: skip);
}
