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

/// Whole calendar days from [time]'s local date to [now]'s local date:
/// 0 for the same day, 1 for yesterday, negative for a future date. Counted
/// on UTC dates so a daylight-saving change cannot turn a day into 23 hours.
int calendarDaysBefore(DateTime time, DateTime now) {
  final a = time.toLocal();
  final b = now.toLocal();
  return DateTime.utc(b.year, b.month, b.day)
      .difference(DateTime.utc(a.year, a.month, a.day))
      .inDays;
}

/// The chat-list timestamp: the time for today, `Yesterday`, a short
/// month-day earlier this year, and a date with its year before that.
///
/// Every form except `Yesterday` comes from [MaterialLocalizations] and the
/// platform's 24-hour setting, so it follows the device locale; the word
/// itself joins the string catalogue with the rest of the copy (T44C).
String formatListTimestamp(
  BuildContext context,
  DateTime time, {
  DateTime? now,
}) {
  final local = time.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  final days = calendarDaysBefore(local, current);
  if (days == 0) {
    return formatTimeOfDay(context, local);
  }
  if (days == 1) {
    return 'Yesterday';
  }
  final localizations = MaterialLocalizations.of(context);
  if (local.year == current.year) {
    return localizations.formatShortMonthDay(local);
  }
  return localizations.formatShortDate(local);
}

/// The day separator in a conversation: `Today`, `Yesterday`, the weekday
/// and date this year, and a date with its year before that, so a thread
/// that spans a new year never shows two identical-looking days.
String formatDayLabel(BuildContext context, DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  final days = calendarDaysBefore(local, current);
  if (days == 0) {
    return 'Today';
  }
  if (days == 1) {
    return 'Yesterday';
  }
  final localizations = MaterialLocalizations.of(context);
  if (local.year == current.year) {
    return localizations.formatMediumDate(local);
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
