part of 'app_state.dart';

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
  /// The invitation is bound (D90) to the target, this account and device, and
  /// the device's signing key by a tag derived from the secret, so the joiner
  /// can tell that the target was not swapped on the way. The key comes from
  /// the native engine; without it (any build that is not the reviewed
  /// engine) no invitation is made.
  Future<String?> createInviteLink(InviteTargetKind kind, String targetId) {
    return _membershipCall<String>((current, client) async {
      // Only the native engine reads the device key; the unavailable
      // service does not implement this, so it is refused (D90).
      final DeviceSigningKeyCryptoService keys;
      if (cryptoService case final DeviceSigningKeyCryptoService engine) {
        keys = engine;
      } else {
        throw UserFacingException(l10n.errorActionUnavailable);
      }
      final accountId = current.accountId;
      final deviceId = current.deviceId;
      if (accountId == null || deviceId == null) {
        throw UserFacingException(l10n.errorActionUnavailable);
      }
      final signingKey = await keys.deviceSigningPublicKey(
        accountId: accountId,
        deviceId: deviceId,
      );
      final link = MembershipInviteLink.generate(origin: client.baseUrl);
      await client.createMembershipInvite(
        current.token,
        kind,
        targetId,
        locator: link.locator,
        signingKey: signingKey,
        bindingTag: link.bindingTag(
          kind: kind,
          targetId: targetId,
          inviterAccountId: accountId,
          inviterDeviceId: deviceId,
          inviterSigningKey: signingKey,
        ),
      );
      return link.url;
    });
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
        // made the link bound it to. A swapped target fails here, before the
        // person sees it or any request is filed.
        if (preview.binding.kind != preview.kind ||
            !link.verifies(preview.binding)) {
          throw UserFacingException(l10n.joinLinkUnusable);
        }
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
        final request = await client.requestToJoin(current.token, link.locator);
        // The answer must carry the binding of this very link; otherwise the
        // server filed the request against something else (a swap between
        // the preview and the request). Withdraw it, best effort.
        final binding = request.binding;
        if (binding == null ||
            binding.kind != request.kind ||
            !link.verifies(binding)) {
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
      final approvedNewCommunity = requests.any((r) =>
          r.status == JoinRequestStatus.approved &&
          r.kind == InviteTargetKind.community &&
          r.targetId != null &&
          !known.contains(r.targetId));
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

  /// Leaves a community and every channel in it, and drops their local
  /// state the way leaving a group does. The last owner cannot leave.
  Future<bool> leaveCommunity(String communityId) async {
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
