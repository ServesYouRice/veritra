import 'dart:convert';
import 'dart:typed_data';

import '../storage/local_store.dart';
import 'crypto_service.dart';
import 'franking.dart';
import 'report_key_pins.dart';

/// The plaintext sealed inside every copy of a C6 report (D95). It carries
/// what the server must never see, the message's envelope id first of all,
/// and what a recipient needs to check the report: the revealed canonical
/// payload bytes `P`, the franking key `kf` and the commitment context
/// (`docs/crypto.md`, "Franking v1"). One body is sealed once per recipient
/// (one copy per instance owner), each with its own aad ([reportAad]).
///
/// A recipient decodes it after opening its copy, then recomputes the
/// commitment over [payload] with [frankKey] and the context here, and
/// compares it with the commitment the server recorded for [envelopeId]. The
/// body is untrusted input from the reporter: [decode] bounds every field and
/// refuses anything it does not know.
///
/// L2-3: a report about a sealed message is body version 2. It adds what the
/// server row of a sealed message lacks: the sender account MLS named
/// ([senderAccountId]) and the message's [designation] `d` (empty for the
/// plain form; `docs/crypto.md`, "Franking a sealed message"). Only an owner
/// whose key `d` names can check its tag, with its own report seed and the
/// franking key the claimed device's signed L1 list names. Nothing in the
/// body is a signature anyone else could check.
///
/// U33: the app writes version 3, which adds the reporter's [reason] to
/// either form (C6 design, "Report reasons"). Versions 1 and 2 still decode,
/// with no reason. The reason is the reporter's claim, never franked.
class ReportBody {
  ReportBody({
    required this.envelopeId,
    required this.conversationId,
    required this.senderDeviceId,
    required this.actionId,
    required List<int> payload,
    required List<int> frankKey,
    this.senderAccountId,
    List<int>? designation,
    this.reason,
  })  : payload = List<int>.unmodifiable(payload),
        frankKey = List<int>.unmodifiable(frankKey),
        designation = senderAccountId == null
            ? null
            : List<int>.unmodifiable(designation ?? const <int>[]);

  /// The body of a report about the message [reveal] was kept for. The
  /// message key is `<sender_device_id>:<action_id>`.
  factory ReportBody.fromReveal(FrankReveal reveal,
      {required ReportReason reason}) {
    final split = reveal.messageKey.indexOf(':');
    if (split < 1 || split == reveal.messageKey.length - 1) {
      throw const FormatException('invalid message key');
    }
    return ReportBody(
      envelopeId: reveal.envelopeId,
      conversationId: reveal.conversationId,
      senderDeviceId: reveal.messageKey.substring(0, split),
      actionId: reveal.messageKey.substring(split + 1),
      payload: reveal.payload,
      frankKey: reveal.frankKey,
      senderAccountId: reveal.sealed ? reveal.senderAccountId : null,
      designation: reveal.sealed ? reveal.designation : null,
      reason: reason,
    );
  }

  static const int version = 1;

  /// L2-3: the body of a report about a sealed message.
  static const int sealedVersion = 2;

  /// U33: either form with the reporter's [reason]. The only version
  /// [encode] writes.
  static const int reasonVersion = 3;
  static const int maxIdBytes = 128;
  static const int maxPayloadBytes = 64 * 1024;

  final String envelopeId;
  final String conversationId;
  final String senderDeviceId;
  final String actionId;

  /// The canonical payload bytes `P`.
  final List<int> payload;
  final List<int> frankKey;

  /// Set only for a sealed message (version 2); [designation] is then
  /// non-null and empty for the plain form.
  final String? senderAccountId;
  final List<int>? designation;

  /// The reporter's reason, from a version 3 body; null for a version 1 or
  /// 2 body (sent before reasons existed).
  final ReportReason? reason;

  /// Whether the report is about a sealed message (explicit: version 2 and
  /// its sender account, never inferred from what the designation holds).
  bool get sealed => senderAccountId != null;

