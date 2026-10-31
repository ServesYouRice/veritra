import 'dart:convert';
import 'dart:io';

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

/// Control, format and separator characters: C0, DEL and C1 controls (Cc),
/// bidi controls, zero-width and other format characters (Cf) and the line
/// and paragraph separators (Zl, Zp). A sender uses them to make
/// `invoice<RLO>fdp.exe` read as `invoiceexe.pdf`. Removing Cf also removes
/// the zero-width joiner, which splits emoji ZWJ sequences into their parts;
/// a name that is safe on every platform matters more than that.
final RegExp _invisibleNameCharacters =
    RegExp(r'[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', unicode: true);

/// Characters Windows does not allow in a file name (the path separators are
/// split off before this).
final RegExp _windowsInvalidNameCharacters = RegExp(r'[<>:"|?*]');

/// Device names Windows reserves, with or without an extension.
final RegExp _windowsReservedName =
    RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$', caseSensitive: false);

/// A file name that is safe to show and to use as a suggested save name:
/// no directories, no invisible or direction-changing characters, valid on
/// Windows as well as elsewhere (the desktop build saves with this name, and
/// the chat shows the same name), bounded length.
String safeAttachmentName(String raw) {
  var name = raw.split(RegExp(r'[/\\]')).last;
  name = name
      .replaceAll(_invisibleNameCharacters, '')
      .replaceAll(_windowsInvalidNameCharacters, '_')
      .trim();
  if (name.startsWith('.')) name = name.replaceFirst(RegExp(r'^\.+'), '');
  if (name.length > 120) {
    final dot = name.lastIndexOf('.');
    final extension =
        dot > 0 && name.length - dot <= 10 ? name.substring(dot) : '';
    name = '${name.substring(0, 120 - extension.length)}$extension';
  }
  // Windows drops trailing dots and spaces, so "a.pdf." is "a.pdf" there.
  name = name.replaceFirst(RegExp(r'[. ]+$'), '');
  final base = name.split('.').first.trimRight();
  if (_windowsReservedName.hasMatch(base)) name = '_$name';
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

/// Working files of an interrupted encryption (`.attachment-<hex>.ciphertext`)
/// or opening (`.veritra-attachment-<hex>.ciphertext`, `.plaintext` and its
/// `.part`). Nothing else in the working directory, which also holds the
/// database, its key and backup files, matches.
final RegExp _attachmentOrphanName = RegExp(
  r'^\.(attachment-[0-9a-f]{32}\.ciphertext'
  r'|veritra-attachment-[0-9a-f]+\.(ciphertext|plaintext|plaintext\.part))$',
);

/// Files younger than this are left alone: another process (a second demo
/// profile shares the directory) or an upload still running may own them.
const Duration attachmentOrphanMinAge = Duration(hours: 1);

/// Deletes the attachment working files a killed or crashed process left in
/// [directory], plaintext `.part` files included. Run it once at start, before
/// attachments are used. Best effort: a file that cannot be deleted is skipped
/// and nothing is thrown.
Future<void> cleanupAttachmentOrphans(
  Directory directory, {
  Duration minAge = attachmentOrphanMinAge,
  DateTime? now,
}) async {
  final cutoff = (now ?? DateTime.now()).subtract(minAge);
  final List<FileSystemEntity> entries;
  try {
    if (!await directory.exists()) return;
    entries = await directory.list(followLinks: false).toList();
  } catch (_) {
    return;
  }
  for (final entry in entries) {
    if (entry is! File) continue;
    final name = entry.uri.pathSegments.last;
    if (!_attachmentOrphanName.hasMatch(name)) continue;
    try {
      if ((await entry.lastModified()).isAfter(cutoff)) continue;
      await entry.delete();
    } on FileSystemException {
      // One file that cannot go must not keep the others.
    }
  }
}
