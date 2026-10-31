import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/confirm.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';
import '../../ui/widgets/refresh_action.dart';

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
        final l10n = context.l10n;
        final invites = widget.state.invites;
        return Scaffold(
          appBar: LargeTitleBar(
            title: l10n.settingsInvites,
            actions: <Widget>[
              RefreshAction(onRefresh: widget.state.refreshInvites),
            ],
          ),
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
                SectionHeader(
                  l10n.inviteCreateSection,
                  padding: const EdgeInsets.only(bottom: BoneSpacing.sm),
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
                                  label: l10n.inviteMaxUses,
                                  child: DropdownButtonFormField<int>(
                                    initialValue: maxUses,
                                    items: <DropdownMenuItem<int>>[
                                      for (final count in const <int>[
                                        1,
                                        5,
                                        10,
                                        25,
                                      ])
                                        DropdownMenuItem(
                                          value: count,
                                          child: Text(
                                            l10n.inviteMaxUsesOption(count),
                                          ),
                                        ),
                                    ],
                                    onChanged: (value) =>
                                        setState(() => maxUses = value ?? 1),
                                  ),
                                ),
                              ),
                              const SizedBox(width: BoneSpacing.md),
                              Expanded(
                                child: _Labelled(
                                  label: l10n.inviteExpires,
                                  child: DropdownButtonFormField<int?>(
                                    initialValue: expiresInDays,
                                    items: <DropdownMenuItem<int?>>[
                                      for (final days in const <int>[1, 7, 30])
                                        DropdownMenuItem(
                                          value: days,
                                          child: Text(
                                            l10n.durationDays(days),
                                          ),
                                        ),
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
                            label: Text(l10n.inviteCreate),
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
                  // A listing that failed is not an empty list.
                  widget.state.invitesLoaded && widget.state.invitesLoadFailed
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Column(
                            children: <Widget>[
                              Text(
                                l10n.inviteLoadFailed,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: BoneSpacing.md),
                              OutlinedButton(
                                onPressed: widget.state.refreshInvites,
                                child: Text(l10n.commonRetry),
                              ),
                            ],
                          ),
                        )
                      : widget.state.invitesLoaded
                          ? EmptyState(
                              icon: Icons.card_giftcard_outlined,
                              title: l10n.inviteEmptyTitle,
                              message: l10n.inviteEmptyMessage,
                            )
                          : const Padding(
                              padding: EdgeInsets.symmetric(vertical: 32),
                              child: Center(child: CircularProgressIndicator()),
                            )
                else ...<Widget>[
                  SectionHeader(l10n.inviteYourInvites),
                  TileGroup(
                    children: <Widget>[
                      for (final invite in invites)
                        _InviteRow(
                          invite: invite,
                          onRevoke: () => _confirmRevoke(context, invite),
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

  Future<void> _confirmRevoke(BuildContext context, Invite invite) async {
    final confirmed = await confirmAction(
      context,
      title: context.l10n.inviteRevokeTitle,
      message: context.l10n.inviteRevokeMessage(invite.code),
      confirmLabel: context.l10n.commonRevoke,
      destructive: true,
    );
    if (!confirmed) return;
    await widget.state.revokeInvite(invite.id);
    if (!context.mounted) return;
    // The action clears the shared error when it starts and sets it when it
    // fails, so an error here belongs to this revoke, not an earlier one.
    final error = widget.state.error;
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(widget.state.error!)));
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
          child: Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
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
            label: context.l10n.inviteUsesPill(invite.uses, invite.maxUses),
            tone: exhausted ? StatusTone.warning : StatusTone.neutral,
            uppercase: false,
            semanticsLabel:
                context.l10n.inviteUsesSemantics(invite.uses, invite.maxUses),
          ),
        ],
      ),
      subtitle: Text(
        expires == null
            ? context.l10n.inviteNeverExpires
            : context.l10n.inviteExpiresAt(formatDateTime(context, expires)),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: MenuAnchor(
        builder: (context, controller, _) => IconButton(
          tooltip: context.l10n.inviteActions,
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
                SnackBar(content: Text(context.l10n.inviteCodeCopied)),
              );
            },
            child: Text(context.l10n.inviteCopyCode),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.block_outlined),
            onPressed: onRevoke,
            child: Text(context.l10n.commonRevoke),
          ),
        ],
      ),
    );
  }
}
