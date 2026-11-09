import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileMode, Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../core/device_lists.dart' show DeviceListPins;
import '../core/k1_backup.dart' show k1BackupPlaintextVersion;
import '../core/models.dart';
import '../core/roles/posting_verdict.dart';
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
import 'community_info_payload.dart' show infoKeyBytes;
import 'message_format.dart';
import 'poll.dart' show pollRowBody;
import 'crypto_service.dart';
import 'franking.dart';
import 'k2_transfer_crypto.dart';
import 'mls_commit_bundle.dart';
import 'native_crypto_bindings.dart';

class NativeCryptoService
    implements
        BackupSealCryptoService,
        BoundedMlsConversationCryptoService,
        ChannelRoutedCryptoService,
        ConversationAuthorityConsumer,
        DeviceListCryptoService,
        DeviceSigningKeyCryptoService,
        EnrollmentPromotionCryptoService,
        K2TransferCryptoService,
        MlsDeviceHealthCryptoService,
        ExpiringPayloadCryptoService,
        MlsSelfUpdateCryptoService,
        MlsStateMaintenanceCryptoService,
        NoticeCaptureConsumer,
        ProfileCodecSource,
        RecoveryCryptoService,
        ReportCryptoService {
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
        final device = bindings.createDevice(
          reservation.accountId,
          reservation.deviceId,
        );
        _device = device;
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
      return await pins
          .judge(leaf.accountId, leaf.deviceId, leaf.signingKey,
              refreshFirst: network)
          .timeout(deviceListJudgeTimeout);
    } on Object {
      return LeafVerdict.checking;
    }
  }

  /// Judges every leaf of [conversationId]'s group (D94). A leaf already
  /// approved with the same key keeps its row unless [rejudgeApproved]; a
  /// leaf whose row is not approved is judged again.
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
    bool rejudgeApproved = false,
  }) async {
    final leaves = _requiredDevice().groupMembers(conversationId);
    final previous = await localStore.loadApprovalLeaves(conversationId);
    final participants = _participantsOf(conversationId);
    final now = _clock().toUtc().millisecondsSinceEpoch;
    final budget = Stopwatch()..start();
    final rows = <ApprovalLeaf>[];
    for (final leaf in leaves) {
      final known = previous
          .where((row) =>
              row.sameLeaf(leaf.accountId, leaf.deviceId) &&
              _sameBytes(row.signingKey, leaf.signingKey))
          .firstOrNull;
      final wasHeld = previous.any((row) =>
          row.sameLeaf(leaf.accountId, leaf.deviceId) &&
          row.verdict != LeafVerdict.approved);
      LeafVerdict verdict;
      if (known != null &&
          known.verdict == LeafVerdict.approved &&
          !rejudgeApproved) {
        verdict = LeafVerdict.approved;
      } else {
        verdict = await _judgeLeaf(leaf,
            network: budget.elapsed < deviceListGroupBudget);
      }
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
      rows.add(ApprovalLeaf(
        conversationId: conversationId,
        accountId: leaf.accountId,
        deviceId: leaf.deviceId,
        signingKey: leaf.signingKey,
        verdict: verdict,
        updatedAt: now,
      ));
    }
    return ApprovalLeafChange(
        conversationId: conversationId, leaves: rows, replaceAll: true);
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
  /// before L1, or whose rows a crash lost) is judged now; leaves that are
  /// not approved are judged again, so a list that now approves them, or a
  /// commit that removed them, releases the hold from local evidence only.
  @override
  Future<bool> refreshApprovalHold(String conversationId) =>
      _serial(() => _refreshApprovalHold(conversationId));

  Future<bool> _refreshApprovalHold(String conversationId) async {
    if (!await _hasGroup(conversationId)) return false;
    final rows = await localStore.loadApprovalLeaves(conversationId);
    if (rows.isNotEmpty &&
        rows.every((row) => row.verdict == LeafVerdict.approved)) {
      return false;
    }
    final change = await _judgeGroup(conversationId);
    await localStore.saveApprovalLeaves(change);
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
  /// with no rows yet is judged first. A sender with no row (rows that an
  /// own commit's re-judge did not write) or with a row that is not
  /// approved is judged once more before its text is dropped: the list may
  /// be reachable now, or name a device added after the last refresh.
  Future<LeafVerdict> _senderVerdict(
      String conversationId, String accountId, String deviceId) async {
    var rows = await localStore.loadApprovalLeaves(conversationId);
    if (rows.isEmpty) {
      final change = await _judgeGroup(conversationId);
      await localStore.saveApprovalLeaves(change);
      rows = change.leaves;
    }
    final row = rows
        .where((row) => row.sameLeaf(idBytes(accountId), idBytes(deviceId)))
        .firstOrNull;
    if (row == null ||
        row.verdict == LeafVerdict.checking ||
        row.verdict == LeafVerdict.unapproved) {
      final change = await _judgeGroup(conversationId);
      await localStore.saveApprovalLeaves(change);
      return change.leaves
              .where((leaf) =>
                  leaf.sameLeaf(idBytes(accountId), idBytes(deviceId)))
              .firstOrNull
              ?.verdict ??
          LeafVerdict.unapproved;
    }
    return row.verdict;
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
      await localStore.saveApprovalLeaves(await _judgeGroup(conversationId));
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
        _device = restored.device;
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
        _device = null;
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
          _device = null;
          final restored = await _openStored(accountId, deviceId, stored);
          _device = restored.device;
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
          _device = null;
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
              device.createGroup(conversationId);
              // One staged commit adds everyone (card I51). With nobody else to
              // add, the bundle only records this device as the group's first
              // member, so later devices can be added by reconcile. A device
              // the approved-device lists do not approve now is left out and
              // added by reconcile once they do (L1, D94).
              final bundle = approved.isEmpty
                  ? const MlsCommitBundle(epoch: 0)
                  : _stage(device, conversationId, adds: approved);
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
            final previous = await _requiredState();
            try {
              final bundle = _stage(_requiredDevice(), conversationId,
                  adds: approved, removes: removes);
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
  }) {
    final staged = device.stageCommitKeyed(
      conversationId,
      adds: [
        for (final add in adds)
          (
            keyPackage: add.package.keyPackage,
            accountId: idBytes(add.package.accountId),
            deviceId: idBytes(add.package.deviceId),
            signingKey: add.signingKey,
          ),
      ],
      removes: [
        for (final remove in removes)
          (
            accountId: idBytes(remove.accountId),
            deviceId: idBytes(remove.deviceId),
          ),
      ],
    );
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
          switch (message.kind) {
            case 'welcome':
              if (message.recipientDeviceId != _deviceId) {
                throw StateError('MLS Welcome recipient mismatch');
              }
              try {
                device.joinGroup(message.conversationId, message.payload);
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
              device.processCommit(message.conversationId, message.payload);
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
        await _requireNotPaused(revocation.conversationId);
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
        if (!_messageTypes.contains(type)) {
          throw ArgumentError.value(type, 'type', 'not a message payload');
        }
        await _requireNotPaused(conversationId);
        await _requireApproved(conversationId);
        final previous = await _requiredState();
        final cursor = await localStore.loadSyncCursor();
        if (!await localStore.hasOutboxCapacity()) {
          throw const OutboxFullException();
        }
        final sharedGroup =
            _authority?.conversationKind(conversationId) == 'community_shared';
        if (sharedGroup != (routeChannelId != null) ||
            (routeChannelId != null && routeGeneration == null)) {
          throw StateError('a channel is named exactly for a shared group');
        }
        final channelId = sharedGroup ? routeChannelId : null;
        try {
          final idempotencyKey = _randomIdempotencyKey();
          final deviceId = _deviceId!;
          // C6: every message carries a franking key inside its encrypted
          // payload and the commitment to it beside the ciphertext. The
          // commitment covers the canonical payload without the key, bound to
          // this conversation, this device and this action.
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
          final payload = framed.padded;
          final commit = bindings.frankCommit(
            key: frankKey,
            conversationId: conversationId,
            senderDeviceId: deviceId,
            actionId: idempotencyKey,
            payload: framed.canonical,
          );
          frankKey.fillRange(0, frankKey.length, 0);
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
              if (channelId != null) ...<String, Object?>{
                'channel_id': channelId,
                'community_layout_generation': routeGeneration,
              },
              // The epoch is already readable in the MLS message header. The
              // server uses it to withhold a message from a device that
              // joined after that epoch and cannot decrypt it (card I51).
              'mls_epoch': epoch,
            },
            frankCommit: commit,
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
                    channelId: channelId),
                conversationId: conversationId,
                senderAccountId: _accountId!,
                senderDeviceId: deviceId,
                createdAt: DateTime.now().toUtc().millisecondsSinceEpoch,
                state: LocalMessageState.pending,
                // The sender's own word: the first echo can only shorten it.
                expiresAt: expiresAt?.toUtc().millisecondsSinceEpoch,
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
      if (syncEventId <= cursor &&
          !await _mayReplay(envelope.conversationId, syncEventId)) {
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
          if (verdict != LeafVerdict.approved &&
              verdict != LeafVerdict.removed) {
            plaintext.fillRange(0, plaintext.length, 0);
            await localStore.commitMlsTransition(MlsStateTransition(
              checkCanCommit: operationFence,
              messageId: marker,
              conversationId: envelope.conversationId,
              expectedCounter: previous.counter,
              expectedCursor: cursor,
              state: _sealNext(previous),
              cursor: syncEventId,
              messageEffects: <MessageEffect>[
                _placeholderRow(
                    envelope,
                    '$unapprovedSenderKeyPrefix$syncEventId:${envelope.id}',
                    LocalMessageKind.invalid),
              ],
            ));
            return null;
          }
        } on NativeCryptoException catch (error) {
          if (!error.kind.ratchetAdvanced) rethrow;
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
        FrankReveal? reveal;
        var info = const <CommunityInfoEvent>[];
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
          final outcome = checked.outcome;
          reveal = checked.reveal;
          switch (outcome) {
            case DecodedAppPayload(:final payload):
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
                info = kind != 'community_shared' && kind != 'community_channel'
                    ? const <CommunityInfoEvent>[]
                    : <CommunityInfoEvent>[
                        communityInfoEventFor(
                          payload,
                          conversationId: envelope.conversationId,
                          senderAccountId: envelope.senderAccountId,
                          senderDeviceId: envelope.senderDeviceId,
                        ),
                      ];
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
              effects = messageEffectsFor(
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
          reveal = null;
          info = const <CommunityInfoEvent>[];
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
          // A reveal for a row this transition does not leave live (an edit,
          // an invalid placeholder) is dropped by the store, not an error.
          frankReveals: reveal == null ? const <FrankReveal>[] : [reveal],
          communityInfo: info,
        ));
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
        _device = null;
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
  };
}

/// The stored form of a received C3 payload ([infoPayloadTypes]), tied to
/// the MLS-authenticated sender and the conversation it arrived in. The body
/// was validated by [AppPayloadCodec].
CommunityInfoEvent communityInfoEventFor(
  DecryptedAppPayload payload, {
  required String conversationId,
  required String senderAccountId,
  required String senderDeviceId,
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
