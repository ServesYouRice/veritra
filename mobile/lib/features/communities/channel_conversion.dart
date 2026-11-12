import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';

/// C3 conversion: asks an owner or admin to confirm making a private
/// channel open (owner answer 2026-11-12). Its earlier posts carry over, so
/// they become visible to everyone who can read the open channel. Making
/// an open channel private needs no warning: it narrows who reads it.
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
    final confirmed =
        await confirmChannelConversion(context, toPrivate: _toPrivate);
    if (!confirmed || !mounted) return;
    setState(() => _sending = true);
    final done = await widget.state
        .convertChannel(widget.channel, toPrivate: _toPrivate);
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
