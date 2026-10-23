import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/account_picker.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';
import 'chat_list_screen.dart';
import 'safety_number_screen.dart';
import '../../l10n/l10n.dart';

/// Conversation metadata and management: who is in it, notification mute,
/// safety actions, and disappearing-message retention.
///
/// The member list here is the server's membership record. Server membership
/// is not proof of who can decrypt — MLS roster changes are committed
/// separately — so every membership action says so rather than implying
/// cryptographic removal.
class ConversationDetailsScreen extends StatefulWidget {
  const ConversationDetailsScreen({
    required this.state,
    required this.conversationId,
    super.key,
  });

  final AppState state;
  final String conversationId;

  @override
  State<ConversationDetailsScreen> createState() =>
      _ConversationDetailsScreenState();
}

class _ConversationDetailsScreenState extends State<ConversationDetailsScreen> {
  @override
  void initState() {
    super.initState();
    // Deferred to a microtask: these calls flip busy state and notify
    // listeners synchronously, which would rebuild ancestors mid-build if
    // started directly from initState.
    scheduleMicrotask(() {
      if (!mounted) {
        return;
      }
      widget.state.loadConversationMembers(widget.conversationId);
      widget.state.loadConversationMuted(widget.conversationId);
    });
  }

  AppState get state => widget.state;
  String get conversationId => widget.conversationId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final conversation = state.conversations
            .where((c) => c.id == conversationId)
            .firstOrNull;
        if (conversation == null) {
          return Scaffold(
            appBar: LargeTitleBar(title: context.l10n.searchTypeConversation),
            body: Center(child: Text(context.l10n.detailsNotFound)),
          );
        }
        final theme = Theme.of(context);
        final l10n = context.l10n;
        final retention = conversation.retentionSeconds;
        final myRole = conversation.currentRole ?? 'member';
        final canManage =
            const <String>{'owner', 'admin', 'moderator'}.contains(myRole);
        // A DM is a fixed pair. Adding a third account would silently turn it
        // into a group the other person never agreed to, so membership
        // editing is not offered here at all.
        final isDm = conversation.isDm;
        final members = state.membersFor(conversationId);
        final memberError = state.errorFor(Ops.members);
        return Scaffold(
          appBar: LargeTitleBar(title: l10n.chatListDetails),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xl,
            ),
            children: <Widget>[
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading:
                        conversationAvatar(context, conversation, radius: 20),
                    title: Text(conversationTitle(l10n, conversation)),
                    subtitle: Text(conversationSubtitle(l10n, conversation)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.tag_outlined),
                    title: Text(
                      l10n.detailsConversationIdLabel,
                      style: theme.textTheme.labelSmall,
                    ),
                    subtitle: Text(
                      shortId(conversation.id),
                      style: BoneType.mono.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: l10n.detailsCopyId,
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () => _copy(
                        context,
                        conversation.id,
                        l10n.detailsConversationId,
                      ),
                    ),
                  ),
                  if (conversation.createdAt != null)
                    ListTile(
                      leading: const Icon(Icons.schedule_outlined),
                      title: Text(
                        l10n.detailsCreatedLabel,
                        style: theme.textTheme.labelSmall,
                      ),
                      subtitle: Text(
                        formatDateTime(context, conversation.createdAt!),
                      ),
                    ),
                ],
              ),
              SectionHeader(l10n.settingsSectionNotifications),
              TileGroup(
                children: <Widget>[
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_off_outlined),
                    title: Text(l10n.chatListMute),
                    subtitle: Text(l10n.detailsMuteDetail),
                    value: state.isMuted(conversationId),
                    onChanged: state.isBusy(Ops.mute)
                        ? null
                        : (value) => _setMuted(context, value),
                  ),
                ],
              ),
              if (state.errorFor(Ops.mute) != null)
                _InlineError(message: state.errorFor(Ops.mute)!),
              SectionHeader(l10n.detailsSectionMembers),
              if (memberError != null) _InlineError(message: memberError),
              TileGroup(
                children: <Widget>[
                  if (members.isEmpty && state.isBusy(Ops.members))
                    ListTile(
                      leading: const SizedBox.square(
                        dimension: 24,
                        child: Center(
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                      title: Text(l10n.detailsLoadingMembers),
                    )
                  else if (members.isEmpty)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(l10n.detailsMembersUnavailable),
                      subtitle: Text(l10n.detailsMembersUnavailableDetail),
                    )
                  else
                    for (final member in members)
                      _MemberTile(
                        member: member,
                        isSelf: member.accountId == state.session?.accountId,
                        // Only a manager can remove someone, never
                        // themselves through this control, and never anyone
                        // ranked at or above their own role.
                        canRemove: canManage &&
                            !isDm &&
                            member.accountId != state.session?.accountId &&
                            _outranks(myRole, member.role),
                        busy: state.isBusy(Ops.members),
                        onRemove: () => _confirmRemove(context, member),
                      ),
                  if (!isDm && state.membershipChangesAvailable)
                    ListTile(
                      leading: const Icon(Icons.person_add_outlined),
                      title: Text(l10n.detailsAddMember),
                      subtitle: Text(canManage
                          ? l10n.detailsAddMemberDetail
                          : l10n.detailsAddMemberNoPermission),
                      onTap: state.isBusy(Ops.members) || !canManage
                          ? null
                          : () => _addMember(context, myRole),
                    ),
                ],
              ),
              const SizedBox(height: BoneSpacing.sm),
              Text(
                l10n.detailsMembershipNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              SectionHeader(l10n.settingsSectionSafety),
              TileGroup(
                children: <Widget>[
                  if (state.safetyNumbersAvailable)
                    ListTile(
                      leading: const Icon(Icons.verified_user_outlined),
                      title: Text(l10n.safetyTitle),
                      subtitle: Text(l10n.detailsSafetyDetail),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SafetyNumberScreen(
                            state: state,
                            conversation: conversation,
                          ),
                        ),
                      ),
                    ),
                  if (isDm && conversation.peerAccountId != null)
                    _BlockTile(
                      state: state,
                      accountId: conversation.peerAccountId!,
                      label: accountLabel(
                        conversation.peerAccountId!,
                        conversation.peerUsername,
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: Text(
                      isDm ? l10n.detailsLeaveDm : l10n.detailsLeave,
                    ),
                    subtitle: Text(l10n.detailsLeaveDetail),
                    onTap: state.isBusy(Ops.members)
                        ? null
                        : () => _confirmLeave(context),
                  ),
                ],
              ),
              SectionHeader(l10n.detailsSectionDisappearing),
              TileGroup(
                dividerIndent: 0,
                children: <Widget>[
                  RadioGroup<int?>(
                    groupValue:
                        retention == null || retention == 0 ? null : retention,
                    onChanged: (value) {
                      if (!state.busy && canManage) {
                        _confirmRetentionChange(
                          context,
                          conversation.id,
                          value,
                        );
                      }
                    },
                    child: Column(
                      children: <Widget>[
                        for (final option in _retentionOptions)
                          RadioListTile<int?>(
                            value: option.seconds,
                            title: Text(option.label(l10n)),
                            enabled: !state.busy && canManage,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: BoneSpacing.sm),
              Text(
                l10n.detailsDisappearingNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  static const _rank = <String, int>{
    'owner': 3,
    'admin': 2,
    'moderator': 1,
    'member': 0,
  };

  /// Whether [actorRole] ranks strictly above [targetRole]. Mirrors the
  /// server's authorization so the UI does not offer an action that will
  /// come back as a generic 403.
  static bool _outranks(String actorRole, String targetRole) =>
      (_rank[actorRole] ?? 0) > (_rank[targetRole] ?? 0);

  /// Roles the actor is actually allowed to grant: anything strictly below
  /// their own.
  static List<String> _grantableRoles(String actorRole) => _rank.entries
      .where((entry) => (_rank[actorRole] ?? 0) > entry.value)
      .map((entry) => entry.key)
      .toList(growable: false)
    ..sort((left, right) => (_rank[left] ?? 0).compareTo(_rank[right] ?? 0));

  static const _retentionOptions = <_RetentionOption>[
    _RetentionOption(null, _retentionOff),
    _RetentionOption(3600, _retentionHour),
    _RetentionOption(86400, _retentionDay),
    _RetentionOption(604800, _retentionWeek),
    _RetentionOption(2592000, _retentionMonth),
  ];

  static String _retentionOff(AppLocalizations l10n) =>
      l10n.detailsRetentionOff;
  static String _retentionHour(AppLocalizations l10n) => l10n.durationHours(1);
  static String _retentionDay(AppLocalizations l10n) => l10n.durationHours(24);
  static String _retentionWeek(AppLocalizations l10n) => l10n.durationDays(7);
  static String _retentionMonth(AppLocalizations l10n) => l10n.durationDays(30);

  Future<void> _setMuted(BuildContext context, bool muted) async {
    final ok = await state.setConversationMuted(conversationId, muted);
    if (!context.mounted || ok) {
      return;
    }
    final error = state.errorFor(Ops.mute);
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _confirmRemove(
    BuildContext context,
    ConversationMember member,
  ) async {
    final label = accountLabel(member.accountId, member.username);
    final confirmed = await _confirm(
      context,
      title: context.l10n.detailsRemoveTitle(label),
      message: context.l10n.detailsRemoveMessage,
      confirmLabel: context.l10n.detailsRemoveConfirm,
    );
    if (!confirmed) {
      return;
    }
    final ok = await state.removeConversationMember(
      conversationId,
      member.accountId,
    );
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? context.l10n.detailsRemoved(label)
            : state.errorFor(Ops.members) ??
                context.l10n.detailsRemoveFailed(label)),
      ),
    );
  }

  Future<void> _confirmLeave(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: context.l10n.detailsLeaveTitle,
      message: context.l10n.detailsLeaveMessage,
      confirmLabel: context.l10n.detailsLeaveConfirm,
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    final ok = await state.leaveConversation(conversationId);
    if (!context.mounted) {
      return;
    }
    if (ok) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    final error = state.errorFor(Ops.members);
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  /// Retention only stamps an expiry on messages sent after the change —
  /// existing messages keep their current timer — but it is still a policy
  /// change worth confirming rather than applying on a stray tap.
  Future<void> _confirmRetentionChange(
    BuildContext context,
    String conversationId,
    int? retentionSeconds,
  ) async {
    final l10n = context.l10n;
    final duration =
        retentionSeconds == null ? '' : retentionLabel(l10n, retentionSeconds);
    final description = retentionSeconds == null
        ? l10n.detailsRetentionOffMessage
        : l10n.detailsRetentionOnMessage(duration);
    final confirmed = await _confirm(
      context,
      title: retentionSeconds == null
          ? l10n.detailsRetentionOffTitle
          : l10n.detailsRetentionOnTitle(duration),
      message: description,
      confirmLabel: l10n.detailsApply,
    );
    if (confirmed) {
      await state.setConversationRetention(conversationId, retentionSeconds);
    }
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final theme = Theme.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _copy(BuildContext context, String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.settingsCopied(label))),
    );
  }

  Future<void> _addMember(BuildContext context, String actorRole) async {
    final grantable = _grantableRoles(actorRole);
    if (grantable.isEmpty) {
      return;
    }
    String role = grantable.first;
    List<SelectedAccount> picked = <SelectedAccount>[];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(context.l10n.detailsAddMember),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AccountPicker(
                  state: state,
                  maxSelection: 1,
                  onChanged: (value) => setDialogState(() => picked = value),
                ),
                const SizedBox(height: 12),
                // Only roles below the actor's own are offered; the server
                // would reject the rest with a generic error.
                SegmentedButton<String>(
                  segments: <ButtonSegment<String>>[
                    for (final option in grantable)
                      ButtonSegment<String>(
                        value: option,
                        label: Text(roleLabel(context.l10n, option)),
                      ),
                  ],
                  selected: <String>{role},
                  onSelectionChanged: (value) =>
                      setDialogState(() => role = value.first),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(context.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: picked.isEmpty
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: Text(context.l10n.detailsAdd),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || picked.isEmpty) {
      return;
    }
    await state.addConversationMember(
      conversationId,
      picked.first.id,
      role: role,
    );
    await state.loadConversationMembers(conversationId);
    if (!context.mounted) {
      return;
    }
    final error = state.error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error ?? context.l10n.detailsMemberAdded(picked.first.label),
        ),
      ),
    );
  }
}

/// The display name of a conversation role the server reports.
String roleLabel(AppLocalizations l10n, String role) {
  switch (role) {
    case 'owner':
      return l10n.roleOwner;
    case 'admin':
      return l10n.roleAdmin;
    case 'moderator':
      return l10n.roleModerator;
    default:
      return l10n.roleMember;
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.isSelf,
    required this.canRemove,
    required this.busy,
    required this.onRemove,
  });

  final ConversationMember member;
  final bool isSelf;
  final bool canRemove;
  final bool busy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final label = accountLabel(member.accountId, member.username);
    final colors = avatarColorsFor(context, member.accountId);
    // Role moved onto a pill; what is left in the subtitle is the one thing
    // that is genuinely a detail.
    final details = <String>[
      if (isSelf) l10n.detailsYou,
      if (member.joinedAt != null)
        l10n.detailsJoined(formatDate(context, member.joinedAt!)),
    ];
    return MergeSemantics(
      child: ListTile(
        leading: ExcludeSemantics(
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.fill,
              shape: BoxShape.circle,
              border: Border.all(color: colors.ring),
            ),
            child: Text(
              accountInitials(member.accountId, member.username),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: colors.glyph,
              ),
            ),
          ),
        ),
        title: Row(
          children: <Widget>[
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: BoneSpacing.sm),
            StatusPill(label: roleLabel(l10n, member.role)),
          ],
        ),
        subtitle: details.isEmpty
            ? null
            : Text(
                details.join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
        trailing: canRemove
            ? IconButton(
                tooltip: l10n.detailsRemoveMember(label),
                onPressed: busy ? null : onRemove,
                icon: const Icon(Icons.person_remove_outlined),
              )
            : null,
      ),
    );
  }
}

