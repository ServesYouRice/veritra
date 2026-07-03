import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/format.dart';
import '../../ui/widgets/empty_state.dart';
import 'chat_list_screen.dart';
import 'conversation_details_screen.dart';

/// Conversation detail screen. Pushed from the chat list; listens to the app
/// state itself because pushed routes sit outside the root rebuild scope.
class ChatScreen extends StatefulWidget {
  const ChatScreen({required this.state, super.key});

  final AppState state;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final composer = TextEditingController();

  @override
  void dispose() {
    composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final conversation = widget.state.selectedConversation;
        final messages = widget.state.selectedMessages;
        return Scaffold(
          appBar: AppBar(
            title: conversation == null
                ? const Text('Conversation')
                : Row(
                    children: <Widget>[
                      CircleAvatar(
                        radius: 16,
                        child: Icon(conversationIcon(conversation), size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          conversationTitle(conversation),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
            actions: <Widget>[
              if (conversation != null)
                IconButton(
                  tooltip: 'Conversation details',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ConversationDetailsScreen(
                        state: widget.state,
                        conversationId: conversation.id,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.info_outline),
                ),
            ],
          ),
          body: Column(
            children: <Widget>[
              Expanded(
                child: conversation == null
                    ? const EmptyState(
                        icon: Icons.forum_outlined,
                        title: 'No conversation selected',
                        message: 'Pick a conversation from the chat list.',
                      )
                    : messages.isEmpty
                        ? const EmptyState(
                            icon: Icons.lock_outline,
                            title: 'No messages yet',
                            message:
                                'Messages are stored as encrypted envelopes '
                                'only the members can read.',
                          )
                        : _MessageList(state: widget.state, messages: messages),
              ),
              _Composer(
                enabled: conversation != null,
                controller: composer,
                busy: widget.state.busy,
                onSend: _send,
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _send() async {
    final text = composer.text.trim();
    if (text.isEmpty) {
      return;
    }
    await widget.state.sendMessage(text);
    if (!mounted) {
      return;
    }
    final error = widget.state.error;
    if (error == null) {
      composer.clear();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.state, required this.messages});

  final AppState state;
  final List<ReceivedMessageEnvelope> messages;

  @override
  Widget build(BuildContext context) {
    // Messages arrive newest-first; the list is reversed so index 0 renders
    // at the bottom. A day separator is emitted whenever the calendar day
    // changes relative to the next-older message.
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final mine = message.senderAccountId == state.session?.accountId;
        final older = index + 1 < messages.length ? messages[index + 1] : null;
        final showDay = older == null ||
            formatDate(older.createdAt) != formatDate(message.createdAt);
        return Column(
          children: <Widget>[
            if (showDay) _DaySeparator(label: formatDate(message.createdAt)),
            _MessageBubble(message: message, mine: mine),
          ],
        );
      },
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label, style: theme.textTheme.labelSmall),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.mine});

  final ReceivedMessageEnvelope message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final deleted = message.deletedAt != null;
    final background =
        mine ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    final foreground = mine ? scheme.onPrimaryContainer : scheme.onSurface;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 4),
              bottomRight: Radius.circular(mine ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (deleted)
                Text(
                  'Message deleted',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground.withValues(alpha: 0.7),
                    fontStyle: FontStyle.italic,
                  ),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: foreground.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Encrypted message',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 4),
              Text(
                _metaLine,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: foreground.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _metaLine {
    final parts = <String>[
      formatTimeOfDay(message.createdAt),
      if (message.editedAt != null) 'edited',
      message.cryptoProtocol,
    ];
    return parts.join(' · ');
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.enabled,
    required this.controller,
    required this.busy,
    required this.onSend,
  });

  final bool enabled;
  final TextEditingController controller;
  final bool busy;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            IconButton(
              // Attachment upload requires client-side encryption, which is
              // not integrated yet; the control stays visible but disabled.
              onPressed: null,
              icon: const Icon(Icons.attach_file),
              tooltip: 'Attachments require client crypto (coming soon)',
            ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(hintText: 'Message'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled && !busy ? () => onSend() : null,
              icon: busy
                  ? SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.onPrimary,
                      ),
                    )
                  : const Icon(Icons.send),
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }
}
