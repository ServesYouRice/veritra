part of 'app_state.dart';

/// C6 step 4: reports. Builds the [ReportsService] for the signed-in account
/// when this build has the reviewed crypto engine. A build with
/// [UnavailableCryptoService] (every release build today) has no reporting:
/// the gate stays as it is.
extension ReportActions on AppState {
  /// Whether this build can file and open reports.
  bool get reportsAvailable =>
      cryptoService is ReportCryptoService &&
      cryptoService is! UnavailableCryptoService;

  /// Whether the signed-in account is an instance owner (the only account a
  /// report is sent to in this version).
  bool get isInstanceOwner => session?.role == 'owner';

  /// The reports service for the current session, or null when there is no
  /// session or this build cannot report.
  ReportsService? get reportsService {
    final current = session;
    final client = api;
    final accountId = current?.accountId;
    final crypto = cryptoService;
    if (current == null ||
        client == null ||
        accountId == null ||
        !reportsAvailable ||
        crypto is! ReportCryptoService) {
      return null;
    }
    return ReportsService(
      api: client,
      token: current.token,
      accountId: accountId,
      crypto: crypto as ReportCryptoService,
      store: localStore,
      seeds: reportSeedStore,
      moderatorsOf: reportModeratorsFor,
      onSeedChanged: () {
        _reportKeyMemo = null;
        _reportKeyUnlisted.clear();
        unawaited(_announceReportKeys());
      },
    );
  }

