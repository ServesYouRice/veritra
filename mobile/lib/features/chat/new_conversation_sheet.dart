import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import '../../ui/validation.dart';
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

  /// Errors show next to their field only after the first submit attempt,
  /// then follow every edit, so an untouched form does not open in red.
  bool attempted = false;

  /// The server's answer to the last attempt. Shown inside the sheet: a
  /// snackbar would sit behind the modal barrier.
  String? submitError;

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleError = attempted && kind == 'group' ? _titleError() : null;
    final membersError = attempted ? _membersError() : null;
    final footerError = membersError ?? submitError;
    // Scrolls so the form stays usable with the keyboard up or at a large
    // text scale, instead of overflowing the sheet.
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
              // The picker below is re-created per kind (different selection
              // limits), so drop any members carried over from the old mode.
              members = <SelectedAccount>[];
              attempted = false;
              submitError = null;
            }),
          ),
          const SizedBox(height: 16),
          if (kind == 'group') ...<Widget>[
            TextField(
              controller: title,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Group name',
                prefixIcon: const Icon(Icons.badge_outlined),
                errorText: titleError,
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
          if (footerError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  footerError,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
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

  String? _titleError() => displayNameError(
        title.text,
        groupName: true,
        l10n: context.l10n,
      );

  String? _membersError() {
    if (members.isNotEmpty) {
      return null;
    }
    return kind == 'dm'
        ? 'Pick the person to message first.'
        : 'Add at least one other member.';
  }

  Future<void> _submit() async {
    // An empty, unnamed group is almost always a mis-tap, and once created it
    // sits in the chat list indistinguishable from the others.
    final invalid =
        _membersError() != null || (kind == 'group' && _titleError() != null);
    setState(() {
      attempted = true;
      submitError = null;
    });
    if (invalid) {
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
    setState(() {
      submitting = false;
      if (created == null) {
        submitError = widget.state.error;
      }
    });
    if (created != null) {
      Navigator.of(context).pop();
    }
  }
}
