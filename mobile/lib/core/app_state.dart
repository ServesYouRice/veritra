import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

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

enum PeerVerificationStatus { unverified, verified, changed }

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
  bool _catchingUpSync = false;
  bool _catchUpRequested = false;
  int _lastSyncEventId = 0;

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

  final Set<String> _busyOps = <String>{};
  final Map<String, String> _opErrors = <String, String>{};
  final StreamController<IncomingCallSignal> _callSignals =
      StreamController<IncomingCallSignal>.broadcast();
  bool _disposed = false;
  Stream<IncomingCallSignal> get callSignals => _callSignals.stream;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool get connected => session != null;

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

  /// Best-effort probe of the instance's setup state so the connect screen
  /// can steer users to the right mode. Returns null when the instance is
  /// unreachable or answers unexpectedly; never sets [error] or [busy].
  Future<bool?> checkSetupRequired(String baseUrl) async {
    final client = apiClientFactory(baseUrl);
    try {
      final status = await client.setupStatus();
      final required = status['setup_required'];
      return required is bool ? required : null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Best-effort hydration of a previously-stored session on cold start.
  /// Failures are swallowed: a stale or unreadable session simply lands the
  /// user on the connect screen rather than crashing the app.
  Future<void> tryRestoreSession() async {
    try {
      final restored = await localStore.loadSession();
      if (restored == null) {
        return;
      }
      if (restored.token.isEmpty) {
        return;
      }
      session = restored;
      _replaceApi(restored.baseUrl);
      await _mlsCrypto?.activateSession(restored);
      pendingOutbox = await localStore.pendingEnvelopes();
      for (final envelope in pendingOutbox) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.failed;
      }
      _lastSyncEventId = await localStore.loadSyncCursor();
      final cached = await localStore.loadSnapshot();
      if (cached != null) {
        conversations = cached.conversations;
        messagesByConversation = cached.messagesByConversation;
        _lastSyncEventId = cached.cursor;
        conversationsLoaded = true;
        notifyListeners();
      }
      try {
        await refreshConversations();
        await refreshDevices();
      } on ApiException catch (err) {
        if (err.statusCode == 401) {
          await _clearLocalSession(preserveDeviceIdentity: true);
          return;
        }
        // Keep the encrypted cache available while offline.
      } catch (_) {
        // Keep the encrypted cache available while offline.
      }
      _startSync();
      notifyListeners();
    } catch (_) {
      // Runtime state falls back to the connect screen; the cached device ID
      // stays available for password login on an already-linked device.
      session = null;
      api = null;
      devices = <Device>[];
      conversationsLoaded = false;
      messagesByConversation = <String, List<ReceivedMessageEnvelope>>{};
      _lastSyncEventId = 0;
      await localStore.saveSyncCursor(0);
    }
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
      _lastSyncEventId = 0;
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
      _lastSyncEventId = 0;
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

  Future<void> _refreshConversations({required bool notify}) async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    conversations = await client.conversations(current.token);
    conversationsLoaded = true;
    await _persistSnapshot();
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> refreshSelectedMessages({bool notify = true}) async {
    final conversationId = selectedConversationId;
    if (conversationId == null) {
      return;
    }
    await _fetchMessages(conversationId);
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _fetchMessages(String conversationId) async {
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
    await _persistSnapshot();
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
      _lastSyncEventId = 0;
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
      final encrypted = await cryptoService.encrypt(conversation.id, plaintext);
      await localStore.enqueueEnvelope(encrypted);
      pendingOutbox = <MessageEnvelope>[...pendingOutbox, encrypted];
      _outboxStates[encrypted.idempotencyKey] = OutboxDeliveryState.sending;
      notifyListeners();
      try {
        await client.sendEnvelope(current.token, encrypted);
        await _removeFromOutbox(encrypted);
      } catch (err) {
        await _recordOutboxFailure(encrypted, err, 0);
        notifyListeners();
        rethrow;
      }
      await _fetchMessages(conversationId);
    });
  }

  Future<void> retryEnvelope(String idempotencyKey) async {
    await _runScoped(Ops.send, () async {
      final current = session;
      final client = api;
      final envelope = pendingOutbox
          .where((item) => item.idempotencyKey == idempotencyKey)
          .firstOrNull;
      if (current == null || client == null || envelope == null) {
        return;
      }
      _outboxStates[idempotencyKey] = OutboxDeliveryState.sending;
      notifyListeners();
      try {
        await client.sendEnvelope(current.token, envelope);
        await _removeFromOutbox(envelope);
        await _fetchMessages(envelope.conversationId);
      } catch (err) {
        final record = (await localStore.pendingEnvelopeRecords())
            .where((item) => item.envelope.idempotencyKey == idempotencyKey)
            .firstOrNull;
        await _recordOutboxFailure(envelope, err, record?.attemptCount ?? 0);
        notifyListeners();
        rethrow;
      }
    });
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
      _lastSyncEventId = 0;
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

  void _startSync() {
    final current = session;
    if (current == null) {
      return;
    }
    unawaited(_syncSubscription?.cancel());
    sync?.dispose();
    sync = syncServiceFactory(current.baseUrl, current.token);
    _setConnectionStatus(ConnectionStatus.connecting);
    _syncSubscription = sync!.events.listen(
      (_) => unawaited(_catchUpSyncEvents()),
      onError: (_) {
        // A dropped socket alone is not proof the server is unreachable; the
        // catch-up attempt that follows decides online vs. offline.
        unawaited(_catchUpSyncEvents());
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
  }

  Future<void> _startPush() async {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    try {
      final config = await client.pushConfig(current.token);
      final vapid = config['vapid_public_key'] as String? ?? '';
      if (config['enabled'] != true) {
        pushConfigured = false;
        return;
      }
      pushConfigured = true;
      _pushInstance = '${current.accountId}:${current.deviceId}';
      await _pushSubscription?.cancel();
      _pushSubscription = pushService.events.listen(_handlePushEvent);
      if (await pushService.takePendingWake()) {
        unawaited(_catchUpSyncEvents());
      }
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
    if (event is PushWakeEvent) {
      await _catchUpSyncEvents();
    } else if (event is PushEndpointEvent && event.instance == _pushInstance) {
      try {
        _pushSubscriptionId = event.provider == 'webpush'
            ? await client.registerWebPush(current.token,
                endpoint: event.endpoint,
                publicKey: event.publicKey,
                authSecret: event.authSecret)
            : await client.registerNativePush(current.token,
                provider: event.provider, deviceToken: event.endpoint);
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
    if (_catchingUpSync) {
      _catchUpRequested = true;
      return;
    }
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    _catchingUpSync = true;
    try {
      do {
        _catchUpRequested = false;
        var pageCursor = _lastSyncEventId;
        var refreshConversationsNeeded = false;
        var refreshSelectedMessagesNeeded = false;
        var refreshDevicesNeeded = false;
        final messageRepairIds = <String>{};
        final cryptoEvents = <SyncEvent>[];
        final selectedId = selectedConversationId;
        while (true) {
          const pageSize = 200;
          final events = await client.syncEvents(
            current.token,
            after: pageCursor,
            limit: pageSize,
          );
          if (events.isEmpty) {
            break;
          }
          for (final event in events) {
            if (event.id > pageCursor) {
              pageCursor = event.id;
            }
            if (event.conversationId != null) {
              if (event.type == 'mls.message.created' ||
                  event.type == 'message.envelope.created' ||
                  event.type.startsWith('call.')) {
                cryptoEvents.add(event);
              }
              refreshConversationsNeeded = true;
              if (event.type.startsWith('message.envelope.')) {
                final messageId = _messageIdFromSyncEvent(event);
                if (messageId != null) {
                  messageRepairIds.add(messageId);
                } else if (event.conversationId == selectedId) {
                  refreshSelectedMessagesNeeded = true;
                }
              } else if (event.conversationId == selectedId &&
                  !event.type.startsWith('reaction.') &&
                  event.type != 'read_receipt.updated') {
                refreshSelectedMessagesNeeded = true;
              }
            } else if (event.type.startsWith('device.')) {
              refreshDevicesNeeded = true;
              refreshConversationsNeeded = true;
            } else if (event.type.startsWith('conversation.')) {
              refreshConversationsNeeded = true;
            }
          }
          if (events.length < pageSize) {
            break;
          }
        }
        if (refreshDevicesNeeded) {
          await refreshDevices();
        }
        if (refreshConversationsNeeded) {
          await _refreshConversations(notify: false);
        }
        for (final messageId in messageRepairIds) {
          await _repairMessage(messageId);
        }
        if (refreshSelectedMessagesNeeded) {
          await refreshSelectedMessages(notify: false);
          await markNewestMessageRead(selectedId!);
        }
        if (_mlsCrypto != null) {
          for (final event in cryptoEvents) {
            await _processCryptoSyncEvent(event);
            _lastSyncEventId = await localStore.loadSyncCursor();
          }
          await _processMlsRevocations();
        }
        if (pageCursor > _lastSyncEventId) {
          await localStore.saveSnapshot(
            conversations,
            messagesByConversation,
            pageCursor,
          );
          _lastSyncEventId = pageCursor;
          notifyListeners();
        }
      } while (_catchUpRequested);
      lastSyncedAt = DateTime.now();
      syncError = null;
      _setConnectionStatus(ConnectionStatus.online);
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) {
        await _clearLocalSession(preserveDeviceIdentity: true);
      } else if (err is ApiException &&
          err.serverCode == 'full_resync_required' &&
          _mlsCrypto == null) {
        await _boundedFullResync();
        final latest = err.intField('latest_event_id') ?? 0;
        await localStore.saveSyncCursor(latest);
        _lastSyncEventId = latest;
        await _persistSnapshot();
        error = null;
        lastSyncedAt = DateTime.now();
        _setConnectionStatus(ConnectionStatus.online);
        notifyListeners();
        return;
      }
      // Background sync failure is a connection fact, not the outcome of
      // whatever the user last tapped. Writing it to the shared [error] made
      // unrelated screens report it as their own failure, so it goes to
      // [syncError] and the offline banner instead.
      syncError = describeError(err);
      _setConnectionStatus(ConnectionStatus.offline);
      notifyListeners();
    } finally {
      _catchingUpSync = false;
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

  String? _mlsMessageIdFromSyncEvent(SyncEvent event) {
    final payload = event.payload;
    if (payload is! Map) return null;
    final value = payload['mls_message_id'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<void> _processCryptoSyncEvent(SyncEvent event) async {
    final current = session;
    final client = api;
    final mls = _mlsCrypto;
    if (current == null || client == null || mls == null) return;
    switch (event.type) {
      case 'mls.message.created':
        final id = _mlsMessageIdFromSyncEvent(event);
        if (id == null)
          throw StateError('MLS sync event is missing its message');
        await mls.processMlsMessage(await client.mlsMessage(current.token, id));
        break;
      case 'message.envelope.created':
        final id = _messageIdFromSyncEvent(event);
        if (id == null)
          throw StateError('message sync event is missing its envelope');
        final envelope = await client.message(current.token, id);
        await mls.processApplicationMessage(envelope, event.id);
        break;
      case 'call.signaling':
      case 'call.state':
        if (event.payload is! Map)
          throw StateError('call sync event is malformed');
        final call = CallSession.fromJson(
            Map<String, Object?>.from(event.payload as Map));
        final signal = await mls.processCallSignal(call, event.id);
        if (signal != null) _callSignals.add(IncomingCallSignal(call, signal));
        break;
    }
  }

  Future<void> _repairMessage(String messageId) async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    try {
      final repaired = await client.message(current.token, messageId);
      final existing = messagesByConversation[repaired.conversationId] ??
          const <ReceivedMessageEnvelope>[];
      final updated = <ReceivedMessageEnvelope>[
        repaired,
        ...existing.where((message) => message.id != repaired.id),
      ]..sort((left, right) {
          final byCreatedAt = right.createdAt.compareTo(left.createdAt);
          return byCreatedAt != 0 ? byCreatedAt : right.id.compareTo(left.id);
        });
      messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
        ...messagesByConversation,
        repaired.conversationId: updated,
      };
    } on ApiException catch (err) {
      if (err.statusCode != 404) {
        rethrow;
      }
      messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
        for (final entry in messagesByConversation.entries)
          entry.key: entry.value
              .where((message) => message.id != messageId)
              .toList(growable: false),
      };
    }
  }

  Future<void> _boundedFullResync() async {
    await _refreshConversations(notify: false);
    final retained = <String>{
      if (selectedConversationId != null) selectedConversationId!,
      ...messagesByConversation.keys,
    };
    final available = conversations.map((item) => item.id).toSet();
    messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
      for (final id in retained.where(available.contains).take(100))
        id: messagesByConversation[id] ?? const <ReceivedMessageEnvelope>[],
    };
    for (final id in messagesByConversation.keys.toList(growable: false)) {
      await _fetchMessages(id);
    }
  }

  Future<void> _clearLocalSession({bool preserveDeviceIdentity = false}) async {
    final current = session;
    await _stopPush(current, api);
    unawaited(_syncSubscription?.cancel());
    _syncSubscription = null;
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
      await localStore.clearCachedState();
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
    _lastSyncEventId = 0;
  }

  Future<void> _persistSnapshot() async {
    if (session == null) {
      return;
    }
    await localStore.saveSnapshot(
      conversations,
      messagesByConversation,
      _lastSyncEventId,
    );
  }

  Future<void> _flushOutbox() async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    final records = await localStore.pendingEnvelopeRecords();
    pendingOutbox =
        records.map((item) => item.envelope).toList(growable: false);
    final now = DateTime.now().toUtc();
    for (final record in records) {
      final envelope = record.envelope;
      if (record.terminal) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.terminal;
        continue;
      }
      if (record.nextAttemptAt?.isAfter(now) ?? false) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.retrying;
        continue;
      }
      _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.sending;
      notifyListeners();
      try {
        await client.sendEnvelope(current.token, envelope);
        await _removeFromOutbox(envelope);
      } catch (err) {
        await _recordOutboxFailure(envelope, err, record.attemptCount);
        if (err is ApiException && err.statusCode == 401) {
          await _clearLocalSession(preserveDeviceIdentity: true);
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
    final auth = error is ApiException && error.statusCode == 401;
    final terminal = error is ApiException &&
        <int>{400, 403, 404, 409, 413, 422}.contains(error.statusCode);
    final failureClass = auth
        ? 'auth'
        : terminal
            ? 'terminal'
            : 'retryable';
    final exponent = min(previousAttempts, 8);
    final nextAttempt = auth || terminal
        ? null
        : DateTime.now().toUtc().add(Duration(seconds: 1 << exponent));
    await localStore.recordOutboxFailure(envelope.idempotencyKey,
        failureClass: failureClass,
        terminal: terminal,
        nextAttemptAt: nextAttempt);
    _outboxStates[envelope.idempotencyKey] = terminal
        ? OutboxDeliveryState.terminal
        : auth
            ? OutboxDeliveryState.failed
            : OutboxDeliveryState.retrying;
  }

  Future<void> _flushMlsOutbox() async {
    final current = session;
    final client = api;
    if (current == null || client == null || _mlsCrypto == null) return;
    for (final message in await localStore.pendingMlsMessages()) {
      await client.sendMlsMessage(
        current.token,
        message.conversationId,
        kind: message.kind,
        payload: message.payload,
        idempotencyKey: message.idempotencyKey,
        recipientDeviceId: message.recipientDeviceId,
        revocationDeviceId: message.revocationDeviceId,
      );
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
    await localStore.removePendingEnvelope(envelope.idempotencyKey);
    pendingOutbox = pendingOutbox
        .where((item) => item.idempotencyKey != envelope.idempotencyKey)
        .toList(growable: false);
    _outboxStates.remove(envelope.idempotencyKey);
    notifyListeners();
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
    _busyOps.add(op);
    _opErrors.remove(op);
    notifyListeners();
    try {
      await body();
      return true;
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) {
        await _clearLocalSession(preserveDeviceIdentity: true);
      }
      _opErrors[op] = describeError(err);
      return false;
    } finally {
      _busyOps.remove(op);
      notifyListeners();
    }
  }

  Future<void> _run(Future<void> Function() body) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await body();
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) {
        await _clearLocalSession(preserveDeviceIdentity: true);
      }
      error = describeError(err);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
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
