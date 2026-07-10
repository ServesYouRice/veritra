import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../ui/widgets/account_picker.dart';

/// Bottom sheet for starting a DM or a private group. Members are picked by
/// exact username via metadata search (or a pasted account ID as fallback).
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
  List<SelectedAccount> members = <SelectedAccount>[];
  String kind = 'dm';
  bool submitting = false;

  @override
  void dispose() {
    title.dispose();
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
            onSelectionChanged: (value) => setState(() {
              kind = value.first;
              // The picker below is re-created per kind (different selection
              // limits), so drop any members carried over from the old mode.
              members = <SelectedAccount>[];
            }),
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
          AccountPicker(
            key: ValueKey<String>(kind),
            state: widget.state,
            label: kind == 'dm' ? 'Who do you want to message?' : 'Add members',
            maxSelection: kind == 'dm' ? 1 : null,
            onChanged: (value) => setState(() => members = value),
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
    if (kind == 'dm' && members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pick the person to message first.'),
        ),
      );
      return;
    }
    setState(() => submitting = true);
    final created = await widget.state.startConversation(
      kind: kind,
      title: kind == 'group' ? title.text.trim() : null,
      memberAccountIds:
          members.map((account) => account.id).toList(growable: false),
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
