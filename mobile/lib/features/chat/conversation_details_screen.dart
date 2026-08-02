import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/format.dart';
import '../../ui/widgets/account_picker.dart';
import 'chat_list_screen.dart';

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
            appBar: AppBar(title: const Text('Conversation')),
            body: const Center(child: Text('Conversation not found.')),
          );
        }
        final theme = Theme.of(context);
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
          appBar: AppBar(title: const Text('Conversation details')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Card(
                child: Column(
                  children: <Widget>[
                    ListTile(
                      leading:
                          conversationAvatar(context, conversation, radius: 20),
                      title: Text(conversationTitle(conversation)),
                      subtitle: Text(conversationSubtitle(conversation)),
                    ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.tag_outlined),
                      title: const Text('Conversation ID'),
                      subtitle: Text(shortId(conversation.id)),
                      trailing: IconButton(
                        tooltip: 'Copy ID',
                        icon: const Icon(Icons.copy_outlined),
                        onPressed: () =>
                            _copy(context, conversation.id, 'Conversation ID'),
                      ),
                    ),
                    if (conversation.createdAt != null)
                      ListTile(
                        leading: const Icon(Icons.schedule_outlined),
                        title: const Text('Created'),
                        subtitle: Text(
                          formatDateTime(context, conversation.createdAt!),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Header('Notifications', theme),
              const SizedBox(height: 8),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.notifications_off_outlined),
                  title: const Text('Mute notifications'),
                  subtitle: const Text(
                    'Stops push for this conversation. Messages still arrive '
                    'and still count as unread.',
                  ),
                  value: state.isMuted(conversationId),
                  onChanged: state.isBusy(Ops.mute)
                      ? null
                      : (value) => _setMuted(context, value),
                ),
              ),
              if (state.errorFor(Ops.mute) != null)
                _InlineError(message: state.errorFor(Ops.mute)!),
              const SizedBox(height: 16),
              _Header('Members', theme),
              const SizedBox(height: 8),
              if (memberError != null) _InlineError(message: memberError),
              Card(
                child: Column(
                  children: <Widget>[
                    if (members.isEmpty && state.isBusy(Ops.members))
                      const ListTile(
                        leading: SizedBox.square(
                          dimension: 24,
                          child: Center(
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                        title: Text('Loading members…'),
                      )
                    else if (members.isEmpty)
                      const ListTile(
                        leading: Icon(Icons.person_outline),
                        title: Text('Member list unavailable'),
                        subtitle: Text(
                          'The server did not return the roster for this '
                          'conversation.',
                        ),
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
                    if (!isDm) ...<Widget>[
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.person_add_outlined),
                        title: const Text('Add member'),
                        subtitle: Text(canManage
                            ? 'Look up an account by username'
                            : 'Moderator permission required'),
                        onTap: state.isBusy(Ops.members) || !canManage
                            ? null
                            : () => _addMember(context, myRole),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This is the server\'s membership record. Encrypted delivery '
                'follows a separate group update, so a change here is not by '
                'itself proof of who can decrypt new messages.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              _Header('Safety', theme),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: <Widget>[
                    if (isDm && conversation.peerAccountId != null)
                      _BlockTile(
                        state: state,
                        accountId: conversation.peerAccountId!,
                        label: accountLabel(
                          conversation.peerAccountId!,
                          conversation.peerUsername,
                        ),
                      ),
                    if (isDm && conversation.peerAccountId != null)
                      const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.logout),
                      title: Text(isDm
                          ? 'Leave this conversation'
                          : 'Leave conversation'),
                      subtitle: const Text(
                        'You stop receiving new messages. Messages already on '
                        'other members\' devices are not deleted.',
                      ),
                      onTap: state.isBusy(Ops.members)
                          ? null
                          : () => _confirmLeave(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _Header('Disappearing messages', theme),
              const SizedBox(height: 8),
              Card(
                child: RadioGroup<int?>(
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
                          title: Text(option.label),
                          enabled: !state.busy && canManage,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'When set, messages sent from then on are deleted from the '
                'server after this time window. Existing messages keep the '
                'timer they were sent with.',
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
    _RetentionOption(null, 'Off'),
    _RetentionOption(3600, '1 hour'),
    _RetentionOption(86400, '24 hours'),
    _RetentionOption(604800, '7 days'),
    _RetentionOption(2592000, '30 days'),
  ];

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
      title: 'Remove $label?',
      message: 'They stop receiving new messages in this conversation. '
          'Messages they already received stay on their device, and encrypted '
          'delivery only changes once the group update is committed.',
      confirmLabel: 'Remove',
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
            ? '$label removed from the conversation.'
            : state.errorFor(Ops.members) ?? 'Could not remove $label.'),
      ),
    );
  }

  Future<void> _confirmLeave(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Leave conversation?',
      message: 'You stop receiving new messages and the conversation is '
          'removed from this device. Messages other members already received '
          'are not deleted.',
      confirmLabel: 'Leave',
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
    final description = retentionSeconds == null
        ? 'New messages will no longer disappear. Messages that already have '
            'a timer keep it.'
        : 'Messages sent from now on will be deleted from the server '
            '${retentionLabel(retentionSeconds)} after they are sent. '
            'Existing messages are not affected.';
    final confirmed = await _confirm(
      context,
      title: retentionSeconds == null
          ? 'Turn off disappearing messages?'
          : 'Disappear after ${retentionLabel(retentionSeconds)}?',
      message: description,
      confirmLabel: 'Apply',
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
            child: const Text('Cancel'),
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
      SnackBar(content: Text('$label copied.')),
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
          title: const Text('Add member'),
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
                        label: Text(_roleLabel(option)),
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: picked.isEmpty
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: const Text('Add'),
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
        content: Text(error ??
            'Added ${picked.first.label} to the conversation. Encrypted '
                'delivery starts once the group update is committed.'),
      ),
    );
  }
}

String _roleLabel(String role) {
  switch (role) {
    case 'owner':
      return 'Owner';
    case 'admin':
      return 'Admin';
    case 'moderator':
      return 'Moderator';
    default:
      return 'Member';
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
    final label = accountLabel(member.accountId, member.username);
    final details = <String>[
      _roleLabel(member.role),
      if (isSelf) 'You',
      if (member.joinedAt != null)
        'Joined ${formatDate(context, member.joinedAt!)}',
    ];
    return MergeSemantics(
      child: ListTile(
        leading: ExcludeSemantics(
          child: CircleAvatar(
            backgroundColor: theme.colorScheme.secondaryContainer,
            foregroundColor: theme.colorScheme.onSecondaryContainer,
            child: Text(accountInitials(member.accountId, member.username)),
          ),
        ),
        title: Text(label),
        subtitle: Text(details.join(' · ')),
        trailing: canRemove
            ? IconButton(
                tooltip: 'Remove $label',
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
    return ListTile(
      leading: Icon(blocked ? Icons.person_off : Icons.block),
      title: Text(blocked ? 'Unblock $label' : 'Block $label'),
      subtitle: Text(
        blocked
            ? 'Their messages are hidden from this account until you unblock '
                'them.'
            : 'The server stops delivering their messages to your account. '
                'They are not told, and messages already on your devices stay.',
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
            ? (blocked ? '$label unblocked.' : '$label blocked.')
            : state.errorFor(Ops.blocks) ?? 'Could not update the block.'),
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

class _Header extends StatelessWidget {
  const _Header(this.title, this.theme);

  final String title;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(title, style: theme.textTheme.titleMedium),
    );
  }
}

class _RetentionOption {
  const _RetentionOption(this.seconds, this.label);

  final int? seconds;
  final String label;
}
