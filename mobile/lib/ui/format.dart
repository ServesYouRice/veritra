/// Lightweight date/time formatting helpers (no intl dependency).
library;

String formatTimeOfDay(DateTime time) {
  final local = time.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

String formatDate(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) {
    return 'Today';
  }
  if (difference == 1) {
    return 'Yesterday';
  }
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = months[local.month - 1];
  if (local.year == now.year) {
    return '$month ${local.day}';
  }
  return '$month ${local.day}, ${local.year}';
}

String formatDateTime(DateTime time) =>
    '${formatDate(time)} · ${formatTimeOfDay(time)}';

/// Compact identifier preview, e.g. `acct_9f2…c41`.
String shortId(String id) {
  if (id.length <= 14) {
    return id;
  }
  return '${id.substring(0, 8)}…${id.substring(id.length - 4)}';
}