  /// Writes a version 3 body. Refuses a body without a [reason]: the writer
  /// never falls back to version 1 or 2.
  Uint8List encode() {
    _check(envelopeId, conversationId, senderDeviceId, actionId, payload,
        frankKey);
    _checkSealed(senderAccountId, designation);
    final chosen = reason;
    if (chosen == null) {
      throw const FormatException('a report body needs a reason');
    }
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'v': reasonVersion,
      'envelope_id': envelopeId,
      'conversation_id': conversationId,
      'sender_device_id': senderDeviceId,
      'action_id': actionId,
      'payload': base64Encode(payload),
      'frank_key': base64Encode(frankKey),
      'reason': chosen.code,
      if (sealed) ...{
        'sender_account_id': senderAccountId,
        'designation': base64Encode(designation!),
      },
    })));
  }

  /// Reads a body a recipient opened. Throws [FormatException] for anything
  /// but exactly the fields one of the versions holds, in range:
  ///
  /// - version 1: the seven common fields;
  /// - version 2: those and the sealed pair (`sender_account_id`,
  ///   `designation`), nine;
  /// - version 3: the common fields and `reason` (eight), plus the sealed
  ///   pair for a sealed message (ten).
  ///
  /// A reason outside version 3's fixed set refuses the whole body (fail
  /// closed: a new reason is a new version, never a new value under v3).
  factory ReportBody.decode(List<int> bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      throw const FormatException('invalid report body');
    }
    if (decoded is! Map) throw const FormatException('invalid report body');
    final v = decoded['v'];
    if (v is! int) throw const FormatException('invalid report body');
    final bool sealedBody;
    final int fields;
    ReportReason? reason;
    switch (v) {
      case version:
        sealedBody = false;
        fields = 7;
      case sealedVersion:
        sealedBody = true;
        fields = 9;
      case reasonVersion:
        // Both or neither of the sealed pair: the count below refuses one
        // without the other.
        sealedBody = decoded.containsKey('sender_account_id');
        fields = sealedBody ? 10 : 8;
        reason = ReportReason.fromCode(decoded['reason']);
      default:
        throw const FormatException('invalid report body');
    }
    if (decoded.length != fields ||
        (sealedBody &&
            (decoded['sender_account_id'] is! String ||
                decoded['designation'] is! String)) ||
        decoded['envelope_id'] is! String ||
        decoded['conversation_id'] is! String ||
        decoded['sender_device_id'] is! String ||
        decoded['action_id'] is! String ||
        decoded['payload'] is! String ||
        decoded['frank_key'] is! String) {
      throw const FormatException('invalid report body');
    }
    final List<int> payload, frankKey;
    List<int>? designation;
    try {
      payload = base64Decode(decoded['payload'] as String);
      frankKey = base64Decode(decoded['frank_key'] as String);
      if (sealedBody) {
        final text = decoded['designation'] as String;
        designation = base64Decode(text);
        // One spelling only.
        if (base64Encode(designation) != text) {
          throw const FormatException('invalid report body');
        }
      }
    } on FormatException {
      throw const FormatException('invalid report body');
    }
    final body = ReportBody(
      envelopeId: decoded['envelope_id'] as String,
      conversationId: decoded['conversation_id'] as String,
      senderDeviceId: decoded['sender_device_id'] as String,
      actionId: decoded['action_id'] as String,
      payload: payload,
      frankKey: frankKey,
      senderAccountId:
          sealedBody ? decoded['sender_account_id'] as String : null,
      designation: designation,
      reason: reason,
    );
    _check(body.envelopeId, body.conversationId, body.senderDeviceId,
        body.actionId, payload, frankKey);
    _checkSealed(body.senderAccountId, body.designation);
    return body;
  }

  static void _checkSealed(String? senderAccountId, List<int>? designation) {
    if (senderAccountId == null) {
      if (designation != null) {
        throw const FormatException('invalid report body');
      }
      return;
    }
    if (senderAccountId.isEmpty ||
        utf8.encode(senderAccountId).length > maxIdBytes ||
        designation == null ||
        (designation.isNotEmpty && !designationWellFormed(designation))) {
      throw const FormatException('invalid report body');
    }
  }

  static void _check(
    String envelopeId,
    String conversationId,
    String senderDeviceId,
    String actionId,
    List<int> payload,
    List<int> frankKey,
  ) {
    for (final id in [envelopeId, conversationId, senderDeviceId, actionId]) {
      if (id.isEmpty || utf8.encode(id).length > maxIdBytes) {
        throw const FormatException('invalid report body');
      }
    }
    if (payload.isEmpty ||
        payload.length > maxPayloadBytes ||
        frankKey.length != frankKeyBytes) {
      throw const FormatException('invalid report body');
    }
  }

  @override
  String toString() => 'ReportBody(${'*' * 4})';
}

