import 'dart:async';
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

/// Audio types a voice note plays inline. Everything else audio-like is
/// offered as a file only; the type comes from the sender and is not trusted.
const Set<String> playableAudioTypes = <String>{
  'audio/mp4',
  'audio/aac',
  'audio/mpeg',
  'audio/ogg',
  'audio/wav',
  'audio/x-wav',
};

/// The largest attachment, in plaintext bytes, that opens from memory. At or
/// below it the image viewer (`Image.memory`) and the voice player
/// (`BytesSource` or the loopback server) take the decrypted bytes and no
/// file is written; above it the attachment is decrypted to a short-lived
/// temp copy that is deleted when its viewer closes, and the hourly sweep
/// removes any that remain (D134).
///
/// Neither viewer has a size limit of its own, so the limit is the peak
/// memory of one open: the bytes, plus a native copy (the image engine's
/// buffer, or the platform-channel and Java copies of `BytesSource`), plus
/// for an image its decoded frame (at most 4096 x 4096 x 4, about 64 MB, see
/// `maxViewerDecodeSide`). At 8 MiB that is about 3 x 8 = 24 MB of bytes on
/// top of the frame, safe on a 2 GB phone; at the 48 MiB attachment limit
/// ([maxPlaintextAttachmentBytes]) it would be about 144 MB. 8 MiB holds
/// every AAC voice note (64 kbit/s is 8 kB/s, so the 10-minute cap is
/// 4.8 MB) and a typical 12 MP photo (3 to 6 MB). It does not hold the WAV
/// fallback past about 95 s (44.1 kHz mono 16-bit is 88 kB/s), a 48 MP
/// photo, or any file for another app: `OpenFilex.open` takes only a path,
/// so external openers always get a temp copy whatever the size.
///
/// `audioplayers` plays bytes natively on Android and Windows; on iOS, macOS
/// and Linux the voice player serves them from memory over a loopback-only
/// HTTP server (`LoopbackClipServer`), so a small voice note plays without a
/// file everywhere. If the platform refuses that server, the note plays from
/// a temp copy.
const int attachmentMemoryLimit = 8 * 1024 * 1024;

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

  /// Whether an image viewer or the voice player takes this attachment from
  /// memory, so it never touches disk (D134). See [attachmentMemoryLimit].
  bool get opensFromMemory => plaintextSize <= attachmentMemoryLimit;

  bool get isImage => previewableImageTypes.contains(mediaType);

  /// A voice note, or other audio, that plays inline in the chat.
  bool get isVoiceNote => playableAudioTypes.contains(mediaType);

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
  static List<AttachmentEntry> listFromBody(
    String? body, {
    String? conversationId,
  }) {
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
final RegExp _invisibleNameCharacters = RegExp(
  r'[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]',
  unicode: true,
);

/// Characters Windows does not allow in a file name (the path separators are
/// split off before this).
final RegExp _windowsInvalidNameCharacters = RegExp(r'[<>:"|?*]');

/// Device names Windows reserves, with or without an extension.
final RegExp _windowsReservedName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
  caseSensitive: false,
);

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
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.aac')) return 'audio/aac';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.ogg') || lower.endsWith('.opus')) return 'audio/ogg';
  if (lower.endsWith('.wav')) return 'audio/wav';
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

/// Whether a filename belongs to an attachment operation's working files.
/// Account removal uses the same allowlist as the orphan sweep, without
/// its age guard: the account runtime has already been closed.
bool isAttachmentWorkingFile(String name) =>
    _attachmentOrphanName.hasMatch(name);

/// Files younger than this are left alone: another process (a second demo
/// profile shares the directory) or an upload still running may own them.
const Duration attachmentOrphanMinAge = Duration(hours: 1);

/// How often a running app sweeps again. A file is old enough to go after
/// [attachmentOrphanMinAge], so one left by a failure while the app keeps
/// running is gone within about two hours instead of at the next start.
const Duration attachmentOrphanSweepInterval = Duration(hours: 1);

/// Runs [cleanupAttachmentOrphans] at [start] and then every [interval]
/// until [stop]. Sweeps never overlap, and a failure (no directory, no path
/// provider) only skips that sweep. The [minAge] guard keeps the files of
/// operations that are still running.
class AttachmentOrphanSweeper {
  AttachmentOrphanSweeper(
    this._directory, {
    this.interval = attachmentOrphanSweepInterval,
    this.minAge = attachmentOrphanMinAge,
    this.alsoSweep,
  });

  /// More cleanup to run on every sweep, given [minAge]: the opened-file
  /// copies of the viewers live outside this directory (D134).
  final Future<void> Function(Duration minAge)? alsoSweep;

  final Future<Directory?> Function() _directory;
  final Duration interval;
  final Duration minAge;
  Timer? _timer;
  bool _sweeping = false;
  bool _stopped = false;

  /// Sweeps now and arms the periodic sweep. A second call does nothing.
  void start() {
    if (_stopped || _timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(sweep()));
    unawaited(sweep());
  }

  Future<void> sweep() async {
    if (_stopped || _sweeping) return;
    _sweeping = true;
    try {
      final directory = await _directory();
      if (directory != null && !_stopped) {
        await cleanupAttachmentOrphans(directory, minAge: minAge);
      }
    } catch (_) {
      // Best effort; the next tick tries again.
    }
    try {
      await alsoSweep?.call(minAge);
    } catch (_) {
      // Best effort; the next tick tries again.
    } finally {
      _sweeping = false;
    }
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}

/// Deletes the attachment working files a killed or crashed process left in
/// [directory], plaintext `.part` files included. Runs at start, before
/// attachments are used, and then periodically ([AttachmentOrphanSweeper]).
/// Best effort: a file that cannot be deleted is skipped and nothing is
/// thrown.
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
    if (!isAttachmentWorkingFile(name)) continue;
    try {
      if ((await entry.lastModified()).isAfter(cutoff)) continue;
      await entry.delete();
    } on FileSystemException {
      // One file that cannot go must not keep the others.
    }
  }
}
