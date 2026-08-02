import 'package:flutter/material.dart';

String formatTimeOfDay(BuildContext context, DateTime time) {
  final local = time.toLocal();
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(local),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
}

String formatDate(BuildContext context, DateTime time) {
  return MaterialLocalizations.of(context).formatMediumDate(time.toLocal());
}

String formatDateTime(BuildContext context, DateTime time) =>
    '${formatDate(context, time)} · ${formatTimeOfDay(context, time)}';

/// Compact identifier preview, e.g. `acct_9f2…c41`.
String shortId(String id) {
  if (id.length <= 14) {
    return id;
  }
  return '${id.substring(0, 8)}…${id.substring(id.length - 4)}';
}

/// How an account is named in lists: its username when the server supplied
/// one to a co-member, otherwise a shortened account ID. Never invents a name.
String accountLabel(String accountId, String? username) =>
    username == null || username.isEmpty ? shortId(accountId) : '@$username';

/// Initials for an avatar, derived from the same label. Falls back to a
/// neutral glyph rather than a misleading letter when nothing is known.
String accountInitials(String accountId, String? username) {
  final source = username != null && username.isNotEmpty ? username : accountId;
  final letters = source.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (letters.isEmpty) {
    return '?';
  }
  return letters.substring(0, letters.length >= 2 ? 2 : 1).toUpperCase();
}
