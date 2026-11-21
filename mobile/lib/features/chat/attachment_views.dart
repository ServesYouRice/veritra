import 'dart:async';
import 'dart:io';
import 'dart:math' show Random, max;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_state.dart';
import '../../core/attachments.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/bar_action.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../l10n/l10n.dart';

/// Whether this platform can offer a "save as" dialog.
bool get _canChooseSaveLocation =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Opens an attachment: images in a viewer, other files in another app on
/// phones, or through a save dialog on desktop.
Future<void> openAttachment(
  BuildContext context,
  AppState state,
  AttachmentEntry entry, {
  required String conversationId,
}) async {
  if (entry.isImage) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttachmentImageScreen(
          state: state,
          entry: entry,
          conversationId: conversationId,
        ),
      ),
    );
    return;
  }
  if (_opensInOtherApp) {
    await openAttachmentExternally(
      context,
      state,
      entry,
      conversationId: conversationId,
    );
    return;
  }
  await saveAttachmentAs(context, state, entry, conversationId: conversationId);
}

/// Phones hand a decrypted file to whichever app handles its type.
bool get _opensInOtherApp => Platform.isAndroid || Platform.isIOS;

/// The subfolder of the opened-files cache this slot uses (B7): each account
/// slot has its own, so a switch can purge one slot's decrypted copies
/// without touching another's. The primary slot is `primary`.
String _openedScope = 'primary';

void useOpenedFilesScope(String? folder) {
  final clean = (folder ?? '').toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9-]'),
        '',
      );
  _openedScope = clean.isEmpty ? 'primary' : clean;
}

/// Folder in the app cache that holds files decrypted for other apps, for
/// every slot.
Future<Directory> _openedFilesRoot() async {
  final cache = await getTemporaryDirectory();
  return Directory('${cache.path}${Platform.pathSeparator}veritra-open');
}

/// Folder in the app cache that holds this slot's decrypted files.
Future<Directory> openedFilesDirectory() async {
  final root = await _openedFilesRoot();
  return Directory('${root.path}${Platform.pathSeparator}$_openedScope');
}

/// Deletes decrypted files left by earlier opens: every slot's, or with
/// [thisSlotOnly] this slot's (a switch purges the slot it leaves). Call at
/// startup, at every switch and before each open; the viewer app may still
/// be reading the file right after it launches, so a file is never deleted
/// at once.
Future<void> purgeOpenedAttachments({bool thisSlotOnly = false}) async {
  try {
    final directory =
        thisSlotOnly ? await openedFilesDirectory() : await _openedFilesRoot();
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException {
    // Best effort: the cache is cleared by the system.
  } on MissingPluginException {
    // No path provider (a test host).
  }
}

/// How long a decrypted copy stays in the cache once another app has it,
/// when nothing tells us the viewer closed (iOS keeps the app in front).
const Duration _openedFileLifetime = Duration(minutes: 10);

/// Deletes every opened-file copy, in every slot, that is older than
/// [minAge]: the hourly backstop for copies whose viewer never reported
/// closing (D134). Called by the attachment sweep. A copy's age is its
/// folder's, which is set when the copy is made.
Future<void> purgeStaleOpenedCopies(Duration minAge, {DateTime? now}) async {
  final cutoff = (now ?? DateTime.now()).subtract(minAge);
  try {
    final root = await _openedFilesRoot();
    if (!await root.exists()) return;
    await for (final slot in root.list(followLinks: false)) {
      if (slot is! Directory) continue;
      await for (final copy in slot.list(followLinks: false)) {
        if (copy is! Directory) continue;
        try {
          if ((await copy.stat()).modified.isAfter(cutoff)) continue;
          await copy.delete(recursive: true);
        } on FileSystemException {
          // One copy that cannot go must not keep the others.
        }
      }
    }
  } on FileSystemException {
    // The next sweep tries again.
  } on MissingPluginException {
    // No path provider (a test host).
  }
}

/// Where the decrypted copy named [fileName] goes: a new, unguessable folder
/// under [root], so no two opens ever share a path and one copy's expiry can
/// never delete another's.
Future<File> newOpenedCopy(Directory root, String fileName) async {
  final random = Random.secure();
  final id = List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final folder = Directory('${root.path}${Platform.pathSeparator}$id');
  await folder.create(recursive: true);
  return File('${folder.path}${Platform.pathSeparator}$fileName');
}

/// Deletes the folder of [copy] (made by [newOpenedCopy]) once the viewer
/// app that was opened on it is closed: when this app comes back to the
/// front after having been in the background. The [lifetime] timer is the
/// fallback for a viewer that never takes this app out of the front.
///
/// Returns a function that stops watching, for a copy deleted another way.
void Function() deleteCopyWhenViewerCloses(
  File copy, {
  Duration lifetime = _openedFileLifetime,
}) {
  final watcher = _ViewerCloseWatcher(copy);
  WidgetsBinding.instance.addObserver(watcher);
  watcher.timer = expireOpenedCopy(copy, lifetime: lifetime);
  return watcher.stop;
}

class _ViewerCloseWatcher with WidgetsBindingObserver {
  _ViewerCloseWatcher(this.copy);

  final File copy;
  Timer? timer;
  bool _wentAway = false;

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wentAway = true;
    } else if (state == AppLifecycleState.resumed && _wentAway) {
      stop();
      unawaited(deleteOpenedCopy(copy));
    }
  }
}

