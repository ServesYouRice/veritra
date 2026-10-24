import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/confirm.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';

/// What opening a message request shows: who it is from and three choices.
/// Nothing from the sender is displayed, fetched or acknowledged until the
/// request is accepted (B8): no messages, no attachments, no read receipt.
///
/// Pops with true when the request was accepted, so the caller can open the
/// conversation.
class MessageRequestScreen extends StatelessWidget {
  const MessageRequestScreen({
    required this.state,
    required this.conversation,
    super.key,
  });

  final AppState state;
  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final peer = conversation.peerUsername;
    final name = peer == null ? l10n.requestUnknownSender : '@$peer';
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.requestsTitle),
      body: ListView(
        padding: const EdgeInsets.all(BoneSpacing.gutter),
        children: <Widget>[
          Icon(
            Icons.mark_chat_unread_outlined,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: BoneSpacing.lg),
          Text(
            l10n.requestFrom(name),
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: BoneSpacing.sm),
          Text(
            l10n.requestExplanation,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: BoneSpacing.xl),
          FilledButton(
            onPressed: () async {
              await state.acceptMessageRequest(conversation.id);
              if (context.mounted) Navigator.of(context).pop(true);
            },
            child: Text(l10n.requestAccept),
          ),
          const SizedBox(height: BoneSpacing.sm),
          OutlinedButton(
            onPressed: () => _block(context, name),
            child: Text(l10n.requestBlock),
          ),
          const SizedBox(height: BoneSpacing.sm),
          TextButton(
            onPressed: () => _delete(context),
            child: Text(l10n.requestDelete),
          ),
        ],
      ),
    );
  }

  Future<void> _block(BuildContext context, String name) async {
    final l10n = context.l10n;
    final confirmed = await confirmAction(
      context,
      title: l10n.requestBlockTitle,
      message: l10n.requestBlockMessage(name),
      confirmLabel: l10n.requestBlock,
      destructive: true,
    );
    if (!confirmed) return;
    final ok = await state.blockMessageRequest(conversation.id);
    if (context.mounted) _finish(context, ok);
  }

  Future<void> _delete(BuildContext context) async {
    final l10n = context.l10n;
    final confirmed = await confirmAction(
      context,
      title: l10n.requestDeleteTitle,
      message: l10n.requestDeleteMessage,
      confirmLabel: l10n.requestDelete,
      destructive: true,
    );
    if (!confirmed) return;
    final ok = await state.deleteMessageRequest(conversation.id);
    if (context.mounted) _finish(context, ok);
  }

  void _finish(BuildContext context, bool ok) {
    if (ok) {
      Navigator.of(context).pop(false);
      return;
    }
    final error = state.errorFor(Ops.members) ?? state.errorFor(Ops.blocks);
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }
}
