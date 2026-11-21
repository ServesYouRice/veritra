part of 'app_state.dart';

/// C2 in the record, kept until it lands (docs/designs/C2-admin-only-posting.md).
///
/// Switching a group to "only admins post", or making an announcement
/// channel, asks the server and then commits the C4 record. A record commit
/// that fails (offline, another commit pending) used to be lost: the setting
/// then held only on the server, which could later report posting as open
/// and let members' posts through on every app. This device now remembers
/// what it meant to write and tries again on each sync pass until the
/// record says so. The server's word only ever stops a retry (someone has
/// changed the setting since); it never writes the record.
extension PostingRecordRetry on AppState {
  /// The posting setting (`admins` or `everyone`) this device still has to
  /// write into [conversationId]'s record.
  static String postingSetting(String conversationId) =>
      'c2.posting_record.$conversationId';

  /// The announcement channels (JSON list) this device still has to write
  /// into the record of the shared group [conversationId].
  static String announceSetting(String conversationId) =>
      'c2.announce_record.$conversationId';

  Future<void> _rememberPostingRecord(
    String conversationId,
    bool adminsOnly,
  ) =>
      localStore.saveSetting(
        postingSetting(conversationId),
        adminsOnly ? 'admins' : 'everyone',
      );

  Future<void> _rememberAnnouncementRecord(
    String sharedConversationId,
    String channelId,
  ) async {
    final key = announceSetting(sharedConversationId);
    final pending = _announcementsOwed(await localStore.loadSetting(key))
      ..add(channelId);
    await localStore.saveSetting(key, jsonEncode(pending.toList()..sort()));
  }

  static Set<String> _announcementsOwed(String? stored) {
    if (stored == null || stored.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(stored);
      if (decoded is List) return {...decoded.whereType<String>()};
    } on FormatException {
      // A damaged entry is dropped.
    }
    return <String>{};
  }

  /// One sync pass: every record write this device still owes, tried once.
  /// Failures are kept for the next pass and never surface as an error.
  Future<void> _retryPostingRecords() async {
    final crypto = _roleCrypto;
    final self = session?.accountId;
    if (crypto == null || self == null) return;
    for (final conversation in List<Conversation>.of(conversations)) {
      final id = conversation.id;
      if (conversation.isGroup) {
        final key = postingSetting(id);
        final want = await localStore.loadSetting(key);
        if (want == null || want.isEmpty) continue;
        final adminsOnly = want == 'admins';
        // Changed on the server since (another admin): not ours to undo.
        if (conversation.postingRestricted != adminsOnly) {
          await localStore.saveSetting(key, '');
          continue;
        }
        await _owedRecordWrite(
          crypto,
          id,
          self,
          done: (record) => record.adminsOnlyPosting == adminsOnly,
          build: (commands) => commands.setPosting(
            adminsOnly: adminsOnly,
            announcementChannels: commands.state.announcementChannels,
          ),
          clear: () => localStore.saveSetting(key, ''),
        );
      } else if (conversation.isCommunityShared) {
        final key = announceSetting(id);
        final owed = _announcementsOwed(await localStore.loadSetting(key));
        if (owed.isEmpty) continue;
        // Only channels the server still lists as announcement channels
        // here, judged once this community's channel list has loaded (an
        // unloaded list is no answer, so the entry is kept).
        final community = communities
            .where((item) => item.sharedConversationId == id)
            .firstOrNull;
        final loaded =
            community == null ? null : channelsByCommunity[community.id];
        if (!communitiesLoaded || loaded == null) continue;
        final listed = {
          for (final channel in loaded)
            if (channel.kind == 'announcement' && channel.conversationId == id)
              channel.id,
        };
        final channels = owed.intersection(listed);
        await _owedRecordWrite(
          crypto,
          id,
          self,
          done: (record) => record.announcementChannels.containsAll(channels),
          build: (commands) => commands.setPosting(
            adminsOnly: commands.state.adminsOnlyPosting,
            announcementChannels: {
              ...commands.state.announcementChannels,
              ...channels,
            },
          ),
          clear: () => localStore.saveSetting(key, ''),
        );
      }
    }
  }

  Future<void> _owedRecordWrite(
    RoleCommandCryptoService crypto,
    String groupId,
    String self, {
    required bool Function(GovernanceState record) done,
    required GovernanceState Function(GovernanceCommands commands) build,
    required Future<void> Function() clear,
  }) async {
    final GovernanceView? view;
    try {
      view = await crypto.governanceView(groupId);
    } catch (_) {
      return;
    }
    // No record (a group made before C4) or no longer an admin: nothing
    // this device can write.
    if (view == null ||
        done(view.record) ||
        view.record.rankOf(self) < BuiltInRole.admin.rank) {
      await clear();
      return;
    }
    try {
      await crypto.stageRoleChange(groupId, (commands, _, __) {
        return build(commands);
      });
      await _flushMlsOutbox();
    } catch (err) {
      // Kept for the next pass (a pending commit, no network).
      developer.log(
        'c2_posting_record_retry_failed ${err.runtimeType}',
        name: 'veritra.sync',
      );
    }
  }
}

/// Test access to one retry pass ([PostingRecordRetry]).
extension PostingRecordRetryTesting on AppState {
  @visibleForTesting
  Future<void> retryPostingRecordsForTesting() => _retryPostingRecords();
}
