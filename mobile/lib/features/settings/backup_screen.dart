import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/tile_group.dart';

/// Encrypted backup of this device (card I45). The backup is encrypted on
/// the device; the recovery code that opens it is shown once and never sent
/// to the server or kept by the app.
class BackupScreen extends StatefulWidget {
  const BackupScreen({required this.state, super.key});

  final AppState state;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() {
      if (mounted) widget.state.refreshBackupStatus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final last = state.lastBackupAt;
        final busy = state.isBusy(Ops.backup);
        final error = state.errorFor(Ops.backup);
        return Scaffold(
          appBar: const LargeTitleBar(title: 'Encrypted backup'),
          body: ListView(
            padding: const EdgeInsets.all(BoneSpacing.gutter),
            children: <Widget>[
              Text(
                'A backup holds this device\'s keys and message history, '
                'encrypted on this device. The server stores it but cannot '
                'read it. Restoring it on a new device needs the recovery '
                'code shown when you make it.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: BoneSpacing.lg),
              const SectionHeader('Status'),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.cloud_done_outlined),
                    title: Text(last == null
                        ? 'No backup from this device yet'
                        : 'Last backup ${formatDateTime(context, last.toLocal())}'),
                    subtitle: const Text(
                        'A new backup replaces the previous one and its code.'),
                  ),
                ],
              ),
              const SizedBox(height: BoneSpacing.lg),
              FilledButton.icon(
                onPressed: busy ? null : () => _create(context),
                icon: busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.backup_outlined),
                label:
                    Text(last == null ? 'Make a backup' : 'Make a new backup'),
              ),
              if (error != null) ...<Widget>[
                const SizedBox(height: BoneSpacing.md),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _create(BuildContext context) async {
    final code = await widget.state.createBackup();
    if (code == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RecoveryCodeDialog(code: code),
    );
  }
}

class _RecoveryCodeDialog extends StatelessWidget {
  const _RecoveryCodeDialog({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save your recovery code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Anyone with this code can restore your messages. Keep it '
            'somewhere safe and offline. It is shown only now, and it stops '
            'working after it is used or when you make a new backup.',
          ),
          const SizedBox(height: BoneSpacing.md),
          SelectableText(code, style: BoneType.mono),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: code)),
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('I saved it'),
        ),
      ],
    );
  }
}

/// Asks for a recovery code and restores that backup onto this empty
/// device (card I45).
Future<void> showRestoreBackupDialog(BuildContext context, AppState state) =>
    showDialog<void>(
      context: context,
      builder: (context) => _RestoreBackupDialog(state: state),
    );

class _RestoreBackupDialog extends StatefulWidget {
  const _RestoreBackupDialog({required this.state});

  final AppState state;

  @override
  State<_RestoreBackupDialog> createState() => _RestoreBackupDialogState();
}

class _RestoreBackupDialogState extends State<_RestoreBackupDialog> {
  final code = TextEditingController();

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final busy = widget.state.isBusy(Ops.restore);
        final error = widget.state.errorFor(Ops.restore);
        return AlertDialog(
          title: const Text('Restore from a backup'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'This device takes the place of the one that made the '
                'backup. Stop using that device first.',
              ),
              const SizedBox(height: BoneSpacing.md),
              TextField(
                controller: code,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                style: BoneType.mono,
                decoration: const InputDecoration(labelText: 'Recovery code'),
              ),
              if (error != null) ...<Widget>[
                const SizedBox(height: BoneSpacing.md),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: busy ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy ? null : _restore,
              child: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Restore'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _restore() async {
    final ok = await widget.state.restoreFromBackup(code.text);
    if (ok && mounted) Navigator.of(context).pop();
  }
}
