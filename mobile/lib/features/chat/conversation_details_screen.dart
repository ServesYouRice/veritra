import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../ui/format.dart';
import '../../ui/widgets/account_picker.dart';
import 'chat_list_screen.dart';

/// Conversation metadata and management: add members by username lookup and
/// configure disappearing-message retention. The server exposes no member
/// list endpoint yet, so membership is write-only here.
class ConversationDetailsScreen extends StatelessWidget {
  const ConversationDetailsScreen({
    required this.state,
    required this.conversationId,
    super.key,
  });

  final AppState state;
  final String conversationId;

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
        final canManage = const <String>{'owner', 'admin', 'moderator'}
            .contains(conversation.currentRole);
        return Scaffold(
          appBar: AppBar(title: const Text('Conversation details')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Card(
                child: Column(
                  children: <Widget>[
                    ListTile(
                      // Decorative: the conversation title names it already.
                      leading: ExcludeSemantics(
                        child: CircleAvatar(
                          child: Icon(conversationIcon(conversation)),
                        ),
                      ),
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
              Semantics(
                header: true,
                child: Text('Members', style: theme.textTheme.titleMedium),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.person_add_outlined),
                  title: const Text('Add member'),
                  subtitle: Text(canManage
                      ? 'Look up an account by username'
                      : 'Moderator permission required'),
                  onTap: state.busy || !canManage
                      ? null
                      : () => _addMember(context),
                ),
              ),
              const SizedBox(height: 16),
              Semantics(
                header: true,
                child: Text(
                  'Disappearing messages',
                  style: theme.textTheme.titleMedium,
                ),
              ),
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
            ],
          ),
        );
      },
    );
  }

  static const _retentionOptions = <_RetentionOption>[
    _RetentionOption(null, 'Off'),
    _RetentionOption(3600, '1 hour'),
    _RetentionOption(86400, '24 hours'),
    _RetentionOption(604800, '7 days'),
    _RetentionOption(2592000, '30 days'),
  ];

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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(retentionSeconds == null
            ? 'Turn off disappearing messages?'
            : 'Disappear after ${retentionLabel(retentionSeconds)}?'),
        content: Text(description),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.setConversationRetention(conversationId, retentionSeconds);
    }
  }

  void _copy(BuildContext context, String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied.')),
    );
  }

  Future<void> _addMember(BuildContext context) async {
    String role = 'member';
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
                SegmentedButton<String>(
                  segments: const <ButtonSegment<String>>[
                    ButtonSegment<String>(
                      value: 'member',
                      label: Text('Member'),
                    ),
                    ButtonSegment<String>(
                      value: 'moderator',
                      label: Text('Moderator'),
                    ),
                    ButtonSegment<String>(
                      value: 'admin',
                      label: Text('Admin'),
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
    if (!context.mounted) {
      return;
    }
    final error = state.error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ??
            'Added ${picked.first.label} to the '
                'conversation.'),
      ),
    );
  }
}

class _RetentionOption {
  const _RetentionOption(this.seconds, this.label);

  final int? seconds;
  final String label;
}
