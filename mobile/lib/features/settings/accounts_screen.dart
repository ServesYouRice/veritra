import 'package:flutter/material.dart';

import '../../core/account_host.dart';
import '../../l10n/l10n.dart';
import '../../storage/account_slots.dart';
import '../../ui/tokens.dart';

/// B7: the accounts on this device. One account is open at a time; the others
/// are paused. Switching tears the open account down completely first.
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({required this.host, super.key});

  final AccountHost host;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.accountsTitle)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: host,
          builder: (context, _) {
            final registry = host.registry;
            final slots = registry.slots
                .where((s) => s.state != SlotState.removing)
                .toList();
            final sharedServer = <String>{};
            final seen = <String>{};
            for (final slot in slots) {
              final origin = slot.origin;
              if (origin != null && !seen.add(origin)) sharedServer.add(origin);
            }
            return Stack(
              children: <Widget>[
                ListView(
                  padding: const EdgeInsets.all(BoneSpacing.gutter),
                  children: <Widget>[
                    Text(l10n.accountsIntro),
                    const SizedBox(height: BoneSpacing.lg),
                    if (host.error != null)
                      _Notice(message: _errorText(context, host.error!)),
                    if (host.duplicateAccount)
                      _Notice(message: l10n.accountsDuplicate),
                    for (final slot in slots) _SlotTile(host: host, slot: slot),
                    if (sharedServer.isNotEmpty) ...<Widget>[
                      const SizedBox(height: BoneSpacing.md),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(Icons.info_outline, size: 18),
                          const SizedBox(width: BoneSpacing.sm),
                          Expanded(
                              child: Text(l10n.accountsSameServer,
                                  key: const ValueKey('same-server'))),
                        ],
                      ),
                    ],
                    const SizedBox(height: BoneSpacing.lg),
                    FilledButton.icon(
                      key: const ValueKey<String>('accounts-add'),
                      onPressed: host.switching || !host.canAdd
                          ? null
                          : () => _add(context),
                      icon: const Icon(Icons.person_add_alt_outlined),
                      label: Text(l10n.accountsAdd),
                    ),
                    if (!host.canAdd)
                      Padding(
                        padding: const EdgeInsets.only(top: BoneSpacing.sm),
                        child: Text(l10n.accountsFull('$maxAccountSlots'),
                            key: const ValueKey('cap-note')),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _errorText(BuildContext context, AccountHostError error) {
    final l10n = context.l10n;
    switch (error) {
      case AccountHostError.full:
        return l10n.accountsFull('$maxAccountSlots');
      case AccountHostError.registry:
        return l10n.accountsErrorRegistry;
      case AccountHostError.openFailed:
        return l10n.accountsErrorOpen;
      case AccountHostError.removeFailed:
        return l10n.accountsErrorRemove;
    }
  }

  Future<void> _add(BuildContext context) async {
    final navigator = Navigator.of(context);
    final outcome = await host.beginAdd();
    if (outcome == SwitchOutcome.needsConfirmation && context.mounted) {
      final name = _label(context, host.activeSlot);
      if (await confirmPushFailure(context, name)) {
        await host.beginAdd(acceptPushFailure: true);
      }
    }
    // The new account's connect screen is the root; leave the settings route.
    if (host.activeSlot?.state == SlotState.pending) {
      navigator.popUntil((route) => route.isFirst);
    }
  }
}

/// "username@host", or "New account" for a slot with no identity yet.
String _label(BuildContext context, AccountSlot? slot) {
  if (slot == null || slot.username == null)
    return context.l10n.accountsNewAccount;
  final host = slot.origin == null ? null : Uri.tryParse(slot.origin!)?.host;
  return host == null || host.isEmpty
      ? slot.username!
      : '${slot.username}@$host';
}

String accountLabel(BuildContext context, AccountSlot? slot) =>
    _label(context, slot);

/// Asks whether to switch although push could not be taken down.
Future<bool> confirmPushFailure(BuildContext context, String name) async {
  final l10n = context.l10n;
  return await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.accountsPushFailTitle),
          content: Text(l10n.accountsPushFailBody(name)),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(l10n.accountsSwitchAnyway),
            ),
          ],
        ),
      ) ??
      false;
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({required this.host, required this.slot});

  final AccountHost host;
  final AccountSlot slot;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isOpen = host.registry.active == slot.namespace;
    final status = isOpen
        ? l10n.accountsOpenNow
        : slot.state == SlotState.pending
            ? l10n.accountsPending
            : null;
    return ListTile(
      key: ValueKey<String>('account-${slot.namespace}'),
      contentPadding: EdgeInsets.zero,
      leading:
          Icon(isOpen ? Icons.account_circle : Icons.account_circle_outlined),
      title: Text(_label(context, slot)),
      subtitle: status == null ? null : Text(status),
      onTap: host.switching || isOpen ? null : () => _switch(context),
      trailing: PopupMenuButton<String>(
        enabled: !host.switching,
        onSelected: (_) => _remove(context),
        itemBuilder: (_) => <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
              value: 'remove', child: Text(l10n.accountsRemove)),
        ],
      ),
    );
  }

  Future<void> _switch(BuildContext context) async {
    final navigator = Navigator.of(context);
    final outcome = await host.switchTo(slot.namespace);
    if (outcome == SwitchOutcome.needsConfirmation && context.mounted) {
      if (await confirmPushFailure(context, _label(context, host.activeSlot))) {
        await host.switchTo(slot.namespace, acceptPushFailure: true);
      }
    }
    if (host.registry.active == slot.namespace) {
      navigator.popUntil((route) => route.isFirst);
    }
  }

  Future<void> _remove(BuildContext context) async {
    final l10n = context.l10n;
    final name = _label(context, slot);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.accountsRemoveTitle(name)),
        content: Text(l10n.accountsRemoveBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.accountsRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final navigator = Navigator.of(context);
    final outcome = await host.remove(slot.namespace);
    if (outcome == SwitchOutcome.needsConfirmation && context.mounted) {
      if (await confirmPushFailure(context, name)) {
        await host.remove(slot.namespace, acceptPushFailure: true);
      }
    }
    if (host.activeSlot?.state != SlotState.active) {
      navigator.popUntil((route) => route.isFirst);
    }
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: BoneSpacing.md),
        child: Text(message,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
}