  /// C6: who receives a report about [conversationId] in a community: the
  /// owner, admins and moderators of the verified role record (C4) of the
  /// community's shared group. Null outside a community or without a record.
  ReportModerators? reportModeratorsFor(String conversationId) {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conversation == null) return null;
    final communityId = conversation.communityId ??
        communities
            .where((c) => c.sharedConversationId == conversationId)
            .firstOrNull
            ?.id;
    if (communityId == null) return null;
    final recordGroup = recordGroupFor(conversationId);
    if (recordGroup == null) return null;
    final GovernanceState? record;
    try {
      record = governanceOf(conversationId);
    } catch (_) {
      return null;
    }
    if (record == null) return null;
    return ReportModerators(
      communityId,
      <String>{
        for (final account in <String>{
          if (record.owner != null) record.owner!,
          ...record.admins.keys,
          ...record.moderators,
        })
          if (record.rankOf(account) >= BuiltInRole.moderator.rank) account,
      },
      recordGroupId: recordGroup,
    );
  }

  /// The channel a C6 report key payload into the shared group [group]
  /// rides in: an open channel, or an announcement channel when this
  /// account is an owner or admin under the verified record (the server
  /// refuses anyone else's envelope there). Null when there is none.
  String? _reportKeyChannelFor(String group) {
    final conversation = conversations.where((c) => c.id == group).firstOrNull;
    final communityId = conversation?.communityId;
    if (conversation == null ||
        !conversation.isCommunityShared ||
        communityId == null) {
      return null;
    }
    final routed = (channelsByCommunity[communityId] ?? const <Channel>[])
        .where((c) => c.conversationId == group && c.isRouted);
    final self = session?.accountId;
    final record = governanceOf(group);
    final admin = self != null &&
        record != null &&
        record.rankOf(self) >= BuiltInRole.admin.rank;
    return (routed.where((c) => c.kind == 'open').firstOrNull ??
            (admin
                ? routed.where((c) => c.kind == 'announcement').firstOrNull
                : null))
        ?.id;
  }

  /// This device's report public key for the signed-in account (canonical
  /// base64), or null when it holds no seed. Cached, see [_reportKeyMemo].
  Future<String?> _ownReportKey(Session current, String accountId) async {
    final memo = _reportKeyMemo;
    if (memo != null &&
        memo.baseUrl == current.baseUrl &&
        memo.accountId == accountId) {
      return memo.key.isEmpty ? null : memo.key;
    }
    final crypto = cryptoService;
    if (crypto is! ReportCryptoService) return null;
    final seed = await reportSeedStore.load(current.baseUrl, accountId);
    String key = '';
    if (seed != null) {
      try {
        key = base64Encode(
            await (crypto as ReportCryptoService).reportPublicKey(seed));
      } finally {
        seed.fillRange(0, seed.length, 0);
      }
    }
    _reportKeyMemo = (baseUrl: current.baseUrl, accountId: accountId, key: key);
    return key.isEmpty ? null : key;
  }

  /// C6 background pass (foreground sync only; never throws), with the
  /// rules in [ReportKeyAnnouncer]:
  ///
  /// - In every community with a verified record, asks (`report_key_request`)
  ///   for the announcements of the record's moderators that this device
  ///   lacks. It runs whether or not anyone reports, so the group never
  ///   learns that this account is about to report.
  /// - Where the record ranks this account moderator or above, announces
  ///   this device's report key (`report_key`) when due, and only where the
  ///   server lists this device's key as this account's moderator inbox: a
  ///   key another device replaced is never announced back.
  Future<void> _announceReportKeys() async {
    final current = session;
    final accountId = current?.accountId;
    final client = api;
    if (current == null ||
        accountId == null ||
        client == null ||
        !reportsAvailable ||
        _reportKeyAnnouncing) {
      return;
    }
    _reportKeyAnnouncing = true;
    try {
      Future<bool> sendIn(
          String group, AppPayloadType type, Map<String, Object?> body) async {
        final channel = _reportKeyChannelFor(group);
        if (channel == null || !_sameSession(current)) return false;
        return _sendPayload(group, type, body, channelId: channel);
      }

      final announcer = ReportKeyAnnouncer(
        store: localStore,
        listedKey: (communityId) async =>
            (await client.getOwnModeratorReportKey(current.token, communityId))
                ?.publicKey,
        send: (group, key) => sendIn(
            group, AppPayloadType.reportKey, <String, Object?>{'key': key}),
        sendRequest: (group, accounts) => sendIn(
            group,
            AppPayloadType.reportKeyRequest,
            <String, Object?>{'accounts': accounts}),
      );
      final moderated = <(String, String)>[];
      for (final community in communities) {
        final shared = community.sharedConversationId;
        if (shared == null) continue;
        if (!_sameSession(current)) return;
        final moderators = reportModeratorsFor(shared);
        if (moderators == null) continue;
        await announcer.askMissing(
            group: moderators.recordGroupId,
            moderators: moderators.accounts.difference({accountId}));
        if (moderators.accounts.contains(accountId)) {
          moderated.add((community.id, moderators.recordGroupId));
        }
      }
      if (moderated.isEmpty || !_sameSession(current)) return;
      final key = await _ownReportKey(current, accountId);
      if (key == null) return;
      await announcer.run(
        key: key,
        moderated: moderated,
        unlisted: _reportKeyUnlisted,
        active: () => _sameSession(current),
      );
    } catch (err) {
      developer.log('c6_report_key_pass_failed ${err.runtimeType}',
          name: 'veritra.sync');
    } finally {
      _reportKeyAnnouncing = false;
    }
  }

  /// Whether this account moderates [communityId] under its verified role
  /// record, so its moderator report inbox is offered.
  bool moderatesCommunity(String communityId) {
    final self = session?.accountId;
    final shared = communities
        .where((c) => c.id == communityId)
        .firstOrNull
        ?.sharedConversationId;
    if (self == null || shared == null || !reportsAvailable) return false;
    final moderators = reportModeratorsFor(shared);
    return moderators != null && moderators.accounts.contains(self);
  }

  /// Whether this device holds the signed-in owner's report-key seed, so the
  /// sign-out screen can warn that signing out deletes it.
  Future<bool> holdsReportSeed() async {
    final current = session;
    final accountId = current?.accountId;
    if (current == null || accountId == null || !reportsAvailable) {
      return false;
    }
    try {
      final seed = await reportSeedStore.load(current.baseUrl, accountId);
      seed?.fillRange(0, seed.length, 0);
      return seed != null;
    } catch (_) {
      return false;
    }
  }

  /// Deletes the signed-in account's report-key seed from this device. Called
  /// on a deliberate sign-out, after the screen warned; reports sealed to it
  /// can no longer be opened here.
  Future<void> _deleteReportSeed(Session? current) async {
    final accountId = current?.accountId;
    if (current == null || accountId == null) return;
    _reportKeyMemo = null;
    _reportKeyUnlisted.clear();
    try {
      await reportSeedStore.delete(current.baseUrl, accountId);
    } catch (_) {
      // Sign-out must not fail on a keystore error.
    }
  }
}
