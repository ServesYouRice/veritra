import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';

/// C3 conversion: asks an owner or admin to confirm making a private
/// channel open (owner answer 2026-11-12). Its earlier posts carry over:
/// with channel history on and the channel keeping its full history
/// ([earlierOpen]), the `move` record opens them for everyone who can read
/// the open channel; otherwise they stay with the people who already had
/// them (review INFO). Making an open channel private asks who stays
/// instead ([pickChannelConversionMembers]).
Future<bool> confirmChannelConversion(BuildContext context,
    {required bool toPrivate, bool earlierOpen = true}) async {
  if (toPrivate) return true;
  final l10n = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.channelConvertOpenTitle),
      content: SingleChildScrollView(
        child: Text(earlierOpen
            ? l10n.channelConvertOpenConfirm
            : l10n.channelConvertOpenConfirmKept),
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
/// and returns the readers still ticked when the admin accepts, or null
/// when they cancel. Unticked readers are never added. The admin cannot
/// accept until the readers have loaded: a failed load must not read as
/// "nobody ticked".
Future<List<ConversationMember>?> pickChannelConversionMembers(
    BuildContext context, AppState state, Channel channel) {
  // Fetched once, whatever rebuilds the dialog's route; a failure is null
  // here, never an error left unhandled until the dialog listens.
  final readers = state.channelReaders(channel).then<List<ConversationMember>?>(
      (readers) => readers,
      onError: (Object _) => null);
  return showDialog<List<ConversationMember>>(
    context: context,
    builder: (_) => _ConversionMembersDialog(readers: readers),
  );
}

class _ConversionMembersDialog extends StatefulWidget {
  const _ConversionMembersDialog({required this.readers});

  /// Null when they could not be loaded.
  final Future<List<ConversationMember>?> readers;

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
      if (!mounted) return;
      setState(() {
        _readers = readers;
        _failed = readers == null;
      });
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
              : () => Navigator.of(context).pop(<ConversationMember>[
                    for (final reader in readers)
                      if (!_unticked.contains(reader.accountId)) reader,
                  ]),
          child: Text(l10n.channelConvertPrivateAccept),
        ),
      ],
    );
  }
}

/// The conversion action in a channel's settings, for owners and admins
/// ([AppState.mayConvertChannel]). On success it closes the dialog it sits
/// in: the channel has a new home. Ticked readers the server refused to add
/// are named in a snack bar first, so the admin can add them by hand.
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
    var members = const <ConversationMember>[];
    if (_toPrivate) {
      final picked = await pickChannelConversionMembers(
          context, widget.state, widget.channel);
      if (picked == null || !mounted) return;
      members = picked;
    } else {
      // Unknown reads as open: the warning never says less than happens.
      final view = widget.state.channelHistoryAvailable
          ? await widget.state.channelHistory(widget.channel)
          : null;
      if (!mounted) return;
      final earlierOpen = widget.state.channelHistoryAvailable &&
          (view == null || view.full || view.pending);
      final confirmed = await confirmChannelConversion(context,
          toPrivate: _toPrivate, earlierOpen: earlierOpen);
      if (!confirmed || !mounted) return;
    }
    setState(() => _sending = true);
    final done = await widget.state.convertChannel(widget.channel,
        toPrivate: _toPrivate,
        members: <String>[for (final member in members) member.accountId]);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!done) return;
    final notAdded = widget.state.channelConversionNotAdded;
    if (notAdded.isNotEmpty) {
      final names = <String>[
        for (final account in notAdded)
          accountLabel(
              account,
              members
                  .where((member) => member.accountId == account)
                  .firstOrNull
                  ?.username),
      ].join(', ');
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.channelConvertNotAdded(names))));
    }
    Navigator.of(context).pop(false);
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
