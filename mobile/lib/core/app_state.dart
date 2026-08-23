import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/crypto_service.dart';
import '../push/push_service.dart';
import '../storage/local_store.dart';
import '../sync/sync_service.dart';
import 'api_client.dart';
import 'errors.dart';
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
class Ops {
  static const send = 'send';
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
  }) : pushService = pushService ?? DisabledMobilePushService();

  final ApiClientFactory apiClientFactory;
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
  Future<void> _sessionTransitionTail = Future<void>.value();
  Stream<IncomingCallSignal> get callSignals => _callSignals.stream;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool get connected => session != null;

  bool get _isForeground => _lifecycleState == AppLifecycleState.resumed;

  /// The UI forwards lifecycle changes here so background push remains a
  /// durable wake marker and the foreground sync owner is the only consumer.
  void handleAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
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
    if (Uri.parse(origin).scheme != 'https') {
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
    } catch (_) {
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
      lifecycle = SessionLifecycle.recoveryRequired;
      recoveryMessage =
          'This device could not restore its encrypted session. Retry or '
          'continue to sign in without clearing local data.';
      notifyListeners();
    }
  }

  void continueWithoutRestore() {
    if (lifecycle != SessionLifecycle.recoveryRequired) return;
    lifecycle = SessionLifecycle.ready;
    recoveryMessage = null;
    notifyListeners();
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
        deviceName: 'Mobile device',
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
      await _fetchMessages(conversationId);
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
      final mls = _mlsCrypto;
      if (mls != null) {
        final packages = await client.claimConversationKeyPackages(
          current.token,
          conversation.id,
        );
        await mls.initializeConversation(conversation.id, packages);
        await _flushMlsOutbox();
      }
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
        deviceName: 'Mobile device',
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
      await client.addConversationMember(
        current.token,
        conversationId,
        accountId,
        role: role,
      );
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
  Future<bool> sendMessageTo(String conversationId, String plaintext) {
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
      final encrypted = await cryptoService.encrypt(conversation.id, plaintext);
      await localStore.enqueueEnvelope(encrypted, draftText: plaintext);
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
        deviceName: 'Linked mobile device',
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
        unawaited(_flushOutbox());
      },
      onError: (_) {
        // A dropped socket alone is not proof the server is unreachable; the
        // catch-up attempt that follows decides online vs. offline.
        unawaited(_catchUpSyncEvents());
        unawaited(_flushOutbox());
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
      unawaited(_flushOutbox());
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
      if (config['enabled'] != true) {
        pushConfigured = false;
        return;
      }
      pushConfigured = true;
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
      await pushService.register(instance: _pushInstance!, vapid: vapid);
      notifyListeners();
    } catch (_) {
      // Push is optional; realtime and foreground catch-up remain available.
    }
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
        notifyListeners();
      } catch (_) {
        // Re-registration on the next startup retries endpoint delivery.
      }
    } else if (event is PushUnregisteredEvent &&
        event.instance == _pushInstance) {
      final id = _pushSubscriptionId;
      _pushSubscriptionId = null;
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
    await _flushOutbox();
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
          final committedCursor = await localStore.loadSyncCursor();
          if (event.id <= committedCursor) continue;
          if (!_syncOwnerActive(current, ownerGeneration)) return;

          if (_isCryptoSyncEvent(event.type)) {
            if (_mlsCrypto == null) {
              throw StateError(
                  'deviceRecoveryRequired: MLS crypto is unavailable');
            }
            final envelope = await _processCryptoSyncEvent(event);
            if (envelope != null) _mergeReceivedEnvelope(envelope);
          } else {
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
      }
      await _acknowledgePendingWake(current, ownerGeneration: ownerGeneration);
      lastSyncedAt = DateTime.now();
      syncError = null;
      deviceRecoveryRequired = false;
      _setConnectionStatus(ConnectionStatus.online);
    } catch (err) {
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      if (err is ApiException && err.statusCode == 401) {
        await _clearLocalSession(
            preserveDeviceIdentity: true,
            preserveOutbox: true,
            drainSyncOwner: false);
      } else if (err is ApiException &&
          err.serverCode == 'full_resync_required') {
        deviceRecoveryRequired = true;
        syncError =
            'This device needs sync recovery before messages can continue.';
        _setConnectionStatus(ConnectionStatus.offline);
        notifyListeners();
        return;
      } else if (err is StateError &&
          err.message.toString().startsWith('deviceRecoveryRequired:')) {
        deviceRecoveryRequired = true;
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

  bool _isCryptoSyncEvent(String type) =>
      type == 'mls.message.created' ||
      type.startsWith('message.envelope.') ||
      type == 'call.signaling' ||
      type == 'call.state';

  Future<void> _refreshProjectionForSyncEvent(SyncEvent event) async {
    final type = event.type;
    if (type.startsWith('device.')) {
      await refreshDevices();
      await _refreshConversations(notify: false, persist: false);
      return;
    }
    if (type.startsWith('conversation.') || type.startsWith('membership.')) {
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
    throw StateError('unsupported sync event type: $type');
  }

  String? _messageIdFromSyncEvent(SyncEvent event) {
    final payload = event.payload;
    if (payload is! Map) {
      return null;
    }
    final value = payload['message_id'];
    return value is String && value.isNotEmpty ? value : null;
  }

  String? _mlsMessageIdFromSyncEvent(SyncEvent event) {
    final payload = event.payload;
    if (payload is! Map) return null;
    final value = payload['mls_message_id'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<ReceivedMessageEnvelope?> _processCryptoSyncEvent(
      SyncEvent event) async {
    final current = session;
    final client = api;
    final mls = _mlsCrypto;
    if (current == null || client == null || mls == null) return null;
    switch (event.type) {
      case 'mls.message.created':
        final id = _mlsMessageIdFromSyncEvent(event);
        if (id == null)
          throw StateError('MLS sync event is missing its message');
        await mls.processMlsMessage(await client.mlsMessage(current.token, id));
        return null;
      case 'message.envelope.created':
      case 'message.envelope.edited':
      case 'message.envelope.deleted':
        final id = _messageIdFromSyncEvent(event);
        if (id == null)
          throw StateError('message sync event is missing its envelope');
        final envelope = _envelopeFromSyncEvent(event);
        if (envelope == null && event.type != 'message.envelope.created') {
          throw StateError('message sync event lacks an immutable envelope');
        }
        final resolved = envelope ?? await client.message(current.token, id);
        await mls.processApplicationMessage(resolved, event.id);
        return resolved;
      case 'call.signaling':
      case 'call.state':
        if (event.payload is! Map)
          throw StateError('call sync event is malformed');
        final call = CallSession.fromJson(
            Map<String, Object?>.from(event.payload as Map));
        final signal = await mls.processCallSignal(call, event.id);
        if (signal != null) _callSignals.add(IncomingCallSignal(call, signal));
        return null;
    }
    throw StateError('unsupported crypto sync event type: ${event.type}');
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
    pendingOutbox = <MessageEnvelope>[];
    _outboxStates.clear();
    _outboxRecords.clear();
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
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
    final now = DateTime.now().toUtc();
    for (final record in records) {
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      final envelope = record.envelope;
      if (record.terminal) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.terminal;
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
    final now = DateTime.now().toUtc();
    DateTime? earliest;
    for (final record in records) {
      final due = record.nextAttemptAt;
      if (record.terminal || due == null || !due.isAfter(now)) continue;
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    if (earliest == null) return;
    final delay = earliest.difference(now);
    _outboxRetryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _outboxRetryTimer = null;
      unawaited(_flushOutbox());
    });
  }

  Future<void> _flushMlsOutbox() async {
    final current = session;
    final client = api;
    if (current == null || client == null || _mlsCrypto == null) return;
    final ownerGeneration = _sessionGeneration;
    final messages = await localStore.pendingMlsMessages();
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    for (final message in messages) {
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      await client.sendMlsMessage(
        current.token,
        message.conversationId,
        kind: message.kind,
        payload: message.payload,
        idempotencyKey: message.idempotencyKey,
        recipientDeviceId: message.recipientDeviceId,
        revocationDeviceId: message.revocationDeviceId,
      );
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      await localStore.removePendingMlsMessage(message.idempotencyKey);
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
        await mls.createRevocationCommit(revocation);
        await _flushMlsOutbox();
        continue;
      }
      final messageId = revocation.commitMessageId;
      if (revocation.state == 'commit_submitted' &&
          messageId != null &&
          await localStore.hasProcessedMlsMessage(messageId)) {
        await client.confirmMlsRevocation(
          current.token,
          revocation.conversationId,
          revocation.revokedDeviceId,
        );
      }
    }
  }

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

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }
}
