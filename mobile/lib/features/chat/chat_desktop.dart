import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';
import 'composer_attachments.dart';

/// Windows, Linux and macOS: where files are dropped, keys are physical and
/// the secondary mouse button opens menus.
bool get isDesktopPlatform =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Keyboard shortcuts of the open chat (W9): Esc backs out of a reply, then
/// out of the chat; Ctrl+F (Cmd+F on macOS) opens search. Esc is ignored
/// while a dialog or menu is open, since those take focus first.
class ChatShortcuts extends StatelessWidget {
  const ChatShortcuts({
    required this.onEscape,
    required this.onSearch,
    required this.child,
    super.key,
  });

  final VoidCallback onEscape;
  final VoidCallback onSearch;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): onEscape,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): onSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): onSearch,
      },
      child: child,
    );
  }
}

/// Lets files be dropped anywhere on the chat on desktop, with a hint while
/// a drag is over it. Elsewhere it is transparent.
class ChatDropZone extends StatefulWidget {
  const ChatDropZone({
    required this.enabled,
    required this.onFiles,
    required this.child,
    super.key,
  });

  final bool enabled;
  final void Function(List<XFile> files) onFiles;
  final Widget child;

  @override
  State<ChatDropZone> createState() => _ChatDropZoneState();
}

class _ChatDropZoneState extends State<ChatDropZone> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) {
        setState(() => _hovering = false);
        if (details.files.isNotEmpty) {
          widget.onFiles(<XFile>[
            for (final item in details.files) XFile(item.path, name: item.name),
          ]);
        }
      },
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: widget.child),
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.85),
                    border: Border.all(color: scheme.primary, width: 2),
                    borderRadius: BorderRadius.circular(BoneRadii.md),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.attach_file),
                        const SizedBox(width: BoneSpacing.sm),
                        Text(context.l10n.attachmentDropHint),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Reads files from the system clipboard, else an image. Returns what was
/// found, or an empty list when the clipboard holds neither, or holds plain
/// text: Office-style apps put a bitmap next to the text they copy, and the
/// person who pressed Ctrl+V wants the text. Files still come first.
///
/// The readers default to the system clipboard; tests replace them. Pasted
/// image bytes are written to a private cache file, which the caller passes on
/// as temporary.
Future<({List<XFile> files, Set<String> temporary})> readClipboardFiles({
  Future<List<String>> Function()? readFiles,
  Future<String?> Function()? readText,
  Future<Uint8List?> Function()? readImage,
  Future<XFile> Function(Uint8List bytes)? storeImage,
}) async {
  try {
    final paths = await (readFiles ?? Pasteboard.files)();
    if (paths.isNotEmpty) {
      return (
        files: <XFile>[for (final path in paths) XFile(path)],
        temporary: const <String>{},
      );
    }
    if (await _clipboardHasText(readText)) {
      return (files: const <XFile>[], temporary: const <String>{});
    }
    final image = await (readImage ?? () => Pasteboard.image)();
    if (image != null && image.isNotEmpty) {
      final file = await (storeImage ?? writePastedImage)(image);
      return (files: <XFile>[file], temporary: <String>{file.path});
    }
  } catch (_) {
    // No clipboard plugin or an unreadable clipboard: fall back to text.
  }
  return (files: const <XFile>[], temporary: const <String>{});
}

/// Whether the clipboard holds text other than whitespace. A clipboard whose
/// text cannot be read counts as having none, so an image can still be pasted.
Future<bool> _clipboardHasText(Future<String?> Function()? readText) async {
  try {
    final String? text;
    if (readText != null) {
      text = await readText();
    } else {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    }
    return text != null && text.trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Wraps the composer's text field so that Ctrl+V / Cmd+V attaches files and
/// images from the clipboard, and still pastes text as before when the
/// clipboard holds none. Desktop only.
class PasteFilesInterceptor extends StatelessWidget {
  const PasteFilesInterceptor({
    required this.onPaste,
    required this.child,
    super.key,
  });

  /// Gets the pasted files; returns false when there were none.
  final Future<bool> Function() onPaste;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return child;
    return Actions(
      actions: <Type, Action<Intent>>{
        PasteTextIntent: _PasteFilesAction(onPaste),
      },
      child: child,
    );
  }
}

class _PasteFilesAction extends Action<PasteTextIntent> {
  _PasteFilesAction(this.onPaste);

  final Future<bool> Function() onPaste;

  @override
  Object? invoke(PasteTextIntent intent) async {
    // callingAction is only set during this synchronous call.
    final textPaste = callingAction;
    if (await onPaste()) return null;
    return textPaste?.invoke(intent);
  }
}
