part of 'app_state.dart';

/// C4: built-in roles kept in each group's signed role record and checked by
/// every app (docs/designs/C4-custom-roles.md, docs/crypto.md "C4 app
/// wiring"). A group or community without a record (one made before C4, a
/// DM) keeps the server's roles as hints only.
///
/// Every change here is an MLS commit built by [GovernanceCommands]; the
/// server's role row is then updated too, so the server's own checks (which
/// the server enforces for its routes) follow the record. The record wins in
/// every app whatever the server says.
extension RoleActions on AppState {
  /// The MLS group whose record governs [conversationId]: the group itself,
  /// or a community channel's shared group.
  String? recordGroupFor(String conversationId) {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conversation == null) return null;
    if (conversation.isGroup || conversation.isCommunityShared) {
      return conversationId;
    }
    if (conversation.kind == 'community_channel' &&
        conversation.communityId != null) {
      return communities
          .where((c) => c.id == conversation.communityId)
          .firstOrNull
          ?.sharedConversationId;
    }
    return null;
  }

  /// C5: whether this account may delete [sender]'s messages in
  /// [conversationId] for everyone: the verified record makes it a
  /// moderator or above that outranks [sender]. Without a record, no.
  bool mayModerateMessage(String conversationId, String? sender) {
    final self = session?.accountId;
    if (self == null || sender == null || sender == self) return false;
    final record = governanceOf(conversationId);
    return record != null && record.mayActOn(self, sender);
  }

  RoleCommandCryptoService? get _roleCrypto {
    final Object? mls = _mlsCrypto;
    return mls is RoleCommandCryptoService ? mls : null;
  }

  /// The verified record, roster and clocks for [conversationId], or null.
  Future<GovernanceView?> governanceViewFor(String conversationId) async {
    final group = recordGroupFor(conversationId);
    final crypto = _roleCrypto;
    if (group == null || crypto == null) return null;
    try {
      return await crypto.governanceView(group);
    } catch (_) {
      return null;
    }
  }

  /// Stages one role command in the record group of [conversationId] and
  /// sends it. False (with the error under [Ops.members]) when refused.
  Future<bool> _roleCommand(
    String conversationId,
    GovernanceState Function(
      GovernanceCommands commands,
      GovernanceObservations? observed,
      DateTime now,
    ) build, {
    Future<void> Function(Session current, ApiClient client)? server,
  }) async {
    final group = recordGroupFor(conversationId);
    final crypto = _roleCrypto;
    if (group == null || crypto == null) return false;
    return _runScoped(Ops.members, () async {
      final current = session;
      final client = api;
      if (current == null || client == null) return;
      try {
        await crypto.stageRoleChange(group, build);
      } on GovernanceCommandException catch (err) {
        throw UserFacingException(_roleRefusal(err.reason));
      }
      await _flushMlsOutbox();
      // The server's row follows; its refusal leaves the record as it is.
      if (server != null) await server(current, client);
      notifyListeners();
    });
  }

  static String _roleRefusal(String reason) => switch (reason) {
        'owner_active' => 'The owner was active in the last 30 days.',
        'election_wait' =>
          'Votes open 7 days after the election started on this device.',
        'stale_owner_observation' ||
        'missing_election_observation' =>
          'This device has not watched this group long enough to vote yet.',
        'not_elector' => 'Only the electing admins can do this.',
        'already_voted' => 'You have already voted.',
        'transfer_first' => 'The owner must transfer ownership first.',
        'commit_pending' => 'Another change is still being sent. Try again.',
        'hierarchy' ||
        'notAllowed' ||
        'not_owner' =>
          'Your role does not allow this.',
        _ => 'This role change is not allowed.',
      };

  /// The server's role row for [accountId] in [conversationId]'s record
  /// group: a group's own member route, or for a community's shared group the
  /// community's member route (the shared conversation's roster is the
  /// community's, and the server refuses role changes on it).
  Future<void> _serverRole(
    Session current,
    ApiClient client,
    String conversationId,
    String accountId,
    String role,
  ) {
    final group = recordGroupFor(conversationId)!;
    final conversation = conversations.where((c) => c.id == group).firstOrNull;
    final communityId = conversation?.communityId ??
        communities
            .where((c) => c.sharedConversationId == group)
            .firstOrNull
            ?.id;
    if (conversation != null &&
        conversation.isCommunityShared &&
        communityId != null) {
      return client.setCommunityMemberRole(
        current.token,
        communityId,
        accountId,
        role,
      );
    }
    return client.addConversationMember(
      current.token,
      group,
      accountId,
      role: role,
    );
  }

  /// Gives [accountId] [role] (never owner: see [transferOwnership]).
  Future<bool> setVerifiedRole(
    String conversationId,
    String accountId,
    BuiltInRole role,
  ) =>
      _roleCommand(
        conversationId,
        (commands, _, __) => commands.setRole(accountId, role),
        server: (current, client) =>
            _serverRole(current, client, conversationId, accountId, role.name),
      );

  /// Marks an admin as one the owner chose (an elector, D81), or not.
  Future<bool> setElector(
    String conversationId,
    String accountId,
    bool enabled,
  ) =>
      _roleCommand(
        conversationId,
        (commands, _, __) => commands.setElector(accountId, enabled),
      );

  /// The owner hands the group to a current admin and becomes an admin.
  Future<bool> transferOwnership(String conversationId, String adminId) =>
      _roleCommand(
        conversationId,
        (commands, _, __) => commands.transfer(adminId),
        server: (current, client) =>
            _serverRole(current, client, conversationId, adminId, 'owner'),
      );

  /// Opens an owner election (D81) after 30 days without the owner here.
  Future<bool> openOwnerElection(String conversationId) =>
      _roleCommand(conversationId, (commands, observed, now) {
        if (observed == null) {
          throw const GovernanceCommandException('stale_owner_observation');
        }
        return commands.openElection(observed, now);
      });

  /// Votes for [candidate]; the deciding vote makes them owner. The server's
  /// owner row then follows through [reconcileServerOwners].
  Future<bool> voteForOwner(String conversationId, String candidate) {
    String? heir;
    return _roleCommand(
      conversationId,
      (commands, observed, now) {
        if (observed == null) {
          throw const GovernanceCommandException(
            'missing_election_observation',
          );
        }
        final next = commands.vote(candidate, observed, now);
        if (next.owner case final owner? when owner != commands.state.owner) {
          heir = governanceSuccessionValue(next.rev, owner);
        }
        return next;
      },
      // The deciding vote: the next sync pass, once this commit is merged,
      // asks the server too.
      server: (current, client) async {
        final group = recordGroupFor(conversationId);
        if (heir == null || group == null) return;
        await localStore.saveSetting(governanceSuccessionSetting(group), heir!);
      },
    );
  }

  /// How often a record owner whose server row still names someone else
  /// asks again (the server may still be waiting for the owner's quiet time
  /// or for other admins).
  static const Duration successionRetry = Duration(hours: 6);

  /// C4 server succession (docs/designs/C4-custom-roles.md, "Server
  /// succession"): the server's owner row follows the verified record. Each
  /// sync pass, for every record group this device belongs to:
  ///
  /// - a won election or claim it saw (saved with that commit) is asked for
  ///   once: as an admin, a vote for the move; as the server's owner, the
  ///   transfer itself;
  /// - while the record names this account owner and the server does not,
  ///   it asks for itself every [successionRetry].
  ///
  /// The server decides by its own rule; a refusal is final for that ask and
  /// never changes the record or the roles apps use.
  Future<void> reconcileServerOwners() async {
    final current = session;
    final client = api;
    final crypto = _roleCrypto;
    final self = current?.accountId;
    if (current == null || client == null || crypto == null || self == null) {
      return;
    }
    for (final conversation in List<Conversation>.of(conversations)) {
      if (!(conversation.isGroup || conversation.isCommunityShared)) continue;
      final id = conversation.id;
      final setting = governanceSuccessionSetting(id);
      final saved = await localStore.loadSetting(setting);
      final parsed = parseGovernanceSuccessionValue(saved);
      final GovernanceView? view;
      try {
        view = await crypto.governanceView(id);
      } catch (_) {
        continue;
      }
      final owner = view?.record.owner;
      if (view == null || owner == null) continue;
      // Not merged here yet (this device's own deciding vote): wait.
      if (parsed != null && view.record.rev < parsed.rev) continue;
      final pending = parsed != null && parsed.owner == owner ? owner : null;
      if (saved != null && saved.isNotEmpty && pending == null) {
        // Malformed, or a later commit moved ownership again: stale.
        await localStore.saveSetting(setting, '');
      }
      String? candidate = pending;
      if (candidate == null &&
          owner == self &&
          conversation.currentRole != 'owner') {
        final last = _successionAskedAt[id];
        final now = DateTime.now();
        if (last == null || now.difference(last) >= successionRetry) {
          _successionAskedAt[id] = now;
          candidate = self;
        }
      }
      if (candidate == null) continue;
      final communityId = conversation.isCommunityShared
          ? (conversation.communityId ??
              communities
                  .where((c) => c.sharedConversationId == id)
                  .firstOrNull
                  ?.id)
          : null;
      if (conversation.isCommunityShared && communityId == null) continue;
      try {
        await client.requestOwnerSuccession(
          current.token,
          conversationId: communityId == null ? id : null,
          communityId: communityId,
          candidateAccountId: candidate,
        );
      } on ApiException catch (err) {
        if (err.statusCode == 401) rethrow;
        // A refusal is final for this ask; anything else is retried.
        if (err.statusCode != 403 && err.statusCode != 404) continue;
      } catch (_) {
        continue;
      }
      if (pending != null) await localStore.saveSetting(setting, '');
    }
  }

  /// The owner's cancel, or a snapshot member's close.
  Future<bool> closeOwnerElection(String conversationId) => _roleCommand(
        conversationId,
        (commands, _, __) => commands.closeElection(),
      );

  /// C2 in the record: "only admins post" for a group.
  Future<void> _recordPosting(String conversationId, bool adminsOnly) async {
    final view = await governanceViewFor(conversationId);
    if (view == null || view.record.adminsOnlyPosting == adminsOnly) return;
    await _roleCommand(
      conversationId,
      (commands, _, __) => commands.setPosting(
        adminsOnly: adminsOnly,
        announcementChannels: commands.state.announcementChannels,
      ),
    );
  }

  /// C2 in the record: an announcement channel of a community.
  Future<void> _recordAnnouncementChannel(
    String sharedConversationId,
    String channelId,
  ) async {
    final view = await governanceViewFor(sharedConversationId);
    if (view == null || view.record.announcementChannels.contains(channelId)) {
      return;
    }
    await _roleCommand(
      sharedConversationId,
      (commands, _, __) => commands.setPosting(
        adminsOnly: commands.state.adminsOnlyPosting,
        announcementChannels: {
          ...commands.state.announcementChannels,
          channelId,
        },
      ),
    );
  }

  /// Before this account leaves [conversationId]'s record group: the owner
  /// must transfer first (D81), and a governing member sends its own leave
  /// proof and waits until the server holds it, so the removal commit that
  /// follows is accepted by every member.
  Future<void> _beforeLeavingRecordGroup(
    Session current,
    String conversationId,
  ) async {
    final group = recordGroupFor(conversationId) ?? conversationId;
    final crypto = _roleCrypto;
    if (crypto == null) return;
    final GovernanceView? view;
    try {
      view = await crypto.governanceView(group);
    } catch (_) {
      return;
    }
    if (view == null) return;
    final self = current.accountId;
    if (self == null) return;
    if (!view.record.mayLeave(self)) {
      throw const UserFacingException(
        'Transfer ownership to an admin before you leave.',
      );
    }
    if (!removalNeedsProof(view.record, self)) return;
    String? channelId;
    final conversation = conversations.where((c) => c.id == group).firstOrNull;
    if (conversation != null && conversation.isCommunityShared) {
      channelId = _selectedChannels[group] ??
          channelsByCommunity[conversation.communityId]
              ?.where((channel) => channel.conversationId == group)
              .firstOrNull
              ?.id;
      if (channelId == null) {
        throw const UserFacingException(
          'Could not tell the community you are leaving. Try again.',
        );
      }
    }
    final sent = await _sendPayload(
      group,
      AppPayloadType.memberLeave,
      const <String, Object?>{},
      channelId: channelId,
    );
    if (!sent) {
      throw const UserFacingException(
        'Could not tell the group you are leaving. Try again.',
      );
    }
    await _flushOutbox();
    final waiting = (await localStore.pendingEnvelopeRecords()).any(
      (record) => record.envelope.conversationId == group,
    );
    if (waiting) {
      throw const UserFacingException(
        'Could not tell the group you are leaving. Try again.',
      );
    }
  }

  /// D81: the owner's app cancels an election by itself, after a random
  /// delay of up to 24 hours (so the cancel tells the server less about when
  /// the owner is online). Looked at on every sync pass.
  Future<void> _scheduleOwnerCancels() async {
    final current = session;
    final crypto = _roleCrypto;
    final self = current?.accountId;
    if (current == null || crypto == null || self == null) return;
    for (final conversation in conversations) {
      if (!(conversation.isGroup || conversation.isCommunityShared)) continue;
      final id = conversation.id;
      if (_ownerCancelTimers.containsKey(id)) continue;
      final GovernanceView? view;
      try {
        view = await crypto.governanceView(id);
      } catch (_) {
        continue;
      }
      if (view == null ||
          view.record.owner != self ||
          view.record.election == null) {
        continue;
      }
      final delay = Duration(
        seconds: _ownerCancelRandom.nextInt(
          const Duration(hours: 24).inSeconds,
        ),
      );
      final generation = _sessionGeneration;
      _ownerCancelTimers[id] = Timer(delay, () {
        _ownerCancelTimers.remove(id);
        if (_disposed || generation != _sessionGeneration) return;
        unawaited(() async {
          final latest = await governanceViewFor(id);
          if (latest == null ||
              latest.record.owner != self ||
              latest.record.election == null) {
            return;
          }
          await closeOwnerElection(id);
        }());
      });
    }
  }

  void _cancelOwnerCancelTimers() {
    for (final timer in _ownerCancelTimers.values) {
      timer.cancel();
    }
    _ownerCancelTimers.clear();
    _successionAskedAt.clear();
  }
}
