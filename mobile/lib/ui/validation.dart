import 'dart:convert';

/// Longest group, community or channel name the server accepts: 64 bytes of
/// UTF-8 after trimming (`validDisplayName` in `server/internal/httpapi`).
const int maxDisplayNameBytes = 64;

/// Inline error for a group, community or channel name, or null when the
/// server would accept it. Checked on the device so the form can say what is
/// wrong next to the field instead of after a round trip.
String? displayNameError(String? value, {String noun = 'name'}) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) {
    return 'Enter a $noun.';
  }
  if (utf8.encode(trimmed).length > maxDisplayNameBytes) {
    return 'That $noun is too long.';
  }
  return null;
}
