import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/passkeys.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import 'reauth_dialog.dart';

/// B7: the account's passkeys. Adding and removing one asks for the password
/// first (a passkey never counts as recent authentication); renaming does not.
class PasskeysScreen extends StatefulWidget {
  const PasskeysScreen({required this.state, super.key});

  final AppState state;

  @override
  State<PasskeysScreen> createState() => _PasskeysScreenState();
}

class _PasskeysScreenState extends State<PasskeysScreen> {
  bool? _offered;

  @override
  void initState() {
    super.initState();
    widget.state.dismissPasskeyNotice();
    _load();
  }

  Future<void> _load() async {
    final info = await widget.state.signedInPasskeyInfo();
    if (!mounted) return;
    setState(() => _offered = info != null);
    if (info != null) await widget.state.refreshPasskeys();
  }

  Future<void> _add() async {
    final state = widget.state;
    final l10n = context.l10n;
    final name = suggestPasskeyName(l10n.passkeyNamePrefix, state.passkeyList);
    if (!await confirmPasswordForRecentAuth(context, state)) return;
    if (!mounted) return;
    final added = await state.addPasskey(name);
    if (!mounted) return;
    if (added) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.passkeysAdded)));
    }
  }

  Future<void> _remove(PasskeyRecord passkey) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.passkeyRemoveTitle),
        content: Text(l10n.passkeyRemoveBody(passkey.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.passkeyRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!await confirmPasswordForRecentAuth(context, widget.state)) return;
    if (!mounted) return;
    if (await widget.state.removePasskey(passkey.id) && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.passkeyRemoved)));
    }
  }

  Future<void> _rename(PasskeyRecord passkey) async {
    final l10n = context.l10n;
    final controller = TextEditingController(text: passkey.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.passkeyRename),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          decoration: InputDecoration(labelText: l10n.passkeyNameLabel),
          onSubmitted: (value) => Navigator.of(dialog).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(controller.text),
            child: Text(l10n.commonContinue),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == passkey.name) return;
    if (!mounted) return;
    await widget.state.renamePasskey(passkey.id, trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsPasskeys)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) {
            final state = widget.state;
            final error = state.errorFor(Ops.passkeys);
            return ListView(
              padding: const EdgeInsets.all(BoneSpacing.gutter),
              children: <Widget>[
                Text(l10n.passkeysIntro),
                const SizedBox(height: BoneSpacing.lg),
                if (_offered == false)
                  Text(l10n.passkeysNotOffered, key: const ValueKey('off'))
                else if (_offered == true) ...<Widget>[
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: BoneSpacing.md),
                      child: Text(error,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ),
                  if (state.passkeysLoaded && state.passkeyList.isEmpty)
                    Text(l10n.passkeysEmpty),
                  for (final passkey in state.passkeyList)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.fingerprint),
                      title: Text(passkey.name),
                      subtitle: Text(<String>[
                        l10n.passkeyCreated(formatDateTime(
                            context, passkey.createdAt.toLocal())),
                        if (passkey.lastUsedAt != null)
                          l10n.passkeyLastUsed(formatDateTime(
                              context, passkey.lastUsedAt!.toLocal())),
                        if (passkey.synced) l10n.passkeyBackedUp,
                      ].join(' · ')),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) => value == 'rename'
                            ? _rename(passkey)
                            : _remove(passkey),
                        itemBuilder: (_) => <PopupMenuEntry<String>>[
                          PopupMenuItem<String>(
                              value: 'rename', child: Text(l10n.passkeyRename)),
                          PopupMenuItem<String>(
                              value: 'remove', child: Text(l10n.passkeyRemove)),
                        ],
                      ),
                    ),
                  const SizedBox(height: BoneSpacing.lg),
                  FilledButton.icon(
                    key: const ValueKey<String>('passkeys-add'),
                    onPressed:
                        state.isBusy(Ops.passkeys) || state.busy ? null : _add,
                    icon: const Icon(Icons.add),
                    label: Text(l10n.passkeysAdd),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
