import 'dart:convert';

import '../crypto/attachment_crypto.dart' show maxPlaintextAttachmentBytes;

/// Media types the app previews inline. Everything else is offered as a
/// file only; the name and type come from the sender and are not trusted.
const Set<String> previewableImageTypes = <String>{
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
};

/// Metadata the server accepts with an uploaded attachment blob. It names
/// the scheme only; keys, names and sizes travel inside the MLS message.
const Map<String, Object?> attachmentUploadMetadata = <String, Object?>{
  'version': 1,
  'algorithm': 'AES-256-GCM-chunked',
  'chunk_size': 1024 * 1024,
};

/// One attachment of a received or sent attachment message: the server
/// blob to download and the manifest that decrypts it.
class AttachmentEntry {
  const AttachmentEntry({
    required this.id,
    required this.fileName,
    required this.mediaType,
    required this.plaintextSize,
    required this.ciphertextSize,
    required this.manifest,
  });

  /// Server attachment id of the encrypted blob.
  final String id;

  /// Display name, stripped of paths and control characters.
  final String fileName;
  final String mediaType;
  final int plaintextSize;
  final int ciphertextSize;

  /// The decryption manifest (key, nonce prefix, chunking, context).
  final Map<String, Object?> manifest;

  bool get isImage => previewableImageTypes.contains(mediaType);

  /// Parses one manifest entry, or returns null if it is malformed.
  static AttachmentEntry? tryParse(Object? raw, {String? conversationId}) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final id = map['id'];
    final name = map['file_name'];
    final type = map['media_type'];
    final plain = map['plaintext_size'];
    final cipher = map['ciphertext_size'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        name is! String ||
        type is! String ||
        plain is! int ||
        plain <= 0 ||
        plain > maxPlaintextAttachmentBytes ||
        cipher is! int ||
        cipher <= plain) {
      return null;
    }
    // The manifest must decrypt only in the conversation it arrived in.
    if (conversationId != null && map['conversation_id'] != conversationId) {
      return null;
    }
    return AttachmentEntry(
      id: id,
      fileName: safeAttachmentName(name),
      mediaType: type.trim().toLowerCase(),
      plaintextSize: plain,
      ciphertextSize: cipher,
      manifest: map,
    );
  }

  /// Parses the JSON list stored in a local attachment message. Malformed
  /// entries are dropped rather than shown.
  static List<AttachmentEntry> listFromBody(String? body,
      {String? conversationId}) {
    if (body == null) return const <AttachmentEntry>[];
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List) return const <AttachmentEntry>[];
      return <AttachmentEntry>[
        for (final item in decoded)
          if (AttachmentEntry.tryParse(item, conversationId: conversationId)
              case final entry?)
            entry,
      ];
    } on FormatException {
      return const <AttachmentEntry>[];
    }
  }
}

/// A file name that is safe to show and to use as a suggested save name:
/// no directories, no control characters, bounded length.
String safeAttachmentName(String raw) {
  var name = raw.split(RegExp(r'[/\\]')).last;
  name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (name.startsWith('.')) name = name.replaceFirst(RegExp(r'^\.+'), '');
  if (name.length > 120) {
    final dot = name.lastIndexOf('.');
    final extension =
        dot > 0 && name.length - dot <= 10 ? name.substring(dot) : '';
    name = '${name.substring(0, 120 - extension.length)}$extension';
  }
  return name.isEmpty ? 'attachment' : name;
}

/// Media type for a picked file: the picker's answer when it gave one,
/// otherwise a guess from the extension for the previewable types.
String attachmentMediaType(String fileName, String? pickerType) {
  final given = pickerType?.trim().toLowerCase();
  if (given != null && given.isNotEmpty && given.contains('/')) return given;
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'application/octet-stream';
}

/// "1.2 MB"-style size for a bubble or dialog.
String formatAttachmentSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
