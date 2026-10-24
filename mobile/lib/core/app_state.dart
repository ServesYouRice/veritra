import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DriftWrappedException;
import 'package:drift/native.dart' show SqliteException;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/app_payload.dart';
import '../crypto/attachment_crypto.dart';
import '../crypto/backup_service.dart';
import '../crypto/mls_commit_bundle.dart';
import '../crypto/crypto_service.dart';
import '../push/push_service.dart';
import '../storage/local_store.dart';
import '../sync/sync_recovery.dart';
import '../sync/sync_service.dart';
import 'api_client.dart';
import 'attachments.dart';
import 'client_config.dart';
import 'composer_drafts.dart';
import 'errors.dart';
import '../storage/message_search.dart';
import 'message_history.dart';
import '../storage/encrypted_database.dart' show LocalMessageKind;
import 'models.dart';
import 'receipts_state.dart';
import 'typing_state.dart';
import '../l10n/l10n.dart';

typedef ApiClientFactory = ApiClient Function(String baseUrl);
typedef SyncServiceFactory = SyncService Function(String baseUrl, String token);

/// Whether the app can currently reach the server. Derived from sync
/// outcomes — a completed catch-up or a delivered realtime event — rather
/// than from optimistic socket state, so "Online" never claims more than the
/// app has actually observed.
enum ConnectionStatus { connecting, online, offline }

enum SessionLifecycle { initializing, ready, recoveryRequired }

enum PeerVerificationStatus { unverified, verified, changed }

enum SetupProbeState {
  idle,
  probing,
  reachable,
  invalidOrigin,
  insecureTransport,
  dnsFailure,
  tlsFailure,
  timedOut,
  notVeritra,
  unavailable,
}

class SetupProbeResult {
  const SetupProbeResult({
    required this.state,
    this.setupRequired,
    this.instanceName,
  });

  const SetupProbeResult.idle() : this(state: SetupProbeState.idle);

  const SetupProbeResult.probing() : this(state: SetupProbeState.probing);

  final SetupProbeState state;
  final bool? setupRequired;
  final String? instanceName;

  bool get isReachable => state == SetupProbeState.reachable;

  /// The probe outcome in English; see [localizedMessage].
  String get message => localizedMessage(englishL10n);

  /// The probe outcome as a sentence for the connect screen.
  String localizedMessage(AppLocalizations l10n) {
    switch (state) {
      case SetupProbeState.idle:
        return '';
      case SetupProbeState.probing:
        return l10n.probeChecking;
      case SetupProbeState.reachable:
        final name = instanceName?.trim();
        return name == null || name.isEmpty
            ? l10n.probeReached
            : l10n.probeConnectedTo(name);
      case SetupProbeState.invalidOrigin:
        return l10n.probeInvalidOrigin;
      case SetupProbeState.insecureTransport:
        return l10n.probeInsecure;
      case SetupProbeState.dnsFailure:
        return l10n.probeDnsFailure;
      case SetupProbeState.tlsFailure:
        return l10n.probeTlsFailure;
      case SetupProbeState.timedOut:
        return l10n.probeTimedOut;
      case SetupProbeState.notVeritra:
        return l10n.probeNotVeritra;
      case SetupProbeState.unavailable:
        return l10n.probeUnavailable;
    }
  }
}

class IncomingCallSignal {
  const IncomingCallSignal(this.call, this.signal);
  final CallSession call;
  final Map<String, Object?> signal;
}

/// Operation keys for scoped busy/error state. A failure or in-flight request
/// for one operation must not disable unrelated controls.
/// Where push stands for this device (card I41).
enum PushState {
  /// Not started yet, or signed out.
  unknown,

  /// The server offers no push provider.
  serverDisabled,

  /// Waiting for the platform to hand over a token or endpoint.
  registering,

  /// No UnifiedPush distributor answered (Android without FCM).
  noDistributor,

  /// The platform or the server refused the registration.
  registrationFailed,

  /// The server accepted this device's registration.
  registered,
}

class Ops {
  static const send = 'send';
  static const attachment = 'attachment';
  static const pushTest = 'push_test';
  static const backup = 'backup';
  static const restore = 'restore';
  static const members = 'members';
  static const blocks = 'blocks';
  static const mute = 'mute';

  /// Refresh failures of the conversation and device lists. The lists keep
  /// their last good contents while this holds an error (card T44A).
  static const conversations = 'conversations';
  static const devices = 'devices';
  static String conversation(String id) => 'conversation:$id';
}

enum RequestBucket { chat, request, hidden }

class AppState extends ChangeNotifier {
  AppState({
    required this.apiClientFactory,
    required this.cryptoService,
    required this.localStore,
    required this.syncServiceFactory,
    MobilePushService? pushService,
    this.backupService,
    this.attachmentService,
    this.config = ClientConfig.production,
    ReceiptPreferences? receiptPreferences,
  })  : pushService = pushService ?? DisabledMobilePushService(),
        receiptPreferences = receiptPreferences ??
            ReceiptPreferences(MemoryReceiptPreferenceStore()) {
    composerDrafts.onChanged = _draftChanged;
    // Read the saved switch now so the settings screen shows it at once.
    unawaited(this.receiptPreferences.loaded);
  }

  /// The "send read receipts" switch (W5).
  final ReceiptPreferences receiptPreferences;

  /// Delivery and read cursors of the other members (W5).
  final ReceiptsState receipts = ReceiptsState();

  /// Who is typing (W5). Ephemeral, memory only.
  final TypingState typing = TypingState();

  /// Encrypted backup and restore (card I45). Null in builds without the
  /// MLS service, where there is nothing to back up.
  final BackupService? backupService;

  /// Encrypts and decrypts attachment files; only demo builds have it.
  final AttachmentCryptoService? attachmentService;

  final ApiClientFactory apiClientFactory;
  final ClientConfig config;
  final CryptoService cryptoService;
  final LocalStore localStore;
  final SyncServiceFactory syncServiceFactory;
  final MobilePushService pushService;

  /// Strings for the messages AppState stores for the UI (errors, recovery
  /// and probe text). `AppShell` sets it to the app's locale (T44C); English
  /// before the shell first builds and where no shell is built. Text already
  /// stored keeps its language. Push data never carries any of it.
  AppLocalizations l10n = englishL10n;

  Session? session;
  ApiClient? api;
  SyncService? sync;
  StreamSubscription<Map<String, Object?>>? _syncSubscription;
  StreamSubscription<PushEvent>? _pushSubscription;
  String? _pushSubscriptionId;
  String? _pushInstance;
  bool pushConfigured = false;
  List<Conversation> conversations = <Conversation>[];
  List<Device> devices = <Device>[];
  // Hydrated from the server list endpoints after auth; also updated
  // locally when records are created from this device.
  List<Community> communities = <Community>[];
  Map<String, List<Channel>> channelsByCommunity = <String, List<Channel>>{};
  List<Invite> invites = <Invite>[];
  Map<String, List<ReceivedMessageEnvelope>> messagesByConversation =
      <String, List<ReceivedMessageEnvelope>>{};
  List<MessageEnvelope> pendingOutbox = <MessageEnvelope>[];
  final Map<String, ConversationHistory> _history =
      <String, ConversationHistory>{};
  final Map<String, OutboxDeliveryState> _outboxStates =
      <String, OutboxDeliveryState>{};
  final Map<String, PendingEnvelopeRecord> _outboxRecords =
      <String, PendingEnvelopeRecord>{};
  String? selectedConversationId;

  /// Unsent composer text and reply targets, in memory only (T49C-4). Not
  /// part of what [notifyListeners] reports; cleared when the session ends.
  final ComposerDrafts composerDrafts = ComposerDrafts();
  DeviceLink? activeDeviceLink;
  DeviceLinkClaim? pendingDeviceLinkClaim;
  String? error;
  bool busy = false;
  // Distinguishes "still fetching the first page" from "genuinely empty" so
  // the UI doesn't show a misleading empty state during cold start. Each list
  // hydrated after auth carries its own flag so screens can show a spinner
  // until their first fetch resolves.
  bool conversationsLoaded = false;
  bool communitiesLoaded = false;
  bool invitesLoaded = false;
  bool devicesLoaded = false;
  final Set<String> _loadingMessageConversations = <String>{};
  final Map<String, String> _messageLoadErrors = <String, String>{};
  AccountSyncEngine? _syncOwner;
  LocalSyncLease? _syncLease;
  int _sessionGeneration = 0;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  int _pendingWakeGeneration = 0;

  // Backward pagination. A conversation is absent from _historyCursors until
  // its first page lands; a null value means the server reported no older
  // history, which is what lets the chat view say "beginning of conversation"
  // instead of showing an endless loader.
  final Map<String, String?> _historyCursors = <String, String?>{};
  final Set<String> _loadingOlder = <String>{};

  /// Server-recorded membership per conversation. Populated on demand by the
  /// details screen; never presented as the MLS roster.
  Map<String, List<ConversationMember>> membersByConversation =
      <String, List<ConversationMember>>{};
  List<BlockedAccount> blockedAccounts = <BlockedAccount>[];
  bool blocksLoaded = false;
  // Muted conversations with the end of each mute; null means no end. A mute
  // whose end has passed no longer counts (W6).
  final Map<String, DateTime?> _mutes = <String, DateTime?>{};
  Timer? _muteTimer;
  final Map<String, Timer> _draftTimers = <String, Timer>{};

  ConnectionStatus connectionStatus = ConnectionStatus.connecting;
  DateTime? lastSyncedAt;
  // Why the last background sync failed. Kept apart from [error] so a
  // connection problem is never reported as the result of a user action.
  String? syncError;
  bool deviceRecoveryRequired = false;

  /// Why sync stopped, when it did (I33). Kept durably by the local store.
  SyncRecovery? syncRecovery;
  SessionLifecycle lifecycle = SessionLifecycle.initializing;
  String? recoveryMessage;

  final Set<String> _busyOps = <String>{};
  final Map<String, String> _opErrors = <String, String>{};
  final StreamController<IncomingCallSignal> _callSignals =
      StreamController<IncomingCallSignal>.broadcast();
  bool _disposed = false;
  bool _flushingOutbox = false;
  bool _flushOutboxRequested = false;
  String? _manualRetryKey;
  Timer? _outboxRetryTimer;
  bool _flushingMlsOutbox = false;
  bool _flushMlsOutboxRequested = false;
  Timer? _mlsOutboxRetryTimer;
  Timer? _catchUpRetryTimer;
  Timer? _expiryTimer;
  bool _purgingExpired = false;
  int _catchUpRetryAttempt = 0;
  final Set<String> _failedMlsConversations = <String>{};
  final Map<String, DateTime> _mlsPendingSeen = <String, DateTime>{};
  final Set<String> _mlsReconcileNow = <String>{};
  bool _mlsReconcileRequested = true;
  Future<void> _sessionTransitionTail = Future<void>.value();
  Stream<IncomingCallSignal> get callSignals => _callSignals.stream;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool get connected => session != null;

  bool get _isForeground => _isForegroundState(_lifecycleState);

  bool _isForegroundState(AppLifecycleState state) =>
      state == AppLifecycleState.resumed ||
      (config.syncWhileUnfocused &&
          (state == AppLifecycleState.inactive ||
              state == AppLifecycleState.hidden));

