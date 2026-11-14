import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/validation.dart';
import '../../ui/widgets/account_picker.dart';

/// Bottom sheet for starting a DM or a private group. It lists the people this
/// device already shares chats with (U27); anyone else is found by exact
/// username via metadata search (or a pasted account ID as fallback). Returns
/// the conversation that was started, or null when the sheet was dismissed.
Future<Conversation?> showNewConversationSheet(
  BuildContext context,
  AppState state,
) async {
  return showModalBottomSheet<Conversation>(
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

/// The people this device already shares a chat with, from local data only:
/// the other person of every direct chat, and the members of every group whose
/// member list this device holds. Never a stranger: a conversation that is
/// still a message request, or hidden, contributes nobody, because starting a
/// chat with someone accepts their request. Never yourself, a blocked account
/// or a community channel's members. Sorted by name.
@visibleForTesting
List<SelectedAccount> knownPeople(AppState state) {
  final own = state.session?.accountId;
  // Someone whose direct chat is still a request stays out even when they
  // also share a group with this person: a tap would accept the request.
  final held = <String?>{
    for (final conversation in state.conversations)
      if (conversation.isDm &&
          state.requestBucket(conversation) != RequestBucket.chat)
        conversation.peerAccountId,
  };
  final people = <String, SelectedAccount>{};
  void add(String accountId, String? username) {
    if (accountId == own ||
        held.contains(accountId) ||
        state.isBlocked(accountId) ||
        people.containsKey(accountId)) {
      return;
    }
    // A shared name never stands in for who someone is (W11): it comes with
    // the username, as in the member list.
    final account = accountLabel(accountId, username);
    final name = state.profileNameOf(accountId);
    people[accountId] = SelectedAccount(
      id: accountId,
      label: name == null || name.isEmpty ? account : '$name ($account)',
    );
  }

  for (final conversation in state.conversations) {
    if (conversation.isCommunityShared ||
        conversation.isChannel ||
        state.requestBucket(conversation) != RequestBucket.chat) {
      continue;
    }
    final peer = conversation.peerAccountId;
    if (conversation.isDm && peer != null) {
      add(peer, conversation.peerUsername);
    }
    if (conversation.isGroup) {
      for (final member in state.membersFor(conversation.id)) {
        add(member.accountId, member.username);
      }
    }
  }
  return people.values.toList()
    ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
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
    final l10n = context.l10n;
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
          Text(l10n.newConversationTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: <ButtonSegment<String>>[
              ButtonSegment<String>(
                value: 'dm',
                label: Text(l10n.newConversationDirect),
                icon: const Icon(Icons.person_outline),
              ),
              ButtonSegment<String>(
                value: 'group',
                label: Text(l10n.newConversationGroup),
                icon: const Icon(Icons.group_outlined),
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
                labelText: l10n.newConversationGroupName,
                prefixIcon: const Icon(Icons.badge_outlined),
                errorText: titleError,
              ),
            ),
            const SizedBox(height: 12),
          ],
          AccountPicker(
            key: ValueKey<String>(kind),
            state: widget.state,
            label: kind == 'dm'
                ? l10n.newConversationWho
                : l10n.newConversationAddMembers,
            maxSelection: kind == 'dm' ? 1 : null,
            suggestions: knownPeople(widget.state),
            onChanged: (value) => setState(() => members = value),
            // Tapping a person you know opens the chat; no second tap.
            onSuggestionPicked: kind == 'dm' ? (_) => _submit() : null,
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
            label: Text(kind == 'dm'
                ? l10n.newConversationStartDm
                : l10n.newConversationCreateGroup),
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
        ? context.l10n.newConversationPickPerson
        : context.l10n.newConversationAddOneMember;
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
      Navigator.of(context).pop(created);
    }
  }
}
