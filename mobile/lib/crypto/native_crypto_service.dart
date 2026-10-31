import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/models.dart';
import '../core/server_origin.dart';
import '../storage/encrypted_database.dart'
    show
        DeleteMessageEffect,
        EditMessageEffect,
        InsertMessageEffect,
        LocalMessageKind,
        LocalMessageState,
        MessageEffect,
        ReactionEffect;
import '../storage/encrypted_database.dart' show PinMessageEffect;
import '../storage/local_store.dart';
import 'app_payload.dart';
import 'message_format.dart';
import 'crypto_service.dart';
import 'mls_commit_bundle.dart';
import 'native_crypto_bindings.dart';

class NativeCryptoService
    implements
        BoundedMlsConversationCryptoService,
        ConversationAuthorityConsumer,
        NoticeCaptureConsumer {
  NativeCryptoService({
    required this.bindings,
    required this.localStore,
  });

  final NativeCryptoBindings bindings;
  final LocalStore localStore;
  @override
  set conversationAuthority(ConversationAuthority value) => _authority = value;
  ConversationAuthority? _authority;
  NativeCryptoDevice? _device;

  /// The rollback counter of the state [_device] holds in memory.
  int? _deviceCounter;
  String? _accountId;
  String? _deviceId;
  String? _noticeOrigin;
  bool _noticeCaptureEnabled = false;
  int _noticeCaptureGeneration = 0;

  @override
  bool get noticeCaptureEnabled => _noticeCaptureEnabled;
  @override
  set noticeCaptureEnabled(bool enabled) {
    if (enabled &&
        (_noticeOrigin == null ||
            _accountId == null ||
            _deviceId == null ||
            _pendingEnrollment)) {
      throw StateError('notice capture requires an active existing identity');
    }
    if (_noticeCaptureEnabled != enabled) {
      _noticeCaptureEnabled = enabled;
      _noticeCaptureGeneration++;
    }
  }

  void _adoptNoticeOrigin(String origin, String accountId, String deviceId) {
    if (_noticeOrigin != origin ||
        _accountId != accountId ||
        _deviceId != deviceId) {
      noticeCaptureEnabled = false;
    }
    _noticeOrigin = origin;
  }

  bool _pendingEnrollment = false;
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<EnrollmentCredential> createEnrollmentCredential(
    EnrollmentReservation reservation,
  ) =>
      _serial(() async {
        noticeCaptureEnabled = false;
        _noticeOrigin = null;
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
        final origin = canonicalizeServerOrigin(session.baseUrl);
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
        _adoptNoticeOrigin(origin, accountId, deviceId);
        _accountId = accountId;
        _deviceId = deviceId;
        _pendingEnrollment = false;
      });

  @override
  Future<void> activateExistingSessionBounded(Session session,
          {required void Function() checkCanCommit}) =>
      _serial(() async {
        checkCanCommit();
        final origin = canonicalizeServerOrigin(session.baseUrl);
        final accountId = session.accountId;
        final deviceId = session.deviceId;
        if (_pendingEnrollment ||
            accountId == null ||
            accountId.isEmpty ||
            deviceId == null ||
            deviceId.isEmpty) {
          throw StateError('existing authenticated identity is unavailable');
        }
        final stored = await localStore.loadCryptoState();
        checkCanCommit();
        if (stored == null)
          throw StateError('protected MLS state is unavailable');
        if (_device != null &&
            _accountId == accountId &&
            _deviceId == deviceId &&
            _deviceCounter == stored.counter) {
          _adoptNoticeOrigin(origin, accountId, deviceId);
          return;
        }
        final restored = bindings.restoreDevice(accountId, deviceId,
            stored.stateKey, stored.counter, stored.sealedState);
        var adopted = false;
        try {
          checkCanCommit();
          if (restored.counter != stored.counter) {
            throw StateError('MLS rollback counter mismatch');
          }
          _device?.close();
          _device = restored.device;
          _deviceCounter = restored.counter;
          _adoptNoticeOrigin(origin, accountId, deviceId);
          _accountId = accountId;
          _deviceId = deviceId;
          adopted = true;
        } finally {
          if (!adopted) restored.device.close();
        }
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
          // One staged commit adds everyone (card I51). With nobody else to
          // add, the bundle only records this device as the group's first
          // member, so later devices can be added by reconcile.
          final bundle = claimedPackages.isEmpty
              ? const MlsCommitBundle(epoch: 0)
              : _stage(device, conversationId, adds: claimedPackages);
          await localStore.commitOutgoingMlsTransition(
            OutgoingMlsStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: await localStore.loadSyncCursor(),
              state: _sealNext(previous),
              messages: <PendingMlsMessage>[
                _bundleItem(conversationId, bundle)
              ],
            ),
          );
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<void> stageMembershipChange(
    String conversationId, {
    List<DeviceKeyPackage> adds = const <DeviceKeyPackage>[],
    List<MlsDeviceRef> removes = const <MlsDeviceRef>[],
  }) =>
      _serial(() async {
        if (adds.isEmpty && removes.isEmpty) {
          throw ArgumentError('a membership change needs a device');
        }
        final previous = await _requiredState();
        try {
          final bundle = _stage(_requiredDevice(), conversationId,
              adds: adds, removes: removes);
          await localStore.commitOutgoingMlsTransition(
            OutgoingMlsStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: await localStore.loadSyncCursor(),
              state: _sealNext(previous),
              messages: <PendingMlsMessage>[
                _bundleItem(conversationId, bundle)
              ],
            ),
          );
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<void> completeCommitBundle(PendingMlsMessage item) =>
      _serial(() async {
        final bundle = MlsCommitBundle.decode(item.payload);
        final previous = await _requiredState();
        try {
          if (bundle.hasCommit) {
            final device = _requiredDevice();
            final before = device.groupEpoch(item.conversationId);
            if (before.pending) device.mergePendingCommit(item.conversationId);
            final after = device.groupEpoch(item.conversationId);
            // Fail closed if the group is not where the accepted commit
            // leads: that would mean a fork.
            if (after.pending || after.epoch != bundle.epoch + 1) {
              throw StateError('accepted MLS commit does not match the group');
            }
          }
          await localStore.commitLocalMlsState(
            expectedCounter: previous.counter,
            expectedCursor: await localStore.loadSyncCursor(),
            state: _sealNext(previous),
            resolvedMlsOutboxKey: item.idempotencyKey,
          );
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<void> abandonCommitBundle(PendingMlsMessage item) => _serial(() async {
        final bundle = MlsCommitBundle.decode(item.payload);
        final previous = await _requiredState();
        try {
          if (bundle.hasCommit) {
            final device = _requiredDevice();
            final status = device.groupEpoch(item.conversationId);
            if (status.pending) {
              device.clearPendingCommit(item.conversationId);
            }
          }
          await localStore.commitLocalMlsState(
            expectedCounter: previous.counter,
            expectedCursor: await localStore.loadSyncCursor(),
            state: _sealNext(previous),
            resolvedMlsOutboxKey: item.idempotencyKey,
          );
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<({int epoch, bool pending})?> groupEpoch(String conversationId) =>
      _serial(() async {
        try {
          return _requiredDevice().groupEpoch(conversationId);
        } on NativeCryptoException {
          return null;
        }
      });

  MlsCommitBundle _stage(
    NativeCryptoDevice device,
    String conversationId, {
    List<DeviceKeyPackage> adds = const <DeviceKeyPackage>[],
    List<MlsDeviceRef> removes = const <MlsDeviceRef>[],
    String? revocationDeviceId,
  }) {
    final staged = device.stageCommit(
      conversationId,
      adds: <({List<int> keyPackage, String accountId, String deviceId})>[
        for (final package in adds)
          (
            keyPackage: package.keyPackage,
            accountId: package.accountId,
            deviceId: package.deviceId,
          ),
      ],
      removes: removes,
    );
    return MlsCommitBundle(
      epoch: staged.epoch,
      commit: staged.commit,
      welcome: staged.welcome,
      added: <MlsDeviceRef>[
        for (final package in adds)
          (accountId: package.accountId, deviceId: package.deviceId),
      ],
      removed: removes,
      revocationDeviceId: revocationDeviceId,
    );
  }

  PendingMlsMessage _bundleItem(
          String conversationId, MlsCommitBundle bundle) =>
      PendingMlsMessage(
        idempotencyKey: _randomIdempotencyKey(),
        conversationId: conversationId,
        kind: MlsCommitBundle.kind,
        payload: bundle.encode(),
      );

  @override
  Future<void> processMlsMessage(MlsMessage message) =>
      _processMlsMessage(message);

  @override
  Future<void> processMlsMessageBounded(MlsMessage message,
          {required void Function() checkCanCommit}) =>
      _processMlsMessage(message, checkCanCommit: checkCanCommit);

  Future<void> _processMlsMessage(MlsMessage message,
          {void Function()? checkCanCommit}) =>
      _serial(() async {
        checkCanCommit?.call();
        final marker = 'mls:${message.syncEventId}:${message.id}';
        if (await localStore.hasProcessedMlsMessage(marker)) {
          return;
        }
        final previous = await _requiredState(checkCanCommit: checkCanCommit);
        final previousCursor = await localStore.loadSyncCursor();
        if (message.syncEventId <= previousCursor) {
          throw StateError('unrecorded MLS message is behind the sync cursor');
        }
        try {
          checkCanCommit?.call();
          if (message.senderDeviceId == _deviceId) {
            // This device's own commit is on the server, so it was
            // accepted: merge it now if the worker has not yet (card I51).
            final bundle = message.kind == 'commit'
                ? (await localStore.pendingMlsMessages())
                    .where((item) =>
                        item.kind == MlsCommitBundle.kind &&
                        item.idempotencyKey == message.idempotencyKey)
                    .firstOrNull
                : null;
            if (bundle != null) {
              checkCanCommit?.call();
              final device = _requiredDevice();
              final expected = MlsCommitBundle.decode(bundle.payload).epoch + 1;
              if (device.groupEpoch(message.conversationId).pending) {
                device.mergePendingCommit(message.conversationId);
              }
              final after = device.groupEpoch(message.conversationId);
              if (after.pending || after.epoch != expected) {
                throw StateError('own MLS commit does not match the group');
              }
              await localStore.commitMlsTransition(MlsStateTransition(
                checkCanCommit: checkCanCommit,
                messageId: marker,
                conversationId: message.conversationId,
                expectedCounter: previous.counter,
                expectedCursor: previousCursor,
                state: _sealNext(previous),
                cursor: message.syncEventId,
                resolvedMlsOutboxKey: bundle.idempotencyKey,
              ));
              return;
            }
            await localStore.commitSyncEvent(SyncEventCommit(
              checkCanCommit: checkCanCommit,
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
              // Another device's commit won this epoch. Any commit this
              // device staged on the same epoch was refused, so it is
              // dropped before applying the winner (card I51).
              if (device.groupEpoch(message.conversationId).pending) {
                device.clearPendingCommit(message.conversationId);
              }
              device.processCommit(message.conversationId, message.payload);
              break;
            default:
              throw StateError('unsupported MLS transport message');
          }
          final next = _sealNext(previous);
          await localStore.commitMlsTransition(MlsStateTransition(
            checkCanCommit: checkCanCommit,
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
          final bundle = _stage(
            _requiredDevice(),
            revocation.conversationId,
            removes: <MlsDeviceRef>[
              (
                accountId: revocation.revokedAccountId,
                deviceId: revocation.revokedDeviceId,
              ),
            ],
            revocationDeviceId: revocation.revokedDeviceId,
          );
          await localStore.commitOutgoingMlsTransition(
            OutgoingMlsStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: await localStore.loadSyncCursor(),
              state: _sealNext(previous),
              messages: <PendingMlsMessage>[
                _bundleItem(revocation.conversationId, bundle),
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
        if (value.transcriptHash.length != 32 || value.digits.length != 60) {
          throw StateError('native safety number output is invalid');
        }
        return ConversationSafetyNumber(
          digits: value.digits,
          transcriptHash: value.transcriptHash,
          qrPayload: 'veritra-safety:v2:$conversationId:'
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
      _processCallSignal(call, syncEventId);

  @override
  Future<Map<String, Object?>?> processCallSignalBounded(
          CallSession call, int syncEventId,
          {required void Function() checkCanCommit}) =>
      _processCallSignal(call, syncEventId, checkCanCommit: checkCanCommit);

  Future<Map<String, Object?>?> _processCallSignal(
          CallSession call, int syncEventId,
          {void Function()? checkCanCommit}) =>
      _serial(() async {
        checkCanCommit?.call();
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
        // The server's envelope fields are checked before the ratchet can
        // step (P2).
        AppPayloadCodec.validateContext(
            call.conversationId, senderDeviceId, actionId);
        final marker = 'call:$syncEventId:${call.id}:$actionId';
        if (await localStore.hasProcessedMlsMessage(marker)) return null;
        final previous = await _requiredState(checkCanCommit: checkCanCommit);
        final cursor = await localStore.loadSyncCursor();
        if (syncEventId <= cursor)
          throw StateError('call signal is behind the sync cursor');
        if (senderDeviceId == _deviceId) {
          checkCanCommit?.call();
          await localStore.commitSyncEvent(SyncEventCommit(
            checkCanCommit: checkCanCommit,
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
          checkCanCommit?.call();
          List<int>? plaintext;
          try {
            plaintext = _requiredDevice().decrypt(
              call.conversationId,
              base64Decode(encoded),
              senderAccountId: senderAccountId,
              senderDeviceId: senderDeviceId,
            );
          } on NativeCryptoException catch (error) {
            // The server also delivers a caller's signals to the caller's
            // other devices, where the guessed sender account is wrong. The
            // ratchet already advanced, so commit and drop the signal (P4).
            if (error.kind != NativeCryptoError.senderMismatch) rethrow;
          }
          // Once decryption succeeds the ratchet has moved, so the state and
          // cursor always commit (P4). A payload that is not a valid call
          // signal is dropped: no row and no signal.
          final outcome = plaintext == null
              ? const InvalidAppPayload()
              : AppPayloadCodec().classify(plaintext,
                  conversationId: call.conversationId,
                  senderDeviceId: senderDeviceId,
                  actionId: actionId);
          await localStore.commitMlsTransition(MlsStateTransition(
              checkCanCommit: checkCanCommit,
              messageId: marker,
              conversationId: call.conversationId,
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              cursor: syncEventId));
          if (outcome is DecodedAppPayload &&
              outcome.payload.type == AppPayloadType.callSignal) {
            return Map<String, Object?>.from(
                outcome.payload.body['signal'] as Map);
          }
          return null;
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<MessageEnvelope> encrypt(String conversationId, String plaintext) =>
      encryptPayload(conversationId, AppPayloadType.text,
          <String, Object?>{'text': plaintext},
          draftText: plaintext);

  /// Encrypts one text, reply, edit, delete or reaction payload (D22) and
  /// records this device's own copy in local history with the MLS state.
  ///
  /// The payload type stays inside the ciphertext: the server-visible
  /// metadata is the same for every type.
  @override
  Future<MessageEnvelope> encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  }) =>
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
            hidden: type == AppPayloadType.pin,
            channelId: _authority?.conversationKind(conversationId) ==
                    'community_shared'
                ? _authority?.conversationChannel(conversationId)
                : null,
          );
          final device = _requiredDevice();
          final epoch = device.groupEpoch(conversationId).epoch;
          final ciphertext = device.encrypt(conversationId, payload);
          final envelope = MessageEnvelope(
            conversationId: conversationId,
            idempotencyKey: idempotencyKey,
            ciphertext: ciphertext,
            cryptoProtocol: 'mls10-openmls-v1',
            cryptoMetadata: <String, Object?>{
              'protocol_version': 1,
              'group_id': conversationId,
              'content_type': 'application',
              'payload_version': 1,
              if (_authority?.conversationKind(conversationId) ==
                  'community_shared')
                'channel_id': _authority?.conversationChannel(conversationId),
              // The epoch is already readable in the MLS message header. The
              // server uses it to withhold a message from a device that
              // joined after that epoch and cannot decrypt it (card I51).
              'mls_epoch': epoch,
            },
            attachmentRefs: attachmentRefs,
          );
          await localStore.commitOutgoingApplicationTransition(
            OutgoingApplicationStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              envelope: envelope,
              draftText: draftText,
              messageEffects: messageEffectsFor(
                DecryptedAppPayload(
                    type: type,
                    actionId: idempotencyKey,
                    body: body,
                    channelId: _authority?.conversationKind(conversationId) ==
                            'community_shared'
                        ? _authority?.conversationChannel(conversationId)
                        : null),
                conversationId: conversationId,
                senderAccountId: _accountId!,
                senderDeviceId: deviceId,
                createdAt: DateTime.now().toUtc().millisecondsSinceEpoch,
                state: LocalMessageState.pending,
                authority: _authority,
              ),
            ),
          );
          return envelope;
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  /// The `invalid` row for an undecodable message. Keyed by the sync event,
  /// never by the envelope's idempotency key (P3).
  InsertMessageEffect _invalidRow(
          ReceivedMessageEnvelope envelope, int syncEventId) =>
      _placeholderRow(envelope, 'invalid:$syncEventId:${envelope.id}',
          LocalMessageKind.invalid);

  InsertMessageEffect _placeholderRow(
          ReceivedMessageEnvelope envelope, String key, String kind,
          {String? body, bool senderHidden = false, String? channelId}) =>
      InsertMessageEffect(
        key: key,
        serverMessageId: envelope.id,
        conversationId: envelope.conversationId,
        senderAccountId: envelope.senderAccountId,
        senderDeviceId: envelope.senderDeviceId,
        kind: kind,
        body: body,
        senderHidden: senderHidden,
        channelId: channelId,
        createdAt: envelope.createdAt.millisecondsSinceEpoch,
        state: LocalMessageState.received,
        expiresAt: envelope.expiresAt?.toUtc().millisecondsSinceEpoch,
      );

  @override
  Future<List<int>?> processApplicationMessage(
    ReceivedMessageEnvelope envelope,
    int syncEventId,
  ) =>
      _processApplicationMessage(envelope, syncEventId);

  @override
  Future<List<int>?> processApplicationMessageBounded(
          ReceivedMessageEnvelope envelope, int syncEventId,
          {required void Function() checkCanCommit}) =>
      _processApplicationMessage(envelope, syncEventId,
          checkCanCommit: checkCanCommit);

  Future<List<int>?> _processApplicationMessage(
      ReceivedMessageEnvelope envelope, int syncEventId,
      {void Function()? checkCanCommit}) {
    final capture = _captureNoticeOwner(envelope);
    void operationFence() {
      checkCanCommit?.call();
      if (capture != null) _checkNoticeOwner(capture);
    }

    return _serial(() async {
      operationFence();
      if (envelope.cryptoProtocol != 'mls10-openmls-v1') {
        throw StateError('unsupported message crypto protocol');
      }
      // The server's envelope fields are checked before the ratchet can
      // step: a malformed event stops sync with nothing consumed (P2).
      AppPayloadCodec.validateContext(envelope.conversationId,
          envelope.senderDeviceId, envelope.idempotencyKey);
      if (envelope.id.isEmpty || envelope.id.length > 128) {
        throw const FormatException('invalid message envelope id');
      }
      final marker = 'application:$syncEventId:${envelope.id}';
      if (await localStore.hasProcessedMlsMessage(marker)) return null;
      final previous = await _requiredState(checkCanCommit: operationFence);
      final cursor = await localStore.loadSyncCursor();
      if (syncEventId <= cursor) {
        throw StateError('unrecorded application message is behind the cursor');
      }
      if (envelope.senderDeviceId == _deviceId) {
        operationFence();
        // Our own message: its text was stored when it was encrypted, and
        // MLS cannot decrypt a message for its own sender.
        await localStore.commitSyncEvent(SyncEventCommit(
          checkCanCommit: operationFence,
          eventKey: marker,
          conversationId: envelope.conversationId,
          expectedCursor: cursor,
          cursor: syncEventId,
          envelope: envelope,
          ownMessageKey:
              messageKey(envelope.senderDeviceId, envelope.idempotencyKey),
          allowOwnPinEffect: pinAllowed(
              kind: _authority?.conversationKind(envelope.conversationId),
              role: _authority?.roleOf(envelope.conversationId, _accountId!)),
        ));
        return null;
      }
      try {
        operationFence();
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
            checkCanCommit: operationFence,
            messageId: marker,
            conversationId: envelope.conversationId,
            expectedCounter: previous.counter,
            expectedCursor: cursor,
            state: _sealNext(previous),
            cursor: syncEventId,
            upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
            messageEffects: <MessageEffect>[
              // Keyed by the sync event: the claimed idempotency key is
              // not authenticated (P3).
              _placeholderRow(
                  envelope,
                  'unverifiable:$syncEventId:${envelope.id}',
                  LocalMessageKind.unverifiable),
            ],
          ));
          return null;
        }
        // From here the ratchet has moved: whatever the payload is, the
        // MLS state and the cursor commit with it (P1). Only a storage
        // error from the commit itself rolls back.
        List<MessageEffect> effects;
        List<int>? text;
        var noticePayload = false;
        try {
          final outcome = AppPayloadCodec().classify(
            plaintext,
            conversationId: envelope.conversationId,
            senderDeviceId: envelope.senderDeviceId,
            actionId: envelope.idempotencyKey,
            communityShared:
                _authority?.conversationKind(envelope.conversationId) ==
                    'community_shared',
            channelId: (envelope.cryptoMetadata is Map
                ? (envelope.cryptoMetadata as Map)['channel_id']
                : null) as String?,
          );
          switch (outcome) {
            case DecodedAppPayload(:final payload):
              if (!_messageTypes.contains(payload.type)) {
                throw const FormatException('unexpected message type');
              }
              effects = messageEffectsFor(
                payload,
                conversationId: envelope.conversationId,
                senderAccountId: envelope.senderAccountId,
                senderDeviceId: envelope.senderDeviceId,
                serverMessageId: envelope.id,
                createdAt: envelope.createdAt.millisecondsSinceEpoch,
                state: LocalMessageState.received,
                expiresAt: envelope.expiresAt?.toUtc().millisecondsSinceEpoch,
                authority: _authority,
              );
              noticePayload = const {
                AppPayloadType.text,
                AppPayloadType.reply,
                AppPayloadType.attachmentManifest,
              }.contains(payload.type);
              if (payload.type == AppPayloadType.text ||
                  payload.type == AppPayloadType.reply) {
                text = utf8.encode(payload.body['text'] as String);
              }
            case UnsupportedAppPayload():
              effects = <MessageEffect>[
                _placeholderRow(
                  envelope,
                  messageKey(envelope.senderDeviceId, envelope.idempotencyKey),
                  LocalMessageKind.unsupported,
                  body: outcome.rawJson,
                  senderHidden: outcome.hidden,
                  channelId: (envelope.cryptoMetadata is Map
                      ? (envelope.cryptoMetadata as Map)['channel_id']
                      : null) as String?,
                ),
              ];
            case InvalidAppPayload():
              effects = <MessageEffect>[_invalidRow(envelope, syncEventId)];
          }
        } catch (_) {
          effects = <MessageEffect>[_invalidRow(envelope, syncEventId)];
          text = null;
          noticePayload = false;
        }
        operationFence();
        await localStore.commitMlsTransition(MlsStateTransition(
          checkCanCommit: operationFence,
          messageId: marker,
          conversationId: envelope.conversationId,
          expectedCounter: previous.counter,
          expectedCursor: cursor,
          state: _sealNext(previous),
          cursor: syncEventId,
          upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
          messageEffects: effects,
          noticeReferences: noticePayload && capture != null
              ? _noticeReferences(capture.owner, envelope, syncEventId, effects)
              : const <LocalNoticeReference>[],
        ));
        return text;
      } catch (_) {
        await _restorePrevious(previous);
        rethrow;
      }
    });
  }

  ({LocalNoticeOwner owner, int generation})? _captureNoticeOwner(
      ReceivedMessageEnvelope envelope) {
    final origin = _noticeOrigin, accountId = _accountId, deviceId = _deviceId;
    if (!_noticeCaptureEnabled ||
        _pendingEnrollment ||
        origin == null ||
        accountId == null ||
        deviceId == null ||
        envelope.senderAccountId == accountId ||
        envelope.senderDeviceId == deviceId) {
      return null;
    }
    return (
      owner: LocalNoticeOwner(
          origin: origin, accountId: accountId, deviceId: deviceId),
      generation: _noticeCaptureGeneration
    );
  }

  void _checkNoticeOwner(({LocalNoticeOwner owner, int generation}) capture) {
    if (!_noticeCaptureEnabled ||
        _pendingEnrollment ||
        capture.generation != _noticeCaptureGeneration ||
        capture.owner.origin != _noticeOrigin ||
        capture.owner.accountId != _accountId ||
        capture.owner.deviceId != _deviceId) {
      throw const CryptoOperationCancelled();
    }
  }

  List<LocalNoticeReference> _noticeReferences(
      LocalNoticeOwner owner,
      ReceivedMessageEnvelope envelope,
      int eventId,
      List<MessageEffect> effects) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    return [
      for (final effect in effects.whereType<InsertMessageEffect>())
        if (effect.state == LocalMessageState.received &&
            const {LocalMessageKind.text, LocalMessageKind.attachment}
                .contains(effect.kind) &&
            !effect.senderHidden &&
            effect.body != null &&
            effect.senderAccountId != owner.accountId &&
            effect.senderDeviceId != owner.deviceId &&
            effect.conversationId == envelope.conversationId &&
            effect.serverMessageId == envelope.id &&
            effect.senderAccountId == envelope.senderAccountId &&
            effect.senderDeviceId == envelope.senderDeviceId &&
            effect.key ==
                messageKey(envelope.senderDeviceId, envelope.idempotencyKey) &&
            (effect.expiresAt == null || effect.expiresAt! > now))
          LocalNoticeReference(
              owner: owner,
              eventId: eventId,
              messageKey: effect.key,
              serverMessageId: envelope.id,
              conversationId: effect.conversationId,
              channelId: effect.channelId,
              senderAccountId: effect.senderAccountId,
              senderDeviceId: effect.senderDeviceId,
              createdAt: effect.createdAt,
              expiresAt: effect.expiresAt),
    ];
  }

  @override
  Future<String> deviceLinkLocator(List<int> secret) async =>
      bindings.deviceLinkLocator(secret);

  @override
  Future<DeviceLinkVerification> deriveDeviceLinkVerification({
    required String accountId,
    required String protocolVersion,
    required String serverOrigin,
    required String linkId,
    required List<int> linkSecret,
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
          serverOrigin: serverOrigin,
          linkId: linkId,
          linkSecret: linkSecret,
          peerDeviceId: peerDeviceId,
          peerSigningKey: peerSigningKey,
          linkNonce: linkNonce,
          localIsExistingDevice: localIsExistingDevice,
        );
      });

  Future<StoredCryptoState> _requiredState(
      {void Function()? checkCanCommit}) async {
    _requiredDevice();
    final state = await localStore.loadCryptoState();
    checkCanCommit?.call();
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
        noticeCaptureEnabled = false;
        _noticeOrigin = null;
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
  AppPayloadType.attachmentManifest,
  AppPayloadType.pin,
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
  int? expiresAt,
  ConversationAuthority? authority,
}) {
  final body = payload.body;
  final decoration = messageDecoration(body,
      members: authority?.memberAccounts(conversationId) ?? const {});
  final forwarded = body['forwarded'];
  final rawHops = forwarded is Map ? forwarded['hops'] : null;
  final hops = rawHops is int ? rawHops.clamp(1, 5) : null;
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
        expiresAt: expiresAt,
        formatJson: decoration.isEmpty ? null : jsonEncode(decoration),
        forwardHops: hops,
        channelId: payload.channelId,
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
          conversationId: conversationId,
          channelId: payload.channelId,
          formatJson: decoration.isEmpty ? null : jsonEncode(decoration),
        ),
      ],
    AppPayloadType.delete => <MessageEffect>[
        row(LocalMessageKind.action),
        DeleteMessageEffect(
          targetKey: body['message_id'] as String,
          deleterAccountId: senderAccountId,
          at: createdAt,
          conversationId: conversationId,
          channelId: payload.channelId,
        ),
      ],
    AppPayloadType.reaction => <MessageEffect>[
        row(LocalMessageKind.action),
        ReactionEffect(
          targetKey: body['message_id'] as String,
          reactorAccountId: senderAccountId,
          reaction: body['reaction'] as String,
          at: createdAt,
          conversationId: conversationId,
          channelId: payload.channelId,
        ),
      ],
    AppPayloadType.attachmentManifest => <MessageEffect>[
        row(LocalMessageKind.attachment, text: jsonEncode(body['attachments'])),
      ],
    AppPayloadType.pin => <MessageEffect>[
        row(LocalMessageKind.action),
        if (pinAllowed(
            kind: authority?.conversationKind(conversationId),
            role: authority?.roleOf(conversationId, senderAccountId)))
          PinMessageEffect(
              conversationId: conversationId,
              targetKey: body['message_id'] as String,
              accountId: senderAccountId,
              at: createdAt,
              pinned: body['pinned'] as bool,
              durationSeconds: body['pinned'] == true
                  ? body['duration_seconds'] as int
                  : null,
              channelId: payload.channelId,
              pendingActionKey: state == LocalMessageState.pending
                  ? messageKey(senderDeviceId, payload.actionId)
                  : null),
      ],
    AppPayloadType.callSignal =>
      throw const FormatException('call signals are not messages'),
  };
}

String _randomIdempotencyKey() => _randomBytes(24)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
