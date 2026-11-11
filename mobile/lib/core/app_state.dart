import 'dart:async';
import 'dart:developer' as developer;
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, mapEquals, setEquals, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../crypto/app_payload.dart';
import '../crypto/poll.dart';
import '../crypto/link_preview.dart';
import '../crypto/message_format.dart';
import '../crypto/device_link_code.dart';
import '../crypto/history_transfer_service.dart';
import '../crypto/k2_transfer_crypto.dart';
import '../crypto/native_crypto_bindings.dart'
    show
        DeviceListBody,
        DeviceListChange,
        DeviceListPair,
        K2LinkContext,
        K2TransferId,
        K2Verification,
        NativeCryptoException,
        idBytes;
import 'device_lists.dart';
import 'k1_restore.dart';
import '../crypto/sha256.dart';
import '../crypto/k2_transcript.dart';
import '../crypto/attachment_crypto.dart';
import '../crypto/backup_service.dart';
import '../crypto/mls_commit_bundle.dart';
import '../crypto/crypto_service.dart';
import 'mls_self_update_policy.dart';
import '../push/push_service.dart';
import '../push/background_wake_runner.dart';
import '../push/notice_decisions.dart';
import '../push/wake_worker_bridge.dart' show WakeNoticeResult;
import '../storage/history_snapshot.dart'
    show HistoryConversation, HistoryImportContext, HistorySnapshot;
import '../storage/local_store.dart';
import '../sync/conversation_pause.dart';
import '../sync/sync_recovery.dart';
import '../sync/sync_service.dart';
import '../calls/call_controller.dart';
import '../calls/call_service.dart' show isTerminalCallState;
import 'api_client.dart';
import 'roles/governance.dart';
import 'roles/posting_verdict.dart';
import 'attachments.dart';
import 'client_config.dart';
import 'device_link_v3_models.dart';
import 'history_transfer_client.dart';
import 'composer_drafts.dart';
import 'errors.dart';
import 'membership_invite_link.dart';
import 'membership_models.dart';
import 'link_preview_service.dart';
import 'link_preview_thumbnail.dart';
import '../storage/message_search.dart';
import 'message_history.dart';
import '../storage/encrypted_database.dart'
    show
        LocalMessageKind,
        LocalMessage,
        LocalPin,
        LocalConversationPref,
        HistoryTransferProgress,
        HistoryTransferStage,
        historyTransferIncoming,
        localStorageErrorCode;
import 'models.dart';
import 'profile_models.dart';
import 'profile_service.dart';
import '../crypto/profile_record_codec.dart'
    show ProfileRecordException, ProfilePhoto;
import 'passkeys.dart';
import 'receipts_state.dart';
import 'report_seed_store.dart';
import 'reports_service.dart';
import 'typing_state.dart';
import '../l10n/l10n.dart';
import 'account_recovery.dart';
import 'k1_backup.dart';
import 'screen_guard.dart';

export 'account_recovery.dart';
export 'membership_invite_link.dart';
export 'membership_models.dart';
export 'screen_guard.dart';

part 'app_state_membership.dart';
part 'app_state_reports.dart';
part 'app_state_passkeys.dart';
part 'app_state_recovery.dart';
part 'app_state_k1_backup.dart';
part 'app_state_k1_restore.dart';
part 'app_state_link_v3.dart';
part 'app_state_device_list.dart';
part 'app_state_profiles.dart';

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
    this.passkeys,
    this.origin,
  });

  const SetupProbeResult.idle() : this(state: SetupProbeState.idle);

  const SetupProbeResult.probing() : this(state: SetupProbeState.probing);

  final SetupProbeState state;
  final bool? setupRequired;
  final String? instanceName;

  /// What the server says about passkeys; null when off or not said (B7).
  final PasskeyServerInfo? passkeys;

  /// The canonical origin that was probed.
  final String? origin;

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

  /// C1: invitations, join requests and community membership.
  static const membership = 'membership';
  static const blocks = 'blocks';
  static const profile = 'profile';
  static const mute = 'mute';

  /// K0: setting the recovery key (R3), and a recovery claim or its cancel
  /// (R4).
  static const recoveryKey = 'recovery_key';
  static const accountRecovery = 'account_recovery';

  /// B7: the passkey list and its changes.
  static const passkeys = 'passkeys';

  /// K2: the link screen of the existing device, and the claim form of the
  /// new one.
  static const deviceLink = 'device_link';
  static const deviceLinkClaim = 'device_link_claim';

  /// Refresh failures of the conversation and device lists. The lists keep
  /// their last good contents while this holds an error (card T44A).
  static const conversations = 'conversations';
  static const devices = 'devices';
  static String conversation(String id) => 'conversation:$id';
}

enum RequestBucket { chat, request, hidden }

/// Why the stored message-request state is not in use: the read failed
/// (tried again later) or the value could not be decoded.
enum _RequestStateFault { unreadable, undecodable }

/// The newest event id a sync pass fetched, as a floor for a leave that
/// cannot be dated by the server (D70). It counts only for the session
/// generation it was recorded under: a value from another session's pass
/// says nothing about this one's events, so it is 0 then.
@visibleForTesting
int passFetchedFloor({
  required int fetchedThrough,
  required int fetchedGeneration,
  required int sessionGeneration,
}) =>
    fetchedGeneration == sessionGeneration ? fetchedThrough : 0;

