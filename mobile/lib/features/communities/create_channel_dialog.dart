import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/validation.dart';

/// Creates once, then retries only member additions that did not succeed.
/// Membership still goes through AppState's ordinary MLS reconciliation.
class CreateChannelDialog extends StatefulWidget {
  const CreateChannelDialog(
      {required this.state, required this.community, super.key});

  final AppState state;
  final Community community;

  @override
  State<CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<CreateChannelDialog> {
  final _name = TextEditingController();
  final _selected = <String>{};
  List<ConversationMember>? _members;
  Channel? _created;
  bool _private = false;
  bool _loading = true;
  bool _saving = false;
  bool _failed = false;
  Session? _owner;

  @override
  void initState() {
    super.initState();
    _owner = widget.state.session;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final members =
        await widget.state.loadCommunityMembers(widget.community.id);
    if (!mounted) return;
    setState(() {
      _members = identical(widget.state.session, _owner) ? members : null;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      if (!identical(widget.state.session, _owner)) {
        setState(() => _failed = true);
        return;
      }
      _created ??= await widget.state.createChannel(
          widget.community.id, _name.text.trim(),
          kind: _private ? 'private' : 'open');
      final channel = _created;
      if (channel == null || !identical(widget.state.session, _owner)) {
        if (mounted) setState(() => _failed = true);
        return;
      }
      if (_private) {
        final conversationId = channel.conversationId;
        if (conversationId == null && _selected.isNotEmpty) {
          if (mounted) setState(() => _failed = true);
          return;
        }
        for (final account in List.of(_selected)) {
          if (!identical(widget.state.session, _owner)) break;
          final added = await widget.state
              .addConversationMember(conversationId!, account);
          if (added) _selected.remove(account);
        }
      }
      if (!mounted) return;
      if (!identical(widget.state.session, _owner) ||
          (_selected.isNotEmpty && _private)) {
        setState(() => _failed = true);
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final self = widget.state.session?.accountId;
    final admin = _members?.any((m) =>
            m.accountId == self && (m.role == 'owner' || m.role == 'admin')) ??
        false;
    final fixed = _saving || _created != null;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(l10n.communityNewChannel),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _name,
                  enabled: !fixed,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: l10n.communityChannelName,
                    errorText: _name.text.isEmpty
                        ? null
                        : displayNameError(_name.text, l10n: l10n),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.channelPrivate),
                  value: _private,
                  onChanged:
                      fixed || widget.community.sharedConversationId == null
                          ? null
                          : (value) => setState(() => _private = value),
                ),
                Text(_private
                    ? l10n.channelPrivateDisclosure
                    : l10n.channelOpenDisclosure),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_members == null) ...[
                  Text(l10n.detailsMembersUnavailable),
                  TextButton(onPressed: _load, child: Text(l10n.commonRetry)),
                ] else if (!admin)
                  Text(l10n.channelAdminOnly)
                else if (_private) ...[
                  const SizedBox(height: 16),
                  Text(l10n.detailsSectionMembers),
                  for (final member in _members!)
                    if (member.accountId != self)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(member.username ?? member.accountId),
                        value: _selected.contains(member.accountId),
                        onChanged: fixed
                            ? null
                            : (value) => setState(() {
                                  if (value == true) {
                                    _selected.add(member.accountId);
                                  } else {
                                    _selected.remove(member.accountId);
                                  }
                                }),
                      ),
                ],
                if (_failed)
                  Text(_created == null
                      ? l10n.channelCreateFailed
                      : l10n.channelMembersFailed),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: _saving ||
                    _loading ||
                    !admin ||
                    displayNameError(_name.text, l10n: l10n) != null
                ? null
                : _save,
            child:
                Text(_created == null ? l10n.commonCreate : l10n.commonRetry),
          ),
        ],
      ),
    );
  }
}
