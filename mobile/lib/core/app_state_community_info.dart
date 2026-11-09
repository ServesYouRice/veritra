part of 'app_state.dart';

/// C3 in the app (docs/designs/C3-private-channels-and-info.md): encrypted
/// community, category and channel names and topics.
///
/// The rules live in [CommunityInfoService]; this part only connects it to
/// the session, the server, the send path and the community lists. Names
/// are shown in this order: the accepted encrypted record, then the legacy
/// server name, then a placeholder (the screen's). The plaintext name is
/// still sent at creation until step 4 (it needs C4's role wiring first, or
/// every community would go nameless).
///
/// What other members' devices may set is checked against the community's
/// verified C4 role state ([VerifiedRoleSource]); until the app holds one,
/// nothing another account wrote is shown (D80).
extension CommunityInfoActions on AppState {
  /// The session's info service, made on first use. Null without a session,
  /// a server or the native crypto service.
  CommunityInfoService? get _info {
    final current = session;
    final client = api;
    final crypto = cryptoService;
    final deviceId = current?.deviceId;
    final accountId = current?.accountId;
    if (current == null ||
        client == null ||
        deviceId == null ||
        accountId == null ||
        crypto is! NativeCryptoService) {
      return null;
    }
    final owner = '$accountId|$deviceId|$_sessionGeneration';
    if (_infoServiceOwner == owner && _infoService != null) {
      return _infoService;
    }
    _infoServiceOwner = owner;
    return _infoService = CommunityInfoService(
      store: localStore,
      api: _AppInfoApi(client, current.token),
      send: (conversationId, type, body) => _sendPayload(
          conversationId, type, body,
          channelId: _infoChannelFor(conversationId)),
      topology: _AppInfoTopology(this),
      codec: CommunityInfoCodec(crypto.bindings),
      policyFor: (communityId) =>
          GovernanceInfoEditPolicy(verifiedCommunityRoles(communityId)),
      accountId: accountId,
      deviceId: deviceId,
      onChanged: notifyListeners,
    );
  }

  /// The community's verified C4 role state, or null while the app holds
  /// none. It comes from [VerifiedRoleSource] (the C4 client wiring); a test
  /// may set [AppState.debugInfoRoleSource].
  GovernanceState? verifiedCommunityRoles(String communityId) {
    final shared = communities
        .where((c) => c.id == communityId)
        .firstOrNull
        ?.sharedConversationId;
    if (shared == null) return null;
    final Object self = this;
    final source =
        debugInfoRoleSource ?? (self is VerifiedRoleSource ? self : null);
    try {
      return source?.governanceOf(shared);
    } catch (_) {
      return null;
    }
  }

  /// The open channel a hidden info payload rides on in a shared group (C0
  /// needs one). Null for any other conversation.
  String? _infoChannelFor(String conversationId) {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    final communityId = conversation?.communityId;
    if (conversation == null ||
        !conversation.isCommunityShared ||
        communityId == null) {
      return null;
    }
    final routed = (channelsByCommunity[communityId] ?? const <Channel>[])
        .where((c) => c.conversationId == conversationId && c.isRouted);
    return (routed.where((c) => c.kind == 'open').firstOrNull ??
            routed.where((c) => c.kind != 'private').firstOrNull)
        ?.id;
  }

  /// The name to show for a community: the accepted encrypted one, else the
  /// legacy server name; null when neither (the screen shows a placeholder).
  String? communityDisplayName(Community community) {
    final name = _info?.shown(infoKindCommunity, community.id)?.name;
    if (name != null) return name;
    return community.name.trim().isEmpty ? null : community.name;
  }

  /// The name to show for a channel, as [communityDisplayName].
  String? channelDisplayName(Channel channel) {
    final name = _info?.shown(infoKindChannel, channel.id)?.name;
    if (name != null) return name;
    return channel.name.trim().isEmpty ? null : channel.name;
  }

  /// A channel's encrypted topic, or null.
  String? channelTopic(Channel channel) {
    final topic = _info?.shown(infoKindChannel, channel.id)?.topic;
    return topic == null || topic.isEmpty ? null : topic;
  }

  /// Whether this account may edit [kind] info in [communityId] under the
  /// verified role state: the edit UI shows only then, so a device never
  /// makes an edit other devices will not accept.
  bool mayEditCommunityInfo(String communityId, String kind) {
    final accountId = session?.accountId;
    if (accountId == null) return false;
    return GovernanceInfoEditPolicy(verifiedCommunityRoles(communityId))
        .mayEdit(accountId, kind);
  }

  static InfoSubject _communitySubject(String communityId) =>
      InfoSubject(infoKindCommunity, communityId, communityId);