/// Deletes the folder of [copy], best effort.
Future<void> deleteOpenedCopy(File copy) async {
  try {
    await copy.parent.delete(recursive: true);
  } on FileSystemException {
    // Purged at the next start, or by the hourly sweep, instead.
  }
}

/// Deletes the folder of [copy] (made by [newOpenedCopy]) after [lifetime].
Timer expireOpenedCopy(File copy, {Duration lifetime = _openedFileLifetime}) {
  return Timer(lifetime, () async {
    try {
      await copy.parent.delete(recursive: true);
    } on FileSystemException {
      // Purged at the next start instead.
    }
  });
}

/// Decrypts [entry] straight to a temporary file in the app cache and opens
/// it with the system's handler for its type: `OpenFilex` takes only a path,
/// so another app always needs a file (D134). The copy is deleted when the
/// viewer closes, after [_openedFileLifetime], at the next open, at the next
/// start and by the hourly sweep. Nothing here logs a name or a path.
Future<void> openAttachmentExternally(
  BuildContext context,
  AppState state,
  AttachmentEntry entry, {
  required String conversationId,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  File? created;
  try {
    await purgeOpenedAttachments();
    final directory = await openedFilesDirectory();
    created = await newOpenedCopy(directory, entry.fileName);
    await state.decryptAttachmentToFile(
      entry,
      created.path,
      conversationId: conversationId,
    );
  } catch (_) {
    if (created != null) await deleteOpenedCopy(created);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.attachmentDownloadFailed)),
    );
    return;
  }
  final file = created;
  final stopWatching = deleteCopyWhenViewerCloses(file);
  final OpenResult result;
  try {
    result = await OpenFilex.open(file.path);
  } catch (_) {
    stopWatching();
    await deleteOpenedCopy(file);
    messenger.showSnackBar(SnackBar(content: Text(l10n.attachmentOpenFailed)));
    return;
  }
  if (result.type != ResultType.done) {
    stopWatching();
    await deleteOpenedCopy(file);
    messenger.showSnackBar(SnackBar(content: Text(l10n.attachmentOpenFailed)));
  }
}

