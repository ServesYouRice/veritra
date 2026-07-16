import 'dart:async';

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

  bool get connected => session != null;
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
      session = await api!.createOwner(
        username: username,
        password: password,
        deviceName: 'Mobile device',
        deviceKeyPackage: await cryptoService.createDeviceKeyPackage(),
        setupToken: setupToken,
      );
      await localStore.saveSession(session!);
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
    final messages = await client.listMessages(current.token, conversationId);
    messagesByConversation = <String, List<ReceivedMessageEnvelope>>{
      ...messagesByConversation,
      conversationId: messages,
    };
    await _persistSnapshot();
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

  /// Creates a DM, group, or community channel conversation and selects it.
  Future<Conversation?> startConversation({
    required String kind,
    String? title,
    String? communityId,
    String? channelId,
    List<String> memberAccountIds = const <String>[],
    int? retentionSeconds,
  }) async {
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
      session = await api!.register(
        inviteCode: inviteCode,
        username: username,
        password: password,
        deviceName: 'Mobile device',
        deviceKeyPackage: await cryptoService.createDeviceKeyPackage(),
      );
      await localStore.saveSession(session!);
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

  Future<void> sendMessageTo(String conversationId, String plaintext) async {
    await _run(() async {
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
      } catch (_) {
        _outboxStates[encrypted.idempotencyKey] = OutboxDeliveryState.failed;
        notifyListeners();
        rethrow;
      }
      await _fetchMessages(conversationId);
    });
  }

  Future<void> retryEnvelope(String idempotencyKey) async {
    await _run(() async {
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
      } catch (_) {
        _outboxStates[idempotencyKey] = OutboxDeliveryState.failed;
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
      activeDeviceLink = await client.approveDeviceLink(
        current.token,
        link.id,
        verificationCode,
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
      activeDeviceLink = DeviceLink(
        id: refreshed.id,
        state: refreshed.state,
        verificationCode: refreshed.verificationCode,
        expiresAt: refreshed.expiresAt,
        code: link.code ?? refreshed.code,
        linkUri: link.linkUri ?? refreshed.linkUri,
        claimedDeviceName: refreshed.claimedDeviceName,
        approvedDeviceId: refreshed.approvedDeviceId,
      );
    });
  }

  Future<void> claimDeviceLink(String baseUrl, String code) async {
    await _run(() async {
      _replaceApi(baseUrl);
      pendingDeviceLinkClaim = await api!.claimDeviceLink(
        code: code,
        deviceName: 'Linked mobile device',
        deviceKeyPackage: await cryptoService.createDeviceKeyPackage(),
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
      final linkedSession = await client.completeDeviceLinkClaim(
        claim.deviceLink.id,
        claim.claimToken,
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
    _syncSubscription = sync!.events.listen(
      (_) => unawaited(_catchUpSyncEvents()),
      onError: (_) => unawaited(_catchUpSyncEvents()),
    );
    unawaited(_catchUpSyncEvents());
    unawaited(_flushOutbox());
    unawaited(sync!.connect());
    // _startSync runs exactly once per established session, which makes it
    // the single hook for hydrating server-listed records.
    unawaited(refreshInvites());
    unawaited(refreshCommunities());
    unawaited(_startPush());
  }

  Future<void> _startPush() async {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    try {
      final config = await client.pushConfig(current.token);
      final vapid = config['vapid_public_key'];
      if (config['enabled'] != true || vapid is! String || vapid.isEmpty) {
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
        _pushSubscriptionId = await client.registerWebPush(
          current.token,
          endpoint: event.endpoint,
          publicKey: event.publicKey,
          authSecret: event.authSecret,
        );
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
              refreshConversationsNeeded = true;
              if (event.conversationId == selectedId) {
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
        if (refreshSelectedMessagesNeeded) {
          await refreshSelectedMessages(notify: false);
          await markNewestMessageRead(selectedId!);
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
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) {
        await _clearLocalSession(preserveDeviceIdentity: true);
      } else if (err is ApiException &&
          err.serverCode == 'full_resync_required') {
        await _refreshConversations(notify: false);
        final selectedId = selectedConversationId;
        if (selectedId != null) {
          await _fetchMessages(selectedId);
        }
        final latest = err.intField('latest_event_id') ?? 0;
        await localStore.saveSyncCursor(latest);
        _lastSyncEventId = latest;
        await _persistSnapshot();
        error = null;
        notifyListeners();
        return;
      }
      error = describeError(err);
      notifyListeners();
    } finally {
      _catchingUpSync = false;
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
    pendingOutbox = await localStore.pendingEnvelopes();
    for (final envelope in pendingOutbox) {
      _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.failed;
    }
    try {
      for (final envelope in List<MessageEnvelope>.from(pendingOutbox)) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.sending;
        notifyListeners();
        await client.sendEnvelope(current.token, envelope);
        await _removeFromOutbox(envelope);
      }
    } catch (_) {
      // The encrypted envelopes remain queued for the next reconnect.
      for (final envelope in pendingOutbox) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.failed;
      }
      notifyListeners();
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
    unawaited(_syncSubscription?.cancel());
    sync?.dispose();
    unawaited(_pushSubscription?.cancel());
    pushService.dispose();
    api?.close();
    super.dispose();
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
