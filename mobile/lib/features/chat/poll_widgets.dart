import 'package:flutter/material.dart';

import '../../crypto/poll.dart';
import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';

/// A poll inside a message bubble (B3). Tapping an option votes; tapping your
/// own choice again takes it back. [members] limits the count to accounts in
/// the current roster; null counts every voter.
class PollCard extends StatelessWidget {
  const PollCard({
    super.key,
    required this.poll,
    required this.ownAccountId,
    required this.members,
    required this.onVote,
    this.onClose,
  });

  final PollView poll;
  final String? ownAccountId;
  final Set<String>? members;

  /// Sends the new choice list for this account; null when voting is not
  /// possible here (read-only conversation).
  final void Function(List<int> choices)? onVote;

  /// Closes the poll; set only for the poll's author while it is open.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final counts = poll.tally(members: members);
    final voters = poll.voterCount(members: members);
    final close = poll.closed ? null : onClose;
    final own = ownAccountId == null
        ? const <int>[]
        : (poll.votes[ownAccountId] ?? const <int>[]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(poll.question, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          poll.multipleChoice ? l10n.pollChooseSeveral : l10n.pollChooseOne,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: BoneSpacing.xs),
        for (var index = 0; index < poll.options.length; index++)
          _option(context, index, counts[index], voters, own),
        const SizedBox(height: 4),
        Text(
          l10n.pollVoteTotal(voters.toString()),
          style: theme.textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (poll.closed)
          Text(
            l10n.pollClosedNotice,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (close != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: close,
              child: Text(l10n.pollClose),
            ),
          ),
        Text(
          l10n.pollVisibleNotice,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _option(
      BuildContext context, int index, int count, int voters, List<int> own) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chosen = own.contains(index);
    final vote = poll.closed ? null : onVote;
    return InkWell(
      onTap: vote == null
          ? null
          : () {
              final next = poll.multipleChoice
                  ? (chosen
                      ? <int>[
                          for (final i in own)
                            if (i != index) i
                        ]
                      : <int>[...own, index])
                  : (chosen ? const <int>[] : <int>[index]);
              vote(next);
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  chosen
                      ? (poll.multipleChoice
                          ? Icons.check_box
                          : Icons.radio_button_checked)
                      : (poll.multipleChoice
                          ? Icons.check_box_outline_blank
                          : Icons.radio_button_unchecked),
                  size: 18,
                  color: chosen ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(poll.options[index],
                      style: theme.textTheme.bodyMedium),
                ),
                const SizedBox(width: 8),
                Text(count.toString(), style: theme.textTheme.labelMedium),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: voters == 0 ? 0 : count / voters,
                minHeight: 4,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the poll composer returns.
typedef PollDraft = ({
  String question,
  List<String> options,
  bool multipleChoice,
});

/// The "new poll" dialog. Null when cancelled.
Future<PollDraft?> showPollComposer(BuildContext context) =>
    showDialog<PollDraft>(
      context: context,
      builder: (_) => const _PollComposerDialog(),
    );

class _PollComposerDialog extends StatefulWidget {
  const _PollComposerDialog();

  @override
  State<_PollComposerDialog> createState() => _PollComposerDialogState();
}

class _PollComposerDialogState extends State<_PollComposerDialog> {
  final TextEditingController _question = TextEditingController();
  final List<TextEditingController> _options = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multiple = false;

  @override
  void dispose() {
    _question.dispose();
    for (final controller in _options) {
      controller.dispose();
    }
    super.dispose();
  }

  PollDraft get _draft => (
        question: _question.text.trim(),
        options: [for (final option in _options) option.text.trim()],
        multipleChoice: _multiple,
      );

  bool get _valid => isValidPollBody(<String, Object?>{
        'question': _draft.question,
        'options': _draft.options,
        'multiple_choice': _multiple,
      });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.pollComposerTitle),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _question,
                maxLength: maxPollQuestionLength,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: l10n.pollQuestionLabel,
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
              ),
              for (var index = 0; index < _options.length; index++)
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _options[index],
                        maxLength: maxPollOptionLength,
                        decoration: InputDecoration(
                          labelText: l10n.pollOptionLabel('${index + 1}'),
                          counterText: '',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    if (_options.length > minPollOptions)
                      IconButton(
                        tooltip: l10n.pollRemoveOption,
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          final removed = _options[index];
                          setState(() => _options.removeAt(index));
                          // Disposed after the field using it is gone.
                          WidgetsBinding.instance
                              .addPostFrameCallback((_) => removed.dispose());
                        },
                      ),
                  ],
                ),
              if (_options.length < maxPollOptions)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: Text(l10n.pollAddOption),
                    onPressed: () =>
                        setState(() => _options.add(TextEditingController())),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.pollMultipleChoice),
                value: _multiple,
                onChanged: (value) => setState(() => _multiple = value),
              ),
              Text(
                _valid ? l10n.pollVisibleNotice : l10n.pollInvalidHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _valid ? () => Navigator.of(context).pop(_draft) : null,
          child: Text(l10n.pollSend),
        ),
      ],
    );
  }
}
