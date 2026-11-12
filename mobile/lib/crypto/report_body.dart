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
/// ([senderAccountId]), the sender's franking [signature] `s` over the
/// commitment and the sender leaf's [signingKey] it verified under
/// (`docs/crypto.md`, "Franking a sealed message"). The recipient checks `s`
/// and that the key is the claimed device's in the claimed account's
/// signed L1 device list.
class ReportBody {
  ReportBody({
    required this.envelopeId,
    required this.conversationId,
    required this.senderDeviceId,
    required this.actionId,
    required List<int> payload,
    required List<int> frankKey,
    this.senderAccountId,
    List<int>? signature,
    List<int>? signingKey,
  })  : payload = List<int>.unmodifiable(payload),
        frankKey = List<int>.unmodifiable(frankKey),
        signature = signature == null ? null : List<int>.unmodifiable(signature),
        signingKey =
            signingKey == null ? null : List<int>.unmodifiable(signingKey);

  /// The body of a report about the message [reveal] was kept for. The
  /// message key is `<sender_device_id>:<action_id>`.
  factory ReportBody.fromReveal(FrankReveal reveal) {
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
      signature: reveal.sealed ? reveal.signature : null,
      signingKey: reveal.sealed ? reveal.signingKey : null,
    );
  }

  static const int version = 1;

  /// L2-3: the body of a report about a sealed message.
  static const int sealedVersion = 2;
  static const int maxIdBytes = 128;
  static const int maxPayloadBytes = 64 * 1024;

  final String envelopeId;
  final String conversationId;
  final String senderDeviceId;
  final String actionId;

  /// The canonical payload bytes `P`.
  final List<int> payload;
  final List<int> frankKey;

  /// Set together, only for a sealed message (version 2).
  final String? senderAccountId;
  final List<int>? signature;
  final List<int>? signingKey;

  bool get sealed => signature != null;

  Uint8List encode() {
    _check(envelopeId, conversationId, senderDeviceId, actionId, payload,
        frankKey);
    _checkSealed(senderAccountId, signature, signingKey);
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'v': sealed ? sealedVersion : version,
      'envelope_id': envelopeId,
      'conversation_id': conversationId,
      'sender_device_id': senderDeviceId,
      'action_id': actionId,
      'payload': base64Encode(payload),
      'frank_key': base64Encode(frankKey),
      if (sealed) ...{
        'sender_account_id': senderAccountId,
        'signature': base64Encode(signature!),
        'signing_key': base64Encode(signingKey!),
      },
    })));
  }

  /// Reads a body a recipient opened. Throws [FormatException] for anything
  /// but exactly the fields [encode] writes, in range.
  factory ReportBody.decode(List<int> bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      throw const FormatException('invalid report body');
    }
    final sealedBody = decoded is Map && decoded['v'] == sealedVersion;
    if (decoded is! Map ||
        decoded.length != (sealedBody ? 10 : 7) ||
        (decoded['v'] != version && !sealedBody) ||
        (sealedBody &&
            (decoded['sender_account_id'] is! String ||
                decoded['signature'] is! String ||
                decoded['signing_key'] is! String)) ||
        decoded['envelope_id'] is! String ||
        decoded['conversation_id'] is! String ||
        decoded['sender_device_id'] is! String ||
        decoded['action_id'] is! String ||
        decoded['payload'] is! String ||
        decoded['frank_key'] is! String) {
      throw const FormatException('invalid report body');
    }
    final List<int> payload, frankKey;
    List<int>? signature, signingKey;
    try {
      payload = base64Decode(decoded['payload'] as String);
      frankKey = base64Decode(decoded['frank_key'] as String);
      if (sealedBody) {
        signature = base64Decode(decoded['signature'] as String);
        signingKey = base64Decode(decoded['signing_key'] as String);
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
      signature: signature,
      signingKey: signingKey,
    );
    _check(body.envelopeId, body.conversationId, body.senderDeviceId,
        body.actionId, payload, frankKey);
    _checkSealed(body.senderAccountId, signature, signingKey);
    return body;
  }

  static void _checkSealed(
      String? senderAccountId, List<int>? signature, List<int>? signingKey) {
    final any =
        senderAccountId != null || signature != null || signingKey != null;
    if (!any) return;
    if (senderAccountId == null ||
        senderAccountId.isEmpty ||
        utf8.encode(senderAccountId).length > maxIdBytes ||
        signature?.length != frankSignatureBytes ||
        signingKey?.length != 32) {
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
