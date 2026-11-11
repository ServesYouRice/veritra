import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart' show getDirectoryPath;
import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/k1_backup.dart';
import '../../core/k1_second_copy.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/tile_group.dart';
import 'k1_restore_screen.dart';
import 'recovery_key_screen.dart';

/// The status line of K1 automatic backups, for the settings tile and the
/// screen below.
String autoBackupStatusText(BuildContext context, AppState state) {
  final l10n = context.l10n;
  switch (state.k1BackupView) {
    case K1BackupView.unknown:
      return l10n.recoveryKeyStatusUnknown;
    case K1BackupView.serverOff:
      return l10n.autoBackupServerOff;
    case K1BackupView.noKey:
      return l10n.autoBackupNoKey;
    case K1BackupView.needsKeyHere:
      return state.k1BackupState?.lastError == K1BackupError.keyChanged
          ? l10n.autoBackupKeyChanged
          : l10n.autoBackupNeedsKeyHere;
    case K1BackupView.on:
      final backup = state.k1BackupState;
      final error = backup?.lastError;
      if (error != null) return autoBackupErrorText(l10n, error);
      final last = backup?.lastSuccessAt;
      return last == null
          ? l10n.autoBackupPending
          : l10n.autoBackupLast(formatDateTime(context, last.toLocal()));
  }
}

String autoBackupErrorText(AppLocalizations l10n, K1BackupError error) =>
    switch (error) {
      K1BackupError.network => l10n.autoBackupErrorNetwork,
      K1BackupError.spaceFull => l10n.autoBackupErrorSpace,
      K1BackupError.tooLarge => l10n.autoBackupErrorTooLarge,
      K1BackupError.keyChanged => l10n.autoBackupKeyChanged,
      K1BackupError.unavailable => l10n.autoBackupServerOff,
      K1BackupError.failed => l10n.autoBackupErrorFailed,
    };

/// K1 automatic backups (K1-3): status, "Back up now", and on a device that
/// was not given the key, "Type recovery key".
class AutoBackupScreen extends StatelessWidget {
  const AutoBackupScreen({required this.state, this.isPhone, super.key});

  final AppState state;

