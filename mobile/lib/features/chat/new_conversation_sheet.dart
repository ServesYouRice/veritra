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

  /// Set by the first submit. Problems are then shown inline under the
  /// field they concern and re-checked as the form changes, instead of in a
  /// snack bar that the sheet itself covers.
  bool attempted = false;
  String? submitError;

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scrolls when the keyboard and a large text scale leave the sheet less
    // height than the form needs, instead of overflowing it.
    return SingleChildScrollView(
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
              attempted = false;
              submitError = null;
              // The picker below is re-created per kind (different selection
              // limits), so drop any members carried over from the old mode.
              members = <SelectedAccount>[];
            }),
          ),
          const SizedBox(height: 16),
          if (kind == 'group') ...<Widget>[
            TextField(
              controller: title,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (attempted) setState(() {});
              },
              decoration: InputDecoration(
                labelText: 'Group name',
                prefixIcon: const Icon(Icons.badge_outlined),
                errorText: attempted ? _titleProblem() : null,
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
          if (attempted && _membersProblem() != null)
            _InlineProblem(message: _membersProblem()!),
          if (submitError != null) _InlineProblem(message: submitError!),
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

  String? _titleProblem() => kind == 'group' && title.text.trim().isEmpty
      ? 'Give the group a name.'
      : null;

  String? _membersProblem() {
    if (members.isNotEmpty) return null;
    return kind == 'dm'
        ? 'Pick the person to message first.'
        : 'Add at least one other member.';
  }

  Future<void> _submit() async {
    // An empty, unnamed group is almost always a mis-tap, and once created it
    // sits in the chat list indistinguishable from the others.
    setState(() {
      attempted = true;
      submitError = null;
    });
    if (_titleProblem() != null || _membersProblem() != null) {
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
      setState(() => submitError = widget.state.error);
    }
  }
}

/// A form problem shown under the control it concerns, announced when it
/// appears.
class _InlineProblem extends StatelessWidget {
  const _InlineProblem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, left: 12),
        child: Text(
          message,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}