/// Decrypts an attachment into a place the user picks.
Future<void> saveAttachmentAs(
  BuildContext context,
  AppState state,
  AttachmentEntry entry, {
  required String conversationId,
}) async {
  if (!_canChooseSaveLocation) {
    _snack(context, context.l10n.attachmentDemoImagesOnly);
    return;
  }
  final location = await getSaveLocation(suggestedName: entry.fileName);
  if (location == null || !context.mounted) return;
  try {
    await state.saveAttachment(
      entry,
      location.path,
      conversationId: conversationId,
    );
    if (context.mounted) {
      _snack(context, context.l10n.attachmentSaved(entry.fileName));
    }
  } catch (_) {
    if (context.mounted) {
      _snack(context, context.l10n.attachmentDownloadFailed);
    }
  }
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// One attachment inside a message bubble.
class AttachmentTile extends StatelessWidget {
  const AttachmentTile({required this.entry, required this.onOpen, super.key});

  final AttachmentEntry entry;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = formatFileSize(context, entry.plaintextSize);
    return Semantics(
      button: onOpen != null,
      // The tile's own tap action: excludeSemantics below drops the InkWell's,
      // and this node must still be activatable by assistive technology.
      onTap: onOpen,
      label: entry.isImage
          ? context.l10n.attachmentImageSemantics(entry.fileName, size)
          : context.l10n.attachmentFileSemantics(entry.fileName, size),
      excludeSemantics: true,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(BoneRadii.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                entry.isImage
                    ? Icons.image_outlined
                    : Icons.insert_drive_file_outlined,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: BoneSpacing.sm),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      entry.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      size,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen viewer for an image attachment, decrypted in memory.
class AttachmentImageScreen extends StatefulWidget {
  const AttachmentImageScreen({
    required this.state,
    required this.entry,
    required this.conversationId,
    super.key,
  });

  final AppState state;
  final AttachmentEntry entry;
  final String conversationId;

  @override
  State<AttachmentImageScreen> createState() => _AttachmentImageScreenState();
}

/// The most pixels an image may declare and still be shown. The bytes come
/// from a peer, and a small file can declare billions of pixels (a
/// decompression bomb); decoding one allocates width x height x 4 bytes. 48
/// million is a 48 MP photo (8000 x 6000), about 190 MB while decoding.
const int maxViewerPixels = 48 * 1000 * 1000;

/// The longest side an image is decoded at. Larger images are decoded
/// smaller, which also bounds memory for the zoomable viewer (4096 x 3072 x 4
/// is about 50 MB). For animated GIF and WebP the cost per frame is bounded
/// the same way; the number of frames is not.
const int maxViewerDecodeSide = 4096;

/// The pixel size an image declares in its header, read without decoding it,
/// or null when [bytes] are not an image the engine can open.
Future<({int width, int height})?> readImageSize(Uint8List bytes) =>
    _declaredSize(() => ui.ImmutableBuffer.fromUint8List(bytes));

/// [readImageSize] for an image in a file, which the engine reads itself.
Future<({int width, int height})?> readImageFileSize(String path) =>
    _declaredSize(() => ui.ImmutableBuffer.fromFilePath(path));

Future<({int width, int height})?> _declaredSize(
  Future<ui.ImmutableBuffer> Function() open,
) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await open();
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (width: descriptor.width, height: descriptor.height);
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// The `cacheWidth` and `cacheHeight` that decode an image of [width] x
/// [height] no larger than [maxViewerDecodeSide] on its longest side, keeping
/// its proportions. Null for both when it already fits.
({int? width, int? height}) viewerDecodeSize(int width, int height) {
  if (max(width, height) <= maxViewerDecodeSide) {
    return (width: null, height: null);
  }
  return width >= height
      ? (width: maxViewerDecodeSide, height: null)
      : (width: null, height: maxViewerDecodeSide);
}

class _LoadedImage {
  const _LoadedImage(this.size, {this.bytes, this.copy});

  /// The decrypted image, for one that opens from memory.
  final Uint8List? bytes;

  /// The temp copy of an image too big for memory (D134).
  final File? copy;
  final ({int width, int height})? size;

  /// Whether it is safe to hand to the decoder.
  bool get showable =>
      size != null &&
      size!.width > 0 &&
      size!.height > 0 &&
      size!.width * size!.height <= maxViewerPixels;

  /// Wipes the bytes and deletes the copy.
  Future<void> discard() async {
    bytes?.fillRange(0, bytes!.length, 0);
    final file = copy;
    if (file != null) await deleteOpenedCopy(file);
  }
}

class _AttachmentImageScreenState extends State<AttachmentImageScreen> {
  late Future<_LoadedImage> _image = _load();
  _LoadedImage? _shown;
  bool _closed = false;

  @override
  void dispose() {
    _closed = true;
    final shown = _shown;
    _shown = null;
    if (shown != null) unawaited(shown.discard());
    super.dispose();
  }

  /// Downloads and decrypts the image, then reads its declared size before
  /// anything decodes it. A small image stays in memory and no file is
  /// written; a big one goes to a temp copy that [dispose] deletes (D134).
  Future<_LoadedImage> _load() async {
    final previous = _shown;
    _shown = null;
    if (previous != null) await previous.discard();
    final _LoadedImage loaded;
    if (widget.entry.opensFromMemory) {
      final bytes = await widget.state.loadAttachment(
        widget.entry,
        conversationId: widget.conversationId,
      );
      loaded = _LoadedImage(await readImageSize(bytes), bytes: bytes);
    } else {
      final root = await openedFilesDirectory();
      final copy = await newOpenedCopy(root, widget.entry.fileName);
      try {
        await widget.state.decryptAttachmentToFile(
          widget.entry,
          copy.path,
          conversationId: widget.conversationId,
        );
        loaded = _LoadedImage(await readImageFileSize(copy.path), copy: copy);
      } catch (_) {
        await deleteOpenedCopy(copy);
        rethrow;
      }
    }
    if (_closed) {
      // The screen was closed while this was loading: nobody will show it.
      await loaded.discard();
      throw StateError('viewer closed');
    }
    _shown = loaded;
    return loaded;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LargeTitleBar(
        title: widget.entry.fileName,
        actions: <Widget>[
          if (_canChooseSaveLocation)
            BarAction(
              label: context.l10n.attachmentSave,
              icon: Icons.download_outlined,
              onPressed: () => saveAttachmentAs(
                context,
                widget.state,
                widget.entry,
                conversationId: widget.conversationId,
              ),
            ),
        ],
      ),
      body: FutureBuilder<_LoadedImage>(
        future: _image,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(context.l10n.attachmentImageFailed),
                  const SizedBox(height: BoneSpacing.md),
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _image = _load();
                    }),
                    child: Text(context.l10n.commonRetry),
                  ),
                ],
              ),
            );
          }
          final loaded = snapshot.data;
          if (loaded == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!loaded.showable) {
            return Center(child: Text(context.l10n.attachmentImageUnshowable));
          }
          final decode = viewerDecodeSize(
            loaded.size!.width,
            loaded.size!.height,
          );
          return InteractiveViewer(
            child: Center(
              child: loaded.bytes != null
                  ? Image.memory(
                      loaded.bytes!,
                      cacheWidth: decode.width,
                      cacheHeight: decode.height,
                      semanticLabel: widget.entry.fileName,
                      errorBuilder: (context, _, __) =>
                          Text(context.l10n.attachmentImageUnshowable),
                    )
                  : Image.file(
                      loaded.copy!,
                      cacheWidth: decode.width,
                      cacheHeight: decode.height,
                      semanticLabel: widget.entry.fileName,
                      errorBuilder: (context, _, __) =>
                          Text(context.l10n.attachmentImageUnshowable),
                    ),
            ),
          );
        },
      ),
    );
  }
}