  /// Phones back up only when the app is opened (D91); null reads the
  /// platform.
  final bool? isPhone;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final phone = isPhone ?? (Platform.isAndroid || Platform.isIOS);
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.autoBackupTitle),
      body: AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final view = state.k1BackupView;
          final backup = state.k1BackupState;
          final last = backup?.lastSuccessAt;
          final running = state.k1BackupRunning;
          return ListView(
            padding: const EdgeInsets.all(BoneSpacing.gutter),
            children: <Widget>[
              Text(phone ? l10n.autoBackupIntroPhone : l10n.autoBackupIntro),
              const SizedBox(height: BoneSpacing.md),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    key: const ValueKey<String>('auto-backup-status'),
                    leading: Icon(state.k1BackupNeedsAttention
                        ? Icons.warning_amber_outlined
                        : Icons.cloud_done_outlined),
                    title: Text(autoBackupStatusText(context, state)),
                    subtitle: view == K1BackupView.on &&
                            backup?.lastError != null &&
                            last != null
                        ? Text(l10n.autoBackupLast(
                            formatDateTime(context, last.toLocal())))
                        : null,
                  ),
                  if (state.k1BackupStale)
                    ListTile(
                      leading: const Icon(Icons.history_toggle_off),
                      title: Text(l10n.autoBackupStale),
                    ),
                ],
              ),
              if (view == K1BackupView.on && phone) ...<Widget>[
                const SizedBox(height: BoneSpacing.sm),
                Text(l10n.autoBackupPhoneNote,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: BoneSpacing.md),
              if (view == K1BackupView.on)
                FilledButton(
                  key: const ValueKey<String>('auto-backup-now'),
                  onPressed: running
                      ? null
                      : () => state.runK1BackupIfDue(force: true),
                  child: Text(
                      running ? l10n.autoBackupRunning : l10n.autoBackupNow),
                ),
              if (view == K1BackupView.needsKeyHere)
                FilledButton(
                  key: const ValueKey<String>('auto-backup-type-key'),
                  onPressed: () => _typeKey(context),
                  child: Text(l10n.autoBackupTypeKey),
                ),
              if (state.k1ConfirmDue || state.k1ConfirmBadge) ...<Widget>[
                const SizedBox(height: BoneSpacing.md),
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      key: const ValueKey<String>('auto-backup-confirm'),
                      leading: const Icon(Icons.key_outlined),
                      title: Text(l10n.k1ConfirmTitle),
                      subtitle: Text(l10n.k1ConfirmDetail),
                      onTap: () => _confirmKey(context),
                    ),
                    if (state.k1ConfirmDue)
                      ListTile(
                        key:
                            const ValueKey<String>('auto-backup-confirm-later'),
                        leading: const Icon(Icons.schedule),
                        title: Text(l10n.autoBackupPromptLater),
                        onTap: state.postponeK1Confirm,
                      ),
                  ],
                ),
              ],
              if (view == K1BackupView.on) ..._secondCopy(context, backup),
              if (state.k1RestoreSupported) ...<Widget>[
                const SizedBox(height: BoneSpacing.sm),
                OutlinedButton(
                  key: const ValueKey<String>('auto-backup-restore'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => K1RestoreScreen(state: state),
                    ),
                  ),
                  child: Text(l10n.k1RestoreOpen),
                ),
              ],
              if (view == K1BackupView.noKey)
                FilledButton(
                  key: const ValueKey<String>('auto-backup-create-key'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RecoveryKeyScreen(state: state),
                    ),
                  ),
                  child: Text(l10n.recoveryKeyCreate),
                ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _secondCopy(BuildContext context, K1BackupState? backup) {
    final l10n = context.l10n;
    if (!k1SecondCopySupported) {
      return <Widget>[
        const SizedBox(height: BoneSpacing.md),
        Text(l10n.k1SecondCopyPhone,
            style: Theme.of(context).textTheme.bodySmall),
      ];
    }
    final path = backup?.secondCopyPath;
    final at = backup?.secondCopyAt;
    return <Widget>[
      const SizedBox(height: BoneSpacing.md),
      TileGroup(
        children: <Widget>[
          ListTile(
            key: const ValueKey<String>('auto-backup-second-copy'),
            leading: Icon(backup?.secondCopyFailed == true
                ? Icons.warning_amber_outlined
                : Icons.folder_copy_outlined),
            title: Text(path == null
                ? l10n.k1SecondCopyChoose
                : l10n.k1SecondCopyFolder(path)),
            subtitle: backup?.secondCopyFailed == true
                ? Text(l10n.k1SecondCopyFailed)
                : at != null
                    ? Text(l10n
                        .autoBackupLast(formatDateTime(context, at.toLocal())))
                    : Text(l10n.k1SecondCopyDetail),
            onTap: () async {
              final folder = await getDirectoryPath();
              if (folder != null) await state.setK1SecondCopyFolder(folder);
            },
          ),
          if (path != null)
            ListTile(
              key: const ValueKey<String>('auto-backup-second-copy-off'),
              leading: const Icon(Icons.close),
              title: Text(l10n.k1SecondCopyOff),
              onTap: () => state.setK1SecondCopyFolder(null),
            ),
        ],
      ),
    ];
  }

  Future<void> _confirmKey(BuildContext context) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final typed = await showDialog<String>(
      context: context,
      builder: (_) => const RecoveryKeyTypeDialog(),
    );
    if (typed == null || typed.trim().isEmpty) return;
    final ok = await state.confirmK1Key(typed);
    messenger.showSnackBar(SnackBar(
        content: Text(ok ? l10n.k1ConfirmOk : l10n.k1ConfirmMismatch)));
  }

  Future<void> _typeKey(BuildContext context) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final typed = await showDialog<String>(
      context: context,
      builder: (_) => const RecoveryKeyTypeDialog(),
    );
    if (typed == null || typed.trim().isEmpty) return;
    final ok = await state.enableK1BackupsWithKey(typed);
    messenger.showSnackBar(SnackBar(
        content: Text(ok ? l10n.autoBackupKeyOn : l10n.autoBackupKeyWrong)));
  }
}

/// Asks for the recovery key. The typed text cannot be wiped from a Dart
/// string; the field is cleared when the dialog goes (best effort, K0).
class RecoveryKeyTypeDialog extends StatefulWidget {
  const RecoveryKeyTypeDialog();

  @override
  State<RecoveryKeyTypeDialog> createState() => RecoveryKeyTypeDialogState();
}

class RecoveryKeyTypeDialogState extends State<RecoveryKeyTypeDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.recoveryKeyConfirmTitle),
      content: TextField(
        key: const ValueKey<String>('auto-backup-key-field'),
        controller: _controller,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        keyboardType: TextInputType.visiblePassword,
        textCapitalization: TextCapitalization.characters,
        minLines: 2,
        maxLines: 4,
        style: BoneType.mono,
        decoration: InputDecoration(labelText: l10n.recoveryKeyField),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey<String>('auto-backup-key-submit'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.autoBackupTypeKey),
        ),
      ],
    );
  }
}
