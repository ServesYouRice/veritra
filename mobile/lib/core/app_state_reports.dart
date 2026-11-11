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
    );
  }

  /// C6: who receives a report about [conversationId] in a community: the
  /// owner, admins and moderators of the verified role record (C4) of the
  /// community's shared group. Null outside a community or without a record.
  ReportModerators? reportModeratorsFor(String conversationId) {
    final conversation =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    final communityId = conversation?.communityId;
    if (conversation == null || communityId == null) return null;
    final GovernanceState? record;
    try {
      record = governanceOf(conversationId);
    } catch (_) {
      return null;
    }
    if (record == null) return null;
    return ReportModerators(communityId, <String>{
      for (final account in <String>{
        if (record.owner != null) record.owner!,
        ...record.admins.keys,
        ...record.moderators,
      })
        if (record.rankOf(account) >= BuiltInRole.moderator.rank) account,
    });
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
    try {
      await reportSeedStore.delete(current.baseUrl, accountId);
    } catch (_) {
      // Sign-out must not fail on a keystore error.
    }
  }
}
