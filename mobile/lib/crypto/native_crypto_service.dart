import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/models.dart';
import '../storage/encrypted_database.dart'
    show
        DeleteMessageEffect,
        EditMessageEffect,
        InsertMessageEffect,
        LocalMessageKind,
        LocalMessageState,
        MessageEffect,
        ReactionEffect;
import '../storage/local_store.dart';
import 'app_payload.dart';
import 'crypto_service.dart';
import 'native_crypto_bindings.dart';

class NativeCryptoService implements MlsConversationCryptoService {
  NativeCryptoService({
    required this.bindings,
    required this.localStore,
  });

  final NativeCryptoBindings bindings;
  final LocalStore localStore;
  NativeCryptoDevice? _device;

  /// The rollback counter of the state [_device] holds in memory.
  int? _deviceCounter;
  String? _accountId;
  String? _deviceId;
  bool _pendingEnrollment = false;
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<EnrollmentCredential> createEnrollmentCredential(
    EnrollmentReservation reservation,
  ) =>
      _serial(() async {
        _device?.close();
        final device = bindings.createDevice(
          reservation.accountId,
          reservation.deviceId,
        );
        _device = device;
        _accountId = reservation.accountId;
        _deviceId = reservation.deviceId;
        _pendingEnrollment = true;
        return device.createEnrollmentCredential(reservation.challenge);
      });

  @override
  Future<void> activateSession(Session session) => _serial(() async {
        final accountId = session.accountId;
        final deviceId = session.deviceId;
        if (accountId == null ||
            accountId.isEmpty ||
            deviceId == null ||
            deviceId.isEmpty) {
          throw StateError('authenticated device identity is unavailable');
        }
        final stored = await localStore.loadCryptoState();
        if (stored == null) {
          if (!_pendingEnrollment ||
              _accountId != accountId ||
              _deviceId != deviceId ||
              _device == null) {
            throw StateError('protected MLS state is unavailable');
          }
          final key = _randomBytes(32);
          final sealed = _device!.sealState(key, 1);
          await localStore.saveCryptoState(
            StoredCryptoState(counter: 1, stateKey: key, sealedState: sealed),
            await localStore.loadSyncCursor(),
          );
          _deviceCounter = 1;
        } else {
          _device?.close();
          final restored = bindings.restoreDevice(
            accountId,
            deviceId,
            stored.stateKey,
            stored.counter,
            stored.sealedState,
          );
          if (restored.counter != stored.counter) {
            restored.device.close();
            throw StateError('MLS rollback counter mismatch');
          }
          _device = restored.device;
          _deviceCounter = restored.counter;
        }
        _accountId = accountId;
        _deviceId = deviceId;
        _pendingEnrollment = false;
      });

