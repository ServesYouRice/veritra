part of 'app_state.dart';

/// C3 in the app (docs/designs/C3-private-channels-and-info.md): encrypted
/// community, category and channel names and topics.
///
/// The rules live in [CommunityInfoService]; this part only connects it to
/// the session, the server, the send path and the community lists. Names
/// are shown from the accepted encrypted record, else a placeholder (the
/// screen's). The server keeps no names (step 4, migration 0082): a name
/// typed at creation goes only into the encrypted record.
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
    final Object crypto = cryptoService;
    final deviceId = current?.deviceId;
    final accountId = current?.accountId;
    if (current == null ||
        client == null ||
        deviceId == null ||
        accountId == null ||
        crypto is! CommunityInfoCryptoService) {
      return null;
    }
    final owner = '$accountId|$deviceId|$_sessionGeneration';
    final previous = _infoServiceSession;
    if (_infoServiceOwner == owner &&
        previous != null &&
        _sameSession(previous) &&
        _infoService != null) {
      return _infoService;
    }
    _infoServiceOwner = owner;
    _infoServiceSession = current;
    // Another session: nothing learned for the last one carries over.
    _infoAdminOf.clear();
    _infoPublishing.clear();
    final generation = _sessionGeneration;
    bool active() => !_disposed && _syncOwnerActive(current, generation);
    final Object service = cryptoService;
    final mls = service is MlsConversationCryptoService ? service : null;
    return _infoService = CommunityInfoService(
      store: localStore,
      api: _AppInfoApi(client, current.token, active),
      send: (conversationId, type, body) => active()
          ? _sendPayload(conversationId, type, body,
              channelId: _infoChannelFor(conversationId))
          : Future.value(false),
      // Background info sends report under their own op, never as the
      // composer's send.
      topology: _AppInfoTopology(this),
      codec: crypto.communityInfoCodec,
      policyFor: (communityId) =>
          GovernanceInfoEditPolicy(verifiedCommunityRoles(communityId)),
      // Who rotates after a removal: the verified record's owner and
      // admins, never a moderator, whatever the server says.
      verifiedRolesOf: verifiedCommunityRoles,
      accountId: accountId,
      deviceId: deviceId,
      onChanged: () {
        if (active()) notifyListeners();
      },
      // A new info key is stamped with the group's epoch (key freshness).
      epochOf: mls == null
          ? null
          : (conversationId) async {
              try {
                return (await mls.groupEpoch(conversationId))?.epoch;
              } catch (_) {
                return null;
              }
            },
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
    // An announcement channel takes posts from owners and admins only; a
    // member's request waits for an open channel.
    return (routed.where((c) => c.kind == 'open').firstOrNull ??
            (_infoAdminOf[communityId] == true
                ? routed.where((c) => c.kind == 'announcement').firstOrNull
                : null))
        ?.id;
  }

  /// The name to show for a community: the accepted encrypted record's, or
  /// null (the screen shows a placeholder). The server keeps no name (C3
  /// step 4), so there is no plaintext fallback.
  String? communityDisplayName(Community community) =>
      _info?.shown(infoKindCommunity, community.id)?.name;

  /// The name to show for a channel, as [communityDisplayName].
  String? channelDisplayName(Channel channel) =>
      _info?.shown(infoKindChannel, channel.id)?.name;

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
      name: shown?.name ?? legacy,
      icon: shown?.icon,
      categories: shown?.categories ?? const <String>[],
      channels: channels.take(infoMaxChannels).toList(),
    );
  }

  /// Writes the community's encrypted record from what the app knows, with
  /// [name] when given. Owners and admins only (the server checks too).
  /// [mint] only when the community was just created: anyone else without
  /// the key asks for it instead of making a parallel one.
  ///
  /// Never call it from inside the session queue (`_run`): it sends, and a
  /// send queues behind the caller.
  ///
  /// [edit] changes the record built from what the app knows (icon,
  /// categories, channel places) before it is sealed.
  Future<bool> publishCommunityInfo(String communityId,
      {String? name,
      bool mint = false,
      CommunityInfoRecord Function(CommunityInfoRecord now)? edit}) async {
    final service = _info;
    if (service == null) return false;
    final known = name?.trim() ??
        service.shown(infoKindCommunity, communityId)?.name ??
        communities.where((c) => c.id == communityId).firstOrNull?.name.trim();
    if (known == null || known.isEmpty) return false;
    final previous = _infoPublishing[communityId];
    final done = Completer<void>();
    _infoPublishing[communityId] = done.future;
    if (previous != null) await previous;
    try {
      await service.loadAccepted(_communitySubject(communityId));
      final revision =
          service.shown(infoKindCommunity, communityId)?.revision ?? 0;
      await service.publish(_communitySubject(communityId), (revision) {
        final now = _communityRecordNow(communityId, revision);
        final named = CommunityInfoRecord(
          kind: now.kind,
          subjectId: now.subjectId,
          revision: revision,
          name: name?.trim() ?? now.name,
          icon: now.icon,
          categories: now.categories,
          channels: now.channels,
        );
        return edit == null ? named : edit(named);
      }, mint: mint, expectedRevision: revision);
      return true;
    } catch (err) {
      // Body-free: no name, key or server text.
      developer.log('c3_publish_failed ${err.runtimeType}',
          name: 'veritra.sync');
      return false;
    } finally {
      done.complete();
      if (identical(_infoPublishing[communityId], done.future)) {
        _infoPublishing.remove(communityId);
      }
    }
  }

  /// Writes a channel's encrypted name and topic. Any member may, unless
  /// admins restrict channel info (D80; the UI asks [mayEditCommunityInfo]).
  /// [mint] only for a private channel just created (its own key). Never
  /// call it from inside the session queue.
  ///
  /// [categoryId] moves a private channel (its record holds its place);
  /// [moveCategory] says whether to apply it, so null can mean "none".
  Future<bool> publishChannelInfo(Channel channel,
      {required String name,
      String topic = '',
      bool mint = false,
      bool moveCategory = false,
      String? categoryId}) async {
    final service = _info;
    if (service == null) return false;
    final private = channel.kind == 'private';
    final position = private
        ? (channelsByCommunity[channel.communityId] ?? const <Channel>[])
            .where((c) => c.kind == 'private')
            .toList()
            .indexWhere((c) => c.id == channel.id)
        : 0;
    // A community record still being written (its key made at creation)
    // finishes first, so an open channel created right after finds the key.
    final pending = _infoPublishing[channel.communityId];
    if (pending != null) await pending;
    try {
      final subject =
          InfoSubject(infoKindChannel, channel.id, channel.communityId);
      await service.loadAccepted(subject);
      final current = service.shown(infoKindChannel, channel.id);
      await service.publish(
        subject,
        (revision) => CommunityInfoRecord(
          kind: infoKindChannel,
          subjectId: channel.id,
          revision: revision,
          name: name.trim(),
          topic: topic.trim(),
          icon: current?.icon,
          privatePlace: private
              ? moveCategory
                  ? InfoPrivatePlace(
                      categoryId: categoryId,
                      position: current?.privatePlace?.position ??
                          (position < 0 ? 0 : position))
                  : current?.privatePlace ??
                      InfoPrivatePlace(position: position < 0 ? 0 : position)
              : null,
        ),
        mint: mint && private,
        expectedRevision: current?.revision ?? 0,
      );
      return true;
    } catch (err) {
      developer.log('c3_publish_failed ${err.runtimeType}',
          name: 'veritra.sync');
      return false;
    }
  }

  /// The community's categories in order, from its accepted record.
  List<String> communityCategories(String communityId) =>
      _info?.shown(infoKindCommunity, communityId)?.categories ??
      const <String>[];

  /// A category's encrypted name, or null (show a placeholder).
  String? categoryDisplayName(String categoryId) {
    final record = _info?.shown(infoKindCategory, categoryId);
    return record == null || record.isTombstone ? null : record.name;
  }

  /// The category [channel] sits in, or null. An open channel's place is in
  /// the community record; a private channel's in its own record, so members
  /// outside it never learn where it sits.
  String? channelCategory(Channel channel) {
    final service = _info;
    if (service == null) return null;
    final String? id;
    if (channel.kind == 'private') {
      id = service.shown(infoKindChannel, channel.id)?.privatePlace?.categoryId;
    } else {
      id = service
          .shown(infoKindCommunity, channel.communityId)
          ?.channels
          ?.where((p) => p.channelId == channel.id)
          .firstOrNull
          ?.categoryId;
    }
    return id != null && communityCategories(channel.communityId).contains(id)
        ? id
        : null;
  }

  /// The community's encrypted icon, or null.
  ProfilePhoto? communityIcon(Community community) =>
      _info?.shown(infoKindCommunity, community.id)?.icon;

  /// Sets or clears ([icon] null) the community icon. Owners and admins only.
  Future<bool> setCommunityIcon(String communityId, ProfilePhoto? icon) =>
      publishCommunityInfo(communityId,
          edit: (now) => CommunityInfoRecord(
                kind: now.kind,
                subjectId: now.subjectId,
                revision: now.revision,
                name: now.name,
                icon: icon,
                categories: now.categories,
                channels: now.channels,
              ));

  /// Makes a category: its own encrypted record (under the community key),
  /// then the community record lists it. Returns its id, or null. Owners and
  /// admins only; the server binds the id to this community on first write.
  Future<String?> createCommunityCategory(
      String communityId, String name) async {
    final service = _info;
    final trimmed = name.trim();
    if (service == null || trimmed.isEmpty) return null;
    final existing = communityCategories(communityId);
    if (existing.length >= infoMaxCategories) return null;
    // A deleted category's id is reused first: the server binds each id to
    // the community for good, at most 200 of them.
    final reuse = service
        .tombstonedCategories(communityId)
        .where((id) => !existing.contains(id))
        .firstOrNull;
    final String id;
    if (reuse != null) {
      id = reuse;
    } else {
      final random = Random.secure();
      final hex = List<String>.generate(
              16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      id = 'cat_$hex';
    }
    final expected =
        reuse == null ? 0 : service.shown(infoKindCategory, id)?.revision ?? 0;
    if (!await _publishCategory(communityId, id, trimmed, expected: expected)) {
      return null;
    }
    final listed = await publishCommunityInfo(communityId,
        edit: (now) => CommunityInfoRecord(
              kind: now.kind,
              subjectId: now.subjectId,
              revision: now.revision,
              name: now.name,
              icon: now.icon,
              categories: <String>[
                ...?now.categories?.where((c) => c != id),
                id,
              ],
              channels: now.channels,
            ));
    return listed ? id : null;
  }

  /// Deletes a category (C3: a tombstone, there is no client DELETE). The
  /// community record drops it and every open channel in it first, so it
  /// leaves the view at once; then the category's own record becomes a
  /// tombstone, whose id a later category reuses. A private channel's own
  /// place keeps the id but shows no category, since the community no
  /// longer lists it. Owners and admins only.
  Future<bool> deleteCommunityCategory(
      String communityId, String categoryId) async {
    final service = _info;
    if (service == null ||
        !communityCategories(communityId).contains(categoryId)) {
      return false;
    }
    final unlisted = await publishCommunityInfo(communityId,
        edit: (now) => CommunityInfoRecord(
              kind: now.kind,
              subjectId: now.subjectId,
              revision: now.revision,
              name: now.name,
              icon: now.icon,
              categories: <String>[
                ...?now.categories?.where((c) => c != categoryId),
              ],
              channels: <InfoChannelPlace>[
                for (final place in now.channels ?? const <InfoChannelPlace>[])
                  place.categoryId == categoryId
                      ? InfoChannelPlace(channelId: place.channelId)
                      : place,
              ],
            ));
    if (!unlisted) return false;
    final pending = _infoPublishing[communityId];
    if (pending != null) await pending;
    try {
      await service.publish(
        InfoSubject(infoKindCategory, categoryId, communityId),
        (revision) => CommunityInfoRecord(
          kind: infoKindCategory,
          subjectId: categoryId,
          revision: revision,
        ),
        expectedRevision:
            service.shown(infoKindCategory, categoryId)?.revision ?? 0,
      );
    } catch (err) {
      // The category is already out of the community's list; only its id
      // is not free for reuse yet.
      developer.log('c3_publish_failed ${err.runtimeType}',
          name: 'veritra.sync');
    }
    return true;
  }

  /// Renames a category. Owners and admins only.
  Future<bool> renameCommunityCategory(
      String communityId, String categoryId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return Future.value(false);
    return _publishCategory(communityId, categoryId, trimmed,
        expected: _info?.shown(infoKindCategory, categoryId)?.revision ?? 0);
  }

  Future<bool> _publishCategory(
      String communityId, String categoryId, String name,
      {required int expected}) async {
    final service = _info;
    if (service == null) return false;
    final pending = _infoPublishing[communityId];
    if (pending != null) await pending;
    try {
      await service.publish(
        InfoSubject(infoKindCategory, categoryId, communityId),
        (revision) => CommunityInfoRecord(
          kind: infoKindCategory,
          subjectId: categoryId,
          revision: revision,
          name: name,
        ),
        expectedRevision: expected,
      );
      return true;
    } catch (err) {
      developer.log('c3_publish_failed ${err.runtimeType}',
          name: 'veritra.sync');
      return false;
    }
  }

  /// Puts [channel] in [categoryId] (null: none). An open channel's place is
  /// the community record's (owners and admins); a private channel's is its
  /// own record's.
  Future<bool> placeChannel(Channel channel, String? categoryId) async {
    if (categoryId != null &&
        !communityCategories(channel.communityId).contains(categoryId)) {
      return false;
    }
    if (channel.kind == 'private') {
      final current = _info?.shown(infoKindChannel, channel.id);
      final name = current?.name;
      if (name == null) return false;
      return publishChannelInfo(channel,
          name: name,
          topic: current?.topic ?? '',
          moveCategory: true,
          categoryId: categoryId);
    }
    return publishCommunityInfo(channel.communityId,
        edit: (now) => CommunityInfoRecord(
              kind: now.kind,
              subjectId: now.subjectId,
              revision: now.revision,
              name: now.name,
              icon: now.icon,
              categories: now.categories,
              channels: <InfoChannelPlace>[
                for (final place in now.channels ?? const <InfoChannelPlace>[])
                  place.channelId == channel.id
                      ? InfoChannelPlace(
                          channelId: place.channelId, categoryId: categoryId)
                      : place,
              ],
            ));
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

  /// Outbound work must run outside the session queue that merges commits:
  /// sending a payload queues behind it. Request/answer remains the recovery
  /// path if this best-effort delivery is interrupted or no key is held yet.
  Future<void> _deliverInfoAfterAdd(
      Session owner, int generation, String conversationId) async {
    if (!_syncOwnerActive(owner, generation)) return;
    final service = _info;
    if (service == null) return;
    try {
      for (final community in List.of(communities)) {
        if (community.sharedConversationId == conversationId) {
          await service.loadAccepted(_communitySubject(community.id));
        }
        final channels = channelsByCommunity[community.id] ?? const <Channel>[];
        final subjects = <InfoSubject>[
          if (community.sharedConversationId == conversationId) ...[
            _communitySubject(community.id),
            for (final category
                in service.shown(infoKindCommunity, community.id)?.categories ??
                    const <String>[])
              InfoSubject(infoKindCategory, category, community.id),
            for (final channel in channels)
              if (channel.kind != 'private')
                InfoSubject(infoKindChannel, channel.id, community.id),
          ],
          for (final channel in channels)
            if (channel.kind == 'private' &&
                channel.conversationId == conversationId)
              InfoSubject(infoKindChannel, channel.id, community.id),
        ];
        if (subjects.isEmpty) continue;
        final home = service.homeOf(subjects.first);
        if (home == null || home.conversationId != conversationId) continue;
        if (!_syncOwnerActive(owner, generation)) return;
        await service.deliverAfterAdd(home, community.id, subjects);
      }
    } catch (err) {
      developer.log('c3_add_delivery_failed ${err.runtimeType}',
          name: 'veritra.sync');
    }
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
    // Until the lists load, no mark or record can be placed; a pass now
    // would see an empty world.
    if (!communitiesLoaded) return;
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
      if (_sameSession(current)) {
        _scheduleInfoRotation(await service.nextDeferredRotation(), current);
      }
    } catch (err) {
      developer.log('c3_refresh_failed ${err.runtimeType}',
          name: 'veritra.sync');
    } finally {
      _infoRefreshRunning = false;
    }
  }

  /// Runs the info pass again when a deferred remote-removal rotation's
  /// turn comes ([CommunityInfoService.nextDeferredRotation]). Passes are
  /// otherwise event driven, and a deferred mark has no event of its own.
  /// Foreground only: a background wake never sends info keys, and the next
  /// foreground catch-up runs the pass anyway.
  void _scheduleInfoRotation(DateTime? at, Session owner) {
    _infoRotationTimer?.cancel();
    _infoRotationTimer = null;
    if (at == null || _disposed) return;
    final generation = _sessionGeneration;
    var wait = at.difference(DateTime.now()) + const Duration(seconds: 1);
    if (wait.isNegative) wait = Duration.zero;
    _infoRotationTimer = Timer(wait, () {
      _infoRotationTimer = null;
      if (_disposed ||
          generation != _sessionGeneration ||
          !_sameSession(owner) ||
          !_isForeground) {
        return;
      }
      unawaited(refreshCommunityInfo());
    });
  }

  Future<void> _refreshOneCommunity(CommunityInfoService service,
      ApiClient client, Session current, Community community) async {
    // Refresh availability each pass: roles can change during a session.
    // A failed read leaves the role unknown instead of reusing old authority.
    _infoAdminOf.remove(community.id);
    try {
      final members =
          await client.communityMembers(current.token, community.id);
      if (!_sameSession(current)) return;
      _infoAdminOf[community.id] = members.any((m) =>
          m.accountId == current.accountId &&
          (m.role == 'owner' || m.role == 'admin'));
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) rethrow;
    }
    // One versions call; only subjects above what this device accepted are
    // fetched.
    final communitySubject = _communitySubject(community.id);
    await service.loadAccepted(communitySubject);
    final channels = channelsByCommunity[community.id] ?? const <Channel>[];
    final categories =
        service.shown(infoKindCommunity, community.id)?.categories ??
            const <String>[];
    Map<String, int> versions;
    try {
      versions = {
        for (final v in await client.infoVersions(current.token,
            communityIds: [community.id],
            categoryIds: categories,
            channelIds: channels.map((c) => c.id).toList()))
          '${v.kind}|${v.id}': v.version
      };
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) rethrow;
      return;
    }
    Future<void> one(InfoSubject subject) async {
      final version = versions[subject.key];
      if (version == null) return;
      await _refreshSubject(service, subject, version);
    }

    await one(communitySubject);
    // The community record may have named new categories.
    for (final category
        in service.shown(infoKindCommunity, community.id)?.categories ??
            const <String>[]) {
      final subject = InfoSubject(infoKindCategory, category, community.id);
      if (!versions.containsKey(subject.key)) {
        await _refreshSubject(service, subject, null);
      } else {
        await one(subject);
      }
    }
    for (final channel in channels) {
      await one(InfoSubject(infoKindChannel, channel.id, community.id));
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
      await service.observeRemoval(home, community.id);
      await service.answerRequests(home, community.id);
    }
  }

  Future<void> _refreshSubject(
      CommunityInfoService service, InfoSubject subject, int? version) async {
    try {
      await service.refresh(subject, knownVersion: version);
    } catch (err) {
      if (err is ApiException && err.statusCode == 401) rethrow;
      developer.log('c3_subject_refresh_failed ${err.runtimeType}',
          name: 'veritra.sync');
    }
  }
}

class _AppInfoApi implements InfoApi {
  _AppInfoApi(this.client, this.token, this.active);
  final ApiClient client;
  final String token;
  final bool Function() active;

  void checkActive() {
    if (!active()) throw const CryptoOperationCancelled();
  }

  @override
  Future<ServedCommunityInfo?> get(
      {required String kind,
      required String subjectId,
      String? communityId}) async {
    checkActive();
    final got = await client.getInfoRecord(token,
        kind: kind, subjectId: subjectId, communityId: communityId);
    checkActive();
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
    checkActive();
    try {
      final version = await client.putInfoRecord(token,
          kind: kind,
          subjectId: subjectId,
          communityId: communityId,
          keyId: keyId,
          blob: blob,
          expectedVersion: expectedVersion);
      checkActive();
      return version;
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
  bool? serverSaysAdmin(String communityId) => state._infoAdminOf[communityId];

  @override
  bool sendHeld(String conversationId) =>
      state.sendHeldForRemoval(conversationId);

  @override
  bool communityGone(String communityId) =>
      state.communitiesLoaded &&
      !state.communities.any((c) => c.id == communityId);
}
