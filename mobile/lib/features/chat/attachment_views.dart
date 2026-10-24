import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
  final File file;
  try {
    await purgeOpenedAttachments();
    final directory = await _openedFilesDirectory();
    await directory.create(recursive: true);
    file = File('${directory.path}${Platform.pathSeparator}${entry.fileName}');
    await state.saveAttachment(
      entry,
      file.path,
      conversationId: conversationId,
    );
  } catch (_) {
    messenger
        .showSnackBar(SnackBar(content: Text(l10n.attachmentDownloadFailed)));
    return;
  }
  Timer(_openedFileLifetime, () async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Purged at the next start instead.
    }
  });
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

class _AttachmentImageScreenState extends State<AttachmentImageScreen> {
  late Future<Uint8List> _bytes = widget.state.loadAttachment(
    widget.entry,
    conversationId: widget.conversationId,
  );

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
      body: FutureBuilder<Uint8List>(
        future: _bytes,
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
                      _bytes = widget.state.loadAttachment(
                        widget.entry,
                        conversationId: widget.conversationId,
                      );
                    }),
                    child: Text(context.l10n.commonRetry),
                  ),
                ],
              ),
            );
          }
          final bytes = snapshot.data;
          if (bytes == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return InteractiveViewer(
            child: Center(
              child: Image.memory(
                bytes,
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
