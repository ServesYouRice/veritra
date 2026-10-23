import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/attachments.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../l10n/l10n.dart';

/// Whether this platform can offer a "save as" dialog.
bool get _canChooseSaveLocation =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Asks for a file and sends it as an encrypted attachment. Shows a
/// confirmation first, since the file leaves the device once sent.
Future<void> pickAndSendAttachment(
  BuildContext context,
  AppState state,
  String conversationId,
) async {
  final XFile? file;
  try {
    file = await openFile();
  } catch (_) {
    if (context.mounted) {
      _snack(context, context.l10n.attachmentPickUnavailable);
    }
    return;
  }
  if (file == null || !context.mounted) return;
  final size = await file.length();
  if (!context.mounted) return;
  final name = safeAttachmentName(file.name);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.attachmentSendTitle),
      content: Text(
        context.l10n.attachmentSendMessage(name, formatFileSize(context, size)),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.l10n.attachmentSend),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final sent = await state.sendAttachment(
    conversationId,
    path: file.path,
    fileName: file.name,
    mediaType: file.mimeType,
  );
  if (!sent && context.mounted) {
    _snack(
      context,
      state.errorFor(Ops.attachment) ?? context.l10n.attachmentSendFailed,
    );
  }
}

/// Opens an attachment: images in a viewer, other files through a save
/// dialog where the platform has one.
Future<void> openAttachment(
  BuildContext context,
  AppState state,
  AttachmentEntry entry,
) async {
  if (entry.isImage) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttachmentImageScreen(state: state, entry: entry),
      ),
    );
    return;
  }
  await saveAttachmentAs(context, state, entry);
}

/// Decrypts an attachment into a place the user picks.
Future<void> saveAttachmentAs(
  BuildContext context,
  AppState state,
  AttachmentEntry entry,
) async {
  if (!_canChooseSaveLocation) {
    _snack(context, context.l10n.attachmentDemoImagesOnly);
    return;
  }
  final location = await getSaveLocation(suggestedName: entry.fileName);
  if (location == null || !context.mounted) return;
  try {
    await state.saveAttachment(entry, location.path);
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
    super.key,
  });

  final AppState state;
  final AttachmentEntry entry;

  @override
  State<AttachmentImageScreen> createState() => _AttachmentImageScreenState();
}

class _AttachmentImageScreenState extends State<AttachmentImageScreen> {
  late Future<Uint8List> _bytes = widget.state.loadAttachment(widget.entry);

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
              onPressed: () =>
                  saveAttachmentAs(context, widget.state, widget.entry),
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
                      _bytes = widget.state.loadAttachment(widget.entry);
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
