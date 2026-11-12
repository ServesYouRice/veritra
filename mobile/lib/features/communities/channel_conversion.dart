import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';

/// C3 conversion: asks an owner or admin to confirm making a private
/// channel open (owner answer 2026-11-12). Its earlier posts carry over, so
/// they become visible to everyone who can read the open channel. Making
/// an open channel private asks who stays instead
/// ([pickChannelConversionMembers]).
Future<bool> confirmChannelConversion(BuildContext context,
    {required bool toPrivate}) async {
  if (toPrivate) return true;
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.channelConvertOpenTitle),
      content: SingleChildScrollView(
        child: Text(l10n.channelConvertOpenConfirm),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.channelConvertOpenAccept),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// C3 conversion, open to private (owner answer 2026-11-12, "Admin picks
/// during switch"): lists the open [channel]'s current readers, all ticked,
/// and returns the account ids still ticked when the admin accepts, or
/// null when they cancel. Unticked readers are never added. The admin
/// cannot accept until the readers have loaded: a failed load must not
/// read as "nobody ticked".
Future<List<String>?> pickChannelConversionMembers(
    BuildContext context, AppState state, Channel channel) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => _ConversionMembersDialog(
      readers: state.channelReaders(channel),
    ),
  );
}

class _ConversionMembersDialog extends StatefulWidget {
  const _ConversionMembersDialog({required this.readers});

  final Future<List<ConversationMember>> readers;

  @override
  State<_ConversionMembersDialog> createState() =>
      _ConversionMembersDialogState();
}

class _ConversionMembersDialogState extends State<_ConversionMembersDialog> {
  List<ConversationMember>? _readers;
  final _unticked = <String>{};
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.readers.then((readers) {
      if (mounted) setState(() => _readers = readers);
    }, onError: (Object _) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final readers = _readers;
    final Widget content;
    if (_failed) {
      content = Text(l10n.channelConvertReadersFailed);
    } else if (readers == null) {
      content = const Center(child: CircularProgressIndicator());
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(readers.isEmpty
              ? l10n.channelConvertPrivateNoReaders
              : l10n.channelConvertPrivatePick),
          for (final reader in readers)
            CheckboxListTile(
              value: !_unticked.contains(reader.accountId),
              onChanged: (ticked) => setState(() => ticked == true
                  ? _unticked.remove(reader.accountId)
                  : _unticked.add(reader.accountId)),
              title: Text(accountLabel(reader.accountId, reader.username)),
              contentPadding: EdgeInsets.zero,
            ),
        ],
      );
    }
    return AlertDialog(
      title: Text(l10n.channelConvertPrivateTitle),
      content: SingleChildScrollView(child: content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: readers == null
              ? null
              : () => Navigator.of(context).pop(<String>[
                    for (final reader in readers)
                      if (!_unticked.contains(reader.accountId))
                        reader.accountId,
                  ]),
          child: Text(l10n.channelConvertPrivateAccept),
        ),
      ],
    );
  }
}

/// The conversion action in a channel's settings, for owners and admins
/// ([AppState.mayConvertChannel]). On success it closes the dialog it sits
/// in: the channel has a new home.
class ChannelConversionAction extends StatefulWidget {
  const ChannelConversionAction(
      {required this.state, required this.channel, super.key});

  final AppState state;
  final Channel channel;

  @override
  State<ChannelConversionAction> createState() =>
      _ChannelConversionActionState();
}

class _ChannelConversionActionState extends State<ChannelConversionAction> {
  bool _sending = false;

  bool get _toPrivate => widget.channel.kind != 'private';

  Future<void> _convert() async {
    var members = const <String>[];
    if (_toPrivate) {
      final picked = await pickChannelConversionMembers(
          context, widget.state, widget.channel);
      if (picked == null || !mounted) return;
      members = picked;
    } else {
      final confirmed =
          await confirmChannelConversion(context, toPrivate: _toPrivate);
      if (!confirmed || !mounted) return;
    }
    setState(() => _sending = true);
    final done = await widget.state.convertChannel(widget.channel,
        toPrivate: _toPrivate, members: members);
    if (!mounted) return;
    setState(() => _sending = false);
    if (done) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        onPressed: _sending ? null : _convert,
        icon: Icon(_toPrivate ? Icons.lock_outline : Icons.lock_open_outlined),
        label: Text(_toPrivate
            ? l10n.channelConvertToPrivate
            : l10n.channelConvertToOpen),
      ),
    );
  }
}
