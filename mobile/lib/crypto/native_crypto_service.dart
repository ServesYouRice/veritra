import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/models.dart';
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
        try {
          final plaintext = _requiredDevice()
              .decrypt(call.conversationId, base64Decode(encoded));
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
      _serial(() async {
        final previous = await _requiredState();
        final cursor = await localStore.loadSyncCursor();
        if (!await localStore.hasOutboxCapacity()) {
          throw const OutboxFullException();
        }
        try {
          final idempotencyKey = _randomIdempotencyKey();
          final payload = AppPayloadCodec().encode(
            type: AppPayloadType.text,
            conversationId: conversationId,
            senderDeviceId: _deviceId!,
            actionId: idempotencyKey,
            body: <String, Object?>{'text': plaintext},
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
              'payload_type': AppPayloadType.text.name,
            },
          );
          await localStore.commitOutgoingApplicationTransition(
            OutgoingApplicationStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              envelope: envelope,
              draftText: plaintext,
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
          await localStore.commitSyncEvent(SyncEventCommit(
            eventKey: marker,
            conversationId: envelope.conversationId,
            expectedCursor: cursor,
            cursor: syncEventId,
            envelope: envelope,
          ));
          return null;
        }
        try {
          final plaintext = _requiredDevice()
              .decrypt(envelope.conversationId, envelope.ciphertext);
          final payload = AppPayloadCodec().decode(
            plaintext,
            conversationId: envelope.conversationId,
            senderDeviceId: envelope.senderDeviceId,
            actionId: envelope.idempotencyKey,
          );
          await localStore.commitMlsTransition(MlsStateTransition(
            messageId: marker,
            conversationId: envelope.conversationId,
            expectedCounter: previous.counter,
            expectedCursor: cursor,
            state: _sealNext(previous),
            cursor: syncEventId,
            upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
          ));
          if (payload.type != AppPayloadType.text) return null;
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
    return StoredCryptoState(
      counter: nextCounter,
      stateKey: List<int>.from(previous.stateKey),
      sealedState: _requiredDevice().sealState(previous.stateKey, nextCounter),
    );
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
        _accountId = null;
        _deviceId = null;
      });
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _randomIdempotencyKey() => _randomBytes(24)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
