part of 'app_state.dart';

/// W11: the encrypted display name and photo of people and groups
/// (docs/designs/W11-profiles.md). The work is in [ProfileService]; this
/// file connects it to the session, the sync events, sends and rosters.
/// Nothing here logs a name, a photo or a key.

/// The profile routes of one session.
class _SessionProfileApi implements ProfileApi {
  _SessionProfileApi(this._client, this._token);
  final ApiClient _client;
  final String _token;

  @override
  Future<ProfileFetch> fetch(String kind, String subjectId,
          {int? ifNoneMatchVersion}) =>
      kind == profileSubjectAccount
          ? _client.fetchAccountProfile(_token, subjectId,
              ifNoneMatchVersion: ifNoneMatchVersion)
          : _client.fetchConversationProfile(_token, subjectId,
              ifNoneMatchVersion: ifNoneMatchVersion);

  @override
  Future<int> put(String kind, String subjectId, Uint8List blob,
          {required String keyId, int? ifMatchVersion}) =>
      kind == profileSubjectAccount
          ? _client.putAccountProfile(_token, blob,
              keyId: keyId, ifMatchVersion: ifMatchVersion)
          : _client.putConversationProfile(_token, subjectId, blob,
              keyId: keyId, ifMatchVersion: ifMatchVersion);

  @override
  Future<List<ProfileVersion>> versions(
          {List<String> accountIds = const <String>[],
          List<String> conversationIds = const <String>[]}) =>
      _client.profileVersions(_token,
          accountIds: accountIds, conversationIds: conversationIds);
}

extension ProfileActions on AppState {
  /// Whether this build keeps encrypted profiles (it needs the native
  /// library). Screens hide the editors otherwise.
  bool get profilesAvailable => profiles != null;

  /// The name to show for [accountId]: their display name when one was
  /// shared with this device, else null (show the username).
  String? profileNameOf(String accountId) => profiles?.account(accountId)?.name;

  Uint8List? profilePhotoOf(String accountId) =>
      profiles?.account(accountId)?.photoPng;

  /// A group's shared name, or null.
  String? groupProfileName(String conversationId) =>
      profiles?.conversation(conversationId)?.name;

  Uint8List? groupProfilePhoto(String conversationId) =>
      profiles?.conversation(conversationId)?.photoPng;

  /// Whether [conversationId] may be given a key message without side
  /// effects: a message request would be accepted by a send, and a
  /// conversation outside the list is not ours to post into.
  bool _profileKeyTarget(Conversation conversation) =>
      !isMessageRequest(conversation) &&
      !conversation.isChannel &&
      !sendHeldForRemoval(conversation.id);

  Future<void> _startProfiles(Session current) async {
    final source = cryptoService;
    final client = api;
    final accountId = current.accountId;
    if (source is! ProfileCodecSource ||
        client == null ||
        accountId == null ||
        profiles != null) {
      return;
    }
    final service = ProfileService(
      store: localStore,
      codec: (source as ProfileCodecSource).profileCodec,
      api: _SessionProfileApi(client, current.token),
      accountId: accountId,
      sendKey: (conversationId, type, body) async {
        if (_disposed || !_sameSession(current)) return false;
        try {
          return await _sendPayload(conversationId, type, body);
        } catch (_) {
          return false;
        }
      },
      postableConversationIds: () => [
        for (final conversation in conversations)
          if (_profileKeyTarget(conversation)) conversation.id,
      ],
      coMemberAccountIds: _coMemberAccounts,
    );
    try {
      await service.load();
    } catch (_) {
      service.dispose();
      return;
    }
    if (!_sameSession(current) || _disposed) {
      service.dispose();
      return;
    }
    profiles = service..addListener(notifyListeners);
    notifyListeners();
    _profileTimer?.cancel();
    _profileTimer = Timer.periodic(
        const Duration(hours: 24), (_) => unawaited(_profileCheck()));
    unawaited(_profileCheck());
  }

  void _stopProfiles() {
    _profileTimer?.cancel();
    _profileTimer = null;
    final service = profiles;
    profiles = null;
    service?.removeListener(notifyListeners);
    service?.dispose();
  }

  /// The periodic check, and what a fresh start needs: key messages that
  /// could not be queued, conversations new to this device, and the records
  /// whose version moved.
  Future<void> _profileCheck() async {
    final service = profiles;
    if (service == null || session == null) return;
    try {
      await _profileLoadRosters();
      await service.retryDeliveries();
      await _profileNoteConversations();
      await service.onKeysMayHaveArrived();
      await service.checkVersions(
        accountIds: <String>{
          if (session?.accountId != null) session!.accountId!,
          for (final conversation in conversations)
            if (conversation.peerAccountId != null) conversation.peerAccountId!,
          for (final members in membersByConversation.values)
            for (final member in members) member.accountId,
        },
        conversationIds: [
          for (final conversation in conversations)
            if (conversation.isGroup) conversation.id,
        ],
      );
    } catch (_) {
      // Profiles are best effort; the next check tries again.
    }
  }

