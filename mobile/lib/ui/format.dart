import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

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

/// Compact, locale-aware timestamp for a list row: the time of day for today,
/// `Yesterday`, the month and day within the current year, otherwise a short
/// date. [now] exists for tests; it defaults to the device clock.
///
/// `Yesterday` comes from the app's ARB strings and everything else from
/// [MaterialLocalizations], so the order and month names follow the locale.
String formatListTime(BuildContext context, DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final todayStart = DateTime(today.year, today.month, today.day);
  // Rounded rather than truncated so a 23- or 25-hour DST day still counts
  // as one day.
  final daysAgo = (todayStart.difference(day).inHours / 24).round();
  // A timestamp slightly ahead of this clock (server skew) on the same
  // calendar day is still today.
  if (daysAgo == 0) {
    return formatTimeOfDay(context, local);
  }
  if (daysAgo == 1) {
    return context.l10n.listTimeYesterday;
  }
  final localizations = MaterialLocalizations.of(context);
  if (daysAgo > 0 && local.year == today.year) {
    return localizations.formatShortMonthDay(local);
  }
  return localizations.formatShortDate(local);
}

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
