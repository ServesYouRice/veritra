import 'dart:convert';

import '../l10n/l10n.dart';

/// Longest group, community or channel name the server accepts: 64 bytes of
/// UTF-8 after trimming (`validDisplayName` in `server/internal/httpapi`).
const int maxDisplayNameBytes = 64;

/// Inline error for a group, community or channel name, or null when the
/// server would accept it. Checked on the device so the form can say what is
/// wrong next to the field instead of after a round trip.
///
/// [groupName] picks the group wording; [l10n] defaults to English for
/// callers without a [BuildContext].
String? displayNameError(
  String? value, {
  bool groupName = false,
  AppLocalizations? l10n,
}) {
  final strings = l10n ?? englishL10n;
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) {
    return groupName
        ? strings.validationGroupNameRequired
        : strings.validationNameRequired;
  }
  if (utf8.encode(trimmed).length > maxDisplayNameBytes) {
    return groupName
        ? strings.validationGroupNameTooLong
        : strings.validationNameTooLong;
  }
  return null;
}
