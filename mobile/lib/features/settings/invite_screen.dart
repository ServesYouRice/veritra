import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';

/// Mint invite codes for the invite-only registration flow. Invites the
/// account has created are listed from the server (`GET /invites`), so codes
/// survive restarts.
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
        final invites = widget.state.invites;
        return Scaffold(
          appBar: const LargeTitleBar(title: 'Invites'),
          body: RefreshIndicator(
            onRefresh: widget.state.refreshInvites,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                BoneSpacing.gutter,
                BoneSpacing.sm,
                BoneSpacing.gutter,
                BoneSpacing.xl,
              ),
              children: <Widget>[
                const SectionHeader(
                  'Create an invite',
                  padding: EdgeInsets.only(bottom: BoneSpacing.sm),
                ),
                TileGroup(
                  dividerIndent: 0,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(BoneSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: _Labelled(
                                  label: 'Max uses',
                                  child: DropdownButtonFormField<int>(
                                    initialValue: maxUses,
                                    items: const <DropdownMenuItem<int>>[
                                      DropdownMenuItem(
                                          value: 1, child: Text('1')),
                                      DropdownMenuItem(
                                          value: 5, child: Text('5')),
                                      DropdownMenuItem(
                                          value: 10, child: Text('10')),
                                      DropdownMenuItem(
                                          value: 25, child: Text('25')),
                                    ],
                                    onChanged: (value) =>
                                        setState(() => maxUses = value ?? 1),
                                  ),
                                ),
                              ),
                              const SizedBox(width: BoneSpacing.md),
                              Expanded(
                                child: _Labelled(
                                  label: 'Expires',
                                  child: DropdownButtonFormField<int?>(
                                    initialValue: expiresInDays,
                                    items: const <DropdownMenuItem<int?>>[
                                      DropdownMenuItem(
                                          value: 1, child: Text('1 day')),
                                      DropdownMenuItem(
                                          value: 7, child: Text('7 days')),
                                      DropdownMenuItem(
                                          value: 30, child: Text('30 days')),
                                    ],
                                    onChanged: (value) =>
                                        setState(() => expiresInDays = value),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: BoneSpacing.lg),
                          FilledButton.icon(
                            onPressed: widget.state.busy
                                ? null
                                : () => _create(context),
                            icon: const Icon(Icons.card_giftcard_outlined),
                            label: const Text('Create invite'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: BoneSpacing.sm),
                if (invites.isEmpty)
                  // Spinner until the first fetch resolves, then the empty
                  // state — otherwise "No invites yet" flashes during load.
                  widget.state.invitesLoaded
                      ? const EmptyState(
                          icon: Icons.card_giftcard_outlined,
                          title: 'No invites yet',
                          message: 'Invite codes you create appear here. Share '
                              'them over a secure channel.',
                        )
                      : const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Center(child: CircularProgressIndicator()),
                        )
                else ...<Widget>[
                  const SectionHeader('Your invites'),
                  TileGroup(
                    children: <Widget>[
                      for (final invite in invites)
                        _InviteRow(
                          invite: invite,
                          onRevoke: () => widget.state.revokeInvite(invite.id),
                        ),
                    ],
                  ),
                ],
              ],
            ),
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

/// A form control with the same `micro` label treatment the connect screen
/// uses, so the two forms in the app read as one system.
class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(
            left: BoneSpacing.xs,
            bottom: BoneSpacing.sm,
          ),
          child: Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall,
          ),
        ),
        child,
      ],
    );
  }
}

class _InviteRow extends StatelessWidget {
  const _InviteRow({required this.invite, required this.onRevoke});

  final Invite invite;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expires = invite.expiresAt;
    final exhausted = invite.maxUses > 0 && invite.uses >= invite.maxUses;
    return ListTile(
      leading: const Icon(Icons.confirmation_number_outlined),
      title: Row(
        children: <Widget>[
          Flexible(
            child: SelectableText(
              invite.code,
              style: BoneType.mono.copyWith(
                fontSize: 15,
                letterSpacing: 1.2,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: BoneSpacing.sm),
          // Uses are the fact that decides whether the code still works, so
          // they get the pill rather than a clause in the joined subtitle.
          StatusPill(
            label: '${invite.uses}/${invite.maxUses}',
            tone: exhausted ? StatusTone.warning : StatusTone.neutral,
            uppercase: false,
            semanticsLabel: '${invite.uses} of ${invite.maxUses} uses',
          ),
        ],
      ),
      subtitle: Text(
        expires == null
            ? 'Never expires'
            : 'Expires ${formatDateTime(context, expires)}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: MenuAnchor(
        builder: (context, controller, _) => IconButton(
          tooltip: 'Invite actions',
          icon: const Icon(Icons.more_vert),
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
        menuChildren: <Widget>[
          MenuItemButton(
            leadingIcon: const Icon(Icons.copy_outlined),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: invite.code));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Invite code copied.')),
              );
            },
            child: const Text('Copy code'),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.block_outlined),
            onPressed: onRevoke,
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
  }
}