  /// The community record as it stands, or one built from the legacy name
  /// and the open channels the app knows.
  CommunityInfoRecord _communityRecordNow(String communityId, int revision) {
    final shown = _info?.shown(infoKindCommunity, communityId);
    final community = communities.where((c) => c.id == communityId).firstOrNull;
    final open = (channelsByCommunity[communityId] ?? const <Channel>[])
        .where((c) => c.isRouted && c.kind != 'private')
        .map((c) => c.id)
        .toList();
    final kept = shown?.channels ?? const <InfoChannelPlace>[];
    final channels = <InfoChannelPlace>[
      ...kept.where((p) => open.contains(p.channelId)),
      for (final id in open)
        if (!kept.any((p) => p.channelId == id))
          InfoChannelPlace(channelId: id),
    ];
    final legacy = community?.name.trim() ?? '';
    return CommunityInfoRecord(
      kind: infoKindCommunity,
      subjectId: communityId,
      revision: revision,
      name: shown?.name ?? (legacy.isEmpty ? 'Community' : legacy),
      icon: shown?.icon,
      categories: shown?.categories ?? const <String>[],
      channels: channels.take(infoMaxChannels).toList(),
    );
  }

  /// Writes the community's encrypted record from what the app knows, with
  /// [name] when given. Owners and admins only (the server checks too).
  Future<bool> publishCommunityInfo(String communityId, {String? name}) async {
    final service = _info;
    if (service == null) return false;
    try {
      await service.publish(_communitySubject(communityId), (revision) {
        final now = _communityRecordNow(communityId, revision);
        return CommunityInfoRecord(
          kind: now.kind,
          subjectId: now.subjectId,
          revision: revision,
          name: name?.trim() ?? now.name,
          icon: now.icon,
          categories: now.categories,
          channels: now.channels,
        );
      });
      return true;
    } catch (err) {
      // Body-free: no name, key or server text.
      developer.log('c3_publish_failed ${err.runtimeType}',
          name: 'veritra.sync');
      return false;
    }
  }

  /// Writes a channel's encrypted name and topic. Any member may, unless
  /// admins restrict channel info (D80; the UI asks [mayEditCommunityInfo]).
  Future<bool> publishChannelInfo(Channel channel,
      {required String name, String topic = ''}) async {
    final service = _info;
    if (service == null) return false;
    final private = channel.kind == 'private';
    final position = private
        ? (channelsByCommunity[channel.communityId] ?? const <Channel>[])
            .where((c) => c.kind == 'private')
            .toList()
            .indexWhere((c) => c.id == channel.id)
        : 0;
    final current = service.shown(infoKindChannel, channel.id);
    try {
      await service.publish(
        InfoSubject(infoKindChannel, channel.id, channel.communityId),
        (revision) => CommunityInfoRecord(
          kind: infoKindChannel,
          subjectId: channel.id,
          revision: revision,
          name: name.trim(),
          topic: topic.trim(),
          icon: current?.icon,
          privatePlace: private
              ? current?.privatePlace ??
                  InfoPrivatePlace(position: position < 0 ? 0 : position)
              : null,
        ),
      );
      return true;
    } catch (err) {
      developer.log('c3_publish_failed ${err.runtimeType}',
          name: 'veritra.sync');
      return false;
    }
  }

  /// After a member left [conversationId] (removed, kicked or banned): the
  /// key that conversation carries rotates at once (D80). The rotation runs
  /// once the removal commit is applied; the send path holds it until then.
  Future<void> _markInfoRotation(String conversationId) async {
    final service = _info;
    if (service == null) return;
    for (final community in communities) {
      if (community.sharedConversationId == conversationId) {
        final home = service.homeOf(_communitySubject(community.id));
        if (home != null) await service.markRotationDue(home, community.id);
      }
      for (final channel
          in channelsByCommunity[community.id] ?? const <Channel>[]) {
        if (channel.kind == 'private' &&
            channel.conversationId == conversationId) {
          final home = service
              .homeOf(InfoSubject(infoKindChannel, channel.id, community.id));
          if (home != null) await service.markRotationDue(home, community.id);
        }
      }
    }
    unawaited(refreshCommunityInfo());
  }