  /// Reads the rosters of groups not loaded yet (a bounded number per
  /// check), so the audience can be judged from the whole picture.
  Future<void> _profileLoadRosters() async {
    final current = session;
    final client = api;
    if (current == null || client == null) return;
    var budget = 40;
    for (final conversation in List<Conversation>.of(conversations)) {
      if (budget == 0) break;
      if (conversation.isDm ||
          membersByConversation.containsKey(conversation.id)) {
        continue;
      }
      budget--;
      try {
        final members =
            await client.conversationMembers(current.token, conversation.id);
        if (!_sameSession(current)) return;
        membersByConversation = <String, List<ConversationMember>>{
          ...membersByConversation,
          conversation.id: members,
        };
      } catch (_) {
        // A roster that cannot be read leaves the picture incomplete.
      }
    }
    _profileRosterChanged();
  }

  /// The account key goes into every conversation once. Only the device with
  /// the lowest id among this account's devices does it, so a second device
  /// does not repeat the burst.
  Future<void> _profileNoteConversations() async {
    final service = profiles;
    final self = session?.deviceId;
    if (service == null || self == null) return;
    final active = devices.where((d) => d.revokedAt == null).map((d) => d.id);
    if (active.isNotEmpty &&
        active.reduce((a, b) => a.compareTo(b) <= 0 ? a : b) != self) {
      return;
    }
    await service.noteConversations([
      for (final conversation in conversations)
        if (_profileKeyTarget(conversation)) conversation.id,
    ]);
  }

  /// Every other account this one shares a conversation with, or null while
  /// a group's roster is not loaded (no rotation is judged from part of the
  /// picture).
  Set<String>? _coMemberAccounts() {
    final self = session?.accountId;
    final out = <String>{};
    for (final conversation in conversations) {
      if (conversation.isDm) {
        final peer = conversation.peerAccountId;
        if (peer != null) out.add(peer);
        continue;
      }
      final members = membersByConversation[conversation.id];
      if (members == null) return null;
      for (final member in members) {
        out.add(member.accountId);
      }
    }
    if (self != null) out.remove(self);
    return out;
  }

  /// A roster loaded: judge the audience and drop what is no longer shared.
  void _profileRosterChanged() {
    final service = profiles;
    final co = _coMemberAccounts();
    if (service == null || co == null) return;
    unawaited(service.noteCoMembers(co).then((_) => service.pruneUnshared(co)));
  }

  /// Sync events that concern profiles.
  void _profileSyncEvent(SyncEvent event) {
    final service = profiles;
    if (service == null) return;
    final type = event.type;
    final conversationId = event.conversationId;
    if (type == 'profile.updated') {
      unawaited(service.onProfileUpdated(event.payload));
    } else if ((type == 'membership.removed' || type == 'membership.left') &&
        conversationId != null) {
      unawaited(service.markGroupRotationDue(conversationId));
    } else if ((type.startsWith('conversation.') ||
            type.startsWith('membership.')) &&
        conversationId != null) {
      // A roster change: the next post here carries the group key, so a
      // member who just joined learns it with no burst of messages (S13).
      unawaited(service.markGroupKeyForSidecar(conversationId));
    }
  }

  /// Adds the key sidecars to an outgoing post.
  Future<Map<String, Object?>> _withProfileSidecars(
    String conversationId,
    AppPayloadType type,
    Map<String, Object?> body,
  ) async {
    final service = profiles;
    if (service == null ||
        !const {
          AppPayloadType.text,
          AppPayloadType.reply,
          AppPayloadType.attachmentManifest,
          AppPayloadType.poll,
        }.contains(type)) {
      return body;
    }
    // A text near the payload limit has no room for a key.
    final text = body['text'];
    if (text is String && text.length > 8000) return body;
    try {
      final extras = await service.sidecars(conversationId);
      return extras.isEmpty ? body : <String, Object?>{...body, ...extras};
    } catch (_) {
      return body;
    }
  }

  @visibleForTesting
  void debugProfileSyncEvent(SyncEvent event) => _profileSyncEvent(event);

  @visibleForTesting
  Future<Map<String, Object?>> debugWithProfileSidecars(String conversationId,
          AppPayloadType type, Map<String, Object?> body) =>
      _withProfileSidecars(conversationId, type, body);

  /// Sets this account's display name and photo (null clears each).
  Future<bool> saveOwnProfile({String? name, ProfilePhoto? photo}) =>
      _profileWrite(() => profiles!.saveOwnProfile(name: name, photo: photo));

  /// Sets a group's name and photo (null clears each).
  Future<bool> saveGroupProfile(String conversationId,
          {String? name, ProfilePhoto? photo}) =>
      _profileWrite(() =>
          profiles!.saveGroupProfile(conversationId, name: name, photo: photo));

  Future<bool> _profileWrite(Future<void> Function() write) async {
    if (profiles == null) return false;
    return _runScoped(Ops.profile, () async {
      try {
        await write();
      } on ProfileConflictException {
        throw UserFacingException(l10n.profileSaveConflict);
      } on ProfileRecordException {
        throw UserFacingException(l10n.profileSaveInvalid);
      }
    });
  }

  /// Blocking drops the blocked account's cached profile and keys, and the
  /// next write of this account's own profile uses a new key (B1).
  void _profileAccountBlocked(String accountId) {
    final service = profiles;
    if (service == null) return;
    unawaited(service.forgetAccount(accountId));
    unawaited(service.markOwnRotationDue());
  }

  void _profileConversationLeft(String conversationId) {
    unawaited(profiles?.forgetConversation(conversationId));
  }
}