  @override
  Future<List<List<int>>> createReplenishmentKeyPackages({int count = 5}) =>
      _serial(() async {
        if (count <= 0 || count > 10) {
          throw ArgumentError.value(count, 'count');
        }
        final previous = await _requiredState();
        try {
          final packages = <List<int>>[
            for (var index = 0; index < count; index++)
              _requiredDevice().createKeyPackage(),
          ];
          await _commitLocalMutation(previous);
          return packages;
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<void> initializeConversation(
    String conversationId,
    List<DeviceKeyPackage> claimedPackages,
  ) =>
      _serial(() async {
        final previous = await _requiredState();
        try {
          final device = _requiredDevice();
          device.createGroup(conversationId);
          final existingRecipients = <String>[];
          final outbound = <PendingMlsMessage>[];
          for (final package in claimedPackages) {
            final added = device.addMember(
              conversationId,
              package.keyPackage,
              package.accountId,
              package.deviceId,
            );
            for (final recipient in existingRecipients) {
              outbound.add(PendingMlsMessage(
                idempotencyKey: _randomIdempotencyKey(),
                conversationId: conversationId,
                kind: 'commit',
                recipientDeviceId: recipient,
                payload: added.commit,
              ));
            }
            outbound.add(PendingMlsMessage(
              idempotencyKey: _randomIdempotencyKey(),
              conversationId: conversationId,
              kind: 'welcome',
              recipientDeviceId: package.deviceId,
              payload: added.welcome,
            ));
            existingRecipients.add(package.deviceId);
          }
          if (outbound.isEmpty) {
            await _commitLocalMutation(previous);
          } else {
            final next = _sealNext(previous);
            await localStore.commitOutgoingMlsTransition(
              OutgoingMlsStateTransition(
                expectedCounter: previous.counter,
                expectedCursor: await localStore.loadSyncCursor(),
                state: next,
                messages: outbound,
              ),
            );
          }
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<void> processMlsMessage(MlsMessage message) => _serial(() async {
        final marker = 'mls:${message.syncEventId}:${message.id}';
        if (await localStore.hasProcessedMlsMessage(marker)) {
          return;
        }
        final previous = await _requiredState();
        final previousCursor = await localStore.loadSyncCursor();
        if (message.syncEventId <= previousCursor) {
          throw StateError('unrecorded MLS message is behind the sync cursor');
        }
        try {
          if (message.senderDeviceId == _deviceId) {
            await localStore.commitSyncEvent(SyncEventCommit(
              eventKey: marker,
              conversationId: message.conversationId,
              expectedCursor: previousCursor,
              cursor: message.syncEventId,
            ));
            return;
          }
          final device = _requiredDevice();
          switch (message.kind) {
            case 'welcome':
              if (message.recipientDeviceId != _deviceId) {
                throw StateError('MLS Welcome recipient mismatch');
              }
              device.joinGroup(message.conversationId, message.payload);
              break;
            case 'commit':
              device.processCommit(message.conversationId, message.payload);
              break;
            default:
              throw StateError('unsupported MLS transport message');
          }
          final next = _sealNext(previous);
          await localStore.commitMlsTransition(MlsStateTransition(
            messageId: marker,
            conversationId: message.conversationId,
            expectedCounter: previous.counter,
            expectedCursor: previousCursor,
            state: next,
            cursor: message.syncEventId,
          ));
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<void> createRevocationCommit(MlsRevocation revocation) =>
      _serial(() async {
        if (revocation.coordinatorDeviceId != _deviceId ||
            revocation.state != 'pending') {
          throw StateError('device is not the pending revocation coordinator');
        }
        final previous = await _requiredState();
        try {
          final commit = _requiredDevice().removeMember(
            revocation.conversationId,
            revocation.revokedAccountId,
            revocation.revokedDeviceId,
          );
          await localStore.commitOutgoingMlsTransition(
            OutgoingMlsStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: await localStore.loadSyncCursor(),
              state: _sealNext(previous),
              messages: <PendingMlsMessage>[
                PendingMlsMessage(
                  idempotencyKey: _randomIdempotencyKey(),
                  conversationId: revocation.conversationId,
                  kind: 'commit',
                  revocationDeviceId: revocation.revokedDeviceId,
                  payload: commit,
                ),
              ],
            ),
          );
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<ConversationSafetyNumber> conversationSafetyNumber(
          String conversationId) =>
      _serial(() async {
        final value =
            _requiredDevice().conversationSafetyNumber(conversationId);
        if (value.transcriptHash.length != 32 || value.digits.length != 12) {
          throw StateError('native safety number output is invalid');
        }
        return ConversationSafetyNumber(
          digits: value.digits,
          transcriptHash: value.transcriptHash,
          qrPayload: 'veritra-safety:v1:$conversationId:'
              '${base64Url.encode(value.transcriptHash).replaceAll('=', '')}',
        );
      });

  @override
  Future<EncryptedCallSignal> encryptCallSignal(
          String conversationId, Map<String, Object?> signal) =>
      _serial(() async {
        final previous = await _requiredState();
        final cursor = await localStore.loadSyncCursor();
        final actionId = _randomIdempotencyKey();
        try {
          final payload = AppPayloadCodec().encode(
            type: AppPayloadType.callSignal,
            conversationId: conversationId,
            senderDeviceId: _deviceId!,
            actionId: actionId,
            body: <String, Object?>{'signal': signal},
          );
          final ciphertext = _requiredDevice().encrypt(conversationId, payload);
          await localStore.commitLocalMlsState(
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous));
          return EncryptedCallSignal(<String, Object?>{
            'version': 1,
            'ciphertext': base64Encode(ciphertext),
            'protocol': 'mls10-openmls-v1',
            'sender_device_id': _deviceId!,
            'action_id': actionId,
          });
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<Map<String, Object?>?> processCallSignal(
          CallSession call, int syncEventId) =>
      _serial(() async {
        final metadata = call.metadata;
        final senderDeviceId = metadata['sender_device_id'];
        final actionId = metadata['action_id'];
        final encoded = metadata['ciphertext'];
        if (senderDeviceId is! String ||
            actionId is! String ||
            encoded is! String ||
            metadata['protocol'] != 'mls10-openmls-v1' ||
            metadata['version'] != 1) {
          throw const FormatException('invalid encrypted call signal');
        }
        final marker = 'call:$syncEventId:${call.id}:$actionId';
        if (await localStore.hasProcessedMlsMessage(marker)) return null;
        final previous = await _requiredState();
        final cursor = await localStore.loadSyncCursor();
        if (syncEventId <= cursor)
          throw StateError('call signal is behind the sync cursor');
        if (senderDeviceId == _deviceId) {
          await localStore.commitSyncEvent(SyncEventCommit(
            eventKey: marker,
            conversationId: call.conversationId,
            expectedCursor: cursor,
            cursor: syncEventId,
          ));
          return null;
        }
        // Calls are two-party DMs, so the sender is whichever party is not
        // this account. Own-device signals were skipped above.
        final senderAccountId = call.createdBy == _accountId
            ? call.invitedAccountId
            : call.createdBy;
        try {
          final plaintext = _requiredDevice().decrypt(
            call.conversationId,
            base64Decode(encoded),
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
          );
          final payload = AppPayloadCodec().decode(plaintext,
              conversationId: call.conversationId,
              senderDeviceId: senderDeviceId,
              actionId: actionId);
          if (payload.type != AppPayloadType.callSignal) {
            throw const FormatException('unexpected call payload type');
          }
          await localStore.commitMlsTransition(MlsStateTransition(
              messageId: marker,
              conversationId: call.conversationId,
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              cursor: syncEventId));
          return Map<String, Object?>.from(payload.body['signal'] as Map);
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<MessageEnvelope> encrypt(String conversationId, String plaintext) =>
      encryptPayload(conversationId, AppPayloadType.text,
          <String, Object?>{'text': plaintext});

  /// Encrypts one text, reply, edit, delete or reaction payload (D22) and
  /// records this device's own copy in local history with the MLS state.
  ///
  /// The payload type stays inside the ciphertext: the server-visible
  /// metadata is the same for every type.
  @override
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body,
  ) =>
      _serial(() async {
        if (!_messageTypes.contains(type)) {
          throw ArgumentError.value(type, 'type', 'not a message payload');
        }
        final previous = await _requiredState();
        final cursor = await localStore.loadSyncCursor();
        if (!await localStore.hasOutboxCapacity()) {
          throw const OutboxFullException();
        }
        try {
          final idempotencyKey = _randomIdempotencyKey();
          final deviceId = _deviceId!;
          final payload = AppPayloadCodec().encode(
            type: type,
            conversationId: conversationId,
            senderDeviceId: deviceId,
            actionId: idempotencyKey,
            body: body,
          );
          final ciphertext = _requiredDevice().encrypt(conversationId, payload);
          final envelope = MessageEnvelope(
            conversationId: conversationId,
            idempotencyKey: idempotencyKey,
            ciphertext: ciphertext,
            cryptoProtocol: 'mls10-openmls-v1',
            cryptoMetadata: <String, Object?>{
              'protocol_version': 1,
              'group_id': conversationId,
              'content_type': 'application',
              'payload_version': appPayloadVersion,
            },
          );
          await localStore.commitOutgoingApplicationTransition(
            OutgoingApplicationStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              envelope: envelope,
              draftText:
                  type == AppPayloadType.text || type == AppPayloadType.reply
                      ? body['text'] as String
                      : null,
              messageEffects: messageEffectsFor(
                DecryptedAppPayload(
                    type: type, actionId: idempotencyKey, body: body),
                conversationId: conversationId,
                senderAccountId: _accountId!,
                senderDeviceId: deviceId,
                createdAt: DateTime.now().toUtc().millisecondsSinceEpoch,
                state: LocalMessageState.pending,
              ),
            ),
          );
          return envelope;
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<List<int>?> processApplicationMessage(
    ReceivedMessageEnvelope envelope,
    int syncEventId,
  ) =>
      _serial(() async {
        if (envelope.cryptoProtocol != 'mls10-openmls-v1') {
          throw StateError('unsupported message crypto protocol');
        }
        final marker = 'application:$syncEventId:${envelope.id}';
        if (await localStore.hasProcessedMlsMessage(marker)) return null;
        final previous = await _requiredState();
        final cursor = await localStore.loadSyncCursor();
        if (syncEventId <= cursor) {
          throw StateError(
              'unrecorded application message is behind the cursor');
        }
        if (envelope.senderDeviceId == _deviceId) {
          // Our own message: its text was stored when it was encrypted, and
          // MLS cannot decrypt a message for its own sender.
          await localStore.commitSyncEvent(SyncEventCommit(
            eventKey: marker,
            conversationId: envelope.conversationId,
            expectedCursor: cursor,
            cursor: syncEventId,
            envelope: envelope,
            ownMessageKey:
                messageKey(envelope.senderDeviceId, envelope.idempotencyKey),
          ));
          return null;
        }
        try {
          final List<int> plaintext;
          try {
            plaintext = _requiredDevice().decrypt(
              envelope.conversationId,
              envelope.ciphertext,
              senderAccountId: envelope.senderAccountId,
              senderDeviceId: envelope.senderDeviceId,
            );
          } on NativeCryptoException catch (error) {
            if (error.kind != NativeCryptoError.senderMismatch) rethrow;
            // The ratchet already advanced, so the message can never be
            // decrypted again. Keep going and record a warning instead of
            // the claimed sender's words (D25).
            await localStore.commitMlsTransition(MlsStateTransition(
              messageId: marker,
              conversationId: envelope.conversationId,
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              cursor: syncEventId,
              upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
              messageEffects: <MessageEffect>[
                InsertMessageEffect(
                  key: messageKey(
                      envelope.senderDeviceId, envelope.idempotencyKey),
                  serverMessageId: envelope.id,
                  conversationId: envelope.conversationId,
                  senderAccountId: envelope.senderAccountId,
                  senderDeviceId: envelope.senderDeviceId,
                  kind: LocalMessageKind.unverifiable,
                  createdAt: envelope.createdAt.millisecondsSinceEpoch,
                  state: LocalMessageState.received,
                ),
              ],
            ));
            return null;
          }
          final payload = AppPayloadCodec().decode(
            plaintext,
            conversationId: envelope.conversationId,
            senderDeviceId: envelope.senderDeviceId,
            actionId: envelope.idempotencyKey,
          );
          if (!_messageTypes.contains(payload.type) &&
              payload.type != AppPayloadType.attachmentManifest) {
            throw const FormatException('unexpected message payload type');
          }
          await localStore.commitMlsTransition(MlsStateTransition(
            messageId: marker,
            conversationId: envelope.conversationId,
            expectedCounter: previous.counter,
            expectedCursor: cursor,
            state: _sealNext(previous),
            cursor: syncEventId,
            upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
            messageEffects: messageEffectsFor(
              payload,
              conversationId: envelope.conversationId,
              senderAccountId: envelope.senderAccountId,
              senderDeviceId: envelope.senderDeviceId,
              serverMessageId: envelope.id,
              createdAt: envelope.createdAt.millisecondsSinceEpoch,
              state: LocalMessageState.received,
            ),
          ));
          if (payload.type != AppPayloadType.text &&
              payload.type != AppPayloadType.reply) {
            return null;
          }
          return utf8.encode(payload.body['text'] as String);
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<DeviceLinkVerification> deriveDeviceLinkVerification({
    required String accountId,
    required String protocolVersion,
    required List<int> linkNonce,
    required String peerDeviceId,
    required List<int> peerSigningKey,
    required bool localIsExistingDevice,
  }) =>
      _serial(() async {
        if (_accountId != accountId) {
          throw StateError('device-link account mismatch');
        }
        return _requiredDevice().deriveDeviceLinkVerification(
          protocolVersion: protocolVersion,
          peerDeviceId: peerDeviceId,
          peerSigningKey: peerSigningKey,
          linkNonce: linkNonce,
          localIsExistingDevice: localIsExistingDevice,
        );
      });

  Future<StoredCryptoState> _requiredState() async {
    _requiredDevice();
    final state = await localStore.loadCryptoState();
    if (state == null) throw StateError('protected MLS state is unavailable');
    if (state.counter != _deviceCounter) {
      // The stored state moved without this service (a backup restore, or a
      // commit whose outcome was lost). Never build on the stale in-memory
      // group state: reload the committed one.
      await _restorePrevious(state);
    }
    return state;
  }

  NativeCryptoDevice _requiredDevice() {
    final device = _device;
    if (device == null || _accountId == null || _deviceId == null) {
      throw StateError('native MLS device is not active');
    }
    return device;
  }

  StoredCryptoState _sealNext(StoredCryptoState previous) {
    final nextCounter = previous.counter + 1;
    final next = StoredCryptoState(
      counter: nextCounter,
      stateKey: List<int>.from(previous.stateKey),
      sealedState: _requiredDevice().sealState(previous.stateKey, nextCounter),
    );
    // The in-memory group now matches [next]. Callers that fail to commit it
    // call [_restorePrevious], which resets this.
    _deviceCounter = nextCounter;
    return next;
  }

  Future<void> _commitLocalMutation(StoredCryptoState previous) async {
    await localStore.commitLocalMlsState(
      expectedCounter: previous.counter,
      expectedCursor: await localStore.loadSyncCursor(),
      state: _sealNext(previous),
    );
  }

  Future<void> _restorePrevious(StoredCryptoState previous) async {
    _device?.close();
    _deviceCounter = null;
    final restored = bindings.restoreDevice(
      _accountId!,
      _deviceId!,
      previous.stateKey,
      previous.counter,
      previous.sealedState,
    );
    if (restored.counter != previous.counter) {
      restored.device.close();
      _device = null;
      throw StateError('failed to restore the previous MLS state');
    }
    _device = restored.device;
    _deviceCounter = restored.counter;
  }

  Future<T> _serial<T>(Future<T> Function() operation) async {
    final previous = _operationTail;
    final done = Completer<void>();
    _operationTail = done.future;
    await previous.catchError((_) {});
    try {
      return await operation();
    } finally {
      done.complete();
    }
  }

  @override
  Future<void> dispose() => _serial(() async {
        _device?.close();
        _device = null;
        _deviceCounter = null;
        _accountId = null;
        _deviceId = null;
      });
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

const Set<AppPayloadType> _messageTypes = <AppPayloadType>{
  AppPayloadType.text,
  AppPayloadType.reply,
  AppPayloadType.edit,
  AppPayloadType.delete,
  AppPayloadType.reaction,
};

/// The local history key of a message: its authenticated sender device and
/// action ID (D22). The server cannot choose or change either part.
String messageKey(String senderDeviceId, String actionId) =>
    '$senderDeviceId:$actionId';

/// Turns one authenticated payload into local history changes (D22, D23).
/// Edit, delete and reaction envelopes add a hidden action row so the
/// timeline knows to skip them.
List<MessageEffect> messageEffectsFor(
  DecryptedAppPayload payload, {
  required String conversationId,
  required String senderAccountId,
  required String senderDeviceId,
  required int createdAt,
  required String state,
  String? serverMessageId,
}) {
  final body = payload.body;
  InsertMessageEffect row(String kind, {String? text, String? replyTo}) =>
      InsertMessageEffect(
        key: messageKey(senderDeviceId, payload.actionId),
        serverMessageId: serverMessageId,
        conversationId: conversationId,
        senderAccountId: senderAccountId,
        senderDeviceId: senderDeviceId,
        kind: kind,
        body: text,
        replyTo: replyTo,
        createdAt: createdAt,
        state: state,
      );
  return switch (payload.type) {
    AppPayloadType.text => <MessageEffect>[
        row(LocalMessageKind.text, text: body['text'] as String),
      ],
    AppPayloadType.reply => <MessageEffect>[
        row(LocalMessageKind.text,
            text: body['text'] as String,
            replyTo: body['reply_to_id'] as String),
      ],
    AppPayloadType.edit => <MessageEffect>[
        row(LocalMessageKind.action),
        EditMessageEffect(
          targetKey: body['message_id'] as String,
          editorAccountId: senderAccountId,
          body: body['text'] as String,
          at: createdAt,
        ),
      ],
    AppPayloadType.delete => <MessageEffect>[
        row(LocalMessageKind.action),
        DeleteMessageEffect(
          targetKey: body['message_id'] as String,
          deleterAccountId: senderAccountId,
          at: createdAt,
        ),
      ],
    AppPayloadType.reaction => <MessageEffect>[
        row(LocalMessageKind.action),
        ReactionEffect(
          targetKey: body['message_id'] as String,
          reactorAccountId: senderAccountId,
          reaction: body['reaction'] as String,
          at: createdAt,
        ),
      ],
    // Attachments arrive in a later milestone; until then the manifest is
    // kept out of the timeline rather than shown as an empty bubble.
    AppPayloadType.attachmentManifest => <MessageEffect>[
        row(LocalMessageKind.action),
      ],
    AppPayloadType.callSignal =>
      throw const FormatException('call signals are not messages'),
  };
}

String _randomIdempotencyKey() => _randomBytes(24)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
