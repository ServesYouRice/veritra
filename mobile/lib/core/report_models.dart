import 'dart:convert';
import 'dart:typed_data';

/// C6 report wire models (`docs/designs/C6-reports-franking.md`). The server
/// carries sealed ciphertext only; nothing here holds a message, and no
/// `toString` prints sealed bytes.

const int _maxIdLength = 128;
const int _reportKeyBytes = 32;
// Mirrors the server's bound (`MaxSealedReportBytes`).
const int _maxSealedBytes = 4 + 32 + 256 * 1024 + 16;

String _id(Object? value) {
  if (value is! String || value.isEmpty || value.length > _maxIdLength) {
    throw const FormatException('invalid report field');
  }
  return value;
}

List<int> _bytes(Object? value, {int? length, int? max}) {
  if (value is! String) throw const FormatException('invalid report field');
  final bytes = base64Decode(value);
  if ((length != null && bytes.length != length) ||
      (max != null && bytes.length > max)) {
    throw const FormatException('invalid report field');
  }
  return bytes;
}

/// One recipient key of a report inbox, as `GET /reports/inbox` lists it.
class ReportInboxRecipient {
  ReportInboxRecipient({
    required this.inboxId,
    required List<int> publicKey,
    required this.keyRev,
  }) : publicKey = List<int>.unmodifiable(publicKey);

  factory ReportInboxRecipient.fromJson(Map<String, Object?> json) {
    final rev = json['key_rev'];
    if (rev is! int || rev < 1) throw const FormatException('invalid rev');
    return ReportInboxRecipient(
      inboxId: _id(json['inbox_id']),
      publicKey: _bytes(json['public_key'], length: _reportKeyBytes),
      keyRev: rev,
    );
  }

  final String inboxId;
  final List<int> publicKey;
  final int keyRev;
}

/// Where a report about a message of one conversation goes.
class ReportInbox {
  ReportInbox({required this.kind, required this.recipients});

  factory ReportInbox.fromJson(Map<String, Object?> json) {
    final kind = json['inbox_kind'];
    final rows = json['recipients'];
    if (kind is! String || kind.isEmpty || (rows != null && rows is! List)) {
      throw const FormatException('invalid inbox');
    }
    return ReportInbox(
      kind: kind,
      recipients: [
        for (final row in (rows as List? ?? const <Object?>[]))
          if (row is Map)
            ReportInboxRecipient.fromJson(Map<String, Object?>.from(row))
          else
            throw const FormatException('invalid recipient'),
      ],
    );
  }

  /// `instance_owner` or `community`.
  final String kind;
  final List<ReportInboxRecipient> recipients;
}

/// One stored copy of a report in an inbox the caller reads. [id] is the
/// copy's own id (used to dismiss it and to ask for the envelope record);
/// [reportId] is the reporter's id, the same in every copy.
class ReportCopyRow {
  ReportCopyRow({
    required this.id,
    required this.reportId,
    required this.inboxKind,
    required this.inboxId,
    required this.keyRev,
    required List<int> recipientPublicKey,
    required this.conversationId,
    required this.reporterAccountId,
    required List<int> sealed,
    required this.createdAt,
  })  : recipientPublicKey = List<int>.unmodifiable(recipientPublicKey),
        sealed = List<int>.unmodifiable(sealed);

  factory ReportCopyRow.fromJson(Map<String, Object?> json) {
    final rev = json['key_rev'];
    final created = json['created_at'];
    if (rev is! int || rev < 1 || created is! String) {
      throw const FormatException('invalid report');
    }
    return ReportCopyRow(
      id: _id(json['id']),
      reportId: _id(json['report_id']),
      inboxKind: _id(json['inbox_kind']),
      inboxId: _id(json['inbox_id']),
      keyRev: rev,
      recipientPublicKey:
          _bytes(json['recipient_public_key'], length: _reportKeyBytes),
      conversationId: _id(json['conversation_id']),
      reporterAccountId: _id(json['reporter_account_id']),
      sealed: _bytes(json['sealed'], max: _maxSealedBytes),
      createdAt: DateTime.parse(created).toUtc(),
    );
  }

  final String id;
  final String reportId;
  final String inboxKind;
  final String inboxId;
  final int keyRev;
  final List<int> recipientPublicKey;
  final String conversationId;
  final String reporterAccountId;
  final List<int> sealed;
  final DateTime createdAt;

  @override
  String toString() => 'ReportCopyRow($id)';
}

/// What the server recorded when the reported message was sent: the sender,
/// the conversation and the franking commitment (C6, condition G1).
class ReportEnvelopeRecord {
  ReportEnvelopeRecord({
    required this.envelopeId,
    required this.conversationId,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.frankCommit,
    required this.createdAt,
    this.sealed = false,
    this.idempotencyKey,
  });

  factory ReportEnvelopeRecord.fromJson(Map<String, Object?> json) {
    final created = json['created_at'];
    if (created is! String) throw const FormatException('invalid record');
    // L2-3: a sealed envelope's record names no sender, and must not.
    final sealed = json['sealed'] == true;
    if (sealed &&
        (json['sender_account_id'] != null ||
            json['sender_device_id'] != null)) {
      throw const FormatException('invalid record');
    }
    return ReportEnvelopeRecord(
      sealed: sealed,
      envelopeId: _id(json['envelope_id']),
      conversationId: _id(json['conversation_id']),
      senderAccountId: sealed ? '' : _id(json['sender_account_id']),
      senderDeviceId: sealed ? '' : _id(json['sender_device_id']),
      frankCommit: json['frank_commit'] == null
          ? null
          : List<int>.unmodifiable(_bytes(json['frank_commit'], length: 32)),
      createdAt: DateTime.parse(created).toUtc(),
      idempotencyKey: sealed ? _id(json['idempotency_key']) : null,
    );
  }

  final String envelopeId;
  final String conversationId;

  /// Empty for a [sealed] record.
  final String senderAccountId;
  final String senderDeviceId;

  /// L2-3: the server stored the message sealed, with no sender.
  final bool sealed;

  /// L2-3: the key the sealed envelope is stored under (required for a
  /// [sealed] record, null otherwise). The verifier requires it to equal
  /// the report's action id, so a member's copy of the ciphertext and
  /// commitment under another key is not attributed to the sender.
  final String? idempotencyKey;

  /// Null for a message sent without franking.
  final List<int>? frankCommit;
  final DateTime createdAt;
}

/// L2-3 (review M2): a sender device's franking key from its account's
/// signed list, and when this device first pinned that list.
class SenderFrankKey {
  SenderFrankKey(List<int> key, {required this.pinnedAt})
      : key = Uint8List.fromList(key);

  final Uint8List key;

  /// When this device first pinned the sender's list (its own clock).
  final DateTime pinnedAt;
}
