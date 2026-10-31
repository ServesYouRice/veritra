import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path_provider/path_provider.dart';

import '../../core/app_state.dart';
import '../../core/attachments.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';

/// Most files that can wait in the composer at once.
const int maxPendingAttachments = 10;

/// A file chosen, dropped or pasted into the composer. It is only a path
/// until sent: encryption starts at send time, one attachment per file.
class PendingAttachment {
  PendingAttachment({
    required this.path,
    required this.name,
    required this.size,
    this.mediaType,
    this.temporary = false,
  });

  final String path;
  final String name;
  final int size;
  final String? mediaType;

  /// True for a copy the app made (a pasted image), deleted once it is
  /// sent or removed.
  final bool temporary;

  Future<void> discard() async {
    if (!temporary) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best effort: the cache directory is cleared by the system.
    }
  }
}

/// The files waiting to be sent from one conversation's composer.
class ComposerAttachments extends ChangeNotifier {
  final List<PendingAttachment> _items = <PendingAttachment>[];

  /// True while one [sendPendingAttachments] call runs, from its first line
  /// to its last, including the clean-up after each file. A second call finds
  /// it set and sends nothing.
  bool _sendingBatch = false;

  /// The file whose send is under way. Taking it off the tray must not delete
  /// its temporary copy until the send has read it.
  PendingAttachment? _inFlight;
  bool _discardInFlight = false;
  bool _disposed = false;

  List<PendingAttachment> get items =>
      List<PendingAttachment>.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  int get length => _items.length;

  /// Whether a batch send is running on this tray.
  bool get isSending => _sendingBatch;

  /// Whether [item] is still waiting on the tray.
  bool contains(PendingAttachment item) => _items.contains(item);

  void add(PendingAttachment item) {
    _items.add(item);
    _notify();
  }

  Future<void> remove(PendingAttachment item) async {
    if (_items.remove(item)) _notify();
    await _discard(item);
  }

  /// Drops everything, deleting the app's own temporary copies. The file
  /// being sent right now is deleted once its send ends.
  Future<void> clear() async {
    final dropped = List<PendingAttachment>.of(_items);
    _items.clear();
    if (dropped.isNotEmpty) _notify();
    for (final item in dropped) {
      await _discard(item);
    }
  }

  Future<void> _discard(PendingAttachment item) async {
    if (identical(item, _inFlight)) {
      _discardInFlight = true;
      return;
    }
    await item.discard();
  }

  void _markInFlight(PendingAttachment item) {
    _inFlight = item;
    _discardInFlight = false;
  }

  /// Ends the in-flight marker and deletes the file now if it was taken off
  /// the tray while it was being sent.
  Future<void> _clearInFlight(PendingAttachment item) async {
    final discard = _discardInFlight;
    _inFlight = null;
    _discardInFlight = false;
    if (discard) await item.discard();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Adds files to [tray], refusing empty ones, ones over the server's cap and
/// any beyond [maxPendingAttachments] before anything is encrypted or
/// uploaded. One message names every refusal.
Future<void> addAttachmentFiles(
  BuildContext context,
  AppState state,
  ComposerAttachments tray,
  Iterable<XFile> files, {
  Set<String> temporaryPaths = const <String>{},
}) async {
  final picked = files.toList();
  if (picked.isEmpty) return;
  final limit = await state.attachmentSizeLimit();
  final problems = <String>[];
  var tooMany = false;
  for (final file in picked) {
    final name = safeAttachmentName(file.name);
    final temporary = temporaryPaths.contains(file.path);
    final int size;
    try {
      size = await file.length();
    } on FileSystemException {
      // A folder or an unreadable file: not an attachment.
      continue;
    }
    if (!context.mounted) return;
    if (size <= 0) {
      problems.add(context.l10n.attachmentEmptyFile(name));
    } else if (size > limit) {
      problems.add(
        context.l10n.attachmentTooLarge(name, formatFileSize(context, limit)),
      );
    } else if (tray.length >= maxPendingAttachments) {
      tooMany = true;
    } else {
      tray.add(PendingAttachment(
        path: file.path,
        name: name,
        size: size,
        mediaType: file.mimeType,
        temporary: temporary,
      ));
      continue;
    }
    if (temporary) {
      await PendingAttachment(
              path: file.path, name: name, size: 0, temporary: true)
          .discard();
    }
  }
  if (tooMany && context.mounted) {
    problems.add(context.l10n.attachmentTooMany(maxPendingAttachments));
  }
  if (problems.isNotEmpty && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(problems.join('\n'))));
  }
}

