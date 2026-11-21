part of 'app_state.dart';

/// C4 record format 3 (docs/crypto.md, "C4 record format 3"): the settings
/// and bans other packages waited for, kept in the group's verified record
/// and enforced by every member's app.
///
/// - C3: admins restrict channel names and topics to moderators and above.
/// - W8: admins make pinning admin-only.
/// - C5: a ban the server holds is also in the community's record, so every
///   member's app refuses to add the account back and hides its posts where
///   a private channel still holds it.
///
/// The server keeps enforcing what it can see. The record is written after
/// the server for a ban (the removal commit carries it) and before the
/// server for a lift, so apps are never looser than the server's word.
extension RecordFormat3Actions on AppState {
  /// The shared group of [communityId], or null (a legacy community).
  String? _sharedGroupOf(String communityId) => communities
      .where((c) => c.id == communityId)
      .firstOrNull
      ?.sharedConversationId;

  /// C3: channel names and topics edited only by moderators and above, or
  /// by anyone ([restricted] false). Admins and above.
  Future<bool> setChannelInfoRestricted(
    String conversationId,
    bool restricted,
  ) =>
      _roleCommand(
        conversationId,
        (commands, _, __) => commands.setChannelInfoRestricted(restricted),
      );

  /// W8: only owners and admins pin and unpin ([adminsOnly]), or the
  /// default. Admins and above.
  Future<bool> setAdminsOnlyPins(String conversationId, bool adminsOnly) =>
      _roleCommand(
        conversationId,
        (commands, _, __) => commands.setAdminsOnlyPins(adminsOnly),
      );

  /// C5: whether [communityId]'s verified record bans [accountId]; null
  /// when there is no record (a legacy community, a group made before C4).
  bool? recordBans(String communityId, String accountId) {
    final shared = _sharedGroupOf(communityId);
    if (shared == null) return null;
    return governanceOf(shared)?.bans.contains(accountId);
  }

  /// C5: the accounts [communityId]'s verified record bans.
  Set<String> recordBansOf(String communityId) {
    final shared = _sharedGroupOf(communityId);
    if (shared == null) return const <String>{};
    return governanceOf(shared)?.bans ?? const <String>{};
  }

  /// C5: whether this account may write or lift a ban in [communityId]'s
  /// record (admins and above by the record, as the server's unban).
  bool mayManageRecordBans(String communityId) {
    final shared = _sharedGroupOf(communityId);
    final self = session?.accountId;
    if (shared == null || self == null) return false;
    final record = governanceOf(shared);
    return record != null && record.rankOf(self) >= BuiltInRole.admin.rank;
  }

  /// C5: writes a ban the server already holds into the record (a ban made
  /// before this build, or one a moderator's removal commit could not
  /// carry). Admins and above, for an account out of the group.
  Future<bool> applyBanToRecord(String communityId, String accountId) async {
    final shared = _sharedGroupOf(communityId);
    if (shared == null) return false;
    final ok = await _roleCommand(
      shared,
      (commands, _, __) => commands.ban(accountId),
    );
    if (ok) await _forgetOwedBan(shared, accountId);
    _copyRoleError(ok);
    return ok;
  }

  /// The role command's error, shown where the moderation screens look.
  void _copyRoleError(bool ok) {
    if (ok) return;
    final error = errorFor(Ops.members);
    if (error != null) {
      _opErrors[Ops.membership] = error;
      notifyListeners();
    }
  }

  /// C5: remembers that this device banned [accountId] in [communityId], so
  /// its removal commit carries the ban (or a later pass writes it).
  Future<void> _oweBanRecord(String communityId, String accountId) async {
    final shared = _sharedGroupOf(communityId);
    if (shared == null || governanceOf(shared) == null) return;
    final key = banRecordOwedSetting(shared);
    final now = DateTime.now();
    final owed = decodeOwedBans(await localStore.loadSetting(key), now)
      ..[accountId] = now.add(banRecordOwedLifetime).millisecondsSinceEpoch;
    await localStore.saveSetting(key, encodeOwedBans(owed));
  }

  Future<void> _forgetOwedBan(String groupId, String accountId) async {
    final key = banRecordOwedSetting(groupId);
    final stored = await localStore.loadSetting(key);
    if (stored == null || stored.isEmpty) return;
    final owed = decodeOwedBans(stored, DateTime.now());
    if (owed.remove(accountId) == null) return;
    await localStore.saveSetting(key, encodeOwedBans(owed));
  }

  /// C5: lifts the record's ban of [accountId] before the server's, so the
  /// record never refuses an add the server allows for longer than it takes
  /// to commit. False (error under the membership op) when it could not.
  Future<bool> _liftRecordBan(String communityId, String accountId) async {
    final shared = _sharedGroupOf(communityId);
    if (shared == null) return true;
    await _forgetOwedBan(shared, accountId);
    if (governanceOf(shared)?.bans.contains(accountId) != true) return true;
    final ok = await _roleCommand(
      shared,
      (commands, _, __) => commands.liftBan(accountId),
    );
    _copyRoleError(ok);
    return ok;
  }

  /// One sync pass: bans this device still owes a record. An entry goes
  /// once the record holds the ban; an admin writes the bans of accounts
  /// already out of the group in one role-only commit; an entry whose
  /// account is out of the group but that this device cannot write (a
  /// moderator whose removal someone else committed) goes too, and an admin
  /// applies it from the Moderation screen. An account still in the group
  /// waits for its removal commit, at most [banRecordOwedLifetime].
  Future<void> _retryBanRecords() async {
    final crypto = _roleCrypto;
    final self = session?.accountId;
    if (crypto == null || self == null) return;
    for (final community in List<Community>.of(communities)) {
      final shared = community.sharedConversationId;
      if (shared == null) continue;
      final key = banRecordOwedSetting(shared);
      final stored = await localStore.loadSetting(key);
      if (stored == null || stored.isEmpty) continue;
      final owed = decodeOwedBans(stored, DateTime.now());
      final GovernanceView? view;
      try {
        view = await crypto.governanceView(shared);
      } catch (_) {
        continue;
      }
      if (view == null) {
        await localStore.saveSetting(key, '');
        continue;
      }
      final record = view.record;
      owed.removeWhere((account, _) => record.bans.contains(account));
      final gone = {
        for (final account in owed.keys)
          if (!view.roster.contains(account)) account,
      };
      if (gone.isNotEmpty && record.rankOf(self) >= BuiltInRole.admin.rank) {
        try {
          await crypto.stageRoleChange(
            shared,
            (commands, _, __) => commands.banAll(gone),
          );
          await _flushMlsOutbox();
          owed.removeWhere((account, _) => gone.contains(account));
        } catch (err) {
          // Kept for the next pass (a pending commit, no network).
          developer.log(
            'c5_ban_record_retry_failed ${err.runtimeType}',
            name: 'veritra.sync',
          );
        }
      } else {
        owed.removeWhere((account, _) => gone.contains(account));
      }
      await localStore.saveSetting(key, encodeOwedBans(owed));
    }
  }
}

/// Test access to one retry pass ([RecordFormat3Actions]).
extension RecordFormat3Testing on AppState {
  @visibleForTesting
  Future<void> retryBanRecordsForTesting() => _retryBanRecords();
}
