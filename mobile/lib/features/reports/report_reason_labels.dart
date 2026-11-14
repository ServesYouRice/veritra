import '../../crypto/report_body.dart';
import '../../l10n/app_localizations.dart';

/// The words for a report reason (U33, report body v3). One place, so the
/// form and the inbox can never name a reason differently.
String reportReasonLabel(AppLocalizations l10n, ReportReason reason) =>
    switch (reason) {
      ReportReason.spam => l10n.c6ReportReasonSpam,
      ReportReason.harassment => l10n.c6ReportReasonHarassment,
      ReportReason.hate => l10n.c6ReportReasonHate,
      ReportReason.violence => l10n.c6ReportReasonViolence,
      ReportReason.sexual => l10n.c6ReportReasonSexual,
      ReportReason.childSafety => l10n.c6ReportReasonChildSafety,
      ReportReason.selfHarm => l10n.c6ReportReasonSelfHarm,
      ReportReason.privateInfo => l10n.c6ReportReasonPrivateInfo,
      ReportReason.other => l10n.c6ReportReasonOther,
    };
