import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileMode, Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/device_lists.dart' show DeviceListPins;
import '../core/k1_backup.dart' show k1BackupPlaintextVersion;
import '../core/models.dart';
import '../core/roles/governance.dart';
import '../core/roles/governance_codec.dart'
    show decodeGovernance, encodeGovernance;
import '../core/roles/governance_commands.dart';
import '../core/roles/posting_verdict.dart';
import '../core/roles/timeout_verdict.dart';
import '../core/server_origin.dart';
import '../storage/encrypted_database.dart'
    show
        DeleteMessageEffect,
        EditMessageEffect,
        EnrollmentPromotionOutcome,
        FrankReveal,
        HistoryTransferProgress,
        HistoryTransferStage,
        InsertMessageEffect,
        historyTransferIncoming,
        historyTransferOutgoing,
        LocalMessageKind,
        LocalMessageState,
        MessageEffect,
        ReactionEffect;
import '../storage/encrypted_database.dart'
    show
        PinMessageEffect,
        PollCloseEffect,
        PollVoteEffect,
        ProfileKeyEffect,
        profileSubjectAccount,
        profileSubjectConversation;
import 'profile_key_payload.dart';
import 'profile_record_codec.dart' show ProfileRecordCodec;
import '../storage/history_snapshot.dart'
    show HistoryImportContext, HistorySnapshot;
import '../storage/local_store.dart';
import '../sync/conversation_pause.dart';
import 'app_payload.dart';
import 'c7_channel_book.dart';
import 'c7_group_state.dart';
import 'c7_history.dart';
import 'c7_import.dart';
import 'c7_keys.dart';
import 'c7_sync.dart';
import 'c7_two_part.dart';
import 'community_info_codec.dart' show CommunityInfoCodec;
import 'community_info_payload.dart' show infoKeyBytes;
import 'message_format.dart';
import 'poll.dart' show pollRowBody;
import 'crypto_service.dart';
import 'franking.dart';
import 'report_key_announcement.dart';
import 'k2_transfer_crypto.dart';
import 'mls_commit_bundle.dart';
import 'native_crypto_bindings.dart';
import '../calls/room/native_call_group.dart';
import '../calls/room/room_ports.dart'
    show CallGroupHandle, ParentGroupView, RoomCryptoSource;

