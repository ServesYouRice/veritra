import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../ui/format.dart';
import 'chat_list_screen.dart';

/// Conversation metadata and management: add members by account ID and
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
        return Scaffold(
          appBar: AppBar(title: const Text('Conversation details')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Card(
                child: Column(
                  children: <Widget>[
                    ListTile(
                      leading: CircleAvatar(
                        child: Icon(conversationIcon(conversation)),
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
                        subtitle: Text(formatDateTime(conversation.createdAt!)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('Members', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.person_add_outlined),
                  title: const Text('Add member'),
                  subtitle: const Text('Invite an account by its ID'),
                  onTap: state.busy ? null : () => _addMember(context),
                ),
              ),
              const SizedBox(height: 16),
              Text('Disappearing messages', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: RadioGroup<int?>(
                  groupValue:
                      retention == null || retention == 0 ? null : retention,
                  onChanged: (value) {
                    if (!state.busy) {
                      state.setConversationRetention(conversation.id, value);
                    }
                  },
                  child: Column(
                    children: <Widget>[
                      for (final option in _retentionOptions)
                        RadioListTile<int?>(
                          value: option.seconds,
                          title: Text(option.label),
                          enabled: !state.busy,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'When set, the server deletes encrypted envelopes after this '
                'time window.',
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

  void _copy(BuildContext context, String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied.')),
    );
  }

  Future<void> _addMember(BuildContext context) async {
    final controller = TextEditingController();
    String role = 'member';
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Add member'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: controller,
                  autofocus: true,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Account ID',
                    prefixIcon: Icon(Icons.alternate_email),
                  ),
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
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Add'),
              ),
            ],
          ),
        ),
      );
      final accountId = controller.text.trim();
      if (confirmed != true || accountId.isEmpty) {
        return;
      }
      await state.addConversationMember(conversationId, accountId, role: role);
      if (!context.mounted) {
        return;
      }
      final error = state.error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error ?? 'Member added.')),
      );
    } finally {
      controller.dispose();
    }
  }
}

class _RetentionOption {
  const _RetentionOption(this.seconds, this.label);

  final int? seconds;
  final String label;
}
