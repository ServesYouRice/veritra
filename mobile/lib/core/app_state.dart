import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/app_payload.dart';
import '../crypto/backup_service.dart';
import '../crypto/mls_commit_bundle.dart';
import '../crypto/crypto_service.dart';
import '../push/push_service.dart';
import '../storage/local_store.dart';
import '../sync/sync_recovery.dart';
import '../sync/sync_service.dart';
import 'api_client.dart';
import 'client_config.dart';
import 'errors.dart';
import 'message_history.dart';
import '../storage/encrypted_database.dart' show LocalMessageKind;
import 'models.dart';

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

  String get message {
    switch (state) {
      case SetupProbeState.idle:
        return '';
      case SetupProbeState.probing:
        return 'Checking the server…';
      case SetupProbeState.reachable:
        final name = instanceName?.trim();
        return name == null || name.isEmpty
            ? 'Veritra server reached.'
            : 'Connected to $name.';
      case SetupProbeState.invalidOrigin:
        return 'Enter an HTTPS server origin, for example '
            'https://chat.example.org.';
      case SetupProbeState.insecureTransport:
        return 'Veritra requires HTTPS. Put a self-hosted server behind TLS '
            'with a trusted certificate or Caddy.';
      case SetupProbeState.dnsFailure:
        return 'That address could not be found. Check the hostname and try '
            'again.';
      case SetupProbeState.tlsFailure:
        return 'The server certificate was not accepted. Use a trusted '
            'certificate or configure Caddy TLS.';
      case SetupProbeState.timedOut:
        return 'The server took too long to respond. Check the address and '
            'connection.';
      case SetupProbeState.notVeritra:
        return 'That address does not look like a Veritra server.';
      case SetupProbeState.unavailable:
        return 'Could not reach the server. Check the address and your '
            'connection.';
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
  static const pushTest = 'push_test';
  static const backup = 'backup';
  static const restore = 'restore';
  static const members = 'members';
  static const blocks = 'blocks';
  static const mute = 'mute';
  static String conversation(String id) => 'conversation:$id';
}

class AppState extends ChangeNotifier {
  AppState({
    required this.apiClientFactory,
    required this.cryptoService,
    required this.localStore,
    required this.syncServiceFactory,
    MobilePushService? pushService,
    this.backupService,
    this.config = ClientConfig.production,
  }) : pushService = pushService ?? DisabledMobilePushService();

  /// Encrypted backup and restore (card I45). Null in builds without the
  /// MLS service, where there is nothing to back up.
  final BackupService? backupService;

  final ApiClientFactory apiClientFactory;
  final ClientConfig config;
  final CryptoService cryptoService;
  final LocalStore localStore;
  final SyncServiceFactory syncServiceFactory;
  final MobilePushService pushService;

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
  final Set<String> _mutedConversations = <String>{};

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

  bool isMuted(String conversationId) =>
      _mutedConversations.contains(conversationId);

  bool isBlocked(String accountId) =>
      blockedAccounts.any((block) => block.accountId == accountId);

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
    final messages = await localStore.loadMessages(conversationId);
    final reactions = await localStore.loadReactions(conversationId);
    _history[conversationId] = ConversationHistory(
      conversationId: conversationId,
      messages: messages,
      reactions: reactions,
    );
    notifyListeners();
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
      byKey[ConversationHistory.keyOf(
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
        idempotencyKey: local.key.substring(local.senderDeviceId.length + 1),
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
      return 'The server is out of storage for this account. Delete older '
          'attachments or ask the administrator for more space.';
    }
    return 'This encrypted message could not be sent. Copy it or discard it.';
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
      final cached = await localStore.loadSnapshot();
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      if (cached != null) {
        conversations = cached.conversations;
        messagesByConversation = cached.messagesByConversation;
        conversationsLoaded = true;
        notifyListeners();
      }
      try {
        await refreshConversations();
        await refreshDevices();
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
      lifecycle = SessionLifecycle.ready;
      notifyListeners();
    } catch (error) {
      // Keep the encrypted database and cursor intact. Recovery is explicit so
      // a keystore/database failure cannot look like an ordinary logout.
      await _mlsCrypto?.dispose();
      api?.close();
      session = null;
      api = null;
      sync?.dispose();
      sync = null;
      devices = <Device>[];
      conversationsLoaded = false;
      messagesByConversation = <String, List<ReceivedMessageEnvelope>>{};
      _history.clear();
      lifecycle = SessionLifecycle.recoveryRequired;
      localStoreFailure =
          error is LocalStoreUnavailableException ? error.kind : null;
      recoveryMessage = error is LocalStoreUnavailableException
          ? _localStoreFailureMessage(error.kind)
          : 'This device could not restore its encrypted session. Retry or '
              'continue to sign in without clearing local data.';
      notifyListeners();
    }
  }

  static String _localStoreFailureMessage(LocalStoreFailureKind kind) {
    switch (kind) {
      case LocalStoreFailureKind.profileLocked:
        return 'This profile is already open in another Veritra window. '
            'Close that window, then retry.';
      case LocalStoreFailureKind.keyUnavailable:
      case LocalStoreFailureKind.keyWriteFailed:
        return 'This device could not read its secure storage. Unlock the '
            'device and retry. Your messages are kept.';
      case LocalStoreFailureKind.keyMissing:
      case LocalStoreFailureKind.keyMalformed:
      case LocalStoreFailureKind.keyRejected:
        return 'The key that protects this device\'s messages is missing or '
            'does not match. Nothing has been deleted. You can retry, or '
            'reset this device and link it again.';
    }
  }

  /// Why the encrypted local database could not be opened (I39), or null.
  LocalStoreFailureKind? localStoreFailure;

  /// Signing in cannot work while the local database is unreadable, so the
  /// recovery screen offers it only for other restore failures.
  bool get canContinueWithoutRestore => localStoreFailure == null;

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
    if (lifecycle != SessionLifecycle.recoveryRequired ||
        localStoreFailure == null) {
      return;
    }
    await _enqueueSessionTransition(() async {
      busy = true;
      notifyListeners();
      try {
        await localStore.quarantineUnreadableDatabase(confirmed: true);
        localStoreFailure = null;
        recoveryMessage = null;
        lifecycle = SessionLifecycle.ready;
      } catch (err) {
        recoveryMessage = 'The reset did not finish. Nothing was deleted. '
            'Retry.';
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
      await refreshConversations();
      await refreshDevices();
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
        throw StateError(
            'Password login requires this device to be linked first.');
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
      await refreshConversations();
      await refreshDevices();
      _startSync();
    });
  }

  Future<void> refreshConversations() async {
    await _refreshConversations(notify: true);
  }

  Future<void> refreshDevices() async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    try {
      devices = await client.devices(current.token);
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
    conversationsLoaded = true;
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
      _messageLoadErrors[conversationId] = describeError(err);
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
      _messageLoadErrors[conversationId] = describeError(err);
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
      await refreshConversations();
      await refreshDevices();
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
      _mutedConversations.remove(conversationId);
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

  /// Best-effort read of the server's mute flag. Silent on failure: an
  /// unknown mute state must not block opening a conversation.
  Future<void> loadConversationMuted(String conversationId) async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    try {
      final muted =
          await client.conversationMuted(current.token, conversationId);
      _setMutedLocally(conversationId, muted);
    } catch (_) {
      // Leave the last known value; the toggle still reports its own errors.
    }
  }

  Future<bool> setConversationMuted(String conversationId, bool muted) {
    return _runScoped(Ops.mute, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      final applied = await client.setConversationMuted(
        current.token,
        conversationId,
        muted,
      );
      _setMutedLocally(conversationId, applied);
    });
  }

  void _setMutedLocally(String conversationId, bool muted) {
    final changed = muted
        ? _mutedConversations.add(conversationId)
        : _mutedConversations.remove(conversationId);
    if (changed) {
      notifyListeners();
    }
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
    return client.searchMetadata(current.token, query.trim());
  }

  /// Best-effort read receipt for the newest visible message. Failures are
  /// intentionally silent; receipts must never block reading.
  Future<void> markNewestMessageRead(String conversationId) async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    final messages = messagesByConversation[conversationId] ??
        const <ReceivedMessageEnvelope>[];
    if (messages.isEmpty) {
      return;
    }
    try {
      await client.markRead(current.token, conversationId, messages.first.id);
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

  Future<bool> _sendPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body,
  ) {
    return _runScoped(Ops.send, () async {
      final current = session;
      final client = api;
      final conversation =
          conversations.where((item) => item.id == conversationId).firstOrNull;
      if (current == null || client == null || conversation == null) {
        return;
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
        encrypted = await mls.encryptPayload(conversation.id, type, body);
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
      final refreshed = await client.deviceLink(current.token, link.id);
      var merged = DeviceLink(
        id: refreshed.id,
        state: refreshed.state,
        verificationCode: link.verificationCode,
        expiresAt: refreshed.expiresAt,
        code: link.code ?? refreshed.code,
        linkUri: link.linkUri ?? refreshed.linkUri,
        claimedDeviceName: refreshed.claimedDeviceName,
        approvedDeviceId: refreshed.approvedDeviceId,
        accountId: refreshed.accountId,
        createdByDeviceId: refreshed.createdByDeviceId,
        protocolVersion: refreshed.protocolVersion,
        linkNonce: refreshed.linkNonce,
        existingSigningKey: refreshed.existingSigningKey,
        claimedDeviceId: refreshed.claimedDeviceId,
        claimedSigningKey: refreshed.claimedSigningKey,
        transcriptHash: link.transcriptHash ?? refreshed.transcriptHash,
      );
      if (refreshed.state == 'claimed' &&
          refreshed.accountId != null &&
          refreshed.protocolVersion != null &&
          refreshed.linkNonce?.length == 32 &&
          refreshed.claimedDeviceId != null &&
          refreshed.claimedSigningKey?.length == 32) {
        final verification = await cryptoService.deriveDeviceLinkVerification(
          accountId: refreshed.accountId!,
          protocolVersion: refreshed.protocolVersion!,
          linkNonce: refreshed.linkNonce!,
          peerDeviceId: refreshed.claimedDeviceId!,
          peerSigningKey: refreshed.claimedSigningKey!,
          localIsExistingDevice: true,
        );
        if (refreshed.transcriptHash != null &&
            !_constantTimeBytesEqual(
                verification.transcriptHash, refreshed.transcriptHash!)) {
          throw StateError('Device-link transcript was substituted');
        }
        merged = _deviceLinkWithVerification(merged, verification);
      }
      activeDeviceLink = merged;
    });
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
      await refreshConversations();
      await refreshDevices();
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
      await refreshDevices();
    });
  }

  Future<bool> reauthenticate(String password) async {
    var succeeded = false;
    await _run(() async {
      final current = session;
      final client = api;
      final deviceSecret = current?.deviceSecret;
      if (current == null || client == null || deviceSecret == null) {
        throw StateError('This device must be linked again.');
      }
      await client.reauthenticate(current.token, password, deviceSecret);
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
        await refreshDevices();
      }
    });
  }

  Future<ConversationSafetyNumber> conversationSafetyNumber(
      String conversationId) async {
    final mls = _mlsCrypto;
    if (mls == null) throw StateError('production MLS is unavailable');
    return mls.conversationSafetyNumber(conversationId);
  }

  Future<void> markPeerVerified(
      String conversationId, String peerAccountId) async {
    final safety = await conversationSafetyNumber(conversationId);
    await localStore.savePeerVerification(
        conversationId, peerAccountId, safety.transcriptHash);
  }

  Future<PeerVerificationStatus> peerVerificationStatus(
      String conversationId, String peerAccountId) async {
    final saved =
        await localStore.loadPeerVerification(conversationId, peerAccountId);
    if (saved == null) return PeerVerificationStatus.unverified;
    final current = await conversationSafetyNumber(conversationId);
    return _constantTimeBytesEqual(saved, current.transcriptHash)
        ? PeerVerificationStatus.verified
        : PeerVerificationStatus.changed;
  }

  void selectConversation(String id) {
    selectedConversationId = id;
    notifyListeners();
    unawaited(loadMessages(id));
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
    sync?.dispose();
    sync = syncServiceFactory(current.baseUrl, current.token);
    _setConnectionStatus(ConnectionStatus.connecting);
    _syncSubscription = sync!.events.listen(
      (_) {
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
            ? 'Test sent. A notification should arrive within a minute.'
            : results.contains('gone')
                ? 'The push provider no longer accepts this device. '
                    'Registering again.'
                : 'The push provider did not accept the test. Try again '
                    'later.';
        if (results.contains('gone')) {
          _pushSubscriptionId = null;
          pushProvider = null;
          _setPushState(PushState.registering);
          unawaited(_startPush());
        }
      } on ApiException catch (error) {
        if (error.statusCode == 401) rethrow;
        pushTestResult = error.serverCode == 'push_test_rate_limited'
            ? 'Wait a minute before sending another test.'
            : error.serverCode == 'no_push_subscription'
                ? 'This device is not registered for push yet.'
                : 'The test could not be sent.';
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
              _mergeReceivedEnvelope(envelope);
              await refreshHistory(envelope.conversationId);
            }
          } else {
            if (!_knownProjectionEvent(event.type)) {
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
      syncError = describeError(err);
      _setConnectionStatus(ConnectionStatus.offline);
      notifyListeners();
    }
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
    syncError = recovery.message;
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
    return err is SocketException ||
        err is TimeoutException ||
        err is HttpException ||
        err is HandshakeException;
  }

  bool _isCryptoSyncEvent(String type) =>
      type == 'mls.message.created' ||
      type.startsWith('message.envelope.') ||
      type == 'call.signaling' ||
      type == 'call.state';

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
      await refreshDevices();
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
      }
      return;
    }
    if (type == 'mls.revocation.pending' ||
        type == 'mls.revocation.completed') {
      return;
    }
    throw SyncEventFailure(SyncFailureKind.unsupportedEvent,
        eventId: event.id, eventType: type);
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

  void _mergeReceivedEnvelope(ReceivedMessageEnvelope envelope) {
    final existing = messagesByConversation[envelope.conversationId] ??
        const <ReceivedMessageEnvelope>[];
    final updated = <ReceivedMessageEnvelope>[
      envelope,
      ...existing.where((item) => item.id != envelope.id),
    ]..sort((left, right) {
        final byCreatedAt = right.createdAt.compareTo(left.createdAt);
        return byCreatedAt != 0 ? byCreatedAt : right.id.compareTo(left.id);
      });
    messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
      ...messagesByConversation,
      envelope.conversationId: updated,
    };
  }

  Future<void> _clearLocalSession({
    bool preserveDeviceIdentity = false,
    bool preserveOutbox = false,
    bool drainSyncOwner = true,
  }) async {
    _sessionGeneration++;
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
    sync?.dispose();
    sync = null;
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
    pendingOutbox = <MessageEnvelope>[];
    _outboxStates.clear();
    _outboxRecords.clear();
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _mlsOutboxRetryTimer?.cancel();
    _mlsOutboxRetryTimer = null;
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
    _mutedConversations.clear();
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
      throw StateError('This build does not allow the server address '
          '$baseUrl. Use an https:// server origin.');
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
        _opErrors[op] = describeError(err);
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
        if (err is ApiException && err.statusCode == 401) {
          await _clearLocalSession(
              preserveDeviceIdentity: true, preserveOutbox: true);
        }
        error = describeError(err);
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
    _sessionGeneration++;
    _syncOwner?.dispose();
    unawaited(_syncOwner?.cancelAndDrain());
    _syncOwner = null;
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _mlsOutboxRetryTimer?.cancel();
    _mlsOutboxRetryTimer = null;
    unawaited(_syncSubscription?.cancel());
    sync?.dispose();
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