  /// One pass over every community with the shared-group layout: fetch and
  /// judge each record, answer key requests, and run due rotations. Runs on
  /// `info.updated`, when the communities load, and after a catch-up (at
  /// most once a minute). Never throws.
  Future<void> refreshCommunityInfo() async {
    final service = _info;
    final current = session;
    final client = api;
    if (service == null || current == null || client == null) return;
    if (_infoRefreshRunning) {
      _infoRefreshAgain = true;
      return;
    }
    _infoRefreshRunning = true;
    _lastInfoRefresh = DateTime.now();
    try {
      do {
        _infoRefreshAgain = false;
        for (final community in List.of(communities)) {
          if (!_sameSession(current)) return;
          if (community.sharedConversationId == null) continue;
          await _refreshOneCommunity(service, client, current, community);
        }
        await service.runRotations((home, communityId) => [
              if (home.keySubjectKind == infoKindChannel)
                InfoSubject(infoKindChannel, home.keySubjectId, communityId)
              else ...[
                _communitySubject(communityId),
                for (final c in service
                        .shown(infoKindCommunity, communityId)
                        ?.categories ??
                    const <String>[])
                  InfoSubject(infoKindCategory, c, communityId),
                for (final ch
                    in channelsByCommunity[communityId] ?? const <Channel>[])
                  if (ch.kind != 'private')
                    InfoSubject(infoKindChannel, ch.id, communityId),
              ],
            ]);
      } while (_infoRefreshAgain && _sameSession(current));
    } catch (err) {
      developer.log('c3_refresh_failed ${err.runtimeType}',
          name: 'veritra.sync');
    } finally {
      _infoRefreshRunning = false;
    }
  }

  Future<void> _refreshOneCommunity(CommunityInfoService service,
      ApiClient client, Session current, Community community) async {
    // Who answers key requests: owners and admins by the server's word.
    try {
      final members =
          await client.communityMembers(current.token, community.id);
      _infoAdminOf[community.id] = members.any((m) =>
          m.accountId == current.accountId &&
          (m.role == 'owner' || m.role == 'admin'));
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) rethrow;
    }
    final subjects = <InfoSubject>[
      _communitySubject(community.id),
    ];
    for (final subject in subjects.toList()) {
      await _refreshSubject(service, subject);
    }
    final record = service.shown(infoKindCommunity, community.id);
    for (final category in record?.categories ?? const <String>[]) {
      await _refreshSubject(
          service, InfoSubject(infoKindCategory, category, community.id));
    }
    for (final channel
        in channelsByCommunity[community.id] ?? const <Channel>[]) {
      await _refreshSubject(
          service, InfoSubject(infoKindChannel, channel.id, community.id));
    }
    // Answer what this device can: the community key, and each private
    // channel's key in its own group.
    final homes = <InfoKeyHome>{
      if (service.homeOf(_communitySubject(community.id)) case final home?)
        home,
      for (final channel
          in channelsByCommunity[community.id] ?? const <Channel>[])
        if (channel.kind == 'private')
          if (service.homeOf(
                  InfoSubject(infoKindChannel, channel.id, community.id))
              case final home?)
            home,
    };
    for (final home in homes) {
      await service.answerRequests(home, community.id);
    }
  }

  Future<void> _refreshSubject(
      CommunityInfoService service, InfoSubject subject) async {
    try {
      await service.refresh(subject);
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) rethrow;
      developer.log('c3_subject_refresh_failed ${err.runtimeType}',
          name: 'veritra.sync');
    }
  }
}

class _AppInfoApi implements InfoApi {
  _AppInfoApi(this.client, this.token);
  final ApiClient client;
  final String token;

  @override
  Future<ServedCommunityInfo?> get(
      {required String kind,
      required String subjectId,
      String? communityId}) async {
    final got = await client.getInfoRecord(token,
        kind: kind, subjectId: subjectId, communityId: communityId);
    if (got == null) return null;
    return ServedCommunityInfo(
        subjectKind: kind,
        subjectId: subjectId,
        version: got.version,
        keyId: got.keyId,
        blob: got.blob);
  }

  @override
  Future<int> put(
      {required String kind,
      required String subjectId,
      String? communityId,
      required String keyId,
      required List<int> blob,
      required int expectedVersion}) async {
    try {
      return await client.putInfoRecord(token,
          kind: kind,
          subjectId: subjectId,
          communityId: communityId,
          keyId: keyId,
          blob: blob,
          expectedVersion: expectedVersion);
    } on ApiException catch (err) {
      if (err.statusCode == 412) throw const InfoVersionConflict();
      rethrow;
    }
  }
}

class _AppInfoTopology implements InfoTopology {
  _AppInfoTopology(this.state);
  final AppState state;

  @override
  String? sharedConversationOf(String communityId) => state.communities
      .where((c) => c.id == communityId)
      .firstOrNull
      ?.sharedConversationId;

  @override
  String? privateConversationOf(String channelId) {
    for (final channels in state.channelsByCommunity.values) {
      for (final c in channels) {
        if (c.id == channelId && c.kind == 'private' && c.isRouted) {
          return c.conversationId;
        }
      }
    }
    return null;
  }

  @override
  bool serverSaysAdmin(String communityId) =>
      state._infoAdminOf[communityId] ?? false;
}
