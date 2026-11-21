part of 'app_state.dart';

/// Where the "only accept community invites from people I share a group with"
/// switch is stored (owner decision 2026-11-21). The value is scoped to the
/// server and account, so another account signed in on this device never
/// inherits it; only that exact scope followed by `true` turns it on.
const String _sharedOnlyInvitesSetting = 'c1.invites_shared_only';

/// The account event an owner or admin gets when a join request is filed for
/// a group or community it runs. It carries nothing (owner decision
/// 2026-11-21); the app shows "New join request" and the list says the rest.
const String joinRequestNoticeEventType = 'account.join_request';

/// C1: joining groups and communities through invitation links, deciding join
/// requests, and leaving or removing members of a community.
///
/// What the server records here is membership only. A member's devices join
/// or leave each MLS group through the staged commits reconcile sends (card
/// I51), so every action that changes a roster asks reconcile to run and none
/// of them claims encrypted access has changed. An invitation's secret is made
/// and kept in the link ([MembershipInviteLink]): the server and the calls
/// below only see the locator derived from it.
extension MembershipActions on AppState {
  /// Runs [body] under the membership op: its failure lands in
  /// `errorFor(Ops.membership)` and the call returns null.
  Future<T?> _membershipCall<T extends Object>(
    Future<T> Function(Session current, ApiClient client) body,
  ) async {
    T? result;
    await _runScoped(Ops.membership, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) return;
      result = await body(current, client);
    });
    return result;
  }

  /// Creates an invitation for a group or community the account owns or
  /// administers and returns the link to share. The link holds the secret and
  /// is not stored anywhere: the server keeps a hash of the locator only.
  ///
  /// The invitation is bound (D90, v3) to the target, the MLS group it admits
  /// to, this account and device, and the device's signing key: by a tag
  /// derived from the secret, by a commitment to the key in the link, and by
  /// this device's signature over the same fields and the link's locator
  /// (ABI 13 sign, domain `veritra-invite-binding-v2`). The key and the
  /// signature come from the native engine; without it (any build that is not
  /// the reviewed engine) no invitation is made.
  ///
  /// The anchor group is the group itself, or the community's shared group;
  /// a legacy community (no shared group) gets no invitation. It is anchored
  /// only if this device is in that MLS group with its own key, so a joiner's
  /// Welcome check can pass.
  Future<String?> createInviteLink(InviteTargetKind kind, String targetId) {
    return _membershipCall<String>((current, client) async {
      // Only the native engine reads the device key and signs; the
      // unavailable service implements neither, so it is refused (D90).
      final engine = cryptoService;
      if (engine is! DeviceSigningKeyCryptoService ||
          engine is! InviteBindingCryptoService) {
        throw UserFacingException(l10n.errorActionUnavailable);
      }
      final keys = engine as DeviceSigningKeyCryptoService;
      final signer = engine as InviteBindingCryptoService;
      final accountId = current.accountId;
      final deviceId = current.deviceId;
      if (accountId == null || deviceId == null) {
        throw UserFacingException(l10n.errorActionUnavailable);
      }
      final signingKey = await keys.deviceSigningPublicKey(
        accountId: accountId,
        deviceId: deviceId,
      );
      final anchorGroupId = kind == InviteTargetKind.group
          ? targetId
          : communities
              .where((community) => community.id == targetId)
              .firstOrNull
              ?.sharedConversationId;
      if (anchorGroupId == null || anchorGroupId.isEmpty) {
        throw UserFacingException(l10n.errorActionUnavailable);
      }
      Uint8List? ownLeaf;
      try {
        ownLeaf = await signer.memberSigningKey(
          conversationId: anchorGroupId,
          accountId: accountId,
          deviceId: deviceId,
        );
      } on Object {
        ownLeaf = null;
      }
      if (ownLeaf == null || !_sameBytes(ownLeaf, signingKey)) {
        throw UserFacingException(l10n.errorActionUnavailable);
      }
      final link = MembershipInviteLink.generate(
        origin: client.baseUrl,
        inviterSigningKey: signingKey,
      );
      final message = link.bindingMessage(
        kind: kind,
        targetId: targetId,
        anchorGroupId: anchorGroupId,
        inviterAccountId: accountId,
        inviterDeviceId: deviceId,
        inviterSigningKey: signingKey,
      );
      final signature = await signer.signInviteBinding(
        accountId: accountId,
        deviceId: deviceId,
        message: message,
      );
      // Never hand out a link whose own signature does not verify.
      if (!await signer.verifyInviteBinding(
        signingKey: signingKey,
        message: message,
        signature: signature,
      )) {
        throw UserFacingException(l10n.errorActionUnavailable);
      }
      await client.createMembershipInvite(
        current.token,
        kind,
        targetId,
        locator: link.locator,
        anchorGroupId: anchorGroupId,
        signingKey: signingKey,
        bindingTag: link.bindingTag(
          kind: kind,
          targetId: targetId,
          anchorGroupId: anchorGroupId,
          inviterAccountId: accountId,
          inviterDeviceId: deviceId,
          inviterSigningKey: signingKey,
        ),
        bindingSignature: signature,
      );
      return link.url;
    });
  }

  /// Whether what the server says about an invitation is what its creating
  /// device bound it to (D90, v3). Fails closed: every check below must pass,
  /// and a build without the signing engine accepts nothing.
  ///
  /// 1. The shown kind is the bound kind, the key hashes to the commitment in
  ///    the link, the tag is the one the secret makes, and the anchor names a
  ///    group (a group's own id for a group) (`MembershipInviteLink.matches`).
  /// 2. The device's signature verifies under the key over the message the
  ///    link rebuilds, in the invitation domain.
  /// 3. Where this device already holds an MLS group with the inviting device,
  ///    that group's roster key must be the key named. A stranger to the
  ///    inviter shares no group, so nothing is read and the commitment in the
  ///    link is the anchor; any group that names another key refuses.
  /// 4. A community this device already pinned to a shared group through an
  ///    earlier verified link must be anchored to that same group.
  Future<bool> _inviteBindingHolds(
    MembershipInviteLink link,
    InviteBinding binding,
    InviteTargetKind shownKind,
  ) async {
    if (binding.kind != shownKind || !link.matches(binding)) return false;
    final engine = cryptoService;
    if (engine is! InviteBindingCryptoService) return false;
    final signer = engine as InviteBindingCryptoService;
    try {
      final signed = await signer.verifyInviteBinding(
        signingKey: binding.inviterSigningKey,
        message: link.bindingMessageOf(binding),
        signature: binding.signature,
      );
      if (!signed) return false;
      if (binding.kind == InviteTargetKind.community) {
        final pinned = await localStore.loadCommunityInviteAnchor(
          binding.targetId,
        );
        if (pinned != null && pinned != binding.anchorGroupId) return false;
      }
      for (final conversation in conversations.toList(growable: false)) {
        final Uint8List? known;
        try {
          known = await signer.memberSigningKey(
            conversationId: conversation.id,
            accountId: binding.inviterAccountId,
            deviceId: binding.inviterDeviceId,
          );
        } on Object {
          // This conversation has no readable group here: nothing to compare.
          continue;
        }
        if (known == null) continue;
        if (!_sameBytes(known, binding.inviterSigningKey)) return false;
      }
    } on Object {
      return false;
    }
    return true;
  }

  /// Hides the "New join request" notice.
  void dismissJoinRequestNotice() {
    if (!joinRequestNotice) return;
    joinRequestNotice = false;
    notifyListeners();
  }

  static String _sharedOnlyScope(Session owner) =>
      '${owner.baseUrl}\u0000${owner.accountId}\u0000';

  /// Reads the stored "only from people I share a group with" switch into
  /// [communityInvitesSharedOnly]. Off when nothing (or another account's
  /// value) is stored.
  Future<void> loadCommunityInvitesSharedOnly() async {
    final owner = session;
    if (owner == null) return;
    final String? raw;
    try {
      raw = await localStore.loadSetting(_sharedOnlyInvitesSetting);
    } on Object {
      return;
    }
    if (!identical(session, owner)) return;
    final value = raw == '${_sharedOnlyScope(owner)}true';
    if (value == communityInvitesSharedOnly) return;
    communityInvitesSharedOnly = value;
    notifyListeners();
  }

  /// Turns the switch on or off for this account. False when it could not be
  /// stored (the choice still applies until the app restarts).
  Future<bool> setCommunityInvitesSharedOnly(bool value) async {
    final owner = session;
    communityInvitesSharedOnly = value;
    notifyListeners();
    if (owner == null) return false;
    try {
      await localStore.saveSetting(
        _sharedOnlyInvitesSetting,
        '${_sharedOnlyScope(owner)}$value',
      );
      return true;
    } on Object {
      return false;
    }
  }

  /// Whether this device shares a group or conversation with [accountId]:
  /// the account is in the MLS roster of one of its groups (read from the
  /// group's own tree, never the server's member list), or is the other side
  /// of a direct conversation. A message request does not count: it is how a
  /// stranger first reaches someone.
  bool sharesConversationWith(String accountId) {
    if (accountId == session?.accountId) return true;
    final engine = cryptoService;
    final roster = engine is MlsRosterSource ? engine as MlsRosterSource : null;
    for (final conversation in conversations.toList(growable: false)) {
      if (isMessageRequest(conversation)) continue;
      if (conversation.peerAccountId == accountId) return true;
      final members = roster?.groupMemberAccounts(conversation.id);
      if (members != null && members.contains(accountId)) return true;
    }
    return false;
  }

  /// Refuses a community invitation from someone this account shares no group
  /// or conversation with, when the switch is on (owner decision 2026-11-21).
  /// Runs after the binding check, so a forged link still reads as unusable.
  void _refuseStrangerInvite(InviteTargetKind kind, InviteBinding binding) {
    if (kind != InviteTargetKind.community || !communityInvitesSharedOnly) {
      return;
    }
    if (!sharesConversationWith(binding.inviterAccountId)) {
      throw UserFacingException(l10n.joinInviteFromStranger);
    }
  }

  /// C1 v3: the shared group a verified invitation pinned each of
  /// [communities] to, or null where none was pinned. Throws when the store
  /// cannot answer, so the caller keeps what it already shows rather than
  /// trust the server's mapping or drop a community.
  Future<Map<String, String?>> _communityInviteAnchorsOf(
    List<Community> communities,
  ) async =>
      <String, String?>{
        for (final community in communities)
          community.id:
              await localStore.loadCommunityInviteAnchor(community.id),
      };

  /// C1 v3: whether the server's account of [community] agrees with the
  /// shared group in [pinned] (from [_communityInviteAnchorsOf]): its shared
  /// group is the pinned one and so is every open or announcement channel's.
  /// A community this device never pinned passes.
  static bool _communityKeepsInviteAnchor(
    Community community,
    List<Channel> channels,
    String? pinned,
  ) {
    if (pinned == null) return true;
    if (community.sharedConversationId != pinned) return false;
    for (final channel in channels) {
      if (channel.kind == 'private') continue;
      if (channel.conversationId != pinned) return false;
    }
    return true;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  Future<List<MembershipInvite>?> loadMembershipInvites(
    InviteTargetKind kind,
    String targetId,
  ) {
    return _membershipCall<List<MembershipInvite>>(
      (current, client) =>
          client.listMembershipInvites(current.token, kind, targetId),
    );
  }

  Future<bool> revokeMembershipInvite(String inviteId) async {
    final done = await _membershipCall<bool>((current, client) async {
      await client.revokeMembershipInvite(current.token, inviteId);
      return true;
    });
    return done ?? false;
  }

  /// Reads a pasted link and asks the server what it leads to. A link of
  /// another server, a malformed one, and a revoked, expired or used up one
  /// each fail with a message that does not repeat the input.
  Future<({MembershipInviteLink link, InvitePreview preview})?>
      previewInviteLink(String text) {
    return _membershipCall<
        ({
          MembershipInviteLink link,
          InvitePreview preview
        })>((current, client) async {
      final link = MembershipInviteLink.tryParse(
        text,
        expectedOrigin: client.baseUrl,
      );
      if (link == null) throw UserFacingException(l10n.joinLinkInvalid);
      try {
        final preview = await client.previewMembershipInvite(
          current.token,
          link.locator,
        );
        // What the server says the link leads to must be what the device that
        // made the link bound it to, signed by that device and anchored to its
        // key. A swapped target fails here, before the person sees it or any
        // request is filed.
        if (!await _inviteBindingHolds(link, preview.binding, preview.kind)) {
          throw UserFacingException(l10n.joinLinkUnusable);
        }
        await loadCommunityInvitesSharedOnly();
        _refuseStrangerInvite(preview.kind, preview.binding);
        return (link: link, preview: preview);
      } on ApiException catch (err) {
        if (err.statusCode == 404) {
          throw UserFacingException(l10n.joinLinkUnusable);
        }
        rethrow;
      }
    });
  }

  /// Asks to join through [link]. Nothing is granted until an owner or admin
  /// approves.
  Future<JoinRequest?> requestToJoin(MembershipInviteLink link) {
    return _membershipCall<JoinRequest>((current, client) async {
      try {
        // Persist the verified anchor before the server can approve and
        // deliver a Welcome, including when the request response is lost: the
        // group a Welcome must come from (the group, or the community's shared
        // group, v3) with the inviter's key, and for a community the group the
        // server must name as its shared group from now on.
        final preview = await client.previewMembershipInvite(
          current.token,
          link.locator,
        );
        if (!await _inviteBindingHolds(link, preview.binding, preview.kind)) {
          throw UserFacingException(l10n.joinLinkUnusable);
        }
        await loadCommunityInvitesSharedOnly();
        _refuseStrangerInvite(preview.kind, preview.binding);
        final verified = preview.binding;
        await localStore.saveInviteAnchor(
          InviteAnchor(
            conversationId: verified.anchorGroupId,
            accountId: verified.inviterAccountId,
            deviceId: verified.inviterDeviceId,
            signingKey: verified.inviterSigningKey,
          ),
        );
        if (preview.kind == InviteTargetKind.community) {
          await localStore.saveCommunityInviteAnchor(
            verified.targetId,
            verified.anchorGroupId,
          );
        }
        final request = await client.requestToJoin(current.token, link.locator);
        // The answer must carry the binding of this very link, for the target
        // and group the preview showed; otherwise the server filed the
        // request against something else (a swap between the preview and the
        // request). Withdraw it, best effort.
        final binding = request.binding;
        if (binding == null ||
            binding.targetId != verified.targetId ||
            binding.anchorGroupId != verified.anchorGroupId ||
            !await _inviteBindingHolds(link, binding, request.kind)) {
          try {
            await client.cancelJoinRequest(current.token, request.id);
          } on Object {
            // The request stays pending on a server that lies; an admin sees
            // it as filed through a link that was never theirs to approve.
          }
          throw UserFacingException(l10n.joinLinkUnusable);
        }
        return request;
      } on ApiException catch (err) {
        if (err.statusCode == 404) {
          throw UserFacingException(l10n.joinLinkUnusable);
        }
        if (err.serverCode == 'already_member') {
          throw UserFacingException(l10n.joinAlreadyMember);
        }
        rethrow;
      }
    });
  }

  /// The account's own recent requests. A community that approved one is
  /// listed again, so it appears without a restart.
  Future<List<JoinRequest>?> loadOwnJoinRequests() async {
    final requests = await _membershipCall<List<JoinRequest>>(
      (current, client) => client.listOwnJoinRequests(current.token),
    );
    if (requests != null) {
      final known = <String>{for (final c in communities) c.id};
      final approvedNewCommunity = requests.any(
        (r) =>
            r.status == JoinRequestStatus.approved &&
            r.kind == InviteTargetKind.community &&
            r.targetId != null &&
            !known.contains(r.targetId),
      );
      if (approvedNewCommunity) unawaited(refreshCommunities());
    }
    return requests;
  }

  Future<bool> cancelJoinRequest(String requestId) async {
    final done = await _membershipCall<bool>((current, client) async {
      await client.cancelJoinRequest(current.token, requestId);
      return true;
    });
    return done ?? false;
  }

  /// Pending requests for a group or community, for its owners and admins.
  Future<List<JoinRequest>?> loadJoinRequests(
    InviteTargetKind kind,
    String targetId,
  ) {
    return _membershipCall<List<JoinRequest>>(
      (current, client) =>
          client.listJoinRequests(current.token, kind, targetId),
    );
  }

  /// The conversations an approval adds the requester to: the group itself,
  /// or every channel conversation of the community this device knows.
  List<String> _joinTargetConversations(JoinRequest request) {
    final targetId = request.targetId;
    if (targetId == null) return const <String>[];
    if (request.kind == InviteTargetKind.group) return <String>[targetId];
    return <String>[
      for (final c in conversations)
        if (c.isChannel && c.communityId == targetId) c.id,
    ];
  }

  /// Approves or declines [request]. Approving records membership on the
  /// server and asks reconcile to add the new member's devices to the MLS
  /// group, which another step completes: until then the member is approved
  /// but has no encrypted access. Refused beforehand where no group device
  /// here could add them (K0 step 8).
  Future<bool> decideJoinRequest(
    JoinRequest request, {
    required bool approve,
  }) async {
    final done = await _membershipCall<bool>((current, client) async {
      final conversationIds =
          approve ? _joinTargetConversations(request) : const <String>[];
      if (approve) {
        if (!membershipChangesAvailable) {
          throw StateError('adding members is not available in this build');
        }
        for (final id in conversationIds) {
          final refusal = await _noPeerRefusal(id);
          if (refusal != null) throw UserFacingException(refusal);
        }
      }
      await client.decideJoinRequest(
        current.token,
        request.id,
        approve: approve,
      );
      if (approve) {
        for (final id in conversationIds) {
          _mlsReconcileRequested = true;
          _mlsReconcileNow.add(id);
          _mlsChangeRetries.remove(id);
        }
        unawaited(_catchUpSyncEvents());
      }
      return true;
    });
    return done ?? false;
  }

  Future<List<ConversationMember>?> loadCommunityMembers(String communityId) {
    return _membershipCall<List<ConversationMember>>(
      (current, client) => client.communityMembers(current.token, communityId),
    );
  }

  /// Removes another member from a community and from all its channels at
  /// once. Their devices leave each channel's MLS group through reconcile;
  /// until a removal commit is applied here, sends to those channels wait
  /// (D68).
  Future<bool> removeCommunityMember(
    String communityId,
    String accountId,
  ) async {
    final done = await _membershipCall<bool>((current, client) async {
      if (!membershipChangesAvailable) {
        throw StateError('removing members is not available in this build');
      }
      final removal = await client.removeCommunityMember(
        current.token,
        communityId,
        accountId,
      );
      for (final channel in removal.channels) {
        await _afterMemberRemoved(channel.conversationId, accountId);
        final members = membersByConversation[channel.conversationId];
        if (members != null) {
          membersByConversation = <String, List<ConversationMember>>{
            ...membersByConversation,
            channel.conversationId: members
                .where((member) => member.accountId != accountId)
                .toList(growable: false),
          };
        }
      }
      return true;
    });
    return done ?? false;
  }

  /// Drops the removed account from each channel's local roster and reconciles
  /// its MLS group, as [removeCommunityMember] does.
  Future<void> _afterCommunityRemoval(
    CommunityRemoval removal,
    String accountId,
  ) async {
    for (final channel in removal.channels) {
      await _afterMemberRemoved(channel.conversationId, accountId);
      final members = membersByConversation[channel.conversationId];
      if (members != null) {
        membersByConversation = <String, List<ConversationMember>>{
          ...membersByConversation,
          channel.conversationId: members
              .where((member) => member.accountId != accountId)
              .toList(growable: false),
        };
      }
    }
  }

  /// Kicks a member (C5): removes them from the community and its channels;
  /// they may be added or invited again.
  Future<bool> kickCommunityMember(String communityId, String accountId) async {
    final done = await _membershipCall<bool>((current, client) async {
      final removal = await client.kickCommunityMember(
        current.token,
        communityId,
        accountId,
      );
      await _afterCommunityRemoval(removal, accountId);
      return true;
    });
    return done ?? false;
  }

  /// Bans an account (C5): removes it if it is a member, and refuses its
  /// return until the ban is lifted. The community's verified record gets
  /// the ban too (record format 3): this device's removal commit carries it,
  /// or a later sync pass writes it ([RecordFormat3Actions]), so every
  /// member's app refuses to add the account back, whatever the server
  /// later says.
  Future<bool> banCommunityMember(String communityId, String accountId) async {
    final done = await _membershipCall<bool>((current, client) async {
      final removal = await client.banCommunityMember(
        current.token,
        communityId,
        accountId,
      );
      // Before the removal is reconciled, so its commit can carry the ban.
      await _oweBanRecord(communityId, accountId);
      await _afterCommunityRemoval(removal, accountId);
      return true;
    });
    return done ?? false;
  }

  /// Lifts a ban: the record's first (admins and above), then the
  /// server's. It does not add the account back. A ban only the record
  /// holds (the server's was lifted by a build older than this) is lifted
  /// there alone.
  Future<bool> unbanCommunityMember(
    String communityId,
    String accountId,
  ) async {
    if (!await _liftRecordBan(communityId, accountId)) return false;
    final done = await _membershipCall<bool>((current, client) async {
      try {
        await client.unbanCommunityMember(
          current.token,
          communityId,
          accountId,
        );
      } on ApiException catch (err) {
        // Nothing to lift on the server: the record held it alone.
        if (err.statusCode != 404) rethrow;
      }
      return true;
    });
    return done ?? false;
  }

  /// Mutes a member for [seconds] (0 lifts it).
  ///
  /// C5: the community's verified record carries the timeout too, so every
  /// member's app hides the member's posts as the server refuses them
  /// (docs/crypto.md, "C5 timeouts in the record"). A timeout is set on the
  /// server first and then recorded with the server's own times; a lift
  /// leaves the record first and only then the server. Either way a failure
  /// leaves apps no stricter than the server.
  Future<bool> timeoutCommunityMember(
    String communityId,
    String accountId,
    int seconds,
  ) async {
    final shared = communities
        .where((c) => c.id == communityId)
        .firstOrNull
        ?.sharedConversationId;
    if (seconds == 0 && shared != null) {
      final view = await governanceViewFor(shared);
      if (view != null && view.record.timeouts.containsKey(accountId)) {
        final lifted = await _roleCommand(
          shared,
          (commands, _, __) => commands.liftTimeout(accountId),
        );
        if (!lifted) return false;
      }
    }
    DateTime? until;
    final done = await _membershipCall<bool>((current, client) async {
      until = await client.setMemberTimeout(
        current.token,
        communityId,
        accountId,
        seconds,
      );
      return true;
    });
    final end = until;
    if (done == true && seconds > 0 && end != null && shared != null) {
      final view = await governanceViewFor(shared);
      if (view != null) {
        final untilMs = end.millisecondsSinceEpoch;
        await _roleCommand(
          shared,
          (commands, _, __) => commands.setTimeout(
            accountId,
            fromMs: untilMs - seconds * 1000,
            untilMs: untilMs,
          ),
        );
      }
    }
    return done ?? false;
  }

  Future<bool> setChannelSlowMode(
    String communityId,
    String channelId,
    int seconds,
  ) async {
    final done = await _membershipCall<bool>((current, client) async {
      await client.setChannelSlowMode(
        current.token,
        communityId,
        channelId,
        seconds,
      );
      return true;
    });
    return done ?? false;
  }

  Future<bool> setInvitesPaused(String communityId, int seconds) async {
    final done = await _membershipCall<bool>((current, client) async {
      await client.setInvitesPaused(current.token, communityId, seconds);
      return true;
    });
    return done ?? false;
  }

  Future<List<CommunityBan>?> loadCommunityBans(String communityId) =>
      _membershipCall<List<CommunityBan>>(
        (current, client) => client.communityBans(current.token, communityId),
      );

  /// Every running timeout of the community the server remembers (C5),
  /// for admins and above: of accounts that left (`member` false; lifted
  /// with [timeoutCommunityMember] and 0, owner decision 2026-11-21) and of
  /// current members (`member` true).
  Future<List<CommunityTimeout>?> loadCommunityTimeouts(String communityId) =>
      _membershipCall<List<CommunityTimeout>>(
        (current, client) =>
            client.communityTimeouts(current.token, communityId),
      );

  /// C5 rejoin gap: the members among [timeouts] whose running server
  /// timeout this device may write into the shared group's record now
  /// ([mayApplyServerTimeout]: the record lacks it, they are in the MLS
  /// roster, the record lets this account act on them, and the end is far
  /// enough ahead). Empty without a record.
  Future<Set<String>> serverTimeoutsToApply(
    String communityId,
    List<CommunityTimeout> timeouts,
  ) async {
    final self = session?.accountId;
    final shared = communities
        .where((c) => c.id == communityId)
        .firstOrNull
        ?.sharedConversationId;
    final members = timeouts.where((t) => t.member).toList();
    if (self == null || shared == null || members.isEmpty) return const {};
    final view = await governanceViewFor(shared);
    if (view == null) return const {};
    final now = DateTime.now();
    return <String>{
      for (final t in members)
        if (mayApplyServerTimeout(
          record: view.record,
          roster: view.roster,
          actor: self,
          account: t.accountId,
          serverUntil: t.timeoutUntil,
          now: now,
        ))
          t.accountId,
    };
  }

  /// C5 rejoin gap: writes a member's running server timeout, ending at
  /// [until], into the shared group's record, starting now
  /// ([applyServerTimeout], checked again against the record when staged).
  /// Only ever an admin's explicit action: no device does it on its own, so
  /// admins' devices do not race. The server already holds the timeout and
  /// is not called. False (with the error under [Ops.members]) when refused.
  Future<bool> applyServerTimeoutToRecord(
    String communityId,
    String accountId,
    DateTime until,
  ) async {
    final shared = communities
        .where((c) => c.id == communityId)
        .firstOrNull
        ?.sharedConversationId;
    if (shared == null) return false;
    return _roleCommand(
      shared,
      (commands, _, now) => applyServerTimeout(
        commands,
        accountId,
        serverUntil: until,
        now: now,
      ),
    );
  }

  Future<ModerationState?> loadModerationState(String communityId) =>
      _membershipCall<ModerationState>(
        (current, client) => client.moderationState(current.token, communityId),
      );

  Future<List<ModerationEvent>?> loadModerationEvents(String communityId) =>
      _membershipCall<List<ModerationEvent>>(
        (current, client) =>
            client.moderationEvents(current.token, communityId),
      );

  /// Leaves a community and every channel in it, and drops their local
  /// state the way leaving a group does. The last owner cannot leave.
  Future<bool> leaveCommunity(String communityId) async {
    final shared = communities
        .where((community) => community.id == communityId)
        .firstOrNull
        ?.sharedConversationId;
    if (shared == null) return _leaveCommunity(communityId, null);
    _leavingRecordGroups.add(shared);
    try {
      return await _leaveCommunity(communityId, shared);
    } finally {
      _leavingRecordGroups.remove(shared);
      // A leave that did not go through voids its signed statement.
      _voidCancelledLeavesSoon();
    }
  }

  Future<bool> _leaveCommunity(String communityId, String? shared) async {
    // C4: the shared group's record decides first (outside the op: it
    // sends): the owner transfers before leaving, a governing member sends
    // its leave proof.
    final owner = session;
    if (owner != null && shared != null) {
      try {
        await _beforeLeavingRecordGroup(owner, shared);
      } on UserFacingException catch (err) {
        _opErrors[Ops.membership] = err.message;
        notifyListeners();
        return false;
      }
    }
    final done = await _membershipCall<bool>((current, client) async {
      final removal = await client.removeCommunityMember(
        current.token,
        communityId,
        'me',
      );
      for (final channel in removal.channels) {
        await _dropLeftConversationLocally(
          current,
          channel.conversationId,
          channel.eventId,
        );
      }
      if (shared != null) await _leaveWentThrough(shared);
      communities = communities
          .where((community) => community.id != communityId)
          .toList(growable: false);
      channelsByCommunity = <String, List<Channel>>{
        for (final entry in channelsByCommunity.entries)
          if (entry.key != communityId) entry.key: entry.value,
      };
      return true;
    });
    return done ?? false;
  }
}
