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
  await saveAttachmentAs(
    context,
    state,
    entry,
    conversationId: conversationId,
  );
}

/// Phones hand a decrypted file to whichever app handles its type.
bool get _opensInOtherApp => Platform.isAndroid || Platform.isIOS;

/// Folder in the app cache that holds files decrypted for other apps.
Future<Directory> _openedFilesDirectory() async {
  final cache = await getTemporaryDirectory();
  return Directory('${cache.path}${Platform.pathSeparator}veritra-open');
}

/// Deletes decrypted files left by earlier opens. Call at startup, and
/// before each open; the viewer app may still be reading the file right
/// after it launches, so a file is never deleted at once.
Future<void> purgeOpenedAttachments() async {
  try {
    final directory = await _openedFilesDirectory();
    if (await directory.exists()) await directory.delete(recursive: true);
  } on FileSystemException {
    // Best effort: the cache is cleared by the system.
  } on MissingPluginException {
    // No path provider (a test host).
  }
}

/// How long a decrypted copy stays in the cache once another app has it.
const Duration _openedFileLifetime = Duration(minutes: 10);

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

/// Deletes the folder of [copy] (made by [newOpenedCopy]) after [lifetime].
Timer expireOpenedCopy(
  File copy, {
  Duration lifetime = _openedFileLifetime,
}) {
  return Timer(lifetime, () async {
    try {
      await copy.parent.delete(recursive: true);
    } on FileSystemException {
      // Purged at the next start instead.
    }
  });
}

/// Decrypts [entry] to a temporary file in the app cache and opens it with
/// the system's handler for its type. The copy is deleted after
/// [_openedFileLifetime], at the next open and at the next start.
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
    final directory = await _openedFilesDirectory();
    created = await newOpenedCopy(directory, entry.fileName);
    await state.saveAttachment(
      entry,
      created.path,
      conversationId: conversationId,
    );
  } catch (_) {
    if (created != null) {
      try {
        await created.parent.delete(recursive: true);
      } on FileSystemException {
        // Purged at the next start instead.
      }
    }
    messenger
        .showSnackBar(SnackBar(content: Text(l10n.attachmentDownloadFailed)));
    return;
  }
  final file = created;
  expireOpenedCopy(file);
  final OpenResult result;
  try {
    result = await OpenFilex.open(file.path);
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.attachmentOpenFailed)));
    return;
  }
  if (result.type != ResultType.done) {
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
Future<({int width, int height})?> readImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
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
  const _LoadedImage(this.bytes, this.size);

  final Uint8List bytes;
  final ({int width, int height})? size;

  /// Whether it is safe to hand to the decoder.
  bool get showable =>
      size != null &&
      size!.width > 0 &&
      size!.height > 0 &&
      size!.width * size!.height <= maxViewerPixels;
}

class _AttachmentImageScreenState extends State<AttachmentImageScreen> {
  late Future<_LoadedImage> _image = _load();

  /// Downloads and decrypts the image, then reads its declared size before
  /// anything decodes it.
  Future<_LoadedImage> _load() async {
    final bytes = await widget.state.loadAttachment(
      widget.entry,
      conversationId: widget.conversationId,
    );
    return _LoadedImage(bytes, await readImageSize(bytes));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LargeTitleBar(
        title: widget.entry.fileName,
        actions: <Widget>[
          if (_canChooseSaveLocation)
            IconButton(
              tooltip: context.l10n.attachmentSave,
              icon: const Icon(Icons.download_outlined),
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
              child: Image.memory(
                loaded.bytes,
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
