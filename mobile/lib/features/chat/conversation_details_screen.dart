import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/block_actions.dart';
import '../../calls/call_controller.dart';
import '../../core/app_state.dart';
import '../settings/profile_edit_screen.dart';
import '../../core/models.dart';
import '../../ui/avatar.dart';
import '../../ui/motion.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/account_picker.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/tile_group.dart';
import '../communities/membership_screens.dart';
import '../search/search_screen.dart';
import 'chat_list_screen.dart';
import 'mute_sheet.dart';
import 'roles_screen.dart';
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
        // C4: the verified record's role where the group has one; the
        // server's role is only a hint without it.
        final self = state.session?.accountId;
        final myRole =
            (self == null ? null : state.roleOf(conversationId, self)) ??
                conversation.currentRole ??
                'member';
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
              _DetailsHeader(
                avatar: conversationAvatar(context, conversation,
                    radius: 44, profiles: state.profiles),
                title: conversationTitle(l10n, conversation,
                    profiles: state.profiles),
                subtitle: _headerSubtitle(l10n, conversation),
              ),
              const SizedBox(height: BoneSpacing.lg),
              _ActionRow(
                actions: <Widget>[
                  _DetailAction(
                    key: const Key('details-mute'),
                    icon: state.isMuted(conversationId)
                        ? Icons.notifications_off_outlined
                        : Icons.notifications_outlined,
                    label: state.isMuted(conversationId)
                        ? l10n.detailsActionUnmute
                        : l10n.detailsActionMute,
                    onTap: state.isBusy(Ops.mute)
                        ? null
                        : () => _chooseMute(context),
                  ),
                  // The same message search the chat's Ctrl+F opens: the app
                  // has no search inside one chat.
                  _DetailAction(
                    key: const Key('details-search'),
                    icon: Icons.search,
                    label: l10n.chatListSearch,
                    onTap: () => Navigator.of(context).push(
                      sharedAxisRoute<void>(
                        (_) => SearchScreen(state: state),
                      ),
                    ),
                  ),
                  if (isDm && !state.readOnlyWithoutPeer(conversationId))
                    ValueListenableBuilder<CallController?>(
                      valueListenable: state.callController,
                      builder: (context, calls, _) => calls == null
                          ? const SizedBox.shrink()
                          : ListenableBuilder(
                              listenable: calls,
                              builder: (context, _) => _DetailAction(
                                key: const Key('details-call'),
                                icon: Icons.call_outlined,
                                label: l10n.detailsActionCall,
                                onTap: calls.busy
                                    ? null
                                    : () =>
                                        unawaited(calls.start(conversation.id)),
                              ),
                            ),
                    ),
                ],
              ),
              if (state.isMuted(conversationId))
                Padding(
                  padding: const EdgeInsets.only(top: BoneSpacing.sm),
                  child: Text(
                    _muteStatus(context, l10n),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (state.errorFor(Ops.mute) != null)
                _InlineError(message: state.errorFor(Ops.mute)!),
              const SizedBox(height: BoneSpacing.lg),
              if (conversation.isGroup && state.profilesAvailable) ...<Widget>[
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      key: const Key('group-profile-tile'),
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(l10n.groupProfileTitle),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ProfileEditScreen.group(
                            state: state,
                            conversationId: conversation.id,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: BoneSpacing.sm),
              ],
              // One row, one sheet: the five options and the reason they are
              // locked live there instead of down the page (U30).
              TileGroup(
                children: <Widget>[
                  ListTile(
                    key: const Key('details-retention'),
                    leading: const Icon(Icons.timer_outlined),
                    title: Text(l10n.detailsSectionDisappearing),
                    subtitle: Text(
                      retention == null || retention == 0
                          ? l10n.detailsRetentionOff
                          : retentionLabel(l10n, retention),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openRetentionSheet(
                      context,
                      conversation,
                      canManage: canManage,
                    ),
                  ),
                ],
              ),
              if (!isDm) ...<Widget>[
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
                          profileName: state.profileNameOf(member.accountId),
                          isSelf: member.accountId == state.session?.accountId,
                          // Only a manager can remove someone, never
                          // themselves through this control, and never anyone
                          // ranked at or above their own role.
                          canRemove: canManage &&
                              !isDm &&
                              member.accountId != state.session?.accountId &&
                              _outranks(
                                  myRole,
                                  state.roleOf(
                                          conversationId, member.accountId) ??
                                      member.role),
                          busy: state.isBusy(Ops.members),
                          onRemove: () => _confirmRemove(context, member),
                        ),
                    // K0 step 8: no group device here could add them.
                    if (!isDm &&
                        state.membershipChangesAvailable &&
                        !state.readOnlyWithoutPeer(conversationId))
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
              ],
              if (conversation.isGroup ||
                  conversation.isCommunityShared) ...<Widget>[
                const SizedBox(height: BoneSpacing.sm),
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      key: const Key('roles-tile'),
                      leading: const Icon(Icons.admin_panel_settings_outlined),
                      title: Text(l10n.rolesTitle),
                      subtitle: Text(l10n.rolesDetail),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RolesScreen(
                            state: state,
                            conversationId: conversationId,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              // C1: invitation links and join requests of a group, for its
              // owners and admins. A DM or a community channel has none.
              if (conversation.isGroup &&
                  const <String>{'owner', 'admin'}
                      .contains(myRole)) ...<Widget>[
                const SizedBox(height: BoneSpacing.sm),
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.link),
                      title: Text(l10n.membInviteManage),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => MembershipManageScreen(
                            state: state,
                            kind: InviteTargetKind.group,
                            targetId: conversationId,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
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
              const SizedBox(height: BoneSpacing.lg),
              // The identifiers and the membership caveat are for the few who
              // look for them (U30).
              TileGroup(
                children: <Widget>[
                  Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      key: const Key('details-advanced'),
                      leading: const Icon(Icons.tune_outlined),
                      title: Text(l10n.detailsSectionAdvanced),
                      childrenPadding: const EdgeInsets.only(
                        bottom: BoneSpacing.md,
                      ),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
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
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: BoneSpacing.lg,
                          ),
                          child: Text(
                            l10n.detailsMembershipNote,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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

  /// The line under the name: who this is, never an identifier. A chat of two
  /// shows the username unless the name above already is it.
  String? _headerSubtitle(AppLocalizations l10n, Conversation conversation) {
    if (conversation.isDm) {
      final peer = conversation.peerAccountId;
      if (peer == null) return null;
      final label = accountLabel(peer, conversation.peerUsername);
      return label ==
              conversationTitle(l10n, conversation, profiles: state.profiles)
          ? null
          : label;
    }
    return conversation.isChannel
        ? l10n.communityChannelSubtitle
        : l10n.conversationPrivateGroup;
  }

  /// The five timers in one sheet. Locked, it opens all the same and says why:
  /// a disabled list with no reason reads as broken.
  Future<void> _openRetentionSheet(
    BuildContext context,
    Conversation conversation, {
    required bool canManage,
  }) async {
    final theme = Theme.of(context);
    final retention = conversation.retentionSeconds;
    final current = retention == null || retention == 0 ? null : retention;
    final chosen = await showModalBottomSheet<({int? seconds})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final l10n = sheetContext.l10n;
        final editable = canManage && !state.busy;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: BoneSpacing.gutter,
                  ),
                  child: Text(
                    l10n.detailsSectionDisappearing,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (!canManage)
                  Padding(
                    key: const Key('retention-locked'),
                    padding: const EdgeInsets.fromLTRB(
                      BoneSpacing.gutter,
                      BoneSpacing.sm,
                      BoneSpacing.gutter,
                      0,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Icon(Icons.lock_outline, size: 18),
                        const SizedBox(width: BoneSpacing.sm),
                        Expanded(
                          child: Text(
                            // The server lets the owner of a chat of two, who
                            // started it, change the timer; no role is named.
                            conversation.isDm
                                ? l10n.detailsRetentionLockedDm
                                : l10n.detailsRetentionLocked,
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    BoneSpacing.gutter,
                    BoneSpacing.sm,
                    BoneSpacing.gutter,
                    BoneSpacing.sm,
                  ),
                  child: Text(
                    l10n.detailsDisappearingNote,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                RadioGroup<int?>(
                  groupValue: current,
                  onChanged: (value) {
                    if (editable) {
                      Navigator.of(sheetContext).pop((seconds: value));
                    }
                  },
                  child: Column(
                    children: <Widget>[
                      for (final option in _retentionOptions)
                        RadioListTile<int?>(
                          value: option.seconds,
                          title: Text(option.label(l10n)),
                          enabled: editable,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (chosen == null || chosen.seconds == current || !context.mounted) {
      return;
    }
    await _confirmRetentionChange(context, conversation.id, chosen.seconds);
  }

  String _muteStatus(BuildContext context, AppLocalizations l10n) {
    if (!state.isMuted(conversationId)) return l10n.detailsMuteDetail;
    final until = state.mutedUntil(conversationId);
    return until == null
        ? l10n.muteStatusAlways
        : l10n.muteStatusUntil(formatDateTime(context, until.toLocal()));
  }

  Future<void> _chooseMute(BuildContext context) async {
    final duration = await chooseMuteDuration(
      context,
      muted: state.isMuted(conversationId),
    );
    if (duration == null || !context.mounted) return;
    final ok = await state.setConversationMute(conversationId, duration);
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
      destructive: true, // U15
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

/// The photo, the name and, under it, who this is: the page opens on a person
/// or a group, not on a form (U30).
class _DetailsHeader extends StatelessWidget {
  const _DetailsHeader({
    required this.avatar,
    required this.title,
    this.subtitle,
  });

  final Widget avatar;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        const SizedBox(height: BoneSpacing.sm),
        avatar,
        const SizedBox(height: BoneSpacing.md),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: BoneSpacing.xs),
            child: Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// The few things most people open this page for, side by side under the name.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final action in actions) Flexible(child: action),
      ],
    );
  }
}

/// A round icon with its word under it, 72 wide so three fit a phone and the
/// label has room to wrap at large text.
class _DetailAction extends StatelessWidget {
  const _DetailAction({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 72, maxWidth: 104),
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        excludeSemantics: true,
        onTap: onTap,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(BoneRadii.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: BoneSpacing.sm,
              vertical: BoneSpacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CircleAvatar(
                  radius: 24,
                  backgroundColor: scheme.surfaceContainerHigh,
                  foregroundColor:
                      enabled ? scheme.onSurface : scheme.onSurfaceVariant,
                  child: Icon(icon),
                ),
                const SizedBox(height: BoneSpacing.xs),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    this.profileName,
    required this.isSelf,
    required this.canRemove,
    required this.busy,
    required this.onRemove,
  });

  final ConversationMember member;

  /// The display name this person shared (W11). A member list shows it with
  /// the username, so a chosen name never stands in for who someone is.
  final String? profileName;
  final bool isSelf;
  final bool canRemove;
  final bool busy;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final account = accountLabel(member.accountId, member.username);
    final label = profileName == null ? account : '$profileName ($account)';
    final colors = avatarColorsFor(context, member.accountId);
    // U15: the role shows under the name, in words.
    final details = <String>[
      roleLabel(l10n, member.role),
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
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          details.join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        // U15: removing sits in a per-member menu, not behind a bare icon.
        trailing: canRemove
            ? PopupMenuButton<VoidCallback>(
                key: Key('member-menu-${member.accountId}'),
                tooltip: l10n.memberModerateTooltip(label),
                enabled: !busy,
                onSelected: (action) => action(),
                itemBuilder: (_) => <PopupMenuEntry<VoidCallback>>[
                  PopupMenuItem<VoidCallback>(
                    value: onRemove,
                    child: Text(l10n.detailsRemoveConfirm),
                  ),
                ],
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
        blocked
            ? l10n.detailsBlockedDetail
            // A block hides a profile only in a chat of two (S8); in a group
            // you share, everyone still gets the key.
            : state.profilesAvailable
                ? '${l10n.detailsBlockDetail} ${l10n.profileBlockNote}'
                : l10n.detailsBlockDetail,
      ),
      onTap: state.isBusy(Ops.blocks)
          ? null
          : () => _toggle(context, blocked: blocked),
    );
  }

  // U16: blocking asks first; both directions offer Undo.
  Future<void> _toggle(BuildContext context, {required bool blocked}) =>
      toggleBlock(
        context,
        state,
        accountId: accountId,
        label: label,
        blocked: blocked,
      );
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
