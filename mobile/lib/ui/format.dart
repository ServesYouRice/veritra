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
