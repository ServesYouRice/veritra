import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import '../../storage/encrypted_database.dart'
    show LocalMessage, LocalMessageKind;
import '../../storage/history_snapshot.dart' show HistoryConversation;
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import 'formatted_message.dart';

/// Conversations copied from another device (K2) that this device is not a
/// member of. Read-only: there is no composer and no message action, and
/// nothing on these screens talks to the server.
class CopiedHistoryListScreen extends StatelessWidget {
  const CopiedHistoryListScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final items = state.historyOnlyConversations;
        return Scaffold(
          appBar: AppBar(title: Text(context.l10n.k2HistoryOnlyTitle)),
          body: items.isEmpty
              ? EmptyState(
                  icon: Icons.history,
                  title: context.l10n.k2HistoryOnlyTitle,
                  message: context.l10n.k2HistoryEmpty)
              : ListView(
                  children: <Widget>[
                    _Notice(text: context.l10n.k2HistoryOnlyNotice),
                    for (final item in items)
                      ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(historyTitle(context, item)),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CopiedHistoryScreen(
                                state: state, conversation: item),
                          ),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}

String historyTitle(BuildContext context, HistoryConversation c) {
  final title = c.title?.trim();
  return title == null || title.isEmpty
      ? context.l10n.k2HistoryUntitled
      : title;
}

/// One copied conversation, shown read-only from local encrypted storage.
/// Sender names are not part of the copy, so other members are shown as
/// "Another member"; attachments are listed but never downloaded.
class CopiedHistoryScreen extends StatefulWidget {
  const CopiedHistoryScreen(
      {required this.state, required this.conversation, super.key});

  final AppState state;
  final HistoryConversation conversation;

  @override
  State<CopiedHistoryScreen> createState() => _CopiedHistoryScreenState();
}

class _CopiedHistoryScreenState extends State<CopiedHistoryScreen> {
  late Future<List<LocalMessage>> _messages =
      widget.state.historyOnlyMessages(widget.conversation.id);

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_reload);
  }

  @override
  void dispose() {
    widget.state.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _messages = widget.state.historyOnlyMessages(widget.conversation.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final own = widget.state.session?.accountId;
    return Scaffold(
      appBar: AppBar(title: Text(historyTitle(context, widget.conversation))),
      body: Column(
        children: <Widget>[
          _Notice(text: context.l10n.k2HistoryOnlyNotice),
          Expanded(
            child: FutureBuilder<List<LocalMessage>>(
              future: _messages,
              builder: (context, snapshot) {
                final rows = snapshot.data;
                if (rows == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (rows.isEmpty) {
                  return EmptyState(
                      icon: Icons.history,
                      title: historyTitle(context, widget.conversation),
                      message: context.l10n.k2HistoryEmpty);
                }
                return ListView.builder(
                  key: const ValueKey('copied-history-messages'),
                  itemCount: rows.length,
                  itemBuilder: (context, i) => _Row(
                      message: rows[i], own: rows[i].senderAccountId == own),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('copied-history-notice'),
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(
          horizontal: BoneSpacing.gutter, vertical: BoneSpacing.sm),
      child: Row(
        children: <Widget>[
          const Icon(Icons.lock_outline, size: 18),
          const SizedBox(width: BoneSpacing.sm),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.message, required this.own});
  final LocalMessage message;
  final bool own;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final Widget body = switch (message.kind) {
      LocalMessageKind.text => FormattedMessage(
          // No mention callback: copied history never looks up a profile.
          text: message.body ?? '',
          formatJson: message.formatJson),
      LocalMessageKind.attachment => Text(l10n.k2HistoryAttachment,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontStyle: FontStyle.italic)),
      _ => Text(l10n.chatMessageUnsupported,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontStyle: FontStyle.italic)),
    };
    final at = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: BoneSpacing.gutter, vertical: BoneSpacing.sm),
      child: Column(
        crossAxisAlignment:
            own ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          Text(
              '${own ? l10n.detailsYou : l10n.k2HistoryOtherMember} · '
              '${formatDateTime(context, at)}',
              style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          body,
        ],
      ),
    );
  }
}