/// Why a person reports a message (U33, report body v3). A fixed list: the
/// codes are the wire values, one digit each, so a sealed report's size
/// does not depend on the reason. The set is fixed for body version 3; a
/// reason added later needs a new body version, and a v3 body naming any
/// other code is refused whole ([ReportBody.decode]). The reason is the
/// reporter's claim and is not covered by franking.
enum ReportReason {
  spam(1),
  harassment(2),
  hate(3),
  violence(4),
  sexual(5),
  childSafety(6),
  selfHarm(7),
  privateInfo(8),
  other(9);

  const ReportReason(this.code);

  /// The wire value in a version 3 body.
  final int code;

  /// The reason [value] names. Throws [FormatException] for anything but
  /// one of the codes above as a JSON integer (`3.0`, `"3"`, `0`, `10` and a
  /// missing value are refused).
  static ReportReason fromCode(Object? value) {
    if (value is int) {
      for (final reason in values) {
        if (reason.code == value) return reason;
      }
    }
    throw const FormatException('invalid report body');
  }
}

/// One sealed copy of a report, as `POST /api/v1/reports` takes it.
class SealedReportCopy {
  SealedReportCopy({
    required this.inboxId,
    required this.keyRev,
    required List<int> recipientPublicKey,
    required List<int> sealed,
  })  : recipientPublicKey = List<int>.unmodifiable(recipientPublicKey),
        sealed = List<int>.unmodifiable(sealed);

  final String inboxId;
  final int keyRev;
  final List<int> recipientPublicKey;
  final List<int> sealed;

  Map<String, Object?> toJson() => {
        'inbox_id': inboxId,
        'key_rev': keyRev,
        'recipient_public_key': base64Encode(recipientPublicKey),
        'sealed': base64Encode(sealed),
      };
}

/// Seals [body] once for each of [recipients], each copy bound to its own
/// recipient, the conversation, [reportId] and the reporter ([reportAad]).
/// [recipients] must already have passed [ReportKeyPins.requirePinned]: this
/// seals to exactly the keys it is given. [reportId] is chosen by the
/// reporter's app, once per report, and is the same in every copy.
Future<List<SealedReportCopy>> sealReportCopies({
  required ReportCryptoService crypto,
  required String inboxKind,
  required List<ReportRecipientKey> recipients,
  required String conversationId,
  required String reportId,
  required String reporterAccountId,
  required ReportBody body,
}) async {
  if (recipients.isEmpty) throw ArgumentError.value(recipients, 'recipients');
  final plaintext = body.encode();
  try {
    final copies = <SealedReportCopy>[];
    for (final recipient in recipients) {
      final aad = reportAad(
        inboxKind: inboxKind,
        inboxId: recipient.inboxId,
        recipientKey: recipient.publicKey,
        conversationId: conversationId,
        reportId: reportId,
        reporterAccountId: reporterAccountId,
      );
      copies.add(SealedReportCopy(
        inboxId: recipient.inboxId,
        keyRev: recipient.keyRev,
        recipientPublicKey: recipient.publicKey,
        sealed: await crypto.sealReport(
          recipientPublicKey: recipient.publicKey,
          aad: aad,
          plaintext: Uint8List.fromList(plaintext),
        ),
      ));
    }
    return copies;
  } finally {
    // The plaintext holds the revealed message and its key.
    plaintext.fillRange(0, plaintext.length, 0);
  }
}