/// Block/unblock for the DM counterpart. The copy states the actual effect —
/// the server stops delivering their messages to this account — and does not
/// claim anything about the other person's device.
class _BlockTile extends StatelessWidget {
  const _BlockTile({
    required this.state,
    required this.accountId,
    required this.label,
  });

  final AppState state;
  final String accountId;
  final String label;

  @override
  Widget build(BuildContext context) {
    final blocked = state.isBlocked(accountId);
    final l10n = context.l10n;
    return ListTile(
      leading: Icon(blocked ? Icons.person_off : Icons.block),
      title: Text(
        blocked
            ? l10n.searchUnblockAccount(label)
            : l10n.searchBlockAccount(label),
      ),
      subtitle: Text(
        blocked ? l10n.detailsBlockedDetail : l10n.detailsBlockDetail,
      ),
      onTap: state.isBusy(Ops.blocks)
          ? null
          : () => _toggle(context, blocked: blocked),
    );
  }

  Future<void> _toggle(BuildContext context, {required bool blocked}) async {
    final ok = blocked
        ? await state.unblockAccount(accountId)
        : await state.blockAccount(accountId);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? (blocked
                ? context.l10n.blockedUnblocked(label)
                : context.l10n.searchBlocked(label))
            : state.errorFor(Ops.blocks) ?? context.l10n.searchBlockFailed),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _RetentionOption {
  const _RetentionOption(this.seconds, this.label);

  final int? seconds;
  final String Function(AppLocalizations l10n) label;
}
