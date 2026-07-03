import 'package:flutter/material.dart';

import '../../core/app_state.dart';

/// Bottom sheet for starting a DM or a private group. The server accepts a
/// title and initial member account IDs; there is no directory endpoint yet,
/// so members are added by account ID.
Future<void> showNewConversationSheet(
  BuildContext context,
  AppState state,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: _NewConversationForm(state: state),
    ),
  );
}

class _NewConversationForm extends StatefulWidget {
  const _NewConversationForm({required this.state});

  final AppState state;

  @override
  State<_NewConversationForm> createState() => _NewConversationFormState();
}

class _NewConversationFormState extends State<_NewConversationForm> {
  final title = TextEditingController();
  final memberIds = TextEditingController();
  String kind = 'dm';
  bool submitting = false;

  @override
  void dispose() {
    title.dispose();
    memberIds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('New conversation', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(
                value: 'dm',
                label: Text('Direct message'),
                icon: Icon(Icons.person_outline),
              ),
              ButtonSegment<String>(
                value: 'group',
                label: Text('Group'),
                icon: Icon(Icons.group_outlined),
              ),
            ],
            selected: <String>{kind},
            onSelectionChanged: (value) => setState(() => kind = value.first),
          ),
          const SizedBox(height: 16),
          if (kind == 'group') ...<Widget>[
            TextField(
              controller: title,
              decoration: const InputDecoration(
                labelText: 'Group name',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: memberIds,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: kind == 'dm' ? 'Account ID' : 'Member account IDs',
              helperText: kind == 'dm'
                  ? 'The account ID of the person to message.'
                  : 'Comma-separated account IDs (optional).',
              prefixIcon: const Icon(Icons.alternate_email),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: submitting ? null : _submit,
            icon: const Icon(Icons.add_comment_outlined),
            label: Text(kind == 'dm' ? 'Start DM' : 'Create group'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final members = memberIds.text
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (kind == 'dm' && members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter the account ID to start a direct message.'),
        ),
      );
      return;
    }
    setState(() => submitting = true);
    final created = await widget.state.startConversation(
      kind: kind,
      title: kind == 'group' ? title.text.trim() : null,
      memberAccountIds: members,
    );
    if (!mounted) {
      return;
    }
    setState(() => submitting = false);
    if (created != null) {
      Navigator.of(context).pop();
    } else if (widget.state.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.state.error!)),
      );
    }
  }
}
