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
    );
  }
}