class NativeCryptoService
    implements
        C7HistoryService,
        BackupSealCryptoService,
        BackupOpenCryptoService,
        CommunityInfoCryptoService,
        MlsRosterSource,
        BoundedMlsConversationCryptoService,
        ChannelRoutedCryptoService,
        ConversationAuthorityConsumer,
        C7HistoryConsumer,
        DeviceListCryptoService,
        ApprovedDeviceDiscoveryCryptoService,
        OwnDeviceAlertCryptoService,
        DeviceSigningKeyCryptoService,
        EnrollmentPromotionCryptoService,
        InviteBindingCryptoService,
        K2TransferCryptoService,
        MlsDeviceHealthCryptoService,
        ExpiringPayloadCryptoService,
        MlsSelfUpdateCryptoService,
        MlsStateMaintenanceCryptoService,
        NoticeCaptureConsumer,
        ProfileCodecSource,
        RecoveryCryptoService,
        ReportCryptoService,
        RoleCommandCryptoService,
        MlsRosterCryptoService,
        RoomCryptoSource {
  NativeCryptoService({
    required this.bindings,
    required this.localStore,
    DateTime Function()? clock,
    this.frankingPolicy = const FrankingPolicy(),
  }) : _clock = clock ?? DateTime.now;

  final NativeCryptoBindings bindings;

  @override
  ProfileRecordCodec get profileCodec => ProfileRecordCodec(bindings);
  final LocalStore localStore;

  /// What the receive path does with a payload that carries no franking key
  /// (D95). Accepts them for now.
  final FrankingPolicy frankingPolicy;

  /// The time key-package expiry is judged by (D70).
  final DateTime Function() _clock;
  @override
  set conversationAuthority(ConversationAuthority value) => _authority = value;

  /// C7: whether sends in community conversations go in two parts. Off by
  /// default; AppState follows the server's `c7_history`.
  @override
  bool c7SealedBodies = false;

  @override
  Future<MessageEnvelope> c7ProposeRecord(
    String conversationId,
    String channelId, {
    required bool full,
    bool create = false,
    int? layoutGeneration,
  }) =>
      _serial(() => _c7Propose(conversationId, channelId,
          full: full, create: create, layoutGeneration: layoutGeneration));

  @override
  Future<C7ChannelView?> c7ChannelView(
      String conversationId, String channelId) async {
    if (!_c7Active(conversationId)) return null;
    final book = (await _c7LoadBook(conversationId, channelId))
        .expirePending(_c7NowMs());
    return C7ChannelView(
      full: book.mode == c7ModeFull,
      status: book.status.name,
      pending: book.pending != null && book.ownNotice != 'stale',
      ownNotice: book.ownNotice,
      recorded: book.headBytes != null || book.chain.highestSeq >= 0,
    );
  }

  @override
  Future<List<C7Due>> c7DueWork(Iterable<String> conversationIds) =>
      _serial(() => _c7Due(conversationIds));

  @override
  Future<MessageEnvelope?> c7Send(C7Due due) => _serial(() => switch (due) {
        C7DueSync(:final conversationId, :final forEpoch) =>
          _c7SendSync(conversationId, forEpoch),
        C7DueRequest(:final conversationId) => _c7SendRequest(conversationId),
        C7DueRepropose() => throw ArgumentError.value(
            due, 'due', 'the app proposes a stale record again'),
      });

  @override
  Future<Map<String, bool>> c7HistoryLines(String conversationId) async {
    if (!_c7Active(conversationId)) return const <String, bool>{};
    final group = await _c7LoadGroup(conversationId);
    return <String, bool>{
      for (final channel in group.channels)
        for (final (key, full)
            in (await _c7LoadBook(conversationId, channel)).lines)
          key: full,
    };
  }

  @override
  Future<DateTime?> c7NextDueAt(Iterable<String> conversationIds) async {
    int? next;
    void consider(int at) => next = next == null ? at : min(next!, at);
    for (final conversationId in conversationIds) {
      if (!_c7Active(conversationId)) continue;
      final group = await _c7LoadGroup(conversationId);
      for (final duty in group.duties.values) {
        if (!duty.settled) consider(duty.dueAtMs);
      }
      final request = group.requestDueAtMs;
      if (request != null && !group.joinSynced && group.joinEpoch != null) {
        consider(request);
      }
    }
    return next == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(next!, isUtc: true);
  }

  @override
  Future<void> c7SyncDelivered(String conversationId, int forEpoch) =>
      _serial(() => _c7SyncDelivered(conversationId, forEpoch));

  @override
  Future<List<String>> c7ImportDue(Iterable<String> conversationIds) async {
    final out = <String>[];
    for (final conversationId in conversationIds) {
      if (!_c7Active(conversationId)) continue;
      final group = await _c7LoadGroup(conversationId);
      if (group.joinEpoch != null && group.joinSynced && !group.imported) {
        out.add(conversationId);
      }
    }
    return out;
  }

  @override
  Future<int> c7ImportHistory(
    String conversationId, {
    required C7HistoryPage groupLevel,
    required Map<String, C7HistoryPage> channels,
    List<C7FormerKey> formerKeys = const <C7FormerKey>[],
    bool first = true,
  }) =>
      _serial(() => _c7Import(conversationId,
          groupLevel: groupLevel,
          channels: channels,
          formerKeys: formerKeys,
          first: first));

  @override
  Future<String?> c7EarlierCursor(
      String conversationId, String channelId) async {
    if (!_c7Active(conversationId)) return null;
    if (!(await _c7LoadGroup(conversationId)).imported) return null;
    if ((await _c7LoadBook(conversationId, channelId)).mode != c7ModeFull) {
      return null;
    }
    return C7ImportState.decode(
            await localStore.loadSetting(c7ImportSetting(conversationId)))
        .cursors[channelId];
  }

  @override
  Future<void> c7CommitExpiredSkip(SyncEventCommit tombstone) =>
      _serial(() async {
        final miss = tombstone.conversationId.isEmpty
            ? _c7None
            : await _c7Miss(tombstone.conversationId);
        await localStore.commitSyncEvent(SyncEventCommit(
          eventKey: tombstone.eventKey,
          conversationId: tombstone.conversationId,
          expectedCursor: tombstone.expectedCursor,
          cursor: tombstone.cursor,
          checkCanCommit: tombstone.checkCanCommit,
          c7Settings: <String, String?>{...tombstone.c7Settings, ...miss},
        ));
      });

  String? _c7PrivateChannel(String conversationId) => switch (_authority) {
        final ConversationCommunitySource source =>
          source.privateGroupChannel(conversationId),
        _ => null,
      };

  /// A conversation in the C0 layout: a shared group or a private channel's
  /// own group. There a two-part message with no `channel_id` is
  /// group-level and may only be a `history_sync` or its request.
  bool _c7Layout(String conversationId) =>
      _authority?.conversationKind(conversationId) == 'community_shared' ||
      _c7PrivateChannel(conversationId) != null;

  @override
  CommunityInfoCodec get communityInfoCodec => CommunityInfoCodec(bindings);
  ConversationAuthority? _authority;
  NativeCryptoDevice? _device;

  @override
  GovernanceState? governanceOf(String conversationId) {
    final device = _device;
    if (device == null) return null;
    try {
      final state = device.groupRoleState(conversationId);
      final record = state.record;
      if (record == null) return null;
      return decodeGovernance(record);
    } catch (_) {
      return null;
    }
  }

  @override
  Set<String>? mlsAccountsOf(String conversationId) =>
      _approvedAccountsOf(conversationId);

  @override
  Set<String>? groupMemberAccounts(String conversationId) =>
      _approvedAccountsOf(conversationId);

  /// The accounts holding a leaf in [conversationId]'s MLS tree that this
  /// device's last judgment found `approved` by the account's L1 list, with
  /// the key in the tree (review L7: an unapproved leaf can carry any
  /// account's id, so it must not make that account a channel member for
  /// C6 reports or the C3 no-admin rule). Null when the group is unknown or
  /// no judgment is cached yet; a load is started, so a later call answers.
  Set<String>? _approvedAccountsOf(String conversationId) {
    final device = _device;
    if (device == null) return null;
    final verdicts = _verdictCache[conversationId];
    if (verdicts == null) {
      unawaited(_warmVerdicts(conversationId));
      return null;
    }
    try {
      return <String>{
        for (final leaf in device.groupMembers(conversationId))
          if (verdicts.any((row) =>
              row.verdict == LeafVerdict.approved &&
              row.sameLeaf(leaf.accountId, leaf.deviceId) &&
              _sameBytes(row.signingKey, leaf.signingKey)))
            utf8.decode(leaf.accountId),
      };
    } catch (_) {
      return null;
    }
  }

  /// The last judged leaves per conversation (L7), kept in step with every
  /// write of the stored verdicts this service makes.
  final Map<String, List<ApprovalLeaf>> _verdictCache =
      <String, List<ApprovalLeaf>>{};

  /// Verdict writes per conversation, so a load that a write overtook is
  /// not cached (it would hold the rows from before that write).
  final Map<String, int> _verdictWrites = <String, int>{};

  Future<void> _warmVerdicts(String conversationId) async {
    final writes = _verdictWrites[conversationId] ?? 0;
    try {
      final rows = await localStore.loadApprovalLeaves(conversationId);
      if ((_verdictWrites[conversationId] ?? 0) != writes) return;
      _verdictCache.putIfAbsent(conversationId, () => rows);
    } on Object {
      // Asked again on the next call.
    }
  }

  void _rememberVerdicts(ApprovalLeafChange change) {
    _verdictWrites.update(change.conversationId, (n) => n + 1,
        ifAbsent: () => 1);
    if (change.replaceAll) {
      _verdictCache[change.conversationId] =
          List<ApprovalLeaf>.of(change.leaves);
      return;
    }
    final cached = _verdictCache[change.conversationId];
    if (cached == null) return;
    for (final row in change.leaves) {
      cached.removeWhere((old) => old.sameLeaf(row.accountId, row.deviceId));
      cached.add(row);
    }
  }

  Future<void> _saveApprovalLeaves(ApprovalLeafChange change) async {
    await localStore.saveApprovalLeaves(change);
    _rememberVerdicts(change);
  }

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

  /// The enrolling device's first sealed state, kept until it is stored: a
  /// seal moves the device's generation, so a retried activation must store
  /// this same state rather than seal again (D70).
  StoredCryptoState? _firstState;

  /// Whether the first sealed state (and its state key) is still held.
  @visibleForTesting
  bool get holdsFirstState => _firstState != null;
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<EnrollmentCredential> createEnrollmentCredential(
    EnrollmentReservation reservation,
  ) =>
      _serial(() async {
        // An identity this database already promoted is never enrolled
        // again under the same IDs (schema 18 ledger).
        await _refusePromoted(reservation.accountId, reservation.deviceId);
        noticeCaptureEnabled = false;
        _noticeOrigin = null;
        _device?.close();
        _closeCallGroups();
        final device = bindings.createDevice(
          reservation.accountId,
          reservation.deviceId,
        );
        _device = device;
        _verdictCache.clear();
        // The fresh device holds no stored state yet (C-b5dfd921d890).
        _deviceCounter = null;
        _accountId = reservation.accountId;
        _deviceId = reservation.deviceId;
        _pendingEnrollment = true;
        _firstState = null;
        return device.createEnrollmentCredential(reservation.challenge);
      });

  @override
  Future<Uint8List> deviceSigningPublicKey({
    required String accountId,
    required String deviceId,
  }) =>
      _serial(() async {
        final device = _requiredDevice();
        if (_pendingEnrollment ||
            _accountId != accountId ||
            _deviceId != deviceId) {
          throw StateError('the active identity is not this device');
        }
        return Uint8List.fromList(device.signingPublicKey());
      });

  // C1 invitation binding v2 (ABI 13 sign, verify and member key read).

  @override
  Future<Uint8List> signInviteBinding({
    required String accountId,
    required String deviceId,
    required List<int> message,
  }) =>
      _serial(() async {
        final device = _requiredDevice();
        if (_pendingEnrollment ||
            _accountId != accountId ||
            _deviceId != deviceId) {
          throw StateError('the active identity is not this device');
        }
        return Uint8List.fromList(device.c7Sign(
          domain: inviteBindingSigningDomain,
          message: message,
        ));
      });

  @override
  Future<bool> verifyInviteBinding({
    required List<int> signingKey,
    required List<int> message,
    required List<int> signature,
  }) async {
    try {
      return bindings.c7Verify(
        domain: inviteBindingSigningDomain,
        publicKey: signingKey,
        message: message,
        signature: signature,
      );
    } on NativeCryptoException {
      // An older library refuses the domain; any engine error is no proof.
      return false;
    } on ArgumentError {
      return false;
    }
  }

  @override
  Future<Uint8List?> memberSigningKey({
    required String conversationId,
    required String accountId,
    required String deviceId,
  }) =>
      _serial(() async {
        final device = _requiredDevice();
        try {
          return Uint8List.fromList(
            device.memberSignatureKey(conversationId, accountId, deviceId),
          );
        } on NativeCryptoException {
          // No such group here, or no such member in it.
          return null;
        }
      });

  // C6 reports (ABI 12). Stateless: none touches the device or its state.

  @override
  Future<Uint8List> generateReportKeySeed() async =>
      bindings.generateReportKeySeed();

  @override
  Future<Uint8List> reportPublicKey(Uint8List seed) async =>
      bindings.reportPublicKey(seed);

  @override
  Future<Uint8List> sealReport({
    required List<int> recipientPublicKey,
    required List<int> aad,
    required Uint8List plaintext,
  }) async =>
      bindings.sealReport(
          recipientPublicKey: recipientPublicKey,
          aad: aad,
          plaintext: plaintext);

  @override
  Future<Uint8List> openReport({
    required Uint8List seed,
    required List<int> aad,
    required List<int> sealed,
  }) async =>
      bindings.openReport(seed: seed, aad: aad, sealed: sealed);

  @override
  Future<Uint8List> frankCommit({
    required Uint8List key,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Uint8List payload,
  }) async =>
      bindings.frankCommit(
          key: key,
          conversationId: conversationId,
          senderDeviceId: senderDeviceId,
          actionId: actionId,
          payload: payload);

  // K0 recovery (ABI 11). The bindings are synchronous; each call is
  // serialized with the MLS operations only where it touches the device.

  @override
  Future<Uint8List> generateRecoveryKey() async =>
      bindings.generateRecoveryKey();

  @override
  Future<String> encodeRecoveryKey(Uint8List entropy) async =>
      bindings.encodeRecoveryKey(entropy);

  @override
  Future<Uint8List> decodeRecoveryKey(String text) async =>
      bindings.decodeRecoveryKey(text);

  @override
  Future<Uint8List> sealK1Backup({
    required String accountId,
    required String sourceDeviceId,
    required int createdAtMs,
    required int counter,
    required Uint8List rkPub,
    required Uint8List plaintext,
  }) async =>
      bindings.sealBackup(
          accountId: accountId,
          sourceDeviceId: sourceDeviceId,
          createdAtMs: createdAtMs,
          counter: counter,
          plaintextVersion: k1BackupPlaintextVersion,
          rkPub: rkPub,
          plaintext: plaintext);

  @override
  int get k1BackupMaxPlaintextBytes =>
      NativeCryptoBindings.backupMaxPlaintextBytes;

  @override
  BackupHeaderInfo peekK1Backup(Uint8List prefix) =>
      bindings.peekBackup(prefix);

  @override
  Future<OpenedBackup> openK1Backup({
    required Uint8List ciphertext,
    required Uint8List entropy,
    required String accountId,
    String? sourceDeviceId,
  }) async =>
      bindings.openBackup(
          ciphertext: ciphertext,
          entropy: entropy,
          accountId: accountId,
          sourceDeviceId: sourceDeviceId);

  @override
  Future<RecoveryKeyValues> deriveRecoveryKey(Uint8List entropy) async {
    final derived = bindings.deriveRecoveryKey(entropy);
    return RecoveryKeyValues(
        rkPub: derived.rkPub,
        rkId: derived.rkId,
        rkAuthPub: derived.rkAuthPub,
        rkListPub: derived.rkListPub);
  }

  @override
  Future<Uint8List> signRecoveryProof({
    required Uint8List entropy,
    required List<int> challenge,
    required List<int> signingKey,
    required List<int> keyPackage,
    required String origin,
  }) async =>
      bindings.signRecoveryProof(
          entropy: entropy,
          challenge: challenge,
          signingKey: signingKey,
          keyPackage: keyPackage,
          origin: origin);

  // L1 approved-device list (D94). The rules live in Rust; the pins in the
  // app. Without pins no add is staged and every leaf is "checking".

  DeviceListPins? _deviceListPins;

  @override
  set deviceListPins(DeviceListPins? pins) => _deviceListPins = pins;

  @override
  Future<List<MlsDeviceRef>> missingApprovedDevices(
      String? conversationId, Iterable<String> accountIds,
      {Set<String> excluding = const <String>{}}) async {
    final pins = _deviceListPins;
    if (pins == null) return const [];
    final present = await _serial(() async {
      if (conversationId == null) {
        return <MlsDeviceRef>{(accountId: _accountId!, deviceId: _deviceId!)};
      }
      return <MlsDeviceRef>{
        for (final leaf in _requiredDevice().groupMembers(conversationId))
          (
            accountId: utf8.decode(leaf.accountId),
            deviceId: utf8.decode(leaf.deviceId)
          ),
      };
    });
    final budget = Stopwatch()..start();
    final missing = <MlsDeviceRef>[];
    // The server's member list and every account the tree already holds: an
    // account the server leaves out cannot hide its new device this way.
    final accounts = <String>{
      ...accountIds,
      for (final ref in present) ref.accountId,
    }..removeAll(excluding);
    for (final account in accounts) {
      final remaining = deviceListGroupBudget - budget.elapsed;
      List<DeviceListPair> pairs;
      try {
        pairs = remaining > Duration.zero
            ? await pins.approvedDevices(account).timeout(
                remaining < deviceListJudgeTimeout
                    ? remaining
                    : deviceListJudgeTimeout)
            : await pins.approvedDevices(account, refreshFirst: false);
      } on Object {
        // A failed refresh cannot invent additions. Existing pins still work.
        pairs = await pins.approvedDevices(account, refreshFirst: false);
      }
      for (final pair in pairs) {
        final ref = (accountId: account, deviceId: utf8.decode(pair.deviceId));
        if (!present.contains(ref)) missing.add(ref);
      }
    }
    return missing;
  }

  @override
  DeviceListChainResult checkChain(
          String accountId, List<List<int>> statements) =>
      bindings.checkDeviceListChain(idBytes(accountId), statements);

  @override
  DeviceListSummary checkStep({
    required String accountId,
    required List<int>? prev,
    required List<int> statement,
    required List<DeviceListPair> history,
  }) =>
      bindings.checkDeviceListStep(
          expectedAccountId: idBytes(accountId),
          prev: prev,
          statement: statement,
          history: history);

  @override
  Future<Uint8List> signDeviceList(DeviceListBody body) => _serial(() async {
        final device = _requiredDevice();
        final deviceId = _deviceId;
        if (deviceId == null) throw StateError('no device identity');
        return device.signDeviceList(body, idBytes(deviceId));
      });

  @override
  Future<Uint8List> currentSigningKey() => _serial(
      () async => Uint8List.fromList(_requiredDevice().signingPublicKey()));

  @override
  Future<void> holdRecoveryListSeed(Uint8List entropy) => _serial(() async {
        final device = _device;
        // The seed must be in the record before the pending state is sealed
        // once (the sealed state is reused as is).
        if (!_pendingEnrollment || device == null || _firstState != null) {
          throw StateError('no unsealed pending enrollment identity');
        }
        device.holdRecoveryListSeed(entropy);
      });

  @override
  Future<Uint8List> signRecoveryDeviceList({
    required List<int> prev,
    required DeviceListBody body,
    required List<DeviceListPair> history,
    Uint8List? entropy,
  }) =>
      _serial(() async {
        final previous = await _requiredState();
        try {
          final statement = _requiredDevice().signRecoveryDeviceList(
              prev: prev, body: body, history: history, entropy: entropy);
          // A held seed was dropped by the signing: store that at once.
          if (entropy == null) {
            await localStore.commitLocalMlsState(
              expectedCounter: previous.counter,
              expectedCursor: await localStore.loadSyncCursor(),
              state: _sealNext(previous),
            );
          }
          return statement;
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<bool> dropRecoveryListHold() => _serial(() async {
        final previous = await _requiredState();
        try {
          final dropped = _requiredDevice().dropRecoveryListHold();
          if (dropped) {
            await localStore.commitLocalMlsState(
              expectedCounter: previous.counter,
              expectedCursor: await localStore.loadSyncCursor(),
              state: _sealNext(previous),
            );
          }
          return dropped;
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  /// How long one leaf judgment may wait for the server before it is
  /// recorded as "checking" (the commit is applied either way, D94).
  static const Duration deviceListJudgeTimeout = Duration(seconds: 10);

  /// The most one group judgment spends waiting for the server; leaves
  /// judged after that read only the stored pins.
  static const Duration deviceListGroupBudget = Duration(seconds: 15);

  Future<LeafVerdict> _judgeLeaf(LeafPair leaf, {bool network = true}) async {
    final accountId = _accountId;
    final deviceId = _deviceId;
    if (accountId != null &&
        deviceId != null &&
        _sameBytes(leaf.accountId, idBytes(accountId)) &&
        _sameBytes(leaf.deviceId, idBytes(deviceId))) {
      // This device's own leaf; a twin with another key is judged below.
      final own = _device?.signingPublicKey();
      if (own != null && _sameBytes(own, leaf.signingKey)) {
        return LeafVerdict.approved;
      }
      return LeafVerdict.unapproved;
    }
    final pins = _deviceListPins;
    if (pins == null) return LeafVerdict.checking;
    try {
      final verdict = await pins
          .judge(leaf.accountId, leaf.deviceId, leaf.signingKey,
              refreshFirst: network)
          .timeout(deviceListJudgeTimeout);
      if (verdict == LeafVerdict.approved &&
          await _alertedPastPin(leaf.accountId)) {
        return LeafVerdict.checking;
      }
      return verdict;
    } on Object {
      return LeafVerdict.checking;
    }
  }

  /// L2-5: the setting holding, per alerting device of [accountId], the
  /// highest list head that device named in a `device_list_alert`: one line
  /// `<head>:<list id hex>:<alerting device id>` per device (a single line
  /// is the format from before review M3, read the same way).
  static String alertHeadSetting(String accountId) =>
      'l2.alert_head.$accountId';

  /// At most this many alerting devices are kept per account; the lowest
  /// heads go first. An account's approved devices bound it in practice.
  static const int maxAlertsPerAccount = 32;

  /// L2-5: the setting holding the own list head this device last alerted
  /// [conversationId] about.
  static String alertSentSetting(String conversationId) =>
      'l2.alert_sent.$conversationId';

  /// Conversations whose last judgment found a leaf of this device's own
  /// account that its list does not approve (L2-5).
  final Set<String> _ownAlertsDue = <String>{};

  /// The heads, list ids and alerting devices kept by [alertHeadSetting].
  Future<List<({int head, String listId, String deviceId})>> _alerted(
      String accountId) async {
    final value = await localStore.loadSetting(alertHeadSetting(accountId));
    if (value == null) return const [];
    final out = <({int head, String listId, String deviceId})>[];
    for (final line in value.split('\n')) {
      final first = line.indexOf(':');
      final second = first < 0 ? -1 : line.indexOf(':', first + 1);
      if (second < 0) continue;
      final head = int.tryParse(line.substring(0, first));
      if (head == null) continue;
      out.add((
        head: head,
        listId: line.substring(first + 1, second),
        deviceId: line.substring(second + 1),
      ));
    }
    return out;
  }

  /// Whether one stored alert still holds [pin]'s account (L2-5):
  ///
  /// - with no pin, yes (nothing shows the head is known);
  /// - once the pin shows the alerting device removed, no: a rogue device
  ///   that alerts a head never published holds its account's leaves only
  ///   until the account removes it;
  /// - for the pinned list, while the pin is below the alerted head;
  /// - for another list id, while the pin lists the alerting device: the
  ///   server shows this device another genesis than the one the account's
  ///   own device holds (held as `checking`, never a sticky conflict, owner
  ///   decision 2026-11-08, L1-3 question 3). A pin that does not list the
  ///   alerter at all is a list restarted from a new genesis (or one that
  ///   never knew it): the old alert names nothing in it and stops counting
  ///   (review M3), so it cannot hold the account's leaves for good.
  static bool _alertHolds(
      ({int head, String listId, String deviceId}) alert, DeviceListPin? pin) {
    if (pin == null) return true;
    final alerter = utf8.encode(alert.deviceId);
    final rows =
        pin.keys.where((key) => _sameBytes(key.deviceId, alerter)).toList();
    if (rows.any((key) => key.removedVersion != 0)) return false;
    if (_hex(pin.listId) == alert.listId) return pin.version < alert.head;
    return rows.isNotEmpty;
  }

  /// Whether a device of [accountId] alerted a list head newer than this
  /// device's pin, or a list other than the pinned one ([_alertHolds]): the
  /// server has not shown this device the list the account's own device
  /// holds, so no leaf of the account is approved until it does (L2-5).
  Future<bool> _alertedPastPin(List<int> accountId) async {
    final String account;
    try {
      account = utf8.decode(accountId);
    } on FormatException {
      return false;
    }
    final alerts = await _alerted(account);
    if (alerts.isEmpty) return false;
    final pin = await localStore.loadDeviceListPin(account);
    return alerts.any((alert) => _alertHolds(alert, pin));
  }

  /// L2-5 receive: an approved device of [accountId] says the account's
  /// list head is [headVersion] and that a leaf of it in [conversationId]
  /// is not on it. The head is kept per alerting device (only ever raised
  /// for the same list), so one device's inflated head never drops another
  /// device's honest alert (review M3); alerts that no longer hold (their
  /// device removed, the pin caught up, or a list that does not list them)
  /// are dropped. The list is fetched again past the rate limit and the
  /// group is judged again: a fork of the pinned chain becomes `conflict`
  /// (L1), and a head the server keeps from this device holds the account's
  /// leaves as `checking`. Never throws; it runs after the message's
  /// transition has committed.
  Future<void> _applyDeviceListAlert(String conversationId, String accountId,
      String deviceId, int headVersion, String listId) async {
    try {
      if (!deviceId.contains('\n')) {
        final pin = await localStore.loadDeviceListPin(accountId);
        final kept = [
          for (final alert in await _alerted(accountId))
            if (alert.deviceId != deviceId && _alertHolds(alert, pin)) alert,
        ];
        final own = (await _alerted(accountId))
            .where((alert) => alert.deviceId == deviceId)
            .firstOrNull;
        final next =
            own == null || own.listId != listId || headVersion > own.head
                ? (head: headVersion, listId: listId, deviceId: deviceId)
                : own;
        if (_alertHolds(next, pin)) kept.add(next);
        kept.sort((a, b) => b.head.compareTo(a.head));
        final value = [
          for (final alert in kept.take(maxAlertsPerAccount))
            '${alert.head}:${alert.listId}:${alert.deviceId}',
        ].join('\n');
        await localStore.saveSetting(alertHeadSetting(accountId), value);
      }
      final pins = _deviceListPins;
      if (pins != null) {
        pins.invalidate(accountId);
        await pins
            .refresh(accountId, force: true)
            .timeout(deviceListJudgeTimeout);
      }
      final change = await _judgeGroup(conversationId);
      await _saveApprovalLeaves(change);
    } on Object {
      // Best effort: the stored heads still apply at the next judgment.
    }
  }

  /// L2-5 send: the alerts this device owes, one per conversation and own
  /// list head. Each body names this account, its pinned head version and
  /// list id. A conversation already alerted at the current head is left
  /// out. Call [markOwnDeviceAlertSent] once the alert is queued.
  @override
  Future<List<({String conversationId, Map<String, Object?> body})>>
      ownDeviceAlertsDue() async {
    final accountId = _accountId;
    if (accountId == null || _ownAlertsDue.isEmpty) return const [];
    final pin = await localStore.loadDeviceListPin(accountId);
    if (pin == null) return const [];
    final due = <({String conversationId, Map<String, Object?> body})>[];
    for (final conversationId in _ownAlertsDue.toList()) {
      final sent =
          await localStore.loadSetting(alertSentSetting(conversationId));
      if (sent == '${pin.version}') {
        _ownAlertsDue.remove(conversationId);
        continue;
      }
      due.add((
        conversationId: conversationId,
        body: <String, Object?>{
          'account_id': accountId,
          'head_version': pin.version,
          'list_id': _hex(pin.listId),
        },
      ));
    }
    return due;
  }

  /// Records that [conversationId] was alerted at own list head
  /// [headVersion], so the same alert is not sent again.
  @override
  Future<void> markOwnDeviceAlertSent(
      String conversationId, int headVersion) async {
    await localStore.saveSetting(
        alertSentSetting(conversationId), '$headVersion');
    _ownAlertsDue.remove(conversationId);
  }

  /// Judges every leaf against the current pins (D94). Cached approval is
  /// never authority after a signed removal or fork becomes known.
  ///
  /// The conversation's participants (when the app knows them) bound the
  /// roster: with [welcome] every leaf of an account that is not a
  /// participant is unapproved whatever its list says, and on any later
  /// judgment a leaf that was not approved before must still pass that
  /// check to become approved, so a re-judge by list alone can never undo
  /// the Welcome's roster check. A leaf new to the group after a commit is
  /// judged by its list only (the design's rule for commits).
  Future<ApprovalLeafChange> _judgeGroup(
    String conversationId, {
    bool welcome = false,
  }) async {
    final leaves = _requiredDevice().groupMembers(conversationId);
    final previous = await localStore.loadApprovalLeaves(conversationId);
    final participants = _participantsOf(conversationId);
    final now = _clock().toUtc().millisecondsSinceEpoch;
    final budget = Stopwatch()..start();
    final rows = <ApprovalLeaf>[];
    for (final leaf in leaves) {
      final wasHeld = previous.any(
        (row) =>
            row.sameLeaf(leaf.accountId, leaf.deviceId) &&
            row.verdict != LeafVerdict.approved,
      );
      var verdict = await _judgeLeaf(
        leaf,
        network: budget.elapsed < deviceListGroupBudget,
      );
      if (participants != null &&
          (welcome || wasHeld) &&
          verdict == LeafVerdict.approved) {
        String? account;
        try {
          account = utf8.decode(leaf.accountId);
        } on FormatException {
          account = null;
        }
        if (account == null || !participants.contains(account)) {
          verdict = LeafVerdict.unapproved;
        }
      }
      rows.add(
        ApprovalLeaf(
          conversationId: conversationId,
          accountId: leaf.accountId,
          deviceId: leaf.deviceId,
          signingKey: leaf.signingKey,
          verdict: verdict,
          updatedAt: now,
        ),
      );
    }
    // L2-5: a leaf of this device's own account that its own list does not
    // approve (never listed, listed after its removal, or a twin of this
    // device with another key) is reported to the group.
    final own = _accountId;
    if (own != null &&
        rows.any((row) =>
            row.verdict == LeafVerdict.unapproved &&
            _sameBytes(row.accountId, idBytes(own)))) {
      _ownAlertsDue.add(conversationId);
    }
    return ApprovalLeafChange(
      conversationId: conversationId,
      leaves: rows,
      replaceAll: true,
    );
  }

  /// The participants a Welcome's roster must stay within, or null when the
  /// app has not told this service (then only the lists are checked).
  Set<String>? _participantsOf(String conversationId) {
    final members = _authority?.memberAccounts(conversationId);
    if (members == null || members.isEmpty) return null;
    return {...members, if (_accountId != null) _accountId!};
  }

  /// Whether [conversationId] is held for an unapproved, removed or
  /// undecided leaf (the approval hold, D94). A group never judged (from
  /// before L1, or whose rows a crash lost) is judged now; all leaves are
  /// judged again, so a list that now removes or approves them, or a
  /// commit that removed them, releases the hold from local evidence only.
  @override
  Future<bool> refreshApprovalHold(String conversationId) =>
      _serial(() => _refreshApprovalHold(conversationId));

  Future<bool> _refreshApprovalHold(String conversationId) async {
    if (!await _hasGroup(conversationId)) return false;
    final change = await _judgeGroup(conversationId);
    await _saveApprovalLeaves(change);
    return change.leaves.any((row) => row.verdict != LeafVerdict.approved);
  }

  Future<bool> _hasGroup(String conversationId) async {
    try {
      _requiredDevice().groupEpoch(conversationId);
      return true;
    } on NativeCryptoException {
      return false;
    }
  }

  /// Refuses to encrypt anything to [conversationId] while it is held.
  Future<void> _requireApproved(String conversationId) async {
    if (await _refreshApprovalHold(conversationId)) {
      throw ConversationApprovalHeldException(conversationId);
    }
  }

  /// What the sender leaf of a received message was judged (D94). A group
  /// is judged again even when the sender was approved previously: the
  /// latest pin may remove it or be in conflict.
  Future<LeafVerdict> _senderVerdict(
    String conversationId,
    String accountId,
    String deviceId,
  ) async {
    final change = await _judgeGroup(conversationId);
    await _saveApprovalLeaves(change);
    final row = change.leaves
        .where((row) => row.sameLeaf(idBytes(accountId), idBytes(deviceId)))
        .firstOrNull;
    return row?.verdict ?? LeafVerdict.unapproved;
  }

  /// The keyed adds the pins approve, each with the key the pin lists (never
  /// one the server sent). Packages of devices not approved now are left
  /// out; reconcile offers them again later.
  Future<List<({DeviceKeyPackage package, Uint8List signingKey})>> _gateAdds(
      List<DeviceKeyPackage> adds) async {
    final pins = _deviceListPins;
    if (pins == null) return const [];
    final out = <({DeviceKeyPackage package, Uint8List signingKey})>[];
    for (final package in adds) {
      Uint8List? key;
      try {
        key = await pins
            .approvedKey(package.accountId, package.deviceId)
            .timeout(deviceListJudgeTimeout);
      } on Object {
        key = null;
      }
      if (key != null) out.add((package: package, signingKey: key));
    }
    return out;
  }

  /// Writes this device's view of the group after its own commit merged.
  /// Not atomic with the merge: if it is lost, the group has no rows and is
  /// judged before it is next used (fail closed).
  Future<void> _rejudgeAfterOwnCommit(String conversationId) async {
    try {
      if (!await _hasGroup(conversationId)) return;
      await _saveApprovalLeaves(await _judgeGroup(conversationId));
    } on Object {
      // Judged again before the next send.
    }
  }

  @override
  Future<StoredCryptoState> sealPendingEnrollment() => _serial(() async {
        final device = _device;
        if (!_pendingEnrollment || device == null) {
          throw StateError('no pending enrollment identity');
        }
        // Sealed once: a second seal would move the generation, so the
        // activation stores exactly this state (as for [_firstState]).
        final first = _firstState ??= () {
          final key = _randomBytes(32);
          return _sealedState(1, key, device.sealChanges(key, 1));
        }();
        return _copyState(first);
      });

  @override
  Future<void> resumePendingEnrollment({
    required String accountId,
    required String deviceId,
    required StoredCryptoState state,
  }) =>
      _serial(() async {
        if (state.counter != 1 || state.stateKey.length != 32) {
          throw StateError('pending enrollment state is invalid');
        }
        // A frozen pre-join state whose identity was promoted once must not
        // open again, whatever the active MLS state is (finding 4).
        await _refusePromoted(accountId, deviceId);
        final restored = _formatChecked(() => bindings.restoreRecords(accountId,
                deviceId, state.stateKey, state.counter, state.sealedState, [
              for (final change in state.changes)
                if (change.sealed != null) change.sealed!
            ]));
        if (restored.generation != state.counter) {
          restored.device.close();
          throw StateError('MLS rollback counter mismatch');
        }
        noticeCaptureEnabled = false;
        _noticeOrigin = null;
        _device?.close();
        _closeCallGroups();
        _device = restored.device;
        _verdictCache.clear();
        _deviceCounter = null;
        _accountId = accountId;
        _deviceId = deviceId;
        _pendingEnrollment = true;
        _firstState = _copyState(state);
      });

  @override
  Future<void> abandonPendingEnrollment() => _serial(() async {
        if (!_pendingEnrollment) return;
        _device?.close();
        _closeCallGroups();
        _device = null;
        _verdictCache.clear();
        _deviceCounter = null;
        final first = _firstState;
        if (first != null) {
          first.stateKey.fillRange(0, first.stateKey.length, 0);
        }
        _firstState = null;
        _accountId = null;
        _deviceId = null;
        _pendingEnrollment = false;
      });

  static StoredCryptoState _copyState(StoredCryptoState state) =>
      StoredCryptoState(
        counter: state.counter,
        stateKey: List<int>.from(state.stateKey),
        sealedState: List<int>.from(state.sealedState),
        changes: <CryptoRecordChange>[
          for (final change in state.changes)
            CryptoRecordChange(
              kind: change.kind,
              recordId: List<int>.from(change.recordId),
              generation: change.generation,
              sealed:
                  change.sealed == null ? null : List<int>.from(change.sealed!),
            ),
        ],
      );

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
              _device == null ||
              // Promoted once: its MLS state was lost (a restore, an
              // identity change), and the frozen pending state is no
              // replacement for it (finding 4).
              await localStore.isEnrollmentPromoted(
                  accountId: accountId, deviceId: deviceId)) {
            throw StateError('protected MLS state is unavailable');
          }
          final first = _firstState ??= () {
            final key = _randomBytes(32);
            return _sealedState(1, key, _device!.sealChanges(key, 1));
          }();
          await localStore.saveCryptoState(
            first,
            await localStore.loadSyncCursor(),
          );
          _firstState = null;
          _deviceCounter = 1;
        } else {
          // A state is stored, so the first save committed (its outcome
          // may have been lost): the copy and its key are never needed.
          _firstState = null;
          _device?.close();
          _closeCallGroups();
          _device = null;
          _verdictCache.clear();
          final restored = await _openStored(accountId, deviceId, stored);
          _device = restored.device;
          _verdictCache.clear();
          _deviceCounter = restored.counter;
        }
        _adoptNoticeOrigin(origin, accountId, deviceId);
        _accountId = accountId;
        _deviceId = deviceId;
        _pendingEnrollment = false;
      });

  @override
  Future<EnrollmentPromotionOutcome> promotePendingEnrollment(
    Session session, {
    required String kind,
    required String promotionId,
    HistoryTransferProgress? transfer,
  }) =>
      _serial(() async {
        final origin = canonicalizeServerOrigin(session.baseUrl);
        final accountId = session.accountId;
        final deviceId = session.deviceId;
        if (accountId == null ||
            accountId.isEmpty ||
            deviceId == null ||
            deviceId.isEmpty ||
            session.token.isEmpty) {
          throw StateError('authenticated device identity is unavailable');
        }
        final first = _firstState;
        if (!_pendingEnrollment ||
            _device == null ||
            first == null ||
            _accountId != accountId ||
            _deviceId != deviceId) {
          throw StateError('no pending enrollment identity');
        }
        // The store checks the pending row, the ledger, the MLS state and
        // the session in the same transaction that writes them.
        final outcome =
            await localStore.promotePendingEnrollment(EnrollmentPromotion(
          kind: kind,
          session: session,
          promotionId: promotionId,
          expectedState: first,
          promotedAt: _clock().toUtc(),
          transfer: transfer,
        ));
        if (outcome == EnrollmentPromotionOutcome.promoted) {
          // The device in memory is exactly the state just stored.
          _firstState = null;
          _deviceCounter = first.counter;
        } else {
          // An earlier promotion committed: the stored state is the
          // identity, and the frozen one is never used again.
          _device?.close();
          _closeCallGroups();
          _device = null;
          _verdictCache.clear();
          _deviceCounter = null;
          first.stateKey.fillRange(0, first.stateKey.length, 0);
          _firstState = null;
          _pendingEnrollment = false;
          final stored = await localStore.loadCryptoState();
          if (stored == null) {
            throw StateError('protected MLS state is unavailable');
          }
          final restored = await _openStored(accountId, deviceId, stored);
          _device = restored.device;
          _verdictCache.clear();
          _deviceCounter = restored.counter;
        }
        _adoptNoticeOrigin(origin, accountId, deviceId);
        _accountId = accountId;
        _deviceId = deviceId;
        _pendingEnrollment = false;
        return outcome;
      });

  Future<void> _refusePromoted(String accountId, String deviceId) async {
    if (await localStore.isEnrollmentPromoted(
        accountId: accountId, deviceId: deviceId)) {
      throw StateError('this enrollment was already promoted');
    }
  }

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
        final restored = await _openStored(accountId, deviceId, stored,
            checkCanCommit: checkCanCommit);
        var adopted = false;
        try {
          checkCanCommit();
          _device?.close();
          _closeCallGroups();
          _device = restored.device;
          _verdictCache.clear();
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
          final device = _requiredDevice();
          // The pool holds at most 1,000 packages (D70). Expired ones are
          // dropped first, so a full pool frees up as they expire instead
          // of refusing every replenishment until a later sync prunes.
          device.pruneKeyPackages(_clock());
          final packages = <List<int>>[];
          for (var index = 0; index < count; index++) {
            try {
              packages.add(device.createKeyPackage());
            } on NativeCryptoException {
              // The pool is full (or a key failed): keep the packages
              // already made, so a pool with a few free places still
              // fills them. The caller settles only what it gets; the rest
              // stays owed.
              if (packages.isEmpty || !_handleAnswers()) rethrow;
              break;
            }
          }
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
      _gateAdds(claimedPackages).then((approved) => _serial(() async {
            final previous = await _requiredState();
            try {
              final device = _requiredDevice();
              // C4: a group or a community's shared group starts with the
              // genesis record (its creator owns it); a DM and a private
              // channel's group carry none.
              if (roleRecordKinds
                  .contains(_authority?.conversationKind(conversationId))) {
                device.createGroupWithRoles(
                    conversationId,
                    encodeGovernance(
                        GovernanceState.genesis(_requiredAccount())));
              } else {
                device.createGroup(conversationId);
              }
              // One staged commit adds everyone (card I51). With nobody else to
              // add, the bundle only records this device as the group's first
              // member, so later devices can be added by reconcile. A device
              // the approved-device lists do not approve now is left out and
              // added by reconcile once they do (L1, D94).
              final bundle = approved.isEmpty
                  ? const MlsCommitBundle(epoch: 0)
                  : _stage(device, conversationId,
                      adds: approved,
                      record:
                          await _plannedRecord(conversationId, adds: approved));
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
          }));

  @override
  Future<void> stageMembershipChange(
    String conversationId, {
    List<DeviceKeyPackage> adds = const <DeviceKeyPackage>[],
    List<MlsDeviceRef> removes = const <MlsDeviceRef>[],
  }) =>
      _gateAdds(adds).then((approved) => _serial(() async {
            if (adds.isEmpty && removes.isEmpty) {
              throw ArgumentError('a membership change needs a device');
            }
            if (approved.isEmpty && removes.isEmpty) {
              // No device of this change is on its account's approved-device
              // list now: nothing is staged and the change stays pending.
              throw DeviceListNotApprovedException(
                  [for (final add in adds) add.deviceId]);
            }
            await _requireNotPaused(conversationId);
            // C4: a removal that would prune a governing account and that
            // this device cannot prove stays pending for a device that can.
            final proven = await _provenRemoves(conversationId, removes);
            if (approved.isEmpty && proven.isEmpty) {
              throw GovernanceRemovalUnprovenException(conversationId);
            }
            final previous = await _requiredState();
            try {
              final bundle = _stage(_requiredDevice(), conversationId,
                  adds: approved,
                  removes: proven,
                  record: await _plannedRecord(conversationId,
                      adds: approved, removes: proven),
                  leaveStatements:
                      await _leaveStatementsFor(conversationId, proven));
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
          }));

  @override
  Future<void> stageSelfUpdate(String conversationId) => _serial(() async {
        await _requireNotPaused(conversationId);
        // A fresh path secret would be encrypted to every leaf (D94).
        await _requireApproved(conversationId);
        final previous = await _requiredState();
        try {
          // C4: receivers refuse an owner commit that leaves an election
          // open, and a path-only self-update carries no record, so while
          // one is open the owner's update is the cancel.
          final cancel = _ownerCancelRecord(conversationId);
          if (cancel != null) {
            final bundle =
                _stage(_requiredDevice(), conversationId, record: cancel);
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
            return;
          }
          final staged = _requiredDevice().stageSelfUpdate(conversationId);
          if (staged.commit.isEmpty || staged.welcome.isNotEmpty) {
            throw StateError('MLS self-update output is invalid');
          }
          await localStore.commitOutgoingMlsTransition(
            OutgoingMlsStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: await localStore.loadSyncCursor(),
              state: _sealNext(previous),
              messages: <PendingMlsMessage>[
                _bundleItem(
                  conversationId,
                  MlsCommitBundle(epoch: staged.epoch, commit: staged.commit),
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
  Future<void> completeCommitBundle(PendingMlsMessage item) =>
      _serial(() async {
        final bundle = MlsCommitBundle.decode(item.payload);
        await _requireNotPaused(item.conversationId);
        // Sync may have merged this accepted commit while the outbox worker
        // waited for the server's answer, settling its entry, and later
        // commits may have moved the group on since. Nothing is left to do,
        // and the epoch check below would see a fork that is not there.
        if (!await _isQueuedBundle(item)) return;
        final previous = await _requiredState();
        try {
          int? infoRemovalEpoch;
          var c7Settings = const <String, String?>{};
          if (bundle.hasCommit) {
            final device = _requiredDevice();
            final ({int epoch, bool pending}) before;
            try {
              before = device.groupEpoch(item.conversationId);
            } on NativeCryptoException {
              // The group is gone: the user left or deleted the chat (D70),
              // or this device was removed. Nothing is left to merge, and
              // the entry settles instead of failing on every retry. A
              // group that is stored but failed to load is not gone.
              if (!await _groupGone(previous, item.conversationId)) rethrow;
              await localStore.commitLocalMlsState(
                expectedCounter: previous.counter,
                expectedCursor: await localStore.loadSyncCursor(),
                state: _sealNext(previous),
                resolvedMlsOutboxKey: item.idempotencyKey,
              );
              return;
            }
            if (before.pending) {
              final outcome = device.c7MergePendingCommit(item.conversationId);
              try {
                if (outcome.removedAny && !outcome.removedSelf) {
                  infoRemovalEpoch = outcome.newEpoch;
                }
                c7Settings =
                    await _c7Commit(item.conversationId, outcome, own: true);
              } finally {
                outcome.wipeRoot();
              }
            }
            final after = device.groupEpoch(item.conversationId);
            // Fail closed if the group is not where the accepted commit
            // leads: that would mean a fork.
            if (after.pending || after.epoch != bundle.epoch + 1) {
              throw StateError('accepted MLS commit does not match the group');
            }
          }
          final own = bundle.hasCommit
              ? _ownCommitEffects(item.conversationId, bundle)
              : (
                  observation: null,
                  settings: const <String, String?>{},
                );
          await localStore.commitLocalMlsState(
            governanceObservation: own.observation,
            expectedCounter: previous.counter,
            expectedCursor: await localStore.loadSyncCursor(),
            state: _sealNext(previous),
            resolvedMlsOutboxKey: item.idempotencyKey,
            // C4 proofs share the C7 settings channel.
            c7Settings: <String, String?>{...c7Settings, ...own.settings},
            infoRemoval: infoRemovalEpoch == null
                ? null
                : (
                    conversationId: item.conversationId,
                    epoch: infoRemovalEpoch
                  ),
          );
          if (bundle.hasCommit) {
            await _rejudgeAfterOwnCommit(item.conversationId);
          }
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  @override
  Future<void> abandonCommitBundle(PendingMlsMessage item) => _serial(() async {
        final bundle = MlsCommitBundle.decode(item.payload);
        await _requireNotPaused(item.conversationId);
        // Already settled: a commit staged since belongs to a newer entry,
        // so clearing the pending commit here would drop that one instead.
        if (!await _isQueuedBundle(item)) return;
        final previous = await _requiredState();
        try {
          if (bundle.hasCommit) {
            final device = _requiredDevice();
            ({int epoch, bool pending})? status;
            try {
              status = device.groupEpoch(item.conversationId);
            } on NativeCryptoException {
              // The group is gone (this device was removed, or the chat
              // deleted, D70): nothing is pending, and the entry settles.
              // A group that is stored but failed to load is not gone.
              if (!await _groupGone(previous, item.conversationId)) rethrow;
              status = null;
            }
            // Only a commit pending on the bundle's own epoch is this
            // bundle's. Sync may have applied another device's winning
            // commit meanwhile without settling this entry, and a commit
            // staged after that is newer: keep it.
            if (status != null &&
                status.pending &&
                status.epoch == bundle.epoch) {
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

  /// Drops key packages that expired more than 24 hours before [now] and
  /// stores the change (D70). Returns how many went. AppState calls it
  /// after a caught-up foreground sync pass (S4).
  @override
  Future<int> pruneExpiredKeyPackages(DateTime now) => _serial(() async {
        final previous = await _requiredState();
        try {
          final removed = _requiredDevice().pruneKeyPackages(now);
          if (removed > 0) await _commitLocalMutation(previous);
          return removed;
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

  /// Drops this device's state for a conversation the user left or
  /// deleted (D70), stores the change, then settles that conversation's
  /// queued MLS control messages: with no group, a queued commit could only
  /// fail. Only a user action may call this, never a server event: a
  /// removal already dropped the group. Returns whether a group was stored.
  @override
  Future<bool> deleteConversationState(String conversationId) =>
      _serial(() async {
        final previous = await _requiredState();
        final bool deleted;
        try {
          deleted = _requiredDevice().deleteGroup(conversationId);
          if (deleted) await _commitLocalMutation(previous);
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
        // After the group is gone. A crash in between leaves entries that
        // settle on their own: [completeCommitBundle] and
        // [abandonCommitBundle] settle a bundle whose group is missing.
        for (final queued in await localStore.pendingMlsMessages()) {
          if (queued.conversationId == conversationId) {
            await localStore.removePendingMlsMessage(queued.idempotencyKey);
          }
        }
        return deleted;
      });

  /// Whether [item] is still an unsettled entry of the MLS outbox. Run only
  /// inside [_serial], so sync cannot settle it between this check and the
  /// change that follows.
  Future<bool> _isQueuedBundle(PendingMlsMessage item) async =>
      (await localStore.pendingMlsMessages()).any((queued) =>
          queued.kind == MlsCommitBundle.kind &&
          queued.idempotencyKey == item.idempotencyKey);

  @override
  Future<({int epoch, bool pending})?> groupEpoch(String conversationId) =>
      _serial(() async {
        try {
          return _requiredDevice().groupEpoch(conversationId);
        } on NativeCryptoException {
          // A missing group and a handle a native panic left poisoned both
          // answer operationFailed. A call that takes the same device lock
          // tells them apart: if it succeeds and the handle holds the
          // committed state, the group is simply missing. Otherwise reload
          // the committed state and ask once more, so a poisoned or stale
          // handle never reads as "no group" and is not kept.
          final stored = await localStore.loadCryptoState();
          if (stored == null) return null;
          if (stored.counter == _deviceCounter && _handleAnswers()) {
            return null;
          }
          await _restorePrevious(stored);
        }
        try {
          return _requiredDevice().groupEpoch(conversationId);
        } on NativeCryptoException {
          return null;
        }
      });

  /// Whether a group lookup that failed means the group is truly gone: the
  /// handle answers, it holds the committed state ([previous]), and the
  /// stored records have no group record for [conversationId]. Anything
  /// else (a poisoned or stale handle, a stored group that failed to load)
  /// is not a missing group.
  Future<bool> _groupGone(
      StoredCryptoState previous, String conversationId) async {
    if (!_handleAnswers() || _deviceCounter != previous.counter) return false;
    final stored = await localStore.loadCryptoState();
    if (stored == null || stored.counter != previous.counter) return false;
    // The bytes the bindings send as the group id: the low byte of each
    // code unit (they refuse an id with a unit above 0xff before any call).
    final id = [for (final unit in conversationId.codeUnits) unit & 0xff];
    return !(await localStore.loadCryptoRecords()).any((record) =>
        record.kind == cryptoRecordKindGroup &&
        _sameBytes(record.recordId, id));
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Whether the device handle still answers a call that takes its lock
  /// (`with_device` in `crypto/rust/src/ffi.rs`). A native panic poisons that
  /// lock, after which every call fails.
  bool _handleAnswers() {
    try {
      _requiredDevice().signingPublicKey();
      return true;
    } on NativeCryptoException {
      return false;
    }
  }

  /// Stages a commit with change list version 2 (L1, ABI 14): every add
  /// names the signing key the approved-device list pins for it, and Rust
  /// refuses a key package that holds another. [adds] come only from
  /// [_gateAdds].
  MlsCommitBundle _stage(
    NativeCryptoDevice device,
    String conversationId, {
    List<({DeviceKeyPackage package, Uint8List signingKey})> adds = const [],
    List<MlsDeviceRef> removes = const <MlsDeviceRef>[],
    String? revocationDeviceId,
    GovernanceState? record,
    List<Uint8List> leaveStatements = const <Uint8List>[],
  }) {
    final keyedAdds = [
      for (final add in adds)
        (
          keyPackage: add.package.keyPackage,
          accountId: idBytes(add.package.accountId),
          deviceId: idBytes(add.package.deviceId),
          signingKey: add.signingKey,
        ),
    ];
    final keyedRemoves = [
      for (final remove in removes)
        (
          accountId: idBytes(remove.accountId),
          deviceId: idBytes(remove.deviceId),
        ),
    ];
    // C4: a commit whose record must change carries it ([_plannedRecord]).
    ({List<int> commit, List<int> welcome, int epoch}) plain() => record == null
        ? device.stageCommitKeyed(conversationId,
            adds: keyedAdds, removes: keyedRemoves)
        : device.stageCommitWithRoles(conversationId,
            record: encodeGovernance(record),
            adds: keyedAdds,
            removes: keyedRemoves);
    // C4 leave proof in the commit (ABI 24): the leavers' own statements
    // ride in the commit's authenticated data. Best effort: a list Rust
    // refuses is dropped and the commit goes as before.
    ({List<int> commit, List<int> welcome, int epoch}) staged;
    if (leaveStatements.isEmpty || keyedRemoves.isEmpty) {
      staged = plain();
    } else {
      try {
        staged = device.stageCommitProven(conversationId,
            record: record == null ? null : encodeGovernance(record),
            leaveStatements: leaveStatements,
            adds: keyedAdds,
            removes: keyedRemoves);
      } on NativeCryptoException catch (error) {
        if (error.kind != NativeCryptoError.invalidArgument) rethrow;
        staged = plain();
      }
    }
    return MlsCommitBundle(
      epoch: staged.epoch,
      commit: staged.commit,
      welcome: staged.welcome,
      added: <MlsDeviceRef>[
        for (final add in adds)
          (accountId: add.package.accountId, deviceId: add.package.deviceId),
      ],
      removed: removes,
      revocationDeviceId: revocationDeviceId,
      roleChange: record != null,
    );
  }

  // C4 role record wiring (docs/crypto.md, "C4 app wiring"). The rules are
  // `validateCommit` and `requiredRecord` in core/roles/governance.dart; the
  // inputs here come from MLS only (the staged review, the tree), never from
  // a server role, label or timestamp.

  /// Conversation kinds whose MLS group carries a role record. A DM has no
  /// roles, and a private channel's group is judged by its community's
  /// shared group.
  static const Set<String> roleRecordKinds = <String>{
    'group',
    'community_shared',
  };

  String _requiredAccount() {
    final account = _accountId;
    if (account == null) throw StateError('no account identity');
    return account;
  }

  static String? _utf8OrNull(List<int> bytes) {
    try {
      final text = utf8.decode(bytes, allowMalformed: false);
      return text.startsWith('\u{FEFF}') ? null : text;
    } on FormatException {
      return null;
    }
  }

  /// The accounts whose every leaf [removes] takes out of [groupId]: the
  /// ones the commit drops from the account roster.
  Set<String> _accountsLeaving(
      NativeCryptoDevice device, String groupId, List<MlsDeviceRef> removes) {
    if (removes.isEmpty) return const <String>{};
    final removing = <String>{
      for (final remove in removes)
        '${remove.accountId}\u0000${remove.deviceId}'
    };
    final touched = <String>{};
    final staying = <String>{};
    for (final leaf in device.groupMembers(groupId)) {
      final account = _utf8OrNull(leaf.accountId);
      final deviceId = _utf8OrNull(leaf.deviceId);
      if (account == null || deviceId == null) continue;
      if (removing.contains('$account\u0000$deviceId')) {
        touched.add(account);
      } else {
        staying.add(account);
      }
    }
    return touched.difference(staying);
  }

  /// Whether [account]'s departure is proven by evidence every member
  /// holds (rules 2 and 3 of the removal proof; a kick, rule 1, is the
  /// caller's): its own `member_leave` in this group since it was last
  /// added, or its own approved-device list having removed every leaf it
  /// has in [leaves]. A list that cannot be read now is retried later.
  ///
  /// [provenLeaves] (C4 leave proof in the commit, ABI 24) are the removed
  /// leaves whose own signed statement the commit carries, verified by Rust
  /// against the tree before it: one of them that is a leaf of [account]
  /// its list approves proves the leave, as its `member_leave` would (owner
  /// decision B: a removed leaf proves nothing).
  Future<bool> _removalProven(
      String groupId, String account, List<LeafPair> leaves,
      {List<LeafPair> provenLeaves = const <LeafPair>[]}) async {
    if (await localStore
            .loadSetting(governanceLeaveSetting(groupId, account)) !=
        null) {
      return true;
    }
    for (final leaf in provenLeaves) {
      if (_utf8OrNull(leaf.accountId) != account) continue;
      final verdict = await _judgeLeaf(leaf);
      if (verdict == LeafVerdict.checking) {
        throw TimeoutException('approved-device list unavailable');
      }
      if (verdict == LeafVerdict.approved) return true;
    }
    final own = leaves.where((leaf) => _utf8OrNull(leaf.accountId) == account);
    if (own.isEmpty) return false;
    for (final leaf in own) {
      final verdict = await _judgeLeaf(leaf);
      if (verdict == LeafVerdict.checking) {
        throw TimeoutException('approved-device list unavailable');
      }
      if (verdict != LeafVerdict.removed) return false;
    }
    return true;
  }

  /// [removes] without the devices of governing accounts this device cannot
  /// prove gone (producer side of the removal proof). Those stay pending on
  /// the server for a device that can: the kicker, or any member once the
  /// leaver's proof or its list arrives.
  Future<List<MlsDeviceRef>> _provenRemoves(
      String groupId, List<MlsDeviceRef> removes) async {
    if (removes.isEmpty) return removes;
    final device = _requiredDevice();
    final bytes = device.groupRoleState(groupId).record;
    if (bytes == null) return removes;
    final record = decodeGovernance(bytes);
    final self = _requiredAccount();
    final leaves = device.groupMembers(groupId);
    final unproven = <String>{};
    for (final gone in _accountsLeaving(device, groupId, removes)) {
      if (!removalNeedsProof(record, gone)) continue;
      if (record.mayActOn(self, gone)) continue;
      if (await _removalProven(groupId, gone, leaves)) continue;
      unproven.add(gone);
    }
    if (unproven.isEmpty) return removes;
    return [
      for (final remove in removes)
        if (!unproven.contains(remove.accountId)) remove,
    ];
  }

  /// Whether this device holds a leave proof of [account] in [groupId]
  /// (its `member_leave`, or its signed statement).
  Future<bool> _holdsLeaveProof(String groupId, String account) async =>
      await localStore.loadSetting(governanceLeaveSetting(groupId, account)) !=
          null ||
      await localStore
              .loadSetting(governanceLeaveSignedSetting(groupId, account)) !=
          null;

  /// The proof settings a removal spends or a re-add voids for [account].
  static Map<String, String?> _leaveProofsCleared(
          String groupId, String account) =>
      <String, String?>{
        governanceLeaveSetting(groupId, account): null,
        governanceLeaveSignedSetting(groupId, account): null,
      };

  /// The signed leave statements this device holds for the accounts
  /// [removes] takes out of the record group [groupId] (C4 leave proof in
  /// the commit): at most one per leaf, at most 16. Rust keeps only those
  /// that still verify and name a leaf the commit removes.
  Future<List<Uint8List>> _leaveStatementsFor(
      String groupId, List<MlsDeviceRef> removes) async {
    if (removes.isEmpty || governanceOf(groupId) == null) {
      return const <Uint8List>[];
    }
    final out = <Uint8List>[];
    final leaves = <int>{};
    for (final account
        in _accountsLeaving(_requiredDevice(), groupId, removes)) {
      final stored = await localStore
          .loadSetting(governanceLeaveSignedSetting(groupId, account));
      if (stored == null) continue;
      final Uint8List statement;
      try {
        statement = base64.decode(stored);
      } on FormatException {
        continue;
      }
      if (!isLeaveStatement(statement) ||
          !leaves.add(leaveStatementLeaf(statement))) {
        continue;
      }
      out.add(statement);
      if (out.length == leaveStatementsMax) break;
    }
    return out;
  }

  /// The record this device's own commit must carry, or null when the group
  /// has none or the commit leaves it unchanged. Runs the receivers' check
  /// on it first, so a commit they would refuse is never staged.
  Future<GovernanceState?> _plannedRecord(
    String groupId, {
    List<({DeviceKeyPackage package, Uint8List signingKey})> adds = const [],
    List<MlsDeviceRef> removes = const <MlsDeviceRef>[],
  }) async {
    final device = _requiredDevice();
    final state = device.groupRoleState(groupId);
    final bytes = state.record;
    if (bytes == null) return null;
    final prev = decodeGovernance(bytes);
    final before = state.accounts;
    if (before == null) throw StateError('group roster is not text');
    final self = _requiredAccount();
    final after = <String>{
      ...before.difference(_accountsLeaving(device, groupId, removes)),
      for (final add in adds) add.package.accountId,
    };
    final next = requiredRecord(prev, self, before: before, after: after);
    final check =
        validateCommit(prev, next, self, before: before, after: after);
    if (!check.ok) throw GovernanceCommandException(check.reject!.name);
    return next == prev ? null : next;
  }

  /// The cancel the owner's next commit must be while an election is open
  /// in [groupId], else null.
  GovernanceState? _ownerCancelRecord(String groupId) {
    final device = _requiredDevice();
    final state = device.groupRoleState(groupId);
    final bytes = state.record;
    if (bytes == null) return null;
    final record = decodeGovernance(bytes);
    if (record.election == null || record.owner != _accountId) return null;
    final roster = state.accounts;
    if (roster == null) return null;
    return requiredRecord(record, _accountId!, before: roster, after: roster);
  }

  /// Phase one's verdict on a remote commit in a record group. Throws
  /// [GovernanceRefusedException] to refuse it, [GovernanceHeldException]
  /// when evidence it needs may still arrive, or a [TimeoutException]
  /// when an approved-device list it depends on cannot be read now (sync
  /// then retries the commit). Returns the observation and settings to
  /// commit with it.
  Future<
          ({
            GovernanceObservationChange? observation,
            Map<String, String?> settings
          })>
      _judgeIncomingCommit(String groupId, IncomingCommitReview review) async {
    final beforeBytes = review.recordBefore;
    final afterBytes = review.recordAfter;
    if (beforeBytes == null) {
      // Rust never lets a group gain a record by proposal.
      if (afterBytes != null) {
        throw const GovernanceRefusedException('record_added');
      }
      return (observation: null, settings: const <String, String?>{});
    }
    if (afterBytes == null) {
      throw const GovernanceRefusedException('record_dropped');
    }
    final GovernanceState prev;
    final GovernanceState next;
    try {
      prev = decodeGovernance(beforeBytes);
      next = decodeGovernance(afterBytes);
    } on Object {
      throw const GovernanceRefusedException('record_unreadable');
    }
    final committer = review.committerAccount;
    final before = review.accountsBefore;
    final after = review.accountsAfter;
    if (committer == null || before == null || after == null) {
      throw const GovernanceRefusedException('ids_not_text');
    }
    final check = validateCommit(prev, next, committer,
        before: before, after: after, epoch: review.epoch);
    if (!check.ok) throw GovernanceRefusedException(check.reject!.name);

    // L1 gate: a leaf on no approved-device list may still commit adds,
    // removals and updates (D94), but it never acts with its account's
    // role: any member can add a leaf under another account's id.
    LeafVerdict? verdict;
    Future<bool> committerApproved() async {
      final judged = verdict ??= await _judgeLeaf(review.committer);
      if (judged == LeafVerdict.checking) {
        throw TimeoutException('approved-device list unavailable');
      }
      return judged == LeafVerdict.approved;
    }

    final expected =
        requiredRecord(prev, committer, before: before, after: after);
    final ownerCancel = committer == prev.owner && prev.election != null;
    // Held, never refused: the committer's list may approve the leaf on a
    // later read (a device linked since the last fetch), so sync applies
    // the commit again by itself. A leaf its list `removed` stays held:
    // nothing orders the removal against the commit (decision B).
    if ((next != expected || ownerCancel) && !await committerApproved()) {
      throw const GovernanceHeldException('committer_unapproved');
    }
    final leaving = before.difference(after);
    final governing =
        leaving.where((account) => removalNeedsProof(prev, account)).toList();
    if (governing.isNotEmpty) {
      final leaves = _requiredDevice().groupMembers(groupId);
      for (final gone in governing) {
        if (prev.mayActOn(committer, gone) && await committerApproved()) {
          continue;
        }
        // Held, never refused: the other members hold the proof this
        // device may lack (a newcomer's Welcome carries none), and the
        // proof or the leaver's list may still arrive.
        if (!await _removalProven(groupId, gone, leaves,
            provenLeaves: review.provenLeaves)) {
          throw const GovernanceHeldException('removal_unproven');
        }
      }
    }
    // C4 (review MEDIUM, round 7): a leave proof is consent to a removal
    // now, not forever. A commit from one of the leaving account's own
    // approved leaves after its proof arrived means the leave did not go
    // through (a cancelled leave voids its statement with a self-update), so
    // both proofs are dropped. A leaf its list does not approve proves
    // nothing either way (it may carry any account's id), so it cannot void
    // an honest leave.
    final voided =
        await _holdsLeaveProof(groupId, committer) && await committerApproved();
    var senderApproved = true;
    if (committer == prev.owner || committer == next.owner) {
      final judged = verdict ?? await _judgeLeaf(review.committer);
      senderApproved = judged == LeafVerdict.approved;
    }
    return (
      observation: GovernanceObservationChange(
        groupId: groupId,
        state: next,
        authenticatedSender: committer,
        receivedAt: _clock().toUtc(),
        senderApproved: senderApproved,
      ),
      // A proof is spent by the removal it proves and void once the
      // account is added again.
      settings: <String, String?>{
        if (voided) ..._leaveProofsCleared(groupId, committer),
        for (final account in leaving) ..._leaveProofsCleared(groupId, account),
        for (final account in after.difference(before))
          ..._leaveProofsCleared(groupId, account),
        // C4 server succession: a won election or claim (the owner set by a
        // commit that is not the owner's). The app then asks the server to
        // move its owner row too; the record has already decided.
        if (next.owner case final heir?
            when heir != prev.owner && committer != prev.owner)
          governanceSuccessionSetting(groupId): governanceSuccessionValue(
            next.rev,
            heir,
          ),
      },
    );
  }

  /// What this device's own accepted commit commits beside the state: the
  /// record's observation, and proofs spent or voided by it.
  ({GovernanceObservationChange? observation, Map<String, String?> settings})
      _ownCommitEffects(String groupId, MlsCommitBundle bundle) {
    GovernanceState? record;
    Set<String>? roster;
    try {
      final state = _requiredDevice().groupRoleState(groupId);
      final bytes = state.record;
      record = bytes == null ? null : decodeGovernance(bytes);
      roster = state.accounts;
    } on Object {
      record = null;
    }
    // C4 leave proof in the commit: this device's own self-update gives it
    // a new leaf, which voids any leave statement it signed before.
    final updated = <String, String?>{
      if (bundle.isUpdateOnly) governanceLeaveSignedOutSetting(groupId): null,
    };
    if (record == null) {
      return (observation: null, settings: updated);
    }
    final settings = <String, String?>{
      ...updated,
      for (final add in bundle.added)
        ..._leaveProofsCleared(groupId, add.accountId),
      for (final remove in bundle.removed)
        if (roster != null && !roster.contains(remove.accountId))
          ..._leaveProofsCleared(groupId, remove.accountId),
    };
    GovernanceObservationChange? observation;
    try {
      observation = GovernanceObservationChange(
        groupId: groupId,
        state: record,
        authenticatedSender: _requiredAccount(),
        receivedAt: _clock().toUtc(),
      );
    } on Object {
      observation = null;
    }
    return (observation: observation, settings: settings);
  }

  /// The observation an application message adds: the owner's posts are
  /// its activity, and a first message starts this device's clocks.
  Future<GovernanceObservationChange?> _applicationObservation(
      String groupId, String sender,
      {required bool approved}) async {
    final record = governanceOf(groupId);
    if (record == null) return null;
    if (sender != record.owner &&
        await localStore.loadGovernanceObservations(groupId) != null) {
      return null;
    }
    try {
      return GovernanceObservationChange(
        groupId: groupId,
        state: record,
        authenticatedSender: sender,
        receivedAt: _clock().toUtc(),
        senderApproved: approved,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<GovernanceView?> governanceView(String groupId) => _serial(() async {
        final device = _device;
        if (device == null) return null;
        final GroupRoleState state;
        try {
          state = device.groupRoleState(groupId);
        } on NativeCryptoException {
          return null;
        }
        final bytes = state.record;
        final roster = state.accounts;
        if (bytes == null || roster == null) return null;
        final GovernanceState record;
        try {
          record = decodeGovernance(bytes);
        } on Object {
          return null;
        }
        return GovernanceView(
          record: record,
          roster: roster,
          observations: await localStore.loadGovernanceObservations(groupId),
        );
      });

  @override
  Future<void> stageRoleChange(
    String groupId,
    GovernanceState Function(GovernanceCommands commands,
            GovernanceObservations? observed, DateTime now)
        build,
  ) =>
      _serial(() async {
        await _requireNotPaused(groupId);
        // A fresh path secret would be encrypted to every leaf (D94).
        await _requireApproved(groupId);
        final device = _requiredDevice();
        if (device.groupEpoch(groupId).pending) {
          throw const GovernanceCommandException('commit_pending');
        }
        final state = device.groupRoleState(groupId);
        final bytes = state.record;
        final roster = state.accounts;
        if (bytes == null) {
          throw const GovernanceCommandException('no_record');
        }
        if (roster == null) {
          throw const GovernanceCommandException('roster_not_text');
        }
        final prev = decodeGovernance(bytes);
        final next = build(
          GovernanceCommands(
              state: prev,
              actor: _requiredAccount(),
              members: roster,
              // C5: a timeout names the epoch this commit produces.
              epoch: device.groupEpoch(groupId).epoch + 1),
          await localStore.loadGovernanceObservations(groupId),
          _clock().toUtc(),
        );
        final previous = await _requiredState();
        try {
          final bundle = _stage(device, groupId, record: next);
          await localStore.commitOutgoingMlsTransition(
            OutgoingMlsStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: await localStore.loadSyncCursor(),
              state: _sealNext(previous),
              messages: <PendingMlsMessage>[_bundleItem(groupId, bundle)],
            ),
          );
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
      });

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
        if (message.syncEventId <= previousCursor &&
            !await _mayReplay(message.conversationId, message.syncEventId)) {
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
              int? infoRemovalEpoch;
              var c7Settings = const <String, String?>{};
              if (device.groupEpoch(message.conversationId).pending) {
                final outcome =
                    device.c7MergePendingCommit(message.conversationId);
                try {
                  if (outcome.removedAny && !outcome.removedSelf) {
                    infoRemovalEpoch = outcome.newEpoch;
                  }
                  c7Settings = await _c7Commit(message.conversationId, outcome,
                      own: true);
                } finally {
                  outcome.wipeRoot();
                }
              }
              final after = device.groupEpoch(message.conversationId);
              if (after.pending || after.epoch != expected) {
                throw StateError('own MLS commit does not match the group');
              }
              final own = _ownCommitEffects(message.conversationId,
                  MlsCommitBundle.decode(bundle.payload));
              await localStore.commitMlsTransition(MlsStateTransition(
                governanceObservation: own.observation,
                checkCanCommit: checkCanCommit,
                messageId: marker,
                conversationId: message.conversationId,
                expectedCounter: previous.counter,
                expectedCursor: previousCursor,
                state: _sealNext(previous),
                cursor: message.syncEventId,
                resolvedMlsOutboxKey: bundle.idempotencyKey,
                infoRemovalEpoch: infoRemovalEpoch,
                c7Settings: <String, String?>{...c7Settings, ...own.settings},
              ));
              await _rejudgeAfterOwnCommit(message.conversationId);
              return;
            }
            if (message.kind == 'commit') {
              // No queued bundle: the outbox worker already merged and
              // settled it, so the group is past the epoch the commit was
              // built on. Anything else means this device never merged a
              // commit the server holds under its identity (a clone-restored
              // twin, or an accepted commit it dropped): the group forked,
              // so stop here rather than fill the chat with D54
              // placeholders.
              final built =
                  mlsMessageEpoch(message.payload, message.conversationId);
              final group =
                  _requiredDevice().groupEpoch(message.conversationId);
              if (built == null || group.epoch <= built) {
                throw StateError('own MLS commit was never merged here');
              }
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
          int? infoRemovalEpoch;
          GovernanceObservationChange? commitObservation;
          var commitSettings = const <String, String?>{};
          var c7Settings = const <String, String?>{};
          switch (message.kind) {
            case 'welcome':
              if (message.recipientDeviceId != _deviceId) {
                throw StateError('MLS Welcome recipient mismatch');
              }
              try {
                device.joinGroup(message.conversationId, message.payload);
                // D99: do not persist a joined group until the inviter's
                // actual MLS leaf matches the locally verified invitation.
                // The outer failure path restores the consumed key package
                // and group state, so a rejected Welcome is retryable.
                final anchor =
                    await localStore.loadInviteAnchor(message.conversationId);
                if (anchor != null) {
                  final key = device.memberSignatureKey(message.conversationId,
                      anchor.accountId, anchor.deviceId);
                  if (!_sameBytes(key, anchor.signingKey)) {
                    throw StateError(
                        'Invitation does not match the encrypted group');
                  }
                }
                // C4: a joiner starts both waits now; a Welcome is no
                // owner activity.
                final record = governanceOf(message.conversationId);
                if (record != null) {
                  // Proofs this device kept from an earlier membership
                  // say nothing about this one.
                  final roster =
                      device.groupRoleState(message.conversationId).accounts;
                  commitSettings = <String, String?>{
                    for (final account in roster ?? const <String>{})
                      ..._leaveProofsCleared(message.conversationId, account),
                    // A statement this device signed in an earlier
                    // membership names a leaf that is gone.
                    governanceLeaveSignedOutSetting(message.conversationId):
                        null,
                  };
                  commitObservation = GovernanceObservationChange(
                    groupId: message.conversationId,
                    state: record,
                    authenticatedSender: _requiredAccount(),
                    receivedAt: _clock().toUtc(),
                    senderApproved: false,
                  );
                }
              } on NativeCryptoException catch (error) {
                if (error.kind !=
                    NativeCryptoError.welcomeKeyPackageUnavailable) {
                  rethrow;
                }
                // The Welcome is for a key package this device no longer
                // holds, or one that expired (D74). Nothing was consumed
                // and nothing can be: sync moves on, and the chat says to
                // ask to be added again.
                await localStore.commitMlsTransition(MlsStateTransition(
                  checkCanCommit: checkCanCommit,
                  messageId: marker,
                  conversationId: message.conversationId,
                  expectedCounter: previous.counter,
                  expectedCursor: previousCursor,
                  state: _sealNext(previous),
                  cursor: message.syncEventId,
                  messageEffects: <MessageEffect>[
                    InsertMessageEffect(
                      key: 'welcome-unavailable:'
                          '${message.syncEventId}:${message.id}',
                      conversationId: message.conversationId,
                      senderAccountId: message.senderAccountId,
                      senderDeviceId: message.senderDeviceId,
                      kind: LocalMessageKind.invalid,
                      createdAt: message.createdAt.millisecondsSinceEpoch,
                      state: LocalMessageState.received,
                    ),
                  ],
                ));
                return;
              }
              break;
            case 'commit':
              // Another device's commit won this epoch. Any commit this
              // device staged on the same epoch was refused, so it is
              // dropped before applying the winner (card I51).
              if (device.groupEpoch(message.conversationId).pending) {
                device.clearPendingCommit(message.conversationId);
              }
              // ABI 13 reports authenticated MLS effects, independent of the
              // server's membership labels. Persist the rotation obligation
              // with this transition, including during inbound-only wakes.
              // C4: two phases. Rust stages and holds the commit; the role
              // record change and any governing removal are judged here
              // before it merges. A refusal discards it; the outer catch
              // then restores the committed state (the ratchet step is used
              // up) and the conversation pauses on this commit (I33).
              final review = device.stageIncomingCommit(
                  message.conversationId, message.payload);
              try {
                final judged =
                    await _judgeIncomingCommit(message.conversationId, review);
                commitObservation = judged.observation;
                commitSettings = judged.settings;
              } catch (_) {
                device.discardIncomingCommit(message.conversationId);
                rethrow;
              }
              final pairs = device.mergeIncomingCommit(
                  message.conversationId, message.payload);
              final root = pairs.root;
              try {
                if (pairs.removed && !pairs.removedSelf) {
                  infoRemovalEpoch = pairs.epoch;
                }
                c7Settings = await _c7Commit(
                    message.conversationId, pairs.c7Outcome,
                    own: false);
              } finally {
                root?.fillRange(0, root.length, 0);
              }
              break;
            default:
              throw StateError('unsupported MLS transport message');
          }
          // L1 (D94): the commit or Welcome is applied, never refused for a
          // list reason. Every leaf of the group is judged now and the
          // verdicts commit with the state, so a crash cannot leave the
          // merged group unjudged. A group this device left has no leaves.
          final ApprovalLeafChange approval;
          if (await _hasGroup(message.conversationId)) {
            approval = await _judgeGroup(message.conversationId,
                welcome: message.kind == 'welcome');
          } else {
            approval = ApprovalLeafChange(
                conversationId: message.conversationId,
                leaves: const [],
                replaceAll: true);
          }
          // C7: the re-add wipe and the newcomer's floor (decision 5).
          final welcomeC7 = message.kind == 'welcome'
              ? await _c7Welcome(message.conversationId,
                  device.groupEpoch(message.conversationId).epoch)
              : null;
          checkCanCommit?.call();
          final next = _sealNext(previous);
          await localStore.commitMlsTransition(MlsStateTransition(
            checkCanCommit: checkCanCommit,
            messageId: marker,
            conversationId: message.conversationId,
            expectedCounter: previous.counter,
            expectedCursor: previousCursor,
            state: next,
            cursor: message.syncEventId,
            approvalLeaves: approval,
            infoRemovalEpoch: infoRemovalEpoch,
            governanceObservation: commitObservation,
            // C4 leave proofs share the C7 settings channel.
            c7Settings: <String, String?>{
              ...c7Settings,
              ...?welcomeC7,
              ...commitSettings,
            },
          ));
          _rememberVerdicts(approval);
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
        await _requireNotPaused(revocation.conversationId);
        final removes = <MlsDeviceRef>[
          (
            accountId: revocation.revokedAccountId,
            deviceId: revocation.revokedDeviceId,
          ),
        ];
        if ((await _provenRemoves(revocation.conversationId, removes))
            .isEmpty) {
          throw GovernanceRemovalUnprovenException(revocation.conversationId);
        }
        final previous = await _requiredState();
        try {
          final bundle = _stage(
            _requiredDevice(),
            revocation.conversationId,
            removes: removes,
            revocationDeviceId: revocation.revokedDeviceId,
            record: await _plannedRecord(revocation.conversationId,
                removes: removes),
            leaveStatements:
                await _leaveStatementsFor(revocation.conversationId, removes),
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
        await _requireNotPaused(conversationId);
        await _requireApproved(conversationId);
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
        if (syncEventId <= cursor &&
            !await _mayReplay(call.conversationId, syncEventId)) {
          throw StateError('call signal is behind the sync cursor');
        }
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
          final ciphertext = base64Decode(encoded);
          List<int>? plaintext;
          try {
            // Null when this device can never decrypt the signal (D54): it
            // is dropped and sync moves past it.
            plaintext = await _decryptOrUndecryptable(
                previous,
                () => _requiredDevice().decrypt(
                      call.conversationId,
                      ciphertext,
                      senderAccountId: senderAccountId,
                      senderDeviceId: senderDeviceId,
                    ));
          } on NativeCryptoException catch (error) {
            // The server also delivers a caller's signals to the caller's
            // other devices, where the guessed sender account is wrong. The
            // ratchet already advanced, so commit and drop the signal (P4).
            if (!error.kind.ratchetAdvanced) rethrow;
          }
          // L1 (D94): a device that is not on its account's list never rings
          // or signals as that account; its signal is dropped like any
          // other that cannot be used.
          if (plaintext != null) {
            final verdict = await _senderVerdict(
                call.conversationId, senderAccountId, senderDeviceId);
            if (verdict != LeafVerdict.approved &&
                verdict != LeafVerdict.removed) {
              plaintext.fillRange(0, plaintext.length, 0);
              plaintext = null;
            }
          }
          // The state and cursor always commit from here (P4, D54). A
          // payload that is not a valid call signal is dropped: no row and
          // no signal.
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
      _encryptPayload(conversationId, type, body,
          attachmentRefs: attachmentRefs, draftText: draftText);

  @override
  Future<MessageEnvelope> encryptChannelPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    required String channelId,
    required int layoutGeneration,
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  }) =>
      _encryptPayload(conversationId, type, body,
          attachmentRefs: attachmentRefs,
          draftText: draftText,
          routeChannelId: channelId,
          routeGeneration: layoutGeneration);

  @override
  Future<MessageEnvelope> encryptExpiringPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    required DateTime expiresAt,
    String? channelId,
    int? layoutGeneration,
    List<String> attachmentRefs = const <String>[],
    String? draftText,
  }) =>
      _encryptPayload(conversationId, type, body,
          attachmentRefs: attachmentRefs,
          draftText: draftText,
          routeChannelId: channelId,
          routeGeneration: layoutGeneration,
          expiresAt: expiresAt);

  /// [routeChannelId] and [routeGeneration] are given exactly for a post in a
  /// community's shared group; any other pairing fails before anything is
  /// encrypted, so a post can neither lose its channel nor gain one.
  Future<MessageEnvelope> _encryptPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    required List<String> attachmentRefs,
    required String? draftText,
    String? routeChannelId,
    int? routeGeneration,
    DateTime? expiresAt,
  }) =>
      _serial(() async {
        final info = infoPayloadTypes.contains(type);
        // C4: a leave proof is hidden and never franked, like an info
        // payload, but changes no community info.
        final leaveProof = leaveNoticePayloadTypes.contains(type);
        // C6: a report key announcement or request is hidden and never
        // franked either, and changes no community info.
        final reportKey = reportKeyPayloadTypes.contains(type);
        // L2-5: the own-device alert goes into a chat that is held because
        // of the very leaf it reports, so it alone skips the approval hold.
        // It is hidden and never franked, and carries no secret.
        final deviceAlert = type == AppPayloadType.deviceListAlert;
        if (!_messageTypes.contains(type) &&
            !info &&
            !leaveProof &&
            !reportKey &&
            !deviceAlert) {
          throw ArgumentError.value(type, 'type', 'not a message payload');
        }
        // C3 info payloads carry no expiry and are never franked: a report
        // must never hand an info key to its reader.
        if ((info || reportKey) && expiresAt != null) {
          throw ArgumentError.value(
              type, 'type', 'info payloads do not expire');
        }
        if (deviceAlert && expiresAt != null) {
          throw ArgumentError.value(type, 'type', 'alerts do not expire');
        }
        await _requireNotPaused(conversationId);
        if (!deviceAlert) await _requireApproved(conversationId);
        final signedLeave = type == AppPayloadType.memberLeaveSigned;
        if (signedLeave && governanceOf(conversationId) == null) {
          throw ArgumentError.value(type, 'type', 'only in a record group');
        }
        final previous = await _requiredState();
        final cursor = await localStore.loadSyncCursor();
        if (!await localStore.hasOutboxCapacity()) {
          throw const OutboxFullException();
        }
        if (signedLeave ||
            (type == AppPayloadType.memberLeave &&
                governanceOf(conversationId) != null)) {
          // Written before the statement exists: if the leave does not go
          // through, the app voids it with a self-update (C4 leave proof in
          // the commit). A leftover after a failed send costs one update.
          // The plain member_leave sets it too: it is a proof on its own
          // (receivers drop it on this leaf's next commit), and the signed
          // statement after it is best effort.
          await localStore.saveSetting(
              governanceLeaveSignedOutSetting(conversationId), '1');
        }
        final sharedGroup =
            _authority?.conversationKind(conversationId) == 'community_shared';
        if (sharedGroup != (routeChannelId != null) ||
            (routeChannelId != null && routeGeneration == null)) {
          throw StateError('a channel is named exactly for a shared group');
        }
        final channelId = sharedGroup ? routeChannelId : null;
        // C7: a private channel's own group names its channel in the clear
        // metadata (the server already maps the group to it), never inside
        // the payload, so the server's posting checks apply to its posts.
        final c7Private = c7SealedBodies && !sharedGroup
            ? _c7PrivateChannel(conversationId)
            : null;
        try {
          final idempotencyKey = _randomIdempotencyKey();
          final deviceId = _deviceId!;
          // C6: every message carries a franking key inside its encrypted
          // payload and the commitment to it beside the ciphertext. The
          // commitment covers the canonical payload without the key, bound to
          // this conversation, this device and this action.
          final Uint8List payload;
          final List<int>? commit;
          final groupEpoch = _requiredDevice().groupEpoch(conversationId);
          if (info || leaveProof || reportKey || deviceAlert) {
            payload = AppPayloadCodec().encode(
              type: type,
              conversationId: conversationId,
              senderDeviceId: deviceId,
              actionId: idempotencyKey,
              // The proof names the epoch it is encrypted in, which the
              // receiver reads from the authenticated MLS header too.
              // The signed statement is made now, for this leaf as it is.
              body: signedLeave
                  ? <String, Object?>{
                      'statement': base64
                          .encode(_requiredDevice().signLeave(conversationId)),
                    }
                  : leaveProof
                      ? <String, Object?>{'epoch': groupEpoch.epoch}
                      : body,
              hidden: true,
              channelId: channelId,
            );
            commit = null;
          } else {
            final frankKey = generateFrankKey();
            final framed = AppPayloadCodec().encodeFranked(
              type: type,
              conversationId: conversationId,
              senderDeviceId: deviceId,
              actionId: idempotencyKey,
              body: body,
              frankKey: frankKey,
              hidden: type.sendsHidden,
              channelId: channelId,
              expiresAtMs: expiresAt?.toUtc().millisecondsSinceEpoch,
            );
            payload = framed.padded;
            commit = bindings.frankCommit(
              key: frankKey,
              conversationId: conversationId,
              senderDeviceId: deviceId,
              actionId: idempotencyKey,
              payload: framed.canonical,
            );
            frankKey.fillRange(0, frankKey.length, 0);
          }
          final device = _requiredDevice();
          final epoch = groupEpoch.epoch;
          // C7: in a community conversation MLS carries only the reference;
          // the padded VAP1 goes in the sealed body beside it.
          List<int> mlsPlaintext = payload;
          Uint8List? sealedBody;
          // C7 (decision 7): the generation a post's own row records.
          String? c7Gen;
          if (c7SealedBodies &&
              c7CommunityKind(_authority?.conversationKind(conversationId))) {
            final communityId = switch (_authority) {
              final ConversationCommunitySource source =>
                source.conversationCommunity(conversationId),
              _ => null,
            };
            if (communityId == null || communityId.isEmpty) {
              throw StateError('C7 needs the community of this conversation');
            }
            // A post in a `full` and `ok` channel seals under the current
            // generation's key, and so does an action whose target was
            // sealed in the current period (decision 7); everything else
            // under a random key (I4).
            final generation = await _c7SealGen(
                conversationId, channelId ?? c7Private, type, epoch, body);
            if (generation != null && c7HistoryPostTypes.contains(type)) {
              c7Gen = c7GenTag(generation.key!);
            }
            final sealed = c7SealMessage(
              bindings: bindings,
              sign: (message) => device.c7Sign(
                  domain: c7PostSignatureDomain, message: message),
              communityId: communityId,
              conversationId: conversationId,
              channelId: channelId ?? c7Private,
              senderDeviceId: deviceId,
              actionId: idempotencyKey,
              epoch: epoch,
              paddedVap1: payload,
              chk: generation?.key,
              generation: generation?.epoch ?? 0,
            );
            mlsPlaintext = sealed.reference;
            sealedBody = sealed.sealedBody;
          }
          final ciphertext = device.encrypt(conversationId, mlsPlaintext);
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
              if (channelId != null) ...<String, Object?>{
                'channel_id': channelId,
                'community_layout_generation': routeGeneration,
              } else if (c7Private != null && sealedBody != null)
                'channel_id': c7Private,
              // The epoch is already readable in the MLS message header. The
              // server uses it to withhold a message from a device that
              // joined after that epoch and cannot decrypt it (card I51).
              'mls_epoch': epoch,
              // C4: the server exempts a governing member's own leave proof
              // from the posting rules (it cannot read the type); receivers
              // refuse anything else under this mark.
              if (leaveProof) leaveNoticeMetadataKey: true,
            },
            frankCommit: commit,
            sealedBody: sealedBody,
            attachmentRefs: attachmentRefs,
          );
          await localStore.commitOutgoingApplicationTransition(
            OutgoingApplicationStateTransition(
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              envelope: envelope,
              draftText: draftText,
              messageEffects: info || leaveProof || reportKey || deviceAlert
                  ? <MessageEffect>[
                      InsertMessageEffect(
                        key: messageKey(deviceId, idempotencyKey),
                        conversationId: conversationId,
                        senderAccountId: _accountId!,
                        senderDeviceId: deviceId,
                        kind: LocalMessageKind.action,
                        senderHidden: true,
                        channelId: channelId,
                        createdAt:
                            DateTime.now().toUtc().millisecondsSinceEpoch,
                        state: LocalMessageState.pending,
                      ),
                    ]
                  : _c7Recorded(
                      messageEffectsFor(
                        DecryptedAppPayload(
                            type: type,
                            actionId: idempotencyKey,
                            body: body,
                            channelId: channelId),
                        conversationId: conversationId,
                        senderAccountId: _accountId!,
                        senderDeviceId: deviceId,
                        createdAt:
                            DateTime.now().toUtc().millisecondsSinceEpoch,
                        state: LocalMessageState.pending,
                        // The sender's own word: the first echo can only
                        // shorten it.
                        expiresAt: expiresAt?.toUtc().millisecondsSinceEpoch,
                        authority: _authority,
                      ),
                      messageKey(deviceId, idempotencyKey),
                      c7Gen),
              communityInfo: info
                  ? <CommunityInfoEvent>[
                      communityInfoEventFor(
                        DecryptedAppPayload(
                            type: type, actionId: idempotencyKey, body: body),
                        conversationId: conversationId,
                        senderAccountId: _accountId!,
                        senderDeviceId: deviceId,
                        epoch: epoch,
                      ),
                    ]
                  : const <CommunityInfoEvent>[],
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

  /// Whether clear envelope metadata carries the C4 leave-notice mark.
  static bool _marksLeaveNotice(Object? metadata) =>
      metadata is Map && metadata[leaveNoticeMetadataKey] == true;

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
      if (syncEventId <= cursor &&
          !await _mayReplay(envelope.conversationId, syncEventId)) {
        throw StateError('unrecorded application message is behind the cursor');
      }
      if (envelope.senderDeviceId == _deviceId) {
        operationFence();
        // Our own message: its text was stored when it was encrypted, and
        // MLS cannot decrypt a message for its own sender. C7: an own
        // record applies now, in sync order (decision 4).
        final ownC7 =
            await _c7OwnEcho(envelope.conversationId, envelope.idempotencyKey);
        operationFence();
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
          c7Settings: ownC7,
        ));
        return null;
      }
      try {
        operationFence();
        LeafVerdict? senderVerdict;
        List<int> plaintext;
        // C7: whether the message came in two parts, and the channel its
        // clear metadata names (bound into the body's aad).
        var c7TwoPart = false;
        String? c7Channel;
        C7Opened? c7Opened;
        try {
          final decrypted = await _decryptOrUndecryptable(
              previous,
              () => _requiredDevice().decrypt(
                    envelope.conversationId,
                    envelope.ciphertext,
                    senderAccountId: envelope.senderAccountId,
                    senderDeviceId: envelope.senderDeviceId,
                  ));
          if (decrypted == null) {
            // This device can never decrypt the message (D54): an epoch it
            // never held or whose secrets are gone, or damaged bytes. Sync
            // moves past it and the conversation shows a placeholder with
            // no content. The committed group is already back in memory.
            final miss = await _c7Miss(envelope.conversationId);
            await localStore.commitMlsTransition(MlsStateTransition(
              checkCanCommit: operationFence,
              messageId: marker,
              conversationId: envelope.conversationId,
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              cursor: syncEventId,
              upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
              c7Settings: miss,
              messageEffects: <MessageEffect>[
                // An `invalid` row holds no content and offers no action;
                // the timeline reads this key prefix to say "couldn't
                // unlock" rather than "couldn't read".
                _placeholderRow(
                    envelope,
                    'undecryptable:$syncEventId:${envelope.id}',
                    LocalMessageKind.invalid),
              ],
            ));
            return null;
          }
          plaintext = decrypted;
          // L1 (D94): a message from a leaf that is not approved never
          // speaks as its account. The ratchet has moved, so the state and
          // the cursor commit; the text is not kept.
          final verdict = await _senderVerdict(envelope.conversationId,
              envelope.senderAccountId, envelope.senderDeviceId);
          senderVerdict = verdict;
          if (verdict != LeafVerdict.approved &&
              verdict != LeafVerdict.removed) {
            plaintext.fillRange(0, plaintext.length, 0);
            final miss = await _c7Miss(envelope.conversationId);
            await localStore.commitMlsTransition(MlsStateTransition(
              checkCanCommit: operationFence,
              messageId: marker,
              conversationId: envelope.conversationId,
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              cursor: syncEventId,
              c7Settings: miss,
              messageEffects: <MessageEffect>[
                _placeholderRow(
                    envelope,
                    '$unapprovedSenderKeyPrefix$syncEventId:${envelope.id}',
                    LocalMessageKind.invalid),
              ],
            ));
            return null;
          }
          // C7: a two-part message's reference names its sealed body. A
          // missing, swapped or damaged body is an invalid row; the MLS
          // state and the cursor commit with it (P1), so a server that
          // strips a body cannot stop the conversation.
          // Parsed whatever the conversation's cached kind: the magic and
          // the exact 68 bytes never match a VAP1, MLS authenticated them,
          // and a list that has not caught up must not lose the message.
          final reference = parseC7Reference(plaintext);
          if (reference != null) {
            final metadata = envelope.cryptoMetadata;
            final routeChannel =
                metadata is Map ? metadata['channel_id'] : null;
            C7Opened? opened;
            try {
              opened = c7OpenLiveParts(
                bindings: bindings,
                reference: reference,
                sealedBody: envelope.sealedBody,
                conversationId: envelope.conversationId,
                channelId: routeChannel is String ? routeChannel : null,
                senderDeviceId: envelope.senderDeviceId,
                actionId: envelope.idempotencyKey,
              );
            } finally {
              reference.bodyKey.fillRange(0, reference.bodyKey.length, 0);
            }
            plaintext.fillRange(0, plaintext.length, 0);
            c7TwoPart = true;
            c7Channel = routeChannel is String ? routeChannel : null;
            if (opened == null) {
              final miss = await _c7Miss(envelope.conversationId);
              await localStore.commitMlsTransition(MlsStateTransition(
                checkCanCommit: operationFence,
                messageId: marker,
                conversationId: envelope.conversationId,
                expectedCounter: previous.counter,
                expectedCursor: cursor,
                state: _sealNext(previous),
                cursor: syncEventId,
                upsertedEnvelopes: <ReceivedMessageEnvelope>[envelope],
                c7Settings: miss,
                messageEffects: <MessageEffect>[
                  _invalidRow(envelope, syncEventId),
                ],
              ));
              return null;
            }
            c7Opened = opened;
            plaintext = opened.paddedVap1;
          }
        } on NativeCryptoException catch (error) {
          if (!error.kind.ratchetAdvanced) rethrow;
          // The ratchet already advanced, so the message can never be
          // decrypted again. Keep going and record a warning instead of
          // the claimed sender's words (D25).
          final miss = await _c7Miss(envelope.conversationId);
          await localStore.commitMlsTransition(MlsStateTransition(
            checkCanCommit: operationFence,
            messageId: marker,
            conversationId: envelope.conversationId,
            expectedCounter: previous.counter,
            expectedCursor: cursor,
            state: _sealNext(previous),
            cursor: syncEventId,
            c7Settings: miss,
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
        FrankReveal? reveal;
        var info = const <CommunityInfoEvent>[];
        var settings = const <String, String?>{};
        var c7Invalid = false;
        ({String accountId, int headVersion, String listId})? alert;
        try {
          final checked = _checkFranking(
            envelope,
            plaintext,
            AppPayloadCodec().classify(
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
            ),
          );
          // C4: the server lets an envelope marked as a leave notice past
          // the posting rules (C2, timeout, slow mode), so a marked
          // envelope is only ever a leave proof this app knows, or a hidden
          // payload it does not (a newer leave proof); anything else under
          // the mark, a visible unsupported payload included, is an invalid
          // row and never shows (review L1).
          final markedWrongly = _marksLeaveNotice(envelope.cryptoMetadata) &&
              !switch (checked.outcome) {
                DecodedAppPayload(:final payload) =>
                  leaveNoticePayloadTypes.contains(payload.type),
                UnsupportedAppPayload(:final hidden) => hidden,
                InvalidAppPayload() => false,
              };
          final outcome =
              markedWrongly ? const InvalidAppPayload() : checked.outcome;
          reveal = markedWrongly ? null : checked.reveal;
          switch (outcome) {
            case DecodedAppPayload(:final payload):
              // C7: in the C0 layout a group-level two-part message (no
              // channel_id) is a history_sync or its request, and those are
              // never anything else; a private group names only its own
              // channel. The C7 types come only in two parts. Anything
              // else is an invalid row: the server cannot tell a post from
              // a history_sync, so this is what keeps a post that skipped
              // the posting checks from showing.
              final c7Kind = c7PayloadTypes.contains(payload.type);
              final layout = _c7Layout(envelope.conversationId);
              final privateChannel = _c7PrivateChannel(envelope.conversationId);
              if ((c7Kind && !c7TwoPart) ||
                  (c7TwoPart &&
                      layout &&
                      ((c7Channel == null) !=
                              c7GroupLevelTypes.contains(payload.type) ||
                          (privateChannel != null &&
                              c7Channel != null &&
                              c7Channel != privateChannel)))) {
                effects = <MessageEffect>[_invalidRow(envelope, syncEventId)];
                reveal = null;
                c7Invalid = true;
                break;
              }
              if (c7Kind) {
                // C7 records, history_sync and its request change state and
                // show nothing; a hidden action row stands in for the
                // envelope (decisions 4 and 5).
                final opened = c7Opened!;
                settings = switch (payload.type) {
                  AppPayloadType.historyChange => opened.trailer.isEmpty
                      ? await _c7ApplyProposal(envelope, payload,
                          routeChannel: c7Channel,
                          epoch: mlsMessageEpoch(
                              envelope.ciphertext, envelope.conversationId),
                          verdict: senderVerdict)
                      : await _c7Miss(envelope.conversationId),
                  AppPayloadType.historySync => await _c7ApplySync(
                      envelope, payload, opened.trailer,
                      epoch: mlsMessageEpoch(
                          envelope.ciphertext, envelope.conversationId),
                      verdict: senderVerdict),
                  AppPayloadType.historySyncRequest => opened.trailer.isEmpty
                      ? await _c7ApplyRequest(envelope.conversationId, payload)
                      : const <String, String?>{},
                  _ => const <String, String?>{},
                };
                effects = <MessageEffect>[
                  _placeholderRow(
                    envelope,
                    messageKey(
                        envelope.senderDeviceId, envelope.idempotencyKey),
                    LocalMessageKind.action,
                    senderHidden: true,
                  ),
                ];
                reveal = null;
                break;
              }
              // C3: info keys, key requests and announcements change state
              // and show nothing. A hidden action row stands in for the
              // envelope; no reveal is ever kept, so a report cannot hand an
              // info key to its reader.
              if (infoPayloadTypes.contains(payload.type)) {
                effects = <MessageEffect>[
                  _placeholderRow(
                    envelope,
                    messageKey(
                        envelope.senderDeviceId, envelope.idempotencyKey),
                    LocalMessageKind.action,
                    senderHidden: true,
                    channelId: payload.channelId,
                  ),
                ];
                // Kept only from a community conversation (its shared group
                // or a private channel's group): a DM or plain group never
                // seeds community keys or announcements.
                final kind =
                    _authority?.conversationKind(envelope.conversationId);
                // Owner decision B: info keys and info edits are admin
                // actions; none is taken from a leaf its list removed.
                final roleActionFromRemoved =
                    senderVerdict == LeafVerdict.removed &&
                        payload.type != AppPayloadType.infoKeyRequest;
                info = roleActionFromRemoved ||
                        (kind != 'community_shared' &&
                            kind != 'community_channel')
                    ? const <CommunityInfoEvent>[]
                    : <CommunityInfoEvent>[
                        communityInfoEventFor(
                          payload,
                          conversationId: envelope.conversationId,
                          senderAccountId: envelope.senderAccountId,
                          senderDeviceId: envelope.senderDeviceId,
                          // From the message's own header, never the
                          // server's `mls_epoch` metadata: decryption
                          // succeeded, so this epoch is authenticated (it
                          // selects the epoch secrets and is in the AAD).
                          epoch: mlsMessageEpoch(
                              envelope.ciphertext, envelope.conversationId),
                        ),
                      ];
                reveal = null;
                break;
              }
              // L2-5: an own-device alert. It counts only about the account
              // MLS authenticated as its sender (an approved device of it,
              // checked above); it shows nothing and is never reportable.
              if (payload.type == AppPayloadType.deviceListAlert) {
                effects = <MessageEffect>[
                  _placeholderRow(
                    envelope,
                    messageKey(
                        envelope.senderDeviceId, envelope.idempotencyKey),
                    LocalMessageKind.action,
                    senderHidden: true,
                    channelId: payload.channelId,
                  ),
                ];
                // Review M3: only from a leaf its list approves now; a
                // removed (stolen or replaced) device's alert is ignored.
                if (senderVerdict == LeafVerdict.approved &&
                    payload.body['account_id'] == envelope.senderAccountId) {
                  alert = (
                    accountId: envelope.senderAccountId,
                    headVersion: payload.body['head_version'] as int,
                    listId: payload.body['list_id'] as String,
                  );
                }
                reveal = null;
                break;
              }
              // C4: the sender's own leave proof (docs/crypto.md, "C4 app
              // wiring"). Kept only in a record group, and only when the
              // epoch it names is the one MLS authenticated for it.
              // C4 leave proof in the commit (ABI 24): the sender's signed
              // statement, kept under the same rules (record group, approved
              // leaf) for a commit that removes it.
              if (payload.type == AppPayloadType.memberLeaveSigned) {
                effects = <MessageEffect>[
                  _placeholderRow(
                    envelope,
                    messageKey(
                        envelope.senderDeviceId, envelope.idempotencyKey),
                    LocalMessageKind.action,
                    senderHidden: true,
                    channelId: payload.channelId,
                  ),
                ];
                if (senderVerdict == LeafVerdict.approved &&
                    governanceOf(envelope.conversationId) != null) {
                  settings = <String, String?>{
                    governanceLeaveSignedSetting(
                            envelope.conversationId, envelope.senderAccountId):
                        payload.body['statement'] as String,
                  };
                }
                reveal = null;
                break;
              }
              if (payload.type == AppPayloadType.memberLeave) {
                effects = <MessageEffect>[
                  _placeholderRow(
                    envelope,
                    messageKey(
                        envelope.senderDeviceId, envelope.idempotencyKey),
                    LocalMessageKind.action,
                    senderHidden: true,
                    channelId: payload.channelId,
                  ),
                ];
                final epoch = mlsMessageEpoch(
                    envelope.ciphertext, envelope.conversationId);
                // Owner decision B (review M1): a leaf its list removed (a
                // stolen or replaced phone) has no role, so its leave proof
                // never strips a governing account; only an approved leaf's
                // counts.
                if (senderVerdict == LeafVerdict.approved &&
                    epoch != null &&
                    payload.body['epoch'] == epoch &&
                    governanceOf(envelope.conversationId) != null) {
                  settings = <String, String?>{
                    governanceLeaveSetting(
                            envelope.conversationId, envelope.senderAccountId):
                        epoch.toString(),
                  };
                }
                reveal = null;
                break;
              }
              // C6: a member's own report key, or a request for keys. Kept
              // as settings in the record group only, from an approved
              // device; who moderates is judged when a report is sealed.
              if (reportKeyPayloadTypes.contains(payload.type)) {
                effects = <MessageEffect>[
                  _placeholderRow(
                    envelope,
                    messageKey(
                        envelope.senderDeviceId, envelope.idempotencyKey),
                    LocalMessageKind.action,
                    senderHidden: true,
                    channelId: payload.channelId,
                  ),
                ];
                settings = reportKeySettingsFor(
                  payload,
                  conversationId: envelope.conversationId,
                  senderAccountId: envelope.senderAccountId,
                  isRecordGroup: governanceOf(envelope.conversationId) != null,
                  verdict: senderVerdict,
                  selfAccountId: _accountId,
                  syncEventId: syncEventId,
                );
                reveal = null;
                break;
              }
              if (!_messageTypes.contains(payload.type)) {
                throw const FormatException('unexpected message type');
              }
              final authority = _authority;
              final VerifiedRoleSource? roles = authority is VerifiedRoleSource
                  ? authority as VerifiedRoleSource
                  : null;
              // C2: a restricted post from a sender below admin is dropped.
              // A hidden action row stands in for it, so the timeline hides
              // the server's copy of the envelope too; no notice, no text.
              // The MLS state and cursor still commit.
              if (roles != null &&
                  restrictedPostTypes.contains(payload.type) &&
                  shouldDropRestrictedPost(
                    record: roles.governanceOf(envelope.conversationId),
                    sender: envelope.senderAccountId,
                    channelId: payload.channelId,
                    serverRestricts: roles.serverRestrictsPosting(
                        envelope.conversationId, payload.channelId),
                    senderRemoved: senderVerdict == LeafVerdict.removed,
                  )) {
                effects = <MessageEffect>[
                  _placeholderRow(
                    envelope,
                    messageKey(
                      envelope.senderDeviceId,
                      envelope.idempotencyKey,
                    ),
                    LocalMessageKind.action,
                    senderHidden: true,
                    channelId: payload.channelId,
                  ),
                ];
                reveal = null;
                break;
              }
              // C5: content from a member the verified record has in a
              // timeout at this post's time is hidden the same way.
              if (roles != null &&
                  timeoutRefusedTypes.contains(payload.type) &&
                  shouldDropTimedOutPost(
                    record: roles.governanceOf(envelope.conversationId),
                    sender: envelope.senderAccountId,
                    serverTime: envelope.createdAt,
                    receivedAt: _clock(),
                    // Epochs compare only within the record's own group.
                    postEpoch: governanceOf(envelope.conversationId) != null
                        ? mlsMessageEpoch(
                            envelope.ciphertext,
                            envelope.conversationId,
                          )
                        : null,
                  )) {
                effects = <MessageEffect>[
                  _placeholderRow(
                    envelope,
                    messageKey(
                        envelope.senderDeviceId, envelope.idempotencyKey),
                    LocalMessageKind.action,
                    senderHidden: true,
                    channelId: payload.channelId,
                  ),
                ];
                reveal = null;
                break;
              }
              // C7: a live post sealed under a generation this device
              // does not hold as current there (decision 5, "Unsure"); one
              // sealed under the current one records it (decision 7).
              String? postGen;
              final postChannel = payload.channelId ?? c7Channel;
              final postEpoch =
                  mlsMessageEpoch(envelope.ciphertext, envelope.conversationId);
              if (c7Opened != null &&
                  c7Opened.trailer.isEmpty &&
                  postChannel != null &&
                  postEpoch != null &&
                  c7HistoryPostTypes.contains(payload.type)) {
                (:settings, gen: postGen) = await _c7GenCheck(
                    envelope: envelope,
                    channelId: postChannel,
                    epoch: postEpoch,
                    opened: c7Opened);
              }
              effects = _c7Recorded(
                messageEffectsFor(
                  payload,
                  conversationId: envelope.conversationId,
                  senderAccountId: envelope.senderAccountId,
                  senderDeviceId: envelope.senderDeviceId,
                  serverMessageId: envelope.id,
                  createdAt: envelope.createdAt.millisecondsSinceEpoch,
                  state: LocalMessageState.received,
                  // The sender's signed expiry bounds the server's: the shorter
                  // wins. A payload without one (an older sender) keeps the
                  // server-stamped time, as before.
                  expiresAt: effectiveExpiryMillis(
                      senderMs: payload.expiresAtMs,
                      serverMs:
                          envelope.expiresAt?.toUtc().millisecondsSinceEpoch),
                  authority: _authority,
                  // Owner decision B: a leaf its account's list removed
                  // (a stolen or replaced phone) keeps ordinary messages but
                  // never acts with its account's role.
                  senderActsWithRole: senderVerdict != LeafVerdict.removed,
                ),
                messageKey(envelope.senderDeviceId, envelope.idempotencyKey),
                postGen,
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
              c7Invalid = true;
          }
        } catch (_) {
          effects = <MessageEffect>[_invalidRow(envelope, syncEventId)];
          text = null;
          noticePayload = false;
          reveal = null;
          info = const <CommunityInfoEvent>[];
          settings = const <String, String?>{};
          alert = null;
          c7Invalid = true;
        }
        c7Opened?.bodyKey.fillRange(0, c7Opened.bodyKey.length, 0);
        // C7: a message this device could not fully apply (decision 5,
        // "Unsure"; a P1 `invalid` body).
        if (c7Invalid) {
          settings = await _c7Miss(envelope.conversationId);
        }
        // L1 (design, "Messages from a leaf"): a leaf that was approved once
        // and has been removed from its account's list since is still shown,
        // marked "sent from a device <name> removed". The verdict is recorded
        // now, at entry: once the removal commit lands the leaf is gone and
        // cannot be judged again. Its edits mark the text they leave.
        if (senderVerdict == LeafVerdict.removed) {
          effects = <MessageEffect>[
            for (final effect in effects)
              switch (effect) {
                InsertMessageEffect() => effect.markedSenderRemoved(),
                EditMessageEffect() => effect.markedSenderRemoved(),
                _ => effect,
              },
          ];
        }
        // C4: the owner's posts are its activity; a first message also
        // starts this device's clocks for a group it holds a record for.
        final observation = await _applicationObservation(
            envelope.conversationId, envelope.senderAccountId,
            approved: senderVerdict == LeafVerdict.approved);
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
          // A reveal for a row this transition does not leave live (an edit,
          // an invalid placeholder) is dropped by the store, not an error.
          frankReveals: reveal == null ? const <FrankReveal>[] : [reveal],
          communityInfo: info,
          c7Settings: settings,
          governanceObservation: observation,
        ));
        if (alert != null) {
          await _applyDeviceListAlert(envelope.conversationId, alert.accountId,
              envelope.senderDeviceId, alert.headVersion, alert.listId);
        }
        return text;
      } catch (_) {
        await _restorePrevious(previous);
        rethrow;
      }
    });
  }

  /// C6 receive rule for franking, applied to a payload that already
  /// classified. The commitment context is the envelope's own ids, which
  /// `classify` has just matched against the decrypted payload (condition
  /// G2), never fields read out of the payload again.
  ///
  /// | payload                     | envelope `frank_commit` | result            |
  /// |-----------------------------|-------------------------|-------------------|
  /// | malformed `frank`           | any                     | invalid           |
  /// | franked                     | missing or wrong        | invalid           |
  /// | franked                     | matches                 | accepted, with a reveal to keep |
  /// | no `frank` member           | any                     | per [frankingPolicy] (D95) |
  ///
  /// With the policy that accepts unfranked payloads (today's), the last
  /// row is accepted but unreportable. A policy that refuses them makes an
  /// unfranked payload invalid, except a hidden payload this app does not
  /// understand (design item 9: the C7 hidden types are never franked).
  ///
  /// A native failure while recomputing throws; the caller's `catch` turns
  /// that into an `invalid` row, never a stuck sync.
  ({AppPayloadOutcome outcome, FrankReveal? reveal}) _checkFranking(
      ReceivedMessageEnvelope envelope,
      List<int> plaintext,
      AppPayloadOutcome outcome) {
    if (outcome is InvalidAppPayload) return (outcome: outcome, reveal: null);
    switch (AppPayloadCodec.frankOf(plaintext)) {
      case Unfranked():
        if (frankingPolicy.acceptsUnfranked(outcome)) {
          return (outcome: outcome, reveal: null);
        }
        return (outcome: const InvalidAppPayload(), reveal: null);
      case MalformedFrank():
        return (outcome: const InvalidAppPayload(), reveal: null);
      case Franked(:final canonical, :final key):
        final commit = envelope.frankCommit;
        if (commit == null || commit.length != frankCommitBytes) {
          return (outcome: const InvalidAppPayload(), reveal: null);
        }
        final expected = bindings.frankCommit(
          key: key,
          conversationId: envelope.conversationId,
          senderDeviceId: envelope.senderDeviceId,
          actionId: envelope.idempotencyKey,
          payload: canonical,
        );
        if (!frankCommitEquals(expected, commit)) {
          return (outcome: const InvalidAppPayload(), reveal: null);
        }
        // Kept so the message can be reported later (D95, schema 19): kf and
        // the exact bytes P the commitment covers.
        return (
          outcome: outcome,
          reveal: FrankReveal(
            messageKey:
                messageKey(envelope.senderDeviceId, envelope.idempotencyKey),
            conversationId: envelope.conversationId,
            envelopeId: envelope.id,
            frankKey: key,
            payload: canonical,
          ),
        );
    }
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

  // K2 history transfer (K2TransferCryptoService). Every state-changing step
  // is one _serial operation: native call, seal, one expected-counter commit
  // (with the progress row where one changes), restore on failure.

  int get _nowMs => _clock().toUtc().millisecondsSinceEpoch;

  /// The seven-day transfer window of a link (the native retention rule).
  static const int _k2TransferWindowMs = 7 * 24 * 60 * 60 * 1000;

  static const String _k2SourcePrefix = 'k2-source-';
  static const String _k2SourceSuffix = '.bin';
  static final RegExp _k2TransferIdPattern = RegExp(r'^[0-9a-f]{64}$');

  /// Plaintext is read in pieces this large (the native stream's maximum).
  static const int _k2ChunkBytes = 1024 * 1024;

  @override
  Future<K2ReceiveResult> k2ReceiveBegin(
          K2LinkContext context, List<int> secret,
          {required int originalExpiresAt}) =>
      _serial(() async {
        final device = _requiredDevice();
        if (!_pendingEnrollment) {
          throw const K2TransferException('no pending enrollment identity');
        }
        // The pending state is frozen at its first seal: a record created
        // afterwards would never be stored.
        if (_firstState != null) {
          throw const K2TransferException(
              'the pending state is already sealed');
        }
        return device.k2ReceiveBegin(context, secret,
            originalExpiresAt: originalExpiresAt, now: _nowMs);
      });

  @override
  Future<K2ProofResult> k2EnrollmentProof(K2TransferId id,
          {required String locator,
          required List<int> reservationRequestId,
          required String deviceName,
          required List<int> challenge,
          required List<int> keyPackage,
          required List<int> claimTokenHash,
          required List<int> deviceSecretHash,
          required List<int> initialSessionHash}) =>
      _serial(() async {
        if (!_pendingEnrollment) {
          throw const K2TransferException('no pending enrollment identity');
        }
        return _requiredDevice().k2EnrollmentProof(id,
            now: _nowMs,
            locator: locator,
            reservationRequestId: reservationRequestId,
            deviceName: deviceName,
            challenge: challenge,
            keyPackage: keyPackage,
            claimTokenHash: claimTokenHash,
            deviceSecretHash: deviceSecretHash,
            initialSessionHash: initialSessionHash);
      });

  @override
  Future<bool> k2VerifyPendingApproval(K2TransferId id, List<int> approvalTag,
          {required int approvedAt}) =>
      _serial(() async {
        final first = _firstState;
        final accountId = _accountId;
        final deviceId = _deviceId;
        if (!_pendingEnrollment ||
            first == null ||
            accountId == null ||
            deviceId == null) {
          throw const K2TransferException('no pending enrollment identity');
        }
        // A scratch device from the frozen state: the approval is applied in
        // memory only and the copy is closed, so nothing is sealed, stored
        // or changed on the pending identity.
        final scratch = _formatChecked(() => bindings.restoreRecords(accountId,
                deviceId, first.stateKey, first.counter, first.sealedState, [
              for (final change in first.changes)
                if (change.sealed != null) change.sealed!
            ]));
        try {
          // approved_at is the server's clock. A clock here that runs behind
          // it would make native refuse a genuine approval as one from the
          // future, so only this scratch check lifts `now` to it. The tag and
          // the link-expiry bound are still checked natively, and the real
          // apply after promotion keeps the real clock and its retry.
          scratch.device.k2ApplyApproval(id, approvalTag,
              approvedAt: approvedAt, now: max(_nowMs, approvedAt));
          return true;
        } on NativeCryptoException catch (err) {
          if (err.kind == NativeCryptoError.operationFailed) return false;
          rethrow;
        } finally {
          scratch.device.close();
        }
      });

  @override
  Future<K2Status> k2Inspect(K2TransferId id) =>
      _serial(() async => _requiredDevice().k2Inspect(id, now: _nowMs));

  @override
  Future<String> k2RevealSas(K2TransferId id, List<int> sourceRandom) =>
      _serial(() async {
        // Read only, so it runs on the frozen pending identity too.
        if (!_pendingEnrollment) {
          throw const K2TransferException('no pending enrollment identity');
        }
        return _requiredDevice().k2RevealSas(id, sourceRandom, now: _nowMs);
      });

  @override
  Future<List<int>> k2SourceCommitment(
          String serverOrigin, List<int> sourceRandom) =>
      _serial(() async =>
          _requiredDevice().k2SourceCommitment(serverOrigin, sourceRandom));

  @override
  Future<int> k2ApplyApproval(K2TransferId id, List<int> approvalTag,
          {required int approvedAt}) =>
      _serial(() => _transferMutation<int>((device) async =>
          device.k2ApplyApproval(id, approvalTag,
              approvedAt: approvedAt, now: _nowMs)));

  @override
  Future<K2Verification> k2SourceAccept(K2LinkContext context, List<int> secret,
          {required int originalExpiresAt,
          required List<int> transcriptHash,
          required List<int> claimTag,
          required List<int> sourceRandom}) =>
      _serial(() => _transferMutation<K2Verification>((device) async =>
          device.k2SourceAccept(context, secret,
              originalExpiresAt: originalExpiresAt,
              now: _nowMs,
              transcriptHash: transcriptHash,
              claimTag: claimTag,
              sourceRandom: sourceRandom)));

  @override
  Future<int> k2SourceConfirm(K2TransferId id, String typedSas,
      {required String recipientDeviceId,
      required String claimRequestHash}) async {
    // Read the link's original expiry first: the row's latest deadline.
    final original =
        (await k2Inspect(id)).originalExpiresAt + _k2TransferWindowMs;
    return _serial(() => _transferMutation<int>((device) async {
          final existing =
              await localStore.loadHistoryTransfer(id.serverOrigin, id.linkId);
          if (existing != null &&
              (existing.direction != historyTransferOutgoing ||
                  existing.stage != HistoryTransferStage.approving)) {
            throw const K2TransferException('the approval is already settled');
          }
          // A retry keeps the digest the first confirmation stored: the
          // server's claim hash is immutable, and the approving row is what
          // the upload later sends.
          if (existing != null &&
              _storedClaimHash(existing) != claimRequestHash) {
            throw const K2TransferException('another claim is stored');
          }
          return device.k2SourceConfirm(id, typedSas, now: _nowMs);
        },
            row: (_) async => HistoryTransferProgress(
                  origin: id.serverOrigin,
                  linkId: id.linkId,
                  direction: historyTransferOutgoing,
                  accountId: _accountId!,
                  deviceId: _deviceId!,
                  peerDeviceId: recipientDeviceId,
                  stage: HistoryTransferStage.approving,
                  expiresAt: original,
                  payloadJson: jsonEncode(<String, Object?>{
                    'claim_request_hash': claimRequestHash
                  }),
                )));
  }

  @override
  Future<K2ApprovalRequest> k2SourceApprovalRequest(K2TransferId id) =>
      _serial(() async {
        final device = _requiredDevice();
        // The row is stored in the same transaction as the native intent,
        // so it proves the intent is durable before the tag is released.
        await _transferRow(id, historyTransferOutgoing);
        return device.k2SourceApprovalRequest(id, now: _nowMs);
      });

  @override
  Future<HistoryTransferProgress> k2SourcePrepare(K2TransferId id,
          {required String cacheDirectory}) =>
      _serial(() async {
        k2RequireLinkId(id.linkId);
        final row = await _transferRow(id, historyTransferOutgoing);
        if (row.stage != HistoryTransferStage.approving) return row;
        File? cached;
        try {
          return await _transferMutation<HistoryTransferProgress>(
              (device) async {
            final status = device.k2Inspect(id, now: _nowMs);
            if (status.stage != K2Stage.approved) {
              throw const K2TransferException('the transfer is not approved');
            }
            final exported = await localStore.exportHistorySnapshot();
            final encoded = _bytes(exported);
            try {
              // The exporter allocated this counter and creation time in its
              // own transaction; native binds exactly these to the bundle.
              final snapshot = HistorySnapshot.decode(encoded);
              final stream = device.k2SourceBegin(id,
                  now: _nowMs,
                  createdAt: snapshot.createdAt,
                  snapshotCounter: snapshot.counter,
                  plaintextVersion: k2HistoryPlaintextVersion,
                  payloadLength: encoded.length);
              try {
                var offset = 0;
                while (offset < encoded.length) {
                  final end = min(encoded.length, offset + _k2ChunkBytes);
                  offset = stream.write(
                      offset, Uint8List.sublistView(encoded, offset, end));
                }
                final bundle = stream.sourceFinish(now: _nowMs);
                final directory = Directory(cacheDirectory);
                directory.createSync(recursive: true);
                if (!_k2TransferIdPattern.hasMatch(bundle.transferId)) {
                  throw const K2TransferException(
                      'the transfer ID is not valid');
                }
                final path = '$cacheDirectory${Platform.pathSeparator}'
                    '$_k2SourcePrefix${bundle.transferId}$_k2SourceSuffix';
                cached =
                    await _drainCiphertext(stream, bundle.ciphertextSize, path);
                return row.copyWith(
                  stage: HistoryTransferStage.snapshotReady,
                  transferId: bundle.transferId,
                  ciphertextSha256: bundle.ciphertextHash,
                  ciphertextSize: bundle.ciphertextSize,
                  handoff: bundle.handoff,
                  filePath: path,
                );
              } finally {
                stream.close();
              }
            } finally {
              _wipe(encoded);
              _wipe(exported);
            }
          }, row: (progress) async => progress);
        } catch (_) {
          // Keep the file only when the commit landed and its outcome was
          // lost: the stored row then names it.
          final file = cached;
          if (file != null) {
            try {
              final stored = await localStore.loadHistoryTransfer(
                  id.serverOrigin, id.linkId);
              if (stored?.filePath != file.path && file.existsSync()) {
                file.deleteSync();
              }
            } catch (_) {}
          }
          rethrow;
        }
      });

  /// Drains the source stream's ciphertext into [path] (private working
  /// directory): a temporary file, flushed, then renamed. Never plaintext.
  Future<File> _drainCiphertext(
      K2HistoryStream stream, int size, String path) async {
    final temporary = File('$path.part');
    final handle = temporary.openSync(mode: FileMode.write);
    var closed = false;
    try {
      var offset = 0;
      while (true) {
        final chunk = stream.read(offset);
        handle.writeFromSync(chunk.bytes);
        _wipe(chunk.bytes);
        offset = chunk.nextOffset;
        if (chunk.eof) break;
      }
      if (offset != size) {
        throw const K2TransferException('the encrypted copy has a wrong size');
      }
      handle.flushSync();
      handle.closeSync();
      closed = true;
      return temporary.renameSync(path);
    } catch (_) {
      if (!closed) handle.closeSync();
      if (temporary.existsSync()) temporary.deleteSync();
      rethrow;
    }
  }

  @override
  Future<HistoryTransferProgress> k2SourcePosted(K2TransferId id) =>
      _serial(() => _transferMutation<HistoryTransferProgress>((device) async {
            final row = await _transferRow(id, historyTransferOutgoing);
            if (row.stage == HistoryTransferStage.uploaded) {
              // A retry after the commit: native posted is idempotent.
              device.k2SourcePosted(id, now: _nowMs);
              return row;
            }
            if (row.stage != HistoryTransferStage.snapshotReady) {
              throw const K2TransferException('no cached copy to post');
            }
            device.k2SourcePosted(id, now: _nowMs);
            return row.copyWith(stage: HistoryTransferStage.uploaded);
          }, row: (progress) async => progress));

  @override
  Future<HistoryTransferProgress> k2ReceiveHandoff(K2TransferId id,
          {required List<int> handoff,
          required String transferId,
          required List<int> ciphertextSha256,
          required int ciphertextSize,
          required String downloadPath}) =>
      _serial(() async {
        k2RequireLinkId(id.linkId);
        final row = await _transferRow(id, historyTransferIncoming);
        if (row.stage != HistoryTransferStage.awaitingHandoff) {
          // Stored already: only this exact handoff may be treated as done.
          if (row.handoff == null || !_sameBytes(row.handoff!, handoff)) {
            throw const K2TransferException('another handoff is stored');
          }
          return row;
        }
        return _transferMutation<HistoryTransferProgress>((device) async {
          final begun = device.k2ReceiveBeginBundle(id, handoff,
              now: _nowMs, plaintextVersion: k2HistoryPlaintextVersion);
          begun.stream.close();
          if (begun.transferId != transferId ||
              !_sameBytes(begun.ciphertextHash, ciphertextSha256) ||
              begun.ciphertextSize != ciphertextSize) {
            throw const K2TransferException(
                'the handoff names another transfer');
          }
          return row.copyWith(
            stage: HistoryTransferStage.downloading,
            transferId: begun.transferId,
            ciphertextSha256: begun.ciphertextHash,
            ciphertextSize: begun.ciphertextSize,
            handoff: handoff,
            filePath: downloadPath,
          );
        }, row: (progress) async => progress);
      });

  /// Opens the stored bundle on a native stream and feeds it the whole
  /// ciphertext file. The caller closes the stream. The digest, header and
  /// every chunk are checked by native before any plaintext can be read.
  ({K2HistoryStream stream, K2OpenedBundleResult opened}) _openReceivedBundle(
      NativeCryptoDevice device, K2TransferId id, HistoryTransferProgress row,
      {bool reportRejection = false}) {
    if (row.handoff == null ||
        row.transferId == null ||
        row.ciphertextSha256 == null ||
        row.ciphertextSize == null ||
        row.filePath == null) {
      throw const K2TransferException('no handoff is stored');
    }
    final begun = device.k2ReceiveBeginBundle(id, row.handoff!,
        now: _nowMs, plaintextVersion: k2HistoryPlaintextVersion);
    final stream = begun.stream;
    // Native refusing the ciphertext itself (digest, header or a chunk
    // failing authentication) is a rejection of the bytes; every other
    // failure keeps its own type.
    T rejectable<T>(T Function() step) {
      try {
        return step();
      } on NativeCryptoException catch (err) {
        if (reportRejection && err.kind == NativeCryptoError.operationFailed) {
          throw const _K2BundleRejected();
        }
        rethrow;
      }
    }

    try {
      if (begun.transferId != row.transferId ||
          !_sameBytes(begun.ciphertextHash, row.ciphertextSha256!) ||
          begun.ciphertextSize != row.ciphertextSize) {
        throw const K2TransferException('the handoff names another transfer');
      }
      final file = File(row.filePath!);
      if (!file.existsSync() || file.lengthSync() != row.ciphertextSize) {
        throw const K2TransferException('the download is incomplete');
      }
      final handle = file.openSync();
      try {
        var offset = 0;
        while (offset < begun.ciphertextSize) {
          final chunk = handle
              .readSync(min(_k2ChunkBytes, begun.ciphertextSize - offset));
          if (chunk.isEmpty) {
            throw const K2TransferException('the download is incomplete');
          }
          offset = rejectable(() => stream.write(offset, chunk));
        }
      } finally {
        handle.closeSync();
      }
      return (
        stream: stream,
        opened: rejectable(() => stream.receiveFinish(now: _nowMs)),
      );
    } catch (_) {
      stream.close();
      rethrow;
    }
  }

  @override
  Future<bool> k2VerifyDownload(K2TransferId id) => _serial(() async {
        final row = await _transferRow(id, historyTransferIncoming);
        await _requiredState();
        try {
          _openReceivedBundle(_requiredDevice(), id, row, reportRejection: true)
              .stream
              .close();
          return true;
        } on _K2BundleRejected {
          // Only the native digest, header or chunk authentication failing
          // answers false (the caller then deletes the file). Anything else
          // (I/O, a missing record, the library) passes through: it says
          // nothing about the bytes, so the file is kept.
          return false;
        }
      });

  @override
  Future<HistoryTransferProgress> k2ImportDownloaded(K2TransferId id) =>
      _serial(() async {
        var row = await _transferRow(id, historyTransferIncoming);
        if (row.stage == HistoryTransferStage.imported ||
            row.stage == HistoryTransferStage.acknowledged) {
          return row;
        }
        if (row.stage != HistoryTransferStage.downloaded) {
          throw const K2TransferException('the download is not complete');
        }
        // Verify the whole file, then commit native importing before the
        // database import (a crash after this reopens the same bundle).
        await _transferMutation<void>((device) async {
          _openReceivedBundle(device, id, row).stream.close();
          device.k2Importing(id, now: _nowMs);
        });
        await _requiredState();
        final device = _requiredDevice();
        final bundle = _openReceivedBundle(device, id, row);
        final payload = Uint8List(bundle.opened.payloadLength);
        try {
          var offset = 0;
          while (true) {
            final chunk = bundle.stream.read(offset);
            try {
              if (offset + chunk.bytes.length > payload.length) {
                throw const K2TransferException('the history is too long');
              }
              payload.setRange(
                  offset, offset + chunk.bytes.length, chunk.bytes);
            } finally {
              _wipe(chunk.bytes);
            }
            offset = chunk.nextOffset;
            if (chunk.eof) break;
          }
          if (offset != payload.length) {
            throw const K2TransferException('the history is incomplete');
          }
          // The counter and creation time are the authenticated native
          // header's, never the snapshot's own claims: the importer refuses
          // a snapshot whose inner values differ.
          await localStore.importHistorySnapshot(
              payload,
              HistoryImportContext(
                  origin: id.serverOrigin,
                  accountId: row.accountId,
                  sourceDeviceId: row.peerDeviceId,
                  recipientDeviceId: row.deviceId,
                  transferId: row.transferId!,
                  digest: _hex(row.ciphertextSha256!),
                  snapshotCounter: bundle.opened.snapshotCounter,
                  snapshotCreatedAt: bundle.opened.createdAt));
        } finally {
          bundle.stream.close();
          _wipe(payload);
        }
        row = row.copyWith(stage: HistoryTransferStage.imported);
        await localStore.saveHistoryTransfer(row);
        return row;
      });

  @override
  Future<void> k2Finish(K2TransferId id) => _serial(() async {
        final row = await _transferRow(id, null);
        if (row.stage != HistoryTransferStage.acknowledged) {
          throw const K2TransferException('the server has not confirmed yet');
        }
        await _removeTransfer(id, row);
      });

  @override
  Future<void> k2Abandon(K2TransferId id) => _serial(() async {
        await _removeTransfer(id,
            await localStore.loadHistoryTransfer(id.serverOrigin, id.linkId));
      });

  @override
  Future<int> k2ExpireTransfers() => _serial(() async {
        final now = _nowMs;
        final previous = await _requiredState();
        try {
          // Nothing changed natively when none was removed: no new state.
          if (_requiredDevice().k2Expire(now: now) > 0) {
            await _commitLocalMutation(previous);
          }
        } catch (_) {
          await _restorePrevious(previous);
          rethrow;
        }
        var removed = 0;
        for (final row in await localStore.loadHistoryTransfers()) {
          if (row.expiresAt > now) continue;
          _deleteTransferFile(row);
          await localStore.deleteHistoryTransfer(row.origin, row.linkId);
          removed++;
        }
        return removed;
      });

  @override
  Future<int> k2SweepOrphanCaches(String cacheDirectory) => _serial(() async {
        final directory = Directory(cacheDirectory);
        if (!directory.existsSync()) return 0;
        final named = <String>{
          for (final row in await localStore.loadHistoryTransfers())
            if (row.filePath != null) File(row.filePath!).absolute.path,
        };
        var removed = 0;
        for (final entry in directory.listSync(followLinks: false)) {
          if (entry is! File) continue;
          final name = entry.uri.pathSegments.last;
          if (!name.startsWith(_k2SourcePrefix)) continue;
          final cached = name.endsWith('$_k2SourceSuffix.part')
              ? File(entry.path.substring(0, entry.path.length - 5))
              : entry;
          if (!cached.path.endsWith(_k2SourceSuffix) ||
              named.contains(cached.absolute.path)) {
            continue;
          }
          entry.deleteSync();
          removed++;
        }
        return removed;
      });

  static String? _storedClaimHash(HistoryTransferProgress row) {
    try {
      final decoded = jsonDecode(row.payloadJson);
      final hash = decoded is Map ? decoded['claim_request_hash'] : null;
      return hash is String ? hash : null;
    } on FormatException {
      return null;
    }
  }

  /// Removes the native record (committed first, only when it was there),
  /// then the ciphertext file, then the row. Each step is safe to repeat, so
  /// a crash between them is finished by the next call.
  Future<void> _removeTransfer(
      K2TransferId id, HistoryTransferProgress? row) async {
    final previous = await _requiredState();
    try {
      if (_requiredDevice().k2Forget(id)) {
        await _commitLocalMutation(previous);
      }
    } catch (_) {
      await _restorePrevious(previous);
      rethrow;
    }
    if (row != null) _deleteTransferFile(row);
    await localStore.deleteHistoryTransfer(id.serverOrigin, id.linkId);
  }

  static void _deleteTransferFile(HistoryTransferProgress row) {
    final path = row.filePath;
    if (path == null) return;
    for (final candidate in <String>[path, '$path.part']) {
      final file = File(candidate);
      if (file.existsSync()) file.deleteSync();
    }
  }

  /// The stored progress row of [id] for [direction] (either when null), or a
  /// [K2TransferException].
  Future<HistoryTransferProgress> _transferRow(
      K2TransferId id, String? direction) async {
    final row =
        await localStore.loadHistoryTransfer(id.serverOrigin, id.linkId);
    if (row == null || (direction != null && row.direction != direction)) {
      throw const K2TransferException('no such transfer');
    }
    return row;
  }

  /// One native transfer mutation. Call it only inside [_serial]: [mutate]
  /// runs on the committed state, the result is sealed as the next state and
  /// stored with [row]'s progress (or alone) in one expected-counter
  /// transaction. On any failure the committed state comes back and the
  /// error is rethrown.
  Future<T> _transferMutation<T>(
    Future<T> Function(NativeCryptoDevice device) mutate, {
    Future<HistoryTransferProgress> Function(T result)? row,
  }) async {
    final previous = await _requiredState();
    try {
      final result = await mutate(_requiredDevice());
      final progress = row == null ? null : await row(result);
      final next = _sealNext(previous);
      final cursor = await localStore.loadSyncCursor();
      if (progress == null) {
        await localStore.commitLocalMlsState(
            expectedCounter: previous.counter,
            expectedCursor: cursor,
            state: next);
      } else {
        await localStore.commitHistoryTransferState(
            expectedCounter: previous.counter,
            expectedCursor: cursor,
            state: next,
            transfer: progress);
      }
      return result;
    } catch (_) {
      await _restorePrevious(previous);
      rethrow;
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _bytes(List<int> value) =>
      value is Uint8List ? value : Uint8List.fromList(value);

  /// Overwrites [value] where it can be (an unmodifiable list cannot).
  static void _wipe(List<int> value) {
    try {
      value.fillRange(0, value.length, 0);
    } on UnsupportedError {
      // Nothing more can be done for a read-only list.
    }
  }

  Future<StoredCryptoState> _requiredState(
      {void Function()? checkCanCommit}) async {
    // A pending enrollment's fresh device must never be sealed over the state
    // already stored here; only activateSession may adopt or replace it.
    if (_pendingEnrollment) {
      throw StateError('MLS state is unavailable until enrollment completes');
    }
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

  /// B6 call-group handles open on scratch copies of this identity. Each
  /// closes when its call ends, and all close when the identity changes or
  /// the service is disposed, so no call outlives its account.
  final Set<ScratchCallGroupHandle> _callGroups = <ScratchCallGroupHandle>{};

  void _closeCallGroups() {
    for (final handle in _callGroups.toList()) {
      handle.close();
    }
    _callGroups.clear();
  }

  /// A scratch device restored from the committed state (D70): the call
  /// group is created and joined there and is never sealed, stored, backed
  /// up or transferred, because nothing ever seals that device.
  @override
  Future<CallGroupHandle> openCallGroup() => _serial(() async {
        final accountId = _accountId;
        final deviceId = _deviceId;
        if (_pendingEnrollment ||
            _device == null ||
            accountId == null ||
            deviceId == null) {
          throw StateError('native MLS device is not active');
        }
        final restored = await _restoreCommitted(accountId, deviceId,
            minimumCounter: _deviceCounter ?? 0);
        final handle = _TrackedCallGroup(restored.device, bindings,
            onClose: (handle) => _callGroups.remove(handle));
        _callGroups.add(handle);
        return handle;
      });

  @override
  ParentGroupView get parentGroups => NativeParentGroupView.live(
        () => _pendingEnrollment ? null : _device,
        // B6 (review MEDIUM, round 7): only leaves this device's L1
        // judgment approves may be in a call, as for [_approvedAccountsOf].
        judged: (conversationId) {
          final verdicts = _verdictCache[conversationId];
          if (verdicts == null) unawaited(_warmVerdicts(conversationId));
          return verdicts;
        },
        load: (conversationId) async {
          // A load a verdict write overtook caches nothing; try again.
          for (var i = 0; i < 3 && _verdictCache[conversationId] == null; i++) {
            await _warmVerdicts(conversationId);
          }
          return _verdictCache[conversationId];
        },
      );

  NativeCryptoDevice _requiredDevice() {
    final device = _device;
    if (device == null || _accountId == null || _deviceId == null) {
      throw StateError('native MLS device is not active');
    }
    return device;
  }

  /// Seals what changed since the committed state as the next state: the
  /// root and the changed records, stored together by the caller (D70).
  StoredCryptoState _sealNext(StoredCryptoState previous) {
    final nextCounter = previous.counter + 1;
    final NativeChangeSet sealed;
    try {
      sealed = _requiredDevice().sealChanges(previous.stateKey, nextCounter);
    } on NativeRecordLimitException catch (error) {
      // Nothing was sealed; the caller rolls back (D70).
      throw recordLimitFromNative(error);
    }
    final next = _sealedState(nextCounter, previous.stateKey, sealed);
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

  /// Native errors after which a peer's message may be one this device can
  /// never decrypt (D54). Every other kind, such as invalidArgument or
  /// unknown, stops sync under I33.
  static const _undecryptableErrors = <NativeCryptoError>{
    NativeCryptoError.operationFailed,
    NativeCryptoError.nativePanic,
    NativeCryptoError.invalidOutput,
  };

  /// Runs [decrypt] for a peer's message. After a failure in
  /// [_undecryptableErrors] the committed group comes back from [previous]
  /// and [decrypt] runs once more on the fresh handle: the failed attempt
  /// may have changed the group in memory, and a native panic leaves the
  /// handle poisoned, so one failure alone must not cost the message.
  /// Returns null only when the retry fails the same way, with the committed
  /// group restored again. Any other error, including a [ratchetAdvanced]
  /// one from either attempt, is rethrown.
  Future<List<int>?> _decryptOrUndecryptable(
      StoredCryptoState previous, List<int> Function() decrypt) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return decrypt();
      } on NativeCryptoException catch (error) {
        if (!_undecryptableErrors.contains(error.kind)) rethrow;
      }
      await _restorePrevious(previous);
    }
    return null;
  }

  /// Replaces the device handle with one restored from [previous]. The new
  /// handle is built before the old one is closed, so [_device] never points
  /// at a closed handle. If the restore fails, the old handle (whose group
  /// state can no longer be trusted) is closed and the device left inactive:
  /// callers fail closed until the session is activated again.
  /// Whether [eventId] of [conversationId] may be applied behind the sync
  /// cursor: only a paused conversation's events above what was replayed
  /// (C1 prerequisite 1). The store re-checks this inside the commit.
  Future<bool> _mayReplay(String conversationId, int eventId) async {
    final pause = await localStore.loadConversationPause(conversationId);
    return pause != null && eventId > pause.resumeAfter;
  }

  /// Refuses MLS work that would change a paused conversation's group: its
  /// state must stay where the failed event left it until a replay applies
  /// the events in order. Queued messages stay queued.
  Future<void> _requireNotPaused(String conversationId) async {
    if (await localStore.loadConversationPause(conversationId) != null) {
      throw ConversationSyncPausedException(conversationId);
    }
  }

  @override
  Future<bool> deviceHandleUsable() => _serial(() async {
        try {
          _requiredDevice().signingPublicKey();
          return true;
        } catch (_) {
          return false;
        }
      });

  Future<void> _restorePrevious(StoredCryptoState previous) async {
    // A pending enrollment holds a fresh device whose key is in the issued
    // credential; reloading stored state would replace it and activation
    // would then seal the wrong device. Refuse before touching the handle.
    if (_pendingEnrollment) {
      throw StateError('crypto state cannot be restored during enrollment');
    }
    _deviceCounter = null;
    ({NativeCryptoDevice device, int counter}) restored;
    try {
      // The committed state, which is [previous] unless a commit landed
      // whose outcome was lost; never an older one.
      restored = await _restoreCommitted(_accountId!, _deviceId!,
          minimumCounter: previous.counter);
    } catch (_) {
      _device?.close();
      _device = null;
      rethrow;
    }
    _device?.close();
    _device = restored.device;
    _deviceCounter = restored.counter;
  }

  static StoredCryptoState _sealedState(
          int counter, List<int> stateKey, NativeChangeSet sealed) =>
      StoredCryptoState(
        counter: counter,
        stateKey: List<int>.from(stateKey),
        sealedState: sealed.root,
        changes: <CryptoRecordChange>[
          for (final change in sealed.changes)
            CryptoRecordChange(
              kind: change.kind,
              recordId: change.id,
              generation: change.generation,
              sealed: change.sealed,
            ),
        ],
      );

  /// Whether [sealed] is a whole-state blob of format 2 or 3 (the version
  /// follows the 8-byte magic). Unauthenticated: it only picks the
  /// migration, which runs every check of the old restore.
  static bool _isLegacyFormat(List<int> sealed) =>
      sealed.length > 10 &&
      sealed[8] == 0 &&
      (sealed[9] == 2 || sealed[9] == 3);

  /// Opens the stored state at activation. A format 2/3 blob is migrated
  /// to records first, one way, in one compare-and-swap commit (D70
  /// section 5); the device then comes from what was stored, so the
  /// migrated records are read back before anything builds on them.
  Future<({NativeCryptoDevice device, int counter})> _openStored(
      String accountId, String deviceId, StoredCryptoState stored,
      {void Function()? checkCanCommit}) async {
    if (_isLegacyFormat(stored.sealedState)) {
      final migrated = _formatChecked(() => bindings.migrateLegacyState(
          accountId,
          deviceId,
          stored.stateKey,
          stored.counter,
          stored.sealedState));
      try {
        final next = stored.counter + 1;
        final sealed = migrated.device.sealChanges(stored.stateKey, next);
        checkCanCommit?.call();
        await localStore.commitCryptoMigration(
          expectedCounter: stored.counter,
          expectedSealedState: stored.sealedState,
          state: _sealedState(next, stored.stateKey, sealed),
          checkCanCommit: checkCanCommit,
        );
      } finally {
        migrated.device.close();
      }
    }
    return _restoreCommitted(accountId, deviceId,
        minimumCounter: stored.counter);
  }

  /// Restores the committed state: the root and every record, read in one
  /// transaction. Its generation must equal the stored counter, which must
  /// be at least [minimumCounter].
  Future<({NativeCryptoDevice device, int counter})> _restoreCommitted(
      String accountId, String deviceId,
      {required int minimumCounter}) async {
    final snapshot = await localStore.loadCryptoSnapshot();
    final state = snapshot.state;
    if (state == null) {
      throw StateError('protected MLS state is unavailable');
    }
    if (state.counter < minimumCounter) {
      throw StateError('MLS rollback counter mismatch');
    }
    final restored = _formatChecked(() => bindings.restoreRecords(
        accountId,
        deviceId,
        state.stateKey,
        state.counter,
        state.sealedState,
        [for (final record in snapshot.records) record.sealed]));
    if (restored.generation != state.counter) {
      restored.device.close();
      throw StateError('MLS rollback counter mismatch');
    }
    return (device: restored.device, counter: restored.generation);
  }

  /// Turns an unsupported format into [CryptoStateFormatUnsupported] so the
  /// app can offer re-linking. Every other failure is rethrown unchanged;
  /// both stay fail-closed.
  T _formatChecked<T>(T Function() open) {
    try {
      return open();
    } on NativeCryptoException catch (error) {
      if (error.kind == NativeCryptoError.stateFormatUnsupported) {
        throw const CryptoStateFormatUnsupported();
      }
      rethrow;
    }
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
        _closeCallGroups();
        _device = null;
        _verdictCache.clear();
        _deviceCounter = null;
        _firstState = null;
        _accountId = null;
        _deviceId = null;
      });
}

/// The app-level form of a native record-limit error: names the
/// conversation when the record is its group (kind 2), else nothing.
CryptoRecordLimitExceeded recordLimitFromNative(
        NativeRecordLimitException error) =>
    CryptoRecordLimitExceeded(
        conversationId: error.recordKind == 2 && error.recordId.isNotEmpty
            ? String.fromCharCodes(error.recordId)
            : null);

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

/// Native refused the downloaded ciphertext itself: its digest, header or a
/// chunk failed authentication. Private to [NativeCryptoService.k2VerifyDownload].
class _K2BundleRejected implements Exception {
  const _K2BundleRejected();
}

/// The clear envelope metadata key that marks a C4 leave notice (a
/// governing member's own `member_leave`); the server's
/// `storage.EnvelopeLeaveNoticeKey`. Its value is always `true`.
const String leaveNoticeMetadataKey = 'c4_leave';

const Set<AppPayloadType> _messageTypes = <AppPayloadType>{
  AppPayloadType.text,
  AppPayloadType.reply,
  AppPayloadType.edit,
  AppPayloadType.delete,
  AppPayloadType.reaction,
  AppPayloadType.attachmentManifest,
  AppPayloadType.pin,
  AppPayloadType.poll,
  AppPayloadType.pollVote,
  AppPayloadType.pollClose,
  AppPayloadType.profileKey,
  AppPayloadType.groupProfileKey,
};

/// The profile keys a payload carries, as store effects (W11). The key body
/// of `profile_key` and its sidecar belong to the sender's own account; the
/// group variants belong to the conversation the message arrived in and only
/// a group takes one. A key that breaks the field rules is dropped alone.
List<MessageEffect> profileKeyEffects(
  DecryptedAppPayload payload, {
  required String conversationId,
  required String senderAccountId,
  required int receivedAt,
  String? conversationKind,
}) {
  final body = payload.body;
  final Object? account;
  final Object? group;
  switch (payload.type) {
    case AppPayloadType.profileKey:
      account = body;
      group = null;
    case AppPayloadType.groupProfileKey:
      account = null;
      group = body;
    case AppPayloadType.text:
    case AppPayloadType.reply:
    case AppPayloadType.attachmentManifest:
    case AppPayloadType.poll:
      account = body[profileKeyBodyName];
      group = body[groupProfileKeyBodyName];
    default:
      return const <MessageEffect>[];
  }
  final effects = <MessageEffect>[];
  // A subject id outside the column's bounds would abort the whole commit.
  if (senderAccountId.isEmpty ||
      senderAccountId.length > 128 ||
      conversationId.isEmpty ||
      conversationId.length > 128) {
    return effects;
  }
  final accountKey = parseProfileKey(account);
  if (accountKey != null) {
    effects.add(ProfileKeyEffect(
        kind: profileSubjectAccount,
        subjectId: senderAccountId,
        key: accountKey.key,
        keyId: accountKey.keyId,
        version: accountKey.version,
        receivedAt: receivedAt));
  }
  final groupKey = parseProfileKey(group);
  // Only a plain group has a group profile; a DM, a community or a channel
  // takes none (C3 may reuse this later). An unknown kind is refused too.
  if (groupKey != null && conversationKind == 'group') {
    effects.add(ProfileKeyEffect(
        kind: profileSubjectConversation,
        subjectId: conversationId,
        key: groupKey.key,
        keyId: groupKey.keyId,
        version: groupKey.version,
        receivedAt: receivedAt));
  }
  return effects;
}

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
  bool senderActsWithRole = true,
}) {
  final body = payload.body;
  final decoration = messageDecoration(body,
      members: authority?.memberAccounts(conversationId) ?? const {});
  final forwarded = body['forwarded'];
  final rawHops = forwarded is Map ? forwarded['hops'] : null;
  final hops = rawHops is int ? rawHops.clamp(1, 5) : null;
  // W11: keys ride in key messages and as sidecars on posts. A key this
  // device sent itself (a pending row) is already held, so only received ones
  // become effects.
  List<MessageEffect> keys() => state == LocalMessageState.pending
      ? const <MessageEffect>[]
      : profileKeyEffects(
          payload,
          conversationId: conversationId,
          senderAccountId: senderAccountId,
          receivedAt: createdAt,
          conversationKind: authority?.conversationKind(conversationId),
        );
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
        ...keys(),
      ],
    AppPayloadType.reply => <MessageEffect>[
        row(LocalMessageKind.text,
            text: body['text'] as String,
            replyTo: body['reply_to_id'] as String),
        ...keys(),
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
          moderatorProtects: senderActsWithRole
              ? moderatorProtectsFor(authority, conversationId, senderAccountId)
              : null,
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
        ...keys(),
      ],
    AppPayloadType.pin => <MessageEffect>[
        row(LocalMessageKind.action),
        if (pinAllowed(
            kind: authority?.conversationKind(conversationId),
            role: senderActsWithRole
                ? authority?.roleOf(conversationId, senderAccountId)
                : null))
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
    AppPayloadType.poll => <MessageEffect>[
        row(LocalMessageKind.poll, text: pollRowBody(body)),
        ...keys(),
      ],
    AppPayloadType.profileKey ||
    AppPayloadType.groupProfileKey =>
      <MessageEffect>[
        row(LocalMessageKind.action),
        ...keys(),
      ],
    AppPayloadType.pollVote => <MessageEffect>[
        row(LocalMessageKind.action),
        PollVoteEffect(
          targetKey: body['message_id'] as String,
          voterAccountId: senderAccountId,
          choices: (body['choices'] as List).cast<int>(),
          conversationId: conversationId,
          channelId: payload.channelId,
        ),
      ],
    AppPayloadType.pollClose => <MessageEffect>[
        row(LocalMessageKind.action),
        PollCloseEffect(
          targetKey: body['message_id'] as String,
          closerAccountId: senderAccountId,
          conversationId: conversationId,
          channelId: payload.channelId,
        ),
      ],
    AppPayloadType.callSignal =>
      throw const FormatException('call signals are not messages'),
    AppPayloadType.infoKey ||
    AppPayloadType.infoKeyRequest ||
    AppPayloadType.infoUpdate =>
      throw const FormatException('community info payloads are not messages'),
    AppPayloadType.memberLeave ||
    AppPayloadType.memberLeaveSigned =>
      throw const FormatException('leave proofs are not messages'),
    AppPayloadType.deviceListAlert =>
      throw const FormatException('device list alerts are not messages'),
    AppPayloadType.historyChange ||
    AppPayloadType.historySync ||
    AppPayloadType.historySyncRequest =>
      throw const FormatException('C7 history payloads are not messages'),
    AppPayloadType.reportKey ||
    AppPayloadType.reportKeyRequest =>
      throw const FormatException('report key payloads are not messages'),
  };
}

/// The stored form of a received C3 payload ([infoPayloadTypes]), tied to
/// the MLS-authenticated sender and the conversation it arrived in. The body
/// was validated by [AppPayloadCodec]. [epoch] is the MLS epoch the message
/// was encrypted in, which only a successful decryption authenticates.
CommunityInfoEvent communityInfoEventFor(
  DecryptedAppPayload payload, {
  required String conversationId,
  required String senderAccountId,
  required String senderDeviceId,
  required int? epoch,
}) {
  final body = payload.body;
  final kind = switch (payload.type) {
    AppPayloadType.infoKey => CommunityInfoEventKind.key,
    AppPayloadType.infoKeyRequest => CommunityInfoEventKind.keyRequest,
    AppPayloadType.infoUpdate => CommunityInfoEventKind.update,
    _ => throw ArgumentError.value(payload.type, 'type', 'not an info type'),
  };
  return CommunityInfoEvent(
    kind: kind,
    subjectKind: body['subject_kind'] as String,
    subjectId: body['subject_id'] as String,
    conversationId: conversationId,
    senderAccountId: senderAccountId,
    senderDeviceId: senderDeviceId,
    keyId: kind == CommunityInfoEventKind.keyRequest
        ? null
        : body['key_id'] as String,
    key: kind == CommunityInfoEventKind.key ? infoKeyBytes(body) : null,
    revision:
        kind == CommunityInfoEventKind.update ? body['revision'] as int : null,
    recordSha256: kind == CommunityInfoEventKind.update
        ? body['record_sha256'] as String
        : null,
    epoch: epoch,
  );
}

String _randomIdempotencyKey() => _randomBytes(24)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

/// The epoch an MLS commit was built on, read from its clear header, or null
/// when [message] is not an MLS 1.0 public or private message of the group
/// [groupId]. RFC 9420 §6: `MLSMessage` starts with the protocol version
/// (u16, 1) and wire format (u16: 1 public, 2 private); both framings then
/// carry `opaque group_id<V>` and `uint64 epoch`.
int? mlsMessageEpoch(List<int> message, String groupId) {
  var offset = 0;
  int? u16() {
    if (offset + 2 > message.length) return null;
    final value = (message[offset] << 8) | message[offset + 1];
    offset += 2;
    return value;
  }

  if (u16() != 1) return null;
  final wireFormat = u16();
  if (wireFormat != 1 && wireFormat != 2) return null;
  // The variable-length size of group_id (RFC 9420 §2.1.2): the top two
  // bits of the first byte give 1, 2 or 4 bytes; 0b11 is invalid.
  if (offset >= message.length) return null;
  final prefix = message[offset] >> 6;
  if (prefix == 3) return null;
  final sizeBytes = 1 << prefix;
  if (offset + sizeBytes > message.length) return null;
  var length = message[offset] & 0x3f;
  for (var index = 1; index < sizeBytes; index++) {
    length = (length << 8) | message[offset + index];
  }
  offset += sizeBytes;
  // The bytes the bindings send as the group ID (`native_crypto_bindings.dart`
  // passes `Uint8List.fromList(groupId.codeUnits)`), so a header matches the
  // group the native side created, whatever characters the ID holds.
  final expected = Uint8List.fromList(groupId.codeUnits);
  if (length != expected.length || offset + length + 8 > message.length) {
    return null;
  }
  for (var index = 0; index < length; index++) {
    if (message[offset + index] != expected[index]) return null;
  }
  offset += length;
  // An epoch above 2^63 - 1 is not one this app could have reached.
  if (message[offset] & 0x80 != 0) return null;
  var epoch = 0;
  for (var index = 0; index < 8; index++) {
    epoch = (epoch << 8) | message[offset + index];
  }
  return epoch;
}

/// C5: the accounts [actor] may not moderate in [conversationId] under the
/// verified role record the app holds for it (C4; a community channel uses
/// its shared group's), or null when there is no record or [actor] is below
/// moderator. Everyone else's messages it may delete (`mayActOn`): an
/// account the record does not name is a member.
Set<String>? moderatorProtectsFor(
    ConversationAuthority? authority, String conversationId, String actor) {
  final roles =
      authority is VerifiedRoleSource ? authority as VerifiedRoleSource : null;
  final GovernanceState? record;
  try {
    record = roles?.governanceOf(conversationId);
  } catch (_) {
    return null;
  }
  if (record == null || record.rankOf(actor) < BuiltInRole.moderator.rank) {
    return null;
  }
  final rank = record.rankOf(actor);
  return <String>{
    actor,
    for (final account in <String>{
      if (record.owner != null) record.owner!,
      ...record.admins.keys,
      ...record.moderators,
    })
      if (record.rankOf(account) >= rank) account,
  };
}

class _TrackedCallGroup extends ScratchCallGroupHandle {
  _TrackedCallGroup(super.device, super.bindings, {required this.onClose});
  final void Function(_TrackedCallGroup handle) onClose;

  @override
  void close() {
    super.close();
    onClose(this);
  }
}

// C7 full mode inside the native service (docs/designs/C7-channel-history.md,
// decisions 2 to 5): records under C4 authority, per-channel chains,
// generation keys, the rekey at a removal merge, `history_sync` slots and
// duties, and the `keyless` and `unsure` states. Every state change is
// returned as settings for the same local transaction as the MLS step that
// causes it (decision 5, "One local transaction").

/// A newcomer asks for its `history_sync` when none arrived this long after
/// its Welcome (decision 5, `history_sync_request`).
const Duration c7RequestDelay = Duration(seconds: 60);

/// Members other than the committer wait [c7FallbackBase] plus up to
/// [c7FallbackPerMember] per member at random, at most [c7FallbackCap],
/// before sending a `history_sync` of their own (decision 5, "Duty").
const Duration c7FallbackBase = Duration(seconds: 20);
const Duration c7FallbackPerMember = Duration(seconds: 2);
const Duration c7FallbackCap = Duration(minutes: 10);

/// Posts sealed under a generation key. Control payloads never are.
const Set<AppPayloadType> c7HistoryPostTypes = <AppPayloadType>{
  AppPayloadType.text,
  AppPayloadType.reply,
  AppPayloadType.attachmentManifest,
  AppPayloadType.poll,
};

/// Actions that name a target post (`message_id`): sealed under the current
/// generation only when their target was sealed in the current period and
/// the channel is `ok` (decision 7). A moderator's delete is a `delete`.
const Set<AppPayloadType> c7TargetedTypes = <AppPayloadType>{
  AppPayloadType.edit,
  AppPayloadType.delete,
  AppPayloadType.reaction,
  AppPayloadType.pin,
  AppPayloadType.pollVote,
  AppPayloadType.pollClose,
};

const Map<String, String?> _c7None = <String, String?>{};

/// Clear metadata of a group-level C7 message (owner answer Q3): the epoch a
/// `history_sync` answers, which the server delivers only to the devices that
/// joined at it, and the epoch a newcomer's request asks for (its own join).
const String c7SyncForEpochKey = 'c7_sync_for_epoch';
const String c7SyncRequestForEpochKey = 'c7_sync_request_for_epoch';

extension _C7Engine on NativeCryptoService {
  bool _c7Active(String conversationId) =>
      c7SealedBodies &&
      c7CommunityKind(_authority?.conversationKind(conversationId));

  String? _c7CommunityOf(String conversationId) => switch (_authority) {
        final ConversationCommunitySource source =>
          source.conversationCommunity(conversationId),
        _ => null,
      };

  Future<C7GroupState> _c7LoadGroup(String conversationId) async =>
      C7GroupState.decode(
          await localStore.loadSetting(c7GroupSetting(conversationId)));

  Future<C7ChannelBook> _c7LoadBook(
          String conversationId, String channelId) async =>
      C7ChannelBook.decode(
          await localStore
              .loadSetting(c7ChannelSetting(conversationId, channelId)),
          channelId,
          conversationId);

  /// The channels a `history_sync` from this device names besides those it
  /// keeps a chain for: the server's list and a private group's own channel
  /// (decision 5, "Channels named, not assumed").
  Set<String> _c7KnownChannels(String conversationId, C7GroupState group) {
    final authority = _authority;
    return <String>{
      ...group.channels,
      if (authority is C7ChannelListSource)
        ...(authority as C7ChannelListSource).c7Channels(conversationId),
      if (_c7PrivateChannel(conversationId) case final String channel) channel,
    };
  }

  /// The settings that store [group] and [books] (each book's channel joins
  /// the group's channel list).
  Map<String, String?> _c7Put(String conversationId, C7GroupState group,
      Iterable<C7ChannelBook> books) {
    final out = <String, String?>{};
    final channels = <String>{...group.channels};
    for (final book in books) {
      out[c7ChannelSetting(conversationId, book.channelId)] = book.encode();
      channels.add(book.channelId);
    }
    out[c7GroupSetting(conversationId)] =
        group.copyWith(channels: channels).encode();
    return out;
  }

  Map<String, String?> _c7Wipe(String conversationId, C7GroupState group) =>
      <String, String?>{
        c7GroupSetting(conversationId): null,
        c7ImportSetting(conversationId): null,
        for (final channel in group.channels)
          c7ChannelSetting(conversationId, channel): null,
      };

  int _c7NowMs() => _clock().toUtc().millisecondsSinceEpoch;

  int _c7FallbackDelayMs(String conversationId) {
    int members;
    try {
      members = _requiredDevice().groupMembers(conversationId).length;
    } on Object {
      members = 2;
    }
    final spread = c7FallbackPerMember.inMilliseconds * members;
    final delay = c7FallbackBase.inMilliseconds +
        (spread <= 0 ? 0 : Random.secure().nextInt(spread + 1));
    return delay > c7FallbackCap.inMilliseconds
        ? c7FallbackCap.inMilliseconds
        : delay;
  }

  /// The account and signing key of [deviceId] in the group's current tree,
  /// or null when it holds no leaf there (decision 8: records and slots are
  /// checked only against keys in the tree).
  ({String accountId, Uint8List key})? _c7TreeKey(
      String conversationId, String deviceId) {
    try {
      for (final leaf in _requiredDevice().groupMembers(conversationId)) {
        if (utf8.decode(leaf.deviceId) == deviceId) {
          return (
            accountId: utf8.decode(leaf.accountId),
            key: Uint8List.fromList(leaf.signingKey),
          );
        }
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// D80 and C4: a record's actor is an owner or admin in the verified role
  /// record the app holds (a private channel's group is judged by its
  /// shared group's, which the authority maps). No record, no authority.
  bool _c7MayRecord(String conversationId, String accountId) {
    final authority = _authority;
    if (authority is! VerifiedRoleSource) return false;
    final GovernanceState? record;
    try {
      record = (authority as VerifiedRoleSource).governanceOf(conversationId);
    } on Object {
      return false;
    }
    return record != null && record.rankOf(accountId) >= BuiltInRole.admin.rank;
  }

  /// A record applied after this device already merged a later removal
  /// opened a generation that removal closes: the removal's generation is
  /// derived from the kept root (decision 5, "Rekey").
  C7ChannelBook _c7CatchUp(
      C7ChannelBook book, C7GroupState group, String communityId) {
    final root = group.root;
    final rootEpoch = group.rootEpoch;
    if (root == null ||
        rootEpoch == null ||
        book.mode != c7ModeFull ||
        book.gens.isEmpty ||
        book.gens.last.epoch >= rootEpoch) {
      return book;
    }
    return book.rekey(
        rootEpoch,
        C7Keys(bindings).rekeyChk(
            root: root, communityId: communityId, channelId: book.channelId));
  }

  // ---- commits and Welcomes -------------------------------------------------

  /// The C7 change a merged commit makes, for the same MLS transition. Empty
  /// while C7 is off or outside community conversations. A commit that
  /// removed this device deletes the group's C7 state (the re-add wipe). A
  /// removal rekeys every `full` channel of the group from the exporter root
  /// MLS returned; every membership commit fixes the slot snapshot and the
  /// `history_sync` duty, due at once when this device committed ([own])
  /// and after a jittered delay otherwise.
  Future<Map<String, String?>> _c7Commit(
      String conversationId, C7CommitOutcome outcome,
      {required bool own}) async {
    if (!_c7Active(conversationId)) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    final next = group.afterCommit(outcome);
    if (next == null) return _c7Wipe(conversationId, group);
    if (!outcome.membership) return _c7None;
    final epoch = outcome.newEpoch;
    final community = _c7CommunityOf(conversationId);
    final root = outcome.removedAny ? outcome.root : null;
    final books = <C7ChannelBook>[];
    for (final channel in group.channels) {
      final book = await _c7LoadBook(conversationId, channel);
      books.add(root != null && community != null
          ? book.rekey(
              epoch,
              C7Keys(bindings).rekeyChk(
                  root: root, communityId: community, channelId: channel))
          : book);
    }
    final due = _c7NowMs() + (own ? 0 : _c7FallbackDelayMs(conversationId));
    return _c7Put(
      conversationId,
      next.withSnapshot(
        epoch,
        <String, C7SlotSnapshot>{
          for (final book in books) book.channelId: book.snapshot(epoch),
        },
        due,
      ),
      books,
    );
  }

  /// A Welcome made this device a newcomer at [joinEpoch]: state left under
  /// the group id from an earlier membership is dropped (Trace 4, the re-add
  /// wipe) and the request timer starts.
  Future<Map<String, String?>> _c7Welcome(
      String conversationId, int joinEpoch) async {
    if (!c7SealedBodies) return _c7None;
    final old = await _c7LoadGroup(conversationId);
    return <String, String?>{
      ..._c7Wipe(conversationId, old),
      c7GroupSetting(conversationId): C7GroupState.joined(joinEpoch,
              requestDueAtMs: _c7NowMs() + c7RequestDelay.inMilliseconds)
          .encode(),
    };
  }

  // ---- unsure ---------------------------------------------------------------

  /// This device met a message in [conversationId] it could not fully apply
  /// (decision 5, "Unsure"): every `full` channel of the group keeps the
  /// group's current epoch as its miss epoch, and an `ok` one turns
  /// `unsure`. The current epoch, never the message's own: a server could
  /// label a message low, and nothing at or below the miss epoch clears it.
  Future<Map<String, String?>> _c7Miss(String conversationId) async {
    if (!_c7Active(conversationId)) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    if (group.channels.isEmpty) return _c7None;
    final int epoch;
    try {
      epoch = _requiredDevice().groupEpoch(conversationId).epoch;
    } on Object {
      return _c7None;
    }
    final changed = <C7ChannelBook>[];
    for (final channel in group.channels) {
      final book = await _c7LoadBook(conversationId, channel);
      if (book.mode == c7ModeFull) changed.add(book.markUnsure(epoch));
    }
    return changed.isEmpty ? _c7None : _c7Put(conversationId, group, changed);
  }

  /// The `gen` trigger for a live post (decision 5, "Unsure"): an `ok` `full`
  /// channel whose post at [epoch] was not sealed under the generation this
  /// device holds as current there turns `unsure`, unless the signed `gen`
  /// is 0 or below the current period's start. A live member reads the
  /// signed `gen` only by checking the signature against those candidates:
  /// 0 and the past generations it remembers. A sender in an older period
  /// whose `gen` this device never held is so taken as out of step (a gap,
  /// never a leak). [gen] is the generation the post was sealed under when
  /// it is the current one ([c7GenTag]), for its row (decision 7).
  Future<({Map<String, String?> settings, String? gen})> _c7GenCheck({
    required ReceivedMessageEnvelope envelope,
    required String channelId,
    required int epoch,
    required C7Opened opened,
  }) async {
    final conversationId = envelope.conversationId;
    const none = (settings: _c7None, gen: null);
    final community = _c7CommunityOf(conversationId);
    if (community == null) return none;
    final book = await _c7LoadBook(conversationId, channelId);
    if (book.mode != c7ModeFull || book.status != C7Status.ok) return none;
    final gen = book.genAt(conversationId, epoch);
    final key = gen?.key;
    if (key != null && gen!.epoch != 0) {
      final expected = C7Keys(bindings).postBodyKey(
        chk: key,
        communityId: community,
        channelId: channelId,
        senderDeviceId: envelope.senderDeviceId,
        actionId: envelope.idempotencyKey,
      );
      final same = c7SameBytes(expected, opened.bodyKey);
      expected.fillRange(0, expected.length, 0);
      if (same) return (settings: _c7None, gen: c7GenTag(key));
    }
    final signer = _c7TreeKey(conversationId, envelope.senderDeviceId);
    if (signer != null) {
      final start = book.periodStart ?? 0;
      for (final candidate in <int>{
        0,
        for (final past in book.pastGens)
          if (past < start) past,
      }) {
        final bool valid;
        try {
          valid = bindings.c7Verify(
            domain: c7PostSignatureDomain,
            publicKey: signer.key,
            message: c7PostSignedFields(
              communityId: community,
              channelId: channelId,
              actionId: envelope.idempotencyKey,
              groupId: conversationId,
              epoch: epoch,
              senderDeviceId: envelope.senderDeviceId,
              generation: candidate,
              paddedVap1: opened.paddedVap1,
            ),
            signature: opened.signature,
          );
        } on Object {
          continue;
        }
        if (valid) return none;
      }
    }
    final group = await _c7LoadGroup(conversationId);
    return (
      settings: await _c7Put(conversationId, group, <C7ChannelBook>[
        book.markUnsure(_requiredDevice().groupEpoch(conversationId).epoch),
      ]),
      gen: null,
    );
  }

  /// [effects] with the row [key] recorded as sealed under the C7
  /// generation [gen] (decision 7); unchanged when [gen] is null.
  List<MessageEffect> _c7Recorded(
          List<MessageEffect> effects, String key, String? gen) =>
      gen == null
          ? effects
          : <MessageEffect>[
              for (final effect in effects)
                effect is InsertMessageEffect && effect.key == key
                    ? effect.withC7Gen(gen)
                    : effect,
            ];

  // ---- records ----------------------------------------------------------------

  /// A `history_change` proposal that decrypted live (decision 4). Checked
  /// before the table: a sender its list has not removed (D119), freshness
  /// against the membership floor, the actor's authority in the verified
  /// role record, and the signature against the actor's key in the current
  /// tree. An invalid record leaves its hidden action row and changes
  /// nothing. Returns the settings for the message's transition.
  Future<Map<String, String?>> _c7ApplyProposal(
    ReceivedMessageEnvelope envelope,
    DecryptedAppPayload payload, {
    required String? routeChannel,
    required int? epoch,
    required LeafVerdict? verdict,
  }) async {
    final conversationId = envelope.conversationId;
    if (!_c7Active(conversationId) ||
        epoch == null ||
        verdict != LeafVerdict.approved) {
      return _c7None;
    }
    final community = _c7CommunityOf(conversationId);
    final channel = payload.channelId ?? routeChannel;
    if (community == null || channel == null) return _c7None;
    final C7CompactRecord compact;
    final C7Record record;
    try {
      compact =
          C7CompactRecord.decode(base64Decode(payload.body['r']! as String));
      record = compact.expand(C7RecordContext(
        communityId: utf8.encode(community),
        channelId: utf8.encode(channel),
        groupId: utf8.encode(conversationId),
        epoch: epoch,
        actorDeviceId: utf8.encode(envelope.senderDeviceId),
      ));
    } on Object {
      return _c7None;
    }
    // A move is C3's conversion, not built: it stays an invalid record.
    if (record.reason == c7ReasonMove) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    if (record.epoch < group.floor) return _c7None;
    if (!_c7MayRecord(conversationId, envelope.senderAccountId)) {
      return _c7None;
    }
    final signer = _c7TreeKey(conversationId, envelope.senderDeviceId);
    if (signer == null ||
        signer.accountId != envelope.senderAccountId ||
        !c7VerifyRecord(bindings, record, signer.key)) {
      return _c7None;
    }
    final book = await _c7LoadBook(conversationId, channel);
    final step = book.applyRecord(record, record.encode(),
        source: C7Source.proposalLive, key: compact.key);
    if (step.row == C7Row.invalid) return _c7None;
    return _c7Put(conversationId, group, <C7ChannelBook>[
      book.lineAfter(_c7CatchUp(step.book, group, community),
          messageKey(envelope.senderDeviceId, envelope.idempotencyKey)),
    ]);
  }

  /// This device's own record came back in sync order ([actionId]): it is
  /// applied now, or reported stale (sequenced after a membership commit:
  /// the app proposes it again) or lost (decision 4, "Own proposals").
  Future<Map<String, String?>> _c7OwnEcho(
      String conversationId, String actionId) async {
    if (!_c7Active(conversationId)) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    final community = _c7CommunityOf(conversationId);
    for (final channel in group.channels) {
      final book = await _c7LoadBook(conversationId, channel);
      final late = book.late.where((p) => p.actionId == actionId).firstOrNull;
      if (late != null) {
        // A proposal that timed out came back after all. Other devices
        // apply it, so this one does too (or this device would keep a key
        // the channel dropped); a newer own proposal for the same seq is
        // then lost, as for anyone else's record.
        final rest = book.withoutLate(actionId);
        final record = late.full;
        if (record.epoch < group.floor ||
            !_c7MayRecord(conversationId, _accountId!)) {
          return _c7Put(conversationId, group, <C7ChannelBook>[rest]);
        }
        final step = rest.applyRecord(record, late.record,
            source: C7Source.proposalLive, key: late.key);
        return _c7Put(conversationId, group, <C7ChannelBook>[
          rest.lineAfter(
              community == null
                  ? step.book
                  : _c7CatchUp(step.book, group, community),
              messageKey(_deviceId!, actionId)),
        ]);
      }
      final pending = book.pending;
      if (pending == null || pending.actionId != actionId) continue;
      final record = pending.full;
      if (record.epoch < group.floor) {
        // Kept, so the app can propose the same setting again.
        return _c7Put(conversationId, group,
            <C7ChannelBook>[book.copyWith(ownNotice: 'stale')]);
      }
      if (!_c7MayRecord(conversationId, _accountId!)) {
        return _c7Put(conversationId, group, <C7ChannelBook>[
          book.copyWith(clearPending: true, ownNotice: 'lost'),
        ]);
      }
      final step = book.applyRecord(record, pending.record,
          source: C7Source.proposalLive, key: pending.key, ownProposal: true);
      return _c7Put(conversationId, group, <C7ChannelBook>[
        book.lineAfter(
            community == null
                ? step.book
                : _c7CatchUp(step.book, group, community),
            messageKey(_deviceId!, actionId)),
      ]);
    }
    // Review M1: an own record this device released (cancelled while it
    // was being sent, or given up after a refusal) came back after all.
    // Every other device has applied it, and its key and mode are gone
    // here, so the group fails closed: every `full` channel turns `unsure`
    // and seals under random keys until a rekey, as for a message this
    // device could not apply.
    if (group.released.contains(actionId)) {
      return _c7Miss(conversationId);
    }
    return _c7None;
  }

  // ---- history_sync -----------------------------------------------------------

  /// A live `history_sync` (decision 5). A member checks each reported head
  /// against its chain (the actor's key in the tree, the actor's authority),
  /// takes a key it was missing, clears `unsure` for its own head and key,
  /// and settles its duty when the slots carry its own snapshot. A newcomer
  /// adopts heads and generations on the word of its MLS-authenticated
  /// sender when the head's actor has left (trust limits). A `history_sync`
  /// whose slots do not all open is a message this device could not fully
  /// apply.
  Future<Map<String, String?>> _c7ApplySync(
    ReceivedMessageEnvelope envelope,
    DecryptedAppPayload payload,
    Uint8List trailer, {
    required int? epoch,
    required LeafVerdict? verdict,
  }) async {
    final conversationId = envelope.conversationId;
    if (!_c7Active(conversationId)) return _c7None;
    final community = _c7CommunityOf(conversationId);
    if (community == null) return _c7None;
    final slots = c7OpenSlots(
      bindings: bindings,
      body: payload.body,
      trailer: trailer,
      communityId: community,
      conversationId: conversationId,
      senderDeviceId: envelope.senderDeviceId,
      actionId: envelope.idempotencyKey,
    );
    if (slots == null) return _c7Miss(conversationId);
    // D119: a leaf its list removed hands nothing over.
    if (verdict != LeafVerdict.approved) return _c7None;
    final forEpoch = payload.body['for_epoch']! as int;
    var group = await _c7LoadGroup(conversationId);
    // `for_epoch` is the epoch a membership commit produced (decision 5):
    // one this device merged (its snapshot, its floor) or joined at, and
    // never after the epoch MLS authenticated for the message itself. Any
    // other value could clear `unsure` or settle a duty with no commit.
    if (epoch == null ||
        forEpoch > epoch ||
        !(group.snapshots.containsKey(forEpoch) ||
            forEpoch == group.floor ||
            forEpoch == group.joinEpoch)) {
      return _c7None;
    }
    final known = _c7KnownChannels(conversationId, group);
    final mine = group.snapshots[forEpoch];
    var matches = mine != null;
    final listed = <String>{for (final slot in slots) slot.channelId};
    final changed = <C7ChannelBook>[];
    // Owner answer 2026-11-12, "Newcomer keeps asking": a newcomer counts a
    // `history_sync` for its join only when it is usable, so a junk or
    // keyless one cannot stop it asking. Channels it leaves unsettled stay
    // without a head (a later one may fill them); none of its slots is
    // adopted as `keyless`.
    final newcomer = group.joinEpoch != null &&
        !group.joinSynced &&
        forEpoch >= group.joinEpoch!;
    final settled = <String>{};
    for (final slot in slots) {
      final own = mine?[slot.channelId];
      if (own != null &&
          own.key != null &&
          (!c7SameBytes(own.key, slot.key) ||
              !c7SameBytes(own.plain, slot.plain))) {
        matches = false;
      }
      if (!known.contains(slot.channelId)) continue;
      if (slot.headIsZero) {
        // No record for the channel: nothing to adopt, nothing missing
        // (withholding a key this way is a trust limit, not a starvation).
        settled.add(slot.channelId);
        continue;
      }
      final C7Record record;
      final C7GenerationEntry? entry;
      try {
        record = C7Record.decode(slot.head);
        entry = C7GenerationEntry.decode(slot.entry);
      } on Object {
        matches = false;
        continue;
      }
      if (utf8.decode(record.channelId) != slot.channelId ||
          utf8.decode(record.communityId) != community ||
          utf8.decode(record.groupId) != conversationId ||
          record.epoch > forEpoch ||
          record.reason == c7ReasonMove) {
        continue;
      }
      final book = await _c7LoadBook(conversationId, slot.channelId);
      final signer =
          _c7TreeKey(conversationId, utf8.decode(record.actorDeviceId));
      if (book.hasHead) {
        if (signer == null ||
            !c7VerifyRecord(bindings, record, signer.key) ||
            !_c7MayRecord(conversationId, signer.accountId)) {
          continue;
        }
      } else if (signer != null &&
          !c7VerifyRecord(bindings, record, signer.key)) {
        continue;
      }
      final step = book.applyRecord(record, Uint8List.fromList(slot.head),
          source: C7Source.report, key: slot.key, entry: entry);
      if (step.row == C7Row.invalid) continue;
      var next = _c7CatchUp(step.book, group, community);
      if (step.row == C7Row.noop && entry != null) {
        next = next.confirmedBySlot(forEpoch, slot.key, entry);
      }
      if (newcomer && !book.hasHead && next.status != C7Status.ok) {
        // A head whose key does not work: not adopted, so a usable
        // `history_sync` asked for later still finds the channel empty.
        continue;
      }
      if (next.hasHead && next.status == C7Status.ok) {
        settled.add(slot.channelId);
      }
      changed.add(next);
    }
    // Every channel this device hands a key over for must be in the slots.
    if (mine != null) {
      for (final entry in mine.entries) {
        if (entry.value.key != null && !listed.contains(entry.key)) {
          matches = false;
        }
      }
    }
    final duty = group.duties[forEpoch];
    if (matches && duty != null && !duty.settled) {
      group = group.withDuty(
          forEpoch, C7SyncDuty(dueAtMs: duty.dueAtMs, settled: true));
    }
    if (newcomer) {
      // Usable: every channel this device knows is settled, by this
      // message or by a verified head it already holds with a working key.
      for (final channel in known) {
        if (settled.contains(channel)) continue;
        final held = changed.where((b) => b.channelId == channel).firstOrNull ??
            await _c7LoadBook(conversationId, channel);
        if (held.hasHead && held.status == C7Status.ok) settled.add(channel);
      }
      if (settled.containsAll(known)) {
        group = group.copyWith(joinSynced: true, clearRequest: true);
      } else if (group.requestDueAtMs == null) {
        group = group.copyWith(
            requestDueAtMs: _c7NowMs() +
                c7RequestDelayAfter(group.requestsSent).inMilliseconds);
      }
    }
    return _c7Put(conversationId, group, changed);
  }

  /// A newcomer's `history_sync_request` (decision 5): a member holding the
  /// snapshot for that commit sends again after its jittered delay, unless a
  /// matching `history_sync` arrives first.
  Future<Map<String, String?>> _c7ApplyRequest(
      String conversationId, DecryptedAppPayload payload) async {
    if (!_c7Active(conversationId)) return _c7None;
    final forEpoch = payload.body['for_epoch'];
    if (forEpoch is! int) return _c7None;
    final group = await _c7LoadGroup(conversationId);
    if (!group.snapshots.containsKey(forEpoch)) return _c7None;
    return _c7Put(
        conversationId,
        group.withDuty(
            forEpoch,
            C7SyncDuty(
                dueAtMs: _c7NowMs() + _c7FallbackDelayMs(conversationId))),
        const <C7ChannelBook>[]);
  }

  // ---- sending ------------------------------------------------------------------

  /// The generation a message of [type] in [channelId] seals under at
  /// [epoch], or null (a random key; I4). A post seals under it while the
  /// channel is `full` and `ok`; an action naming a target (decision 7)
  /// only when its target's row records a generation of the current period
  /// too, so an edit's new text never reaches a newcomer who could not read
  /// the post. A target this device holds no generation for (sealed under
  /// a random key, before this period, before schema 41, or restored from
  /// a snapshot) gets a random key: a gap, never a leak.
  Future<C7Gen?> _c7SealGen(String conversationId, String? channelId,
      AppPayloadType type, int epoch, Map<String, Object?> body) async {
    final post = c7HistoryPostTypes.contains(type);
    if (channelId == null ||
        !(post || c7TargetedTypes.contains(type)) ||
        !_c7Active(conversationId)) {
      return null;
    }
    final book = await _c7LoadBook(conversationId, channelId);
    final generation = book.sealGenAt(epoch);
    if (generation == null || post) return generation;
    final target = body['message_id'];
    if (target is! String) return null;
    final row = await localStore.loadMessage(target);
    final sealed = row?.c7Gen;
    if (row == null || row.conversationId != conversationId || sealed == null) {
      return null;
    }
    return book.sealedInPeriod(sealed) ? generation : null;
  }

  /// Queues one hidden C7 message (a record, a `history_sync` or its
  /// request). [channelId] is null for a group-level message. [build] makes
  /// the padded VAP1 and the trailer (a `history_sync`'s slots) from the
  /// action id; [settingsFor] the C7 settings that commit with the outbox
  /// row. C7 types carry no `frank` member and a random `frank_commit`
  /// (decision 3, "Franking"). Runs inside [_serial].
  Future<MessageEnvelope> _c7SendHidden(
    String conversationId, {
    required String? channelId,
    required int? layoutGeneration,
    required ({Uint8List vap1, Uint8List trailer}) Function(
            String actionId, int epoch)
        build,
    required Map<String, String?> Function(String actionId, int epoch)
        settingsFor,
    ({Uint8List chk, int generation})? seal,
    Map<String, Object?> target = const <String, Object?>{},
  }) async {
    await _requireNotPaused(conversationId);
    await _requireApproved(conversationId);
    final community = _c7CommunityOf(conversationId);
    if (community == null || community.isEmpty) {
      throw StateError('C7 needs the community of this conversation');
    }
    final sharedGroup =
        _authority?.conversationKind(conversationId) == 'community_shared';
    if (sharedGroup && channelId != null && layoutGeneration == null) {
      throw StateError('a shared group channel needs its layout generation');
    }
    final previous = await _requiredState();
    final cursor = await localStore.loadSyncCursor();
    if (!await localStore.hasOutboxCapacity()) {
      throw const OutboxFullException();
    }
    try {
      final actionId = _randomIdempotencyKey();
      final deviceId = _deviceId!;
      final device = _requiredDevice();
      final epoch = device.groupEpoch(conversationId).epoch;
      final parts = build(actionId, epoch);
      final sealed = c7SealMessage(
        bindings: bindings,
        sign: (message) =>
            device.c7Sign(domain: c7PostSignatureDomain, message: message),
        communityId: community,
        conversationId: conversationId,
        channelId: channelId,
        senderDeviceId: deviceId,
        actionId: actionId,
        epoch: epoch,
        paddedVap1: parts.vap1,
        chk: seal?.chk,
        generation: seal?.generation ?? 0,
        trailer: parts.trailer,
      );
      final envelope = MessageEnvelope(
        conversationId: conversationId,
        idempotencyKey: actionId,
        ciphertext: device.encrypt(conversationId, sealed.reference),
        cryptoProtocol: 'mls10-openmls-v1',
        cryptoMetadata: <String, Object?>{
          'protocol_version': 1,
          'group_id': conversationId,
          'content_type': 'application',
          'payload_version': 1,
          if (channelId != null) 'channel_id': channelId,
          if (channelId != null && sharedGroup)
            'community_layout_generation': layoutGeneration,
          'mls_epoch': epoch,
          // Owner answer Q3: a group-level message names which type it is
          // and for which epoch, so the server delivers a history_sync only
          // to the devices that commit added (and dedups it).
          ...target,
        },
        frankCommit: _randomBytes(32),
        sealedBody: sealed.sealedBody,
      );
      await localStore.commitOutgoingApplicationTransition(
        OutgoingApplicationStateTransition(
          expectedCounter: previous.counter,
          expectedCursor: cursor,
          state: _sealNext(previous),
          envelope: envelope,
          messageEffects: <MessageEffect>[
            InsertMessageEffect(
              key: messageKey(deviceId, actionId),
              conversationId: conversationId,
              senderAccountId: _accountId!,
              senderDeviceId: deviceId,
              kind: LocalMessageKind.action,
              senderHidden: true,
              channelId: sharedGroup ? channelId : null,
              createdAt: _c7NowMs(),
              state: LocalMessageState.pending,
            ),
          ],
          c7Settings: settingsFor(actionId, epoch),
        ),
      );
      return envelope;
    } catch (_) {
      await _restorePrevious(previous);
      rethrow;
    }
  }

  Future<MessageEnvelope> _c7Propose(
    String conversationId,
    String channelId, {
    required bool full,
    required bool create,
    required int? layoutGeneration,
  }) async {
    if (!_c7Active(conversationId)) {
      throw StateError('C7 is off for this conversation');
    }
    final community = _c7CommunityOf(conversationId);
    if (community == null) throw StateError('C7 needs the community');
    final sharedGroup =
        _authority?.conversationKind(conversationId) == 'community_shared';
    if (!sharedGroup && channelId != _c7PrivateChannel(conversationId)) {
      throw StateError('a private group holds only its own channel');
    }
    if (!_c7MayRecord(conversationId, _accountId!)) {
      throw StateError('only owners and admins change the history setting');
    }
    final group = await _c7LoadGroup(conversationId);
    // A proposal pending past its timeout no longer blocks (owner,
    // 2026-11-12); it moves to `late` in the write that stores this one.
    var book = (await _c7LoadBook(conversationId, channelId))
        .expirePending(_c7NowMs());
    if (book.pending != null && book.ownNotice != 'stale') {
      throw StateError('a history change is already pending here');
    }
    // Review M1: a late proposal still in the outbox and never tried, or
    // refused there for good, never reaches the server, so it is cancelled
    // and leaves `late`. One that left the outbox may still come back, so it
    // stays, and while `late` is full no new proposal is made: a proposal
    // dropped from it would be applied by every other device but this one.
    final queued = <String, PendingEnvelopeRecord>{
      for (final record in await localStore.pendingEnvelopeRecords())
        if (record.envelope.conversationId == conversationId)
          record.envelope.idempotencyKey: record,
    };
    final cancelled = <String>[
      for (final entry in book.late)
        if (queued[entry.actionId] case final record?
            when record.terminal || record.attemptCount == 0)
          entry.actionId,
    ];
    for (final actionId in cancelled) {
      book = book.withoutLate(actionId);
    }
    if (book.late.length >= c7LateProposalLimit) {
      throw StateError('too many history changes are waiting for the server');
    }
    final head = book.headRecord;
    if (create != (head == null && book.chain.highestSeq < 0)) {
      throw StateError(create
          ? 'this channel already has a history record'
          : 'a switch needs the record before it');
    }
    // A closed channel recovers with a switch above every seq seen,
    // chained from its own head (decision 4, row 3 or 5).
    final seq = create
        ? 0
        : (book.status == C7Status.closed
            ? book.chain.highestSeq + 1
            : head!.seq + 1);
    final key = Uint8List.fromList(_randomBytes(32));
    final device = _requiredDevice();
    C7Record? signed;
    final sent = await _c7SendHidden(
      conversationId,
      channelId: channelId,
      layoutGeneration: layoutGeneration,
      // A record that opens a key seals its own message under it, like a
      // post of the generation it opens (decision 3). Epoch 0 is `gen` 0.
      seal: full && device.groupEpoch(conversationId).epoch > 0
          ? (chk: key, generation: device.groupEpoch(conversationId).epoch)
          : null,
      build: (actionId, epoch) {
        final unsigned = C7Record(
          communityId: utf8.encode(community),
          channelId: utf8.encode(channelId),
          seq: seq,
          prev: head?.hash() ?? Uint8List(32),
          mode: full ? c7ModeFull : c7ModeMembersFromJoin,
          reason: create ? c7ReasonCreate : c7ReasonSwitch,
          groupId: utf8.encode(conversationId),
          epoch: epoch,
          closeGroupId: utf8.encode(conversationId),
          closeEpoch: epoch,
          chkCommit: full ? c7ChkCommitOf(key) : Uint8List(32),
          actorDeviceId: utf8.encode(_deviceId!),
          sig: Uint8List(64),
        );
        final sig = device.c7Sign(
            domain: c7HistorySignatureDomain, message: unsigned.signedFields());
        signed = C7Record(
          communityId: unsigned.communityId,
          channelId: unsigned.channelId,
          seq: seq,
          prev: unsigned.prev,
          mode: unsigned.mode,
          reason: unsigned.reason,
          groupId: unsigned.groupId,
          epoch: epoch,
          closeGroupId: unsigned.closeGroupId,
          closeEpoch: epoch,
          chkCommit: unsigned.chkCommit,
          actorDeviceId: unsigned.actorDeviceId,
          sig: sig,
        );
        final compact = C7CompactRecord(
          seq: seq,
          prev: unsigned.prev,
          mode: unsigned.mode,
          reason: unsigned.reason,
          closeEpoch: epoch,
          key: key,
          sig: sig,
        );
        return (
          vap1: AppPayloadCodec().encode(
            type: AppPayloadType.historyChange,
            conversationId: conversationId,
            senderDeviceId: _deviceId!,
            actionId: actionId,
            body: <String, Object?>{'r': base64Encode(compact.encode())},
            hidden: true,
            channelId: sharedGroup ? channelId : null,
          ),
          trailer: Uint8List(0),
        );
      },
      settingsFor: (actionId, _) =>
          _c7Put(conversationId, group.withReleased(cancelled), <C7ChannelBook>[
        book.copyWith(
          pending: C7Pending(
            actionId: actionId,
            sentAtMs: _c7NowMs(),
            record: signed!.encode(),
            key: key,
          ),
          clearNotice: true,
        ),
      ]),
    );
    // Only once the book no longer lists them: an envelope sent in between
    // comes back as an own record this device no longer knows, and that
    // fails closed ([_c7OwnEcho]).
    for (final actionId in cancelled) {
      await localStore.removePendingEnvelope(actionId);
    }
    return sent;
  }

  /// Sends the `history_sync` for the commit that produced [forEpoch] from
  /// the snapshot fixed at that merge, and settles the duty with it. Null
  /// when it is no longer owed.
  Future<MessageEnvelope?> _c7SendSync(
      String conversationId, int forEpoch) async {
    if (!_c7Active(conversationId)) return null;
    final group = await _c7LoadGroup(conversationId);
    final snapshot = group.snapshots[forEpoch];
    final duty = group.duties[forEpoch];
    final community = _c7CommunityOf(conversationId);
    if (snapshot == null || duty == null || duty.settled || community == null) {
      return null;
    }
    final settled = group.withDuty(
        forEpoch, C7SyncDuty(dueAtMs: duty.dueAtMs, settled: true));
    final extra = _c7KnownChannels(conversationId, group)
        .where((channel) => !snapshot.containsKey(channel))
        .toList();
    if (snapshot.isEmpty && extra.isEmpty) {
      // Nothing to name: the duty is settled with nothing sent.
      final previous = await _requiredState();
      await localStore.commitLocalMlsState(
        expectedCounter: previous.counter,
        expectedCursor: await localStore.loadSyncCursor(),
        state: _sealNext(previous),
        c7Settings: _c7Put(conversationId, settled, const <C7ChannelBook>[]),
      );
      return null;
    }
    return _c7SendHidden(
      conversationId,
      channelId: null,
      layoutGeneration: null,
      build: (actionId, _) {
        final parts = c7BuildHistorySync(
          bindings: bindings,
          communityId: community,
          conversationId: conversationId,
          senderDeviceId: _deviceId!,
          actionId: actionId,
          forEpoch: forEpoch,
          snapshot: snapshot,
          extraChannels: extra,
        );
        return (vap1: parts.body0, trailer: parts.slots);
      },
      settingsFor: (_, __) =>
          _c7Put(conversationId, settled, const <C7ChannelBook>[]),
      target: <String, Object?>{c7SyncForEpochKey: forEpoch},
    );
  }

  /// The server reports a `history_sync` for [forEpoch] already delivered
  /// (to the devices that commit added, which this device is not): the duty
  /// is settled with nothing sent.
  Future<void> _c7SyncDelivered(String conversationId, int forEpoch) async {
    if (!_c7Active(conversationId)) return;
    final group = await _c7LoadGroup(conversationId);
    final duty = group.duties[forEpoch];
    if (duty == null || duty.settled) return;
    final previous = await _requiredState();
    await localStore.commitLocalMlsState(
      expectedCounter: previous.counter,
      expectedCursor: await localStore.loadSyncCursor(),
      state: _sealNext(previous),
      c7Settings: _c7Put(
          conversationId,
          group.withDuty(
              forEpoch, C7SyncDuty(dueAtMs: duty.dueAtMs, settled: true)),
          const <C7ChannelBook>[]),
    );
  }

  /// A newcomer's request for the `history_sync` of its join, repeated with
  /// backoff until a usable one arrives.
  Future<MessageEnvelope?> _c7SendRequest(String conversationId) async {
    if (!_c7Active(conversationId)) return null;
    final group = await _c7LoadGroup(conversationId);
    final joinEpoch = group.joinEpoch;
    if (group.joinSynced || joinEpoch == null) return null;
    return _c7SendHidden(
      conversationId,
      channelId: null,
      layoutGeneration: null,
      build: (actionId, _) => (
        vap1: AppPayloadCodec().encode(
          type: AppPayloadType.historySyncRequest,
          conversationId: conversationId,
          senderDeviceId: _deviceId!,
          actionId: actionId,
          body: <String, Object?>{'for_epoch': joinEpoch},
          hidden: true,
        ),
        trailer: Uint8List(0),
      ),
      // Asked again, with backoff, until a usable history_sync arrives.
      settingsFor: (_, __) => _c7Put(
          conversationId,
          group.copyWith(
            requestsSent: group.requestsSent + 1,
            requestDueAtMs: _c7NowMs() +
                c7RequestDelayAfter(group.requestsSent + 1).inMilliseconds,
          ),
          const <C7ChannelBook>[]),
      target: <String, Object?>{c7SyncRequestForEpochKey: joinEpoch},
    );
  }

  // ---- newcomer import (decision 10) ----------------------------------------

  /// The import of what the app fetched (see [c7ImportHistory]). Per
  /// channel: the backward walk over the group-level page first, then every
  /// body that opens under the generation whose window holds its route
  /// epoch (`E_g <= epoch < E_close`, decision 6) and whose signature checks
  /// with that generation's `E_g`, this group and the route epoch (decision
  /// 8: a sender in the current tree by its tree key, any other device by
  /// the server's former-member key, and then marked). Only posts and the
  /// actions that target them are taken, through the live path's classify;
  /// a record, a `history_sync` or any other payload in a channel stream is
  /// never applied. Not franked: the history route serves no
  /// `frank_commit`, so an imported post cannot be reported.
  Future<int> _c7Import(
    String conversationId, {
    required C7HistoryPage groupLevel,
    required Map<String, C7HistoryPage> channels,
    required List<C7FormerKey> formerKeys,
    required bool first,
  }) async {
    if (!_c7Active(conversationId)) return 0;
    final community = _c7CommunityOf(conversationId);
    if (community == null) return 0;
    final group = await _c7LoadGroup(conversationId);
    if (group.joinEpoch == null ||
        (first ? group.imported || !group.joinSynced : !group.imported)) {
      return 0;
    }
    final state = C7ImportState.decode(
        await localStore.loadSetting(c7ImportSetting(conversationId)));
    final keptKeys = first ? formerKeys : state.keys;
    final former = <String, C7FormerKey>{
      for (final key in keptKeys) key.deviceId: key,
    };
    final privateChannel = _c7PrivateChannel(conversationId);
    final shared =
        _authority?.conversationKind(conversationId) == 'community_shared';
    final authority = _authority;
    final VerifiedRoleSource? roles = authority is VerifiedRoleSource
        ? authority as VerifiedRoleSource
        : null;
    final keys = C7Keys(bindings);
    final changedBooks = <C7ChannelBook>[];
    final cursors = <String, String?>{...state.cursors};
    // Pass one: every opened, verified post and action, oldest first.
    final posts = <({String key, String account, InsertMessageEffect row})>[];
    final actions = <List<MessageEffect>>[];
    for (final MapEntry(key: channel, value: page) in channels.entries) {
      // A shared group's channels, or a private group's own channel.
      if (shared ? channel == privateChannel : channel != privateChannel) {
        continue;
      }
      final stored = await _c7LoadBook(conversationId, channel);
      final book = c7WalkBack(
        bindings: bindings,
        book: stored,
        syncs: groupLevel.rows,
        communityId: community,
        conversationId: conversationId,
      );
      if (!identical(book, stored)) changedBooks.add(book);
      cursors[channel] =
          page.complete || page.rows.isEmpty ? null : page.rows.last.messageId;
      for (final row in page.rows.reversed) {
        if (row.channelId != channel) continue;
        final epoch = row.epoch;
        if (epoch == null) continue;
        // The window: E_g <= epoch < E_close.
        final gen = book.genAt(conversationId, epoch);
        final chk = gen?.key;
        if (gen == null || chk == null || gen.epoch == 0) continue;
        final aad = C7Keys.bodyAad(
          conversationId: conversationId,
          channelId: channel,
          senderDeviceId: row.senderDeviceId,
          actionId: row.actionId,
        );
        final bodyKey = keys.postBodyKey(
          chk: chk,
          communityId: community,
          channelId: channel,
          senderDeviceId: row.senderDeviceId,
          actionId: row.actionId,
        );
        ({Uint8List signature, Uint8List paddedVap1})? opened;
        try {
          opened = keys.openBody(bodyKey: bodyKey, aad: aad, sealed: row.body);
        } on Object {
          opened = null;
        } finally {
          bodyKey.fillRange(0, bodyKey.length, 0);
        }
        if (opened == null) continue;
        // Decision 8: a key in the current tree wins over anything the
        // server lists for the same device.
        final tree = _c7TreeKey(conversationId, row.senderDeviceId);
        final listed = tree == null ? former[row.senderDeviceId] : null;
        final signer = tree?.key ?? listed?.signingKey;
        final account = tree?.accountId ?? listed?.accountId;
        if (signer == null || account == null) continue;
        bool valid;
        try {
          valid = bindings.c7Verify(
            domain: c7PostSignatureDomain,
            publicKey: signer,
            message: c7PostSignedFields(
              communityId: community,
              channelId: channel,
              actionId: row.actionId,
              groupId: conversationId,
              epoch: epoch,
              senderDeviceId: row.senderDeviceId,
              generation: gen.epoch,
              paddedVap1: opened.paddedVap1,
            ),
            signature: opened.signature,
          );
        } on Object {
          valid = false;
        }
        if (!valid) continue;
        final outcome = AppPayloadCodec().classify(
          opened.paddedVap1,
          conversationId: conversationId,
          senderDeviceId: row.senderDeviceId,
          actionId: row.actionId,
          communityShared: shared,
          channelId: channel,
        );
        if (outcome is! DecodedAppPayload) continue;
        final payload = outcome.payload;
        final isPost = c7HistoryPostTypes.contains(payload.type);
        if (!isPost && !c7TargetedTypes.contains(payload.type)) continue;
        // C2, as live: a restricted post from a sender below admin.
        if (roles != null &&
            restrictedPostTypes.contains(payload.type) &&
            shouldDropRestrictedPost(
              record: roles.governanceOf(conversationId),
              sender: account,
              channelId: payload.channelId,
              serverRestricts: roles.serverRestrictsPosting(
                  conversationId, payload.channelId),
              senderRemoved: listed != null,
            )) {
          continue;
        }
        final List<MessageEffect> effects;
        try {
          effects = messageEffectsFor(
            payload,
            conversationId: conversationId,
            senderAccountId: account,
            senderDeviceId: row.senderDeviceId,
            serverMessageId: row.messageId,
            createdAt: row.createdAt.millisecondsSinceEpoch,
            state: LocalMessageState.received,
            // The sender's signed expiry; the route serves none of its own.
            expiresAt: effectiveExpiryMillis(
                senderMs: payload.expiresAtMs, serverMs: null),
            authority: authority,
            // A device no longer in the group never acts with a role.
            senderActsWithRole: listed == null,
          );
        } on Object {
          continue;
        }
        final key = messageKey(row.senderDeviceId, row.actionId);
        if (isPost) {
          // The post's own row only: no profile key rides in from history.
          for (final effect in effects) {
            if (effect is! InsertMessageEffect || effect.key != key) continue;
            var insert = effect.withC7Gen(c7GenTag(chk));
            // A former member's post is marked on its row (schema 42), so
            // the mark travels with it into K1 backups and K2 bundles.
            if (listed != null) insert = insert.markedC7Former();
            if (payload.type == AppPayloadType.attachmentManifest) {
              // Owner answer Q2: never offered, so never stored.
              insert = insert.withBody(c7HiddenAttachmentBody);
            }
            posts.add((key: key, account: account, row: insert));
          }
        } else {
          actions.add(<MessageEffect>[
            for (final effect in effects)
              if (effect is! ProfileKeyEffect) effect,
          ]);
        }
      }
    }
    // Pass two: the authors' own deletes as a set first (a deleted post is
    // never inserted, nor is any action on it), then the posts oldest first,
    // then the other actions in order. A moderator's delete applies like
    // any other action, after its target.
    final authors = <String, String>{
      for (final post in posts) post.key: post.account,
    };
    final deleted = <String>{
      for (final action in actions)
        for (final effect in action)
          if (effect is DeleteMessageEffect &&
              authors[effect.targetKey] == effect.deleterAccountId)
            effect.targetKey,
    };
    String? targetOf(MessageEffect effect) => switch (effect) {
          EditMessageEffect(:final targetKey) => targetKey,
          DeleteMessageEffect(:final targetKey) => targetKey,
          ReactionEffect(:final targetKey) => targetKey,
          PinMessageEffect(:final targetKey) => targetKey,
          PollVoteEffect(:final targetKey) => targetKey,
          PollCloseEffect(:final targetKey) => targetKey,
          _ => null,
        };
    final ordered = <MessageEffect>[
      for (final post in posts)
        if (!deleted.contains(post.key)) post.row,
      for (final action in actions)
        for (final effect in action)
          if (!deleted.contains(targetOf(effect))) effect,
    ];
    final next = C7ImportState(cursors: cursors, keys: keptKeys);
    await localStore.importC7History(ordered, c7Settings: <String, String?>{
      if (changedBooks.isNotEmpty || first)
        ..._c7Put(conversationId,
            first ? group.copyWith(imported: true) : group, changedBooks),
      c7ImportSetting(conversationId): next.encode(),
    });
    return posts.where((post) => !deleted.contains(post.key)).length;
  }

  Future<List<C7Due>> _c7Due(Iterable<String> conversationIds) async {
    final now = _c7NowMs();
    final out = <C7Due>[];
    for (final conversationId in conversationIds) {
      if (!_c7Active(conversationId)) continue;
      final group = await _c7LoadGroup(conversationId);
      for (final entry in group.duties.entries) {
        if (!entry.value.settled && entry.value.dueAtMs <= now) {
          out.add(C7DueSync(conversationId, entry.key));
        }
      }
      final request = group.requestDueAtMs;
      if (request != null &&
          request <= now &&
          !group.joinSynced &&
          group.joinEpoch != null) {
        out.add(C7DueRequest(conversationId, group.joinEpoch!));
      }
      for (final channel in group.channels) {
        final book = await _c7LoadBook(conversationId, channel);
        final pending = book.pending;
        if (book.ownNotice == 'stale' && pending != null) {
          out.add(C7DueRepropose(conversationId, channel,
              full: pending.full.mode == c7ModeFull));
        }
      }
    }
    return out;
  }
}
