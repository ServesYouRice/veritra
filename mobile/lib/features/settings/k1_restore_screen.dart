import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/k1_restore.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/tile_group.dart';
import 'auto_backup_screen.dart' show RecoveryKeyTypeDialog;

/// K1-4: restore history from an automatic backup made by another device of
/// this account. The list is the server's; the typed recovery key and the
/// container's own header are what the restore trusts.
class K1RestoreScreen extends StatefulWidget {
  const K1RestoreScreen({required this.state, this.onRestored, super.key});

  final AppState state;

  /// Called after a restore finished (the forced follow-up goes on).
  final Future<void> Function()? onRestored;

  @override
  State<K1RestoreScreen> createState() => _K1RestoreScreenState();
}

class _K1RestoreScreenState extends State<K1RestoreScreen> {
  List<K1BackupEntry>? _entries;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await widget.state.loadK1RestoreList();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  String _resultText(K1RestoreResult result) {
    final l10n = context.l10n;
    return switch (result) {
      K1RestoreResult.done => l10n.k1RestoreDone,
      K1RestoreResult.wrongKey => l10n.k1RestoreWrongKey,
      K1RestoreResult.otherKey => l10n.k1RestoreOtherKey,
      K1RestoreResult.corrupt => l10n.k1RestoreCorrupt,
      K1RestoreResult.network => l10n.k1RestoreNetwork,
      K1RestoreResult.unavailable => l10n.k1RestoreUnavailable,
    };
  }

  Future<void> _restore(K1BackupEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    final typed = await showDialog<String>(
      context: context,
      builder: (_) => const RecoveryKeyTypeDialog(),
    );
    if (typed == null || typed.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    final result = await widget.state.restoreFromK1Backup(entry, typed);
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(content: Text(_resultText(result))));
    if (result == K1RestoreResult.done) {
      await widget.onRestored?.call();
      if (mounted && widget.onRestored != null) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = _entries;
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.k1RestoreTitle),
      body: ListView(
        padding: const EdgeInsets.all(BoneSpacing.gutter),
        children: <Widget>[
          Text(l10n.k1RestoreIntro),
          const SizedBox(height: BoneSpacing.md),
          if (_loading)
            Text(l10n.k1RestoreLoading)
          else if (entries == null)
            Text(l10n.k1RestoreLoadFailed,
                key: const ValueKey<String>('k1-restore-load-failed'))
          else if (entries.isEmpty)
            Text(l10n.k1RestoreEmpty,
                key: const ValueKey<String>('k1-restore-empty'))
          else
            TileGroup(
              children: <Widget>[
                for (final entry in entries)
                  ListTile(
                    key: ValueKey<String>('k1-restore-${entry.id}'),
                    leading: const Icon(Icons.cloud_download_outlined),
                    enabled: !_busy,
                    title: Text(_entryTitle(context, entry)),
                    subtitle: entry.deviceRevoked
                        ? Text(l10n.k1RestoreDeviceRevoked)
                        : null,
                    onTap: _busy ? null : () => _restore(entry),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String _entryTitle(BuildContext context, K1BackupEntry entry) {
    final l10n = context.l10n;
    final device = entry.deviceName.isEmpty
        ? l10n.k1RestoreDeviceUnnamed
        : entry.deviceName;
    final date = formatDateTime(context, entry.createdAt.toLocal());
    return entry.superseded
        ? l10n.k1RestoreEntryPrevious(device, date)
        : l10n.k1RestoreEntry(device, date);
  }
}