  /// The UI forwards lifecycle changes here so background push remains a
  /// durable wake marker and the foreground sync owner is the only consumer.
  void handleAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _isForeground;
    _lifecycleState = state;
    if (state != AppLifecycleState.resumed) flushDrafts();
    if (state == AppLifecycleState.resumed ||
        (!wasForeground && _isForeground)) {
      unawaited(_resumeForegroundSync());
    }
  }

  MlsConversationCryptoService? get _mlsCrypto =>
      cryptoService is MlsConversationCryptoService
          ? cryptoService as MlsConversationCryptoService
          : null;

  /// True once a push endpoint has actually been registered with the server.
  /// [pushConfigured] only means the server offers push; without this, the
  /// settings screen would claim notifications work when no distributor ever
  /// answered.
  bool get pushRegistered => _pushSubscriptionId != null;

  /// Adding members and linking devices work in every build since card I51:
  /// group devices add new member devices to the MLS group themselves.
  bool get membershipChangesAvailable => true;

  /// Backups need the MLS service and a backup service (card I45).
  bool get backupAvailable => backupService != null && _mlsCrypto != null;

  /// When this device last made a backup, once loaded.
  DateTime? lastBackupAt;

  Future<void> refreshBackupStatus() async {
    if (!backupAvailable || session == null) return;
    lastBackupAt = await localStore.loadLastBackupAt();
    notifyListeners();
  }

  /// Makes an encrypted backup of this device, uploads it, and returns the
  /// recovery code, or null on failure (see [errorFor] with [Ops.backup]).
  /// The code is shown once and never stored; a new backup replaces the
  /// previous one and its code.
  Future<String?> createBackup() async {
    String? code;
    await _runScoped(Ops.backup, () async {
      final current = session;
      final client = api;
      final service = backupService;
      if (current == null || client == null || service == null) return;
      try {
        code = await service.createAndUpload(client, current.token);
      } on ApiException catch (error) {
        if (error.statusCode == 401) rethrow;
        throw BackupException(error.statusCode == 507
            ? BackupFailureKind.tooLarge
            : error.statusCode >= 500
                ? BackupFailureKind.network
                : BackupFailureKind.storage);
      } on SocketException {
        throw const BackupException(BackupFailureKind.network);
      } on TimeoutException {
        throw const BackupException(BackupFailureKind.network);
      }
      final now = DateTime.now().toUtc();
      await localStore.saveLastBackupAt(now);
      lastBackupAt = now;
    });
    return code;
  }

  /// Restores a backup onto this empty device and signs it in (card I45).
  /// Returns false with a typed error under [Ops.restore]; an interrupted
  /// download continues on the next attempt.
  Future<bool> restoreFromBackup(String recoveryCode) {
    return _runScoped(Ops.restore, () async {
      final service = backupService;
      if (service == null) {
        throw const BackupException(BackupFailureKind.storage);
      }
      if (session != null) {
        throw const BackupException(BackupFailureKind.deviceNotEmpty);
      }
      await service.recover(recoveryCode);
      await _tryRestoreSession();
    });
  }

  /// Reply, edit, delete and reactions need the MLS service (D22).
  bool get messageActionsAvailable => _mlsCrypto != null;

  /// Safety numbers come from the MLS group, so only builds with the MLS
  /// path (demo builds, D11) can show them.
  bool get safetyNumbersAvailable => _mlsCrypto != null;

  /// Attachments travel as MLS manifest messages, so they need the MLS
  /// path and the native attachment crypto (demo builds, D11).
  bool get attachmentsAvailable =>
      attachmentService != null && _mlsCrypto != null;

  /// Scoped busy/error state. Callers pass an [Ops] key so one slow or failed
  /// action leaves every unrelated control usable.
  bool isBusy(String op) => _busyOps.contains(op);
  String? errorFor(String op) => _opErrors[op];
  void clearError(String op) {
    if (_opErrors.remove(op) != null) {
      notifyListeners();
    }
  }

  /// True while an older page is being fetched for [conversationId].
  bool isLoadingOlder(String conversationId) =>
      _loadingOlder.contains(conversationId);

  /// True when the server has told us older history exists. False both when
  /// history is exhausted and before the first page has loaded.
  bool hasMoreHistory(String conversationId) =>
      _historyCursors[conversationId] != null;

  /// Heard with each batch of received messages once they are decrypted,
  /// stored and shown. The desktop shell uses it to raise notifications
  /// (W3); it gets copies and cannot change the list.
  void Function(List<ReceivedMessageEnvelope> received)? onMessagesPublished;

  bool isMuted(String conversationId) {
    if (!_mutes.containsKey(conversationId)) return false;
    final until = _mutes[conversationId];
    return until == null || until.isAfter(DateTime.now());
  }

  /// When the current mute of [conversationId] ends; null when it is not muted
  /// or the mute has no end.
  DateTime? mutedUntil(String conversationId) =>
      isMuted(conversationId) ? _mutes[conversationId] : null;

  bool isBlocked(String accountId) =>
      blockedAccounts.any((block) => block.accountId == accountId);

  // Message requests (B8). A DM or group that someone else started, whose
  // starter this account has not accepted, waits as a request: no read
  // receipt, no attachment download, no notification. Acceptance is local to
  // this device (syncing it across devices is later work); the accepted peers,
  // accepted groups and declined conversations live in the encrypted local
  // settings, never on the server.
  //
  // The server refuses to remove a member from a DM, so Delete and Block on a
  // DM cannot leave it. They record the conversation as declined instead; it
  // is hidden, and returns as a request only on newer activity from a peer
  // who is not blocked.
  static const String _requestSettingName = 'message_requests';
  Set<String>? _acceptedPeers;
  final Set<String> _acceptedGroups = <String>{};
  final Map<String, DateTime> _declined = <String, DateTime>{};

  /// Whether the request state has been read. Until then nothing from a
  /// stranger is treated as accepted, and the chat list shows no rows.
  bool get requestStateLoaded => _acceptedPeers != null;

  /// Where a conversation belongs: the chat list, the Requests section, or
  /// nowhere (declined, or from a blocked account).
  RequestBucket requestBucket(Conversation conversation) {
    final me = session?.accountId;
    final creator = conversation.createdBy;
    final isDm = conversation.isDm;
    if (me == null ||
        !(isDm || conversation.isGroup) ||
        creator == null ||
        creator == me) {
      return RequestBucket.chat;
    }
    final sender = isDm ? conversation.peerAccountId : creator;
    if (sender == null) return RequestBucket.chat;
    final accepted = _acceptedPeers;
    if (accepted != null &&
        (isDm
            ? accepted.contains(sender)
            : accepted.contains(creator) ||
                _acceptedGroups.contains(conversation.id))) {
      return RequestBucket.chat;
    }
    if (isBlocked(sender)) return RequestBucket.hidden;
    final declinedAt = _declined[conversation.id];
    if (declinedAt != null) {
      final activity = conversation.lastActivityAt;
      if (activity == null || !activity.isAfter(declinedAt)) {
        return RequestBucket.hidden;
      }
    }
    return RequestBucket.request;
  }

  bool isMessageRequest(Conversation conversation) =>
      requestBucket(conversation) == RequestBucket.request;

  bool isMessageRequestId(String conversationId) {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    return conversation != null && isMessageRequest(conversation);
  }

  bool _heldBack(String conversationId) {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    return conversation != null &&
        requestBucket(conversation) != RequestBucket.chat;
  }

  /// Whether the conversation's content may be shown, read or fetched.
  /// Unknown conversations are not.
  bool conversationOpen(String conversationId) {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    return conversation != null &&
        requestBucket(conversation) == RequestBucket.chat;
  }

  /// Loads (or, on first run, creates) the request state. Only an upgrade
  /// ([grandfather]: an earlier local snapshot exists) accepts the
  /// conversations already there, so an update never turns existing chats
  /// into requests. A fresh device (link, reinstall, restore) starts with
  /// only what this account created accepted.
  Future<void> _loadRequestState({required bool grandfather}) async {
    final me = session?.accountId;
    if (me == null || _acceptedPeers != null) return;
    final accepted = <String>{};
    final groups = <String>{};
    final declined = <String, DateTime>{};
    var known = false;
    try {
      final raw = await localStore.loadSetting(_requestSettingName);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['account'] == me) {
          known = true;
          final peers = decoded['accepted'];
          if (peers is List) accepted.addAll(peers.whereType<String>());
          final acceptedGroups = decoded['groups'];
          if (acceptedGroups is List) {
            groups.addAll(acceptedGroups.whereType<String>());
          }
          final gone = decoded['declined'];
          if (gone is Map) {
            for (final entry in gone.entries) {
              final at = DateTime.tryParse('${entry.value}');
              if (entry.key is String && at != null) {
                declined[entry.key as String] = at;
              }
            }
          }
        }
      }
    } catch (_) {
      // An unreadable value is treated as first run.
    }
    if (!known) {
      if (grandfather) {
        for (final conversation in conversations) {
          final peer = conversation.peerAccountId;
          if (conversation.isDm && peer != null) accepted.add(peer);
          if (conversation.isGroup) groups.add(conversation.id);
        }
      }
      await _saveRequestState(me, accepted, groups, declined);
    }
    _acceptedPeers = accepted;
    _acceptedGroups
      ..clear()
      ..addAll(groups);
    _declined
      ..clear()
      ..addAll(declined);
  }

  Future<void> _persistRequestState() async {
    final me = session?.accountId;
    final accepted = _acceptedPeers;
    if (me == null || accepted == null) return;
    await _saveRequestState(me, accepted, _acceptedGroups, _declined);
  }

  Future<void> _saveRequestState(
    String me,
    Set<String> accepted,
    Set<String> groups,
    Map<String, DateTime> declined,
  ) =>
      localStore.saveSetting(
        _requestSettingName,
        jsonEncode(<String, Object?>{
          'account': me,
          'accepted': accepted.toList()..sort(),
          'groups': groups.toList()..sort(),
          'declined': <String, String>{
            for (final entry in declined.entries)
              entry.key: entry.value.toUtc().toIso8601String(),
          },
        }),
      );

  String? _requestSender(Conversation conversation) =>
      conversation.isDm ? conversation.peerAccountId : conversation.createdBy;

  /// Accepts [conversation]'s sender (a DM's peer, or a group) and clears any
  /// earlier decline. Starting or replying in a conversation counts as
  /// accepting it.
  Future<bool> _acceptConversation(Conversation conversation) async {
    final accepted = _acceptedPeers;
    final sender = _requestSender(conversation);
    if (accepted == null || sender == null || isBlocked(sender)) return false;
    if (conversation.isGroup) {
      _acceptedGroups.add(conversation.id);
    } else {
      accepted.add(sender);
    }
    _declined.remove(conversation.id);
    await _persistRequestState();
    notifyListeners();
    return true;
  }

  /// Accepts a request. False when nothing was accepted (unknown
  /// conversation, state not loaded, or a blocked sender).
  Future<bool> acceptMessageRequest(String conversationId) async {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conversation == null) return false;
    final wasRequest = isMessageRequest(conversation);
    if (!await _acceptConversation(conversation)) return false;
    if (wasRequest && selectedConversationId == conversationId) {
      unawaited(loadMessages(conversationId));
    }
    return true;
  }

  Future<bool> _decline(Conversation conversation) async {
    _declined[conversation.id] = DateTime.now().toUtc();
    await _persistRequestState();
    if (selectedConversationId == conversation.id) {
      selectedConversationId = null;
    }
    notifyListeners();
    return true;
  }

  /// Drops the request: a DM cannot be left (the server refuses), so it is
  /// declined; a group is left for real.
  Future<bool> _dropRequest(Conversation conversation) => conversation.isGroup
      ? leaveConversation(conversation.id)
      : _decline(conversation);

  /// Blocks the sender, then drops the request.
  Future<bool> blockMessageRequest(String conversationId) async {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    final sender = conversation == null ? null : _requestSender(conversation);
    if (conversation == null || sender == null) return false;
    if (!await blockAccount(sender)) return false;
    return _dropRequest(conversation);
  }

  /// Drops the request without blocking.
  Future<bool> deleteMessageRequest(String conversationId) async {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conversation == null) return false;
    return _dropRequest(conversation);
  }

  List<ConversationMember> membersFor(String conversationId) =>
      membersByConversation[conversationId] ?? const <ConversationMember>[];
  bool isLoadingMessages(String conversationId) =>
      _loadingMessageConversations.contains(conversationId);
  String? messageLoadError(String conversationId) =>
      _messageLoadErrors[conversationId];
  Conversation? get selectedConversation =>
      conversations.where((c) => c.id == selectedConversationId).firstOrNull;
  List<ReceivedMessageEnvelope> get selectedMessages {
    final id = selectedConversationId;
    if (id == null) {
      return const <ReceivedMessageEnvelope>[];
    }
    return messagesByConversation[id] ?? const <ReceivedMessageEnvelope>[];
  }

  /// Decrypted text for the envelopes of [conversationId] (D23).
  ConversationHistory historyFor(String conversationId) =>
      _history[conversationId] ?? ConversationHistory.empty(conversationId);

  /// Rereads decrypted history for one conversation from the local store.
  Future<void> refreshHistory(String conversationId) async {
    _history[conversationId] = await _loadHistory(conversationId);
    notifyListeners();
  }

  Future<ConversationHistory> _loadHistory(String conversationId) async {
    final messages = await localStore.loadMessages(conversationId);
    final reactions = await localStore.loadReactions(conversationId);
    return ConversationHistory(
      conversationId: conversationId,
      messages: messages,
      reactions: reactions,
    );
  }

  /// What the chat shows, newest first (Stage 4). With MLS, decrypted local
  /// history is the source of truth, so every message this device has read
  /// or sent is shown even when the server is unreachable or the envelope
  /// left the local cache. Server envelopes without a local record (sent
  /// before this device joined, say) still appear, as redacted bars.
  List<ReceivedMessageEnvelope> timelineFor(String conversationId) {
    final envelopes = messagesFor(conversationId);
    if (_mlsCrypto == null) return envelopes;
    final history = historyFor(conversationId);
    final ownDeviceId = session?.deviceId;
    final pendingKeys = <String>{
      if (ownDeviceId != null)
        for (final envelope in pendingOutbox)
          if (envelope.conversationId == conversationId)
            ConversationHistory.keyOf(ownDeviceId, envelope.idempotencyKey),
    };
    final byKey = <String, ReceivedMessageEnvelope>{};
    for (final envelope in envelopes) {
      // A placeholder row is keyed by its sync event, so ask the history
      // which row an envelope belongs to before using its claimed key.
      byKey[history.forEnvelope(envelope)?.key ??
          ConversationHistory.keyOf(
              envelope.senderDeviceId, envelope.idempotencyKey)] = envelope;
    }
    for (final local in history.messages) {
      if (local.kind == LocalMessageKind.action ||
          pendingKeys.contains(local.key) ||
          byKey.containsKey(local.key)) {
        continue;
      }
      byKey[local.key] = ReceivedMessageEnvelope(
        id: local.serverMessageId ?? local.key,
        conversationId: conversationId,
        senderAccountId: local.senderAccountId,
        senderDeviceId: local.senderDeviceId,
        idempotencyKey: local.key.startsWith('${local.senderDeviceId}:')
            ? local.key.substring(local.senderDeviceId.length + 1)
            : local.key,
        ciphertext: const <int>[],
        cryptoProtocol: 'local-history',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(local.createdAt, isUtc: true),
      );
    }
    return byKey.values.toList()
      ..sort((left, right) {
        final byCreatedAt = right.createdAt.compareTo(left.createdAt);
        return byCreatedAt != 0 ? byCreatedAt : right.id.compareTo(left.id);
      });
  }

  List<ReceivedMessageEnvelope> messagesFor(String conversationId) =>
      messagesByConversation[conversationId] ??
      const <ReceivedMessageEnvelope>[];

  List<MessageEnvelope> pendingFor(String conversationId) => pendingOutbox
      .where((envelope) => envelope.conversationId == conversationId)
      .toList(growable: false);

  OutboxDeliveryState outboxState(String idempotencyKey) =>
      _outboxStates[idempotencyKey] ?? OutboxDeliveryState.failed;

  PendingEnvelopeRecord? outboxRecord(String idempotencyKey) =>
      _outboxRecords[idempotencyKey];

  void _setOutboxRecords(List<PendingEnvelopeRecord> records) {
    _outboxRecords
      ..clear()
      ..addEntries(records
          .map((record) => MapEntry(record.envelope.idempotencyKey, record)));
    pendingOutbox =
        records.map((record) => record.envelope).toList(growable: false);
  }

  String outboxFailureMessage(String idempotencyKey) {
    final failure = _outboxRecords[idempotencyKey]?.failureClass ?? '';
    if (failure.contains('storage_quota_exceeded') ||
        failure.contains(':507:')) {
      return l10n.apiErrorStorageFull;
    }
    return l10n.outboxSendFailed;
  }

  /// Probe the instance without changing global action state. The result is
  /// typed so onboarding can distinguish invalid input, TLS, DNS, timeout,
  /// wrong-server and generic availability failures.
  Future<SetupProbeResult> probeSetup(String baseUrl) async {
    final String origin;
    try {
      origin = canonicalizeServerOrigin(baseUrl);
    } on FormatException {
      return const SetupProbeResult(state: SetupProbeState.invalidOrigin);
    }
    if (!config.transport.allows(origin)) {
      return const SetupProbeResult(
        state: SetupProbeState.insecureTransport,
      );
    }

    ApiClient? client;
    try {
      client = apiClientFactory(origin);
      final status = await client.setupStatus();
      final required = status['setup_required'];
      if (required is! bool) {
        return const SetupProbeResult(state: SetupProbeState.notVeritra);
      }
      final name = status['instance_name'];
      return SetupProbeResult(
        state: SetupProbeState.reachable,
        setupRequired: required,
        instanceName: name is String ? name : null,
      );
    } on HandshakeException {
      return const SetupProbeResult(state: SetupProbeState.tlsFailure);
    } on TimeoutException {
      return const SetupProbeResult(state: SetupProbeState.timedOut);
    } on SocketException catch (err) {
      final message = err.message.toLowerCase();
      final dns = message.contains('failed host lookup') ||
          message.contains('nodename') ||
          message.contains('name or service not known') ||
          message.contains('unknown host');
      return SetupProbeResult(
        state: dns ? SetupProbeState.dnsFailure : SetupProbeState.unavailable,
      );
    } on ApiException catch (err) {
      return SetupProbeResult(
        state: err.statusCode >= 400 && err.statusCode < 500
            ? SetupProbeState.notVeritra
            : SetupProbeState.unavailable,
      );
    } on FormatException {
      return const SetupProbeResult(state: SetupProbeState.notVeritra);
    } on HttpException {
      return const SetupProbeResult(state: SetupProbeState.notVeritra);
    } catch (_) {
      return const SetupProbeResult(state: SetupProbeState.unavailable);
    } finally {
      client?.close();
    }
  }

  /// Compatibility helper for non-UI callers that only need setup state.
  /// New onboarding code should use [probeSetup] to preserve failure detail.
  Future<bool?> checkSetupRequired(String baseUrl) async {
    return (await probeSetup(baseUrl)).setupRequired;
  }

  Future<bool> hasStoredDeviceIdentity() async {
    try {
      final stored = await localStore.loadSession();
      return _hasDeviceIdentity(session) || _hasDeviceIdentity(stored);
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async {
    final String origin;
    try {
      origin = canonicalizeServerOrigin(baseUrl);
    } on FormatException {
      return false;
    }
    try {
      final stored = await localStore.loadSession();
      return _hasDeviceIdentity(session, origin) ||
          _hasDeviceIdentity(stored, origin);
    } catch (_) {
      return false;
    }
  }

  bool _hasDeviceIdentity(Session? candidate, [String? origin]) {
    if (candidate == null ||
        candidate.deviceId == null ||
        candidate.deviceId!.isEmpty ||
        candidate.deviceSecret == null ||
        candidate.deviceSecret!.isEmpty) {
      return false;
    }
    if (origin == null) {
      return true;
    }
    try {
      return canonicalizeServerOrigin(candidate.baseUrl) == origin;
    } on FormatException {
      return false;
    }
  }

  /// Best-effort hydration of a previously-stored session on cold start.
  /// Failures are swallowed: a stale or unreadable session simply lands the
  /// user on the connect screen rather than crashing the app.
  Future<void> tryRestoreSession() =>
      _enqueueSessionTransition(_tryRestoreSession);

  Future<void> _tryRestoreSession() async {
    if (_disposed) return;
    final transitionGeneration = ++_sessionGeneration;
    lifecycle = SessionLifecycle.initializing;
    recoveryMessage = null;
    localStoreFailure = null;
    notifyListeners();
    try {
      final stored = await localStore.loadSession();
      // The local database opened, so a run of failed upgrades is over.
      _storageFullFailures = 0;
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      // Expired messages go even from a device that is signed out: it keeps
      // its history for the next sign-in (W2).
      await localStore.purgeExpiredMessages();
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      if (stored == null) {
        lifecycle = SessionLifecycle.ready;
        notifyListeners();
        return;
      }
      final restored = Session(
        baseUrl: canonicalizeServerOrigin(stored.baseUrl),
        token: stored.token,
        accountId: stored.accountId,
        deviceId: stored.deviceId,
        username: stored.username,
        deviceSecret: stored.deviceSecret,
        role: stored.role,
      );
      if (restored.token.isEmpty) {
        lifecycle = SessionLifecycle.ready;
        notifyListeners();
        return;
      }
      session = restored;
      _replaceApi(restored.baseUrl);
      await _mlsCrypto?.activateSession(restored);
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      final records = await localStore.pendingEnvelopeRecords();
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      _setOutboxRecords(records);
      for (final envelope in pendingOutbox) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.failed;
      }
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      composerDrafts.load({
        for (final entry in (await localStore.loadDrafts()).entries)
          entry.key: (text: entry.value.text, replyTo: entry.value.replyTo),
      });
      _mutes
        ..clear()
        ..addAll(await localStore.loadConversationMutes());
      _armMuteTimer();
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      final cached = await localStore.loadSnapshot();
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      if (cached != null) {
        conversations = cached.conversations;
        await _loadRequestState(grandfather: true);
        messagesByConversation = cached.messagesByConversation;
        conversationsLoaded = true;
        notifyListeners();
      }
      try {
        await _refreshConversations(notify: true);
        await _refreshDevices();
        if (!_lifecycleGenerationActive(transitionGeneration)) return;
      } on ApiException catch (err) {
        if (err.statusCode == 401) {
          await _clearLocalSession(
              preserveDeviceIdentity: true, preserveOutbox: true);
          return;
        }
        // Keep the encrypted cache available while offline.
      } catch (_) {
        // Keep the encrypted cache available while offline.
      }
      _startSync();
      unawaited(_scheduleExpiryPurge());
      lifecycle = SessionLifecycle.ready;
      notifyListeners();
    } catch (error) {
      // Keep the encrypted database and cursor intact. Recovery is explicit so
      // a keystore/database failure cannot look like an ordinary logout.
      await _mlsCrypto?.dispose();
      api?.close();
      session = null;
      api = null;
      final previousSync = sync;
      sync = null;
      await previousSync?.dispose();
      devices = <Device>[];
      conversationsLoaded = false;
      messagesByConversation = <String, List<ReceivedMessageEnvelope>>{};
      _history.clear();
      composerDrafts.clear();
      lifecycle = SessionLifecycle.recoveryRequired;
      localStoreFailure =
          error is LocalStoreUnavailableException ? error.kind : null;
      _storageFullFailures =
          localStoreFailure == LocalStoreFailureKind.upgradeStorageFull
              ? _storageFullFailures + 1
              : 0;
      recoveryMessage = error is LocalStoreUnavailableException
          ? _localStoreFailureMessage(error.kind)
          : l10n.recoveryRestoreFailed;
      notifyListeners();
    }
  }

  /// Restores in a row whose upgrade failed for lack of space.
  int _storageFullFailures = 0;

  String _localStoreFailureMessage(LocalStoreFailureKind kind) {
    switch (kind) {
      case LocalStoreFailureKind.profileLocked:
        return l10n.recoveryProfileLocked;
      case LocalStoreFailureKind.keyUnavailable:
      case LocalStoreFailureKind.keyWriteFailed:
        return l10n.recoveryKeyUnavailable;
      case LocalStoreFailureKind.keyMissing:
      case LocalStoreFailureKind.keyMalformed:
      case LocalStoreFailureKind.keyRejected:
        return l10n.recoveryKeyMissing;
      case LocalStoreFailureKind.upgradeStorageFull:
        return _storageFullFailures > 1
            ? l10n.recoveryUpgradeStillFull
            : l10n.recoveryUpgradeFailed;
      case LocalStoreFailureKind.upgradeFailed:
        return l10n.recoveryUpgradeError;
    }
  }

  /// Why the encrypted local database could not be opened (I39), or null.
  LocalStoreFailureKind? localStoreFailure;

  /// Signing in cannot work while the local database is unreadable, so the
  /// recovery screen offers it only for other restore failures.
  bool get canContinueWithoutRestore => localStoreFailure == null;

  /// A reset moves the database and its key aside (it never deletes them),
  /// so it is always reachable and the user is never stuck. An upgrade that
  /// ran out of space leaves a readable database, though, and freeing space
  /// and retrying is the fix: the reset is offered for it only once a retry
  /// has failed the same way again.
  bool get canResetLocalData {
    final failure = localStoreFailure;
    if (failure == null) return false;
    if (failure == LocalStoreFailureKind.upgradeStorageFull) {
      return _storageFullFailures > 1;
    }
    return true;
  }

  void continueWithoutRestore() {
    if (lifecycle != SessionLifecycle.recoveryRequired ||
        !canContinueWithoutRestore) {
      return;
    }
    lifecycle = SessionLifecycle.ready;
    recoveryMessage = null;
    notifyListeners();
  }

  /// The confirmed destructive reset for an unreadable local database (I39).
  /// The old database and its key are moved aside, not deleted; this device
  /// then starts empty and must be linked again.
  Future<void> resetUnreadableLocalData({required bool confirmed}) async {
    if (!confirmed) {
      throw ArgumentError.value(confirmed, 'confirmed',
          'resetting local data needs explicit confirmation');
    }
    if (lifecycle != SessionLifecycle.recoveryRequired || !canResetLocalData) {
      return;
    }
    await _enqueueSessionTransition(() async {
      busy = true;
      notifyListeners();
      try {
        await localStore.quarantineUnreadableDatabase(confirmed: true);
        localStoreFailure = null;
        _storageFullFailures = 0;
        recoveryMessage = null;
        lifecycle = SessionLifecycle.ready;
      } catch (err) {
        recoveryMessage = l10n.recoveryResetFailed;
      } finally {
        busy = false;
        notifyListeners();
      }
    });
  }

  Future<void> createOwner(String baseUrl, String username, String password,
      String setupToken) async {
    await _run(() async {
      _replaceApi(baseUrl);
      final enrollment = await api!.reserveOwnerEnrollment(
        setupToken: setupToken,
      );
      final credential =
          await cryptoService.createEnrollmentCredential(enrollment);
      session = await api!.createOwner(
        username: username,
        password: password,
        deviceName: config.deviceName,
        enrollment: enrollment,
        credential: credential,
        setupToken: setupToken,
      );
      await localStore.saveSession(session!);
      await _mlsCrypto?.activateSession(session!);
      await _publishInitialMlsKeyPackages();
      await localStore.saveSyncCursor(0);
      await _refreshConversations(notify: true);
      await _refreshDevices();
      _startSync();
    });
  }

  Future<void> login(String baseUrl, String username, String password) async {
    await _run(() async {
      _replaceApi(baseUrl);
      final localSession = await localStore.loadSession();
      final deviceId =
          localSession?.baseUrl == api!.baseUrl ? localSession?.deviceId : null;
      final deviceSecret = localSession?.baseUrl == api!.baseUrl
          ? localSession?.deviceSecret
          : null;
      if (deviceId == null ||
          deviceId.isEmpty ||
          deviceSecret == null ||
          deviceSecret.isEmpty) {
        throw StateError(l10n.errorPasswordLoginNeedsLink);
      }
      session = await api!.login(
        username: username,
        password: password,
        deviceId: deviceId,
        deviceSecret: deviceSecret,
      );
      await localStore.saveSession(session!);
      await _mlsCrypto?.activateSession(session!);
      await localStore.saveSyncCursor(0);
      await _refreshConversations(notify: true);
      await _refreshDevices();
      _startSync();
    });
  }

  /// User-initiated refresh (pull-to-refresh, refresh buttons). It never
  /// throws: a failure keeps the last good list and records a safe message
  /// under [Ops.conversations]; calling it again is the retry.
  Future<void> refreshConversations() => _refreshContained(
      Ops.conversations, () => _refreshConversations(notify: true));

  /// Like [refreshConversations], for the device list ([Ops.devices]).
  Future<void> refreshDevices() =>
      _refreshContained(Ops.devices, _refreshDevices);

  Future<void> _refreshContained(
    String op,
    Future<void> Function() load,
  ) async {
    final current = session;
    try {
      await load();
      if (_opErrors.remove(op) != null) notifyListeners();
    } catch (err) {
      if (err is ApiException &&
          err.statusCode == 401 &&
          identical(session, current)) {
        await _enqueueSessionTransition(() async {
          if (!identical(session, current)) return;
          await _clearLocalSession(
              preserveDeviceIdentity: true, preserveOutbox: true);
        });
      }
      _opErrors[op] = describeError(err, l10n);
      notifyListeners();
    }
  }

  Future<void> _refreshDevices() async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    try {
      devices = await client.devices(current.token);
      _opErrors.remove(Ops.devices);
    } finally {
      devicesLoaded = true;
    }
    notifyListeners();
  }

  /// Refreshes the caller's invites from the server. Best-effort: members
  /// without invite permission get a 403, in which case whatever is held
  /// locally (usually nothing) is kept without surfacing an error.
  Future<void> refreshInvites() async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    try {
      invites = await client.listInvites(current.token);
    } catch (_) {
      // Ignored: invite listing is a privilege, not a core flow.
    } finally {
      invitesLoaded = true;
      notifyListeners();
    }
  }

  /// Refreshes communities (and their channels) the account belongs to.
  /// Best-effort for the same reason as [refreshInvites].
  Future<void> refreshCommunities() async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    try {
      final list = await client.listCommunities(current.token);
      final channels = <String, List<Channel>>{};
      for (final community in list) {
        try {
          channels[community.id] =
              await client.listChannels(current.token, community.id);
        } catch (_) {
          channels[community.id] =
              channelsByCommunity[community.id] ?? const <Channel>[];
        }
      }
      communities = list;
      channelsByCommunity = channels;
    } catch (_) {
      // Keep the locally-known records if the server can't list right now.
    } finally {
      communitiesLoaded = true;
      notifyListeners();
    }
  }

  Future<void> _refreshConversations({
    required bool notify,
    bool persist = true,
  }) async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    conversations = await client.conversations(current.token);
    await _loadRequestState(grandfather: false);
    // The server's list is the truth: a conversation no longer in it (an
    // admin removed this account, say) keeps no draft here.
    composerDrafts.retainOnly(conversations.map((item) => item.id));
    conversationsLoaded = true;
    _opErrors.remove(Ops.conversations);
    if (persist) await _persistSnapshot();
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> refreshSelectedMessages({
    bool notify = true,
    bool persist = true,
  }) async {
    final conversationId = selectedConversationId;
    if (conversationId == null) {
      return;
    }
    await _fetchMessages(conversationId, persist: persist);
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _fetchMessages(String conversationId,
      {bool persist = true}) async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    final page = await client.listMessagePage(current.token, conversationId);
    // Refetching the newest page rebuilds the head of the list, so any older
    // pages already merged in are re-merged rather than dropped — otherwise a
    // background sync would silently discard scrolled-back history.
    final existing = messagesByConversation[conversationId] ??
        const <ReceivedMessageEnvelope>[];
    final fresh = page.messages.map((message) => message.id).toSet();
    final older = existing
        .where((message) =>
            !fresh.contains(message.id) &&
            page.nextBefore != null &&
            _isOlderThanPage(message, page.messages))
        .toList(growable: false);
    messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
      ...messagesByConversation,
      conversationId: <ReceivedMessageEnvelope>[...page.messages, ...older],
    };
    _historyCursors[conversationId] = page.nextBefore;
    // A message that just landed ends its sender's "typing…" line.
    final newest = page.messages.firstOrNull;
    if (newest != null &&
        DateTime.now().difference(newest.createdAt) < typingExpiry) {
      typing.stoppedTyping(conversationId, newest.senderAccountId);
    }
    if (persist) await _persistSnapshot();
  }

  /// Messages arrive newest-first. A cached message is "older" than a fresh
  /// page when it sorts after the page's last (oldest) entry.
  bool _isOlderThanPage(
    ReceivedMessageEnvelope message,
    List<ReceivedMessageEnvelope> page,
  ) {
    if (page.isEmpty) {
      return false;
    }
    final oldest = page.last;
    final byCreatedAt = message.createdAt.compareTo(oldest.createdAt);
    return byCreatedAt != 0
        ? byCreatedAt < 0
        : message.id.compareTo(oldest.id) < 0;
  }

  /// Fetches the next older page for [conversationId] and prepends it. Safe to
  /// call repeatedly: it no-ops while a page is in flight and once the server
  /// reports no more history.
  Future<void> loadOlderMessages(String conversationId) async {
    final cursor = _historyCursors[conversationId];
    if (cursor == null || _loadingOlder.contains(conversationId)) {
      return;
    }
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    _loadingOlder.add(conversationId);
    notifyListeners();
    try {
      final page = await client.listMessagePage(
        current.token,
        conversationId,
        before: cursor,
      );
      final existing = messagesByConversation[conversationId] ??
          const <ReceivedMessageEnvelope>[];
      final known = existing.map((message) => message.id).toSet();
      final added = page.messages
          .where((message) => !known.contains(message.id))
          .toList(growable: false);
      messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
        ...messagesByConversation,
        conversationId: <ReceivedMessageEnvelope>[...existing, ...added],
      };
      _historyCursors[conversationId] = page.nextBefore;
      await _persistSnapshot();
    } catch (err) {
      _messageLoadErrors[conversationId] = describeError(err, l10n);
    } finally {
      _loadingOlder.remove(conversationId);
      notifyListeners();
    }
  }

  /// Loads a conversation's messages with tracked loading/error state so the
  /// chat pane can show a retry affordance instead of a misleading empty
  /// state when the fetch fails.
  Future<void> loadMessages(String conversationId) async {
    _loadingMessageConversations.add(conversationId);
    _messageLoadErrors.remove(conversationId);
    notifyListeners();
    try {
      // Local history first: it needs no server, so chats open offline.
      if (_mlsCrypto != null) await refreshHistory(conversationId);
      await _fetchMessages(conversationId);
      if (_mlsCrypto != null) await refreshHistory(conversationId);
      unawaited(markNewestMessageRead(conversationId));
    } catch (err) {
      _messageLoadErrors[conversationId] = describeError(err, l10n);
    } finally {
      _loadingMessageConversations.remove(conversationId);
      notifyListeners();
    }
  }

  Future<void> createGroup() async {
    await startConversation(kind: 'group');
  }

  /// The existing DM with [accountId], if the conversation list already
  /// names that peer. Returns null when no DM is known locally.
  Conversation? existingDmWith(String accountId) => conversations
      .where((conversation) =>
          conversation.isDm && conversation.peerAccountId == accountId)
      .firstOrNull;

  /// Creates a DM, group, or community channel conversation and selects it.
  Future<Conversation?> startConversation({
    required String kind,
    String? title,
    String? communityId,
    String? channelId,
    List<String> memberAccountIds = const <String>[],
    int? retentionSeconds,
  }) async {
    // One canonical DM per pair. The server enforces this too, but reusing
    // the known conversation avoids a pointless round trip and keeps the user
    // out of a second, indistinguishable thread with the same person.
    if (kind == 'dm' && memberAccountIds.length == 1) {
      final existing = existingDmWith(memberAccountIds.single);
      if (existing != null) {
        // Starting a conversation with the peer accepts them.
        await _acceptConversation(existing);
        selectConversation(existing.id);
        return existing;
      }
    }
    Conversation? created;
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      created = await client.createConversationDetailed(
        current.token,
        kind: kind,
        title: title,
        communityId: communityId,
        channelId: channelId,
        memberAccountIds: memberAccountIds,
        retentionSeconds: retentionSeconds,
      );
      final conversation = created!;
      await _setUpConversationGroup(conversation.id);
      conversations = <Conversation>[conversation, ...conversations];
      // The server may hand back a DM the peer created first.
      if (conversation.isDm) await _acceptConversation(conversation);
      selectedConversationId = conversation.id;
      messagesByConversation[conversation.id] = <ReceivedMessageEnvelope>[];
    });
    return error == null ? created : null;
  }

  Future<void> registerWithInvite(
    String baseUrl,
    String inviteCode,
    String username,
    String password,
  ) async {
    await _run(() async {
      _replaceApi(baseUrl);
      final enrollment = await api!.reserveRegistrationEnrollment(inviteCode);
      final credential =
          await cryptoService.createEnrollmentCredential(enrollment);
      session = await api!.register(
        inviteCode: inviteCode,
        username: username,
        password: password,
        deviceName: config.deviceName,
        enrollment: enrollment,
        credential: credential,
      );
      await localStore.saveSession(session!);
      await _mlsCrypto?.activateSession(session!);
      await _publishInitialMlsKeyPackages();
      await localStore.saveSyncCursor(0);
      await _refreshConversations(notify: true);
      await _refreshDevices();
      _startSync();
    });
  }

  Future<Invite?> createInvite({int maxUses = 1, DateTime? expiresAt}) async {
    Invite? created;
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      created = await client.createInvite(
        current.token,
        maxUses: maxUses,
        expiresAt: expiresAt,
      );
      invites = <Invite>[created!, ...invites];
    });
    return error == null ? created : null;
  }

  Future<void> revokeInvite(String inviteId) async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      await client.revokeInvite(current.token, inviteId);
      invites = invites.where((invite) => invite.id != inviteId).toList();
    });
  }

  Future<Community?> createCommunity(String name) async {
    Community? created;
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      created = await client.createCommunity(current.token, name);
      communities = <Community>[created!, ...communities];
    });
    return error == null ? created : null;
  }

  /// Creates a channel and its backing conversation in one server transaction.
  Future<void> createChannel(String communityId, String name) async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      final creation =
          await client.createChannel(current.token, communityId, name);
      await _setUpConversationGroup(creation.conversation.id);
      channelsByCommunity = <String, List<Channel>>{
        ...channelsByCommunity,
        communityId: <Channel>[
          creation.channel,
          ...channelsByCommunity[communityId] ?? const <Channel>[],
        ],
      };
      conversations = <Conversation>[
        creation.conversation,
        ...conversations.where((item) => item.id != creation.conversation.id),
      ];
      selectedConversationId = creation.conversation.id;
      await loadMessages(creation.conversation.id);
    });
  }

  Future<void> addConversationMember(
    String conversationId,
    String accountId, {
    String role = 'member',
  }) async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      if (!membershipChangesAvailable) {
        throw StateError('adding members is not available in this build');
      }
      await client.addConversationMember(
        current.token,
        conversationId,
        accountId,
        role: role,
      );
      // Their devices join the MLS group through reconcile (card I51).
      _mlsReconcileRequested = true;
      _mlsReconcileNow.add(conversationId);
      unawaited(_catchUpSyncEvents());
    });
  }

  /// Loads the server-recorded roster for a conversation.
  Future<bool> loadConversationMembers(String conversationId) {
    return _runScoped(Ops.members, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      final members =
          await client.conversationMembers(current.token, conversationId);
      membersByConversation = <String, List<ConversationMember>>{
        ...membersByConversation,
        conversationId: members,
      };
    });
  }

  /// Removes another member. Server membership only — MLS removal is a
  /// separate, still-pending commit, which the UI must state plainly.
  Future<bool> removeConversationMember(
    String conversationId,
    String accountId,
  ) {
    return _runScoped(Ops.members, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      await client.removeConversationMember(
        current.token,
        conversationId,
        accountId,
      );
      // Their devices leave the MLS group through reconcile (card I51).
      _mlsReconcileRequested = true;
      _mlsReconcileNow.add(conversationId);
      unawaited(_catchUpSyncEvents());
      membersByConversation = <String, List<ConversationMember>>{
        ...membersByConversation,
        conversationId: membersFor(conversationId)
            .where((member) => member.accountId != accountId)
            .toList(growable: false),
      };
    });
  }

  /// Leaves a conversation and drops its local state.
  Future<bool> leaveConversation(String conversationId) {
    return _runScoped(Ops.members, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      await client.removeConversationMember(
        current.token,
        conversationId,
        'me',
      );
      conversations = conversations
          .where((conversation) => conversation.id != conversationId)
          .toList(growable: false);
      messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
        for (final entry in messagesByConversation.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      };
      membersByConversation = <String, List<ConversationMember>>{
        for (final entry in membersByConversation.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      };
      _historyCursors.remove(conversationId);
      _mutes.remove(conversationId);
      unawaited(localStore
          .saveConversationMute(conversationId, muted: false)
          .catchError((Object _) {}));
      composerDrafts.remove(conversationId);
      if (selectedConversationId == conversationId) {
        selectedConversationId = null;
      }
      await _persistSnapshot();
    });
  }

  Future<void> refreshBlocks() async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    await _runScoped(Ops.blocks, () async {
      blockedAccounts = await client.listBlocks(current.token);
    });
    blocksLoaded = true;
    notifyListeners();
  }

  Future<bool> blockAccount(String accountId) {
    return _runScoped(Ops.blocks, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      final block = await client.blockAccount(current.token, accountId);
      blockedAccounts = <BlockedAccount>[
        block,
        ...blockedAccounts.where((item) => item.accountId != accountId),
      ];
      // Blocking hides the peer's future messages server-side, so the
      // conversation list and unread counts change immediately.
      await _refreshConversations(notify: false);
    });
  }

  Future<bool> unblockAccount(String accountId) {
    return _runScoped(Ops.blocks, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      await client.unblockAccount(current.token, accountId);
      blockedAccounts = blockedAccounts
          .where((item) => item.accountId != accountId)
          .toList(growable: false);
      await _refreshConversations(notify: false);
    });
  }

  /// Messages this device holds that match [query] (W10). Answered from the
  /// encrypted local database: no request is made and nothing is sent.
  Future<List<MessageSearchHit>> searchMessages(String query) =>
      localStore.searchMessages(query);

  /// Best-effort read of the server's mute. Silent on failure: an unknown
  /// mute state must not block opening a conversation.
  ///
  /// Returns whether the mute was read.
  Future<bool> loadConversationMuted(String conversationId) async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return false;
    }
    try {
      final mute = await client.conversationMute(current.token, conversationId);
      _setMuteLocally(conversationId, mute);
      return true;
    } catch (_) {
      // Leave the last known value; the control still reports its own errors.
      return false;
    }
  }

  Future<bool> setConversationMuted(String conversationId, bool muted) =>
      setConversationMute(
          conversationId, muted ? MuteDuration.always : MuteDuration.off);

  /// Mutes push for [duration] (or unmutes with [MuteDuration.off]). The
  /// server ends a timed mute by itself, and so does this device.
  Future<bool> setConversationMute(
      String conversationId, MuteDuration duration) {
    return _runScoped(Ops.mute, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      final length = duration.length;
      final applied = await client.setConversationMute(
        current.token,
        conversationId,
        muted: duration != MuteDuration.off,
        until: length == null ? null : DateTime.now().toUtc().add(length),
      );
      _setMuteLocally(conversationId, applied);
    });
  }

  void _setMuteLocally(String conversationId, ConversationMute mute) {
    final before = _mutes.containsKey(conversationId)
        ? (_mutes[conversationId], true)
        : (null, false);
    if (mute.muted) {
      _mutes[conversationId] = mute.until;
    } else {
      _mutes.remove(conversationId);
    }
    final after = _mutes.containsKey(conversationId)
        ? (_mutes[conversationId], true)
        : (null, false);
    if (before != after) {
      unawaited(localStore
          .saveConversationMute(conversationId,
              muted: mute.muted, until: mute.until)
          .catchError((Object _) {}));
      _armMuteTimer();
      notifyListeners();
    }
  }

  /// Wakes the screens when the next timed mute ends, so a chat list never
  /// shows a mute that is over.
  void _armMuteTimer() {
    _muteTimer?.cancel();
    _muteTimer = null;
    final now = DateTime.now();
    DateTime? next;
    for (final until in _mutes.values) {
      if (until != null && until.isAfter(now)) {
        if (next == null || until.isBefore(next)) next = until;
      }
    }
    if (next == null) return;
    var delay = next.difference(now) + const Duration(milliseconds: 250);
    if (delay > const Duration(days: 1)) delay = const Duration(days: 1);
    _muteTimer = Timer(delay, () {
      _muteTimer = null;
      _mutes.removeWhere(
          (_, until) => until != null && !until.isAfter(DateTime.now()));
      _armMuteTimer();
      notifyListeners();
    });
  }

  // ---- drafts (W6) ---------------------------------------------------------

  void _draftChanged(String conversationId) {
    _draftTimers.remove(conversationId)?.cancel();
    if (session == null) return;
    final empty = composerDrafts.textFor(conversationId).isEmpty &&
        composerDrafts.replyTargetFor(conversationId) == null;
    if (empty) {
      // Deleting needs no debounce, and must not wait behind a stale write.
      unawaited(_persistDraft(conversationId));
      return;
    }
    _draftTimers[conversationId] = Timer(const Duration(milliseconds: 500), () {
      _draftTimers.remove(conversationId);
      unawaited(_persistDraft(conversationId));
    });
  }

  Future<void> _persistDraft(String conversationId) async {
    if (session == null) return;
    final generation = _sessionGeneration;
    final text = composerDrafts.textFor(conversationId);
    final replyTo = composerDrafts.replyTargetFor(conversationId);
    try {
      if (text.isEmpty && replyTo == null) {
        await localStore.deleteDraft(conversationId);
      } else {
        if (generation != _sessionGeneration) return;
        await localStore.saveDraft(conversationId, text, replyTo: replyTo);
      }
    } catch (_) {
      // A draft that cannot be saved is still in memory; never block typing.
    }
  }

  /// Writes pending drafts now. Called when the app leaves the foreground,
  /// because a process that is stopped there may never run its timers.
  void flushDrafts() {
    final pending = _draftTimers.keys.toList(growable: false);
    for (final id in pending) {
      _draftTimers.remove(id)?.cancel();
      unawaited(_persistDraft(id));
    }
  }

  void _cancelDraftTimers() {
    for (final timer in _draftTimers.values) {
      timer.cancel();
    }
    _draftTimers.clear();
  }

  Future<void> setConversationRetention(
    String conversationId,
    int? retentionSeconds,
  ) async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      final updated = await client.updateRetention(
        current.token,
        conversationId,
        retentionSeconds,
      );
      conversations =
          conversations.map((c) => c.id == updated.id ? updated : c).toList();
    });
  }

  Future<List<MetadataSearchResult>> searchMetadata(String query) async {
    final current = session;
    final client = api;
    if (current == null || client == null || query.trim().isEmpty) {
      return const <MetadataSearchResult>[];
    }
    try {
      return await client.searchMetadata(current.token, query.trim());
    } catch (err) {
      // The search screen shows the thrown error's text, so hand it only
      // the mapped sentence (card T44A).
      throw UserFacingException(describeError(err, l10n));
    }
  }

  /// Best-effort read receipt for the newest visible message. Failures are
  /// intentionally silent; receipts must never block reading.
  Future<void> markNewestMessageRead(String conversationId) async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    // No read receipt for a request: the sender learns nothing until accepted.
    if (_heldBack(conversationId)) {
      return;
    }
    final messages = messagesByConversation[conversationId] ??
        const <ReceivedMessageEnvelope>[];
    if (messages.isEmpty) {
      return;
    }
    try {
      // With the switch off the receipt is private: the server keeps this
      // account's own cursor for the unread count and shares nothing.
      await receiptPreferences.loaded;
      if (receiptPreferences.sendReadReceipts) {
        await client.markRead(current.token, conversationId, messages.first.id);
      } else {
        await client.markReadPrivate(
            current.token, conversationId, messages.first.id);
      }
      // Clear the unread badge immediately rather than waiting for the next
      // conversation refresh; the receipt has landed server-side.
      var changed = false;
      conversations = conversations.map((c) {
        if (c.id == conversationId && c.unreadCount != 0) {
          changed = true;
          return c.copyWith(unreadCount: 0);
        }
        return c;
      }).toList();
      if (changed) {
        notifyListeners();
      }
    } catch (_) {
      // Ignored: read receipts are advisory.
    }
  }

  Future<void> deleteAccount() async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      await client.deleteAccount(current.token);
      await _clearLocalSession();
    });
  }

  /// Streams bounded server pages into a local JSON file. The file contains
  /// page objects so a large account never needs to be assembled in memory.
  /// The server's export remains ciphertext-only for message content.
  Future<String?> exportAccount() async {
    String? path;
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }

      final directory = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
            RegExp(r'[^0-9]'),
            '',
          );
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        'veritra-account-export-v2-$stamp.json',
      );
      final temporaryFile = File('${file.path}.part');
      IOSink? sink;
      var completed = false;
      try {
        const header = '{"manifest_version":"v2","pages":[';
        const footer = ']}';
        const maxExportBytes = 256 * 1024 * 1024;
        var totalBytes = utf8.encode(header).length;
        sink = temporaryFile.openWrite();
        sink.write(header);
        String? before;
        var firstPage = true;
        var pageCount = 0;
        while (true) {
          if (pageCount >= 2000) {
            throw StateError('Account export has too many pages');
          }
          final page = await client.exportAccountPage(
            current.token,
            limit: 250,
            before: before,
          );
          final encodedPage = utf8.encode(jsonEncode(page));
          final separatorBytes = firstPage ? 0 : 1;
          if (totalBytes +
                  separatorBytes +
                  encodedPage.length +
                  utf8.encode(footer).length >
              maxExportBytes) {
            throw StateError('Account export exceeds the size limit');
          }
          if (!firstPage) {
            sink.add(const <int>[0x2c]);
          }
          sink.add(encodedPage);
          totalBytes += separatorBytes + encodedPage.length;
          firstPage = false;
          pageCount++;
          final next = page['next_before'];
          if (next == null) {
            break;
          }
          if (next is! String || next.isEmpty || next == before) {
            throw StateError('Account export cursor did not advance');
          }
          before = next;
        }
        sink.write(footer);
        await sink.flush();
        await sink.close();
        sink = null;
        await temporaryFile.rename(file.path);
        completed = true;
        path = file.path;
      } finally {
        await sink?.close();
        if (!completed && await temporaryFile.exists()) {
          await temporaryFile.delete();
        }
      }
    });
    return error == null ? path : null;
  }

  Future<void> sendMessage(String plaintext) async {
    final conversationId = selectedConversationId;
    if (conversationId != null) {
      await sendMessageTo(conversationId, plaintext);
    }
  }

  /// Selecting a conversation also loads what the details and chat views need
  /// without making either of them wait on the other.
  void selectAndPrepare(String conversationId) {
    selectConversation(conversationId);
    unawaited(loadConversationMuted(conversationId));
    // The roster names message senders in group chats; a failure here only
    // falls back to shortened account IDs.
    unawaited(loadConversationMembers(conversationId));
  }

  /// Encrypts, queues, and delivers one message. Scoped to [Ops.send] so a
  /// slow or failed send only affects the composer, and the queued envelope
  /// stays retryable from its pending bubble either way.
  Future<bool> sendMessageTo(String conversationId, String plaintext) =>
      _sendPayload(conversationId, AppPayloadType.text,
          <String, Object?>{'text': plaintext});

  /// Replies to the message with local history key [targetKey] (D22).
  Future<bool> replyTo(String conversationId, String targetKey, String text) =>
      _sendPayload(conversationId, AppPayloadType.reply,
          <String, Object?>{'text': text, 'reply_to_id': targetKey});

  /// Replaces the text of one of this account's own messages.
  Future<bool> editMessage(
          String conversationId, String targetKey, String text) =>
      _sendPayload(conversationId, AppPayloadType.edit,
          <String, Object?>{'message_id': targetKey, 'text': text});

  /// Deletes one of this account's own messages for every member.
  Future<bool> deleteMessage(String conversationId, String targetKey) =>
      _sendPayload(conversationId, AppPayloadType.delete,
          <String, Object?>{'message_id': targetKey});

  /// Sets this account's reaction on a message; an empty [reaction] clears it.
  Future<bool> react(
          String conversationId, String targetKey, String reaction) =>
      _sendPayload(conversationId, AppPayloadType.reaction,
          <String, Object?>{'message_id': targetKey, 'reaction': reaction});

  /// Encrypts the file at [path] on this device, uploads only its
  /// ciphertext, then sends the key and name inside an MLS manifest message.
  /// Encryption and upload run outside the session queue so a large file
  /// never holds up other sends; only the manifest joins the outbox.
  Future<bool> sendAttachment(
    String conversationId, {
    required String path,
    required String fileName,
    String? mediaType,
    AttachmentCancellationToken? cancellation,
  }) async {
    final service = attachmentService;
    final current = session;
    final client = api;
    if (service == null || _mlsCrypto == null) return false;
    if (current == null || client == null) return false;
    final ownerGeneration = _sessionGeneration;
    _busyOps.add(Ops.attachment);
    _opErrors.remove(Ops.attachment);
    notifyListeners();
    PreparedEncryptedAttachment? prepared;
    try {
      final name = safeAttachmentName(fileName);
      prepared = await service.encryptFile(
        sourcePath: path,
        conversationId: conversationId,
        attachmentActionId: _randomHexId(),
        fileName: name,
        mediaType: attachmentMediaType(name, mediaType),
        cancellation: cancellation,
      );
      final uploaded = await client.uploadEncryptedAttachment(
        current.token,
        conversationId,
        prepared.openRead(),
        ciphertextLength: prepared.ciphertextLength,
        cryptoMetadata: attachmentUploadMetadata,
      );
      if (!_syncOwnerActive(current, ownerGeneration)) return false;
      final sent = await _sendPayload(
        conversationId,
        AppPayloadType.attachmentManifest,
        <String, Object?>{
          'attachments': <Object?>[
            <String, Object?>{
              ...prepared.manifest,
              'id': uploaded.id,
              'ciphertext_size': prepared.ciphertextLength,
            },
          ],
        },
        attachmentRefs: <String>[uploaded.id],
      );
      if (!sent) {
        _opErrors[Ops.attachment] =
            _opErrors[Ops.send] ?? l10n.attachmentSendFailedState;
      }
      return sent;
    } catch (err) {
      _opErrors[Ops.attachment] = describeError(err, l10n);
      return false;
    } finally {
      await prepared?.cleanup();
      _busyOps.remove(Ops.attachment);
      notifyListeners();
    }
  }

  /// Downloads one attachment's ciphertext and decrypts it in memory. The
  /// ciphertext and plaintext only touch disk as temporary files, which are
  /// removed before this returns.
  Future<Uint8List> loadAttachment(
    AttachmentEntry entry, {
    required String conversationId,
  }) async {
    final service = attachmentService;
    final current = session;
    final client = api;
    if (service == null || current == null || client == null) {
      throw StateError('attachments are unavailable');
    }
    // The caller's conversation decides, not the manifest's claim; the
    // manifest must still name the same conversation.
    if (entry.manifest['conversation_id'] != conversationId) {
      throw StateError('attachment belongs to another conversation');
    }
    if (!conversationOpen(conversationId)) {
      throw StateError('attachments wait until the request is accepted');
    }
    final directory = await service.workingDirectory();
    final base = '${directory.path}${Platform.pathSeparator}'
        '.veritra-attachment-${_randomHexId()}';
    final ciphertext = File('$base.ciphertext');
    final plaintext = File('$base.plaintext');
    try {
      final stream =
          await client.downloadEncryptedAttachment(current.token, entry.id);
      final sink = ciphertext.openWrite();
      var received = 0;
      try {
        await for (final chunk in stream) {
          received += chunk.length;
          if (received > entry.ciphertextSize) {
            throw const FormatException('attachment is larger than announced');
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (received != entry.ciphertextSize) {
        throw const FormatException('attachment is smaller than announced');
      }
      await service.decryptFile(
        ciphertextPath: ciphertext.path,
        destinationPath: plaintext.path,
        manifest: entry.manifest,
      );
      return await plaintext.readAsBytes();
    } finally {
      for (final file in <File>[ciphertext, plaintext]) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // Best effort: the temporary directory is cleared by the system.
        }
      }
    }
  }

  /// Decrypts one attachment into [destinationPath], a location the user
  /// chose.
  Future<void> saveAttachment(
    AttachmentEntry entry,
    String destinationPath, {
    required String conversationId,
  }) async {
    final bytes = await loadAttachment(entry, conversationId: conversationId);
    await File(destinationPath).writeAsBytes(bytes, flush: true);
  }

  /// The most plaintext bytes the server accepts for one attachment (the
  /// operator's `PRIVATE_MESSENGER_LIMIT_ATTACHMENT_MIB`), as its setup
  /// status reports it. An older server, or one that cannot be reached,
  /// leaves the app's own ceiling.
  Future<int> attachmentSizeLimit() async {
    try {
      final status = await api?.setupStatus();
      final limit = status?['max_attachment_bytes'];
      if (limit is int && limit > 0) {
        return limit < maxPlaintextAttachmentBytes
            ? limit
            : maxPlaintextAttachmentBytes;
      }
    } catch (_) {
      // The upload itself still enforces the cap.
    }
    return maxPlaintextAttachmentBytes;
  }

  Future<bool> _sendPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
  }) {
    return _runScoped(Ops.send, () async {
      final current = session;
      final client = api;
      final conversation =
          conversations.where((item) => item.id == conversationId).firstOrNull;
      if (current == null || client == null || conversation == null) {
        return;
      }
      // Replying counts as accepting.
      if (isMessageRequest(conversation)) {
        await _acceptConversation(conversation);
      }
      if (!await localStore.hasOutboxCapacity()) {
        throw const OutboxFullException();
      }
      if (mlsConversationFailed(conversation.id)) {
        throw const ConversationPausedException();
      }
      final mls = _mlsCrypto;
      final MessageEnvelope encrypted;
      if (type == AppPayloadType.text) {
        encrypted = await cryptoService.encrypt(
            conversation.id, body['text'] as String);
      } else if (mls != null) {
        encrypted = await mls.encryptPayload(conversation.id, type, body,
            attachmentRefs: attachmentRefs);
      } else {
        throw StateError('Production MLS/OpenMLS encryption is not integrated');
      }
      final draftText = body['text'] as String?;
      await localStore.enqueueEnvelope(encrypted, draftText: draftText);
      if (mls != null) await refreshHistory(conversation.id);
      final record = (await localStore.pendingEnvelopeRecords())
          .where((item) =>
              item.envelope.idempotencyKey == encrypted.idempotencyKey)
          .firstOrNull;
      if (record != null) {
        _outboxRecords[encrypted.idempotencyKey] = record;
      }
      pendingOutbox = <MessageEnvelope>[...pendingOutbox, encrypted];
      _outboxStates[encrypted.idempotencyKey] = OutboxDeliveryState.sending;
      notifyListeners();
      // Durable acceptance is the send result. Network delivery is owned by
      // the single retry worker, so a slow connection never holds the draft.
      unawaited(_flushOutbox());
    });
  }

  Future<void> retryEnvelope(String idempotencyKey) async {
    await _runScoped(Ops.send, () async {
      final record = _outboxRecords[idempotencyKey] ??
          (await localStore.pendingEnvelopeRecords())
              .where((item) => item.envelope.idempotencyKey == idempotencyKey)
              .firstOrNull;
      if (record == null || record.terminal) {
        return;
      }
      _outboxStates[idempotencyKey] = OutboxDeliveryState.sending;
      notifyListeners();
      _manualRetryKey = idempotencyKey;
      await _flushOutbox();
    });
  }

  Future<void> discardEnvelope(String idempotencyKey) async {
    await _removeFromOutboxByKey(idempotencyKey);
  }

  Future<void> createDeviceLink() async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      if (!membershipChangesAvailable) {
        throw StateError('device linking is not available in this build');
      }
      activeDeviceLink = await client.createDeviceLink(current.token);
    });
  }

  Future<void> approveActiveDeviceLink(String verificationCode) async {
    await _run(() async {
      final current = session;
      final client = api;
      final link = activeDeviceLink;
      if (current == null || client == null || link == null) {
        return;
      }
      if (link.verificationCode.isEmpty ||
          verificationCode.trim() != link.verificationCode ||
          link.transcriptHash?.length != 32) {
        throw StateError('Device-link verification did not match locally');
      }
      activeDeviceLink = await client.approveDeviceLink(
        current.token,
        link.id,
        link.transcriptHash!,
      );
    });
  }

  Future<void> refreshActiveDeviceLink() async {
    await _run(() async {
      final current = session;
      final client = api;
      final link = activeDeviceLink;
      if (current == null || client == null || link == null) {
        return;
      }
      try {
        activeDeviceLink = await _refreshedDeviceLink(current, client, link);
      } catch (_) {
        // Fail closed: whatever was verified before no longer stands, so
        // approval is impossible until a refresh passes every check.
        activeDeviceLink = _deviceLinkWithoutVerification(link);
        rethrow;
      }
    });
  }

  /// The link after a status refresh. The account and nonce are the ones
  /// this device received when it created the link; the server cannot swap
  /// them later, and its relayed transcript hash must match the one derived
  /// here.
  Future<DeviceLink> _refreshedDeviceLink(
      Session current, ApiClient client, DeviceLink link) async {
    final accountId = link.accountId;
    final linkNonce = link.linkNonce;
    if (accountId == null || linkNonce == null || linkNonce.length != 32) {
      throw StateError('Device-link transcript context is incomplete');
    }
    final refreshed = await client.deviceLink(current.token, link.id);
    if ((refreshed.accountId != null && refreshed.accountId != accountId) ||
        (refreshed.linkNonce != null &&
            !_constantTimeBytesEqual(linkNonce, refreshed.linkNonce!))) {
      throw StateError('Device-link transcript was substituted');
    }
    var merged = DeviceLink(
      id: refreshed.id,
      state: refreshed.state,
      verificationCode: link.verificationCode,
      expiresAt: refreshed.expiresAt,
      code: link.code ?? refreshed.code,
      linkUri: link.linkUri ?? refreshed.linkUri,
      claimedDeviceName: refreshed.claimedDeviceName,
      approvedDeviceId: refreshed.approvedDeviceId,
      accountId: accountId,
      createdByDeviceId: refreshed.createdByDeviceId,
      protocolVersion: refreshed.protocolVersion,
      linkNonce: linkNonce,
      existingSigningKey: refreshed.existingSigningKey,
      claimedDeviceId: refreshed.claimedDeviceId,
      claimedSigningKey: refreshed.claimedSigningKey,
      transcriptHash: link.transcriptHash ?? refreshed.transcriptHash,
    );
    if (refreshed.state == 'claimed') {
      if (refreshed.protocolVersion == null ||
          refreshed.claimedDeviceId == null ||
          refreshed.claimedSigningKey?.length != 32) {
        throw StateError('Device-link transcript context is incomplete');
      }
      final relayedHash = refreshed.transcriptHash;
      if (relayedHash == null) {
        throw StateError('Device-link transcript hash is missing');
      }
      final verification = await cryptoService.deriveDeviceLinkVerification(
        accountId: accountId,
        protocolVersion: refreshed.protocolVersion!,
        linkNonce: linkNonce,
        peerDeviceId: refreshed.claimedDeviceId!,
        peerSigningKey: refreshed.claimedSigningKey!,
        localIsExistingDevice: true,
      );
      if (!_constantTimeBytesEqual(verification.transcriptHash, relayedHash)) {
        throw StateError('Device-link transcript was substituted');
      }
      merged = _deviceLinkWithVerification(merged, verification);
    }
    return merged;
  }

  Future<void> claimDeviceLink(String baseUrl, String code) async {
    await _run(() async {
      _replaceApi(baseUrl);
      final enrollment = await api!.reserveDeviceLinkEnrollment(code);
      final credential =
          await cryptoService.createEnrollmentCredential(enrollment);
      if (enrollment.protocolVersion == null ||
          enrollment.linkNonce?.length != 32 ||
          enrollment.existingDeviceId == null ||
          enrollment.existingSigningKey?.length != 32) {
        throw StateError('Device-link transcript context is incomplete');
      }
      final verification = await cryptoService.deriveDeviceLinkVerification(
        accountId: enrollment.accountId,
        protocolVersion: enrollment.protocolVersion!,
        linkNonce: enrollment.linkNonce!,
        peerDeviceId: enrollment.existingDeviceId!,
        peerSigningKey: enrollment.existingSigningKey!,
        localIsExistingDevice: false,
      );
      final claimed = await api!.claimDeviceLink(
        code: code,
        deviceName: 'Linked ${config.deviceName.toLowerCase()}',
        enrollment: enrollment,
        credential: credential,
        verification: verification,
      );
      if (claimed.deviceLink.transcriptHash != null &&
          !_constantTimeBytesEqual(claimed.deviceLink.transcriptHash!,
              verification.transcriptHash)) {
        throw StateError('Device-link transcript was substituted');
      }
      pendingDeviceLinkClaim = DeviceLinkClaim(
        deviceLink:
            _deviceLinkWithVerification(claimed.deviceLink, verification),
        claimToken: claimed.claimToken,
        deviceSecret: claimed.deviceSecret,
      );
    });
  }

  Future<void> completeDeviceLinkClaim() async {
    await _run(() async {
      final client = api;
      final claim = pendingDeviceLinkClaim;
      if (client == null || claim == null) {
        return;
      }
      if (claim.deviceLink.transcriptHash?.length != 32) {
        throw StateError('Device-link transcript is unavailable');
      }
      final linkedSession = await client.completeDeviceLinkClaim(
        claim.deviceLink.id,
        claim.claimToken,
        claim.deviceLink.transcriptHash!,
      );
      if (linkedSession == null) {
        return;
      }
      session = Session(
        baseUrl: linkedSession.baseUrl,
        token: linkedSession.token,
        accountId: linkedSession.accountId,
        deviceId: linkedSession.deviceId,
        username: linkedSession.username,
        deviceSecret: claim.deviceSecret,
        role: linkedSession.role,
      );
      pendingDeviceLinkClaim = null;
      await localStore.saveSession(session!);
      await _mlsCrypto?.activateSession(session!);
      await _publishInitialMlsKeyPackages();
      await localStore.saveSyncCursor(0);
      await _refreshConversations(notify: true);
      await _refreshDevices();
      _startSync();
    });
  }

  Future<void> logout() async {
    await _run(() async {
      final current = session;
      final client = api;
      await _stopPush(current, client);
      await _clearLocalSession(preserveDeviceIdentity: true);
      if (current != null && client != null) {
        try {
          await client.logout(current.token);
        } catch (_) {
          // Local sign-out is the security boundary. The remote token expires
          // normally if revocation cannot be delivered while offline.
        }
      }
    });
  }

  Future<void> logoutOtherDevices() async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      await client.logoutAll(current.token);
      await _refreshDevices();
    });
  }

  Future<bool> reauthenticate(String password) async {
    var succeeded = false;
    await _run(() async {
      final current = session;
      final client = api;
      final deviceSecret = current?.deviceSecret;
      if (current == null || client == null || deviceSecret == null) {
        throw StateError(l10n.errorRelinkRequired);
      }
      final rotated =
          await client.reauthenticate(current.token, password, deviceSecret);
      if (rotated != null && !identical(session, current)) {
        // The session ended or changed while the request was in flight; the
        // caller must not run a sensitive action on its behalf.
        return;
      }
      if (rotated != null) {
        // The server rotated the token (card T37C): persist it before use so
        // a restart never reloads the old one, then reconnect sync with it.
        // A failure here leaves the old token, which the server still accepts
        // for a short grace, so the user can simply retry.
        final next = Session(
          baseUrl: current.baseUrl,
          token: rotated,
          accountId: current.accountId,
          deviceId: current.deviceId,
          username: current.username,
          deviceSecret: current.deviceSecret,
          role: current.role,
        );
        await localStore.saveSession(next);
        session = next;
        unawaited(_startSync());
      }
      succeeded = true;
    });
    return succeeded;
  }

  Future<void> changePassword(String newPassword) async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      await client.changePassword(current.token, newPassword);
    });
  }

  Future<void> revokeDevice(String deviceId) async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      await client.revokeDevice(current.token, deviceId);
      if (deviceId == current.deviceId) {
        await _clearLocalSession();
      } else {
        await _refreshDevices();
      }
    });
  }

  Future<ConversationSafetyNumber> conversationSafetyNumber(
      String conversationId) async {
    final mls = _mlsCrypto;
    if (mls == null) throw StateError('production MLS is unavailable');
    return mls.conversationSafetyNumber(conversationId);
  }

  /// Stored verifications start with the safety-number version they were
  /// made under. Version 1 hashed the group epoch, so every one of them
  /// would now read as a false "changed"; they count as not verified.
  static const _safetyNumberVersion = 2;

  Future<void> markPeerVerified(
      String conversationId, String peerAccountId) async {
    final safety = await conversationSafetyNumber(conversationId);
    await localStore.savePeerVerification(conversationId, peerAccountId,
        <int>[_safetyNumberVersion, ...safety.transcriptHash]);
  }

  Future<PeerVerificationStatus> peerVerificationStatus(
      String conversationId, String peerAccountId) async {
    final saved =
        await localStore.loadPeerVerification(conversationId, peerAccountId);
    if (saved == null ||
        saved.length != 33 ||
        saved.first != _safetyNumberVersion) {
      return PeerVerificationStatus.unverified;
    }
    final current = await conversationSafetyNumber(conversationId);
    return _constantTimeBytesEqual(saved.sublist(1), current.transcriptHash)
        ? PeerVerificationStatus.verified
        : PeerVerificationStatus.changed;
  }

  /// Whether a scanned safety code is exactly this device's code for the
  /// conversation. Both devices must see the same member devices.
  Future<bool> safetyCodeMatches(String conversationId, String scanned) async {
    final current = await conversationSafetyNumber(conversationId);
    return _constantTimeBytesEqual(
        utf8.encode(scanned.trim()), utf8.encode(current.qrPayload));
  }

  void selectConversation(String id) {
    selectedConversationId = id;
    notifyListeners();
    // A request loads nothing until it is accepted.
    if (!_heldBack(id)) {
      unawaited(loadMessages(id));
      unawaited(refreshReceipts(id));
    }
  }

  Timer? _receiptsRefreshTimer;

  /// Pause before delivery announcements are acted on (W5).
  static const Duration receiptsRefreshDebounce = Duration(milliseconds: 500);

  /// Routes the realtime frames that are not stored events (W5): typing and
  /// delivery announcements. True when the frame was one of them.
  @visibleForTesting
  bool handleEphemeralFrame(Map<String, Object?> frame) {
    final type = frame['type'];
    final conversationId = frame['conversation_id'];
    if (type == 'sync.connected') {
      // Delivery announcements are never stored, so any sent while the socket
      // was down are read again here. The catch-up still runs.
      final selected = selectedConversationId;
      if (selected != null) unawaited(refreshReceipts(selected));
      return false;
    }
    if (type != 'typing.updated' && type != 'delivery_receipt.updated') {
      return false;
    }
    if (conversationId is! String) return true;
    if (type == 'delivery_receipt.updated') {
      if (conversationId == selectedConversationId) {
        // A busy group sends one per member per message: read the cursors
        // once after the burst.
        _receiptsRefreshTimer?.cancel();
        _receiptsRefreshTimer = Timer(receiptsRefreshDebounce, () {
          if (!_disposed && conversationId == selectedConversationId) {
            unawaited(refreshReceipts(conversationId));
          }
        });
      }
      return true;
    }
    final payload = frame['payload'];
    final accountId = payload is Map ? payload['account_id'] : null;
    if (accountId is String && accountId != session?.accountId) {
      typing.remoteTyping(conversationId, accountId);
    }
    return true;
  }

  /// Adopts the account's read-receipts switch from the server, so a change
  /// made on another linked device shows here. Best effort.
  Future<void> refreshReadReceiptsSetting() async {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    try {
      final enabled = await client.readReceiptsEnabled(current.token);
      if (_disposed || !_sameSession(current)) return;
      await receiptPreferences.setSendReadReceipts(enabled);
    } catch (_) {
      // The saved choice on this device stands.
    }
  }

  /// Flips the account's read-receipts switch (every linked device follows).
  /// False when the server could not be told; the switch then stays as it was.
  Future<bool> setSendReadReceipts(bool enabled) async {
    final current = session;
    final client = api;
    if (current == null || client == null) return false;
    try {
      await client.setReadReceiptsEnabled(current.token, enabled);
    } catch (_) {
      return false;
    }
    await receiptPreferences.setSendReadReceipts(enabled);
    return true;
  }

  /// Whether ticks are offered in [conversationId]: DMs and groups up to
  /// [tickMaxMembers], never community channels.
  bool ticksApply(String conversationId) {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conversation == null || conversation.isChannel) return false;
    final members = membersFor(conversationId).length;
    return members <= tickMaxMembers;
  }

  /// Reads the other members' delivery and read cursors. Best effort: the
  /// ticks simply stay as they were when it fails.
  Future<void> refreshReceipts(String conversationId) async {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    try {
      final list = await client.listReceipts(current.token, conversationId);
      if (_disposed || !_sameSession(current)) return;
      receipts.set(conversationId, list);
    } catch (_) {
      // Advisory only.
    }
  }

  /// Tells the other members this account is typing in [conversationId].
  /// Throttled, skipped in conversations too large for a typing line, and
  /// never retried: a missed signal is simply a missed signal.
  void notifyTyping(String conversationId) {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    final known = membersFor(conversationId).length;
    final members =
        known > 0 ? known : receipts.receiptsFor(conversationId).length + 1;
    if (members < 2 || members > typingMaxMembers) return;
    if (!typing.takeSendSlot(conversationId)) return;
    unawaited(
      client
          .sendTyping(current.token, conversationId)
          .catchError((Object _) {}),
    );
  }

  Future<void> _startSync() async {
    final current = session;
    if (current == null) {
      return;
    }
    final ownerGeneration = ++_sessionGeneration;
    final previousOwner = _syncOwner;
    final previousLease = _syncLease;
    _syncOwner = null;
    _syncLease = null;
    previousOwner?.dispose();
    await previousOwner?.cancelAndDrain();
    if (previousLease != null) {
      await localStore.releaseSyncLease(previousLease);
    }
    if (ownerGeneration != _sessionGeneration || !_sameSession(current)) {
      return;
    }
    final accountId = current.accountId;
    final deviceId = current.deviceId;
    if (accountId == null || deviceId == null) return;
    final lease = LocalSyncLease(
      origin: current.baseUrl,
      accountId: accountId,
      deviceId: deviceId,
      generation: ownerGeneration,
    );
    await localStore.acquireSyncLease(lease);
    if (ownerGeneration != _sessionGeneration || !_sameSession(current)) {
      await localStore.releaseSyncLease(lease);
      return;
    }
    _syncLease = lease;
    _syncOwner = AccountSyncEngine(
      isOwner: () =>
          ownerGeneration == _sessionGeneration && _sameSession(current),
      work: () => _runOwnedCatchUp(current, ownerGeneration),
    );
    final previousSubscription = _syncSubscription;
    _syncSubscription = null;
    await previousSubscription?.cancel();
    final previousSync = sync;
    sync = null;
    // Close the old socket before opening one for this session so two
    // authenticated sockets never overlap.
    await previousSync?.dispose();
    if (ownerGeneration != _sessionGeneration || !_sameSession(current)) {
      return;
    }
    sync = syncServiceFactory(current.baseUrl, current.token);
    _setConnectionStatus(ConnectionStatus.connecting);
    _syncSubscription = sync!.events.listen(
      (frame) {
        // Ephemeral frames carry nothing to catch up on.
        if (handleEphemeralFrame(frame)) return;
        unawaited(_catchUpSyncEvents());
        unawaited(_flushMlsOutbox());
      },
      onError: (_) {
        // A dropped socket alone is not proof the server is unreachable; the
        // catch-up attempt that follows decides online vs. offline.
        unawaited(_catchUpSyncEvents());
        unawaited(_flushMlsOutbox());
      },
    );
    unawaited(_catchUpSyncEvents());
    unawaited(_flushOutbox());
    unawaited(_flushMlsOutbox());
    unawaited(sync!.connect());
    // _startSync runs exactly once per established session, which makes it
    // the single hook for hydrating server-listed records.
    unawaited(refreshInvites());
    unawaited(refreshCommunities());
    unawaited(refreshBlocks());
    unawaited(refreshReadReceiptsSetting());
    unawaited(_startPush());
  }

  void _setConnectionStatus(ConnectionStatus status) {
    if (connectionStatus == status) {
      return;
    }
    connectionStatus = status;
    notifyListeners();
    if (status == ConnectionStatus.online) {
      // The MLS worker hands over to the application outbox when it ends.
      unawaited(_flushMlsOutbox());
    }
  }

  Future<void> _startPush() async {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    final ownerGeneration = _sessionGeneration;
    try {
      final config = await client.pushConfig(current.token);
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      final vapid = config['vapid_public_key'] as String? ?? '';
      final providers = (config['providers'] as List? ?? const <Object?>[])
          .whereType<String>()
          .toList(growable: false);
      if (config['enabled'] != true || providers.isEmpty) {
        pushConfigured = false;
        _setPushState(PushState.serverDisabled);
        return;
      }
      pushConfigured = true;
      pushProviders = providers;
      notificationPermission = await pushService.notificationPermission();
      _setPushState(PushState.registering);
      _pushInstance = '${current.accountId}:${current.deviceId}';
      await _pushSubscription?.cancel();
      _pushSubscription = pushService.events.listen(_handlePushEvent);
      final wakeGeneration = await pushService.pendingWakeGeneration();
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      if (wakeGeneration > 0) {
        _pendingWakeGeneration = max(_pendingWakeGeneration, wakeGeneration);
        unawaited(_catchUpSyncEvents());
      }
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      await pushService.register(
          instance: _pushInstance!, vapid: vapid, providers: providers);
      notifyListeners();
    } catch (_) {
      // Push is optional; realtime and foreground catch-up remain available.
      if (pushState == PushState.registering) {
        _setPushState(PushState.registrationFailed);
      }
    }
  }

  /// Where push stands for this device (card I41). Never claims more than
  /// was observed: "registered" only after the server accepted the token.
  PushState pushState = PushState.unknown;

  /// The providers the server offers.
  List<String> pushProviders = const <String>[];

  /// The provider this device registered with, once registered.
  String? pushProvider;
  NotificationPermission notificationPermission =
      NotificationPermission.unsupported;

  void _setPushState(PushState next) {
    if (pushState == next) return;
    pushState = next;
    notifyListeners();
  }

  /// Asks for notification permission (Android 13+, iOS).
  Future<void> requestNotificationPermission() async {
    try {
      notificationPermission =
          await pushService.requestNotificationPermission();
    } catch (_) {
      notificationPermission = NotificationPermission.unsupported;
    }
    notifyListeners();
  }

  /// Result of the last test wake, as a short sentence without identifiers.
  String? pushTestResult;

  /// Sends the generic wake to this device's own registration (card I41).
  Future<void> sendTestPush() async {
    await _runScoped(Ops.pushTest, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) return;
      pushTestResult = null;
      try {
        final results = await client.sendTestPush(current.token);
        pushTestResult = results.every((result) => result == 'delivered')
            ? l10n.pushTestSent
            : results.contains('gone')
                ? l10n.pushTestGone
                : l10n.pushTestRejected;
        if (results.contains('gone')) {
          _pushSubscriptionId = null;
          pushProvider = null;
          _setPushState(PushState.registering);
          unawaited(_startPush());
        }
      } on ApiException catch (error) {
        if (error.statusCode == 401) rethrow;
        pushTestResult = error.serverCode == 'push_test_rate_limited'
            ? l10n.pushTestRateLimited
            : error.serverCode == 'no_push_subscription'
                ? l10n.pushTestNotRegistered
                : l10n.pushTestFailed;
      }
    });
  }

  Future<void> _handlePushEvent(PushEvent event) async {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    final ownerGeneration = _sessionGeneration;
    if (event is PushWakeEvent) {
      if (_isForeground) {
        await _observePendingWake();
        await _catchUpSyncEvents();
      }
    } else if (event is PushEndpointEvent && event.instance == _pushInstance) {
      try {
        final subscriptionId = event.provider == 'webpush'
            ? await client.registerWebPush(current.token,
                endpoint: event.endpoint,
                publicKey: event.publicKey,
                authSecret: event.authSecret)
            : await client.registerNativePush(current.token,
                provider: event.provider, deviceToken: event.endpoint);
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        _pushSubscriptionId = subscriptionId;
        pushProvider = event.provider;
        _setPushState(PushState.registered);
        notifyListeners();
      } catch (_) {
        // Re-registration on the next startup retries endpoint delivery.
        _setPushState(PushState.registrationFailed);
      }
    } else if (event is PushRegistrationFailedEvent &&
        event.instance == _pushInstance) {
      // A UnifiedPush failure means no distributor answered; anything else
      // is a provider refusal. Neither carries platform error text.
      _setPushState(event.provider == 'webpush'
          ? PushState.noDistributor
          : PushState.registrationFailed);
    } else if (event is PushUnregisteredEvent &&
        event.instance == _pushInstance) {
      final id = _pushSubscriptionId;
      _pushSubscriptionId = null;
      pushProvider = null;
      _setPushState(PushState.noDistributor);
      if (id != null) {
        try {
          await client.disablePush(current.token, id);
        } catch (_) {}
      }
    }
  }

  Future<void> _resumeForegroundSync() async {
    if (session == null || api == null) return;
    // Timers do not run while the app is suspended.
    await purgeExpiredMessages();
    await _observePendingWake();
    await _catchUpSyncEvents();
    await _flushMlsOutbox();
  }

  Future<void> _observePendingWake() async {
    if (!_isForeground) return;
    try {
      final generation = await pushService.pendingWakeGeneration();
      if (generation > _pendingWakeGeneration) {
        _pendingWakeGeneration = generation;
      }
    } catch (_) {
      // Push is optional; a later resume or wake event can observe it again.
    }
  }

  bool _sameSession(Session expected) {
    final active = session;
    return active != null &&
        active.baseUrl == expected.baseUrl &&
        active.token == expected.token &&
        active.accountId == expected.accountId &&
        active.deviceId == expected.deviceId;
  }

  bool _syncOwnerActive(Session expected, int generation) =>
      generation == _sessionGeneration && _sameSession(expected);

  bool _lifecycleGenerationActive(int generation) =>
      !_disposed && generation == _sessionGeneration;

  Future<void> _acknowledgePendingWake(Session owner,
      {int? ownerGeneration}) async {
    if (!_isForeground ||
        !_sameSession(owner) ||
        (ownerGeneration != null &&
            !_syncOwnerActive(owner, ownerGeneration)) ||
        _pendingWakeGeneration <= 0) {
      return;
    }
    final generation = _pendingWakeGeneration;
    try {
      final acknowledged = await pushService.acknowledgeWake(generation);
      final ownerStillActive = ownerGeneration == null
          ? _sameSession(owner)
          : _syncOwnerActive(owner, ownerGeneration);
      if (!ownerStillActive) return;
      if (acknowledged) {
        _pendingWakeGeneration = 0;
        final latest = await pushService.pendingWakeGeneration();
        final latestOwnerStillActive = ownerGeneration == null
            ? _sameSession(owner)
            : _syncOwnerActive(owner, ownerGeneration);
        if (!latestOwnerStillActive) return;
        if (latest > generation) {
          _pendingWakeGeneration = latest;
          _syncOwner?.markRequested();
        }
      } else {
        await _observePendingWake();
      }
    } catch (_) {
      // A failed platform acknowledgement leaves the durable marker intact.
    }
  }

  Future<void> choosePushDistributor() async {
    if (!pushConfigured) return;
    try {
      await pushService.pickDistributor();
    } catch (_) {
      // The platform picker is optional and may have no installed provider.
    }
  }

  Future<void> _stopPush(Session? current, ApiClient? client) async {
    final id = _pushSubscriptionId;
    final instance = _pushInstance;
    if (id != null && current != null && client != null) {
      try {
        await client.disablePush(current.token, id);
      } catch (_) {}
    }
    if (instance != null) {
      try {
        await pushService.unregister(instance);
      } catch (_) {}
    }
    await _pushSubscription?.cancel();
    _pushSubscription = null;
    _pushSubscriptionId = null;
    _pushInstance = null;
    pushConfigured = false;
    pushProvider = null;
    pushProviders = const <String>[];
    pushState = PushState.unknown;
    pushTestResult = null;
  }

  Future<void> _catchUpSyncEvents() async {
    if (!_isForeground) return;
    await _syncOwner?.request();
  }

  Future<void> _runOwnedCatchUp(Session current, int ownerGeneration) async {
    if (!_isForeground ||
        ownerGeneration != _sessionGeneration ||
        !_sameSession(current)) {
      return;
    }
    final client = api;
    if (client == null) {
      return;
    }
    // A stopped device stays stopped until the user picks a recovery choice
    // (I33): retrying the same event on every wake would be a poison loop.
    final stored = await localStore.loadSyncRecovery();
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    if (stored != null) {
      _enterSyncRecovery(stored);
      return;
    }
    try {
      var pageCursor = await localStore.loadSyncCursor();
      const pageSize = 200;
      while (true) {
        if (!_isForeground || !_syncOwnerActive(current, ownerGeneration)) {
          return;
        }
        final events = await client.syncEvents(
          current.token,
          after: pageCursor,
          limit: pageSize,
        );
        if (!_isForeground || !_syncOwnerActive(current, ownerGeneration)) {
          return;
        }
        if (events.isEmpty) break;
        var returnedCursor = pageCursor;
        for (final event in events) {
          if (event.id <= returnedCursor) {
            throw StateError('sync events are not strictly ordered');
          }
          returnedCursor = event.id;
        }
        final repair = _SyncPageRepair(
          client: client,
          token: current.token,
          events: events,
          processed: localStore.hasProcessedMlsMessage,
        );
        // Each event still commits on its own, but received messages reach
        // the UI in batches, together with their decrypted history. Reloading
        // a conversation's whole history after every message made a burst
        // quadratic (T49C).
        final received = <ReceivedMessageEnvelope>[];
        try {
          for (final event in events) {
            final committedCursor = await localStore.loadSyncCursor();
            if (event.id <= committedCursor) continue;
            if (!_syncOwnerActive(current, ownerGeneration)) return;

            if (_isCryptoSyncEvent(event.type)) {
              if (_mlsCrypto == null) {
                throw SyncEventFailure(SyncFailureKind.cryptoUnavailable,
                    eventId: event.id,
                    eventType: event.type,
                    conversationId: event.conversationId);
              }
              final envelope = await _processCryptoSyncEvent(event, repair);
              if (envelope != null) {
                received.add(envelope);
                if (received.length >= _receivedBatchLimit) {
                  await _publishReceived(received, current, ownerGeneration);
                }
                continue;
              }
            } else {
              // An unknown type outside the crypto namespaces only asks for
              // a refresh, so it is skipped and the cursor moves past it
              // (P5). Unknown crypto types still stop sync.
              if (!_knownProjectionEvent(event.type) &&
                  _failsClosedEvent(event.type)) {
                throw SyncEventFailure(SyncFailureKind.unsupportedEvent,
                    eventId: event.id,
                    eventType: event.type,
                    conversationId: event.conversationId);
              }
              await _refreshProjectionForSyncEvent(event);
              final expectedCursor = await localStore.loadSyncCursor();
              await localStore.commitSyncEvent(SyncEventCommit(
                eventKey: 'sync:${event.id}',
                conversationId: event.conversationId ?? '',
                expectedCursor: expectedCursor,
                cursor: event.id,
              ));
            }
            notifyListeners();
          }
        } catch (_) {
          // Messages committed before the failure still reach the UI; the
          // failure itself is what the caller handles.
          try {
            await _publishReceived(received, current, ownerGeneration);
          } catch (_) {}
          rethrow;
        }
        await _publishReceived(received, current, ownerGeneration);
        pageCursor = await localStore.loadSyncCursor();
        if (events.length < pageSize) break;
      }
      if (_mlsCrypto != null) {
        await _processMlsRevocations();
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        if (_mlsReconcileRequested || _mlsPendingSeen.isNotEmpty) {
          _mlsReconcileRequested = false;
          try {
            await _reconcileMlsMembership();
          } catch (err) {
            // Reconcile is retried after the next catch-up; it never blocks
            // sync.
            _mlsReconcileRequested = true;
            if (err is ApiException && err.statusCode == 401) rethrow;
          }
          if (!_syncOwnerActive(current, ownerGeneration)) return;
        }
      }
      await _acknowledgePendingWake(current, ownerGeneration: ownerGeneration);
      lastSyncedAt = DateTime.now();
      syncError = null;
      deviceRecoveryRequired = false;
      syncRecovery = null;
      _setConnectionStatus(ConnectionStatus.online);
      _cancelCatchUpRetry();
    } catch (err) {
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      if (err is ApiException && err.statusCode == 401) {
        await _clearLocalSession(
            preserveDeviceIdentity: true,
            preserveOutbox: true,
            drainSyncOwner: false);
        return;
      }
      final failure = _recoveryFailureFor(err);
      if (failure != null) {
        final recovery = SyncRecovery.fromFailure(failure, DateTime.now());
        await localStore.saveSyncRecovery(recovery);
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        _enterSyncRecovery(recovery);
        return;
      }
      // Background sync failure is a connection fact, not the outcome of
      // whatever the user last tapped. Writing it to the shared [error] made
      // unrelated screens report it as their own failure, so it goes to
      // [syncError] and the offline banner instead.
      syncError = describeError(err, l10n);
      _setConnectionStatus(ConnectionStatus.offline);
      notifyListeners();
      _scheduleCatchUpRetry(
          retryAfter: err is ApiException ? err.retryAfter : null);
    }
  }

  /// A catch-up that failed for a reason that passes (no connection, a
  /// rate limit, a server error) is tried again with backoff, so the device
  /// does not stay behind until the next socket event or wake. A rate limit
  /// names when its window resets; waiting exactly that long, plus a second
  /// for clock rounding, keeps a late backoff step (up to a minute) from
  /// missing the reset by a few seconds and doubling the wait.
  void _scheduleCatchUpRetry({Duration? retryAfter}) {
    if (_disposed) return;
    _catchUpRetryTimer?.cancel();
    final delay = retryAfter != null
        ? retryAfter + const Duration(seconds: 1)
        : Duration(seconds: min(60, 2 << min(_catchUpRetryAttempt, 5)));
    _catchUpRetryAttempt++;
    _catchUpRetryTimer = Timer(delay, () {
      _catchUpRetryTimer = null;
      unawaited(_catchUpSyncEvents());
    });
  }

  void _cancelCatchUpRetry() {
    _catchUpRetryTimer?.cancel();
    _catchUpRetryTimer = null;
    _catchUpRetryAttempt = 0;
  }

  /// The failure to record as a durable recovery, or null when [err] is a
  /// connection problem that sync simply retries later.
  SyncEventFailure? _recoveryFailureFor(Object err) {
    if (err is SyncEventFailure) {
      return err.kind == SyncFailureKind.transient ||
              err.kind == SyncFailureKind.auth
          ? null
          : err;
    }
    if (err is ApiException &&
        (err.serverCode == 'device_recovery_required' ||
            err.serverCode == 'full_resync_required')) {
      return const SyncEventFailure(SyncFailureKind.cursorExpired);
    }
    // Anything else happened outside one event's processing (a page or a
    // projection refresh failed) and is retried on the next wake. Event
    // processing failures arrive here already typed.
    return null;
  }

  void _enterSyncRecovery(SyncRecovery recovery) {
    syncRecovery = recovery;
    deviceRecoveryRequired = true;
    syncError = recovery.localizedMessage(l10n);
    _setConnectionStatus(ConnectionStatus.offline);
    notifyListeners();
  }

  /// Clears the recovery record and applies the stopped event once more. If
  /// the cause remains, the same record comes back; nothing is skipped.
  Future<void> retrySyncRecovery() async {
    final recovery = syncRecovery ?? await localStore.loadSyncRecovery();
    if (recovery == null ||
        !recovery.choices.contains(SyncRecoveryChoice.retry)) {
      return;
    }
    await localStore.saveSyncRecovery(null);
    syncRecovery = null;
    deviceRecoveryRequired = false;
    syncError = null;
    _setConnectionStatus(ConnectionStatus.connecting);
    notifyListeners();
    await _catchUpSyncEvents();
  }

  /// The destructive recovery: signs out and removes this device's identity,
  /// encryption state and local history, so it can be linked again from
  /// another device. The UI must get explicit confirmation first.
  Future<void> relinkAfterSyncRecovery({required bool confirmed}) async {
    if (!confirmed) {
      throw ArgumentError.value(confirmed, 'confirmed',
          'relinking deletes local history and needs confirmation');
    }
    await _run(() async {
      final current = session;
      final client = api;
      await _stopPush(current, client);
      await _clearLocalSession();
      if (current != null && client != null) {
        try {
          await client.logout(current.token);
        } catch (_) {
          // The local identity is already gone; the token expires normally.
        }
      }
    });
  }

  static bool _isTransientSyncError(Object err) {
    if (err is ApiException) {
      return err.statusCode == 408 ||
          err.statusCode == 429 ||
          err.statusCode >= 500;
    }
    // A failed local commit is storage trouble, not a bad message: the commit
    // rolled back with the ratchet, so a retry is safe (P1).
    if (err is DriftWrappedException) return true;
    return err is SqliteException ||
        err is FileSystemException ||
        err is SocketException ||
        err is TimeoutException ||
        err is HttpException ||
        err is HandshakeException;
  }

  bool _isCryptoSyncEvent(String type) =>
      type == 'mls.message.created' ||
      type.startsWith('message.envelope.') ||
      type == 'call.signaling' ||
      type == 'call.state';

  /// Unknown events in these namespaces may carry or gate ciphertext, so sync
  /// stops at them (I33, P5). Any other unknown type is skipped.
  static bool _failsClosedEvent(String type) =>
      type.startsWith('mls.') ||
      type.startsWith('message.') ||
      type.startsWith('call.');

  bool _knownProjectionEvent(String type) =>
      type.startsWith('device.') ||
      type.startsWith('conversation.') ||
      type.startsWith('membership.') ||
      type == 'retention.updated' ||
      type.startsWith('reaction.') ||
      type == 'read_receipt.updated' ||
      type == 'mls.revocation.pending' ||
      type == 'mls.revocation.completed';

  Future<void> _refreshProjectionForSyncEvent(SyncEvent event) async {
    final type = event.type;
    if (type.startsWith('device.') ||
        type.startsWith('membership.') ||
        type.startsWith('conversation.')) {
      _mlsReconcileRequested = true;
    }
    if (type.startsWith('device.')) {
      await _refreshDevices();
      await _refreshConversations(notify: false, persist: false);
      return;
    }
    if (type.startsWith('conversation.') ||
        type.startsWith('membership.') ||
        type == 'retention.updated') {
      await _refreshConversations(notify: false, persist: false);
      return;
    }
    if (type.startsWith('reaction.') || type == 'read_receipt.updated') {
      if (event.conversationId == selectedConversationId) {
        await refreshSelectedMessages(notify: false, persist: false);
        if (type == 'read_receipt.updated') {
          unawaited(refreshReceipts(event.conversationId!));
        }
      }
      return;
    }
    if (type == 'mls.revocation.pending' ||
        type == 'mls.revocation.completed') {
      return;
    }
    if (_failsClosedEvent(type)) {
      throw SyncEventFailure(SyncFailureKind.unsupportedEvent,
          eventId: event.id, eventType: type);
    }
  }

  String? _messageIdFromSyncEvent(SyncEvent event) {
    final payload = event.payload;
    if (payload is! Map) {
      return null;
    }
    final value = payload['message_id'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<ReceivedMessageEnvelope?> _processCryptoSyncEvent(
      SyncEvent event, _SyncPageRepair repair) async {
    final current = session;
    final client = api;
    final mls = _mlsCrypto;
    if (current == null || client == null || mls == null) return null;
    SyncEventFailure failure(SyncFailureKind kind) => SyncEventFailure(kind,
        eventId: event.id,
        eventType: event.type,
        conversationId: event.conversationId);
    switch (event.type) {
      case 'mls.message.created':
        // Control messages are never skipped: missing, malformed or
        // rejected ones stop sync at this event (I33).
        final id = _mlsMessageIdFromPayload(event.payload);
        if (id == null) throw failure(SyncFailureKind.mlsControlMalformed);
        final message = await repair.mlsMessage(event, id);
        if (message.id != id ||
            message.syncEventId != event.id ||
            (event.conversationId != null &&
                message.conversationId != event.conversationId)) {
          throw failure(SyncFailureKind.mlsControlMalformed);
        }
        try {
          await mls.processMlsMessage(message);
        } catch (err) {
          if (_isTransientSyncError(err)) rethrow;
          throw failure(err is FormatException
              ? SyncFailureKind.mlsControlMalformed
              : SyncFailureKind.mlsState);
        }
        if (message.kind == 'welcome' &&
            message.recipientDeviceId == current.deviceId) {
          await _replenishKeyPackage();
        }
        return null;
      case 'message.envelope.created':
      case 'message.envelope.edited':
      case 'message.envelope.deleted':
        final id = _messageIdFromSyncEvent(event);
        if (id == null) throw failure(SyncFailureKind.applicationMissing);
        final ReceivedMessageEnvelope? inline;
        try {
          inline = _envelopeFromSyncEvent(event);
        } catch (_) {
          throw failure(SyncFailureKind.applicationUndecryptable);
        }
        if (inline == null && event.type != 'message.envelope.created') {
          throw failure(SyncFailureKind.applicationMissing);
        }
        final ReceivedMessageEnvelope resolved;
        if (inline != null) {
          resolved = inline;
        } else {
          final fetched = await repair.envelope(event, id);
          if (fetched == null) {
            // The server proved the envelope expired (410).
            await _commitExpiredTombstone(event, id);
            return null;
          }
          resolved = fetched;
        }
        if (resolved.id != id) {
          throw failure(SyncFailureKind.applicationUndecryptable);
        }
        try {
          await mls.processApplicationMessage(resolved, event.id);
        } catch (err) {
          if (_isTransientSyncError(err)) rethrow;
          if (_provenExpired(resolved.expiresAt)) {
            await _commitExpiredTombstone(event, id);
            return null;
          }
          throw failure(SyncFailureKind.applicationUndecryptable);
        }
        return resolved;
      case 'call.signaling':
      case 'call.state':
        final payload = event.payload;
        if (payload is! Map) {
          throw failure(SyncFailureKind.applicationUndecryptable);
        }
        final CallSession call;
        try {
          call = CallSession.fromJson(Map<String, Object?>.from(payload));
        } catch (_) {
          throw failure(SyncFailureKind.applicationUndecryptable);
        }
        final Map<String, Object?>? signal;
        try {
          signal = await mls.processCallSignal(call, event.id);
        } catch (err) {
          if (_isTransientSyncError(err)) rethrow;
          if (_provenExpired(call.expiresAt)) {
            await _commitExpiredTombstone(event, call.id);
            return null;
          }
          throw failure(SyncFailureKind.applicationUndecryptable);
        }
        if (signal != null) _callSignals.add(IncomingCallSignal(call, signal));
        return null;
    }
    throw failure(SyncFailureKind.unsupportedEvent);
  }

  static String? _mlsMessageIdFromPayload(Object? payload) {
    if (payload is! Map) return null;
    final value = payload['mls_message_id'];
    return value is String && value.isNotEmpty ? value : null;
  }

  static bool _provenExpired(DateTime? expiresAt) =>
      expiresAt != null && !expiresAt.isAfter(DateTime.now().toUtc());

  /// Tombstone policy (I33): an application message or call signal that
  /// failed to apply may be passed over only when its own expiry proves it
  /// would be gone anyway. The tombstone moves the cursor past the event and
  /// stores nothing else: no text, no envelope. Control messages never get
  /// one.
  Future<void> _commitExpiredTombstone(SyncEvent event, String targetId) async {
    final cursor = await localStore.loadSyncCursor();
    await localStore.commitSyncEvent(SyncEventCommit(
      eventKey: 'expired:${event.id}:$targetId',
      conversationId: event.conversationId ?? '',
      expectedCursor: cursor,
      cursor: event.id,
    ));
  }

  ReceivedMessageEnvelope? _envelopeFromSyncEvent(SyncEvent event) {
    final payload = event.payload;
    if (payload is! Map) return null;
    final raw = payload['envelope'];
    if (raw is! Map) return null;
    return ReceivedMessageEnvelope.fromJson(Map<String, Object?>.from(raw));
  }

  /// Most received envelopes [_runOwnedCatchUp] holds back before showing
  /// them; the rest of a sync page is shown when the page ends.
  static const _receivedBatchLimit = 50;

  /// Shows [received] (already committed) with the decrypted history of
  /// their conversations in one notification, then empties the list. The
  /// history is read first, so no frame draws a decrypted message as
  /// ciphertext; if that read fails the list is kept for the caller's
  /// retry. Nothing is applied once another session owns sync.
  Future<void> _publishReceived(
    List<ReceivedMessageEnvelope> received,
    Session owner,
    int ownerGeneration,
  ) async {
    if (received.isEmpty) return;
    final histories = <String, ConversationHistory>{};
    for (final id in received.map((item) => item.conversationId).toSet()) {
      histories[id] = await _loadHistory(id);
    }
    if (_syncOwnerActive(owner, ownerGeneration)) {
      _mergeReceivedEnvelopes(received);
      _history.addAll(histories);
      notifyListeners();
      unawaited(_scheduleExpiryPurge());
      onMessagesPublished?.call(List<ReceivedMessageEnvelope>.of(received));
    }
    received.clear();
  }

  /// Merges [envelopes], in order, into the newest-first lists: a later
  /// envelope replaces any earlier one with its ID.
  void _mergeReceivedEnvelopes(List<ReceivedMessageEnvelope> envelopes) {
    final incoming = <String, Map<String, ReceivedMessageEnvelope>>{};
    final now = DateTime.now().toUtc();
    for (final envelope in envelopes) {
      // Already expired on arrival: never shown (W2).
      if (_envelopeExpired(envelope, now)) continue;
      (incoming[envelope.conversationId] ??=
          <String, ReceivedMessageEnvelope>{})[envelope.id] = envelope;
    }
    final merged = <String, List<ReceivedMessageEnvelope>>{};
    for (final entry in incoming.entries) {
      final existing = messagesByConversation[entry.key] ??
          const <ReceivedMessageEnvelope>[];
      merged[entry.key] = <ReceivedMessageEnvelope>[
        ...entry.value.values,
        ...existing.where((item) => !entry.value.containsKey(item.id)),
      ]..sort((left, right) {
          final byCreatedAt = right.createdAt.compareTo(left.createdAt);
          return byCreatedAt != 0 ? byCreatedAt : right.id.compareTo(left.id);
        });
    }
    messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
      ...messagesByConversation,
      ...merged,
    };
  }

  Future<void> _clearLocalSession({
    bool preserveDeviceIdentity = false,
    bool preserveOutbox = false,
    bool drainSyncOwner = true,
  }) async {
    _sessionGeneration++;
    _cancelDraftTimers();
    final previousOwner = _syncOwner;
    _syncOwner = null;
    previousOwner?.dispose();
    if (drainSyncOwner) {
      await previousOwner?.cancelAndDrain();
    }
    final previousLease = _syncLease;
    _syncLease = null;
    if (previousLease != null) {
      await localStore.releaseSyncLease(previousLease);
    }
    await _mlsCrypto?.dispose();
    final current = session;
    await _stopPush(current, api);
    final previousSubscription = _syncSubscription;
    _syncSubscription = null;
    await previousSubscription?.cancel();
    final previousSync = sync;
    sync = null;
    await previousSync?.dispose();
    if (preserveDeviceIdentity &&
        current != null &&
        current.deviceId != null &&
        current.deviceId!.isNotEmpty) {
      await localStore.saveSession(Session(
        baseUrl: current.baseUrl,
        token: '',
        accountId: current.accountId,
        deviceId: current.deviceId,
        username: current.username,
        deviceSecret: current.deviceSecret,
        role: current.role,
      ));
      await localStore.clearCachedState(preserveOutbox: preserveOutbox);
    } else {
      await localStore.clear();
    }
    session = null;
    api?.close();
    api = null;
    conversations = <Conversation>[];
    conversationsLoaded = false;
    communitiesLoaded = false;
    invitesLoaded = false;
    devicesLoaded = false;
    devices = <Device>[];
    messagesByConversation = <String, List<ReceivedMessageEnvelope>>{};
    _history.clear();
    composerDrafts.clear();
    receipts.clear();
    typing.clear();
    pendingOutbox = <MessageEnvelope>[];
    _outboxStates.clear();
    _outboxRecords.clear();
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _mlsOutboxRetryTimer?.cancel();
    _mlsOutboxRetryTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _cancelCatchUpRetry();
    _failedMlsConversations.clear();
    _mlsPendingSeen.clear();
    _mlsReconcileNow.clear();
    _mlsReconcileRequested = true;
    _manualRetryKey = null;
    _loadingMessageConversations.clear();
    _messageLoadErrors.clear();
    selectedConversationId = null;
    activeDeviceLink = null;
    pendingDeviceLinkClaim = null;
    communities = <Community>[];
    channelsByCommunity = <String, List<Channel>>{};
    invites = <Invite>[];
    membersByConversation = <String, List<ConversationMember>>{};
    blockedAccounts = <BlockedAccount>[];
    blocksLoaded = false;
    _mutes.clear();
    _muteTimer?.cancel();
    _muteTimer = null;
    _acceptedPeers = null;
    _acceptedGroups.clear();
    _declined.clear();
    _historyCursors.clear();
    _loadingOlder.clear();
    _busyOps.clear();
    _opErrors.clear();
    connectionStatus = ConnectionStatus.connecting;
    lastSyncedAt = null;
    syncError = null;
    _pendingWakeGeneration = 0;
    deviceRecoveryRequired = false;
    syncRecovery = null;
    lifecycle = SessionLifecycle.ready;
    recoveryMessage = null;
  }

  Future<void> _persistSnapshot() async {
    if (session == null) {
      return;
    }
    await localStore.saveProjection(conversations, messagesByConversation);
    unawaited(_scheduleExpiryPurge());
  }

  static bool _envelopeExpired(ReceivedMessageEnvelope envelope, DateTime now) {
    final at = envelope.expiresAt;
    return at != null && !at.isAfter(now);
  }

  /// Deletes what has expired from the encrypted database, then from the
  /// lists the screens read, and arms the timer for the next expiry (W2).
  Future<void> purgeExpiredMessages() async {
    if (session == null || _purgingExpired) return;
    _purgingExpired = true;
    final generation = _sessionGeneration;
    try {
      final touched = await localStore.purgeExpiredMessages();
      if (generation != _sessionGeneration || session == null) return;
      final now = DateTime.now().toUtc();
      var changed = touched.isNotEmpty;
      final next = <String, List<ReceivedMessageEnvelope>>{};
      for (final entry in messagesByConversation.entries) {
        final live = entry.value
            .where((envelope) => !_envelopeExpired(envelope, now))
            .toList(growable: false);
        if (live.length != entry.value.length) {
          changed = true;
          touched.add(entry.key);
        }
        next[entry.key] = live;
      }
      if (changed) {
        messagesByConversation = next;
        if (_mlsCrypto != null) {
          for (final id in touched) {
            if (_history.containsKey(id) || id == selectedConversationId) {
              _history[id] = await _loadHistory(id);
            }
          }
        }
        if (generation != _sessionGeneration) return;
        notifyListeners();
      }
    } catch (_) {
      // Retried on the next timer, resume or restart; never blocks the app.
    } finally {
      _purgingExpired = false;
    }
    await _scheduleExpiryPurge();
  }

  Future<void> _scheduleExpiryPurge() async {
    if (session == null || _disposed) return;
    final generation = _sessionGeneration;
    final DateTime? next;
    try {
      next = await localStore.nextMessageExpiry();
    } catch (_) {
      return;
    }
    if (generation != _sessionGeneration || _disposed) return;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (next == null) return;
    var delay = next.difference(DateTime.now().toUtc());
    if (delay < const Duration(milliseconds: 500)) {
      delay = const Duration(milliseconds: 500);
    }
    // Timers beyond a day are re-armed by resume and by the next write.
    if (delay > const Duration(days: 1)) delay = const Duration(days: 1);
    _expiryTimer = Timer(delay, () {
      _expiryTimer = null;
      unawaited(purgeExpiredMessages());
    });
  }

  Future<void> _flushOutbox() async {
    if (_flushingOutbox) {
      _flushOutboxRequested = true;
      return;
    }
    _flushingOutbox = true;
    try {
      do {
        _flushOutboxRequested = false;
        await _flushOutboxOnce();
      } while (_flushOutboxRequested && !_disposed);
    } finally {
      _flushingOutbox = false;
      _manualRetryKey = null;
      unawaited(_scheduleOutboxRetry());
    }
  }

  Future<void> _flushOutboxOnce() async {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    final ownerGeneration = _sessionGeneration;
    final records = await localStore.pendingEnvelopeRecords();
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    _setOutboxRecords(records);
    // An application message was encrypted in the epoch after any MLS
    // control message queued before it, so it waits until those are
    // delivered (I34); the MLS worker starts this flush when it finishes.
    final heldBack = _mlsCrypto == null
        ? const <String>{}
        : (await localStore.pendingMlsMessages())
            .map((message) => message.conversationId)
            .toSet();
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    final now = DateTime.now().toUtc();
    for (final record in records) {
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      final envelope = record.envelope;
      if (record.terminal) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.terminal;
        continue;
      }
      if (heldBack.contains(envelope.conversationId)) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.retrying;
        continue;
      }
      final manualRetry = _manualRetryKey == envelope.idempotencyKey;
      if (!manualRetry && (record.nextAttemptAt?.isAfter(now) ?? false)) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.retrying;
        continue;
      }
      _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.sending;
      notifyListeners();
      try {
        await client.sendEnvelope(current.token, envelope);
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        await _removeFromOutbox(envelope);
      } catch (err) {
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        await _recordOutboxFailure(envelope, err, record.attemptCount);
        if (err is ApiException && err.statusCode == 401) {
          await _clearLocalSession(
              preserveDeviceIdentity: true,
              preserveOutbox: true,
              drainSyncOwner: false);
          break;
        }
      }
    }
    notifyListeners();
  }

  Future<void> _recordOutboxFailure(
    MessageEnvelope envelope,
    Object error,
    int previousAttempts,
  ) async {
    final apiError = error is ApiException ? error : null;
    final auth = apiError?.statusCode == 401;
    final terminal = apiError != null &&
        <int>{400, 403, 404, 409, 413, 422, 507}.contains(apiError.statusCode);
    final retryable = (apiError != null &&
            <int>{408, 429, 500, 502, 503, 504}
                .contains(apiError.statusCode)) ||
        error is SocketException ||
        error is TimeoutException ||
        error is HttpException;
    final failureClass = auth
        ? 'auth'
        : terminal
            ? 'terminal:${apiError.statusCode}:${apiError.serverCode ?? 'rejected'}'
            : retryable
                ? 'retryable:${apiError?.statusCode ?? 'network'}'
                : 'failed';
    final exponent = min(previousAttempts, 8);
    final nextAttempt = retryable
        ? DateTime.now().toUtc().add(Duration(seconds: 1 << exponent))
        : null;
    await localStore.recordOutboxFailure(envelope.idempotencyKey,
        failureClass: failureClass,
        terminal: terminal,
        nextAttemptAt: nextAttempt);
    _outboxStates[envelope.idempotencyKey] = terminal
        ? OutboxDeliveryState.terminal
        : auth
            ? OutboxDeliveryState.failed
            : retryable
                ? OutboxDeliveryState.retrying
                : OutboxDeliveryState.failed;
    final updated = (await localStore.pendingEnvelopeRecords())
        .where(
            (item) => item.envelope.idempotencyKey == envelope.idempotencyKey)
        .firstOrNull;
    if (updated != null) {
      _outboxRecords[envelope.idempotencyKey] = updated;
    }
  }

  Future<void> _scheduleOutboxRetry() async {
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    if (_disposed || session == null || api == null) return;
    final records = await localStore.pendingEnvelopeRecords();
    // Held-back conversations wait for the MLS worker, which flushes when
    // it finishes; scheduling them here would spin.
    final heldBack = _mlsCrypto == null
        ? const <String>{}
        : (await localStore.pendingMlsMessages())
            .map((message) => message.conversationId)
            .toSet();
    final now = DateTime.now().toUtc();
    DateTime? earliest;
    for (final record in records) {
      final due = record.nextAttemptAt;
      if (record.terminal ||
          due == null ||
          heldBack.contains(record.envelope.conversationId)) {
        continue;
      }
      // A retry that fell due since the flush looked is scheduled at
      // once; skipping it would strand it until the next wake.
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    if (earliest == null || _disposed) return;
    final delay = earliest.difference(now);
    _outboxRetryTimer =
        Timer(delay < _minimumRetryDelay ? _minimumRetryDelay : delay, () {
      _outboxRetryTimer = null;
      unawaited(_flushOutbox());
    });
  }

  /// Delivers MLS control messages (I34). One worker runs at a time; a call
  /// while it runs asks for one more pass. It never throws, so callers may
  /// leave its future unawaited.
  Future<void> _flushMlsOutbox() async {
    if (_flushingMlsOutbox) {
      _flushMlsOutboxRequested = true;
      return;
    }
    _flushingMlsOutbox = true;
    try {
      do {
        _flushMlsOutboxRequested = false;
        try {
          await _flushMlsOutboxOnce();
        } catch (_) {
          // A local storage failure leaves every item queued; the retry
          // timer or the next wake tries again.
        }
      } while (_flushMlsOutboxRequested && !_disposed);
    } finally {
      _flushingMlsOutbox = false;
      unawaited(_scheduleMlsOutboxRetry());
      // Application messages held behind a control message may go now.
      unawaited(_flushOutbox());
    }
  }

  /// One pass over the MLS outbox. Messages of one conversation go strictly
  /// in order, and a message that is waiting or failed holds back every
  /// later one of its conversation, because an overtaking commit or Welcome
  /// would fork the group. Other conversations carry on.
  Future<void> _flushMlsOutboxOnce() async {
    final current = session;
    final client = api;
    if (current == null || client == null || _mlsCrypto == null) return;
    final ownerGeneration = _sessionGeneration;
    final messages = await localStore.pendingMlsMessages();
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    final byConversation = <String, List<PendingMlsMessage>>{};
    for (final message in messages) {
      byConversation
          .putIfAbsent(message.conversationId, () => <PendingMlsMessage>[])
          .add(message);
    }
    final failed = <String>{};
    final now = DateTime.now().toUtc();
    for (final entry in byConversation.entries) {
      for (final message in entry.value) {
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        if (message.terminal) {
          failed.add(entry.key);
          break;
        }
        if (message.nextAttemptAt?.isAfter(now) ?? false) break;
        final isBundle = message.kind == MlsCommitBundle.kind;
        try {
          if (isBundle) {
            await client.sendMlsCommitBundle(
              current.token,
              message.conversationId,
              idempotencyKey: message.idempotencyKey,
              bundle: MlsCommitBundle.decode(message.payload),
            );
          } else {
            await client.sendMlsMessage(
              current.token,
              message.conversationId,
              kind: message.kind,
              payload: message.payload,
              idempotencyKey: message.idempotencyKey,
              recipientDeviceId: message.recipientDeviceId,
              revocationDeviceId: message.revocationDeviceId,
            );
          }
        } catch (err) {
          if (!_syncOwnerActive(current, ownerGeneration)) return;
          if (err is ApiException && err.statusCode == 401) {
            await _clearLocalSession(
                preserveDeviceIdentity: true,
                preserveOutbox: true,
                drainSyncOwner: false);
            return;
          }
          if (isBundle && err is ApiException && _refusedBundle(err)) {
            // Another commit won this epoch, or the change is no longer
            // valid. The staged commit was never merged, so dropping it
            // leaves this device in step with the group (card I51). Catch
            // up, then reconcile again.
            await _mlsCrypto?.abandonCommitBundle(message);
            _mlsReconcileRequested = true;
            unawaited(_catchUpSyncEvents());
            break;
          }
          final terminal = await _recordMlsOutboxFailure(message, err);
          if (terminal) failed.add(entry.key);
          break;
        }
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        if (isBundle) {
          await _mlsCrypto?.completeCommitBundle(message);
        } else {
          await localStore.removePendingMlsMessage(message.idempotencyKey);
        }
      }
    }
    if (!_sameSetOf(failed, _failedMlsConversations)) {
      _failedMlsConversations
        ..clear()
        ..addAll(failed);
      notifyListeners();
    }
  }

  /// A commit bundle the server will never accept as sent: it is dropped
  /// and the change is worked out again from the current group.
  static bool _refusedBundle(ApiException err) =>
      err.statusCode == 409 ||
      err.statusCode == 403 ||
      err.statusCode == 400 ||
      err.statusCode == 422;

  /// Brings every group this device is in up to date with the server's
  /// membership (card I51): member devices not in the group are added and
  /// devices of accounts that left are removed, in one staged commit per
  /// group. Only the coordinator device acts at once; the others step in if
  /// a change is still pending a few minutes later.
  Future<void> _reconcileMlsMembership() async {
    final current = session;
    final client = api;
    final mls = _mlsCrypto;
    if (current == null || client == null || mls == null) return;
    final ownerGeneration = _sessionGeneration;
    final changes = await client.mlsPendingChanges(current.token);
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    final now = DateTime.now().toUtc();
    final stillPending = <String>{};
    var staged = false;
    for (final change in changes) {
      final key = _pendingChangeKey(change);
      stillPending.add(key);
      final firstSeen = _mlsPendingSeen.putIfAbsent(key, () => now);
      // The device that made the change commits it too, without waiting.
      final coordinator = change.coordinatorDeviceId == null ||
          change.coordinatorDeviceId == current.deviceId ||
          _mlsReconcileNow.contains(change.conversationId);
      if (!coordinator && now.difference(firstSeen) < _reconcileFallback) {
        continue;
      }
      if (await _hasPendingMlsWork(change.conversationId)) continue;
      final local = await mls.groupEpoch(change.conversationId);
      // Behind or ahead of the server means sync is not finished yet.
      if (local == null || local.pending || local.epoch != change.epoch) {
        continue;
      }
      final adds = change.add.isEmpty
          ? const <DeviceKeyPackage>[]
          : await client.claimDeviceKeyPackages(
              current.token,
              change.conversationId,
              change.add.map((item) => item.deviceId).toList(growable: false),
            );
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      if (adds.isEmpty && change.remove.isEmpty) continue;
      await mls.stageMembershipChange(change.conversationId,
          adds: adds, removes: change.remove);
      _mlsReconcileNow.remove(change.conversationId);
      staged = true;
    }
    _mlsPendingSeen.removeWhere((key, _) => !stillPending.contains(key));
    _mlsReconcileNow.removeWhere((conversationId) =>
        !changes.any((change) => change.conversationId == conversationId));
    if (staged) await _flushMlsOutbox();
  }

  static const _reconcileFallback = Duration(minutes: 3);

  /// A floor on retry timers, so an item a pass cannot send yet never
  /// turns the retry timer into a busy loop.
  static const _minimumRetryDelay = Duration(milliseconds: 100);

  static String _pendingChangeKey(MlsPendingChange change) => <String>[
        change.conversationId,
        '${change.epoch}',
        ...change.add.map((item) => '+${item.deviceId}'),
        ...change.remove.map((item) => '-${item.deviceId}'),
      ].join('|');

  /// Records one delivery failure and says whether it is terminal. Server
  /// rejections are terminal; connection problems and busy servers retry
  /// with bounded exponential backoff.
  Future<bool> _recordMlsOutboxFailure(
      PendingMlsMessage message, Object error) async {
    final apiError = error is ApiException ? error : null;
    final retryable = (apiError != null && _isTransientSyncError(apiError)) ||
        (apiError == null && _isTransientSyncError(error));
    final terminal = apiError != null && !retryable;
    final exponent = min(message.attemptCount, 8);
    await localStore.recordMlsOutboxFailure(
      message.idempotencyKey,
      failureClass: terminal
          ? 'terminal:${apiError.statusCode}:${apiError.serverCode ?? 'rejected'}'
          : 'retryable:${apiError?.statusCode ?? 'network'}',
      terminal: terminal,
      nextAttemptAt: terminal
          ? null
          : DateTime.now().toUtc().add(Duration(seconds: 1 << exponent)),
    );
    return terminal;
  }

  Future<void> _scheduleMlsOutboxRetry() async {
    _mlsOutboxRetryTimer?.cancel();
    _mlsOutboxRetryTimer = null;
    if (_disposed || session == null || api == null || _mlsCrypto == null) {
      return;
    }
    final List<PendingMlsMessage> messages;
    try {
      messages = await localStore.pendingMlsMessages();
    } catch (_) {
      return;
    }
    // Only the head of each conversation can be sent next; a conversation
    // with a terminal message stays paused. A head that fell due since the
    // worker looked is scheduled at once, or it would wait for the next
    // wake.
    final heads = <String, PendingMlsMessage>{};
    for (final message in messages) {
      heads.putIfAbsent(message.conversationId, () => message);
    }
    final now = DateTime.now().toUtc();
    DateTime? earliest;
    for (final head in heads.values) {
      final due = head.nextAttemptAt;
      if (head.terminal || due == null) continue;
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    if (earliest == null || _disposed) return;
    final delay = earliest.difference(now);
    _mlsOutboxRetryTimer =
        Timer(delay < _minimumRetryDelay ? _minimumRetryDelay : delay, () {
      _mlsOutboxRetryTimer = null;
      unawaited(_flushMlsOutbox());
    });
  }

  /// Conversations whose MLS control message the server rejected (I34).
  /// They stay paused, with the message kept, until the device recovers.
  bool mlsConversationFailed(String conversationId) =>
      _failedMlsConversations.contains(conversationId);

  static bool _sameSetOf(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  /// Creates the MLS group for a new conversation and sends each member's
  /// Welcome, so the composer works as soon as the conversation opens.
  Future<void> _setUpConversationGroup(String conversationId) async {
    final current = session;
    final client = api;
    final mls = _mlsCrypto;
    if (current == null || client == null || mls == null) return;
    final packages = await client.claimConversationKeyPackages(
        current.token, conversationId);
    await mls.initializeConversation(conversationId, packages);
    await _flushMlsOutbox();
  }

  /// Every Welcome consumes one of this device's published key packages.
  /// Publishing one back keeps the supply steady, so the device can keep
  /// being added to new conversations. A failure only delays the top-up to
  /// the next Welcome; the Welcome itself is already committed.
  Future<void> _replenishKeyPackage() async {
    final current = session;
    final client = api;
    final mls = _mlsCrypto;
    if (current == null || client == null || mls == null) return;
    try {
      final packages = await mls.createReplenishmentKeyPackages(count: 1);
      await client.publishDeviceKeyPackages(current.token, packages);
    } catch (_) {
      // Retried on the next Welcome.
    }
  }

  Future<void> _publishInitialMlsKeyPackages() async {
    final current = session;
    final client = api;
    final mls = _mlsCrypto;
    if (current == null || client == null || mls == null) return;
    final packages = await mls.createReplenishmentKeyPackages();
    await client.publishDeviceKeyPackages(current.token, packages);
  }

  Future<void> _processMlsRevocations() async {
    final current = session;
    final client = api;
    final mls = _mlsCrypto;
    if (current == null || client == null || mls == null) return;
    for (final revocation in await client.mlsRevocations(current.token)) {
      if (revocation.state == 'pending' &&
          revocation.coordinatorDeviceId == current.deviceId) {
        // Earlier MLS work for this group drains first (I34). In
        // particular, a revocation commit queued before a restart is still
        // "pending" on the server until it is delivered; making another one
        // would fork the group.
        if (await _hasPendingMlsWork(revocation.conversationId)) {
          await _flushMlsOutbox();
          if (await _hasPendingMlsWork(revocation.conversationId)) continue;
        }
        await mls.createRevocationCommit(revocation);
        await _flushMlsOutbox();
        continue;
      }
      final messageId = revocation.commitMessageId;
      if (revocation.state == 'commit_submitted' &&
          messageId != null &&
          await localStore.hasAppliedMlsControlMessage(messageId)) {
        await client.confirmMlsRevocation(
          current.token,
          revocation.conversationId,
          revocation.revokedDeviceId,
        );
      }
    }
  }

  Future<bool> _hasPendingMlsWork(String conversationId) async =>
      (await localStore.pendingMlsMessages())
          .any((message) => message.conversationId == conversationId);

  Future<void> _removeFromOutbox(MessageEnvelope envelope) async {
    await _removeFromOutboxByKey(envelope.idempotencyKey);
  }

  Future<void> _removeFromOutboxByKey(String idempotencyKey) async {
    await localStore.removePendingEnvelope(idempotencyKey);
    pendingOutbox = pendingOutbox
        .where((item) => item.idempotencyKey != idempotencyKey)
        .toList(growable: false);
    _outboxRecords.remove(idempotencyKey);
    _outboxStates.remove(idempotencyKey);
    notifyListeners();
    unawaited(_scheduleOutboxRetry());
  }

  void _replaceApi(String baseUrl) {
    // The UI validates too, but this is the one place every connection path
    // (setup, registration, sign-in, device link, restore) goes through.
    if (!config.transport.allows(baseUrl)) {
      throw StateError(l10n.errorServerNotAllowed(baseUrl));
    }
    api?.close();
    api = apiClientFactory(baseUrl);
  }

  /// Operation-scoped variant of [_run]. Tracks busy/error under [op] and
  /// leaves the global [busy]/[error] fields untouched, so an unrelated
  /// failure cannot disable this control (or vice versa). Returns true when
  /// the body completed without error.
  Future<bool> _runScoped(String op, Future<void> Function() body) async {
    var succeeded = false;
    await _enqueueSessionTransition(() async {
      _busyOps.add(op);
      _opErrors.remove(op);
      notifyListeners();
      try {
        await body();
        succeeded = true;
      } catch (err) {
        if (err is ApiException && err.statusCode == 401) {
          await _clearLocalSession(
              preserveDeviceIdentity: true, preserveOutbox: true);
        }
        _opErrors[op] = describeError(err, l10n);
      } finally {
        _busyOps.remove(op);
        notifyListeners();
      }
    });
    return succeeded;
  }

  Future<void> _run(Future<void> Function() body) async {
    await _enqueueSessionTransition(() async {
      busy = true;
      error = null;
      notifyListeners();
      try {
        await body();
      } catch (err) {
        // `invalid_credentials` rejects the password typed into a signed-in
        // prompt (reauthentication), not the session token: the user keeps
        // the session and can try again.
        if (err is ApiException &&
            err.statusCode == 401 &&
            err.serverCode != 'invalid_credentials') {
          await _clearLocalSession(
              preserveDeviceIdentity: true, preserveOutbox: true);
        }
        error = describeError(err, l10n);
      } finally {
        busy = false;
        notifyListeners();
      }
    });
  }

  Future<void> _enqueueSessionTransition(Future<void> Function() action) {
    final next = _sessionTransitionTail.then((_) => action());
    _sessionTransitionTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    _receiptsRefreshTimer?.cancel();
    typing.dispose();
    receipts.dispose();
    _sessionGeneration++;
    _syncOwner?.dispose();
    unawaited(_syncOwner?.cancelAndDrain());
    _syncOwner = null;
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _mlsOutboxRetryTimer?.cancel();
    _mlsOutboxRetryTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _muteTimer?.cancel();
    _muteTimer = null;
    _cancelDraftTimers();
    _cancelCatchUpRetry();
    unawaited(_syncSubscription?.cancel());
    unawaited(sync?.dispose());
    unawaited(_pushSubscription?.cancel());
    pushService.dispose();
    unawaited(_mlsCrypto?.dispose());
    unawaited(_callSignals.close());
    api?.close();
    super.dispose();
  }
}

DeviceLink _deviceLinkWithVerification(
    DeviceLink link, DeviceLinkVerification verification) {
  return DeviceLink(
    id: link.id,
    state: link.state,
    verificationCode: verification.sas,
    expiresAt: link.expiresAt,
    code: link.code,
    linkUri: link.linkUri,
    claimedDeviceName: link.claimedDeviceName,
    approvedDeviceId: link.approvedDeviceId,
    accountId: link.accountId,
    createdByDeviceId: link.createdByDeviceId,
    protocolVersion: link.protocolVersion,
    linkNonce: link.linkNonce,
    existingSigningKey: link.existingSigningKey,
    claimedDeviceId: link.claimedDeviceId,
    claimedSigningKey: link.claimedSigningKey,
    transcriptHash: verification.transcriptHash,
  );
}

DeviceLink _deviceLinkWithoutVerification(DeviceLink link) {
  return DeviceLink(
    id: link.id,
    state: link.state,
    verificationCode: '',
    expiresAt: link.expiresAt,
    code: link.code,
    linkUri: link.linkUri,
    claimedDeviceName: link.claimedDeviceName,
    approvedDeviceId: link.approvedDeviceId,
    accountId: link.accountId,
    createdByDeviceId: link.createdByDeviceId,
    protocolVersion: link.protocolVersion,
    linkNonce: link.linkNonce,
    existingSigningKey: link.existingSigningKey,
    claimedDeviceId: link.claimedDeviceId,
    claimedSigningKey: link.claimedSigningKey,
    transcriptHash: null,
  );
}

bool _constantTimeBytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

/// Fetches what one page of sync events needs in as few requests as
/// possible (I33): every MLS control message of the page comes from one
/// bounded list request, and each legacy envelope is fetched at most once.
class _SyncPageRepair {
  _SyncPageRepair({
    required this.client,
    required this.token,
    required this.events,
    required this.processed,
  });

  static const int _batchLimit = 200;
  static const int _maxBatchRequests = 3;

  final ApiClient client;
  final String token;
  final List<SyncEvent> events;
  final Future<bool> Function(String marker) processed;
  Future<Map<String, MlsMessage>>? _mlsBatch;
  final Map<String, Future<ReceivedMessageEnvelope?>> _envelopes =
      <String, Future<ReceivedMessageEnvelope?>>{};

  /// Requests made so far, for tests of the batching bound.
  int requests = 0;

  Future<MlsMessage> mlsMessage(SyncEvent event, String id) async {
    final batch = await (_mlsBatch ??= _loadMlsBatch());
    final found = batch[id];
    if (found != null) return found;
    return _fetchMlsMessage(event, id);
  }

  /// The envelope for a legacy event without an inline copy, or null when
  /// the server proves it expired.
  Future<ReceivedMessageEnvelope?> envelope(SyncEvent event, String id) =>
      _envelopes.putIfAbsent(id, () => _fetchEnvelope(event, id));

  Future<Map<String, MlsMessage>> _loadMlsBatch() async {
    final wanted = <String, int>{};
    for (final event in events) {
      if (event.type != 'mls.message.created') continue;
      final id = AppState._mlsMessageIdFromPayload(event.payload);
      if (id == null || await processed('mls:${event.id}:$id')) continue;
      wanted[id] = event.id;
    }
    final found = <String, MlsMessage>{};
    if (wanted.isEmpty) return found;
    final lastEventId = wanted.values.reduce(max);
    var after = wanted.values.reduce(min) - 1;
    try {
      for (var round = 0; round < _maxBatchRequests; round++) {
        requests++;
        final page =
            await client.mlsMessages(token, after: after, limit: _batchLimit);
        for (final message in page) {
          if (wanted[message.id] == message.syncEventId) {
            found[message.id] = message;
          }
        }
        if (found.length == wanted.length ||
            page.length < _batchLimit ||
            page.last.syncEventId >= lastEventId ||
            page.last.syncEventId <= after) {
          break;
        }
        after = page.last.syncEventId;
      }
    } catch (err) {
      if (AppState._isTransientSyncError(err) ||
          (err is ApiException && err.statusCode == 401)) {
        rethrow;
      }
      // Anything else falls back to one request per missing message, which
      // classifies the failure for the event that needs it.
    }
    return found;
  }

  Future<MlsMessage> _fetchMlsMessage(SyncEvent event, String id) async {
    requests++;
    try {
      return await client.mlsMessage(token, id);
    } catch (err) {
      throw _classifyFetch(err, event,
          missing: SyncFailureKind.mlsControlMissing,
          malformed: SyncFailureKind.mlsControlMalformed);
    }
  }

  Future<ReceivedMessageEnvelope?> _fetchEnvelope(
      SyncEvent event, String id) async {
    requests++;
    try {
      return await client.message(token, id);
    } catch (err) {
      if (err is ApiException &&
          err.statusCode == 410 &&
          err.serverCode == 'message_expired') {
        return null;
      }
      throw _classifyFetch(err, event,
          missing: SyncFailureKind.applicationMissing,
          malformed: SyncFailureKind.applicationUndecryptable);
    }
  }

  Object _classifyFetch(
    Object err,
    SyncEvent event, {
    required SyncFailureKind missing,
    required SyncFailureKind malformed,
  }) {
    if (AppState._isTransientSyncError(err) ||
        (err is ApiException && err.statusCode == 401)) {
      return err;
    }
    return SyncEventFailure(
      err is ApiException ? missing : malformed,
      eventId: event.id,
      eventType: event.type,
      conversationId: event.conversationId,
    );
  }
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }
}

/// A random 128-bit id in hex, for attachment actions and temporary files.
String _randomHexId() {
  final random = Random.secure();
  return List<String>.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
