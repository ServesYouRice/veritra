import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../crypto/crypto_service.dart' show C7ChannelView;
import '../../crypto/community_info_codec.dart';
import '../../crypto/profile_record_codec.dart';
import '../../l10n/l10n.dart';
import 'channel_conversion.dart';
import 'channel_history_warning.dart';

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
                  if (widget.channel != null &&
                      widget.channel!.isRouted &&
                      widget.state.channelHistoryAvailable &&
                      widget.state.canCreateChannel(widget.community.id))
                    ChannelHistorySetting(
                        state: widget.state, channel: widget.channel!),
                  if (widget.channel != null &&
                      widget.state.mayConvertChannel(widget.channel!))
                    ChannelConversionAction(
                        state: widget.state, channel: widget.channel!),
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

/// C7: a channel's history setting for owners and admins (decision 1, D80).
/// A change is a record that applies when it comes back in sync order; until
/// then the switch shows it pending.
class ChannelHistorySetting extends StatefulWidget {
  const ChannelHistorySetting(
      {required this.state, required this.channel, super.key});

  final AppState state;
  final Channel channel;

  @override
  State<ChannelHistorySetting> createState() => _ChannelHistorySettingState();
}

class _ChannelHistorySettingState extends State<ChannelHistorySetting> {
  late Future<C7ChannelView?> _view =
      widget.state.channelHistory(widget.channel);
  bool _sending = false;

  // A block, not an arrow: setState must not be handed the Future.
  void _reload() => setState(() {
        _view = widget.state.channelHistory(widget.channel);
      });

  Future<void> _change(bool full) async {
    final confirmed = await confirmChannelHistory(context, full: full);
    if (!confirmed || !mounted) return;
    setState(() => _sending = true);
    await widget.state.setChannelHistory(widget.channel, full: full);
    if (!mounted) return;
    setState(() => _sending = false);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<C7ChannelView?>(
      future: _view,
      builder: (context, snapshot) {
        final view = snapshot.data;
        if (view == null) return const SizedBox.shrink();
        final note = view.pending
            ? l10n.channelHistoryPending
            : switch (view.ownNotice) {
                'timeout' => l10n.channelHistoryTimeout,
                'lost' => l10n.channelHistoryLost,
                _ => view.full && view.status != 'ok'
                    ? l10n.channelHistoryPaused
                    : null,
              };
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.channelHistoryFullLabel),
          subtitle: Text(note == null
              ? l10n.channelHistoryProofLine
              : '${l10n.channelHistoryProofLine}\n$note'),
          value: view.full,
          onChanged: _sending || view.pending ? null : _change,
        );
      },
    );
  }
}
