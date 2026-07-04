import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/format.dart';
import '../../ui/widgets/empty_state.dart';

/// Mint invite codes for the invite-only registration flow. The server has
/// no list-invites endpoint yet, so only invites created this session are
/// shown; copy the code before leaving.
class InviteScreen extends StatefulWidget {
  const InviteScreen({required this.state, super.key});

  final AppState state;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  int maxUses = 1;
  int? expiresInDays = 7;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final theme = Theme.of(context);
        final invites = widget.state.invites;
        return Scaffold(
          appBar: AppBar(title: const Text('Invites')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text('Create an invite',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              initialValue: maxUses,
                              decoration: const InputDecoration(
                                labelText: 'Max uses',
                              ),
                              items: const <DropdownMenuItem<int>>[
                                DropdownMenuItem(value: 1, child: Text('1')),
                                DropdownMenuItem(value: 5, child: Text('5')),
                                DropdownMenuItem(value: 10, child: Text('10')),
                                DropdownMenuItem(value: 25, child: Text('25')),
                              ],
                              onChanged: (value) =>
                                  setState(() => maxUses = value ?? 1),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<int?>(
                              initialValue: expiresInDays,
                              decoration: const InputDecoration(
                                labelText: 'Expires',
                              ),
                              items: const <DropdownMenuItem<int?>>[
                                DropdownMenuItem(
                                    value: 1, child: Text('1 day')),
                                DropdownMenuItem(
                                    value: 7, child: Text('7 days')),
                                DropdownMenuItem(
                                    value: 30, child: Text('30 days')),
                                DropdownMenuItem(
                                    value: null, child: Text('Never')),
                              ],
                              onChanged: (value) =>
                                  setState(() => expiresInDays = value),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed:
                            widget.state.busy ? null : () => _create(context),
                        icon: const Icon(Icons.card_giftcard_outlined),
                        label: const Text('Create invite'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (invites.isEmpty)
                const EmptyState(
                  icon: Icons.card_giftcard_outlined,
                  title: 'No invites this session',
                  message: 'Created invite codes appear here. Copy and '
                      'share them over a secure channel.',
                )
              else ...<Widget>[
                Text('Created this session',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                for (final invite in invites) _InviteCard(invite: invite),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _create(BuildContext context) async {
    final days = expiresInDays;
    final invite = await widget.state.createInvite(
      maxUses: maxUses,
      expiresAt: days == null ? null : DateTime.now().add(Duration(days: days)),
    );
    if (!context.mounted) {
      return;
    }
    if (invite == null && widget.state.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.state.error!)),
      );
    }
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.invite});

  final Invite invite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expires = invite.expiresAt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.confirmation_number_outlined),
          title: SelectableText(
            invite.code,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFamily: 'monospace',
              letterSpacing: 1.2,
            ),
          ),
          subtitle: Text(
            <String>[
              '${invite.maxUses} use${invite.maxUses == 1 ? '' : 's'}',
              if (expires != null) 'expires ${formatDateTime(expires)}',
              if (expires == null) 'never expires',
            ].join(' · '),
          ),
          trailing: IconButton(
            tooltip: 'Copy code',
            icon: const Icon(Icons.copy_outlined),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: invite.code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Invite code copied.')),
              );
            },
          ),
        ),
      ),
    );
  }
}
