import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../crypto/community_info_codec.dart';
import '../../crypto/profile_record_codec.dart';
import '../../l10n/l10n.dart';

/// Edits through encrypted records only. Failed saves keep the draft open.
class EditInfoDialog extends StatefulWidget {
  const EditInfoDialog({
    required this.state,
    required this.community,
    this.channel,
    super.key,
  });

  final AppState state;
  final Community community;
  final Channel? channel;

  @override
  State<EditInfoDialog> createState() => _EditInfoDialogState();
}

class _EditInfoDialogState extends State<EditInfoDialog> {
  late final Session? _owner = widget.state.session;
  late final _name = TextEditingController(
    text: widget.channel != null
        ? widget.state.channelDisplayName(widget.channel!) ?? ''
        : widget.state.communityDisplayName(widget.community) ?? '',
  );
  late final _topic = TextEditingController(
      text: widget.channel == null
          ? ''
          : widget.state.channelTopic(widget.channel!) ?? '');
  bool _saving = false;
  bool _failed = false;

  bool get _allowed =>
      _owner != null &&
      identical(widget.state.session, _owner) &&
      widget.state.mayEditCommunityInfo(widget.community.id,
          widget.channel == null ? infoKindCommunity : infoKindChannel);

  bool get _valid =>
      ProfileRecordCodec.validText(_name.text.trim(), max: infoNameMax) &&
      (widget.channel == null ||
          ProfileRecordCodec.validText(_topic.text.trim(),
              max: infoTopicMax, allowEmpty: true));

  Future<void> _save() async {
    if (_saving || !_allowed || !_valid) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    var saved = false;
    try {
      final channel = widget.channel;
      saved = channel == null
          ? await widget.state.publishCommunityInfo(widget.community.id,
              name: _name.text.trim())
          : await widget.state.publishChannelInfo(channel,
              name: _name.text.trim(), topic: _topic.text.trim());
    } catch (_) {
      // Display fixed copy, never server text or record contents.
    }
    if (!mounted) return;
    if (saved && identical(widget.state.session, _owner)) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final l10n = context.l10n;
          return PopScope(
            canPop: !_saving,
            child: AlertDialog(
              title: Text(widget.channel == null
                  ? l10n.communityEditInfo
                  : l10n.channelEditInfo),
              content: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                    controller: _name,
                    enabled: !_saving && _allowed,
                    autofocus: true,
                    maxLength: infoNameMax,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                        labelText: widget.channel == null
                            ? l10n.communityName
                            : l10n.communityChannelName),
                  ),
                  if (widget.channel != null)
                    TextField(
                      controller: _topic,
                      enabled: !_saving && _allowed,
                      maxLength: infoTopicMax,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(labelText: l10n.channelTopic),
                    ),
                  if (_failed) Text(l10n.communityInfoEditFailed),
                ]),
              ),
              actions: [
                TextButton(
                  onPressed:
                      _saving ? null : () => Navigator.of(context).pop(false),
                  child: Text(l10n.commonCancel),
                ),
                FilledButton(
                  onPressed: !_saving && _allowed && _valid ? _save : null,
                  child: Text(l10n.channelSave),
                ),
              ],
            ),
          );
        },
      );

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    super.dispose();
  }
}
