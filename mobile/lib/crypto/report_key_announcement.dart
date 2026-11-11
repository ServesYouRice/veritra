import 'dart:convert';

import '../storage/device_list_records.dart' show LeafVerdict;
import 'app_payload.dart';

/// C6: moderator report keys authenticated over MLS
/// (docs/designs/C6-reports-franking.md, "Moderator keys over MLS";
/// docs/crypto.md, §4 `report_key` and `report_key_request`).
///
/// A community member's app announces its own report public key in the
/// community's shared group (`report_key`). MLS authenticates the sender's
/// account (D25) and the L1 list approves its device, so a reporter who sees
/// the same key listed by the server for that account's moderator inbox can
/// seal to it without a person comparing codes. Whether that account
/// moderates is judged when a report is sealed, against the verified C4
/// record, never when the announcement arrives.
///
/// A device that lacks a moderator's announcement (it joined after it was
/// sent) asks with `report_key_request`, naming the accounts it lacks; each
/// named account's app announces again.
///
/// Both are hidden, never franked and never reportable. They are kept as
/// settings committed with the MLS state, keyed by the record group (the
/// group whose MLS state holds the C4 record), so nothing a server says
/// about a conversation's kind can plant a key.

/// Most accounts one request may name: well above a community's moderators.
const int maxReportKeyRequestAccounts = 64;

/// Wait between two announcements of the same key in one group, so a burst
/// of requests costs each moderator one message.
const Duration reportKeyAnswerSpacing = Duration(minutes: 5);

/// Wait between two requests from this device for one group.
const Duration reportKeyRequestSpacing = Duration(minutes: 10);

/// `{"key": base64}`: the sender's own 32-byte report public key, canonical
/// base64.
bool isValidReportKeyBody(Map<String, Object?> body) =>
    body.length == 1 && reportKeyBytes(body) != null;

/// The key of a valid `report_key` body, or null.
List<int>? reportKeyBytes(Map<String, Object?> body) {
  final key = body['key'];
  if (key is! String) return null;
  try {
    final bytes = base64Decode(key);
    // Canonical only, so two encodings of one key never differ.
    return bytes.length == 32 && base64Encode(bytes) == key ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// `{"accounts": [account_id, ...]}`: 1 to [maxReportKeyRequestAccounts]
/// distinct, non-empty account ids of at most 128 characters.
bool isValidReportKeyRequestBody(Map<String, Object?> body) {
  final accounts = body['accounts'];
  if (body.length != 1 || accounts is! List) return false;
  if (accounts.isEmpty || accounts.length > maxReportKeyRequestAccounts) {
    return false;
  }
  final seen = <String>{};
  for (final account in accounts) {
    if (account is! String || account.isEmpty || account.length > 128) {
      return false;
    }
    if (!seen.add(account)) return false;
  }
  return true;
}

/// The key [accountId] last announced in [recordGroupId], committed with the
/// MLS state: canonical base64 of 32 bytes.
String reportKeyAnnouncementSetting(String recordGroupId, String accountId) =>
    'c6.report_key.$recordGroupId.${Uri.encodeComponent(accountId)}';

/// The sync event id of the latest request in [recordGroupId] that named
/// this device's account, committed with the MLS state.
String reportKeyRequestSetting(String recordGroupId) =>
    'c6.report_key_request.$recordGroupId';

/// This device's own last announcement in [recordGroupId] (local only):
/// see [ReportKeySent].
String reportKeySentSetting(String recordGroupId) =>
    'c6.report_key_sent.$recordGroupId';

/// When this device last asked [recordGroupId] for keys (local only), in
/// epoch milliseconds.
String reportKeyAskedSetting(String recordGroupId) =>
    'c6.report_key_asked.$recordGroupId';

/// The record of this device's last `report_key` in one group: which key,
/// when, and which request it answered (if any).
class ReportKeySent {
  const ReportKeySent({required this.key, required this.atMs, this.answered});

  /// Canonical base64 of the announced key.
  final String key;
  final int atMs;

  /// The [reportKeyRequestSetting] value seen when it was sent.
  final String? answered;

  String encode() => jsonEncode(<String, Object?>{
        'key': key,
        'at': atMs,
        if (answered != null) 'answered': answered,
      });

  static ReportKeySent? decode(String? raw) {
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final key = map['key'], at = map['at'], answered = map['answered'];
      if (key is! String || at is! int) return null;
      return ReportKeySent(
          key: key, atMs: at, answered: answered is String ? answered : null);
    } catch (_) {
      return null;
    }
  }
}

/// Whether this device should announce [key] in a group now: it never
/// announced this key there, or a request it has not answered arrived and
/// [reportKeyAnswerSpacing] has passed since its last announcement.
bool reportKeyAnnouncementDue({
  required String key,
  required ReportKeySent? sent,
  required String? request,
  required DateTime now,
}) {
  if (sent == null || sent.key != key) return true;
  if (request == null || request == sent.answered) return false;
  return now.toUtc().millisecondsSinceEpoch - sent.atMs >=
      reportKeyAnswerSpacing.inMilliseconds;
}

/// The settings a received `report_key` or `report_key_request` commits with
/// the MLS state, or none. Kept only:
/// - in a record group ([isRecordGroup]: the group's own MLS state holds a
///   C4 record, as the shared group of a community does);
/// - from a device its account's L1 list approves now ([verdict] approved;
///   a removed device cannot set a new key);
/// - for a request, when it names [selfAccountId].
///
/// [syncEventId] orders requests: a later request has a larger id.
Map<String, String?> reportKeySettingsFor(
  DecryptedAppPayload payload, {
  required String conversationId,
  required String senderAccountId,
  required bool isRecordGroup,
  required LeafVerdict? verdict,
  required String? selfAccountId,
  required int syncEventId,
}) {
  if (!isRecordGroup ||
      verdict != LeafVerdict.approved ||
      senderAccountId.isEmpty ||
      senderAccountId.length > 128) {
    return const <String, String?>{};
  }
  switch (payload.type) {
    case AppPayloadType.reportKey:
      final key = reportKeyBytes(payload.body);
      if (key == null) return const <String, String?>{};
      return <String, String?>{
        reportKeyAnnouncementSetting(conversationId, senderAccountId):
            base64Encode(key),
      };
    case AppPayloadType.reportKeyRequest:
      final accounts = payload.body['accounts'];
      if (selfAccountId == null ||
          senderAccountId == selfAccountId ||
          accounts is! List ||
          !accounts.contains(selfAccountId)) {
        return const <String, String?>{};
      }
      return <String, String?>{
        reportKeyRequestSetting(conversationId): syncEventId.toString(),
      };
    default:
      return const <String, String?>{};
  }
}
