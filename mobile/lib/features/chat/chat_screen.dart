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
  const ChatScreen(
      {required this.state, required this.conversationId, super.key});

  final AppState state;
  final String conversationId;

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
        final conversation = widget.state.conversations
            .where((item) => item.id == widget.conversationId)
            .firstOrNull;
        final messages = widget.state.messagesFor(widget.conversationId);
        final pending = widget.state.pendingFor(widget.conversationId);
        return Scaffold(
          appBar: AppBar(
            title: conversation == null
                ? const Text('Conversation')
                : Row(
                    children: <Widget>[
                      ExcludeSemantics(
                        child: CircleAvatar(
                          radius: 16,
                          child: Icon(conversationIcon(conversation), size: 18),
                        ),
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
                    : _messagesPane(conversation.id, messages, pending),
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

  /// Message area for the selected conversation. Failures get an explicit
  /// error + retry instead of masquerading as "No messages yet".
  Widget _messagesPane(
    String conversationId,
    List<ReceivedMessageEnvelope> messages,
    List<MessageEnvelope> pending,
  ) {
    final loading = widget.state.isLoadingMessages(conversationId);
    final loadError = widget.state.messageLoadError(conversationId);
    if (messages.isEmpty && pending.isEmpty) {
      if (loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (loadError != null) {
        return _MessageLoadError(
          message: loadError,
          onRetry: () => widget.state.loadMessages(conversationId),
        );
      }
      return const EmptyState(
        icon: Icons.lock_outline,
        title: 'No messages yet',
        message: 'Messages are stored as encrypted envelopes '
            'only the members can read.',
      );
    }
    return Column(
      children: <Widget>[
        if (loadError != null)
          MaterialBanner(
            content: Text(loadError),
            leading: const Icon(Icons.error_outline),
            actions: <Widget>[
              TextButton(
                onPressed: () => widget.state.loadMessages(conversationId),
                child: const Text('Retry'),
              ),
            ],
          ),
        Expanded(
          child: _MessageList(
            state: widget.state,
            messages: messages,
            pending: pending,
          ),
        ),
      ],
    );
  }

  Future<void> _send() async {
    final text = composer.text.trim();
    if (text.isEmpty) {
      return;
    }
    await widget.state.sendMessageTo(widget.conversationId, text);
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

class _MessageLoadError extends StatelessWidget {
  const _MessageLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Couldn’t load messages',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.state,
    required this.messages,
    required this.pending,
  });

  final AppState state;
  final List<ReceivedMessageEnvelope> messages;
  final List<MessageEnvelope> pending;

  @override
  Widget build(BuildContext context) {
    // Messages arrive newest-first; the list is reversed so index 0 renders
    // at the bottom. A day separator is emitted whenever the calendar day
    // changes relative to the next-older message.
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      itemCount: pending.length + messages.length,
      itemBuilder: (context, index) {
        if (index < pending.length) {
          final envelope = pending[pending.length - 1 - index];
          return _PendingMessageBubble(
            state: state.outboxState(envelope.idempotencyKey),
            onRetry: () => state.retryEnvelope(envelope.idempotencyKey),
          );
        }
        final messageIndex = index - pending.length;
        final message = messages[messageIndex];
        final mine = message.senderAccountId == state.session?.accountId;
        final older = messageIndex + 1 < messages.length
            ? messages[messageIndex + 1]
            : null;
        final showDay = older == null ||
            formatDate(context, older.createdAt) !=
                formatDate(context, message.createdAt);
        return Column(
          children: <Widget>[
            if (showDay)
              _DaySeparator(label: formatDate(context, message.createdAt)),
            _MessageBubble(message: message, mine: mine),
          ],
        );
      },
    );
  }
}

class _PendingMessageBubble extends StatelessWidget {
  const _PendingMessageBubble({required this.state, required this.onRetry});

  final OutboxDeliveryState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final sending = state == OutboxDeliveryState.sending;
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      label: sending
          ? 'Encrypted message sending'
          : 'Encrypted message failed to send. Retry available.',
      child: Align(
        alignment: Alignment.centerRight,
        child: Card(
          margin: const EdgeInsets.symmetric(vertical: 3),
          color: sending
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (sending)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    Icons.error_outline,
                    size: 18,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                const SizedBox(width: 8),
                Text(sending ? 'Sending encrypted message' : 'Send failed'),
                if (!sending) ...<Widget>[
                  const SizedBox(width: 4),
                  TextButton(onPressed: onRetry, child: const Text('Retry')),
                ],
              ],
            ),
          ),
        ),
      ),
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
    final sender = mine ? 'you' : 'sender ${shortId(message.senderAccountId)}';
    return Semantics(
      excludeSemantics: true,
      label: deleted
          ? 'Deleted message from $sender'
          : 'Encrypted message from $sender, '
              '${formatTimeOfDay(context, message.createdAt)}',
      child: Align(
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
                  _metaLine(context),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // The raw crypto protocol identifier is debug info and stays out of the
  // reading surface; the lock icon already conveys the encrypted state.
  String _metaLine(BuildContext context) {
    final parts = <String>[
      formatTimeOfDay(context, message.createdAt),
      if (message.editedAt != null) 'edited',
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
