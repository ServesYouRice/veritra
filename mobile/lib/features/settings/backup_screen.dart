import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import '../../ui/confirm.dart';
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
          appBar: LargeTitleBar(title: context.l10n.settingsBackup),
          body: ListView(
            padding: const EdgeInsets.all(BoneSpacing.gutter),
            children: <Widget>[
              Text(
                context.l10n.backupIntro,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: BoneSpacing.lg),
              SectionHeader(context.l10n.backupSectionStatus),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.cloud_done_outlined),
                    title: Text(
                      last == null
                          ? context.l10n.backupNone
                          : context.l10n.backupLast(
                              formatDateTime(context, last.toLocal()),
                            ),
                    ),
                    subtitle: Text(context.l10n.backupReplacesPrevious),
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
                label: Text(
                  last == null
                      ? context.l10n.backupMake
                      : context.l10n.backupMakeNew,
                ),
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
    // A new backup replaces the previous one and its recovery code stops
    // working, so replacing an existing backup is confirmed first.
    if (widget.state.lastBackupAt != null) {
      final confirmed = await confirmAction(
        context,
        title: context.l10n.backupReplaceTitle,
        message: context.l10n.backupReplaceMessage,
        confirmLabel: context.l10n.backupReplaceConfirm,
        destructive: true,
      );
      if (!confirmed || !context.mounted) return;
    }
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
      title: Text(context.l10n.backupSaveCodeTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(context.l10n.backupSaveCodeMessage),
          const SizedBox(height: BoneSpacing.md),
          SelectableText(code, style: BoneType.mono),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: code)),
          child: Text(context.l10n.commonCopy),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.backupSavedIt),
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
          title: Text(context.l10n.connectRestoreBackup),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(context.l10n.backupRestoreMessage),
              const SizedBox(height: BoneSpacing.md),
              TextField(
                controller: code,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                style: BoneType.mono,
                decoration: InputDecoration(
                  labelText: context.l10n.backupRecoveryCode,
                ),
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
              child: Text(context.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: busy ? null : _restore,
              child: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(context.l10n.backupRestore),
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