class AppState extends ChangeNotifier
    implements ConversationAuthority, VerifiedRoleSource {
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
    ReportSeedStore? reportSeedStore,
    this.passkeyClient = const UnsupportedPasskeyClient(),
    PasskeyPlatform? passkeyPlatform,
    List<String>? passkeyAppleDomains,
    ScreenGuard? screenGuard,
  })  : reportSeedStore = reportSeedStore ?? MemoryReportSeedStore(),
        passkeyPlatform =
            passkeyPlatform ?? passkeyPlatformOf(defaultTargetPlatform),
        passkeyAppleDomains = passkeyAppleDomains ??
            parsePasskeyDomains(passkeyAppleDomainsDefine),
        pushService = pushService ?? DisabledMobilePushService(),
        receiptPreferences = receiptPreferences ??
            ReceiptPreferences(MemoryReceiptPreferenceStore()),
        screenGuard = screenGuard ?? const PlatformScreenGuard() {
    composerDrafts.onChanged = _draftChanged;
    if (cryptoService case final ConversationAuthorityConsumer consumer) {
      consumer.conversationAuthority = this;
    }
    // L1 (D94): the pins the native add gate and leaf judge use.
    if (cryptoService case final DeviceListCryptoService lists) {
      final pins = DeviceListPins(
        store: localStore,
        source: _AppDeviceListSource(this),
        verifier: lists,
      );
      _deviceListPins = pins;
      lists.deviceListPins = pins;
    }
    // Read the saved switch now so the settings screen shows it at once.
    unawaited(this.receiptPreferences.loaded);
  }

  /// The "send read receipts" switch (W5).
  final ReceiptPreferences receiptPreferences;

  /// The platform's passkey ceremonies (B7); Linux and tests use the
  /// unsupported one.
  final PasskeyClient passkeyClient;
  final PasskeyPlatform passkeyPlatform;

  /// Screen guard service (e.g. Android FLAG_SECURE).
  final ScreenGuard screenGuard;

  /// Hostnames compiled into the build's associated domains (iOS, macOS).
  final List<String> passkeyAppleDomains;

  /// Passkeys of the signed-in account, as last read.
  List<PasskeyRecord> passkeyList = const <PasskeyRecord>[];
  bool passkeysLoaded = false;

  /// A passkey was added to or removed from this account somewhere else.
  PasskeyNotice? passkeyNotice;

  /// Passkey row IDs this device changed itself, so its own sync events do
  /// not raise a notice.
  final Set<String> _ownPasskeyChanges = <String>{};

  /// The approved-device list pins (L1); null without an L1 engine.
  DeviceListPins? _deviceListPins;

  /// This account has no approved-device list yet (from before L1): its
  /// devices are added to no chat until the user reviews them once.
  bool ownDeviceListMissing = false;

  /// Delivery and read cursors of the other members (W5).
  final ReceiptsState receipts = ReceiptsState();

  /// Who is typing (W5). Ephemeral, memory only.
  final TypingState typing = TypingState();

  /// Encrypted backup and restore (card I45). Null in builds without the
  /// MLS service, where there is nothing to back up.
  final BackupService? backupService;

  /// Where an instance owner's report-key seed is kept (C6, D95). Memory only
  /// unless the build passes protected storage.
  final ReportSeedStore reportSeedStore;

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

  /// How long sign-out waits for the server to revoke the token before it
  /// gives up. The local wipe never waits on it: the device is signed out
  /// either way, and an unrevoked token expires on its own.
  @visibleForTesting
  Duration signOutRevokeTimeout = const Duration(seconds: 5);

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

  /// K2 device link v3 (app_state_link_v3.dart). [activeDeviceLink] is the
  /// link this device made; [pendingDeviceLinkClaim] is this device's own
  /// waiting claim; [historyTransferStatus] is the history copy, if one is
  /// open.
  DeviceLinkV3View? activeDeviceLink;
  DeviceLinkV3Record? _activeLinkRecord;
  _PendingLinkV3? _pendingLink;
  Timer? _linkPollTimer;
  Timer? _transferTimer;
  bool _transfersRunning = false;
  HistoryTransferStatus? historyTransferStatus;

  /// Where the history copy keeps its ciphertext files; the app's private
  /// support directory unless a test provides one.
  Future<String> Function()? historyTransferDirectory;

  /// The transport of the history copy; the real client unless a test
  /// provides one.
  HistoryTransferTransport Function(String origin)?
      historyTransferTransportFactory;
  Map<String, LocalConversationPref> conversationPrefs = {};
  final Map<String, List<LocalPin>> _pins = {};

  /// The channel the open chat is showing, for a community's shared group
  /// (C0): that group holds every open channel, so which one a post goes to,
  /// and which posts are listed, comes from here. Set by the chat screen.
  final Map<String, String> _selectedChannels = {};
  Set<String> starredMessages = {};
  bool showArchivedChats = false;

  /// Conversation descriptors copied from another device (K2). Historical
  /// metadata only: never a live conversation, member list or permission.
  Map<String, HistoryConversation> _copiedHistory = {};
  bool mentionsInMutedChats = true;

  /// Whether Android FLAG_SECURE protects chats against AI-assistant screen
  /// reading and screenshots. Stored under `screen_guard_chats`. Defaults to true.
  bool screenGuardChats = true;

  int _activeChatViews = 0;

  /// Whether the screen guard is currently active (setting enabled and at least
  /// one chat view active).
  bool get isScreenGuardActive => screenGuardChats && _activeChatViews > 0;

  @visibleForTesting
  int get activeChatViewsForTesting => _activeChatViews;

  /// Which links this device may fetch to build a preview for a message it
  /// sends (B2). Receivers never fetch. Stored under `b2.link_preview`.
  LinkPreviewMode linkPreviewMode = LinkPreviewMode.allowListed;

  /// Replaceable in tests; the default builds previews over HTTPS.
  LinkPreviewService linkPreviews =
      LinkPreviewService(thumbnailEncoder: encodePngThumbnail);
  final Set<String> _previewPending = <String>{};
  @override
  String? roleOf(String conversationId, String accountId) {
    final memberRole = membersFor(conversationId)
        .where((m) => m.accountId == accountId)
        .firstOrNull
        ?.role;
    if (memberRole != null) return memberRole;
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conv != null) {
      if (conv.createdBy != null && conv.createdBy == accountId) return 'owner';
      if (conv.communityId != null) {
        final comm =
            communities.where((c) => c.id == conv.communityId).firstOrNull;
        if (comm?.createdBy != null && comm!.createdBy == accountId) {
          return 'owner';
        }
      }
      if (accountId == session?.accountId) {
        if (conv.currentRole != null) return conv.currentRole;
        if (conv.communityId != null) {
          final commRole = communityRole(conv.communityId!);
          if (commRole != null) return commRole;
        }
      }
    }
    return null;
  }

  @visibleForTesting
  GovernanceState? Function(String conversationId)?
      governanceOverrideForTesting;

  @override
  GovernanceState? governanceOf(String conversationId) {
    if (governanceOverrideForTesting != null) {
      final override = governanceOverrideForTesting!(conversationId);
      if (override != null) return override;
    }
    try {
      return cryptoService.governanceOf(conversationId);
    } catch (_) {
      return null;
    }
  }

  Channel? _findChannel(String? channelId) {
    if (channelId == null) return null;
    for (final list in channelsByCommunity.values) {
      for (final ch in list) {
        if (ch.id == channelId) return ch;
      }
    }
    return null;
  }

  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) {
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conv != null && conv.postingRestricted) return true;
    final chId = channelId ?? conv?.channelId;
    if (chId != null) {
      final ch = _findChannel(chId);
      if (ch != null && ch.kind == 'announcement') return true;
    }
    return false;
  }

  /// C2: reports whether the signed-in user may post in [conversationId]
  /// (and optional [channelId]). When posting is restricted (announcement
  /// channel or admin-only posting), only owners and admins may post.
  bool mayPost(String conversationId, {String? channelId}) {
    final localAccount = session?.accountId;
    if (localAccount == null) return true;
    final record = governanceOf(conversationId);
    final serverRestricted = serverRestrictsPosting(conversationId, channelId);
    final restricted = (record?.isRestricted(channelId: channelId) ?? false) ||
        serverRestricted;
    if (!restricted) return true;

    // Restricted: only owner and admin may post.
    if (record != null) {
      return record.rankOf(localAccount) >= BuiltInRole.admin.rank;
    }
    final role = roleOf(conversationId, localAccount);
    return role == 'owner' || role == 'admin';
  }

  /// The local account's role in [communityId].
  String? communityRole(String communityId) {
    final community = communities.where((c) => c.id == communityId).firstOrNull;
    if (community != null &&
        community.createdBy != null &&
        community.createdBy == session?.accountId) {
      return 'owner';
    }
    if (community?.sharedConversationId != null) {
      final shared = conversations
          .where((c) => c.id == community!.sharedConversationId)
          .firstOrNull;
      if (shared?.currentRole != null) return shared!.currentRole;
    }
    for (final c in conversations) {
      if (c.communityId == communityId && c.currentRole != null) {
        return c.currentRole;
      }
    }
    return null;
  }

  /// Reports whether the signed-in user may create channels in [communityId].
  /// Only owners and admins may create channels (owner decision).
  bool canCreateChannel(String communityId) {
    final localAccount = session?.accountId;
    if (localAccount == null) return false;
    final community = communities.where((c) => c.id == communityId).firstOrNull;
    if (community?.sharedConversationId != null) {
      final record = governanceOf(community!.sharedConversationId!);
      if (record != null) {
        return record.rankOf(localAccount) >= BuiltInRole.admin.rank;
      }
    }
    final role = communityRole(communityId);
    return role == 'owner' || role == 'admin';
  }

  @override
  Set<String> memberAccounts(String conversationId) =>
      membersFor(conversationId).map((m) => m.accountId).toSet();
  @override
  String? conversationKind(String conversationId) =>
      conversations.where((c) => c.id == conversationId).firstOrNull?.kind;
  @override
  String? conversationChannel(String conversationId) =>
      conversations.where((c) => c.id == conversationId).firstOrNull?.channelId;
  bool isArchived(String id) => conversationPrefs[id]?.archivedAt != null;
  bool isChatPinned(String id) => conversationPrefs[id]?.pinnedAt != null;
  List<LocalPin> pinsFor(String id) {
    final channel = selectedChannelFor(id);
    return (_pins[id] ?? const <LocalPin>[])
        .where((p) =>
            p.expiresAt > DateTime.now().millisecondsSinceEpoch &&
            (channel == null || p.channelId == channel))
        .toList();
  }

  bool canPinMessages(String id) => pinAllowed(
      kind: conversationKind(id), role: roleOf(id, session?.accountId ?? ''));
  void toggleArchivedChats() {
    showArchivedChats = !showArchivedChats;
    notifyListeners();
  }

  Future<void> setMentionsInMutedChats(bool value) async {
    mentionsInMutedChats = value;
    await localStore.saveSetting('w8.mentions_muted', '$value');
    notifyListeners();
  }

  Future<void> setScreenGuardChats(bool value) async {
    screenGuardChats = value;
    await localStore.saveSetting('screen_guard_chats', '$value');
    _updateScreenGuard();
    notifyListeners();
  }

  void enterChatView() {
    _activeChatViews++;
    _updateScreenGuard();
  }

  void leaveChatView() {
    if (_activeChatViews > 0) {
      _activeChatViews--;
      _updateScreenGuard();
    }
  }

  void _updateScreenGuard() {
    unawaited(screenGuard.setSecure(isScreenGuardActive));
  }

  Future<void> setLinkPreviewMode(LinkPreviewMode mode) async {
    linkPreviewMode = mode;
    await localStore.saveSetting('b2.link_preview', mode.name);
    notifyListeners();
  }

  Future<void> setConversationArchived(String id, bool archived) async {
    final old = conversationPrefs[id];
    await _saveConversationPref(LocalConversationPref(
        conversationId: id,
        archivedAt: archived ? DateTime.now().millisecondsSinceEpoch : null,
        pinnedAt: old?.pinnedAt));
  }

  Future<void> setChatPinned(String id, bool pinned) async {
    final old = conversationPrefs[id];
    await _saveConversationPref(LocalConversationPref(
        conversationId: id,
        archivedAt: old?.archivedAt,
        pinnedAt: pinned ? DateTime.now().millisecondsSinceEpoch : null));
  }

  Future<void> _saveConversationPref(LocalConversationPref pref) async {
    await localStore.saveConversationPref(pref);
    conversationPrefs = {...conversationPrefs, pref.conversationId: pref};
    notifyListeners();
  }

  Future<void> toggleMessageStar(LocalMessage message) async {
    await localStore.setStarred(
        message.key, !starredMessages.contains(message.key));
    starredMessages = await localStore.loadStarred();
    notifyListeners();
  }

  Future<void> deleteMessageForMe(LocalMessage message) async {
    await localStore.hideMessage(message.conversationId, message.key);
    await refreshHistory(message.conversationId);
  }

  Future<void> _ensureConversationAuthority(String id,
      {ApiClient? client}) async {
    if (cryptoService is! ConversationAuthorityConsumer) return;
    if (membersByConversation.containsKey(id)) return;
    final current = session;
    client ??= api;
    if (current == null || client == null) return;
    final members = await client.conversationMembers(current.token, id);
    membersByConversation = {...membersByConversation, id: members};
    _noteRosterPeers(id);
  }

  List<int>? _activeLinkSecret;
  // L1-3: the random this device committed to when it made the link; it is
  // revealed only after the native accept of the claim.
  List<int>? _activeLinkSourceRandom;
  void _clearLinkSecret() {
    _activeLinkSecret?.fillRange(0, _activeLinkSecret!.length, 0);
    _activeLinkSecret = null;
    _activeLinkSourceRandom?.fillRange(0, _activeLinkSourceRandom!.length, 0);
    _activeLinkSourceRandom = null;
  }

  DeviceLinkClaimView? pendingDeviceLinkClaim;

  /// K0 recovery (app_state_recovery.dart). [recoveryKeyStatus] is the
  /// server's view of this account's recovery key and any waiting recovery;
  /// [pendingAccountRecovery] is this device's own waiting claim;
  /// [recoveryFollowUp] is the step a recovered device must finish before
  /// its chats open.
  RecoveryKeyStatus? recoveryKeyStatus;
  PendingAccountRecovery? pendingAccountRecovery;
  RecoveryFollowUpStep? recoveryFollowUp;
  String? _passwordLeakDay;
  // K0 step 8: whether this device came from a completed recovery, and the
  // conversations it was last found to have no MLS group for.
  bool _recoveredDevice = false;
  // The session generation [_recoveredDevice] was read for; until it is the
  // current one, sends wait for the read (and refuse if it fails).
  int _recoveredMarkGeneration = -1;
  Future<void>? _recoveredMarkLoad;
  final Set<String> _grouplessConversations = <String>{};
  // Conversations whose group was read once; the list refresh reads only
  // new ones, and a Welcome clears the group-less mark.
  final Set<String> _grouplessChecked = <String>{};
  // The last loaded member list said no other account: kept while a
  // membership event drops the list until it is read again.
  final Set<String> _lastKnownNoPeer = <String>{};
  Timer? _recoveryPollTimer;

  /// K1 automatic backups (app_state_k1_backup.dart): this device's state,
  /// whether a run is under way, and the desktop hourly check.
  K1BackupState? _k1State;
  bool _k1Running = false;
  bool _k1RerunRequested = false;
  Timer? _k1Timer;

  /// The clock K1 schedules read; tests move it.
  @visibleForTesting
  DateTime Function() k1Clock = () => DateTime.now().toUtc();

  /// Desktop apps keep running in the tray (W4), so they check hourly;
  /// phones run when the app is opened (D91, until D52).
  @visibleForTesting
  bool k1DesktopTimerEnabled =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  DateTime? _recoveryStatusReadAt;
  String? error;
  bool busy = false;
  // Distinguishes "still fetching the first page" from "genuinely empty" so
  // the UI doesn't show a misleading empty state during cold start. Each list
  // hydrated after auth carries its own flag so screens can show a spinner
  // until their first fetch resolves.
  bool conversationsLoaded = false;
  bool communitiesLoaded = false;
  bool invitesLoaded = false;

  /// True when the last [refreshInvites] could not list the invites. The
  /// listing stays best-effort for everyone else, but the invite screen says
  /// so instead of showing an empty list.
  bool invitesLoadFailed = false;
  bool devicesLoaded = false;
  final Set<String> _loadingMessageConversations = <String>{};
  final Map<String, String> _messageLoadErrors = <String, String>{};
  AccountSyncEngine? _syncOwner;
  LocalSyncLease? _syncLease;
  int _sessionGeneration = 0;
  int _sessionEnds = 0;

  /// Bumped as the first step of every local sign-out, before any await,
  /// and by nothing else. `session` stays set for several awaits while the
  /// sign-out runs; work that captured this value under the old session and
  /// sees it changed must drop its result. Unlike the private session
  /// generation it does not move when sync restarts, so it never drops
  /// work of a session that is still running.
  int get sessionEndGeneration => _sessionEnds;

  int _sessionsEnding = 0;

  /// True while a local sign-out runs. `session` is still set then, but it
  /// already belongs to the past: nothing may be shown or stored for it.
  /// Covers work that starts inside the window, which a value captured from
  /// [sessionEndGeneration] at its start cannot see.
  bool get sessionEnding => _sessionsEnding > 0;

  AttachmentOrphanSweeper? _orphanSweeper;

  /// Removes attachment working files a crash left behind, now and every
  /// hour until [dispose] (TASK-050). Only the UI process calls it. It keeps
  /// running across sign-out: the working directory belongs to the device,
  /// not the account, and files left from before a sign-out are exactly what
  /// it removes.
  void startAttachmentOrphanSweep() {
    final service = attachmentService;
    if (service == null || _disposed || _orphanSweeper != null) return;
    _orphanSweeper = AttachmentOrphanSweeper(service.workingDirectory)..start();
  }

  // D52 bounded background work (phones). Off unless the demo entry point
  // installs the native worker; release builds never construct it.
  WakeRunContext? _wakeRun;
  ApiClient? _wakeApi;
  bool _wakePassComplete = false;
  bool _refreshAfterWake = false;
  bool _replenishAfterWake = false;

  /// Revokes native background work (permits, scheduled jobs) before this
  /// device's private notice state is cleared: logout, relink, identity
  /// change. Set only by the demo entry point that installed the worker.
  Future<void> Function()? beforeLocalSessionClear;

  /// Demo-only phone notices (D52). The demo entry point sets
  /// [phoneNoticeInstaller]; it installs the native worker for the signed-in
  /// account and reports whether native allows phone wakes. Only then is
  /// notice capture switched on and the push registration asked for
  /// `local_decrypt_v1`. Release builds never set it, so both stay off.
  Future<bool> Function()? phoneNoticeInstaller;
  bool phoneNoticesAllowed = false;

  /// A background process installs its worker before the wake runs; it calls
  /// this once native said opt-in is allowed.
  void allowPhoneNotices() => phoneNoticesAllowed = true;

  void _applyNoticeCapture() {
    final crypto = cryptoService;
    if (crypto is! NoticeCaptureConsumer) return;
    final consumer = crypto as NoticeCaptureConsumer;
    try {
      consumer.noticeCaptureEnabled = phoneNoticesAllowed;
    } catch (_) {
      // No active existing identity: no capture, and no opt-in registration.
      phoneNoticesAllowed = false;
    }
  }

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
  /// W11: encrypted display names and photos. Null in a build without the
  /// native library, and until a session has started.
  ProfileService? profiles;
  Timer? _profileTimer;

  /// Whether `conversations` came from the server this session. Before that
  /// it may be empty only because nothing was read yet.
  bool _conversationsFromServer = false;

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

  /// Conversations paused by their own MLS failure, by conversation id (C1
  /// prerequisite 1). Sync goes on for every other conversation. Kept
  /// durably by the local store; loaded at the start of each sync pass.
  Map<String, ConversationPause> conversationPauses =
      const <String, ConversationPause>{};

  /// Whether [conversationId] is paused by a sync failure of its own.
  bool conversationSyncPaused(String conversationId) =>
      conversationPauses.containsKey(conversationId);

  /// The pause of [conversationId], or null.
  ConversationPause? conversationPauseFor(String conversationId) =>
      conversationPauses[conversationId];

  /// Conversations whose user asked for a retry; the next foreground pass
  /// replays them before it reads the global stream.
  final Set<String> _pauseReplayRequests = <String>{};
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
  Duration _expiryBackoff = Duration.zero;

  static Duration _nextExpiryBackoff(Duration current) {
    if (current < const Duration(seconds: 1)) {
      return const Duration(seconds: 1);
    }
    final doubled = current * 2;
    return doubled > const Duration(minutes: 5)
        ? const Duration(minutes: 5)
        : doubled;
  }

  int _catchUpRetryAttempt = 0;
  final Set<String> _failedMlsConversations = <String>{};
  final Map<String, DateTime> _mlsPendingSeen = <String, DateTime>{};
  final Set<String> _mlsReconcileNow = <String>{};
  bool _mlsReconcileRequested = true;

  /// D68: conversations whose application sends wait, unencrypted, until
  /// the MLS commit removing a member is applied locally. Kept in a local
  /// setting per device, so a restart keeps this device's own removals
  /// held before the server's pending-changes list is read again.
  final Map<String, _RemovalHold> _removalHolds = <String, _RemovalHold>{};

  /// Bumped whenever a hold is set; a pending-changes read releases only
  /// holds set before it started (D68).
  int _removalHoldSeq = 0;

  /// The session generation whose stored holds were loaded.
  int? _removalHoldsLoaded;

  /// Pending-changes reads applied to the holds so far (D68).
  int _removalReadCount = 0;

  /// The highest [_removalReadCount] a complete sync fetch started after.
  /// Every commit the server held at that read has then been applied: the
  /// server writes a commit's sync event, its roster change and the new
  /// epoch in one transaction, and an MLS control message that cannot be
  /// applied stops sync at its event (I33), so that fetch never completes.
  int _removalFetchedAfterRead = 0;

  /// Completed and replaced whenever [_removalHolds], a paused conversation
  /// or the session changes, so waiting sends look again. Never polled.
  Completer<void> _removalHoldsChanged = Completer<void>();

  /// Per conversation, the latest send waiting on a removal hold: a later
  /// send queues behind it, so held sends go out in the order made.
  final Map<String, Future<void>> _heldSendTails = <String, Future<void>>{};

  /// Periodic self-update state (MlsSelfUpdatePolicy), loaded for the
  /// session's account and device on first use.
  MlsSelfUpdatePolicy? _selfUpdatePolicy;

  /// Groups with a pending revocation, from the latest revocation pass. A
  /// self-update never competes with the revocation commit.
  final Set<String> _revocationPendingGroups = <String>{};
  DateTime? _lastSelfUpdateStagedAt;

  /// At most one self-update is staged per pass, and none closer than this
  /// to the previous one, so a device catching up on many chats spreads
  /// them out.
  static const _selfUpdateSpacing = Duration(minutes: 1);
  Future<void> _sessionTransitionTail = Future<void>.value();
  Stream<IncomingCallSignal> get callSignals => _callSignals.stream;

  /// The signed-in session's call controller, set by the call host in demo
  /// builds (B5); null otherwise, so release builds show no call controls.
  final ValueNotifier<CallController?> callController =
      ValueNotifier<CallController?>(null);

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
      _resumeAccountRecovery();
      unawaited(runK1BackupIfDue());
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

  /// Restores a backup onto this empty device (card I45). Returns false with
  /// a typed error under [Ops.restore]; an interrupted download continues on
  /// the next attempt.
  ///
  /// A backup carries no token, device secret or MLS state (D71, D73), so a
  /// restore never signs in: it leaves the account's history and settings
  /// on this device, signed out and with no device yet, and reports under
  /// [Ops.restore] how to finish. The device then joins the account as a
  /// new one (today by a device link, which keeps the restored history),
  /// with fresh MLS state, cursor 0 and new key packages, and its groups
  /// add it like any freshly linked device. There is no restored session a
  /// server could reject, so D66's failed-restore case cannot arise; true
  /// is kept for a session that is somehow up after the restore.
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
      // _tryRestoreSession handles its own failures without throwing: the
      // recovery screen, a session the server rejected, nothing stored.
      // The recovery screen and nothing stored mean the restore did not
      // finish; their screen and message stay as they are.
      if (session != null && lifecycle == SessionLifecycle.ready) return;
      if (lifecycle != SessionLifecycle.recoveryRequired) {
        Session? stored;
        try {
          stored = await localStore.loadSession();
        } catch (_) {
          // Reported as a storage failure below.
        }
        if (stored != null && isRestoredAccountSession(stored)) {
          // The history is on this device; it still has to join the
          // account as a new device (D71, D73).
          throw UserFacingException(l10n.backupRestoredLinkToFinish);
        }
      }
      // The local store or keystore failed (the recovery screen says how),
      // or the restored session did not reach the store.
      throw const BackupException(BackupFailureKind.storage);
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
  bool isBusy(String op) =>
      _busyOps.contains(op) || (op == Ops.send && _previewPending.isNotEmpty);
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

  /// Whether nothing may be fetched or acknowledged for the conversation: a
  /// request, a hidden one, or one not in the list (which may well be a
  /// stranger's that the list has not caught up with).
  bool _heldBack(String conversationId) => !conversationOpen(conversationId);

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
  ///
  /// Only an absent value (or one written for another account) is a first
  /// run. A value that cannot be read or decoded fails closed: every DM and
  /// group from someone else is held back as a request, nothing is
  /// grandfathered, and the stored value is not overwritten. A read error is
  /// tried again on the next load; decisions made meanwhile are kept in
  /// memory and merged in then.
  Future<void> _loadRequestState({required bool grandfather}) async {
    final me = session?.accountId;
    if (me == null) return;
    if (_acceptedPeers == null) {
      // A fresh session's state: nothing carries over from an earlier one.
      _requestStateFault = null;
      _requestGrandfatherPending = null;
      _requestUndeclinedPending.clear();
      _requestDecisionsPending = false;
    } else if (_requestStateFault != _RequestStateFault.unreadable) {
      return;
    }
    final generation = _sessionGeneration;
    bool owned() =>
        generation == _sessionGeneration && session?.accountId == me;
    final accepted = <String>{};
    final groups = <String>{};
    final declined = <String, DateTime>{};
    var known = false;
    _RequestStateFault? fault;
    String? raw;
    try {
      raw = await localStore.loadSetting(_requestSettingName);
    } catch (_) {
      fault = _RequestStateFault.unreadable;
    }
    if (!owned()) return;
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          fault = _RequestStateFault.undecodable;
        } else if (decoded['account'] == me) {
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
      } catch (_) {
        fault = _RequestStateFault.undecodable;
      }
    }
    if (fault != null) {
      // Fail closed: hold back what is not this account's own, keep any
      // decision already made in this run, and write nothing.
      if (grandfather) {
        _requestGrandfatherPending ??= List.of(conversations);
      }
      _requestStateFault = fault;
      _acceptedPeers ??= <String>{};
      return;
    }
    // Decisions made while the value could not be read are newer than it.
    final pending = _acceptedPeers;
    final save = !known || _requestDecisionsPending;
    if (pending != null) {
      accepted.addAll(pending);
      groups.addAll(_acceptedGroups);
      declined
        ..removeWhere((id, _) => _requestUndeclinedPending.contains(id))
        ..addAll(_declined);
    }
    if (!known) {
      final earlier = _requestGrandfatherPending;
      if (grandfather || earlier != null) {
        for (final conversation in earlier ?? conversations) {
          final peer = conversation.peerAccountId;
          if (conversation.isDm && peer != null) accepted.add(peer);
          if (conversation.isGroup) groups.add(conversation.id);
        }
      }
    }
    if (save) {
      await _saveRequestState(me, accepted, groups, declined);
      if (!owned()) return;
    }
    _requestStateFault = null;
    _requestGrandfatherPending = null;
    _requestUndeclinedPending.clear();
    _requestDecisionsPending = false;
    _acceptedPeers = accepted;
    _acceptedGroups
      ..clear()
      ..addAll(groups);
    _declined
      ..clear()
      ..addAll(declined);
  }

  /// Why the stored request state could not be used, or null when it was.
  _RequestStateFault? _requestStateFault;

  /// The conversations a failed upgrade load would have grandfathered, kept
  /// for the retry so it does not turn existing chats into requests.
  List<Conversation>? _requestGrandfatherPending;

  /// Conversations accepted while the stored value could not be read: their
  /// stored declines are cleared when it is merged.
  final Set<String> _requestUndeclinedPending = <String>{};

  /// A decision was made while the stored value could not be read.
  bool _requestDecisionsPending = false;

  /// Saves the request state after a user decision. While the stored value
  /// cannot be read, the decision is kept for the merge on the next good
  /// read instead, so nothing stored is lost. A value that cannot be decoded
  /// is replaced only here, by the user's own decision.
  Future<void> _persistRequestState() async {
    final me = session?.accountId;
    final accepted = _acceptedPeers;
    if (me == null || accepted == null) return;
    if (_requestStateFault == _RequestStateFault.unreadable) {
      _requestDecisionsPending = true;
      return;
    }
    await _saveRequestState(me, accepted, _acceptedGroups, _declined);
    if (session?.accountId == me) _requestStateFault = null;
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
    if (_requestStateFault == _RequestStateFault.unreadable) {
      _requestUndeclinedPending.add(conversation.id);
    }
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
  /// Copied conversations this device cannot open live: not in the server's
  /// conversation list and not in a joined community. Empty until the live
  /// list is known (community channels: until communities are known too), so
  /// a live chat is never shown as read-only history.
  List<HistoryConversation> get historyOnlyConversations {
    if (!conversationsLoaded || _copiedHistory.isEmpty) return const [];
    final live = {for (final c in conversations) c.id};
    final joined = {for (final c in communities) c.id};
    return [
      for (final c in _copiedHistory.values)
        if (!live.contains(c.id) &&
            (c.communityId == null ||
                (communitiesLoaded && !joined.contains(c.communityId))))
          c
    ]..sort((a, b) => (a.title ?? '').compareTo(b.title ?? ''));
  }

  bool isHistoryOnly(String conversationId) =>
      historyOnlyConversations.any((c) => c.id == conversationId);

  /// Rereads the copied-history descriptors after a restore or import.
  Future<void> refreshCopiedHistory() async {
    final generation = _sessionGeneration;
    final namespace = await localStore.loadHistoryNamespace();
    if (generation != _sessionGeneration || session == null) return;
    _copiedHistory = Map.of(namespace.conversations);
    notifyListeners();
  }

  /// The visible copied messages of a history-only conversation, oldest
  /// first. Read from this device's encrypted store only: nothing is
  /// fetched, sent, downloaded or looked up. Expired, hidden and deleted
  /// rows are left out.
  Future<List<LocalMessage>> historyOnlyMessages(String conversationId,
      {DateTime? now}) async {
    if (!isHistoryOnly(conversationId)) return const [];
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await localStore.loadMessages(conversationId);
    if (!isHistoryOnly(conversationId)) return const [];
    return [
      for (final m in rows)
        if (const {
              LocalMessageKind.text,
              LocalMessageKind.attachment,
              LocalMessageKind.unsupported
            }.contains(m.kind) &&
            m.hiddenAt == null &&
            m.deletedAt == null &&
            m.senderHidden != true &&
            (m.expiresAt == null || m.expiresAt! > at))
          m
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  Future<void> refreshHistory(String conversationId) async {
    _history[conversationId] = await _loadHistory(conversationId);
    notifyListeners();
  }

  Future<ConversationHistory> _loadHistory(String conversationId) async {
    _pins[conversationId] = await localStore.loadPins(conversationId);
    final stars = await localStore.loadStarred();
    if (!setEquals(starredMessages, stars)) starredMessages = stars;
    final messages = await localStore.loadMessages(conversationId);
    final reactions = await localStore.loadReactions(conversationId);
    return ConversationHistory(
      conversationId: conversationId,
      messages: messages,
      reactions: reactions,
      copiedKeys:
          (await localStore.loadHistoryNamespace()).provenance.keys.toSet(),
    );
  }

  /// What the chat shows, newest first (Stage 4). With MLS, decrypted local
  /// history is the source of truth, so every message this device has read
  /// or sent is shown even when the server is unreachable or the envelope
  /// left the local cache. Server envelopes without a local record (sent
  /// before this device joined, say) still appear, as redacted bars.
  List<ReceivedMessageEnvelope> timelineFor(String conversationId) {
    final all = _timelineForConversation(conversationId);
    final channel = _selectedChannels[conversationId];
    if (channel == null) return all;
    // A shared group holds every open channel; the chat shows one of them.
    final history = historyFor(conversationId);
    return all
        .where((envelope) =>
            (history.forEnvelope(envelope)?.channelId ??
                _metadataChannel(envelope.cryptoMetadata)) ==
            channel)
        .toList(growable: false);
  }

  /// The channel a server envelope names in its clear metadata.
  static String? _metadataChannel(Object? metadata) =>
      metadata is Map ? metadata['channel_id'] as String? : null;

  List<ReceivedMessageEnvelope> _timelineForConversation(
      String conversationId) {
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
    // A row past its expiry is never shown, even while the cached history
    // still holds it (its purge or the reload after it has not landed yet).
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    bool expired(LocalMessage? local) =>
        local?.expiresAt != null && local!.expiresAt! <= nowMs;
    final byKey = <String, ReceivedMessageEnvelope>{};
    for (final envelope in envelopes) {
      // A placeholder row is keyed by its sync event, so ask the history
      // which row an envelope belongs to before using its claimed key.
      final local = history.forEnvelope(envelope);
      if (expired(local)) continue;
      byKey[local?.key ??
          ConversationHistory.keyOf(
              envelope.senderDeviceId, envelope.idempotencyKey)] = envelope;
    }
    for (final local in history.messages) {
      if (local.kind == LocalMessageKind.action ||
          expired(local) ||
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
        final leftLocal = history.forEnvelope(left);
        final rightLocal = history.forEnvelope(right);
        final byCreatedAt = (rightLocal?.createdAt ??
                right.createdAt.millisecondsSinceEpoch)
            .compareTo(
                leftLocal?.createdAt ?? left.createdAt.millisecondsSinceEpoch);
        return byCreatedAt != 0
            ? byCreatedAt
            : (rightLocal?.key ?? right.id)
                .compareTo(leftLocal?.key ?? left.id);
      });
  }

  List<ReceivedMessageEnvelope> messagesFor(String conversationId) =>
      messagesByConversation[conversationId] ??
      const <ReceivedMessageEnvelope>[];

  List<MessageEnvelope> pendingFor(String conversationId) {
    final channel = _selectedChannels[conversationId];
    return pendingOutbox
        .where((envelope) =>
            envelope.conversationId == conversationId &&
            (channel == null ||
                _metadataChannel(envelope.cryptoMetadata) == channel))
        .toList(growable: false);
  }

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
        passkeys: PasskeyServerInfo.fromStatus(status),
        origin: origin,
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
    _localDataDamaged = false;
    notifyListeners();
    try {
      final stored = await localStore.loadSession();
      // The local database opened, so a run of failed upgrades is over.
      _storageFullFailures = 0;
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      // Expired messages go even from a device that is signed out: it keeps
      // its history for the next sign-in (W2).
      try {
        await localStore.purgeExpiredMessages();
      } catch (_) {
        // Best effort: expired text is hidden on read even if this delete
        // failed, and the timer retries. Never a reason for recovery mode.
        _expiryBackoff = _nextExpiryBackoff(_expiryBackoff);
      }
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      if (stored == null) {
        await _loadPendingAccountRecovery();
        await _loadPendingDeviceLink();
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
        await _loadPendingAccountRecovery();
        await _loadPendingDeviceLink();
        lifecycle = SessionLifecycle.ready;
        notifyListeners();
        return;
      }
      await _resumeDeviceListAnchor(restored);
      session = restored;
      _replaceApi(restored.baseUrl);
      await _resumeRecoveredIdentity(restored);
      await _mlsCrypto?.activateSession(restored);
      await _clearDeviceListAnchorJournal(restored);
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      final records = await localStore.pendingEnvelopeRecords();
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      _setOutboxRecords(records);
      for (final envelope in pendingOutbox) {
        _outboxStates[envelope.idempotencyKey] = OutboxDeliveryState.failed;
      }
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      await _reloadStoredDrafts();
      _mutes
        ..clear()
        ..addAll(await localStore.loadConversationMutes());
      conversationPrefs = {
        for (final p in await localStore.loadConversationPrefs())
          p.conversationId: p
      };
      mentionsInMutedChats =
          await localStore.loadSetting('w8.mentions_muted') != 'false';
      linkPreviewMode = linkPreviewModeFromName(
          await localStore.loadSetting('b2.link_preview'));
      screenGuardChats =
          await localStore.loadSetting('screen_guard_chats') != 'false';
      _updateScreenGuard();
      _armMuteTimer();
      final copied = await localStore.loadHistoryNamespace();
      if (!_lifecycleGenerationActive(transitionGeneration)) return;
      // Assigned only after the generation check, so a sign-out during the
      // read never brings the previous account's titles back.
      _copiedHistory = Map.of(copied.conversations);
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
              preserveDeviceIdentity: true,
              keepDrafts: true,
              preserveOutbox: true);
          return;
        }
        // Keep the encrypted cache available while offline.
      } catch (_) {
        // Keep the encrypted cache available while offline.
      }
      unawaited(_startSync());
      unawaited(_ensureKeyPackageSupply().catchError((Object _) {}));
      unawaited(_scheduleExpiryPurge());
      unawaited(resumeHistoryTransfers());
      await _loadSignedInRecoveryState();
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
      case LocalStoreFailureKind.sqliteFeatureMissing:
        return l10n.recoverySqliteFeatureMissing;
    }
  }

  /// Why the encrypted local database could not be opened (I39), or null.
  LocalStoreFailureKind? localStoreFailure;

  /// Sync found the open local database damaged (corrupt or not a
  /// database); see [_enterDamagedStorageRecovery].
  bool _localDataDamaged = false;

  /// Signing in cannot work while the local database is unreadable, so the
  /// recovery screen offers it only for other restore failures.
  bool get canContinueWithoutRestore =>
      localStoreFailure == null && !_localDataDamaged;

  /// A reset moves the database and its key aside (it never deletes them),
  /// so it is always reachable and the user is never stuck. An upgrade that
  /// ran out of space leaves a readable database, though, and freeing space
  /// and retrying is the fix: the reset is offered for it only once a retry
  /// has failed the same way again.
  bool get canResetLocalData {
    if (_localDataDamaged) return true;
    final failure = localStoreFailure;
    if (failure == null) return false;
    if (failure == LocalStoreFailureKind.upgradeStorageFull) {
      return _storageFullFailures > 1;
    }
    // Moving the database aside would not give this build the feature.
    return failure != LocalStoreFailureKind.sqliteFeatureMissing;
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
        // The MLS outbox these marks follow went with the database.
        _mlsAcceptedUnfinished.clear();
        localStoreFailure = null;
        _localDataDamaged = false;
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
      Uint8List? genesis;
      final created = await api!.createOwner(
        username: username,
        password: password,
        deviceName: config.deviceName,
        enrollment: enrollment,
        credential: credential,
        setupToken: setupToken,
        deviceList: genesis = await _signGenesis(enrollment),
      );
      if (genesis != null) await _journalDeviceListAnchor(created, [genesis]);
      await _oweInitialKeyPackages(created);
      await localStore.saveSession(created);
      await _resumeDeviceListAnchor(created);
      await _mlsCrypto?.activateSession(created);
      await _clearDeviceListAnchorJournal(created);
      session = created;
      await localStore.saveSyncCursor(0);
      await _finishSignIn(() async {
        await _publishInitialMlsKeyPackages();
        await _refreshConversations(notify: true);
        await _refreshDevices();
      });
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
        throw UserFacingException(l10n.errorPasswordLoginNeedsLink);
      }
      // Read before saving the new session: a different identity wipes the
      // MLS state with it.
      final hadMlsState = await localStore.loadCryptoState() != null;
      session = await api!.login(
        username: username,
        password: password,
        deviceId: deviceId,
        deviceSecret: deviceSecret,
      );
      await _finishDeviceSignIn(localSession!, hadMlsState);
    });
  }

  /// The steps after a sign-in on an enrolled device, shared by the password
  /// and the passkey paths: [session] is the server's answer, [localSession]
  /// the device identity stored before it, [hadMlsState] whether MLS state
  /// existed before the answer was saved.
  Future<void> _finishDeviceSignIn(
      Session localSession, bool hadMlsState) async {
    {
      final signedIn = session!;
      session = null;
      final sameIdentity = localSession.accountId != null &&
          localSession.baseUrl == signedIn.baseUrl &&
          localSession.accountId == signedIn.accountId &&
          localSession.deviceId == signedIn.deviceId;
      await localStore.saveSession(signedIn);
      await _resumeDeviceListAnchor(signedIn);
      await _reloadStoredDrafts();
      await _mlsCrypto?.activateSession(signedIn);
      await _clearDeviceListAnchorJournal(signedIn);
      session = signedIn;
      // The same device signing in again keeps its cursor: it was committed
      // with the MLS state, and replaying from event 0 would meet commits
      // and messages that state has already consumed (I33 stops sync on
      // them after a restore) or loop on a page of applied events.
      if (!sameIdentity || !hadMlsState) {
        await localStore.saveSyncCursor(0);
      }
      await _finishSignIn(() async {
        await _refreshConversations(notify: true);
        await _refreshDevices();
        await _ensureKeyPackageSupply();
      });
    }
  }

  /// The network steps after a sign-in: [steps] runs once the session is
  /// saved and MLS is active. Sync starts even when a step fails, so a
  /// signed-in app is never left without it; the error is still rethrown
  /// for [_run] to report. A rejected session (401) starts nothing: [_run]
  /// clears it.
  Future<void> _finishSignIn(Future<void> Function() steps) async {
    unawaited(_loadSignedInRecoveryState());
    unawaited(resumeHistoryTransfers());
    try {
      await steps();
    } catch (err) {
      if (err is! ApiException ||
          err.statusCode != 401 ||
          err.serverCode == 'invalid_credentials') {
        unawaited(_startSync());
      }
      rethrow;
    }
    unawaited(_startSync());
  }

  /// Puts the drafts kept through a session expiry back into the composer.
  /// A different identity never reaches here with drafts: saving its session
  /// deletes them.
  Future<void> _reloadStoredDrafts() async {
    composerDrafts.load({
      for (final entry in (await localStore.loadDrafts()).entries)
        entry.key: (text: entry.value.text, replyTo: entry.value.replyTo),
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
    final generation = _sessionGeneration;
    // A refresh started by a session that has since ended or been replaced
    // reports nothing to its successor, success or failure (TASK-027).
    bool owned() => current != null && _refreshOwned(current, generation);
    try {
      await load();
      if (owned() && _opErrors.remove(op) != null) notifyListeners();
    } catch (err) {
      if (!owned()) return;
      if (err is ApiException &&
          err.statusCode == 401 &&
          identical(session, current)) {
        await _enqueueSessionTransition(() async {
          if (!identical(session, current)) return;
          await _clearLocalSession(
              preserveDeviceIdentity: true,
              keepDrafts: true,
              preserveOutbox: true);
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
    final generation = _sessionGeneration;
    try {
      final list = await client.devices(current.token);
      if (!_refreshOwned(current, generation)) return;
      devices = list;
      _opErrors.remove(Ops.devices);
      // L1 repair: take revoked siblings off the list. Never blocks.
      unawaited(_repairDeviceList(list).catchError((Object _) {}));
      unawaited(_retryRecoveryDeviceList().catchError((Object _) {}));
      unawaited(_refreshOwnListState().catchError((Object _) {}));
    } finally {
      if (_refreshOwned(current, generation)) devicesLoaded = true;
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
    final generation = _sessionGeneration;
    List<Invite>? list;
    try {
      list = await client.listInvites(current.token);
    } catch (_) {
      // Not surfaced here: invite listing is a privilege, not a core flow.
    }
    // A reply for a session that has since ended or been replaced is
    // dropped whole, success or failure.
    if (!_refreshOwned(current, generation)) return;
    if (list != null) invites = list;
    invitesLoadFailed = list == null;
    invitesLoaded = true;
    notifyListeners();
  }

  /// Whether a refresh that started under [current] at [generation] may
  /// still publish: that session is the live one.
  bool _refreshOwned(Session current, int generation) =>
      !_disposed && _syncOwnerActive(current, generation);

  /// Refreshes communities (and their channels) the account belongs to.
  /// Best-effort for the same reason as [refreshInvites].
  Future<void> refreshCommunities() async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    final generation = _sessionGeneration;
    try {
      final list = await client.listCommunities(current.token);
      final channels = <String, List<Channel>>{};
      for (final community in list) {
        if (!_refreshOwned(current, generation)) return;
        try {
          channels[community.id] =
              await client.listChannels(current.token, community.id);
        } catch (_) {
          if (!_refreshOwned(current, generation)) return;
          channels[community.id] =
              channelsByCommunity[community.id] ?? const <Channel>[];
        }
      }
      if (!_refreshOwned(current, generation)) return;
      communities = list;
      channelsByCommunity = channels;
    } catch (_) {
      // Keep the locally-known records if the server can't list right now.
    }
    // Nothing from a session that has since ended or been replaced.
    if (!_refreshOwned(current, generation)) return;
    communitiesLoaded = true;
    notifyListeners();
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
    final generation = _sessionGeneration;
    // Everything is read first and published only while the session that
    // asked is still the live one. A stale reply, or its error, is dropped
    // without a trace.
    final List<Conversation> list;
    final List<LocalConversationPref> prefs;
    final String? mentionsMuted;
    final String? previewMode;
    final String? screenGuardPref;
    try {
      list = await client.conversations(current.token);
      prefs = await localStore.loadConversationPrefs();
      mentionsMuted = await localStore.loadSetting('w8.mentions_muted');
      previewMode = await localStore.loadSetting('b2.link_preview');
      screenGuardPref = await localStore.loadSetting('screen_guard_chats');
    } catch (_) {
      if (!_refreshOwned(current, generation)) return;
      rethrow;
    }
    if (!_refreshOwned(current, generation)) return;
    conversations = list;
    _conversationsFromServer = true;
    conversationPrefs = {for (final p in prefs) p.conversationId: p};
    mentionsInMutedChats = mentionsMuted != 'false';
    linkPreviewMode = linkPreviewModeFromName(previewMode);
    screenGuardChats = screenGuardPref != 'false';
    _updateScreenGuard();
    await _loadRequestState(grandfather: false);
    if (!_refreshOwned(current, generation)) return;
    // The server's list is the truth: a conversation no longer in it (an
    // admin removed this account, say) keeps no draft here.
    composerDrafts.retainOnly(conversations.map((item) => item.id));
    conversationsLoaded = true;
    _opErrors.remove(Ops.conversations);
    if (_recoveredDevice) {
      await _refreshGroupless(conversations.map((item) => item.id));
      if (!_refreshOwned(current, generation)) return;
    }
    if (persist) await _persistSnapshot();
    if (!_refreshOwned(current, generation)) return;
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
    // When the fresh page meets what is cached, the older pages already
    // merged in stay reachable, so the deepest cursor (null once history is
    // exhausted) still applies. A gap rewinds to the fresh page's cursor so
    // the missing messages are fetched.
    final overlaps = existing.any((message) => fresh.contains(message.id));
    if (!overlaps ||
        older.isEmpty ||
        !_historyCursors.containsKey(conversationId)) {
      _historyCursors[conversationId] = page.nextBefore;
    }
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
      // Read only what is on screen: not a conversation the user has since
      // left, and nothing while the app is in the background.
      if (selectedConversationId == conversationId && _isForeground) {
        unawaited(markNewestMessageRead(conversationId));
      }
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
      // W11: a new group's name goes into its encrypted profile, not into
      // the server's plaintext `title` column.
      final groupName =
          kind == 'group' && profiles != null ? title?.trim() : null;
      final encryptedName = groupName != null && groupName.isNotEmpty;
      created = await client.createConversationDetailed(
        current.token,
        kind: kind,
        title: encryptedName ? null : title,
        communityId: communityId,
        channelId: channelId,
        memberAccountIds: memberAccountIds,
        retentionSeconds: retentionSeconds,
      );
      final conversation = created!;
      // The server hands back the existing DM for a pair instead of making a
      // second one, and says so with 200 instead of 201 (D67). Its group was
      // built by whoever created it (the peer, or another device of this
      // account), and this device joins it through that Welcome; one whose
      // group this device already holds needs nothing either. Only a new
      // conversation gets a group here. The creator and local-group checks
      // stay for a server that answers 201 either way.
      final mls = _mlsCrypto;
      final existingDm = conversation.isDm &&
          (conversation.existedOnServer ||
              (conversation.createdBy != null &&
                  conversation.createdBy != current.accountId) ||
              (mls != null && await mls.groupEpoch(conversation.id) != null));
      if (!existingDm) await _setUpConversationGroup(conversation.id);
      conversations = <Conversation>[
        conversation,
        ...conversations.where((item) => item.id != conversation.id),
      ];
      if (conversation.isDm) await _acceptConversation(conversation);
      if (encryptedName && conversation.isGroup) {
        // Not awaited: the name appears when the upload is accepted, and a
        // key message that cannot be queued yet is retried by the service.
        unawaited(profiles!
            .saveGroupProfile(conversation.id, name: groupName)
            .catchError((Object _) {}));
      }
      selectedConversationId = conversation.id;
      messagesByConversation.putIfAbsent(
          conversation.id, () => <ReceivedMessageEnvelope>[]);
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
      Uint8List? genesis;
      final created = await api!.register(
        inviteCode: inviteCode,
        username: username,
        password: password,
        deviceName: config.deviceName,
        enrollment: enrollment,
        credential: credential,
        deviceList: genesis = await _signGenesis(enrollment),
      );
      if (genesis != null) await _journalDeviceListAnchor(created, [genesis]);
      await _oweInitialKeyPackages(created);
      await localStore.saveSession(created);
      await _resumeDeviceListAnchor(created);
      await _mlsCrypto?.activateSession(created);
      await _clearDeviceListAnchorJournal(created);
      session = created;
      await localStore.saveSyncCursor(0);
      await _finishSignIn(() async {
        await _publishInitialMlsKeyPackages();
        await _refreshConversations(notify: true);
        await _refreshDevices();
      });
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
      if (created!.createdBy == null) {
        created = Community(
          id: created!.id,
          name: created!.name,
          createdBy: current.accountId,
          createdAt: created!.createdAt,
          sharedConversationId: created!.sharedConversationId,
        );
      }
      communities = <Community>[created!, ...communities];
      // A community with the C0 layout starts with its shared group, which
      // this device creates now; channels in it need no group of their own.
      final shared = created!.sharedConversationId;
      if (shared != null) {
        await _setUpConversationGroup(shared);
        await refreshConversations();
      }
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
      if (!canCreateChannel(communityId)) {
        throw ApiException(403,
            '{"error":"forbidden","message":"Only admins can create channels"}');
      }
      final sharedLayout = communities
              .where((community) => community.id == communityId)
              .firstOrNull
              ?.sharedConversationId !=
          null;
      final creation = await client.createChannel(
        current.token,
        communityId,
        name,
        kind: sharedLayout ? 'open' : 'private',
      );
      final inSharedGroup = creation.conversation.isCommunityShared;
      // An open channel posts into the community's existing group.
      if (!inSharedGroup) {
        await _setUpConversationGroup(creation.conversation.id);
      }
      channelsByCommunity = <String, List<Channel>>{
        ...channelsByCommunity,
        communityId: <Channel>[
          creation.channel,
          ...channelsByCommunity[communityId] ?? const <Channel>[],
        ],
      };
      // The shared group keeps the entry the list already has for it.
      final known =
          conversations.any((item) => item.id == creation.conversation.id);
      if (!inSharedGroup || !known) {
        conversations = <Conversation>[
          creation.conversation,
          ...conversations.where((item) => item.id != creation.conversation.id),
        ];
      }
      selectedConversationId = creation.conversation.id;
      if (inSharedGroup) {
        selectChannel(creation.conversation.id, creation.channel.id);
      }
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
      // K0 step 8: an added member's devices join only through a commit by
      // a group device, and here there is none: the add would wait forever.
      final refusal = await _noPeerRefusal(conversationId);
      if (refusal != null) throw UserFacingException(refusal);
      await client.addConversationMember(
        current.token,
        conversationId,
        accountId,
        role: role,
      );
      // Their devices join the MLS group through reconcile (card I51). The
      // change is new, so an earlier one's backoff does not hold it.
      _mlsReconcileRequested = true;
      _mlsReconcileNow.add(conversationId);
      _mlsChangeRetries.remove(conversationId);
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
      _noteRosterPeers(conversationId);
    });
  }

  /// Removes another member. The server drops the membership at once; their
  /// devices leave the MLS group through a separate commit that reconcile
  /// stages and sends (card I51). Until this device has applied that commit,
  /// application sends to the conversation wait unencrypted and then go out
  /// in order (D68), so nothing is encrypted to the removed devices.
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
      if (!membershipChangesAvailable) {
        throw StateError('removing members is not available in this build');
      }
      await client.removeConversationMember(
        current.token,
        conversationId,
        accountId,
      );
      await _afterMemberRemoved(conversationId, accountId);
      membersByConversation = <String, List<ConversationMember>>{
        ...membersByConversation,
        conversationId: membersFor(conversationId)
            .where((member) => member.accountId != accountId)
            .toList(growable: false),
      };
    });
  }

  /// What follows the server dropping [accountId] from [conversationId]:
  /// sends wait for the removal commit (D68) and reconcile stages it (card
  /// I51). Also used for each channel when a community removes a member.
  Future<void> _afterMemberRemoved(
      String conversationId, String accountId) async {
    // D68: hold sends until the removal commit is applied. Reconcile
    // releases the hold; without MLS nothing would, and nothing is
    // encrypted to a group either. The session queue keeps sends out
    // until the hold is set.
    final mls = _mlsCrypto;
    if (mls != null) {
      final generation = _sessionGeneration;
      await _loadRemovalHolds();
      ({int epoch, bool pending})? local;
      var unreadable = false;
      try {
        local = await mls.groupEpoch(conversationId);
      } catch (_) {
        // Held anyway, at epoch 0: reconcile releases it once the group
        // is readable again, or drops it when there is no local group.
        unreadable = true;
      }
      if (generation == _sessionGeneration && (local != null || unreadable)) {
        final epoch = local?.epoch ?? 0;
        final hold = _removalHolds.putIfAbsent(
            conversationId, () => _RemovalHold(epoch: epoch));
        hold
          ..seq = ++_removalHoldSeq
          // A read before this removal proves nothing about its commit.
          ..unlistedAt = null
          ..accounts.add(accountId);
        if (epoch > hold.epoch) hold.epoch = epoch;
        await _saveRemovalHolds();
        _removalHoldsUpdated();
      }
    }
    // Their devices leave the MLS group through reconcile (card I51). The
    // change is new, so an earlier one's backoff does not hold it.
    _mlsReconcileRequested = true;
    _mlsReconcileNow.add(conversationId);
    _mlsChangeRetries.remove(conversationId);
    unawaited(_catchUpSyncEvents());
  }

  /// Leaves a conversation and drops its local state.
  Future<bool> leaveConversation(String conversationId) {
    return _runScoped(Ops.members, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      final leaveEventId = await client.removeConversationMember(
        current.token,
        conversationId,
        'me',
      );
      await _dropLeftConversationLocally(current, conversationId, leaveEventId);
    });
  }

  /// Drops the local state of a conversation the server has just taken this
  /// account out of: after leaving it, and after leaving its community.
  Future<void> _dropLeftConversationLocally(
    Session current,
    String conversationId,
    int? leaveEventId,
  ) async {
    // A pause (C1 P1) stays until the group is dropped, so a pass that
    // already holds later events of the conversation still holds them
    // back ([_dropLeftConversations] lifts it). Without that drop there
    // is nothing to wait for.
    if (_mlsCrypto is! MlsStateMaintenanceCryptoService) {
      await _dropConversationPause(conversationId);
    }
    conversations = conversations
        .where((conversation) => conversation.id != conversationId)
        .toList(growable: false);
    _profileConversationLeft(conversationId);
    // Sends held for a removal there (D68) end: the conversation is gone.
    if (_removalHolds.remove(conversationId) != null) {
      await _saveRemovalHolds();
    }
    _removalHoldsUpdated();
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
    await _afterLeftConversation(current, conversationId, leaveEventId);
  }

  /// The user left [conversationId] (D70 S4). Its unsent messages can no
  /// longer go, so they are dropped. Its MLS group is dropped by the next
  /// foreground sync pass, before it reads events ([_dropLeftConversations]):
  /// a pass already under way may still apply events of the conversation
  /// from before the leave, and the server sends none after it. The note is
  /// durable, so a restart still drops the group. A local failure here does
  /// not undo or fail the leave.
  Future<void> _afterLeftConversation(
      Session current, String conversationId, int? leaveEventId) async {
    try {
      for (final record in await localStore.pendingEnvelopeRecords()) {
        if (record.envelope.conversationId == conversationId) {
          await _removeFromOutboxByKey(record.envelope.idempotencyKey);
        }
      }
    } catch (_) {
      // Left queued, they fail at the server, which no longer takes them.
    }
    if (_mlsCrypto is! MlsStateMaintenanceCryptoService) return;
    // Before the note, so a Welcome from before the leave that a pass
    // under way applies later already finds it ([_skipWelcomeBeforeLeave]).
    await _noteLeaveFloor(current, conversationId, leaveEventId);
    try {
      await _changeLeftConversations(
          current, (ids) => <String>{...ids, conversationId});
    } catch (_) {
      // Not noted: the group stays until a removal commit or the user
      // leaves again. Nothing is weaker for it.
      return;
    }
    unawaited(_catchUpSyncEvents());
  }

  // Conversations the user left whose MLS group is still to be dropped
  // (D70 S4). One local setting, scoped to the origin, account and device
  // like [_keyPackageNeedSetting]; a record of another identity counts as
  // nothing. Only [leaveConversation], a user action, adds to it.
  static const _leftConversationsSetting = 'mls.left_conversations';

  /// Most conversations the record holds (D38's default conversation cap).
  static const _leftConversationsCap = 1000;
  Future<void> _leftConversationsLock = Future<void>.value();

  Future<Set<String>> _readLeftConversations(Session owner) async {
    final raw = await localStore.loadSetting(_leftConversationsSetting);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final record = jsonDecode(raw);
      if (record is! Map || record['scope'] != _keyPackageScope(owner)) {
        return <String>{};
      }
      final ids = record['ids'];
      return ids is List
          ? <String>{...ids.whereType<String>().where((id) => id.isNotEmpty)}
          : <String>{};
    } on FormatException {
      return <String>{};
    }
  }

  /// One read-modify-write of [owner]'s record; they never interleave.
  /// Returns the set as stored.
  Future<Set<String>> _changeLeftConversations(
      Session owner, Set<String> Function(Set<String> ids) change) {
    final done = _leftConversationsLock.then((_) async {
      final current = await _readLeftConversations(owner);
      final next = change(current);
      if (!setEquals(current, next)) {
        await localStore.saveSetting(
            _leftConversationsSetting,
            jsonEncode(<String, Object?>{
              'scope': _keyPackageScope(owner),
              // The newest leaves are kept at the cap.
              'ids': next
                  .skip(max(0, next.length - _leftConversationsCap))
                  .toList(growable: false),
            }));
      }
      return next;
    });
    _leftConversationsLock =
        done.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return done;
  }

  // The newest sync event id that came before each leave (D70 follow-up).
  // A pass may still hold, or fetch later, an add-Welcome from before the
  // leave; applying it would rejoin the group the leave dropped, with the
  // note already cleared. A Welcome at or below its conversation's floor is
  // skipped instead. Same scope rule as the note; kept in its own setting
  // because it must outlive the note, which the group drop clears.
  static const _leftFloorsSetting = 'mls.left_floors';
  Future<void> _leftFloorsLock = Future<void>.value();

  /// The newest event id the current pass has fetched (reset to the
  /// committed cursor when a pass starts). A leave that cannot ask the
  /// server uses it: the pass may hold events up to it that are not
  /// committed yet, and it is never above the leave's own event.
  int _syncFetchedThrough = 0;

  /// The [_sessionGeneration] [_syncFetchedThrough] was recorded under. A
  /// pass of another session (sign-out, account switch) says nothing about
  /// this one's events, so a mismatch ignores the value.
  int _syncFetchedGeneration = -1;

  Future<Map<String, int>> _readLeftFloors(Session owner) async {
    final raw = await localStore.loadSetting(_leftFloorsSetting);
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final record = jsonDecode(raw);
      if (record is! Map || record['scope'] != _keyPackageScope(owner)) {
        return <String, int>{};
      }
      final floors = record['floors'];
      if (floors is! Map) return <String, int>{};
      return <String, int>{
        for (final entry in floors.entries)
          if (entry.key is String &&
              (entry.key as String).isNotEmpty &&
              entry.value is int &&
              (entry.value as int) > 0)
            entry.key as String: entry.value as int,
      };
    } on FormatException {
      return <String, int>{};
    }
  }

  /// One read-modify-write of [owner]'s floors; they never interleave.
  /// A floor at or below the committed sync cursor is dropped: a pass skips
  /// every event at or below the cursor, so it can no longer matter.
  Future<void> _changeLeftFloors(
      Session owner, void Function(Map<String, int> floors) change) {
    final done = _leftFloorsLock.then((_) async {
      final current = await _readLeftFloors(owner);
      final cursor = await localStore.loadSyncCursor();
      final next = <String, int>{
        for (final entry in current.entries)
          if (entry.value > cursor) entry.key: entry.value,
      };
      change(next);
      next.removeWhere((_, floor) => floor <= cursor);
      if (!mapEquals(current, next)) {
        // The newest leaves are kept at the cap.
        final keep = next.entries
            .toList(growable: false)
            .skip(max(0, next.length - _leftConversationsCap));
        await localStore.saveSetting(
            _leftFloorsSetting,
            jsonEncode(<String, Object?>{
              'scope': _keyPackageScope(owner),
              'floors': <String, int>{
                for (final entry in keep) entry.key: entry.value,
              },
            }));
      }
    });
    _leftFloorsLock =
        done.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return done;
  }

  /// Notes the floor for the leave of [conversationId]: the sync event id
  /// at or below which a Welcome for this device predates the leave.
  ///
  /// [leaveEventId] is the server's own id of the leaver's `membership.left`
  /// event, from the leave response. Welcomes are stored only for member
  /// devices, in the transaction that adds them, so every Welcome with a
  /// lower id came before the leave and any higher id is a real re-add: the
  /// floor is exact and a re-add is never skipped. A server that reports no
  /// id (an older one) is asked for its newest event id instead
  /// (`latest_event_id`, at or above the leave's own event, so at or above
  /// every older one; the sync cursor alone is not, a pass can hold fetched
  /// events beyond it). Where that fails too, the newest id the running pass
  /// of this session fetched stands in (covering the page it holds, not
  /// events it has yet to fetch). Best effort, like the note: a failure
  /// leaves the leave as it was.
  Future<void> _noteLeaveFloor(
      Session current, String conversationId, int? leaveEventId) async {
    try {
      int floor;
      if (leaveEventId != null && leaveEventId > 0) {
        floor = leaveEventId;
      } else {
        final fetched = passFetchedFloor(
          fetchedThrough: _syncFetchedThrough,
          fetchedGeneration: _syncFetchedGeneration,
          sessionGeneration: _sessionGeneration,
        );
        floor = max(await localStore.loadSyncCursor(), fetched);
        final client = api;
        if (client != null) {
          try {
            final latest = await client
                .syncLatestEventId(current.token)
                .timeout(const Duration(seconds: 5));
            floor = max(floor, latest);
          } catch (_) {
            // The cursor and the pass's fetched page stand in for it.
          }
        }
      }
      await _changeLeftFloors(current, (floors) {
        floors[conversationId] = max(floors[conversationId] ?? 0, floor);
      });
    } catch (_) {
      // Not noted: an older Welcome applied after the leave keeps the
      // group until the user leaves again.
    }
  }

  /// A Welcome for this device from before the user's leave of its
  /// conversation is skipped: the cursor moves past it and nothing is
  /// joined, as for a Welcome the device cannot open (D74). The key package
  /// it used is still replaced. Returns whether it was skipped.
  Future<bool> _skipWelcomeBeforeLeave(
      Session current, SyncEvent event, MlsMessage message,
      {required WakeRunContext? wake,
      required SyncEventFailure Function(SyncFailureKind kind, [Object? cause])
          failure}) async {
    try {
      final floor = (await _readLeftFloors(current))[message.conversationId];
      if (floor == null || event.id > floor) return false;
      await _oweKeyPackages(current, 1, welcome: message.id);
      await localStore.commitSyncEvent(SyncEventCommit(
        eventKey: 'sync:${event.id}',
        conversationId: message.conversationId,
        expectedCursor: await localStore.loadSyncCursor(),
        cursor: event.id,
        checkCanCommit: wake?.checkCanCommit,
      ));
    } on WakeWorkCancelled {
      rethrow;
    } catch (err) {
      if (_isTransientSyncError(err)) rethrow;
      throw failure(SyncFailureKind.localStorage, err);
    }
    if (wake != null) {
      // Publishing is an outbound write; the foreground does it.
      _replenishAfterWake = true;
    } else {
      await _replenishKeyPackage();
    }
    return true;
  }

  /// Drops the MLS group of every conversation the user left (D70 S4), and
  /// with it that conversation's queued MLS control messages. Runs inside
  /// a foreground sync pass before it reads events, so no event of the
  /// conversation is being applied meanwhile. Best effort: a failure keeps
  /// the note for the next pass and never stops sync.
  Future<void> _dropLeftConversations(
      Session current, int ownerGeneration) async {
    final Object? mls = _mlsCrypto;
    if (mls is! MlsStateMaintenanceCryptoService) return;
    final Set<String> left;
    try {
      left = await _readLeftConversations(current);
    } catch (_) {
      return;
    }
    for (final conversationId in left) {
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      try {
        await mls.deleteConversationState(conversationId);
        await _changeLeftConversations(
            current, (ids) => ids.difference(<String>{conversationId}));
        // The group is gone, and the server sends nothing more for it: a
        // pause of the conversation (C1 P1) has nothing left to hold.
        await _dropConversationPause(conversationId);
      } catch (err) {
        // Body-free: no conversation id.
        developer.log('mls_left_group_drop_failed ${err.runtimeType}',
            name: 'veritra.sync');
      }
    }
  }

  /// A Welcome to this device for a conversation the user left whose group
  /// was not dropped yet (D70 S4): the user's own deferred leave runs first,
  /// so the old group never blocks the new join, and the note is cleared
  /// only by that drop, never by a join (a D74 Welcome joins nothing). A
  /// failed drop stops sync at this event with Retry, as a storage failure;
  /// a background pass hands the event to the foreground.
  Future<void> _dropLeftBeforeWelcome(Session current, String conversationId,
      {required WakeRunContext? wake,
      required SyncEventFailure Function(SyncFailureKind kind, [Object? cause])
          failure}) async {
    final Object? mls = _mlsCrypto;
    if (mls is! MlsStateMaintenanceCryptoService) return;
    try {
      if (!(await _readLeftConversations(current)).contains(conversationId)) {
        return;
      }
      if (wake != null) throw const WakeWorkCancelled();
      await mls.deleteConversationState(conversationId);
      await _changeLeftConversations(
          current, (ids) => ids.difference(<String>{conversationId}));
    } on WakeWorkCancelled {
      rethrow;
    } catch (err) {
      if (_isTransientSyncError(err)) rethrow;
      throw failure(SyncFailureKind.localStorage, err);
    }
  }

  /// How often a caught-up foreground pass drops expired key packages
  /// (D70 S4). They expire over days; replenishment also prunes first, so
  /// a full pool never waits for this.
  static const _keyPackagePruneInterval = Duration(hours: 6);
  DateTime? _keyPackagePruneAt;

  Future<void> _maybePruneKeyPackages() async {
    final Object? mls = _mlsCrypto;
    if (mls is! MlsStateMaintenanceCryptoService) return;
    final now = DateTime.now();
    final due = _keyPackagePruneAt;
    if (due != null && now.isBefore(due)) return;
    // Set first: a failure waits for the next interval too.
    _keyPackagePruneAt = now.add(_keyPackagePruneInterval);
    try {
      await mls.pruneExpiredKeyPackages(now);
    } catch (err) {
      developer.log('mls_key_package_prune_failed ${err.runtimeType}',
          name: 'veritra.sync');
    }
  }

  Future<void> refreshBlocks() async {
    final current = session;
    final client = api;
    if (current == null || client == null) {
      return;
    }
    await _runScoped(Ops.blocks, () async {
      final previous = blockedAccounts.map((block) => block.accountId).toSet();
      blockedAccounts = await client.listBlocks(current.token);
      for (final block in blockedAccounts) {
        if (!previous.contains(block.accountId)) {
          _profileAccountBlocked(block.accountId);
        }
      }
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
      _profileAccountBlocked(accountId);
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
    if (current == null || client == null || sessionEnding) {
      return false;
    }
    final ends = _sessionEnds;
    try {
      final mute = await client.conversationMute(current.token, conversationId);
      // A reply that lands during or after a sign-out belongs to the old
      // session; storing it would leave a row behind the wipe.
      if (ends != _sessionEnds || sessionEnding || session == null)
        return false;
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
      final ends = _sessionEnds;
      final applied = await client.setConversationMute(
        current.token,
        conversationId,
        muted: duration != MuteDuration.off,
        forDuration: length,
      );
      if (ends != _sessionEnds || sessionEnding || session == null) return;
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

  /// Writes every pending draft and waits for the writes. Runs while the
  /// session that owns the drafts is still current, before a session end
  /// clears local data (D65): an expired session keeps the newest text, and
  /// sign-out wipes it with the rest instead of a late timer writing it back.
  Future<void> _flushDraftsBeforeSessionEnd() async {
    final pending = _draftTimers.keys.toList(growable: false);
    _cancelDraftTimers();
    for (final id in pending) {
      await _persistDraft(id);
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
      notifyListeners();
    });
  }

  Future<void> setPostingPolicy(String conversationId, String policy) async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      final updated = await client.setPostingPolicy(
        current.token,
        conversationId,
        policy,
      );
      conversations = [
        for (final c in conversations)
          if (c.id == updated.id)
            c.copyWith(postingRestricted: updated.postingRestricted)
          else
            c,
      ];
      notifyListeners();
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
      // account's own cursor for the unread count and shares nothing. The
      // same holds while the saved choice cannot be read.
      await receiptPreferences.loaded;
      // The app may have gone to the background while the choice was read.
      if (!_isForeground) return;
      if (receiptPreferences.shareReadReceipts) {
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
  ///
  /// The paging runs outside the session queue, so sends and sign-out never
  /// wait behind it. It belongs to the session it started under: once that
  /// session ends or changes, the export stops, leaves no file and sets no
  /// error or busy state on whatever session comes next.
  Future<String?> exportAccount() async {
    final owner = session;
    final client = api;
    if (owner == null || client == null) {
      return null;
    }
    final ends = _sessionEnds;
    bool owns() =>
        !_disposed &&
        ends == _sessionEnds &&
        _sessionsEnding == 0 &&
        _sameSession(owner);
    if (!owns()) return null;
    busy = true;
    error = null;
    notifyListeners();
    try {
      return await _writeAccountExport(client, owner.token, owns);
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) {
        // Cleared through the queue, and only while the session that got
        // the 401 is still the current one.
        await _enqueueSessionTransition(() async {
          if (!owns()) return;
          await _clearLocalSession(
              preserveDeviceIdentity: true,
              keepDrafts: true,
              preserveOutbox: true);
          error = describeError(err, l10n);
        });
      } else if (owns()) {
        error = describeError(err, l10n);
      }
      return null;
    } finally {
      // A queued action running now owns the busy flag and clears it itself.
      if (_runsActive == 0) busy = false;
      notifyListeners();
    }
  }

  /// The paging and file work of [exportAccount]. [owns] is checked after
  /// every await, before its result is used: an export whose session ended
  /// returns null, and the finally removes its '.part' file.
  Future<String?> _writeAccountExport(
      ApiClient client, String token, bool Function() owns) async {
    final directory = await getApplicationDocumentsDirectory();
    if (!owns()) return null;
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
        if (!owns()) return null;
        if (pageCount >= 2000) {
          throw StateError('Account export has too many pages');
        }
        final page = await client.exportAccountPage(
          token,
          limit: 250,
          before: before,
        );
        if (!owns()) return null;
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
      if (!owns()) return null;
      await temporaryFile.rename(file.path);
      completed = true;
      if (!owns()) {
        // The session ended during the rename: its export is not kept.
        try {
          await file.delete();
        } catch (_) {}
        return null;
      }
      return file.path;
    } finally {
      await sink?.close();
      if (!completed && await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
    }
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
    unawaited(_refreshGroupless(<String>[conversationId], force: true));
  }

  /// Encrypts, queues, and delivers one message. Scoped to [Ops.send] so a
  /// slow or failed send only affects the composer, and the queued envelope
  /// stays retryable from its pending bubble either way.
  Future<bool> sendMessageTo(String conversationId, String plaintext) {
    final body = _composedBody(conversationId, plaintext);
    if (!_wantsLinkPreview(body)) {
      return _sendPayload(conversationId, AppPayloadType.text, body,
          draftText: plaintext);
    }
    return _sendWithLinkPreview(
        conversationId, AppPayloadType.text, body, plaintext);
  }

  /// Whether an outgoing body may get a link preview (B2): the setting is
  /// not off and the text contains a link at all. Nothing is fetched here,
  /// and a body that fails this goes straight to the queue.
  bool _wantsLinkPreview(Map<String, Object?> body) {
    final text = body['text'];
    return linkPreviewMode != LinkPreviewMode.off &&
        text is String &&
        firstLinkInText(text) != null;
  }

  /// Sends [body] with a link preview when one can be built. This device
  /// fetches it, here, before encryption; the server and the receivers never
  /// see or fetch the link. Any failure sends the body unchanged. A second
  /// send for the same conversation while this one is still building is
  /// refused, so a repeated tap cannot send the same text twice.
  Future<bool> _sendWithLinkPreview(String conversationId, AppPayloadType type,
      Map<String, Object?> body, String draftText) async {
    final owner = session;
    final generation = _sessionGeneration;
    if (owner == null || !_previewPending.add(conversationId)) return false;
    notifyListeners();
    var sendable = body;
    try {
      final preview =
          await linkPreviews.build(body['text'] as String, linkPreviewMode);
      if (preview != null) sendable = bodyWithLinkPreview(body, preview);
    } catch (_) {
      // No preview: the message goes out as written.
    } finally {
      _previewPending.remove(conversationId);
      notifyListeners();
    }
    // A sign-out or account switch during the fetch ends this send.
    if (_disposed || !_syncOwnerActive(owner, generation)) return false;
    return _sendPayload(conversationId, type, sendable, draftText: draftText);
  }

  Map<String, Object?> _composedBody(String id, String text) =>
      composeMessage(text, accountsByUsername: {
        for (final m in membersFor(id))
          if (m.username != null) m.username!: m.accountId
      });

  /// Replies to the message with local history key [targetKey] (D22).
  Future<bool> replyTo(String conversationId, String targetKey, String text) {
    final body = <String, Object?>{
      ..._composedBody(conversationId, text),
      'reply_to_id': targetKey
    };
    if (!_wantsLinkPreview(body)) {
      return _sendPayload(conversationId, AppPayloadType.reply, body,
          draftText: text);
    }
    return _sendWithLinkPreview(
        conversationId, AppPayloadType.reply, body, text);
  }

  /// Replaces the text of one of this account's own messages.
  Future<bool> editMessage(
          String conversationId, String targetKey, String text) =>
      _sendPayload(conversationId, AppPayloadType.edit, <String, Object?>{
        'message_id': targetKey,
        ..._composedBody(conversationId, text)
      });

  Future<bool> pinMessage(String conversationId, String targetKey,
      {required bool pinned, int durationSeconds = 604800}) async {
    await _ensureConversationAuthority(conversationId);
    if (!canPinMessages(conversationId)) return false;
    return _sendPayload(conversationId, AppPayloadType.pin, {
      'message_id': targetKey,
      'pinned': pinned,
      if (pinned) 'duration_seconds': durationSeconds
    });
  }

  /// A forward is a fresh send, with no source identity or mention metadata.
  Future<bool> forwardMessage(
      LocalMessage source, List<String> destinations) async {
    final owner = session;
    final generation = _sessionGeneration;
    if (owner == null || !_syncOwnerActive(owner, generation)) return false;
    final live = historyFor(source.conversationId).forKey(source.key);
    if (live == null ||
        live.deletedAt != null ||
        live.hiddenAt != null ||
        (live.expiresAt != null &&
            live.expiresAt! <= DateTime.now().millisecondsSinceEpoch) ||
        !const [LocalMessageKind.text, LocalMessageKind.attachment]
            .contains(live.kind)) return false;
    final targets = destinations.toSet();
    final hops = live.forwardHops ?? 0;
    if (targets.isEmpty || targets.length > (hops >= 5 ? 1 : 5)) return false;
    final nextHops = (hops + 1).clamp(1, 5);
    for (final id in targets) {
      // A shared group needs a channel; a forward names none.
      if (!conversations.any((c) => c.id == id) || _isSharedGroup(id)) {
        return false;
      }
    }
    try {
      for (final id in targets) {
        if (!_syncOwnerActive(owner, generation)) return false;
        if (live.kind == LocalMessageKind.text) {
          final format = decodeDecoration(live.formatJson);
          if (!await _sendPayload(id, AppPayloadType.text, {
            'text': live.body ?? '',
            if (format['entities'] != null) 'entities': format['entities'],
            'forwarded': {'hops': nextHops}
          })) return false;
        } else {
          final attachments = AttachmentEntry.listFromBody(live.body,
              conversationId: live.conversationId);
          if (attachments.isEmpty || attachmentService == null) return false;
          for (final attachment in attachments) {
            if (!_syncOwnerActive(owner, generation)) return false;
            final plaintext = await loadAttachment(attachment,
                conversationId: live.conversationId, memoryOnly: true);
            try {
              if (!_syncOwnerActive(owner, generation)) return false;
              if (!await _sendEncryptedAttachment(id,
                  fileName: attachment.fileName,
                  forwardedHops: nextHops,
                  prepare: (service, name, paddingLimit) =>
                      service.encryptBytes(
                          plaintext: plaintext,
                          conversationId: id,
                          attachmentActionId: _randomHexId(),
                          fileName: name,
                          mediaType: attachment.mediaType,
                          paddingLimit: paddingLimit))) return false;
            } finally {
              plaintext.fillRange(0, plaintext.length, 0);
            }
          }
        }
      }
      return _syncOwnerActive(owner, generation);
    } catch (err) {
      _opErrors[Ops.send] = describeError(err, l10n);
      notifyListeners();
      return false;
    }
  }

  /// Deletes one of this account's own messages for every member.
  Future<bool> deleteMessage(String conversationId, String targetKey) =>
      _sendPayload(conversationId, AppPayloadType.delete,
          <String, Object?>{'message_id': targetKey});

  /// Sets this account's reaction on a message; an empty [reaction] clears it.
  Future<bool> react(
          String conversationId, String targetKey, String reaction) =>
      _sendPayload(conversationId, AppPayloadType.reaction,
          <String, Object?>{'message_id': targetKey, 'reaction': reaction});

  /// Sends a poll (B3). The question and options travel inside the MLS
  /// payload; the server sees only ciphertext. False when the poll breaks
  /// the limits in `crypto/poll.dart` or the send is refused.
  Future<bool> sendPoll(String conversationId,
      {required String question,
      required List<String> options,
      required bool multipleChoice}) {
    final body = <String, Object?>{
      'question': question.trim(),
      'options': [for (final option in options) option.trim()],
      'multiple_choice': multipleChoice,
    };
    if (!isValidPollBody(body)) return Future<bool>.value(false);
    return _sendPayload(conversationId, AppPayloadType.poll, body);
  }

  /// Sets this account's vote on a poll; an empty [choices] takes it back. A
  /// vote the poll would not accept is not sent.
  Future<bool> votePoll(
      String conversationId, String pollKey, List<int> choices) {
    final poll = historyFor(conversationId).forKey(pollKey);
    final account = session?.accountId;
    if (account == null ||
        poll == null ||
        poll.kind != LocalMessageKind.poll ||
        poll.deletedAt != null ||
        poll.hiddenAt != null ||
        applyPollVote(poll.body, account, choices) == null) {
      return Future<bool>.value(false);
    }
    return _sendPayload(conversationId, AppPayloadType.pollVote,
        <String, Object?>{'message_id': pollKey, 'choices': choices});
  }

  /// Closes a poll this account sent; later votes are ignored. False when the
  /// poll is not this account's, is already closed or is gone.
  Future<bool> closePoll(String conversationId, String pollKey) {
    final poll = historyFor(conversationId).forKey(pollKey);
    final account = session?.accountId;
    if (account == null ||
        poll == null ||
        poll.kind != LocalMessageKind.poll ||
        poll.senderAccountId != account ||
        poll.deletedAt != null ||
        poll.hiddenAt != null ||
        applyPollClose(poll.body) == null) {
      return Future<bool>.value(false);
    }
    return _sendPayload(conversationId, AppPayloadType.pollClose,
        <String, Object?>{'message_id': pollKey});
  }

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
    int? forwardedHops,
  }) =>
      _sendEncryptedAttachment(conversationId,
          fileName: fileName,
          forwardedHops: forwardedHops,
          prepare: (service, name, paddingLimit) => service.encryptFile(
              sourcePath: path,
              conversationId: conversationId,
              attachmentActionId: _randomHexId(),
              fileName: name,
              mediaType: attachmentMediaType(name, mediaType),
              cancellation: cancellation,
              paddingLimit: paddingLimit));

  Future<bool> _sendEncryptedAttachment(String conversationId,
      {required String fileName,
      int? forwardedHops,
      required Future<PreparedEncryptedAttachment> Function(
              AttachmentCryptoService service, String name, int paddingLimit)
          prepare}) async {
    // Upload can take long; the channel is the one open when the send began.
    final channelId = _selectedChannels[conversationId];
    final service = attachmentService;
    final current = session;
    final client = api;
    if (service == null || _mlsCrypto == null) return false;
    if (current == null || client == null) return false;
    if (!mayPost(conversationId, channelId: channelId)) {
      _opErrors[Ops.attachment] = 'Only admins can post';
      notifyListeners();
      return false;
    }
    final ownerGeneration = _sessionGeneration;
    _busyOps.add(Ops.attachment);
    _opErrors.remove(Ops.attachment);
    notifyListeners();
    PreparedEncryptedAttachment? prepared;
    try {
      // K0 step 8: nothing is encrypted or uploaded for a conversation no
      // one can add this device to.
      final refusal = await _noPeerRefusal(conversationId);
      if (refusal != null) throw UserFacingException(refusal);
      final name = safeAttachmentName(fileName);
      // Padding stops at the server's cap, so a file just under it is not
      // refused for its padding (docs/crypto.md, attachment padding).
      prepared = await prepare(service, name, await attachmentSizeLimit());
      if (!_syncOwnerActive(current, ownerGeneration)) return false;
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
          if (forwardedHops != null) 'forwarded': {'hops': forwardedHops},
          'attachments': <Object?>[
            <String, Object?>{
              ...prepared.manifest,
              'id': uploaded.id,
              'ciphertext_size': prepared.ciphertextLength,
            },
          ],
        },
        attachmentRefs: <String>[uploaded.id],
        channelId: channelId,
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

  /// Downloads one attachment's ciphertext to a temporary file and decrypts
  /// it. By default it decrypts to a temporary plaintext file and reads that
  /// back. With [memoryOnly] (used by forwarding) it decrypts straight to
  /// bytes and creates no plaintext file. Both temporary files are deleted
  /// in `finally`, best effort: a crash or kill before then can leave them
  /// in the working directory.
  Future<Uint8List> loadAttachment(
    AttachmentEntry entry, {
    required String conversationId,
    bool memoryOnly = false,
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
      if (memoryOnly)
        return await service.decryptBytes(
            ciphertextPath: ciphertext.path, manifest: entry.manifest);
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

  /// Whether sends to [conversationId] wait for a member's removal commit
  /// (D68). The composer offers no second send meanwhile.
  bool sendHeldForRemoval(String conversationId) =>
      _removalHolds.containsKey(conversationId);

  /// Holds sends to [conversationId] as a removal would, for widget tests.
  @visibleForTesting
  void debugHoldSendsForRemoval(String conversationId) {
    _removalHolds[conversationId] = _RemovalHold(epoch: 0)
      ..seq = ++_removalHoldSeq;
    _removalHoldsUpdated();
  }

  /// Sends one payload. After a member removal (D68) it first waits, before
  /// anything is encrypted, until the removal commit is applied; sends to
  /// the same conversation then go out in the order they were made.
  Future<bool> _sendPayload(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
    String? draftText,
    String? channelId,
  }) async {
    final owner = session;
    final ownerGeneration = _sessionGeneration;
    if (owner == null) return false;
    // The channel is fixed here, before anything is awaited, so leaving the
    // chat for another channel cannot redirect a send already made. A shared
    // group without a usable channel sends nothing.
    final route = _channelRouteFor(
        conversationId, channelId ?? _selectedChannels[conversationId]);
    if (route == null && _isSharedGroup(conversationId)) return false;
    final routeChannelId = channelId ?? _selectedChannels[conversationId];
    if (restrictedPostTypes.contains(type) &&
        !mayPost(conversationId, channelId: routeChannelId)) {
      _opErrors[Ops.send] = 'Only admins can post';
      notifyListeners();
      return false;
    }
    // Every send takes its place in its conversation's line, and the next
    // one waits until this one is queued, refused or given up: a send held
    // inside the session queue cannot be overtaken by a later one.
    final previous = _heldSendTails[conversationId];
    final tail = Completer<void>();
    _heldSendTails[conversationId] = tail.future;
    try {
      // With no send ahead and no hold, it joins the session queue at once.
      var wait = previous != null || _removalHolds.containsKey(conversationId);
      if (previous != null) await previous;
      while (true) {
        if (wait &&
            !await _awaitRemovalHold(conversationId, owner, ownerGeneration)) {
          return false;
        }
        final sent = await _sendPayloadOnce(
            owner, ownerGeneration, conversationId, type, body,
            attachmentRefs: attachmentRefs, draftText: draftText, route: route);
        if (sent != null) return sent;
        wait = true;
      }
    } finally {
      tail.complete();
      if (identical(_heldSendTails[conversationId], tail.future)) {
        _heldSendTails.remove(conversationId);
      }
    }
  }

  /// Waits until [conversationId] has no removal hold. False when the
  /// session ended meanwhile; a paused conversation ends the wait too, and
  /// the send then reports the pause.
  Future<bool> _awaitRemovalHold(
      String conversationId, Session owner, int ownerGeneration) async {
    while (true) {
      if (_disposed || !_syncOwnerActive(owner, ownerGeneration)) return false;
      // A paused or departed conversation ends the wait; the attempt then
      // reports the pause or sends nothing.
      if (mlsConversationFailed(conversationId) ||
          conversationSyncPaused(conversationId) ||
          !conversations.any((item) => item.id == conversationId)) {
        return true;
      }
      final changed = _removalHoldsChanged.future;
      final bool held;
      try {
        held = await _heldForRemoval(conversationId);
      } catch (_) {
        // Unreadable outbox: the attempt checks again inside the session
        // queue, where the failure is reported and nothing is encrypted.
        return !_disposed && _syncOwnerActive(owner, ownerGeneration);
      }
      if (!held) {
        return !_disposed && _syncOwnerActive(owner, ownerGeneration);
      }
      await changed;
    }
  }

  /// Whether sends to [conversationId] must wait for a removal commit
  /// (D68): a removal this device made or the server lists, or a queued
  /// commit bundle that removes a member. A revocation's bundle does not
  /// hold sends: it removes a device, not a member, and is not settled
  /// through pending changes.
  Future<bool> _heldForRemoval(String conversationId) async {
    if (_mlsCrypto == null) return false;
    await _loadRemovalHolds();
    if (_removalHolds.containsKey(conversationId)) return true;
    for (final message in await localStore.pendingMlsMessages()) {
      if (message.conversationId != conversationId ||
          message.kind != MlsCommitBundle.kind) {
        continue;
      }
      final bundle = MlsCommitBundle.decode(message.payload);
      if (bundle.removed.isEmpty || bundle.revocationDeviceId != null) {
        continue;
      }
      // Released by reconcile once the commit is applied, not merely when
      // the bundle leaves the queue: a refused one leaves the removal open.
      _removalHolds[conversationId] = _RemovalHold(
        epoch: bundle.epoch,
        listed: true,
        seq: ++_removalHoldSeq,
      )..accounts.addAll(bundle.removed.map((item) => item.accountId));
      await _saveRemovalHolds();
      _removalHoldsUpdated();
      return true;
    }
    return false;
  }

  void _removalHoldsSettled() {
    final previous = _removalHoldsChanged;
    _removalHoldsChanged = Completer<void>();
    previous.complete();
  }

  /// Wakes held sends and redraws the composer after a hold changed.
  void _removalHoldsUpdated() {
    _removalHoldsSettled();
    if (!_disposed) notifyListeners();
  }

  static String _removalHoldsSetting(String deviceId) =>
      'mls_removal_holds:$deviceId';

  /// Loads this device's stored holds once per session. A stored hold
  /// counts as set now, so no read already in flight releases it.
  Future<void> _loadRemovalHolds() async {
    final owner = session;
    final generation = _sessionGeneration;
    if (owner == null || _removalHoldsLoaded == generation) return;
    String? stored;
    try {
      stored = await localStore
          .loadSetting(_removalHoldsSetting(owner.deviceId ?? ''));
    } catch (_) {
      return;
    }
    if (generation != _sessionGeneration || _removalHoldsLoaded == generation) {
      return;
    }
    _removalHoldsLoaded = generation;
    if (stored == null) return;
    try {
      final decoded = jsonDecode(stored) as Map<String, Object?>;
      for (final entry in decoded.entries) {
        final hold = _RemovalHold.fromJson(entry.value as Map<String, Object?>)
          ..seq = ++_removalHoldSeq;
        _removalHolds.putIfAbsent(entry.key, () => hold);
      }
    } catch (_) {
      // An unreadable entry holds nothing; the server's list sets it again.
    }
    if (_removalHolds.isNotEmpty) _removalHoldsUpdated();
  }

  /// Best effort: a failed write only loses the restart-safety of a hold.
  Future<void> _saveRemovalHolds() async {
    final owner = session;
    if (owner == null || _removalHoldsLoaded != _sessionGeneration) return;
    try {
      await localStore.saveSetting(
        _removalHoldsSetting(owner.deviceId ?? ''),
        jsonEncode(<String, Object?>{
          for (final entry in _removalHolds.entries)
            entry.key: entry.value.toJson(),
        }),
      );
    } catch (_) {}
  }

  /// Updates the holds from one pending-changes read that started when
  /// [_removalHoldSeq] was [readSeq]. A hold set after the read started is
  /// left alone. A listed removal holds its conversation; one not listed is
  /// released when no MLS message of it is queued, no commit is staged, a
  /// complete sync fetch started after an earlier read that already left it
  /// out (so a removal commit the server held then has been applied: not
  /// being listed alone does not prove that), and either a commit was
  /// applied since the epoch it was listed at, the server never listed it
  /// (nothing to commit), or every removed account is a member again (the
  /// removal was withdrawn). A conversation that is gone, or has no local
  /// group, holds nothing. A read the server cut at its cap releases only
  /// holds of conversations that are gone.
  Future<void> _updateRemovalHolds(
    List<MlsPendingChange> changes,
    int readSeq,
    Session current,
    ApiClient client,
    MlsConversationCryptoService mls,
  ) async {
    final generation = _sessionGeneration;
    await _loadRemovalHolds();
    if (!_syncOwnerActive(current, generation)) return;
    final read = ++_removalReadCount;
    var followUp = false;
    var changed = false;
    final listed = <String, MlsPendingChange>{
      for (final change in changes)
        if (change.remove.isNotEmpty) change.conversationId: change,
    };
    for (final change in listed.values) {
      final hold = _removalHolds.putIfAbsent(change.conversationId, () {
        changed = true;
        return _RemovalHold(epoch: change.epoch);
      });
      final accounts = change.remove.map((item) => item.accountId);
      if (!hold.listed ||
          hold.epoch < change.epoch ||
          !hold.accounts.containsAll(accounts)) {
        changed = true;
      }
      hold
        ..listed = true
        ..unlistedAt = null
        // A stale read never lowers the epoch a release compares against.
        ..epoch = max(hold.epoch, change.epoch)
        ..accounts.addAll(accounts);
    }
    // A read the server cut at its overall cap may leave whole conversations
    // out: one missing from it proves nothing. The server says so in a
    // response-level flag; an item's own truncated flag may only mean that
    // conversation hit its own cap, which must not hold every other one.
    // A server without the flag flags every item of a cut read: fail closed.
    final serverCut = changes is MlsPendingChanges ? changes.cut : null;
    final cut = serverCut ??
        (changes.isNotEmpty && changes.every((item) => item.truncated));
    for (final conversationId in _removalHolds.keys.toList()) {
      if (listed.containsKey(conversationId)) continue;
      final hold = _removalHolds[conversationId];
      if (hold == null || hold.seq > readSeq) continue;
      var release = !conversations.any((item) => item.id == conversationId);
      if (!release && cut) continue;
      if (!release) {
        // The first read to leave it out asks for one more pass, whose
        // fetch then brings in any commit the server held at this read.
        final unlistedAt = hold.unlistedAt ??= read;
        if (unlistedAt == read) followUp = true;
        final ({int epoch, bool pending})? local;
        try {
          if (await _hasPendingMlsWork(conversationId)) continue;
          local = await mls.groupEpoch(conversationId);
        } catch (err) {
          // One unreadable conversation keeps its hold; the others are
          // still looked at, and the pass still asks for a follow-up.
          if (!_syncOwnerActive(current, generation)) return;
          // Body-free: no conversation, device or crypto text.
          developer.log('mls_removal_hold_epoch_failed ${err.runtimeType}',
              name: 'veritra.sync');
          continue;
        }
        if (local == null) {
          release = true;
        } else if (local.pending || _removalFetchedAfterRead < unlistedAt) {
          continue;
        } else if (!hold.listed || local.epoch > hold.epoch) {
          release = true;
        } else if (hold.accounts.isNotEmpty) {
          try {
            final members =
                await client.conversationMembers(current.token, conversationId);
            release = hold.accounts.every((account) =>
                members.any((member) => member.accountId == account));
          } catch (err) {
            if (err is ApiException && err.statusCode == 401) rethrow;
          }
        }
      }
      if (!_syncOwnerActive(current, generation)) return;
      // A removal made while this conversation was being looked at stays.
      if (!release ||
          !identical(_removalHolds[conversationId], hold) ||
          hold.seq > readSeq) {
        continue;
      }
      _removalHolds.remove(conversationId);
      changed = true;
    }
    // A hold still open is looked at again on the next catch-up.
    if (_removalHolds.isNotEmpty) _mlsReconcileRequested = true;
    if (followUp) _syncOwner?.markRequested();
    if (changed) {
      await _saveRemovalHolds();
      _removalHoldsUpdated();
    }
  }

  /// One attempt to encrypt and queue a payload. Null when a removal hold
  /// appeared before encryption: nothing was encrypted and the caller waits.
  Future<bool?> _sendPayloadOnce(
    Session owner,
    int ownerGeneration,
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body, {
    List<String> attachmentRefs = const <String>[],
    String? draftText,
    ({String channelId, int generation})? route,
  }) {
    var queued = false;
    var held = false;
    return _runScoped(Ops.send, () async {
      if (!_syncOwnerActive(owner, ownerGeneration)) return;
      final current = session;
      final client = api;
      final conversation =
          conversations.where((item) => item.id == conversationId).firstOrNull;
      if (current == null || client == null || conversation == null) {
        return;
      }
      // K0 step 8: a recovered device that no one can add to this
      // conversation sends nothing, not even the acceptance below.
      final refusal = await _noPeerRefusal(conversation.id);
      if (refusal != null) throw UserFacingException(refusal);
      if (!_syncOwnerActive(owner, ownerGeneration)) return;
      // Replying counts as accepting.
      if (isMessageRequest(conversation)) {
        await _acceptConversation(conversation);
      }
      if (!_syncOwnerActive(owner, ownerGeneration)) return;
      if (!await localStore.hasOutboxCapacity()) {
        throw const OutboxFullException();
      }
      if (!_syncOwnerActive(owner, ownerGeneration)) return;
      if (mlsConversationFailed(conversation.id)) {
        throw const ConversationPausedException();
      }
      if (conversationSyncPaused(conversation.id)) {
        throw ConversationSyncPausedException(conversation.id);
      }
      final mls = _mlsCrypto;
      // D68: checked again inside the queue, right before encryption.
      if (mls != null && await _heldForRemoval(conversation.id)) {
        held = true;
        return;
      }
      if (!_syncOwnerActive(owner, ownerGeneration)) return;
      // W11: this account's profile key (and the group's, once a commit has
      // added devices) rides along with a post.
      final sent = mls == null
          ? body
          : await _withProfileSidecars(conversation.id, type, body);
      final carriesKeys = !identical(sent, body);
      if (!_syncOwnerActive(owner, ownerGeneration)) return;
      final MessageEnvelope encrypted;
      // The sender's own expiry goes inside the encrypted payload (TASK-106)
      // when the conversation has a disappearing timer and the service can
      // carry it; otherwise the payload has none and receivers fall back to
      // the server-stamped time.
      final retention = conversation.retentionSeconds;
      final DateTime? senderExpiry = retention != null && retention > 0
          ? DateTime.now().toUtc().add(Duration(seconds: retention))
          : null;
      final Object? expiringService = mls;
      if (mls != null &&
          senderExpiry != null &&
          expiringService is ExpiringPayloadCryptoService) {
        encrypted = await expiringService.encryptExpiringPayload(
            conversation.id, type, sent,
            expiresAt: senderExpiry,
            channelId: route?.channelId,
            layoutGeneration: route?.generation,
            attachmentRefs: attachmentRefs,
            draftText: draftText);
      } else if (mls != null && route != null) {
        final Object service = mls;
        if (service is! ChannelRoutedCryptoService) {
          throw StateError('this crypto service cannot post into a channel');
        }
        encrypted = await service.encryptChannelPayload(
            conversation.id, type, sent,
            channelId: route.channelId,
            layoutGeneration: route.generation,
            attachmentRefs: attachmentRefs,
            draftText: draftText);
      } else if (mls != null) {
        encrypted = await mls.encryptPayload(conversation.id, type, sent,
            attachmentRefs: attachmentRefs, draftText: draftText);
      } else if (type == AppPayloadType.text) {
        encrypted = await cryptoService.encrypt(
            conversation.id, body['text'] as String);
      } else {
        throw StateError('Production MLS/OpenMLS encryption is not integrated');
      }
      if (!_syncOwnerActive(owner, ownerGeneration)) return;
      await localStore.enqueueEnvelope(encrypted, draftText: draftText);
      queued = true;
      if (carriesKeys) {
        unawaited(
            profiles?.sidecarsSent(conversation.id).catchError((Object _) {}));
      }
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
    }).then((succeeded) => succeeded && held ? null : succeeded && queued);
  }

  /// Marks [idempotencyKey] for an immediate retry and runs the delivery
  /// worker. Only the marking is queued; the network delivery runs outside
  /// the session queue, so sends and sign-out never wait on it. Completes
  /// after that flush.
  Future<void> retryEnvelope(String idempotencyKey) async {
    final owner = session;
    if (owner == null) return;
    var flush = false;
    await _runScoped(Ops.send, () async {
      if (!_sameSession(owner)) return;
      final record = _outboxRecords[idempotencyKey] ??
          (await localStore.pendingEnvelopeRecords())
              .where((item) => item.envelope.idempotencyKey == idempotencyKey)
              .firstOrNull;
      if (record == null || record.terminal || !_sameSession(owner)) {
        return;
      }
      _outboxStates[idempotencyKey] = OutboxDeliveryState.sending;
      notifyListeners();
      _manualRetryKey = idempotencyKey;
      flush = true;
    });
    if (!flush) return;
    // The worker checks its session after every request and clears it on a
    // 401 only while that session is still current. It never throws; a
    // local failure of the pass carrying this retry is reported under
    // [Ops.send] by the worker itself.
    await _flushOutbox();
  }

  Future<void> discardEnvelope(String idempotencyKey) async {
    final deviceId = session?.deviceId;
    if (deviceId != null)
      await localStore.discardPendingPin('$deviceId:$idempotencyKey');
    await _removeFromOutboxByKey(idempotencyKey);
  }

  void _requireLinkOrigin(Session current, ApiClient client) {
    if (canonicalizeServerOrigin(current.baseUrl) != client.baseUrl) {
      throw StateError('Device-link server was substituted');
    }
  }

  Future<void> logout() async {
    await _run(() async {
      final current = session;
      final client = api;
      await _stopPush(current, client);
      // C6: the owner's report seed goes with a deliberate sign-out; the
      // sign-out screen warned first.
      await _deleteReportSeed(current);
      final detached = await _clearLocalSession(
          preserveDeviceIdentity: true, keepApiOpen: true);
      await _revokeAndClose(current, detached);
    });
  }

  /// Asks the server to revoke [current]'s token over [client], the client
  /// [_clearLocalSession] detached without closing, then closes it. Runs
  /// after the local wipe: the wipe is the security boundary and never waits
  /// on the network. A revoke that fails or takes longer than
  /// [signOutRevokeTimeout] is dropped, and the token expires on its own.
  Future<void> _revokeAndClose(Session? current, ApiClient? client) async {
    if (client == null) return;
    try {
      if (current != null && current.token.isNotEmpty) {
        await client.logout(current.token).timeout(signOutRevokeTimeout);
      }
    } catch (_) {
      // Offline or slow: the device is signed out either way.
    } finally {
      // Also aborts a revoke still in flight after the timeout.
      client.close();
    }
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
        throw UserFacingException(l10n.errorRelinkRequired);
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
      await _afterPasswordChanged();
    });
  }

  Future<void> revokeDevice(String deviceId) async {
    await _run(() async {
      final current = session;
      final client = api;
      if (current == null || client == null) {
        return;
      }
      await _revokeWithDeviceList(client, current, deviceId);
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

  /// Stores a verification for the safety number whose code the person
  /// compared ([comparedCode]: the code shown to them, or the one they
  /// scanned), and only if that is still the conversation's number. The
  /// current number is read once and both checked and stored from that
  /// reading, so a device that joined or left since the comparison can never
  /// be recorded as verified. Returns false, storing nothing, when the number
  /// is no longer the compared one; a failure to store throws.
  Future<bool> markPeerVerifiedIfMatches(
      String conversationId, String peerAccountId, String comparedCode) async {
    final current = await conversationSafetyNumber(conversationId);
    if (!_constantTimeBytesEqual(
        utf8.encode(comparedCode.trim()), utf8.encode(current.qrPayload))) {
      return false;
    }
    await localStore.savePeerVerification(conversationId, peerAccountId,
        <int>[_safetyNumberVersion, ...current.transcriptHash]);
    return true;
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

  /// Names the channel the chat for [conversationId] is showing, or clears it
  /// with null. Only a community's shared group has channels in it.
  void selectChannel(String conversationId, String? channelId) {
    if (_selectedChannels[conversationId] == channelId) return;
    if (channelId == null) {
      _selectedChannels.remove(conversationId);
    } else {
      _selectedChannels[conversationId] = channelId;
    }
    notifyListeners();
  }

  String? selectedChannelFor(String conversationId) =>
      _selectedChannels[conversationId];

  /// Where a post to [conversationId] goes inside it: the selected channel
  /// and the layout generation the server routes by. Null for every
  /// conversation but a shared group, and for a shared group with no usable
  /// channel selected, where nothing may be sent.
  ({String channelId, int generation})? _channelRouteFor(
      String conversationId, String? channelId) {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    final communityId = conversation?.communityId;
    if (conversation == null ||
        !conversation.isCommunityShared ||
        channelId == null ||
        communityId == null) {
      return null;
    }
    final channel = (channelsByCommunity[communityId] ?? const <Channel>[])
        .where((c) =>
            c.id == channelId &&
            c.conversationId == conversationId &&
            c.kind != 'private')
        .firstOrNull;
    final generation = channel?.layoutGeneration;
    if (channel == null || generation == null) return null;
    return (channelId: channel.id, generation: generation);
  }

  bool _isSharedGroup(String conversationId) =>
      conversations
          .where((c) => c.id == conversationId)
          .firstOrNull
          ?.isCommunityShared ??
      false;

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

  /// Bumped when this device starts and finishes changing the read-receipts
  /// switch, so a server answer read before the change never undoes it.
  int _readReceiptsChanges = 0;

  /// Adopts the account's read-receipts switch from the server, so a change
  /// made on another linked device shows here. Best effort.
  Future<void> refreshReadReceiptsSetting() async {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    final changes = _readReceiptsChanges;
    try {
      final enabled = await client.readReceiptsEnabled(current.token);
      if (_disposed || !_sameSession(current)) return;
      // The switch changed here while the answer was on its way.
      if (changes != _readReceiptsChanges) return;
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
    _readReceiptsChanges++;
    try {
      await client.setReadReceiptsEnabled(current.token, enabled);
    } catch (_) {
      return false;
    } finally {
      // A refresh that started while the change was being sent may have
      // read the old value.
      _readReceiptsChanges++;
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

  /// Starts the sync owner and socket for the current session. Callers do
  /// not wait for it, so it never throws: a failed lease, drain or dispose
  /// step shows as offline with [syncError], and [_catchUpSyncEvents] (the
  /// retry timer, foreground resume, a push wake) starts it again.
  Future<void> _startSync() async {
    final current = session;
    if (current == null) {
      return;
    }
    final ownerGeneration = ++_sessionGeneration;
    _syncStartFailed = null;
    LocalSyncLease? acquired;
    AccountSyncEngine? installed;
    SyncService? opened;
    try {
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
      // Noted before the await: a failure after the write still releases it.
      acquired = lease;
      await localStore.acquireSyncLease(lease);
      if (ownerGeneration != _sessionGeneration || !_sameSession(current)) {
        await localStore.releaseSyncLease(lease);
        return;
      }
      _syncLease = lease;
      _syncOwner = installed = AccountSyncEngine(
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
      sync = opened = syncServiceFactory(current.baseUrl, current.token);
      _setConnectionStatus(ConnectionStatus.connecting);
      _syncSubscription = opened.events.listen(
        (frame) {
          // Ephemeral frames carry nothing to catch up on.
          if (handleEphemeralFrame(frame)) return;
          unawaited(_catchUpSyncEvents());
          unawaited(_flushMlsOutbox());
        },
        onError: (_) {
          // A dropped socket alone is not proof the server is unreachable;
          // the catch-up attempt that follows decides online vs. offline.
          unawaited(_catchUpSyncEvents());
          unawaited(_flushMlsOutbox());
        },
      );
    } catch (err) {
      if (opened != null && identical(sync, opened)) {
        sync = null;
        unawaited(opened.dispose().catchError((Object _) {}));
      }
      await _abandonSyncStart(current, ownerGeneration, err,
          lease: acquired, owner: installed);
      return;
    }
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
    unawaited(_startProfiles(current));
    unawaited(_startPush());
  }

  /// The session whose sync startup failed and left no owner. Only this
  /// session is started again: one that never got as far as [_startSync]
  /// (its MLS activation failed, say) stays without sync.
  Session? _syncStartFailed;
  bool _syncRestartQueued = false;

  /// Undoes a [_startSync] that threw: the owner and lease it installed go,
  /// and, while [current] is still the session, the failure shows as
  /// offline (a connection fact, not the outcome of a sign-in) and a retry
  /// is scheduled with backoff.
  Future<void> _abandonSyncStart(
    Session current,
    int ownerGeneration,
    Object err, {
    LocalSyncLease? lease,
    AccountSyncEngine? owner,
  }) async {
    if (owner != null && identical(_syncOwner, owner)) {
      _syncOwner = null;
      owner.dispose();
    }
    if (lease != null) {
      if (identical(_syncLease, lease)) _syncLease = null;
      try {
        await localStore.releaseSyncLease(lease);
      } catch (_) {
        // The next startup's lease takes its place.
      }
    }
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    _syncStartFailed = current;
    syncError = _isTransientStorageError(err)
        ? l10n.syncErrorStorageBusy
        : describeError(err, l10n);
    _setConnectionStatus(ConnectionStatus.offline);
    notifyListeners();
    _scheduleCatchUpRetry();
  }

  /// Starts sync again for [failed], whose startup failed. Queued, so it
  /// never runs inside a session transition, which the generation bump in
  /// [_startSync] would cut short; fired and not awaited, so a caller that
  /// is itself queued cannot wait on it.
  void _restartSync(Session failed) {
    if (_syncRestartQueued) return;
    _syncRestartQueued = true;
    unawaited(_enqueueSessionTransition(() async {
      _syncRestartQueued = false;
      if (_disposed ||
          _syncOwner != null ||
          !identical(_syncStartFailed, failed) ||
          !_sameSession(failed)) {
        return;
      }
      await _startSync();
    }));
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

  bool _pushLeaving = false;
  int _pushGeneration = 0;
  final Set<Future<bool>> _pushRegistrations = <Future<bool>>{};
  final Set<Future<void>> _pushStarts = <Future<void>>{};
  bool _pushTeardownFailed = false;

  bool _pushOwnerActive(Session current, int generation, int pushGeneration) =>
      !_pushLeaving &&
      pushGeneration == _pushGeneration &&
      _syncOwnerActive(current, generation);

  Future<void> _startPush() {
    if (_pushLeaving || _disposed) return Future.value();
    final work = _startPushRun();
    _pushStarts.add(work);
    unawaited(work.then((_) => _pushStarts.remove(work)));
    return work;
  }

  Future<void> _startPushRun() async {
    if (_pushLeaving || _disposed) return;
    final pushGeneration = _pushGeneration;
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    final ownerGeneration = _sessionGeneration;
    try {
      final config = await client.pushConfig(current.token);
      if (!_pushOwnerActive(current, ownerGeneration, pushGeneration)) return;
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
      if (!_pushOwnerActive(current, ownerGeneration, pushGeneration)) return;
      _setPushState(PushState.registering);
      _pushInstance = '${current.accountId}:${current.deviceId}';
      phoneNoticesAllowed = false;
      final installer = phoneNoticeInstaller;
      if (installer != null) {
        if (!_pushOwnerActive(current, ownerGeneration, pushGeneration)) return;
        // The worker must be installed, and capture on, before the server is
        // told this device decides mention notices locally.
        var allowed = false;
        try {
          allowed = await installer();
        } catch (_) {}
        if (!_pushOwnerActive(current, ownerGeneration, pushGeneration)) {
          // Installation can finish after a timed-out handoff. The callback
          // captures this slot, so it cannot uninstall a newer slot's worker.
          await beforeLocalSessionClear?.call();
          return;
        }
        phoneNoticesAllowed = allowed;
        _applyNoticeCapture();
      }
      await _pushSubscription?.cancel();
      _pushSubscription = pushService.events.listen(_handlePushEvent);
      final wakeGeneration = await pushService.pendingWakeGeneration();
      if (!_pushOwnerActive(current, ownerGeneration, pushGeneration)) return;
      if (wakeGeneration > 0) {
        _pendingWakeGeneration = max(_pendingWakeGeneration, wakeGeneration);
        unawaited(_catchUpSyncEvents());
      }
      if (!_pushOwnerActive(current, ownerGeneration, pushGeneration)) return;
      await _consumePendingEndpoint(current, client, ownerGeneration);
      if (!_pushOwnerActive(current, ownerGeneration, pushGeneration)) return;
      final instance = _pushInstance!;
      await pushService.register(
          instance: instance, vapid: vapid, providers: providers);
      if (!_pushOwnerActive(current, ownerGeneration, pushGeneration)) {
        try {
          await pushService
              .unregister(instance)
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          _pushTeardownFailed = true;
        }
        return;
      }
      notifyListeners();
    } catch (_) {
      // Push is optional; realtime and foreground catch-up remain available.
      if (!_disposed && !_pushLeaving && pushState == PushState.registering) {
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
    if (_pushLeaving || _disposed) return;
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
      await _registerEndpoint(current, client, ownerGeneration, event);
    } else if (event is PushRegistrationFailedEvent &&
        event.instance == _pushInstance) {
      // A UnifiedPush failure means no distributor answered; anything else
      // is a provider refusal. Neither carries platform error text.
      _setPushState(
          event.provider == 'webpush' || event.provider == 'unifiedpush'
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

  /// Registers [event] with the server and, only after that succeeded,
  /// acknowledges its native record. A failure leaves the record for the
  /// next startup or resume. Registering twice (live and pending) is safe.
  Future<bool> _registerEndpoint(Session current, ApiClient client,
      int ownerGeneration, PushEndpointEvent event) {
    if (_pushLeaving || _disposed) return Future.value(false);
    final work = _registerEndpointRun(
        current, client, ownerGeneration, _pushGeneration, event);
    _pushRegistrations.add(work);
    unawaited(work.then((_) => _pushRegistrations.remove(work)));
    return work;
  }

  Future<bool> _registerEndpointRun(Session current, ApiClient client,
      int ownerGeneration, int pushGeneration, PushEndpointEvent event) async {
    try {
      // Every rotation carries the mode again: the server resets a
      // subscription registered without it back to the generic mode.
      final mode = phoneNoticesAllowed ? 'local_decrypt_v1' : null;
      final subscriptionId =
          (event.provider == 'webpush' || event.provider == 'unifiedpush')
              ? await client.registerWebPush(current.token,
                  provider: event.provider,
                  endpoint: event.endpoint,
                  publicKey: event.publicKey,
                  authSecret: event.authSecret,
                  notificationMode: mode)
              : await client.registerNativePush(current.token,
                  provider: event.provider,
                  deviceToken: event.endpoint,
                  notificationMode: mode);
      if (!_pushOwnerActive(current, ownerGeneration, pushGeneration)) {
        // A server registration can commit after teardown started. Use a
        // fresh transport when the old runtime has already closed its own.
        final cleanup = apiClientFactory(current.baseUrl);
        try {
          await cleanup
              .disablePush(current.token, subscriptionId)
              .timeout(const Duration(seconds: 5));
        } finally {
          cleanup.close();
        }
        return true;
      }
      _pushSubscriptionId = subscriptionId;
      pushProvider = event.provider;
      _setPushState(PushState.registered);
      notifyListeners();
    } catch (_) {
      // Re-registration on the next startup retries endpoint delivery.
      if (!_pushLeaving && !_disposed) {
        _setPushState(PushState.registrationFailed);
      }
      return false;
    }
    if (event.generation > 0) {
      try {
        await pushService.acknowledgeEndpoint(event.generation);
      } catch (_) {
        // The record stays; it is registered again, harmlessly, later.
      }
    }
    return true;
  }

  /// Pulls the native pending endpoint record. A record for another
  /// instance is stale and dropped without being uploaded.
  Future<void> _consumePendingEndpoint(
      Session current, ApiClient client, int ownerGeneration) async {
    try {
      final pending = await pushService.pendingEndpoint();
      if (pending == null || !_syncOwnerActive(current, ownerGeneration)) {
        return;
      }
      if (pending.instance != _pushInstance) {
        await pushService.acknowledgeEndpoint(pending.generation);
        return;
      }
      await _registerEndpoint(current, client, ownerGeneration, pending);
    } catch (_) {
      // Push is optional; a later startup or resume pulls the record again.
    }
  }

  Future<void> _resumeForegroundSync() async {
    if (session == null || api == null) return;
    // A background pass hands over to the foreground owner: it is cancelled
    // here, and its own atomic commit drains through the same sync owner.
    _wakeRun?.cancel();
    await _finishDeferredWakeWork();
    // Timers do not run while the app is suspended.
    await purgeExpiredMessages();
    await _observePendingWake();
    await _retryPendingEndpoint();
    await _catchUpSyncEvents();
    await _flushMlsOutbox();
  }

  Future<void> _retryPendingEndpoint() async {
    final current = session;
    final client = api;
    if (current == null || client == null || _pushInstance == null) return;
    await _consumePendingEndpoint(current, client, _sessionGeneration);
  }

  /// Whether the UI is in front; a background wake never starts then.
  bool get foregroundActive => _isForeground;

  /// D52: opens the existing protected session for one bounded background
  /// wake, through the same AppState and sync owner the UI uses. It never
  /// creates keys or state, signs in, registers push, opens the websocket,
  /// flushes an outbox or prompts. A warm process binds to its current
  /// owner. Missing or locked state, a recorded sync recovery or a foreground
  /// UI answers false, leaving the wake pending.
  Future<bool> restoreForBackgroundWake(WakeRunContext wake) async {
    var restored = false;
    await _enqueueSessionTransition(() async {
      restored = await _restoreForWake(wake);
    });
    return restored;
  }

  Future<bool> _restoreForWake(WakeRunContext wake) async {
    if (_disposed ||
        _isForeground ||
        lifecycle == SessionLifecycle.recoveryRequired) {
      return false;
    }
    final crypto = cryptoService;
    if (crypto is! BoundedMlsConversationCryptoService) return false;
    final existing = session;
    if (existing != null) {
      if (_syncOwner == null || existing.token.isEmpty) return false;
      final generation = _sessionGeneration;
      wake.bindOwner(
          () => !_isForeground && _syncOwnerActive(existing, generation));
      return true;
    }
    void fence() {
      if (!wake.active) throw const WakeWorkCancelled();
    }

    final stored = await localStore.loadSession();
    if (stored == null ||
        stored.token.isEmpty ||
        stored.accountId == null ||
        stored.deviceId == null ||
        await localStore.loadSyncRecovery() != null) {
      return false;
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
    if (!config.transport.allows(restored.baseUrl)) return false;
    await wake.check(requireOwner: false);
    await _resumeDeviceListAnchor(restored);
    fence();
    await crypto.activateExistingSessionBounded(restored,
        checkCanCommit: fence);
    fence();
    await _clearDeviceListAnchorJournal(restored);
    fence();
    if (session != null || _isForeground) return false;
    final generation = ++_sessionGeneration;
    session = restored;
    _applyNoticeCapture();
    try {
      _replaceApi(restored.baseUrl);
      _mutes
        ..clear()
        ..addAll(await localStore.loadConversationMutes());
      conversationPrefs = {
        for (final p in await localStore.loadConversationPrefs())
          p.conversationId: p
      };
      mentionsInMutedChats =
          await localStore.loadSetting('w8.mentions_muted') != 'false';
      linkPreviewMode = linkPreviewModeFromName(
          await localStore.loadSetting('b2.link_preview'));
      screenGuardChats =
          await localStore.loadSetting('screen_guard_chats') != 'false';
      _updateScreenGuard();
      final cached = await localStore.loadSnapshot();
      if (cached != null) {
        conversations = cached.conversations;
        messagesByConversation = cached.messagesByConversation;
        conversationsLoaded = true;
        await _loadRequestState(grandfather: true);
      }
      final lease = LocalSyncLease(
        origin: restored.baseUrl,
        accountId: restored.accountId!,
        deviceId: restored.deviceId!,
        generation: generation,
      );
      await localStore.acquireSyncLease(lease);
      if (generation != _sessionGeneration || !_sameSession(restored)) {
        await localStore.releaseSyncLease(lease);
        return false;
      }
      _syncLease = lease;
      _syncOwner = AccountSyncEngine(
        isOwner: () =>
            generation == _sessionGeneration && _sameSession(restored),
        work: () => _runOwnedCatchUp(restored, generation),
      );
      wake.bindOwner(
          () => !_isForeground && _syncOwnerActive(restored, generation));
      return true;
    } catch (_) {
      if (generation == _sessionGeneration && identical(session, restored)) {
        session = null;
        api?.close();
        api = null;
      }
      rethrow;
    }
  }

  /// One bounded catch-up for a background wake, then the private notice
  /// outbox. The pass runs on the existing sync owner with a job-owned HTTP
  /// client that the permit closes on cancellation. Only a complete pass with
  /// every notice decided durably lets native acknowledge the wake.
  Future<WakeCatchUpResult> catchUpForBackgroundWake(
      WakeRunContext wake) async {
    const failed = WakeCatchUpResult(
        caughtUp: false, decisionsDurable: false, changed: false);
    final current = session;
    final owner = _syncOwner;
    if (current == null ||
        owner == null ||
        _wakeRun != null ||
        !wake.ownerBound ||
        _isForeground) {
      return failed;
    }
    final client = apiClientFactory(current.baseUrl);
    final unregister = wake.onCancel(client.close);
    _wakeRun = wake;
    _wakeApi = client;
    _wakePassComplete = false;
    try {
      final before = await localStore.loadSyncCursor();
      await wake.check();
      await owner.request();
      if (!_wakePassComplete || !identical(_wakeRun, wake)) return failed;
      final after = await localStore.loadSyncCursor();
      await wake.check();
      final notices = await _processPendingNotices(current, client, wake);
      return WakeCatchUpResult(
          caughtUp: true,
          decisionsDurable: notices.durable,
          changed: after != before || notices.shown > 0);
    } catch (_) {
      return failed;
    } finally {
      if (identical(_wakeRun, wake)) {
        _wakeRun = null;
        _wakeApi = null;
        _wakePassComplete = false;
      }
      unregister();
      client.close();
    }
  }

  Future<NoticePassResult> _processPendingNotices(
      Session current, ApiClient client, WakeRunContext wake) {
    return LocalNoticeProcessor(
      store: localStore,
      session: current,
      check: wake.checkCanCommit,
      policy: NoticePolicy(
        blocked: (accountId) async {
          if (!blocksLoaded) {
            try {
              await wake.check();
              blockedAccounts = await client.listBlocks(current.token);
              blocksLoaded = true;
            } catch (_) {
              return null;
            }
          }
          return isBlocked(accountId);
        },
        conversationAccepted: (id) =>
            !requestStateLoaded || !conversations.any((c) => c.id == id)
                ? null
                : conversationOpen(id),
        muted: (id) async {
          // A fresh server read for every decision; nothing is written back
          // from a background pass. Failure means "unknown", never unmuted.
          try {
            await wake.check();
            final mute = await client.conversationMute(current.token, id);
            final until = mute.until;
            return mute.muted &&
                (until == null || until.isAfter(DateTime.now().toUtc()));
          } catch (_) {
            return null;
          }
        },
        mentionsInMutedChats: mentionsInMutedChats,
      ),
      present: (id) async => switch (await wake.presentDecision(id)) {
        WakeNoticeResult.shown => LocalNoticeOutcome.shown,
        WakeNoticeResult.suppressed => LocalNoticeOutcome.suppressed,
        WakeNoticeResult.unavailable => LocalNoticeOutcome.unavailable,
      },
    ).run();
  }

  /// Background passes leave list/device refreshes and key-package
  /// publishing to the foreground; run them now.
  Future<void> _finishDeferredWakeWork() async {
    final current = session;
    if (current == null) return;
    final generation = _sessionGeneration;
    await _suppressForegroundNotices(current, always: true);
    if (_refreshAfterWake) {
      _refreshAfterWake = false;
      try {
        await _refreshConversations(notify: true);
        await _refreshDevices();
      } catch (_) {
        // Owed again only to the session that owed it.
        if (_refreshOwned(current, generation)) _refreshAfterWake = true;
      }
    }
    if (!_refreshOwned(current, generation)) return;
    if (_replenishAfterWake) {
      _replenishAfterWake = false;
      await _replenishKeyPackage();
    }
  }

  void _deferProjectionRefresh(SyncEvent event) {
    final type = event.type;
    // Local only: the status is read again on the next resume.
    if (type.startsWith('account.') && _noteAccountSyncEvent(event)) {
      _recoveryStatusReadAt = null;
    }
    if (_isMemberLinkedNotice(type)) {
      // Only a membership pass is asked for; nothing local changed.
      _mlsReconcileRequested = true;
      return;
    }
    if (type == 'device_list.updated') {
      _noteDeviceListUpdated();
      return;
    }
    if (type.startsWith('device.') ||
        type.startsWith('membership.') ||
        type.startsWith('conversation.')) {
      _mlsReconcileRequested = true;
    }
    if (type.startsWith('device.') ||
        type.startsWith('conversation.') ||
        type.startsWith('membership.') ||
        type == 'retention.updated') {
      // A changed roster must be read again before it authorizes anything.
      if (event.conversationId != null) {
        membersByConversation = Map.of(membersByConversation)
          ..remove(event.conversationId);
      } else if (type.startsWith('membership.')) {
        membersByConversation = {};
      }
      _refreshAfterWake = true;
    }
  }

  /// The person is looking at the app: references captured for messages
  /// already committed must never become a late phone notice.
  Future<void> _suppressForegroundNotices(Session current,
      {bool always = false}) async {
    if (!always) {
      final capture = cryptoService;
      if (!_isForeground ||
          capture is! NoticeCaptureConsumer ||
          !(capture as NoticeCaptureConsumer).noticeCaptureEnabled) {
        return;
      }
    }
    final account = current.accountId, device = current.deviceId;
    if (account == null || device == null) return;
    try {
      await localStore.suppressNoticesThrough(
          LocalNoticeOwner(
              origin: current.baseUrl, accountId: account, deviceId: device),
          await localStore.loadSyncCursor());
    } catch (_) {
      // Stale references are also pruned after the freshness window.
    }
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
    await _stopPushStrict(current, client, attempts: 1);
  }

  /// Takes the server subscription and the native registration down, trying
  /// each [attempts] times. Returns whether both are gone (true too when
  /// nothing was registered). The local push state is cleared either way.
  Future<bool> _stopPushStrict(Session? current, ApiClient? client,
      {required int attempts}) async {
    var gone = true;
    Future<bool> attempt(Future<void> Function() action) async {
      for (var i = 0; i < attempts; i++) {
        try {
          await action().timeout(const Duration(seconds: 5));
          return true;
        } catch (_) {}
      }
      return false;
    }

    final id = _pushSubscriptionId;
    final instance = _pushInstance;
    if (id != null && current != null && client != null) {
      gone = await attempt(() => client.disablePush(current.token, id));
    }
    if (instance != null) {
      gone = await attempt(() => pushService.unregister(instance)) && gone;
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
    return gone;
  }

  Future<void> _catchUpSyncEvents() async {
    if (!_isForeground) return;
    final failed = _syncStartFailed;
    if (_syncOwner == null && failed != null && _sameSession(failed)) {
      // The owner never came up; a successful start runs its own catch-up.
      _restartSync(failed);
      return;
    }
    await _syncOwner?.request();
    _retryOwedKeyPackages();
  }

  Future<void> _runOwnedCatchUp(Session current, int ownerGeneration) async {
    // A D52 background pass runs on this same owner, bounded by its permit,
    // instead of pretending the app is in the foreground.
    // A cancelled wake (the UI resumed mid-pass) no longer owns this run:
    // the follow-up pass the resume requested is a foreground pass.
    final pending = _wakeRun;
    final wake = pending != null && pending.active ? pending : null;
    bool mayRun() => wake != null ? wake.active : _isForeground;
    if (!mayRun() ||
        ownerGeneration != _sessionGeneration ||
        !_sameSession(current)) {
      return;
    }
    final client = wake != null ? _wakeApi : api;
    if (client == null) {
      return;
    }
    try {
      // A stopped device stays stopped until the user picks a recovery
      // choice (I33): retrying the same event on every wake would be a
      // poison loop. A storage error reading the record is handled below
      // like any other.
      var stored = await localStore.loadSyncRecovery();
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      if (stored?.kind == SyncFailureKind.applicationUndecryptable &&
          wake == null &&
          await localStore.loadSetting(_undecryptableRetrySetting) == null) {
        // Under D54 a peer message this device can never decrypt no longer
        // stops sync. A stop recorded for one before that rule is cleared,
        // once per store, so its event is applied again. If it still
        // fails, the new record stays. The record is cleared before the
        // one-time flag is saved: a failed clear must leave it to be tried
        // again, not marked done with the stop still in place.
        await localStore.saveSyncRecovery(null);
        await localStore.saveSetting(_undecryptableRetrySetting, 'done');
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        stored = null;
      }
      if (stored != null && wake == null) {
        // A stop recorded for one conversation's event, from before pauses
        // existed, becomes that conversation's pause when the server can
        // serve the event again. The cursor never passed it.
        if (await _pauseStoredRecovery(
            stored, current, client, ownerGeneration)) {
          await localStore.saveSyncRecovery(null);
          stored = null;
        }
        if (!_syncOwnerActive(current, ownerGeneration)) return;
      }
      if (stored != null) {
        _enterSyncRecovery(stored);
        return;
      }
      await _loadConversationPauses(current, ownerGeneration);
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      // Envelopes an earlier pass committed but could not show. A history
      // that still cannot be read keeps them for the next pass; it must not
      // stop this one, or one bad read would block all sync.
      try {
        await _publishReceived(
            <ReceivedMessageEnvelope>[], current, ownerGeneration);
      } catch (_) {}
      if (!mayRun() || !_syncOwnerActive(current, ownerGeneration)) return;
      if (wake == null) {
        await _dropLeftConversations(current, ownerGeneration);
        if (!mayRun() || !_syncOwnerActive(current, ownerGeneration)) return;
        await _replayRequestedPauses(current, client, ownerGeneration);
        if (!mayRun() || !_syncOwnerActive(current, ownerGeneration)) return;
      }
      // Pending-changes reads finished before this fetch starts (D68).
      final fetchAfterRead = _removalReadCount;
      var pageCursor = await localStore.loadSyncCursor();
      _syncFetchedThrough = pageCursor;
      _syncFetchedGeneration = ownerGeneration;
      const pageSize = 200;
      while (true) {
        if (!mayRun() || !_syncOwnerActive(current, ownerGeneration)) {
          return;
        }
        await wake?.check();
        final pageStartCursor = pageCursor;
        final syncPage = await client.syncEventsPage(
          current.token,
          after: pageCursor,
          limit: pageSize,
        );
        final events = syncPage.events;
        if (!mayRun() || !_syncOwnerActive(current, ownerGeneration)) {
          return;
        }
        // Moves the persisted cursor to the scan position the server
        // reported (TASK-209, D92): the hidden run behind the last event is
        // crossed once, not on every poll. Only once the page is fully
        // applied: the stored cursor must equal the page's last event (or
        // the cursor the page started at, when it is empty), so nothing a
        // failed or held-back event left behind is passed. Never moves back.
        Future<void> advanceToScan(int appliedThrough) async {
          final scanned = syncPage.scannedThrough;
          if (scanned == null) return;
          final stored = await localStore.loadSyncCursor();
          if (stored != appliedThrough || scanned <= stored) return;
          if (!_syncOwnerActive(current, ownerGeneration)) return;
          wake?.checkCanCommit();
          await localStore.saveSyncCursor(scanned);
          if (_syncFetchedGeneration == ownerGeneration) {
            _syncFetchedThrough = max(_syncFetchedThrough, scanned);
          }
        }

        if (events.isEmpty) {
          await advanceToScan(pageStartCursor);
          if (!_syncOwnerActive(current, ownerGeneration)) return;
          if (!syncPage.truncated) break;
          pageCursor = await localStore.loadSyncCursor();
          if (pageCursor <= pageStartCursor) {
            developer.log('sync_scan_did_not_advance', name: 'veritra.sync');
            break;
          }
          continue;
        }
        var returnedCursor = pageCursor;
        for (final event in events) {
          if (event.id <= returnedCursor) {
            throw StateError('sync events are not strictly ordered');
          }
          returnedCursor = event.id;
        }
        if (_syncFetchedGeneration == ownerGeneration) {
          _syncFetchedThrough = max(_syncFetchedThrough, returnedCursor);
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
        // Projection events only ask for a refresh. A run of them in a row
        // is refreshed once per kind, then each is committed in order, all
        // before the next crypto event is applied; a failed refresh commits
        // none of the run. Returns false once this run no longer owns sync.
        final projections = <SyncEvent>[];
        Future<bool> commitProjections() async {
          if (projections.isEmpty) return true;
          if (wake != null) {
            // A background pass makes no list/device requests; the next
            // foreground resume refreshes instead.
            projections.forEach(_deferProjectionRefresh);
          } else {
            await _refreshProjectionForSyncEvents(projections);
          }
          for (final event in projections) {
            if (!_syncOwnerActive(current, ownerGeneration)) return false;
            final expectedCursor = await localStore.loadSyncCursor();
            await localStore.commitSyncEvent(SyncEventCommit(
              eventKey: 'sync:${event.id}',
              conversationId: event.conversationId ?? '',
              expectedCursor: expectedCursor,
              cursor: event.id,
              checkCanCommit: wake?.checkCanCommit,
            ));
          }
          projections.clear();
          notifyListeners();
          return true;
        }

        try {
          for (final event in events) {
            final committedCursor = await localStore.loadSyncCursor();
            if (event.id <= committedCursor) continue;
            if (!_syncOwnerActive(current, ownerGeneration)) return;
            await wake?.check();

            if (_heldBackByPause(event)) {
              // A paused conversation's crypto events are passed over by
              // the cursor alone (C1 P1): its group stays where the failed
              // event left it, and a replay applies them in order.
              if (!await commitProjections()) return;
              await _skipPausedEvent(event, wake);
              continue;
            }
            if (_isCryptoSyncEvent(event.type)) {
              if (!await commitProjections()) return;
              if (_mlsCrypto == null) {
                throw SyncEventFailure(SyncFailureKind.cryptoUnavailable,
                    eventId: event.id,
                    eventType: event.type,
                    conversationId: event.conversationId);
              }
              final ReceivedMessageEnvelope? envelope;
              try {
                envelope = await _processCryptoSyncEvent(event, repair,
                    wake: wake, client: client);
              } catch (err) {
                // One conversation's failure pauses that conversation
                // alone; anything that is not about one conversation stops
                // the device as before (I33). A background pass leaves the
                // decision to the foreground.
                if (wake != null ||
                    err is! SyncEventFailure ||
                    !failurePausesConversation(err) ||
                    !await _pauseConversationAt(
                        err, current, client, ownerGeneration)) {
                  rethrow;
                }
                await _skipPausedEvent(event, wake);
                continue;
              }
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
              // (P5). Unknown crypto types still stop sync, at this event.
              if (!_knownProjectionEvent(event.type) &&
                  _failsClosedEvent(event.type)) {
                if (!await commitProjections()) return;
                final unsupported = SyncEventFailure(
                    SyncFailureKind.unsupportedEvent,
                    eventId: event.id,
                    eventType: event.type,
                    conversationId: event.conversationId);
                if (wake != null ||
                    !failurePausesConversation(unsupported) ||
                    !await _pauseConversationAt(
                        unsupported, current, client, ownerGeneration)) {
                  throw unsupported;
                }
                await _skipPausedEvent(event, wake);
                continue;
              }
              projections.add(event);
              continue;
            }
            notifyListeners();
          }
          if (!await commitProjections()) return;
        } catch (_) {
          // Messages committed before the failure still reach the UI (or,
          // if their history cannot be read now, the next catch-up); the
          // failure itself is what the caller handles.
          try {
            await _publishReceived(received, current, ownerGeneration);
          } catch (_) {}
          rethrow;
        }
        await _publishReceived(received, current, ownerGeneration);
        await advanceToScan(events.last.id);
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        pageCursor = await localStore.loadSyncCursor();
        if (syncPage.truncated) {
          // The server's scan budget ended this page early, so a short page
          // is not the end. The cursor must have moved forward, or the same
          // page would be asked for again.
          if (pageCursor <= pageStartCursor) {
            developer.log('sync_scan_did_not_advance', name: 'veritra.sync');
            break;
          }
          continue;
        }
        if (events.length < pageSize) break;
      }
      // Every event up to the end of the stream is applied.
      if (fetchAfterRead > _removalFetchedAfterRead) {
        _removalFetchedAfterRead = fetchAfterRead;
      }
      if (wake != null) {
        // Revocations and membership reconcile send commits; a background
        // pass only receives. Native acknowledges the wake from the result.
        _mlsReconcileRequested = true;
        _wakePassComplete = true;
        return;
      }
      await _suppressForegroundNotices(current);
      if (_mlsCrypto != null) {
        try {
          await _processMlsRevocations();
        } catch (err) {
          // Like reconcile below, revocations never block sync: a failure
          // is retried after its own backoff (TASK-035).
          if (err is ApiException && err.statusCode == 401) rethrow;
          if (_syncOwnerActive(current, ownerGeneration)) {
            _mlsStepSettled('revocations', failed: true);
          }
        }
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
        try {
          await _maybeSelfUpdate(current, ownerGeneration);
        } catch (err) {
          // A self-update is optional; it never blocks sync.
          if (err is ApiException && err.statusCode == 401) rethrow;
        }
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        // Caught up: expired key packages may go (D70 S4).
        await _maybePruneKeyPackages();
        if (!_syncOwnerActive(current, ownerGeneration)) return;
      }
      await _acknowledgePendingWake(current, ownerGeneration: ownerGeneration);
      lastSyncedAt = DateTime.now();
      syncError = null;
      deviceRecoveryRequired = false;
      syncRecovery = null;
      _setConnectionStatus(ConnectionStatus.online);
      _cancelCatchUpRetry();
    } catch (err) {
      // A background pass never clears the session, records a recovery or
      // schedules timers: the foreground decides those with full context.
      if (wake != null) rethrow;
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      if (err is ApiException && err.statusCode == 401) {
        try {
          await _clearLocalSession(
              preserveDeviceIdentity: true,
              keepDrafts: true,
              preserveOutbox: true,
              drainSyncOwner: false);
        } catch (_) {
          // Signing out failed in local storage. Callers do not await this
          // run, so nothing may escape it: stay offline and try again.
          if (!_syncOwnerActive(current, ownerGeneration)) return;
          syncError = describeError(err, l10n);
          _setConnectionStatus(ConnectionStatus.offline);
          notifyListeners();
          _scheduleCatchUpRetry();
        }
        return;
      }
      final failure = _recoveryFailureFor(err);
      if (failure != null && failure.damagedStorage) {
        // No record is written: the write would land in the damaged file,
        // or reload later as a stop that only offers Retry.
        _enterDamagedStorageRecovery();
        return;
      }
      if (failure != null) {
        final recovery = SyncRecovery.fromFailure(failure, DateTime.now());
        try {
          await localStore.saveSyncRecovery(recovery);
        } catch (_) {
          // A failing store may refuse this write too. The device still
          // stops here; the record is written when a later pass stops.
        }
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        _enterSyncRecovery(recovery);
        return;
      }
      // Background sync failure is a connection fact, not the outcome of
      // whatever the user last tapped. Writing it to the shared [error] made
      // unrelated screens report it as their own failure, so it goes to
      // [syncError] and the offline banner instead.
      syncError = _isTransientStorageError(err)
          ? l10n.syncErrorStorageBusy
          : describeError(err, l10n);
      _setConnectionStatus(ConnectionStatus.offline);
      notifyListeners();
      _scheduleCatchUpRetry(
          retryAfter: err is ApiException ? err.retryAfter : null);
    }
  }

  /// Set once a stop recorded for an undecryptable message has been cleared
  /// for D54 (see [_runOwnedCatchUp]).
  static const _undecryptableRetrySetting = 'sync.d54_undecryptable_retried';

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
    if (_isDurableStorageError(err)) {
      return SyncEventFailure(SyncFailureKind.localStorage,
          damagedStorage: _isDamagedStorage(err));
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

  // ---------------------------------------------------------------------
  // Per-conversation MLS failure isolation (C1 prerequisite 1)
  //
  // A failure that belongs to one conversation's event pauses that
  // conversation, not the device: the failure is recorded durably with the
  // event it stopped at, the global cursor moves past that conversation's
  // later crypto events without applying them, and every other
  // conversation keeps syncing. Nothing is dropped. A retry replays the
  // conversation's own stream (`GET /conversations/{id}/sync-events`) in
  // order up to the global cursor and lifts the pause. A failure that is
  // not about one conversation (storage, no crypto, an expired cursor, a
  // failed restore of the native handle, no way to fetch the event again)
  // still stops the device, as before.
  // ---------------------------------------------------------------------

  /// Whether [event] belongs to a paused conversation and would change its
  /// MLS state. Projection events (a refresh request) are not held back.
  bool _heldBackByPause(SyncEvent event) {
    final conversationId = event.conversationId;
    if (conversationId == null) return false;
    if (!conversationPauses.containsKey(conversationId)) return false;
    return _isCryptoSyncEvent(event.type) ||
        (!_knownProjectionEvent(event.type) && _failsClosedEvent(event.type));
  }

  /// Moves the global cursor past [event] of a paused conversation without
  /// applying it. The store refuses unless the pause is durable in the same
  /// step.
  Future<void> _skipPausedEvent(SyncEvent event, WakeRunContext? wake) async {
    await localStore.skipPausedConversationEvent(
      conversationId: event.conversationId!,
      eventId: event.id,
      expectedCursor: await localStore.loadSyncCursor(),
      checkCanCommit: wake?.checkCanCommit,
    );
  }

  /// The server id a sync event points at (an MLS message or an envelope),
  /// so a replay can tell that the event under an id changed. Not content.
  String? _failedRefOf(SyncEvent event) {
    final ref = event.type == 'mls.message.created'
        ? _mlsMessageIdFromPayload(event.payload)
        : _messageIdFromSyncEvent(event);
    return ref != null && ref.length <= 128 ? ref : null;
  }

  /// Pauses the conversation [failure] names, if that is safe. Returns
  /// false, and the caller stops the device as before, when:
  /// - the native handle no longer answers (every group would fail next),
  /// - the server cannot serve this event again from the conversation's own
  ///   stream (nothing may be passed over that cannot be fetched again),
  /// - the pause table is full.
  /// A connection problem while checking is rethrown: the event fails the
  /// same way on the next pass, which checks again.
  Future<bool> _pauseConversationAt(SyncEventFailure failure, Session current,
      ApiClient client, int ownerGeneration) async {
    final conversationId = failure.conversationId;
    final eventId = failure.eventId;
    if (conversationId == null || eventId == null) return false;
    final Object? mls = _mlsCrypto;
    if (mls is MlsDeviceHealthCryptoService &&
        !await mls.deviceHandleUsable()) {
      return false;
    }
    if (!_syncOwnerActive(current, ownerGeneration)) return false;
    final SyncEvent? served;
    try {
      final page = await client.conversationSyncPage(
          current.token, conversationId,
          after: eventId - 1, limit: 1);
      served = page.events.firstOrNull;
    } catch (err) {
      if (_isTransientSyncError(err) ||
          (err is ApiException && err.statusCode == 401)) {
        rethrow;
      }
      return false;
    }
    if (served == null ||
        served.id != eventId ||
        served.conversationId != conversationId ||
        (failure.eventType != null && served.type != failure.eventType) ||
        served.type.length > maxPausedEventTypeLength) {
      return false;
    }
    final ConversationPause pause;
    try {
      pause = await localStore.pauseConversation(
        conversationId: conversationId,
        failedEventId: eventId,
        kind: failure.kind,
        failedEventType: served.type,
        failedRef: _failedRefOf(served),
      );
    } on ConversationPauseLimitReached {
      return false;
    }
    if (_syncOwnerActive(current, ownerGeneration)) {
      conversationPauses = <String, ConversationPause>{
        ...conversationPauses,
        conversationId: pause,
      };
      // Body-free: no conversation id, event or server text.
      developer.log('sync_conversation_paused ${failure.kind.name}',
          name: 'veritra.sync');
      notifyListeners();
    }
    return true;
  }

  /// Turns a global stop recorded for one conversation's event (before
  /// pauses existed) into that conversation's pause. False when it is not
  /// one, or when the pause is not safe (see [_pauseConversationAt]).
  Future<bool> _pauseStoredRecovery(SyncRecovery stored, Session current,
      ApiClient client, int ownerGeneration) async {
    final eventId = stored.eventId;
    if (eventId == null || stored.conversationId == null) return false;
    // The cursor never passed a stopped event.
    if (eventId <= await localStore.loadSyncCursor()) return false;
    final failure = SyncEventFailure(stored.kind,
        eventId: eventId,
        eventType: stored.eventType,
        conversationId: stored.conversationId);
    if (!failurePausesConversation(failure)) return false;
    return _pauseConversationAt(failure, current, client, ownerGeneration);
  }

  /// Loads the durable pauses into [conversationPauses].
  Future<void> _loadConversationPauses(
      Session current, int ownerGeneration) async {
    final stored = await localStore.loadConversationPauses();
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    final loaded = <String, ConversationPause>{
      for (final pause in stored) pause.conversationId: pause,
    };
    var changed = loaded.length != conversationPauses.length;
    for (final entry in loaded.entries) {
      final known = conversationPauses[entry.key];
      if (known == null || known.generation != entry.value.generation) {
        changed = true;
      }
    }
    conversationPauses = loaded;
    if (changed) notifyListeners();
  }

  /// Forgets the pause of a conversation the user left. The server sends
  /// none of its events after the leave.
  Future<void> _dropConversationPause(String conversationId) async {
    _pauseReplayRequests.remove(conversationId);
    try {
      await localStore.clearConversationPause(conversationId);
    } catch (_) {
      // Left in place: it only holds back events the server no longer sends.
    }
    if (conversationPauses.containsKey(conversationId)) {
      conversationPauses = <String, ConversationPause>{
        for (final entry in conversationPauses.entries)
          if (entry.key != conversationId) entry.key: entry.value,
      };
      notifyListeners();
    }
  }

  /// Asks the next foreground pass to replay a paused conversation from the
  /// event it stopped at. Applies the same events in the same order; if the
  /// cause remains the conversation stays paused with the failure recorded
  /// again. Nothing is skipped.
  Future<void> retryConversationPause(String conversationId) async {
    final pause = conversationPauses[conversationId];
    if (pause == null || !pause.retryable) return;
    _pauseReplayRequests.add(conversationId);
    await _catchUpSyncEvents();
  }

  Future<void> _replayRequestedPauses(
      Session current, ApiClient client, int ownerGeneration) async {
    while (_pauseReplayRequests.isNotEmpty) {
      final conversationId = _pauseReplayRequests.first;
      _pauseReplayRequests.remove(conversationId);
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      await _replayPausedConversation(
          conversationId, current, client, ownerGeneration);
    }
  }

  /// Marks a conversation whose stream the server no longer keeps: it stays
  /// paused and only leaving it is offered.
  Future<void> _pauseExpired(String conversationId) async {
    final latest = await localStore.loadConversationPause(conversationId);
    if (latest == null) return;
    final next = await localStore.pauseConversation(
      conversationId: conversationId,
      failedEventId: max(latest.failedEventId, latest.resumeAfter + 1),
      kind: SyncFailureKind.cursorExpired,
      failedEventType: latest.failedEventType,
      failedRef: latest.failedRef,
    );
    conversationPauses = <String, ConversationPause>{
      ...conversationPauses,
      conversationId: next,
    };
    notifyListeners();
  }

  /// Applies a paused conversation's events in order, from the one above
  /// what was already replayed up to the global cursor, then lifts the
  /// pause. Events above the global cursor are left to the global stream,
  /// which reaches them next. Runs inside the sync owner's pass, before it
  /// reads the global stream, under the same lease and crypto queue. Only
  /// an explicit retry runs it: a failing event is never retried on every
  /// pass.
  Future<void> _replayPausedConversation(String conversationId, Session current,
      ApiClient client, int ownerGeneration) async {
    final pause = await localStore.loadConversationPause(conversationId);
    if (pause == null || !pause.retryable) return;
    final generation = pause.generation;
    final through = await localStore.loadSyncCursor();
    var after = pause.resumeAfter;
    final received = <ReceivedMessageEnvelope>[];
    const pageSize = 200;
    try {
      while (true) {
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        final ConversationSyncPage syncPage;
        try {
          syncPage = await client.conversationSyncPage(
              current.token, conversationId,
              after: after, limit: pageSize);
        } on ApiException catch (err) {
          if (err.statusCode == 403) {
            // No longer a member: the leave or removal settles the rest, and
            // the pause stays until the group is dropped.
            return;
          }
          if (err.statusCode == 409 &&
              err.serverCode == 'conversation_recovery_required') {
            await _pauseExpired(conversationId);
            return;
          }
          rethrow;
        }
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        final events = syncPage.events;
        final pageStart = after;
        var last = after;
        for (final event in events) {
          if (event.id <= last || event.conversationId != conversationId) {
            throw StateError('conversation sync events are not in order');
          }
          last = event.id;
        }
        final due = events.where((event) => event.id <= through).toList();
        final repair = _SyncPageRepair(
          client: client,
          token: current.token,
          events: due,
          processed: localStore.hasProcessedMlsMessage,
        );
        for (final event in due) {
          if (!_syncOwnerActive(current, ownerGeneration)) return;
          if (event.id == pause.failedEventId &&
              _replayEventChanged(pause, event)) {
            // The server now serves another event under the id that
            // failed. The original failure stays recorded; replacing it
            // needs a reviewed repair path, not a silent retry.
            developer.log('sync_conversation_replay_event_changed',
                name: 'veritra.sync');
            return;
          }
          final isCrypto = _isCryptoSyncEvent(event.type);
          final unknownCrypto = !isCrypto &&
              !_knownProjectionEvent(event.type) &&
              _failsClosedEvent(event.type);
          if (!isCrypto && !unknownCrypto) {
            // A projection event: the global stream already handled it.
            after = event.id;
            continue;
          }
          try {
            if (unknownCrypto) {
              throw SyncEventFailure(SyncFailureKind.unsupportedEvent,
                  eventId: event.id,
                  eventType: event.type,
                  conversationId: conversationId);
            }
            final envelope = await _processCryptoSyncEvent(event, repair,
                wake: null, client: client);
            if (envelope != null) {
              received.add(envelope);
              if (received.length >= _receivedBatchLimit) {
                await _publishReceived(received, current, ownerGeneration);
              }
            }
          } catch (err) {
            if (err is! SyncEventFailure ||
                !failurePausesConversation(err) ||
                !await _pauseConversationAt(
                    err, current, client, ownerGeneration)) {
              rethrow;
            }
            // Paused again, at this event. Whatever applied before it
            // stays applied and moved the resume point with it.
            return;
          }
          after = event.id;
        }
        // A short page is not the end: the client halves the page size when a
        // reply is over the response limit, and a server may send short
        // pages. The stream ends at an empty page, or at an event the global
        // stream has not reached yet.
        if (due.length < events.length) break;
        if (syncPage.truncated) {
          // The server's scan budget ended this page early, so an empty or
          // short page is not the end. Everything it scanned is applied or
          // hidden from this device for good (D92), so the next page starts
          // at the scan position. It must move forward, or the stream would
          // be asked for the same page again.
          final scanned = syncPage.scannedThrough;
          if (scanned == null || scanned <= pageStart) {
            throw StateError('conversation sync scan did not advance');
          }
          after = max(after, scanned);
          if (after >= through) break;
          continue;
        }
        if (events.isEmpty) break;
      }
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      final cleared = await localStore.clearConversationPause(conversationId,
          generation: generation);
      if (cleared && _syncOwnerActive(current, ownerGeneration)) {
        conversationPauses = <String, ConversationPause>{
          for (final entry in conversationPauses.entries)
            if (entry.key != conversationId) entry.key: entry.value,
        };
        // Membership may have moved on while the conversation was paused.
        _mlsReconcileRequested = true;
        notifyListeners();
      }
    } finally {
      try {
        await _publishReceived(received, current, ownerGeneration);
      } catch (_) {
        // Shown by the next pass, like any committed envelope.
      }
    }
  }

  /// Whether the server's event at the id that failed is not the one that
  /// failed (another type, or another message it points at).
  bool _replayEventChanged(ConversationPause pause, SyncEvent event) {
    final type = pause.failedEventType;
    if (type != null && event.type != type) return true;
    final ref = _failedRefOf(event);
    return pause.failedRef != null && ref != null && ref != pause.failedRef;
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

  /// The record-limit recovery (D70 S4): leaves the conversation whose
  /// group outgrew its cap, then applies events again. The server sends
  /// none of its events after the leave, so the stopped one is not skipped
  /// on this device's word. The UI must get explicit confirmation first.
  /// Returns whether the conversation was left.
  Future<bool> leaveConversationAfterSyncRecovery(
      {required bool confirmed}) async {
    if (!confirmed) {
      throw ArgumentError.value(
          confirmed, 'confirmed', 'leaving a conversation needs confirmation');
    }
    final recovery = syncRecovery;
    final conversationId = recovery?.conversationId;
    if (recovery == null ||
        conversationId == null ||
        !recovery.choices.contains(SyncRecoveryChoice.leaveConversation)) {
      return false;
    }
    if (!await leaveConversation(conversationId)) return false;
    // Cleared only if still the same stop: the dialog may have stayed open
    // meanwhile.
    final stored = await localStore.loadSyncRecovery();
    if (stored != null &&
        (stored.kind != recovery.kind || stored.eventId != recovery.eventId)) {
      return true;
    }
    await localStore.saveSyncRecovery(null);
    syncRecovery = null;
    deviceRecoveryRequired = false;
    syncError = null;
    _setConnectionStatus(ConnectionStatus.connecting);
    notifyListeners();
    await _catchUpSyncEvents();
    return true;
  }

  /// The destructive recovery: signs out and removes this device's identity,
  /// encryption state and local history, so it can be linked again from
  /// another device. The UI must get explicit confirmation first.
  Future<void> relinkAfterSyncRecovery({required bool confirmed}) async {
    if (!confirmed) {
      throw ArgumentError.value(confirmed, 'confirmed',
          'relinking deletes local history and needs confirmation');
    }
    final requested = session;
    await _run(() async {
      // The confirmation dialog may have stayed open while recovery ended,
      // changed kind or the session changed (C-f4bf51f0c756): relinking
      // deletes local data, so it runs only while the same session is
      // still stopped at a failure that offers it.
      final recovery = syncRecovery;
      if (requested == null ||
          !identical(session, requested) ||
          recovery == null ||
          !recovery.choices.contains(SyncRecoveryChoice.relink)) {
        return;
      }
      final current = session;
      final client = api;
      await _stopPush(current, client);
      final detached = await _clearLocalSession(keepApiOpen: true);
      await _revokeAndClose(current, detached);
    });
  }

  /// SQLite codes that pass by themselves: BUSY, LOCKED, NOMEM, IOERR, FULL.
  static const _transientSqliteCodes = <int>{5, 6, 7, 10, 13};

  /// Errno values (and Windows codes) that pass: no space, I/O error, busy,
  /// out of memory or handles, quota.
  static const _transientFileErrors = <int>{5, 11, 12, 16, 24, 28, 122, 112};

  static bool _isTransientStorageError(Object err) {
    final code = localStorageErrorCode(err);
    if (code != null) return _transientSqliteCodes.contains(code);
    if (err is FileSystemException) {
      return _transientFileErrors.contains(err.osError?.errorCode);
    }
    return false;
  }

  /// SQLite CORRUPT (11) or NOTADB (26): the database file is damaged.
  static bool _isDamagedStorage(Object err) {
    final code = localStorageErrorCode(err);
    return code == 11 || code == 26;
  }

  /// Sync found the local database damaged while the app ran. The session
  /// is put down in memory; the only store call is a best-effort release of
  /// the sync lease, whose failure is ignored. The app then shows the
  /// recovery screen a failed restore shows. Retry restores the session
  /// from the same open database handle (the store keeps it cached), so it
  /// helps only if the damage does not touch what a restore reads; the
  /// confirmed reset moves the database aside (C-d0ba626ecdd7). This runs
  /// inside the sync owner's own pass, so the owner is disposed, never
  /// drained.
  void _enterDamagedStorageRecovery() {
    _sessionGeneration++;
    _stopProfiles();
    _removalHolds.clear();
    _removalHoldsLoaded = null;
    _removalHoldsSettled();
    _syncStartFailed = null;
    final owner = _syncOwner;
    _syncOwner = null;
    owner?.dispose();
    final lease = _syncLease;
    _syncLease = null;
    if (lease != null) {
      unawaited(localStore.releaseSyncLease(lease).catchError((Object _) {}));
    }
    final mls = _mlsCrypto;
    if (mls != null) unawaited(mls.dispose().catchError((Object _) {}));
    final subscription = _syncSubscription;
    _syncSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    final previousSync = sync;
    sync = null;
    if (previousSync != null) {
      unawaited(previousSync.dispose().catchError((Object _) {}));
    }
    _wakeRun?.cancel();
    api?.close();
    api = null;
    session = null;
    _resetSessionMemory();
    localStoreFailure = null;
    _localDataDamaged = true;
    lifecycle = SessionLifecycle.recoveryRequired;
    recoveryMessage = l10n.recoveryStorageDamaged;
    notifyListeners();
  }

  /// A local storage failure that will not pass by itself: another SQLite
  /// code (constraint, corrupt, not a database...) or a file error that is
  /// not a transient one.
  static bool _isDurableStorageError(Object err) =>
      (localStorageErrorCode(err) != null || err is FileSystemException) &&
      !_isTransientStorageError(err);

  static bool _isTransientSyncError(Object err) {
    if (err is LocalNoticeCapacityException) return true;
    if (err is CryptoOperationCancelled || err is WakeWorkCancelled)
      return true;
    if (err is ApiException) {
      return err.statusCode == 408 ||
          err.statusCode == 429 ||
          err.statusCode >= 500;
    }
    // A failed local commit that can pass (busy, full, I/O) rolled back with
    // the ratchet, so a retry is safe (P1). Other storage errors are durable.
    if (_isTransientStorageError(err)) return true;
    return err is SocketException ||
        err is TimeoutException ||
        err is HttpException ||
        err is HandshakeException;
  }

  /// The server's `device.member_linked` notice (D96): IDs only, sent to the
  /// account that holds a group's coordinator device.
  static bool _isMemberLinkedNotice(String type) =>
      type == 'device.member_linked';

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
      type == 'mls.revocation.completed' ||
      type == 'device_list.updated';

  /// Refreshes what a run of projection events asks for, once per kind: a
  /// burst of device or membership events costs one device-list and one
  /// conversation-list request, not one per event. Devices are read before
  /// conversations, as for a single event, and the open chat is reloaded
  /// only when an event in the run names it.
  Future<void> _refreshProjectionForSyncEvents(List<SyncEvent> events) async {
    var devices = false;
    var recoveryStatus = false;
    var conversationList = false;
    var selectedMessages = false;
    final receipts = <String>{};
    for (final event in events) {
      final type = event.type;
      _profileSyncEvent(event);
      if (_isMemberLinkedNotice(type)) {
        // A co-member linked a device and this device may coordinate the
        // group change: run the membership pass now instead of waiting for
        // the fallback. IDs only; nothing local changed, so no refresh.
        _mlsReconcileRequested = true;
        continue;
      }
      if (type.startsWith('device.') ||
          type.startsWith('membership.') ||
          type.startsWith('conversation.')) {
        _mlsReconcileRequested = true;
      }
      if (type.startsWith('device.')) {
        devices = true;
        conversationList = true;
      } else if (type.startsWith('conversation.') ||
          type.startsWith('membership.') ||
          type == 'retention.updated') {
        if (event.conversationId != null) {
          membersByConversation = Map.of(membersByConversation)
            ..remove(event.conversationId);
        } else if (type.startsWith('membership.')) {
          membersByConversation = {};
        }
        if (type == 'conversation.posting_policy.updated' &&
            event.payload is Map) {
          try {
            final updated = Conversation.fromJson(
                Map<String, Object?>.from(event.payload as Map));
            conversations = <Conversation>[
              for (final c in conversations)
                if (c.id == updated.id)
                  c.copyWith(postingRestricted: updated.postingRestricted)
                else
                  c,
            ];
          } catch (_) {}
        }
        conversationList = true;
      } else if (type.startsWith('reaction.') ||
          type == 'read_receipt.updated') {
        if (event.conversationId == selectedConversationId) {
          selectedMessages = true;
          if (type == 'read_receipt.updated' && event.conversationId != null) {
            receipts.add(event.conversationId!);
          }
        }
      } else if (type == 'device_list.updated') {
        _noteDeviceListUpdated();
      } else if (type.startsWith('account.')) {
        if (_noteAccountSyncEvent(event)) recoveryStatus = true;
      } else if (type != 'mls.revocation.pending' &&
          type != 'mls.revocation.completed' &&
          _failsClosedEvent(type)) {
        throw SyncEventFailure(SyncFailureKind.unsupportedEvent,
            eventId: event.id, eventType: type);
      }
    }
    if (devices) await _refreshDevices();
    if (recoveryStatus) await refreshRecoveryKeyStatus();
    if (conversationList) {
      await _refreshConversations(notify: false, persist: false);
      // Projection refreshes are batched: reload invalidated rosters once
      // after the batch, so profile rotation need not wait for the daily check.
      await _profileLoadRosters();
    }
    if (selectedMessages) {
      await refreshSelectedMessages(notify: false, persist: false);
    }
    for (final conversationId in receipts) {
      unawaited(refreshReceipts(conversationId));
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
      SyncEvent event, _SyncPageRepair repair,
      {WakeRunContext? wake, required ApiClient client}) async {
    final current = session;
    final mls = _mlsCrypto;
    if (current == null || mls == null) return null;
    // A background pass uses only the bounded inbound operations, fenced by
    // its permit inside the same storage transaction.
    final bounded = wake == null
        ? null
        : mls is BoundedMlsConversationCryptoService
            ? mls
            : throw const WakeWorkCancelled();
    SyncEventFailure failure(SyncFailureKind kind, [Object? cause]) =>
        SyncEventFailure(kind,
            eventId: event.id,
            eventType: event.type,
            conversationId: event.conversationId,
            damagedStorage: cause != null && _isDamagedStorage(cause));
    // A record over its cap (D70) names the record's conversation, which
    // may not be the event's (a Welcome, the device record).
    SyncEventFailure recordLimit(CryptoRecordLimitExceeded err) =>
        SyncEventFailure(SyncFailureKind.recordLimit,
            eventId: event.id,
            eventType: event.type,
            conversationId: err.conversationId);
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
        // This device's own commit, accepted but not yet completed by the
        // outbox (answer lost, or the app stopped): sync merges it, so
        // note its update path here as the outbox would have.
        final ownPathCommit = message.kind == 'commit' &&
            message.senderDeviceId == current.deviceId &&
            await _queuedPathCommit(message.idempotencyKey);
        if (message.kind == 'welcome' &&
            message.recipientDeviceId == current.deviceId) {
          if (await _skipWelcomeBeforeLeave(current, event, message,
              wake: wake, failure: failure)) {
            return null;
          }
          await _dropLeftBeforeWelcome(current, message.conversationId,
              wake: wake, failure: failure);
          // Write-ahead (TASK-028): a Welcome uses up one of this device's
          // published key packages, so its replacement is owed durably
          // before the Welcome commits. Counted once per Welcome; one that
          // then fails stays counted (over-supply, capped).
          await _oweKeyPackages(current, 1, welcome: message.id);
        }
        try {
          if (bounded != null) {
            await bounded.processMlsMessageBounded(message,
                checkCanCommit: wake!.checkCanCommit);
          } else {
            await mls.processMlsMessage(message);
          }
        } catch (err) {
          if (_isTransientSyncError(err)) rethrow;
          if (_isDurableStorageError(err)) {
            throw failure(SyncFailureKind.localStorage, err);
          }
          if (err is CryptoRecordLimitExceeded) throw recordLimit(err);
          throw failure(err is FormatException
              ? SyncFailureKind.mlsControlMalformed
              : SyncFailureKind.mlsState);
        }
        if (ownPathCommit) {
          await _noteSelfUpdate(
              current,
              (policy) => policy.recordPathCommit(
                  message.conversationId, DateTime.now()));
        }
        if (message.kind == 'welcome' &&
            message.recipientDeviceId == current.deviceId) {
          // The leaf key came from a key package published earlier: update
          // it soon. Only noted here; staging waits for a foreground pass.
          await _noteSelfUpdate(
              current,
              (policy) =>
                  policy.recordJoined(message.conversationId, DateTime.now()));
          // K0 step 8: the conversation is no longer read-only.
          _grouplessChecked.add(message.conversationId);
          if (_grouplessConversations.remove(message.conversationId) &&
              !_disposed) {
            notifyListeners();
          }
          if (wake != null) {
            // Publishing is an outbound write; the foreground does it.
            _replenishAfterWake = true;
          } else {
            await _replenishKeyPackage();
          }
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
            await _commitExpiredTombstone(event, id, wake);
            return null;
          }
          resolved = fetched;
        }
        if (resolved.id != id ||
            (event.conversationId != null &&
                resolved.conversationId != event.conversationId)) {
          throw failure(SyncFailureKind.applicationUndecryptable);
        }
        // A post in a community's shared group is decoded by the group's
        // kind, which only the conversation list knows. A device that has
        // just taken the Welcome may not have listed it yet; decoding first
        // would turn the post into a permanent invalid row.
        if (_metadataChannel(resolved.cryptoMetadata) != null &&
            !conversations.any((c) => c.id == resolved.conversationId)) {
          await _refreshConversations(notify: false, persist: false);
        }
        await _ensureConversationAuthority(resolved.conversationId,
            client: client);
        // A message this device can never decrypt does not throw: the
        // crypto service commits past it with a placeholder row (D54), and
        // the envelope is shown as that placeholder. What still throws here
        // is a malformed event or a local failure, and that stops sync.
        try {
          if (bounded != null) {
            await bounded.processApplicationMessageBounded(resolved, event.id,
                checkCanCommit: wake!.checkCanCommit);
          } else {
            await mls.processApplicationMessage(resolved, event.id);
          }
        } catch (err) {
          if (_isTransientSyncError(err)) rethrow;
          if (_isDurableStorageError(err)) {
            throw failure(SyncFailureKind.localStorage, err);
          }
          if (_provenExpired(resolved.expiresAt)) {
            await _commitExpiredTombstone(event, id, wake);
            return null;
          }
          if (err is CryptoRecordLimitExceeded) throw recordLimit(err);
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
        if (event.conversationId != null &&
            call.conversationId != event.conversationId) {
          throw failure(SyncFailureKind.applicationUndecryptable);
        }
        final Map<String, Object?>? signal;
        try {
          signal = bounded != null
              ? await bounded.processCallSignalBounded(call, event.id,
                  checkCanCommit: wake!.checkCanCommit)
              : await mls.processCallSignal(call, event.id);
        } catch (err) {
          if (_isTransientSyncError(err)) rethrow;
          if (_isDurableStorageError(err)) {
            throw failure(SyncFailureKind.localStorage, err);
          }
          if (_provenExpired(call.expiresAt)) {
            await _commitExpiredTombstone(event, call.id, wake);
            return null;
          }
          if (err is CryptoRecordLimitExceeded) throw recordLimit(err);
          throw failure(SyncFailureKind.applicationUndecryptable);
        }
        if (signal != null) {
          _callSignals.add(IncomingCallSignal(call, signal));
        } else if (isTerminalCallState(call.state)) {
          // A hang-up, decline or miss carries no new signal (the server
          // keeps the earlier metadata, which was already read), but the
          // call service must still hear that the call is over.
          _callSignals.add(IncomingCallSignal(call, const <String, Object?>{}));
        }
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
  /// one. (One the crypto service can never decrypt does not fail: it is
  /// committed past with a placeholder, D54.)
  Future<void> _commitExpiredTombstone(
      SyncEvent event, String targetId, WakeRunContext? wake) async {
    final cursor = await localStore.loadSyncCursor();
    await localStore.commitSyncEvent(SyncEventCommit(
      eventKey: 'expired:${event.id}:$targetId',
      conversationId: event.conversationId ?? '',
      expectedCursor: cursor,
      cursor: event.id,
      checkCanCommit: wake?.checkCanCommit,
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

  /// Received envelopes already committed whose history could not be read
  /// to show them, and the sync owner generation that committed them. The
  /// cursor is past them, so a later catch-up of that owner shows them, even
  /// with no new events; no other owner ever does.
  final _unpublishedReceived = <ReceivedMessageEnvelope>[];
  int? _unpublishedGeneration;

  /// Shows [received] (already committed) with the decrypted history of
  /// their conversations in one notification, then empties the list.
  /// Envelopes an earlier try of the same owner could not show go first.
  /// The history is read first, so no frame draws a decrypted message as
  /// ciphertext; if that read fails, the envelopes move to
  /// [_unpublishedReceived] for the owner's next try and the error is
  /// rethrown. Nothing is applied once another session owns sync, and work
  /// kept for an owner that no longer runs is dropped.
  Future<void> _publishReceived(
    List<ReceivedMessageEnvelope> received,
    Session owner,
    int ownerGeneration,
  ) async {
    if (_unpublishedGeneration != _sessionGeneration) {
      _unpublishedReceived.clear();
      _unpublishedGeneration = null;
    }
    if (_unpublishedGeneration == ownerGeneration) {
      received.insertAll(0, _unpublishedReceived);
      _unpublishedReceived.clear();
      _unpublishedGeneration = null;
    }
    if (received.isEmpty) return;
    final histories = <String, ConversationHistory>{};
    try {
      for (final id in received.map((item) => item.conversationId).toSet()) {
        histories[id] = await _loadHistory(id);
      }
    } catch (_) {
      if (_syncOwnerActive(owner, ownerGeneration)) {
        _unpublishedReceived.addAll(received);
        _unpublishedGeneration = ownerGeneration;
      }
      received.clear();
      rethrow;
    }
    if (_syncOwnerActive(owner, ownerGeneration)) {
      _mergeReceivedEnvelopes(received);
      _history.addAll(histories);
      notifyListeners();
      unawaited(_scheduleExpiryPurge());
      // A key may have come with these messages (W11).
      unawaited(profiles?.onKeysMayHaveArrived().catchError((Object _) {}));
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

  /// Ends the local session. With [keepApiOpen] the API client is detached
  /// but not closed and is returned, so sign-out can still revoke the token
  /// on the server; the caller closes it. Otherwise it is closed here and
  /// null is returned.
  Future<ApiClient?> _clearLocalSession({
    bool preserveDeviceIdentity = false,
    bool preserveOutbox = false,
    bool drainSyncOwner = true,
    // Set only when the server rejected the session (401): the same person
    // signs in again to their drafts. Sign-out and relinking wipe them.
    bool keepDrafts = false,
    bool keepApiOpen = false,
  }) async {
    _sessionEnds++;
    _sessionsEnding++;
    try {
      return await _clearLocalSessionSteps(
        preserveDeviceIdentity: preserveDeviceIdentity,
        preserveOutbox: preserveOutbox,
        drainSyncOwner: drainSyncOwner,
        keepDrafts: keepDrafts,
        keepApiOpen: keepApiOpen,
      );
    } finally {
      _sessionsEnding--;
    }
  }

  Future<ApiClient?> _clearLocalSessionSteps({
    required bool preserveDeviceIdentity,
    required bool preserveOutbox,
    required bool drainSyncOwner,
    required bool keepDrafts,
    required bool keepApiOpen,
  }) async {
    _sessionGeneration++;
    // K1: before any await, so a run under way can never write its state
    // (with rk_pub) back into a store this is about to wipe.
    _k1State = null;
    _stopK1Backups();
    _stopProfiles();
    _syncStartFailed = null;
    _keyPackagesOwed = true;
    _keyPackageRetryFailures = 0;
    _keyPackageRetryAt = null;
    // Native permits go first, then capture, then the private notice state
    // (cleared with the rest of the local session below).
    _wakeRun?.cancel();
    final revoke = beforeLocalSessionClear;
    if (revoke != null) {
      try {
        await revoke();
      } catch (_) {
        // The bumped generation already fences any late background commit.
      }
    }
    if (cryptoService case final NoticeCaptureConsumer capture) {
      capture.noticeCaptureEnabled = false;
    }
    await _flushDraftsBeforeSessionEnd();
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
      await localStore.clearCachedState(
          preserveOutbox: preserveOutbox, keepDrafts: keepDrafts);
    } else {
      await localStore.clear();
      // The MLS outbox went with the store; an item kept for a later
      // session (the branch above) keeps its "accepted, unfinished" mark,
      // or a re-send could meet a refusal that drops an accepted commit.
      _mlsAcceptedUnfinished.clear();
    }
    session = null;
    final detachedApi = api;
    api = null;
    if (!keepApiOpen) detachedApi?.close();
    _resetSessionMemory();
    lifecycle = SessionLifecycle.ready;
    recoveryMessage = null;
    return keepApiOpen ? detachedApi : null;
  }

  /// Drops everything one session kept in memory: lists, flags, caches,
  /// request decisions, retry state and timers. It makes no store call and
  /// leaves [session], [api], [lifecycle] and [recoveryMessage] to the
  /// caller. Shared by sign-out and the damaged-storage stop, so nothing of
  /// one account carries over to the next (C-d0ba626ecdd7). The MLS
  /// "accepted, unfinished" marks are not dropped here: they follow the
  /// stored MLS outbox, not the session.
  void _resetSessionMemory() {
    phoneNoticesAllowed = false;
    // K1: a run under way keeps its own copies; nothing of this identity's
    // backup state survives in memory or is written back after a wipe.
    _k1State = null;
    _stopK1Backups();
    _conversationsFromServer = false;
    _keyPackagesOwed = true;
    _keyPackageRetryFailures = 0;
    _keyPackageRetryAt = null;
    if (cryptoService case final NoticeCaptureConsumer capture) {
      capture.noticeCaptureEnabled = false;
    }
    _cancelDraftTimers();
    _activeChatViews = 0;
    _updateScreenGuard();
    conversations = <Conversation>[];
    conversationsLoaded = false;
    communitiesLoaded = false;
    invitesLoaded = false;
    invitesLoadFailed = false;
    devicesLoaded = false;
    devices = <Device>[];
    recoveryKeyStatus = null;
    recoveryFollowUp = null;
    passkeyList = const <PasskeyRecord>[];
    passkeysLoaded = false;
    passkeyNotice = null;
    _ownPasskeyChanges.clear();
    _passwordLeakDay = null;
    _recoveredDevice = false;
    _recoveredMarkGeneration = -1;
    _recoveredMarkLoad = null;
    _grouplessConversations.clear();
    _grouplessChecked.clear();
    _lastKnownNoPeer.clear();
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
    _resetMlsRetries();
    _outboxLocalFailures = 0;
    _mlsOutboxLocalFailures = 0;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _cancelCatchUpRetry();
    _failedMlsConversations.clear();
    _mlsPendingSeen.clear();
    _mlsReconcileNow.clear();
    _mlsReconcileRequested = true;
    _manualRetryKey = null;
    _refreshAfterWake = false;
    _replenishAfterWake = false;
    _keyPackagePruneAt = null;
    _unpublishedReceived.clear();
    _unpublishedGeneration = null;
    _loadingMessageConversations.clear();
    _messageLoadErrors.clear();
    selectedConversationId = null;
    conversationPrefs = {};
    _pins.clear();
    starredMessages = {};
    showArchivedChats = false;
    _copiedHistory = {};
    _resetDeviceLinkState();
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
    conversationPauses = const <String, ConversationPause>{};
    _pauseReplayRequests.clear();
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

  /// Conversations whose history reload after a purge failed, and the
  /// session they belong to. Retried by the next purge, which is armed even
  /// when nothing else is due to expire.
  final Set<String> _historyReloadPending = <String>{};
  Session? _historyReloadSession;

  /// Deletes what has expired from the encrypted database, then from the
  /// lists the screens read, and arms the timer for the next expiry (W2).
  Future<void> purgeExpiredMessages() async {
    final current = session;
    if (current == null || _purgingExpired) return;
    _purgingExpired = true;
    final generation = _sessionGeneration;
    final reloadSession = _historyReloadSession;
    if (reloadSession == null || !_sameSession(reloadSession)) {
      _historyReloadPending.clear();
    }
    try {
      Set<String> touched;
      try {
        touched = await localStore.purgeExpiredMessages();
        // A reload that keeps failing keeps its growing pause.
        if (_historyReloadPending.isEmpty) _expiryBackoff = Duration.zero;
      } catch (_) {
        // The delete is retried with a growing pause, on resume and on
        // restart. The lists below are still pruned, so expired text leaves
        // an open chat even while the database delete keeps failing.
        touched = <String>{};
        _expiryBackoff = _nextExpiryBackoff(_expiryBackoff);
      }
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
      if (changed) messagesByConversation = next;
      final reload = <String>{...touched, ..._historyReloadPending};
      if (_mlsCrypto != null && reload.isNotEmpty) {
        var failed = false;
        for (final id in reload) {
          if (!_history.containsKey(id) && id != selectedConversationId) {
            _historyReloadPending.remove(id);
            continue;
          }
          try {
            final history = await _loadHistory(id);
            if (generation != _sessionGeneration) return;
            _history[id] = history;
            _historyReloadPending.remove(id);
          } catch (_) {
            // The cached history still holds the deleted rows. Drop the
            // expired ones now, so no view (timeline, replies, pins,
            // starred) shows them; reactions come back with the reload,
            // which is tried again.
            if (generation != _sessionGeneration) return;
            final cached = _history[id];
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            bool live(LocalMessage m) =>
                m.expiresAt == null || m.expiresAt! > nowMs;
            if (cached != null && !cached.messages.every(live)) {
              _history[id] = ConversationHistory(
                conversationId: id,
                messages: cached.messages.where(live).toList(),
                reactions: const [],
                copiedKeys: cached.copiedKeys,
              );
            }
            _historyReloadPending.add(id);
            _historyReloadSession = current;
            failed = true;
          }
          changed = true;
        }
        if (failed) _expiryBackoff = _nextExpiryBackoff(_expiryBackoff);
      }
      if (changed) {
        if (generation != _sessionGeneration) return;
        notifyListeners();
      }
    } catch (_) {
      // Never blocks the app; the next purge tries again.
      _expiryBackoff = _nextExpiryBackoff(_expiryBackoff);
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
    final reloadSession = _historyReloadSession;
    final reloadPending = _historyReloadPending.isNotEmpty &&
        reloadSession != null &&
        _sameSession(reloadSession);
    if (next == null && !reloadPending) return;
    // A failed history reload is retried after the pause even when nothing
    // else is due to expire.
    var delay =
        next?.difference(DateTime.now().toUtc()) ?? const Duration(days: 1);
    if (reloadPending && delay > _expiryBackoff) delay = _expiryBackoff;
    if (delay < const Duration(milliseconds: 500)) {
      delay = const Duration(milliseconds: 500);
    }
    if (delay < _expiryBackoff) delay = _expiryBackoff;
    // Timers beyond a day are re-armed by resume and by the next write.
    if (delay > const Duration(days: 1)) delay = const Duration(days: 1);
    _expiryTimer = Timer(delay, () {
      _expiryTimer = null;
      unawaited(purgeExpiredMessages());
    });
  }

  /// Outbox workers, their retry schedulers and the sync drain that
  /// [dispose] starts without awaiting. Tracking only records the futures
  /// AppState already creates; it changes no scheduling.
  final Set<Future<void>> _backgroundWork = <Future<void>>{};

  Future<void> _trackBackground(Future<void> Function() work) {
    final future = work();
    late final Future<void> settled;
    settled = future
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _backgroundWork.remove(settled));
    _backgroundWork.add(settled);
    return future;
  }

  /// Completes once every tracked background operation (outbox and MLS
  /// outbox passes, their retry scheduling, and the sync drain [dispose]
  /// starts) has settled, including ones started while waiting. Tests
  /// await it before closing the store under a disposed AppState.
  @visibleForTesting
  Future<void> get backgroundWorkIdle async {
    while (_backgroundWork.isNotEmpty) {
      await Future.wait(_backgroundWork.toList());
    }
  }

  Future<void> _flushOutbox() => _trackBackground(_flushOutboxRun);

  Future<void> _flushOutboxRun() async {
    if (_flushingOutbox) {
      _flushOutboxRequested = true;
      return;
    }
    _flushingOutbox = true;
    try {
      do {
        _flushOutboxRequested = false;
        final manualRetry = _manualRetryKey;
        final owner = session;
        try {
          await _flushOutboxOnce();
          _outboxLocalFailures = 0;
        } catch (err) {
          // A local storage failure leaves every envelope queued. Callers
          // leave this future unawaited, so nothing may escape; the retry
          // timer tries again with backoff (TASK-042). Only a pass that
          // carried a retry the person tapped reports it, under
          // [Ops.send]; a background pass is no user action.
          _outboxLocalFailures++;
          if (manualRetry != null &&
              owner != null &&
              _manualRetryKey == manualRetry &&
              _sameSession(owner)) {
            _opErrors[Ops.send] = describeError(err, l10n);
            notifyListeners();
          }
        }
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
        _selfUpdatePolicyFor(current)?.recordSent(envelope.conversationId);
      } catch (err) {
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        await _recordOutboxFailure(envelope, err, record.attemptCount);
        if (err is ApiException && err.statusCode == 401) {
          await _clearLocalSession(
              preserveDeviceIdentity: true,
              keepDrafts: true,
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

  /// Consecutive application outbox passes or reads that failed locally.
  int _outboxLocalFailures = 0;

  Future<void> _scheduleOutboxRetry() =>
      _trackBackground(_scheduleOutboxRetryRun);

  Future<void> _scheduleOutboxRetryRun() async {
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    // The timer belongs to the session that read the outbox: one that ended
    // or was replaced during the read arms nothing for its successor.
    final owner = session;
    final generation = _sessionGeneration;
    if (_disposed || owner == null || api == null) return;
    final List<PendingEnvelopeRecord> records;
    final Set<String> heldBack;
    try {
      records = await localStore.pendingEnvelopeRecords();
      // Held-back conversations wait for the MLS worker, which flushes when
      // it finishes; scheduling them here would spin.
      heldBack = _mlsCrypto == null
          ? const <String>{}
          : (await localStore.pendingMlsMessages())
              .map((message) => message.conversationId)
              .toSet();
    } catch (_) {
      // Unreadable outbox: try again later rather than wait for a wake.
      if (_disposed || !_syncOwnerActive(owner, generation)) return;
      _outboxLocalFailures++;
      _armOutboxRetry(_localRetryDelay(_outboxLocalFailures));
      return;
    }
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
    var delay = earliest?.difference(now);
    // After a local failure a queued envelope may have no due time (it was
    // never tried) or a stale one, so wait at least the local backoff.
    if (_outboxLocalFailures > 0) {
      final fallback = _localRetryDelay(_outboxLocalFailures);
      if (delay == null || delay < fallback) delay = fallback;
    }
    if (delay == null || _disposed || !_syncOwnerActive(owner, generation)) {
      return;
    }
    _armOutboxRetry(delay);
  }

  void _armOutboxRetry(Duration delay) {
    // Two schedulers may overlap their reads; only the last timer stays.
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer =
        Timer(delay < _minimumRetryDelay ? _minimumRetryDelay : delay, () {
      _outboxRetryTimer = null;
      unawaited(_flushOutbox());
    });
  }

  /// Delivers MLS control messages (I34). One worker runs at a time; a call
  /// while it runs asks for one more pass. It never throws, so callers may
  /// leave its future unawaited.
  Future<void> _flushMlsOutbox() => _trackBackground(_flushMlsOutboxRun);

  Future<void> _flushMlsOutboxRun() async {
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
          _mlsOutboxLocalFailures = 0;
        } catch (_) {
          // A local storage failure leaves every item queued; the retry
          // timer tries again with backoff, even for an item that names no
          // due time.
          _mlsOutboxLocalFailures++;
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
    // Items settled some other way no longer need finishing.
    _mlsAcceptedUnfinished.removeWhere(
        (key) => !messages.any((message) => message.idempotencyKey == key));
    final byConversation = <String, List<PendingMlsMessage>>{};
    for (final message in messages) {
      byConversation
          .putIfAbsent(message.conversationId, () => <PendingMlsMessage>[])
          .add(message);
    }
    final failed = <String>{};
    final now = DateTime.now().toUtc();
    for (final entry in byConversation.entries) {
      // A conversation paused by its own sync failure keeps its queued
      // commits and Welcomes untouched, unsent and unfinished (C1 P1): its
      // group must not move until a replay has applied the missed events.
      if (conversationSyncPaused(entry.key)) continue;
      for (final message in entry.value) {
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        if (message.terminal) {
          failed.add(entry.key);
          break;
        }
        if (message.nextAttemptAt?.isAfter(now) ?? false) break;
        final isBundle = message.kind == MlsCommitBundle.kind;
        try {
          if (_mlsAcceptedUnfinished.contains(message.idempotencyKey)) {
            // The server already accepted it; only finishing it here
            // failed. Sending it again could meet a refusal (this device
            // removed meanwhile, say) that would drop an accepted commit.
          } else if (isBundle) {
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
                keepDrafts: true,
                preserveOutbox: true,
                drainSyncOwner: false);
            return;
          }
          final backoff = isBundle && err is ApiException
              ? _selfUpdateRefusal(message, err)
              : null;
          if (backoff != null) {
            // A self-update is optional: a refusal the server gives after
            // its duplicate check drops it, so it does not pause the
            // conversation, and the policy waits before trying again.
            await _mlsCrypto?.abandonCommitBundle(message);
            if (!_syncOwnerActive(current, ownerGeneration)) return;
            _selfUpdatePolicyFor(current)?.recordBackoff(
                message.conversationId, DateTime.now(), backoff);
            await _saveSelfUpdates();
            if (err is ApiException && err.statusCode == 409) {
              _mlsReconcileRequested = true;
              unawaited(_catchUpSyncEvents());
            }
            break;
          }
          if (isBundle &&
              err is ApiException &&
              _refusedBundle(err) &&
              !_isUpdateOnlyBundle(message)) {
            // Another commit won this epoch, or the change is no longer
            // valid. The staged commit was never merged, so dropping it
            // leaves this device in step with the group (card I51). Catch
            // up, then reconcile again: at once on a new epoch, otherwise
            // after the change's backoff.
            await _mlsCrypto?.abandonCommitBundle(message);
            // The retry maps belong to this session; once it ended they
            // were cleared and must stay so.
            if (!_syncOwnerActive(current, ownerGeneration)) return;
            _mlsBundleRefused(message);
            _mlsReconcileRequested = true;
            unawaited(_catchUpSyncEvents());
            break;
          }
          final terminal = await _recordMlsOutboxFailure(message, err);
          if (terminal) failed.add(entry.key);
          break;
        }
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        try {
          if (isBundle) {
            await _mlsCrypto?.completeCommitBundle(message);
          } else {
            await localStore.removePendingMlsMessage(message.idempotencyKey);
          }
        } catch (err) {
          // Accepted but not finished here: it is never dropped, and it
          // holds back the rest of its conversation until a timed retry
          // finishes it.
          if (!_syncOwnerActive(current, ownerGeneration)) return;
          _mlsAcceptedUnfinished.add(message.idempotencyKey);
          await _recordMlsFinishFailure(message, err);
          break;
        }
        _mlsAcceptedUnfinished.remove(message.idempotencyKey);
        if (isBundle) {
          final bundle = MlsCommitBundle.decode(message.payload);
          // Sends held for this removal (D68) go once reconcile confirms it.
          if (bundle.removed.isNotEmpty &&
              _removalHolds.containsKey(message.conversationId)) {
            _mlsReconcileRequested = true;
            unawaited(_catchUpSyncEvents());
          }
          // A self-update, and any commit that removes someone, carries an
          // update path: this device's leaf key is fresh again.
          if (bundle.isUpdateOnly || bundle.removed.isNotEmpty) {
            _selfUpdatePolicyFor(current)
                ?.recordPathCommit(message.conversationId, DateTime.now());
            await _saveSelfUpdates();
          }
        }
      }
    }
    if (!_sameSetOf(failed, _failedMlsConversations)) {
      _failedMlsConversations
        ..clear()
        ..addAll(failed);
      // A held send to a paused conversation reports the pause.
      _removalHoldsSettled();
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
    // Results are recorded only for the session that ran the pass: the
    // retry maps of one that ended were cleared and stay so.
    final ownerGeneration = _sessionGeneration;
    try {
      await _reconcileMlsMembershipOnce(current, client, mls);
      if (_syncOwnerActive(current, ownerGeneration)) {
        _mlsStepSettled('reconcile', failed: false);
      }
    } catch (err) {
      // The pending-changes list could not be read: try again later, not
      // only on the next catch-up something else starts.
      if ((err is! ApiException || err.statusCode != 401) &&
          _syncOwnerActive(current, ownerGeneration)) {
        _mlsStepSettled('reconcile', failed: true);
      }
      rethrow;
    } finally {
      // Every pass, failed or not, re-arms the wake for the earliest change
      // still backing off.
      if (_syncOwnerActive(current, ownerGeneration)) _armMlsRetryWake();
    }
  }

  Future<void> _reconcileMlsMembershipOnce(Session current, ApiClient client,
      MlsConversationCryptoService mls) async {
    final ownerGeneration = _sessionGeneration;
    // Holds set after this point are newer than the list (D68).
    final holdSeq = _removalHoldSeq;
    final changes = await client.mlsPendingChanges(current.token);
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    final now = DateTime.now().toUtc();
    final stillPending = <String>{};
    var staged = false;
    var failed = false;
    for (final change in changes) {
      final key = _pendingChangeKey(change);
      stillPending.add(key);
      final firstSeen = _mlsPendingSeen.putIfAbsent(key, () => now);
      // A change whose bundle was refused is neither claimed nor staged
      // again until its backoff passes.
      if (_mlsChangeWaiting(change.conversationId, change.epoch, now)) {
        continue;
      }
      // The device that made the change commits it too, without waiting.
      final coordinator = change.coordinatorDeviceId == null ||
          change.coordinatorDeviceId == current.deviceId ||
          _mlsReconcileNow.contains(change.conversationId);
      if (!coordinator && now.difference(firstSeen) < reconcileFallback) {
        continue;
      }
      // Each conversation is reconciled on its own: one refusal (a device
      // the server lists that is already a member, say) must not stop the
      // others. A failed one stays pending and is tried on the next pass.
      try {
        if (await _hasPendingMlsWork(change.conversationId)) continue;
        final local = await mls.groupEpoch(change.conversationId);
        // Behind or ahead of the server means sync is not finished yet.
        if (local == null || local.pending || local.epoch != change.epoch) {
          continue;
        }
        // L1 (D94): only devices on their account's approved list are
        // claimed and added; the rest wait, and no key package is spent.
        final discovery = mls is ApprovedDeviceDiscoveryCryptoService
            ? mls as ApprovedDeviceDiscoveryCryptoService
            : null;
        List<MlsDeviceRef>? discovered;
        if (discovery != null) {
          try {
            discovered = await _discoverApprovedAdds(
                current, client, discovery, change.conversationId);
          } catch (err) {
            if (err is ApiException && err.statusCode == 401) rethrow;
            if (change.remove.isEmpty) rethrow;
            // Discovery failure authorizes no additions, but must not prevent
            // removing a leaf. Never fall back to server-enumerated adds.
            discovered = const [];
          }
        }
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        final approvedAdds = discovered == null
            ? await _approvedForAdd(change.add)
            : [for (final ref in discovered) ref.deviceId];
        if (approvedAdds.isEmpty &&
            change.add.isNotEmpty &&
            change.remove.isEmpty) {
          throw DeviceListNotApprovedException(
              [for (final item in change.add) item.deviceId]);
        }
        final adds = approvedAdds.isEmpty
            ? const <DeviceKeyPackage>[]
            : await client.claimDeviceKeyPackages(
                current.token,
                change.conversationId,
                approvedAdds,
              );
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        if (discovered != null) _checkDiscoveredPackages(discovered, adds);
        if (adds.isEmpty && change.remove.isEmpty) continue;
        await mls.stageMembershipChange(change.conversationId,
            adds: adds, removes: change.remove);
        _mlsReconcileNow.remove(change.conversationId);
        staged = true;
      } catch (err) {
        // A revoked session ends the whole pass; anything else is local to
        // this conversation.
        if (err is ApiException && err.statusCode == 401) rethrow;
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        failed = true;
        // Not claimed again on every catch-up: it waits out a backoff.
        _mlsChangeFailed(change.conversationId, change.epoch);
        // Body-free: no conversation, device or server text.
        developer.log(
            'mls_reconcile_conversation_failed '
            '${err is ApiException ? err.statusCode : err.runtimeType}',
            name: 'veritra.sync');
      }
    }
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    _mlsPendingSeen.removeWhere((key, _) => !stillPending.contains(key));
    _mlsReconcileNow.removeWhere((conversationId) =>
        !changes.any((change) => change.conversationId == conversationId));
    // A change the server no longer lists, or lists at another epoch, starts
    // afresh.
    _mlsChangeRetries.removeWhere((conversationId, retry) => !changes.any(
        (change) =>
            change.conversationId == conversationId &&
            change.epoch == retry.epoch));
    if (failed) _mlsReconcileRequested = true;
    try {
      await _updateRemovalHolds(changes, holdSeq, current, client, mls);
    } catch (err) {
      // The holds stay as they were and are looked at on the next pass; a
      // commit staged above still goes out.
      if (err is ApiException && err.statusCode == 401) rethrow;
      _mlsReconcileRequested = true;
    }
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    if (staged) await _flushMlsOutbox();
  }

  /// The device ids of [adds] that the approved-device lists approve now.
  /// Without an L1 engine every id passes here: such an engine does no MLS
  /// (the native one gates each add again with the pinned key).
  Future<List<String>> _approvedForAdd(List<MlsDeviceRef> adds) async {
    final pins = _deviceListPins;
    if (pins == null) return [for (final item in adds) item.deviceId];
    final out = <String>[];
    for (final item in adds) {
      try {
        if (await pins.approvedKey(item.accountId, item.deviceId) != null) {
          out.add(item.deviceId);
        }
      } on Object {
        // Unavailable: not added now.
      }
    }
    return out;
  }

  Future<List<MlsDeviceRef>> _discoverApprovedAdds(
      Session current,
      ApiClient client,
      ApprovedDeviceDiscoveryCryptoService discovery,
      String conversationId,
      {bool creating = false}) async {
    final members =
        await client.conversationMembers(current.token, conversationId);
    final missing = await discovery.missingApprovedDevices(
        creating ? null : conversationId,
        members.map((member) => member.accountId));
    // The server and native commit format cap each bundle at 256 changes.
    return missing.take(256).toList();
  }

  void _checkDiscoveredPackages(
      List<MlsDeviceRef> requested, List<DeviceKeyPackage> packages) {
    final expected = requested.toSet();
    final seen = <String>{};
    for (final package in packages) {
      if (!expected.contains(
              (accountId: package.accountId, deviceId: package.deviceId)) ||
          !seen.add(package.deviceId)) {
        throw const FormatException('unexpected claimed device');
      }
    }
  }

  /// How long a device that is not the change's coordinator waits before it
  /// commits the change itself. The wake armed by [_armMlsRetryWake] makes a
  /// pass run when this ends, so the fallback does not depend on a sync event
  /// arriving by chance.
  @visibleForTesting
  Duration reconcileFallback = const Duration(minutes: 3);

  /// A little past the fallback, so a timer that fires early by a clock
  /// rounding still finds it over.
  static const _reconcileFallbackMargin = Duration(seconds: 1);

  // Membership changes that failed or whose commit bundle the server refused
  // back off (TASK-029). Plan defaults for bug-hunt Q-003 and Q-005: a
  // bounded, capped backoff and no terminal pause, since no source shows
  // which refusals are permanent. A change is neither claimed nor staged
  // again for [mlsRetryBase], doubling per attempt up to [mlsRetryCap], so a
  // permanent refusal costs at most one key-package claim and one bundle
  // per cap interval. A new epoch (another commit landed: a 409 epoch
  // conflict) or the change leaving the server's list starts it afresh.
  // Memory only; a restart or a session change resets it.

  /// The first wait after a failed MLS membership change or catch-up step.
  @visibleForTesting
  Duration mlsRetryBase = const Duration(seconds: 1);

  /// The longest wait between two attempts of one change or step.
  @visibleForTesting
  Duration mlsRetryCap = const Duration(minutes: 10);

  /// Per conversation: the epoch the change failed at, how often, and when
  /// it may go again. A null [due] has been handed to a pass already.
  final Map<String, ({int epoch, int attempts, DateTime? due})>
      _mlsChangeRetries =
      <String, ({int epoch, int attempts, DateTime? due})>{};

  /// Per catch-up step ('revocations', 'reconcile') that failed as a whole
  /// or in part: how often in a row, and when the wake retries it.
  final Map<String, ({int attempts, DateTime? due})> _mlsStepRetries =
      <String, ({int attempts, DateTime? due})>{};

  /// One timer for the earliest deadline above, so an idle session still
  /// reconciles when a backoff ends. Separate from the catch-up and outbox
  /// retry timers, which a successful catch-up or an empty outbox cancel.
  Timer? _mlsRetryWake;

  Duration _mlsRetryDelay(int attempts) {
    var delay = mlsRetryBase;
    for (var i = 1; i < attempts && delay < mlsRetryCap; i++) {
      delay *= 2;
    }
    return delay > mlsRetryCap ? mlsRetryCap : delay;
  }

  /// Backs off the change of [conversationId] at [epoch] after a failure.
  void _mlsChangeFailed(String conversationId, int epoch) {
    final previous = _mlsChangeRetries[conversationId];
    final attempts =
        previous != null && previous.epoch == epoch ? previous.attempts + 1 : 1;
    _mlsChangeRetries[conversationId] = (
      epoch: epoch,
      attempts: attempts,
      due: DateTime.now().toUtc().add(_mlsRetryDelay(attempts)),
    );
  }

  /// Whether the change of [conversationId] at [epoch] still waits out its
  /// backoff at [now]. A change that may go takes its deadline with it, so
  /// the wake does not fire for it again while the attempt runs.
  bool _mlsChangeWaiting(String conversationId, int epoch, DateTime now) {
    final retry = _mlsChangeRetries[conversationId];
    if (retry == null) return false;
    if (retry.epoch != epoch) {
      _mlsChangeRetries.remove(conversationId);
      return false;
    }
    final due = retry.due;
    if (due == null) return false;
    if (now.isBefore(due)) return true;
    _mlsChangeRetries[conversationId] =
        (epoch: retry.epoch, attempts: retry.attempts, due: null);
    return false;
  }

  /// Records how a catch-up [step] went. A failed one is retried by the
  /// wake after a backoff that grows while it keeps failing; it runs on
  /// every catch-up meanwhile, as before.
  void _mlsStepSettled(String step, {required bool failed}) {
    if (failed) {
      final attempts = (_mlsStepRetries[step]?.attempts ?? 0) + 1;
      _mlsStepRetries[step] = (
        attempts: attempts,
        due: DateTime.now().toUtc().add(_mlsRetryDelay(attempts)),
      );
    } else if (_mlsStepRetries.remove(step) == null) {
      return;
    }
    _armMlsRetryWake();
  }

  /// The server refused the membership bundle [message] for good or for
  /// this epoch: its change backs off. A revocation commit has its own path.
  void _mlsBundleRefused(PendingMlsMessage message) {
    final MlsCommitBundle bundle;
    try {
      bundle = MlsCommitBundle.decode(message.payload);
    } catch (_) {
      return;
    }
    if (bundle.revocationDeviceId != null) return;
    _mlsChangeFailed(message.conversationId, bundle.epoch);
    _armMlsRetryWake();
  }

  /// Arms the wake for the earliest backoff deadline, replacing any earlier
  /// one. It belongs to the session that armed it: once that session ends
  /// or sync restarts, it does nothing.
  void _armMlsRetryWake() {
    _mlsRetryWake?.cancel();
    _mlsRetryWake = null;
    final owner = session;
    if (_disposed || owner == null) return;
    DateTime? earliest;
    for (final due in _mlsRetryDeadlines()) {
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    if (earliest == null) return;
    final generation = _sessionGeneration;
    final delay = earliest.difference(DateTime.now().toUtc());
    _mlsRetryWake =
        Timer(delay < _minimumRetryDelay ? _minimumRetryDelay : delay, () {
      _mlsRetryWake = null;
      if (_disposed) return;
      if (!_syncOwnerActive(owner, generation)) {
        // A rotated token or a sync restart keeps this device signed in:
        // its backoffs are still in place (a session end clears them and
        // cancels this timer), so the wake moves to the live owner instead
        // of being lost.
        final live = session;
        if (live != null &&
            live.baseUrl == owner.baseUrl &&
            live.accountId == owner.accountId &&
            live.deviceId == owner.deviceId) {
          _armMlsRetryWake();
        }
        return;
      }
      // Hand every expired deadline to the catch-up below, so a pass that
      // cannot reach the change (a failed fetch, say) does not re-fire the
      // wake at once.
      _consumeMlsRetryDeadlines(DateTime.now().toUtc());
      _mlsReconcileRequested = true;
      unawaited(_catchUpSyncEvents());
      _armMlsRetryWake();
    });
  }

  Iterable<DateTime> _mlsRetryDeadlines() sync* {
    for (final retry in _mlsChangeRetries.values) {
      final due = retry.due;
      if (due != null) yield due;
    }
    for (final retry in _mlsStepRetries.values) {
      final due = retry.due;
      if (due != null) yield due;
    }
    // A change this device left to its coordinator becomes its own to commit
    // when the fallback ends. A deadline already past is not listed: the
    // pass that found it over has acted on it, and a change that still
    // cannot be staged (sync not finished, say) is retried by the backoffs
    // above, not by a wake that would fire again at once.
    final now = DateTime.now().toUtc();
    for (final firstSeen in _mlsPendingSeen.values) {
      final due = firstSeen.add(reconcileFallback + _reconcileFallbackMargin);
      if (due.isAfter(now)) yield due;
    }
  }

  void _consumeMlsRetryDeadlines(DateTime now) {
    for (final entry in _mlsChangeRetries.entries.toList()) {
      final due = entry.value.due;
      if (due != null && !due.isAfter(now)) {
        _mlsChangeRetries[entry.key] = (
          epoch: entry.value.epoch,
          attempts: entry.value.attempts,
          due: null
        );
      }
    }
    for (final entry in _mlsStepRetries.entries.toList()) {
      final due = entry.value.due;
      if (due != null && !due.isAfter(now)) {
        _mlsStepRetries[entry.key] =
            (attempts: entry.value.attempts, due: null);
      }
    }
  }

  /// Drops every backoff and the wake: the session ended or the app closes.
  void _resetMlsRetries() {
    _mlsRetryWake?.cancel();
    _mlsRetryWake = null;
    _mlsChangeRetries.clear();
    _mlsStepRetries.clear();
    // Held sends belong to the session that ended: they wake and give up.
    // The stored holds stay for this device's next session.
    _removalHolds.clear();
    _removalHoldsLoaded = null;
    _removalHoldsSettled();
  }

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
  /// rejections are terminal, and so are local errors that cannot pass by
  /// themselves: an item that does not decode, a bad argument, a durable
  /// storage error (TASK-052). They pause the conversation, with the item
  /// kept; nothing resumes it yet but the device's own recovery (bug-hunt
  /// Q-006 is open). Connection problems, busy servers, a malformed
  /// response, transient storage errors and unknown errors retry with
  /// bounded exponential backoff.
  Future<bool> _recordMlsOutboxFailure(
      PendingMlsMessage message, Object error) async {
    final apiError = error is ApiException ? error : null;
    final bool terminal;
    final String failureClass;
    if (apiError != null) {
      terminal = !_isTransientSyncError(apiError);
      failureClass = terminal
          ? 'terminal:${apiError.statusCode}:${apiError.serverCode ?? 'rejected'}'
          : 'retryable:${apiError.statusCode}';
    } else if (_isDurableLocalError(error)) {
      terminal = true;
      failureClass = 'terminal:local:${error.runtimeType}';
    } else {
      terminal = false;
      failureClass = error is ApiResponseException
          ? 'retryable:response'
          : error is SocketException ||
                  error is TimeoutException ||
                  error is HttpException ||
                  error is HandshakeException
              ? 'retryable:network'
              : _isTransientSyncError(error)
                  ? 'retryable:local'
                  : 'retryable:unknown';
    }
    final exponent = min(message.attemptCount, 8);
    await localStore.recordMlsOutboxFailure(
      message.idempotencyKey,
      failureClass: failureClass,
      terminal: terminal,
      nextAttemptAt: terminal
          ? null
          : DateTime.now().toUtc().add(Duration(seconds: 1 << exponent)),
    );
    return terminal;
  }

  /// A local error a retry cannot fix. A malformed server response is a
  /// [FormatException] too, but the next answer may be fine.
  static bool _isDurableLocalError(Object error) =>
      (error is FormatException && error is! ApiResponseException) ||
      error is ArgumentError ||
      _isDurableStorageError(error);

  /// Items the server accepted whose local finishing (merging the commit,
  /// or removing the item) failed; the next pass only finishes them. Memory
  /// only: after a restart the item is sent again, and the server answers
  /// a repeated idempotency key with the original result.
  final Set<String> _mlsAcceptedUnfinished = <String>{};

  /// Consecutive MLS outbox passes or queue reads that failed locally.
  int _mlsOutboxLocalFailures = 0;

  /// Records that the server accepted [message] but finishing it here
  /// failed with [error]. Always a timed retry with the item's own backoff,
  /// never terminal: the group already moved on with it (TASK-030).
  Future<void> _recordMlsFinishFailure(
      PendingMlsMessage message, Object error) async {
    // Body-free: no conversation, device or server text.
    developer.log('mls_outbox_finish_failed ${error.runtimeType}',
        name: 'veritra.sync');
    final exponent = min(message.attemptCount, 8);
    await localStore.recordMlsOutboxFailure(
      message.idempotencyKey,
      failureClass: 'retryable:finish',
      terminal: false,
      nextAttemptAt:
          DateTime.now().toUtc().add(Duration(seconds: 1 << exponent)),
    );
  }

  /// The wait after [failures] consecutive local storage failures of an
  /// outbox worker: 1 s, doubling to 256 s, like an item's own retries.
  static Duration _localRetryDelay(int failures) =>
      Duration(seconds: 1 << min(max(failures - 1, 0), 8));

  Future<void> _scheduleMlsOutboxRetry() =>
      _trackBackground(_scheduleMlsOutboxRetryRun);

  Future<void> _scheduleMlsOutboxRetryRun() async {
    _mlsOutboxRetryTimer?.cancel();
    _mlsOutboxRetryTimer = null;
    // Armed only for the session that read the queue (see
    // [_scheduleOutboxRetry]).
    final owner = session;
    final generation = _sessionGeneration;
    if (_disposed || owner == null || api == null || _mlsCrypto == null) {
      return;
    }
    final List<PendingMlsMessage> messages;
    try {
      messages = await localStore.pendingMlsMessages();
    } catch (_) {
      // Unreadable queue: try again later rather than wait for a wake.
      if (_disposed || !_syncOwnerActive(owner, generation)) return;
      _mlsOutboxLocalFailures++;
      _armMlsOutboxRetry(_localRetryDelay(_mlsOutboxLocalFailures));
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
    var delay = earliest?.difference(now);
    // After a local failure the stored due times may be stale or missing
    // (the failure could not be recorded), so wait at least the local
    // backoff: a due head would otherwise be retried at the floor forever.
    if (_mlsOutboxLocalFailures > 0) {
      final fallback = _localRetryDelay(_mlsOutboxLocalFailures);
      if (delay == null || delay < fallback) delay = fallback;
    }
    if (delay == null || _disposed || !_syncOwnerActive(owner, generation)) {
      return;
    }
    _armMlsOutboxRetry(delay);
  }

  void _armMlsOutboxRetry(Duration delay) {
    // Two schedulers may overlap their reads; only the last timer stays.
    _mlsOutboxRetryTimer?.cancel();
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
    final ownerGeneration = _sessionGeneration;
    final List<DeviceKeyPackage> packages;
    if (mls is ApprovedDeviceDiscoveryCryptoService) {
      final requested = await _discoverApprovedAdds(current, client,
          mls as ApprovedDeviceDiscoveryCryptoService, conversationId,
          creating: true);
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      packages = requested.isEmpty
          ? const []
          : await client.claimDeviceKeyPackages(current.token, conversationId,
              [for (final ref in requested) ref.deviceId]);
      _checkDiscoveredPackages(requested, packages);
    } else {
      packages = await client.claimConversationKeyPackages(
          current.token, conversationId);
    }
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    await mls.initializeConversation(conversationId, packages);
    // The creator's leaf key was made with the group.
    await _noteSelfUpdate(current,
        (policy) => policy.recordPathCommit(conversationId, DateTime.now()));
    await _saveSelfUpdates();
    await _flushMlsOutbox();
  }

  /// Every Welcome consumes one of this device's published key packages,
  /// and the Welcome path has already owed its replacement durably.
  /// Publishing what is owed keeps the supply steady, so the device can keep
  /// being added to new conversations. Sync never fails over it: what a
  /// failure leaves owed goes with the next Welcome or catch-up.
  Future<void> _replenishKeyPackage() async {
    try {
      await _publishOwedKeyPackages();
    } catch (_) {
      // Still owed; retried later.
    }
  }

  /// A new device's first key packages. Owed by [_oweInitialKeyPackages]
  /// before its session was saved, so a failure here (reported by the
  /// sign-in) or a crash is retried by restore, sign-in or catch-up.
  Future<void> _publishInitialMlsKeyPackages() => _publishOwedKeyPackages();

  // Key-package supply (TASK-028). The server never says how many unclaimed
  // packages this device has left, so the device keeps a durable count of
  // those it owes: the first batch of a new device, plus one per Welcome.
  // The count lives in one local setting, scoped to the origin, account and
  // device that owe it; a record of another identity counts as nothing and
  // is replaced. It only goes down after the server accepted a publish (or
  // answered that it holds its most). Residual: a crash after the server
  // accepted a publish but before the count went down publishes that batch
  // again (at most [_keyPackageBatchCap] spare packages). Each batch is
  // generated, and its private keys stored, before it is sent: a batch that
  // is never accepted stays in local MLS state unused, at most one batch
  // per attempt, as no discard call exists.
  static const _keyPackageNeedSetting = 'mls.key_package_need';

  /// Most packages one publish carries, and most the record owes: the
  /// native batch limit and the server's per-request limit.
  static const _keyPackageBatchCap = 10;

  /// A new device's first batch (the native default).
  static const _initialKeyPackages = 5;

  /// False only once this process has seen nothing owed for this session;
  /// spares a store read on every catch-up.
  bool _keyPackagesOwed = true;
  int _keyPackageRetryFailures = 0;
  DateTime? _keyPackageRetryAt;
  Future<void> _keyPackageNeedLock = Future<void>.value();
  Future<void>? _keyPackagePublish;
  Session? _keyPackagePublishOwner;

  String _keyPackageScope(Session owner) {
    String origin;
    try {
      origin = canonicalizeServerOrigin(owner.baseUrl);
    } on FormatException {
      origin = owner.baseUrl;
    }
    return '$origin\u0000${owner.accountId}\u0000${owner.deviceId}';
  }

  /// The stored record when it belongs to [owner]'s identity, else null.
  Future<({int need, String? welcome})?> _readKeyPackageNeed(
      Session owner) async {
    final raw = await localStore.loadSetting(_keyPackageNeedSetting);
    if (raw == null || raw.isEmpty) return null;
    try {
      final record = jsonDecode(raw);
      if (record is! Map || record['scope'] != _keyPackageScope(owner)) {
        return null;
      }
      final need = record['need'];
      final welcome = record['welcome'];
      return (
        need: need is int ? need.clamp(0, _keyPackageBatchCap) : 0,
        welcome: welcome is String ? welcome : null,
      );
    } on FormatException {
      return null;
    }
  }

  /// One read-modify-write of [owner]'s record ([change] returns null to
  /// leave it); they never interleave, so an increment and a decrement
  /// cannot lose each other. Returns what [owner] owes afterwards.
  Future<int> _changeKeyPackageNeed(
      Session owner,
      ({int need, String? welcome})? Function(
              ({int need, String? welcome})? current)
          change) {
    final done = _keyPackageNeedLock.then((_) async {
      final current = await _readKeyPackageNeed(owner);
      final next = change(current);
      final need = (next ?? current)?.need.clamp(0, _keyPackageBatchCap) ?? 0;
      if (next != null) {
        await localStore.saveSetting(
            _keyPackageNeedSetting,
            jsonEncode(<String, Object?>{
              'scope': _keyPackageScope(owner),
              'need': need,
              if (next.welcome != null) 'welcome': next.welcome,
            }));
      }
      if (_sameSession(owner)) _keyPackagesOwed = need > 0;
      return need;
    });
    _keyPackageNeedLock =
        done.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return done;
  }

  /// Owes [count] more packages for [owner]. With [welcome], counts that
  /// Welcome once: a replay or a retried event adds nothing.
  Future<int> _oweKeyPackages(Session owner, int count, {String? welcome}) {
    _keyPackagesOwed = true;
    return _changeKeyPackageNeed(owner, (current) {
      if (welcome != null && current?.welcome == welcome) return null;
      return (
        need: (current?.need ?? 0) + count,
        welcome: welcome ?? current?.welcome,
      );
    });
  }

  /// Records [published] packages the server accepted for [owner].
  Future<int> _settleKeyPackages(Session owner, int published) =>
      _changeKeyPackageNeed(
          owner,
          (current) => current == null
              ? null
              : (need: current.need - published, welcome: current.welcome));

  /// Written before a new device's session is saved, so even a crash right
  /// after the save leaves its first batch owed.
  Future<void> _oweInitialKeyPackages(Session created) async {
    if (_mlsCrypto == null) return;
    await _oweKeyPackages(created, _initialKeyPackages);
  }

  /// Publishes what this device owes, best effort: a failure stays owed.
  /// Only a rejected session (401) is rethrown.
  Future<void> _ensureKeyPackageSupply() async {
    try {
      await _publishOwedKeyPackages();
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) rethrow;
    }
  }

  /// After a catch-up pass that ended online: publishes anything still
  /// owed, at once the first time and then with backoff (1 minute doubling
  /// to an hour), as every attempt stores a batch of private keys first.
  void _retryOwedKeyPackages() {
    final current = session;
    if (!_keyPackagesOwed ||
        current == null ||
        _mlsCrypto == null ||
        connectionStatus != ConnectionStatus.online) {
      return;
    }
    final now = DateTime.now();
    final at = _keyPackageRetryAt;
    if (at != null && now.isBefore(at)) return;
    _keyPackageRetryAt = now
        .add(Duration(minutes: min(60, 1 << min(_keyPackageRetryFailures, 6))));
    unawaited(_publishOwedKeyPackages().then((_) {
      if (_sameSession(current)) {
        _keyPackageRetryFailures = 0;
        _keyPackageRetryAt = null;
      }
    }, onError: (Object _) {
      if (_sameSession(current)) _keyPackageRetryFailures++;
    }));
  }

  /// Publishes one capped batch of what the current session owes and
  /// settles it once the server accepted it. One publish per session runs
  /// at a time; a second caller joins it.
  Future<void> _publishOwedKeyPackages() {
    final current = session;
    if (current == null) return Future<void>.value();
    final running = _keyPackagePublish;
    if (running != null && identical(_keyPackagePublishOwner, current)) {
      return running;
    }
    final publish = _publishOwedKeyPackagesOnce(current);
    _keyPackagePublish = publish;
    _keyPackagePublishOwner = current;
    unawaited(publish.then<void>((_) {}, onError: (Object _) {}).then((_) {
      if (identical(_keyPackagePublish, publish)) {
        _keyPackagePublish = null;
        _keyPackagePublishOwner = null;
      }
    }));
    return publish;
  }

  Future<void> _publishOwedKeyPackagesOnce(Session current) async {
    final client = api;
    final mls = _mlsCrypto;
    if (client == null || mls == null || !_sameSession(current)) return;
    final owed = await _changeKeyPackageNeed(current, (_) => null);
    if (owed <= 0 || !_sameSession(current)) return;
    final packages = await mls.createReplenishmentKeyPackages(
        count: min(owed, _keyPackageBatchCap));
    // Generated for this session; never published for another.
    if (!_sameSession(current)) return;
    try {
      await client.publishDeviceKeyPackages(current.token, packages);
    } on ApiException catch (err) {
      if (err.statusCode != 409 ||
          err.serverCode != 'key_package_quota_exceeded') {
        rethrow;
      }
      // The server already holds its most unclaimed packages for this
      // device (50): nothing is owed.
      await _settleKeyPackages(current, owed);
      return;
    }
    await _settleKeyPackages(current, packages.length);
  }

  Future<void> _processMlsRevocations() async {
    final current = session;
    final client = api;
    final mls = _mlsCrypto;
    if (current == null || client == null || mls == null) return;
    // Recorded only for the session that ran the pass (see
    // [_reconcileMlsMembership]).
    final ownerGeneration = _sessionGeneration;
    final List<MlsRevocation> revocations;
    try {
      revocations = await client.mlsRevocations(current.token);
    } catch (err) {
      // A revoked session ends the whole pass; otherwise reconcile still
      // runs, and the list is read again after a backoff (TASK-035).
      if (err is ApiException && err.statusCode == 401) rethrow;
      // Body-free: no server text.
      developer.log(
          'mls_revocations_unavailable '
          '${err is ApiException ? err.statusCode : err.runtimeType}',
          name: 'veritra.sync');
      if (_syncOwnerActive(current, ownerGeneration)) {
        _mlsStepSettled('revocations', failed: true);
      }
      return;
    }
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    var failed = false;
    _revocationPendingGroups
      ..clear()
      ..addAll(revocations
          .where((revocation) => revocation.state == 'pending')
          .map((revocation) => revocation.conversationId));
    for (final revocation in revocations) {
      if (!_syncOwnerActive(current, ownerGeneration)) return;
      // Each revocation is handled on its own: one that cannot be committed
      // here (no local group, or no leaf for the device) must not fail the
      // pass, or reconcile and the wake ACK never run. It is listed again,
      // and tried again on the next pass, which the wake starts after a
      // backoff when nothing else does.
      try {
        if (revocation.state == 'pending' &&
            revocation.coordinatorDeviceId == current.deviceId) {
          // Earlier MLS work for this group drains first (I34). In
          // particular, a revocation commit queued before a restart is
          // still "pending" on the server until it is delivered; making
          // another one would fork the group.
          var target = revocation;
          if (await _hasPendingMlsWork(revocation.conversationId)) {
            await _flushMlsOutbox();
            if (await _hasPendingMlsWork(revocation.conversationId)) continue;
            // The drain may have delivered this revocation's own commit, and
            // the list above predates it: read the revocation again and
            // commit only if the server still waits for this device.
            final fresh = (await client.mlsRevocations(current.token))
                .where((item) =>
                    item.conversationId == revocation.conversationId &&
                    item.revokedDeviceId == revocation.revokedDeviceId)
                .firstOrNull;
            if (fresh == null ||
                fresh.state != 'pending' ||
                fresh.coordinatorDeviceId != current.deviceId ||
                await _hasPendingMlsWork(revocation.conversationId)) {
              continue;
            }
            target = fresh;
          }
          await mls.createRevocationCommit(target);
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
      } catch (err) {
        // A revoked session ends the whole pass.
        if (err is ApiException && err.statusCode == 401) rethrow;
        failed = true;
        // Body-free: no conversation, device or server text.
        developer.log(
            'mls_revocation_failed '
            '${err is ApiException ? err.statusCode : err.runtimeType}',
            name: 'veritra.sync');
      }
    }
    if (!_syncOwnerActive(current, ownerGeneration)) return;
    _mlsStepSettled('revocations', failed: failed);
  }

  /// How long the self-update policy waits after the server refused the
  /// update-only bundle [message] with [err], or null when [message] is not
  /// one or [err] is to be retried unchanged.
  ///
  /// Only refusals the server gives after its duplicate check drop the
  /// bundle: a retry of a bundle the server already accepted (its answer
  /// lost) gets 200, never one of these. Anything else, such as the write
  /// budget's 429 that is checked before the duplicate check, may hide an
  /// accepted bundle; dropping it would leave this device an epoch behind
  /// its own commit, so the same bundle is retried as sent.
  static Duration? _selfUpdateRefusal(
      PendingMlsMessage message, ApiException err) {
    final Duration backoff;
    switch ((err.statusCode, err.serverCode)) {
      // The server's budget; an operator may set it above the default.
      case (429, 'mls_self_update_limit'):
        final retryAfter = err.retryAfter;
        backoff =
            retryAfter != null && retryAfter > MlsSelfUpdatePolicy.minInterval
                ? retryAfter
                : MlsSelfUpdatePolicy.minInterval;
      // Another commit won the epoch, or a removal must land first.
      case (409, 'mls_epoch_conflict' || 'mls_change_pending'):
        backoff = MlsSelfUpdatePolicy.conflictBackoff;
      // Will not pass soon; an older server answers 400 invalid_input.
      case (400 || 403 || 422, _):
        backoff = MlsSelfUpdatePolicy.refusedBackoff;
      default:
        return null;
    }
    return _isUpdateOnlyBundle(message) ? backoff : null;
  }

  /// Whether the outbox holds this device's commit bundle [idempotencyKey]
  /// and it carries an update path (a self-update, or a removal). Never
  /// throws: a wrong answer costs at most an early or late self-update.
  Future<bool> _queuedPathCommit(String idempotencyKey) async {
    try {
      final queued = (await localStore.pendingMlsMessages())
          .where((item) =>
              item.kind == MlsCommitBundle.kind &&
              item.idempotencyKey == idempotencyKey)
          .firstOrNull;
      if (queued == null) return false;
      final bundle = MlsCommitBundle.decode(queued.payload);
      return bundle.isUpdateOnly || bundle.removed.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static bool _isUpdateOnlyBundle(PendingMlsMessage message) {
    try {
      return MlsCommitBundle.decode(message.payload).isUpdateOnly;
    } on FormatException {
      return false;
    }
  }

  /// The policy for [current]'s device, loading its saved state on first
  /// use; null without an MLS service that can stage self-updates.
  Future<MlsSelfUpdatePolicy?> _selfUpdates(Session current) async {
    final known = _selfUpdatePolicyFor(current);
    if (known != null) return known;
    final accountId = current.accountId;
    final deviceId = current.deviceId;
    if (cryptoService is! MlsSelfUpdateCryptoService ||
        accountId == null ||
        deviceId == null) {
      return null;
    }
    final raw = await localStore
        .loadSetting('${MlsSelfUpdatePolicy.settingName}:$deviceId');
    // Another load may have finished meanwhile; keep the first.
    return _selfUpdatePolicyFor(current) ??
        (_selfUpdatePolicy = MlsSelfUpdatePolicy.decode(raw,
            accountId: accountId, deviceId: deviceId));
  }

  /// Records [change] in the policy of [current]'s device. Never throws: a
  /// lost note costs at most an early or late self-update, while a failure
  /// here would fail the sync step or group setup that already committed.
  Future<void> _noteSelfUpdate(
      Session current, void Function(MlsSelfUpdatePolicy policy) change) async {
    try {
      final policy = await _selfUpdates(current);
      if (policy != null) change(policy);
    } catch (_) {}
  }

  /// The loaded policy when it belongs to [current]'s device, else null.
  MlsSelfUpdatePolicy? _selfUpdatePolicyFor(Session current) {
    final policy = _selfUpdatePolicy;
    return policy != null &&
            policy.accountId == current.accountId &&
            policy.deviceId == current.deviceId
        ? policy
        : null;
  }

  /// Saves the policy state when it changed. A failure keeps it dirty for
  /// the next save; losing it costs at most an early or late update.
  Future<void> _saveSelfUpdates() async {
    final policy = _selfUpdatePolicy;
    if (policy == null || !policy.dirty) return;
    policy.dirty = false;
    try {
      await localStore.saveSetting(
          '${MlsSelfUpdatePolicy.settingName}:${policy.deviceId}',
          policy.encode());
    } catch (_) {
      policy.dirty = true;
    }
  }

  /// Periodic self-update (docs/crypto.md): stages at most one update-only
  /// commit per foreground pass, for the conversation the policy finds most
  /// due, through the same staged-commit path as membership changes (D28).
  /// Never in a background wake, and never for a group that has a pending
  /// revocation or removal, MLS work queued, or a commit staged.
  Future<void> _maybeSelfUpdate(Session current, int ownerGeneration) async {
    final service = cryptoService;
    final crypto = service is MlsSelfUpdateCryptoService
        ? service as MlsSelfUpdateCryptoService
        : null;
    final mls = _mlsCrypto;
    final client = api;
    if (crypto == null ||
        mls == null ||
        client == null ||
        conversations.isEmpty) {
      return;
    }
    final policy = await _selfUpdates(current);
    if (policy == null || !_syncOwnerActive(current, ownerGeneration)) return;
    final now = DateTime.now().toUtc();
    try {
      // Every device a commit adds joins at once; the group's size spreads
      // their join updates, so learn it first.
      for (final conversationId in policy.joinsPending.toList()) {
        // A stale record for a chat no longer listed costs no request.
        if (membersByConversation.containsKey(conversationId) ||
            !conversations.any((c) => c.id == conversationId)) {
          continue;
        }
        try {
          await _ensureConversationAuthority(conversationId);
        } catch (err) {
          if (err is ApiException && err.statusCode == 401) rethrow;
        }
        if (!_syncOwnerActive(current, ownerGeneration)) return;
      }
      final due = policy.due(<SelfUpdateCandidate>[
        for (final conversation in conversations)
          (
            id: conversation.id,
            lastActivity: conversation.lastMessageAt,
            // 0 means not known; a DM always has two members.
            members: conversation.isDm ? 2 : membersFor(conversation.id).length,
          ),
      ], now);
      final previous = _lastSelfUpdateStagedAt;
      if (due.isEmpty ||
          (previous != null && now.difference(previous) < _selfUpdateSpacing)) {
        return;
      }
      List<MlsPendingChange>? changes;
      for (final conversationId in due) {
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        // A commit tells every member this device is online, so a request
        // (or a declined one) and a DM with a blocked peer get none, as
        // they get no read receipt. Their records stay for later.
        if (!_selfUpdateAllowed(conversationId)) continue;
        if (_revocationPendingGroups.contains(conversationId) ||
            _failedMlsConversations.contains(conversationId) ||
            await _hasPendingMlsWork(conversationId)) {
          continue;
        }
        final local = await mls.groupEpoch(conversationId);
        if (local == null) {
          // No group on this device (yet): look again much later.
          policy.recordBackoff(
              conversationId, now, MlsSelfUpdatePolicy.refusedBackoff);
          continue;
        }
        if (local.pending) continue;
        changes ??= await client.mlsPendingChanges(current.token);
        if (!_syncOwnerActive(current, ownerGeneration)) return;
        final change = changes
            .where((item) => item.conversationId == conversationId)
            .firstOrNull;
        // A removal goes first; a different epoch means sync is not done.
        if (change != null &&
            (change.remove.isNotEmpty || change.epoch != local.epoch)) {
          continue;
        }
        try {
          await crypto.stageSelfUpdate(conversationId);
        } catch (err) {
          policy.recordBackoff(
              conversationId, now, MlsSelfUpdatePolicy.failureBackoff);
          // Body-free: no conversation, device or server text.
          developer.log('mls_self_update_stage_failed ${err.runtimeType}',
              name: 'veritra.sync');
          continue;
        }
        _lastSelfUpdateStagedAt = now;
        await _flushMlsOutbox();
        break;
      }
    } finally {
      await _saveSelfUpdates();
    }
  }

  /// Whether a self-update may go to [conversationId]: an accepted chat,
  /// and for a DM a peer known not to be blocked (blocks loaded first).
  bool _selfUpdateAllowed(String conversationId) {
    if (!conversationOpen(conversationId)) return false;
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conversation == null || !conversation.isDm) return conversation != null;
    final peer = conversation.peerAccountId;
    return blocksLoaded && peer != null && !isBlocked(peer);
  }

  /// Whether MLS work for [conversationId] must wait: control messages
  /// queued ahead of it, or a pause of the conversation itself (C1 P1),
  /// which keeps reconcile, revocation commits and self-updates away from
  /// its group.
  Future<bool> _hasPendingMlsWork(String conversationId) async =>
      conversationSyncPaused(conversationId) ||
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
      throw UserFacingException(l10n.errorServerNotAllowed(baseUrl));
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
              preserveDeviceIdentity: true,
              keepDrafts: true,
              preserveOutbox: true);
        }
        _opErrors[op] = describeError(err, l10n);
      } finally {
        _busyOps.remove(op);
        notifyListeners();
      }
    });
    return succeeded;
  }

  /// Bodies of [_run] executing right now (0 or 1: they are queued).
  int _runsActive = 0;

  Future<void> _run(Future<void> Function() body) async {
    await _enqueueSessionTransition(() async {
      _runsActive++;
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
              preserveDeviceIdentity: true,
              keepDrafts: true,
              preserveOutbox: true);
        }
        error = describeError(err, l10n);
      } finally {
        _runsActive--;
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

  // ---- B7 account switcher (docs/designs/B7-passkeys.md, S5) ----

  /// Steps 2 and 5 of a switch: writes pending drafts and takes this
  /// device's push registration down (the server subscription and the native
  /// registration, each tried up to three times). Returns false when push
  /// could not be taken down, so the caller can ask before leaving.
  Future<bool> prepareToLeave() async {
    var pushGone = true;
    await _enqueueSessionTransition(() async {
      await _flushDraftsBeforeSessionEnd();
      _pushLeaving = true;
      _pushGeneration++;
      // Pending registrations may already have committed server-side.
      var drained = true;
      try {
        await Future.wait(_pushStarts.toList())
            .timeout(const Duration(seconds: 5));
        drained = (await Future.wait(_pushRegistrations.toList())
                .timeout(const Duration(seconds: 5)))
            .every((gone) => gone);
      } catch (_) {
        drained = false;
      }
      pushGone = await _stopPushStrict(session, api, attempts: 3) &&
          drained &&
          !_pushTeardownFailed;
    });
    return pushGone;
  }

  /// The user kept this account open after push could not be taken down:
  /// register again, as a resume would.
  void resumeAfterCancelledSwitch() {
    _pushLeaving = false;
    _pushTeardownFailed = false;
    // Let old registrations remove their late subscriptions before a new
    // registration can reuse the same server-side subscription identity.
    unawaited(Future.wait<void>([
      ..._pushStarts,
      for (final pending in _pushRegistrations) pending.then<void>((_) {}),
    ]).then((_) {
      if (session != null && !_disposed && !_pushLeaving) {
        unawaited(_startPush());
      }
    }));
  }

  /// Steps 4 and 6: stops sync, sockets and timers, advances the session
  /// generation (the I30 fences then drop any late result), closes the
  /// crypto handles, and waits for the work that cannot be cancelled.
  /// The AppState is unusable afterwards.
  Future<void> closeForSwitch() async {
    dispose();
    await _switchResourceClose;
    // A request that never answers must not hold the switch: the client was
    // closed above, and the generation fence drops anything that arrives.
    await backgroundWorkIdle.timeout(const Duration(seconds: 5),
        onTimeout: () {});
  }

  Future<void>? _switchResourceClose;

  @override
  void dispose() {
    _disposed = true;
    unawaited(screenGuard.setSecure(false));
    _recoveryPollTimer?.cancel();
    _recoveryPollTimer = null;
    _stopK1Backups();
    _orphanSweeper?.stop();
    _orphanSweeper = null;
    _stopProfiles();
    _resetDeviceLinkState();
    _receiptsRefreshTimer?.cancel();
    typing.dispose();
    receipts.dispose();
    _sessionGeneration++;
    _syncOwner?.dispose();
    final drain = _syncOwner?.cancelAndDrain();
    if (drain != null) unawaited(_trackBackground(() => drain));
    _syncOwner = null;
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _mlsOutboxRetryTimer?.cancel();
    _mlsOutboxRetryTimer = null;
    _resetMlsRetries();
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
    _switchResourceClose = _mlsCrypto?.dispose();
    unawaited(_switchResourceClose);
    unawaited(_callSignals.close());
    api?.close();
    super.dispose();
  }
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

/// One conversation's D68 send hold.
class _RemovalHold {
  _RemovalHold({required this.epoch, this.listed = false, this.seq = 0});

  factory _RemovalHold.fromJson(Map<String, Object?> json) => _RemovalHold(
        epoch: json['epoch'] as int,
        listed: json['listed'] as bool? ?? true,
      )..accounts.addAll(
          (json['accounts'] as List? ?? const <Object?>[]).cast<String>());

  /// The epoch the removal was made or last listed at.
  int epoch;

  /// Whether the server listed the removal as a change to commit.
  bool listed;

  /// [AppState._removalHoldSeq] when the hold was last set.
  int seq;

  /// The removed accounts.
  final Set<String> accounts = <String>{};

  /// The pending-changes read that first left this removal out, since it
  /// was last set or listed. Not stored: after a restart a read sets it
  /// again.
  int? unlistedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'epoch': epoch,
        'listed': listed,
        'accounts': accounts.toList()..sort(),
      };
}