/// Asks for one or more files and puts them in the composer's tray.
Future<void> pickAttachmentFiles(
  BuildContext context,
  AppState state,
  ComposerAttachments tray,
) async {
  final List<XFile> files;
  try {
    files = await openFiles();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.attachmentPickUnavailable)),
      );
    }
    return;
  }
  if (!context.mounted) return;
  await addAttachmentFiles(context, state, tray, files);
}

/// What an image from the clipboard is called and stored as.
String pastedImageName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'image-${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.png';
}

/// Writes clipboard image bytes to a private cache file, for the tray.
Future<XFile> writePastedImage(Uint8List bytes) async {
  final directory = await getTemporaryDirectory();
  final folder = Directory(
    '${directory.path}${Platform.pathSeparator}veritra-paste',
  );
  await folder.create(recursive: true);
  final random = Random.secure().nextInt(1 << 32).toRadixString(16);
  final name = pastedImageName(DateTime.now());
  final file = File('${folder.path}${Platform.pathSeparator}$random-$name');
  await file.writeAsBytes(bytes, flush: true);
  return XFile(file.path, name: name, mimeType: 'image/png');
}

/// Deletes pasted images left behind by an earlier run. Call at startup.
Future<void> purgePastedImages() async {
  try {
    final directory = await getTemporaryDirectory();
    final folder = Directory(
      '${directory.path}${Platform.pathSeparator}veritra-paste',
    );
    if (await folder.exists()) await folder.delete(recursive: true);
  } on FileSystemException {
    // Best effort.
  } on MissingPluginException {
    // No path provider (a test host).
  }
}

/// Sends each waiting file as its own encrypted attachment message, in
/// order, taking sent ones off the tray. Stops at the first failure and
/// leaves the rest waiting. Returns whether everything was sent.
///
/// Only one call runs per tray: a call made while another is still running,
/// even in its clean-up after a file, sends nothing and returns false. A file
/// taken off the tray before its turn is not sent, and one taken off during
/// its own send keeps its temporary copy until that send ends.
Future<bool> sendPendingAttachments(
  BuildContext context,
  AppState state,
  String conversationId,
  ComposerAttachments tray,
) async {
  if (tray._sendingBatch) return false;
  tray._sendingBatch = true;
  try {
    for (final item in tray.items) {
      // The person may have removed it since the list was copied.
      if (!tray.contains(item)) continue;
      tray._markInFlight(item);
      final bool sent;
      try {
        sent = await state.sendAttachment(
          conversationId,
          path: item.path,
          fileName: item.name,
          mediaType: item.mediaType,
        );
      } finally {
        await tray._clearInFlight(item);
      }
      if (!sent) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              state.errorFor(Ops.attachment) ??
                  context.l10n.attachmentSendFailed,
            ),
          ));
        }
        return false;
      }
      await tray.remove(item);
    }
    return true;
  } finally {
    tray._sendingBatch = false;
  }
}

/// The files waiting to be sent, as removable chips above the composer.
class AttachmentTray extends StatelessWidget {
  const AttachmentTray({required this.tray, super.key});

  final ComposerAttachments tray;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tray,
      builder: (context, _) {
        if (tray.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            BoneSpacing.md,
            BoneSpacing.sm,
            BoneSpacing.md,
            0,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: BoneSpacing.xs,
              runSpacing: BoneSpacing.xs,
              children: <Widget>[
                for (final item in tray.items)
                  InputChip(
                    avatar: const Icon(Icons.insert_drive_file_outlined),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        '${item.name} · ${formatFileSize(context, item.size)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    deleteButtonTooltipMessage:
                        context.l10n.attachmentRemove(item.name),
                    onDeleted: () => tray.remove(item),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
