import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/status_pill.dart';
import 'chat_list_screen.dart';
import 'conversation_details_screen.dart';

/// Conversation detail screen. Pushed from the chat list; listens to the app
/// state itself because pushed routes sit outside the root rebuild scope.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.state,
    required this.conversationId,
    this.showBackButton = true,
    super.key,
  });

  final AppState state;
  final String conversationId;

  /// False when the screen is the detail pane of the wide master-detail
  /// layout, where there is no route to pop back to.
  final bool showBackButton;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final composer = TextEditingController();
  final scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    scroll.addListener(_maybeLoadOlder);
  }

  @override
  void dispose() {
    scroll.removeListener(_maybeLoadOlder);
    scroll.dispose();
    composer.dispose();
    super.dispose();
  }

  /// The list is reversed, so scrolling back in time approaches maxScrollExtent.
  /// Requesting the next page slightly before the edge keeps the loader from
  /// appearing as a hard stop. [AppState.loadOlderMessages] is idempotent, so
  /// repeated scroll callbacks are harmless.
  void _maybeLoadOlder() {
    if (!scroll.hasClients || !scroll.position.hasContentDimensions) {
      return;
    }
    final remaining = scroll.position.maxScrollExtent - scroll.position.pixels;
    if (remaining < 400) {
      unawaited(widget.state.loadOlderMessages(widget.conversationId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final theme = Theme.of(context);
        final conversation = widget.state.conversations
            .where((item) => item.id == widget.conversationId)
            .firstOrNull;
        final messages = widget.state.messagesFor(widget.conversationId);
        final pending = widget.state.pendingFor(widget.conversationId);
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: widget.showBackButton,
            titleSpacing: widget.showBackButton ? 0 : BoneSpacing.gutter,
            title: conversation == null
                ? const Text('Conversation')
                : Row(
                    children: <Widget>[
                      conversationAvatar(
                        context,
                        conversation,
                        radius: 17,
                        // Only the pushed layout: see conversationAvatar.
                        hero: widget.showBackButton,
                      ),
                      const SizedBox(width: BoneSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              conversationTitle(conversation),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // The subtitle line is the honest one-word status
                            // of the thread, in the micro style.
                            Text(
                              widget.state.isMuted(conversation.id)
                                  ? 'MUTED · ENCRYPTED'
                                  : 'ENCRYPTED',
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
            actions: <Widget>[
              if (conversation != null)
                IconButton(
                  tooltip: 'Conversation details',
                  onPressed: () => Navigator.of(context).push(
                    sharedAxisRoute<void>(
                      (_) => ConversationDetailsScreen(
                        state: widget.state,
                        conversationId: conversation.id,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.info_outline),
                ),
              const SizedBox(width: BoneSpacing.sm),
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
                // Scoped to the send operation: an unrelated background task
                // no longer disables the composer.
                busy: widget.state.isBusy(Ops.send),
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
            conversationId: conversationId,
            controller: scroll,
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
    final sent = await widget.state.sendMessageTo(widget.conversationId, text);
    if (!mounted) {
      return;
    }
    if (sent) {
      // Durable acceptance, rather than HTTP delivery, is the point at which
      // the submitted draft is safe to clear. Preserve newer edits.
      if (composer.text.trim() == text) composer.clear();
      return;
    }
    final error = widget.state.errorFor(Ops.send);
    if (error != null) {
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
            const SizedBox(height: BoneSpacing.lg),
            Text(
              'Couldn’t load messages',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: BoneSpacing.sm),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: BoneSpacing.lg),
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
    required this.conversationId,
    required this.controller,
    required this.messages,
    required this.pending,
  });

  final AppState state;
  final String conversationId;
  final ScrollController controller;
  final List<ReceivedMessageEnvelope> messages;
  final List<MessageEnvelope> pending;

  bool get _isDm =>
      state.conversations
          .where((item) => item.id == conversationId)
          .firstOrNull
          ?.isDm ??
      false;

  /// Names a sender from the loaded roster when possible, falling back to a
  /// shortened account ID. Server-supplied display metadata, not a verified
  /// identity claim.
  String _senderLabel(String accountId) {
    final member = state
        .membersFor(conversationId)
        .where((item) => item.accountId == accountId)
        .firstOrNull;
    return accountLabel(accountId, member?.username);
  }

  @override
  Widget build(BuildContext context) {
    final hasMore = state.hasMoreHistory(conversationId);
    final loadingOlder = state.isLoadingOlder(conversationId);
    // Messages arrive newest-first; the list is reversed so index 0 renders
    // at the bottom. Because older items are appended to the end of the
    // reversed list, prepending history does not move the visible messages,
    // which is what preserves the scroll position across a page load. A day
    // separator is emitted whenever the calendar day changes relative to the
    // next-older message.
    final footerCount = hasMore || loadingOlder ? 1 : 0;
    return ListView.builder(
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.symmetric(
        horizontal: BoneSpacing.gutter,
        vertical: BoneSpacing.lg,
      ),
      itemCount: pending.length + messages.length + footerCount,
      itemBuilder: (context, index) {
        if (index == pending.length + messages.length) {
          return _HistoryFooter(
            loading: loadingOlder,
            onLoad: () => state.loadOlderMessages(conversationId),
          );
        }
        if (index < pending.length) {
          final envelope = pending[pending.length - 1 - index];
          final key = envelope.idempotencyKey;
          final record = state.outboxRecord(key);
          final terminal = state.outboxState(key) == OutboxDeliveryState.terminal;
          return _PendingMessageBubble(
            state: state.outboxState(key),
            failureMessage: terminal ? state.outboxFailureMessage(key) : null,
            onRetry: terminal ? null : () => state.retryEnvelope(key),
            onCopy: record?.draftText == null
                ? null
                : () => Clipboard.setData(
                      ClipboardData(text: record!.draftText!),
                    ),
            onDiscard: terminal ? () => state.discardEnvelope(key) : null,
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
            _MessageBubble(
              message: message,
              mine: mine,
              senderLabel: _senderLabel(message.senderAccountId),
              // In a DM the app bar already says who the other person is;
              // only group and channel bubbles need a per-message sender.
              showSender: !mine && !_isDm,
            ),
          ],
        );
      },
    );
  }
}

/// Top-of-list affordance for older history: a spinner while a page is in
/// flight, and an explicit button otherwise so history is reachable without
/// relying on a scroll gesture.
class _HistoryFooter extends StatelessWidget {
  const _HistoryFooter({required this.loading, required this.onLoad});

  final bool loading;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BoneSpacing.lg),
      child: Center(
        child: loading
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton.icon(
                onPressed: onLoad,
                icon: const Icon(Icons.history),
                label: const Text('Load older messages'),
              ),
      ),
    );
  }
}

class _PendingMessageBubble extends StatelessWidget {
  const _PendingMessageBubble({
    required this.state,
    required this.onRetry,
    this.failureMessage,
    this.onCopy,
    this.onDiscard,
  });

  final OutboxDeliveryState state;
  final VoidCallback? onRetry;
  final String? failureMessage;
  final VoidCallback? onCopy;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final sending = state == OutboxDeliveryState.sending;
    final terminal = state == OutboxDeliveryState.terminal;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      label: sending
          ? 'Encrypted message sending'
          : terminal
              ? 'Encrypted message failed permanently. Copy or discard available.'
              : 'Encrypted message failed to send. Retry available.',
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(
            color:
                sending ? scheme.surfaceContainerHigh : scheme.errorContainer,
            borderRadius: _bubbleRadius(mine: true),
            border: Border.all(
              color: sending ? scheme.outlineVariant : scheme.error,
            ),
          ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (sending)
                      const SizedBox.square(
                        dimension: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        Icons.error_outline,
                        size: 18,
                        color: scheme.onErrorContainer,
                      ),
                    const SizedBox(width: BoneSpacing.sm),
                    Text(
                      sending
                          ? 'Sending encrypted message'
                          : terminal
                              ? 'Message needs attention'
                              : 'Send failed',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: sending
                            ? scheme.onSurface
                            : scheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
                if (failureMessage != null) ...<Widget>[
                  const SizedBox(height: BoneSpacing.xs),
                  Text(
                    failureMessage!,
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ],
                if (!sending)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (onRetry != null)
                        TextButton(
                          onPressed: onRetry,
                          child: const Text('Retry'),
                        ),
                      if (onCopy != null)
                        TextButton(
                          onPressed: onCopy,
                          child: const Text('Copy'),
                        ),
                      if (onDiscard != null)
                        TextButton(
                          onPressed: onDiscard,
                          child: const Text('Discard'),
                        ),
                    ],
                  ),
              ],
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: BoneSpacing.md),
      // The date is already the spoken form, so the pill needs no separate
      // semantics label — only the uppercasing, which StatusPill does.
      child: Center(child: StatusPill(label: label)),
    );
  }
}

/// Corner radii for a bubble: square-ish on the tail corner, [BoneRadii.bubble]
/// everywhere else.
BorderRadius _bubbleRadius({required bool mine}) => BorderRadius.only(
      topLeft: const Radius.circular(BoneRadii.bubble),
      topRight: const Radius.circular(BoneRadii.bubble),
      bottomLeft: Radius.circular(mine ? BoneRadii.bubble : 5),
      bottomRight: Radius.circular(mine ? 5 : BoneRadii.bubble),
    );

/// Widths of the redacted bars that stand in for an undecryptable message,
/// as fractions of the bubble's content width.
///
/// **The widths are bucketed on purpose. Do not make this linear in
/// [byteLength].** A bar whose width tracked the ciphertext length exactly
/// would make the length of every message readable over the user's shoulder —
/// a real, if small, regression against a threat this app takes seriously, and
/// one that today's identical-width bubbles happen not to have. Six buckets
/// keep the rhythm of a real conversation while leaking only which of six
/// ranges a message falls in.
///
/// The thresholds are coarse by design and are byte counts of the whole
/// envelope, which carries a large constant crypto overhead; they are not
/// character counts and should not be tuned to look like them.
///
/// Capped at three lines so one long message cannot dominate the thread.
List<double> redactedBarFractions(int byteLength) {
  const thresholds = <int>[64, 128, 224, 384, 640];
  var bucket = 0;
  while (bucket < thresholds.length && byteLength > thresholds[bucket]) {
    bucket++;
  }
  const shapes = <List<double>>[
    <double>[0.30],
    <double>[0.46],
    <double>[0.64],
    <double>[0.88],
    <double>[1, 0.58],
    <double>[1, 1, 0.71],
  ];
  return shapes[bucket];
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.senderLabel,
    required this.showSender,
  });

  final ReceivedMessageEnvelope message;
  final bool mine;
  final String senderLabel;
  final bool showSender;

  /// Horizontal padding inside the bubble, doubled — the amount the bars have
  /// to give back to the container.
  static const double _insetX = 28;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final deleted = message.deletedAt != null;
    // Bone keeps sent bubbles **on tone**: a near-white accent tiled down a
    // whole column would blow out the plum ground the direction is built on
    // (`docs/design.md` §K). Mine and theirs separate by one tonal step
    // plus a hairline, not by fill colour.
    final background =
        mine ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow;
    final foreground = scheme.onSurface;
    final sender = mine ? 'you' : senderLabel;
    return Semantics(
      excludeSemantics: true,
      label: deleted
          ? 'Deleted message from $sender'
          : 'Encrypted message from $sender, '
              '${formatTimeOfDay(context, message.createdAt)}',
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Taken from the layout rather than the window so the bubble is
          // sized to its pane in the wide master-detail layout too.
          final maxWidth = math.min(420.0, constraints.maxWidth * 0.82);
          return Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: _bubbleRadius(mine: mine),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (showSender)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(
                          senderLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (deleted)
                      Text(
                        'Message deleted',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    else
                      _RedactedBars(
                        byteLength: message.ciphertext.length,
                        contentWidth: maxWidth - _insetX,
                        color: foreground,
                      ),
                    const SizedBox(height: 6),
                    _metaLine(context, scheme),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // The raw crypto protocol identifier is debug info and stays out of the
  // reading surface; the lock glyph carries the encrypted state now that the
  // bars have replaced the `Encrypted message` row that used to say it in
  // every single bubble.
  Widget _metaLine(BuildContext context, ColorScheme scheme) {
    final theme = Theme.of(context);
    final parts = <String>[
      formatTimeOfDay(context, message.createdAt),
      if (message.editedAt != null) 'edited',
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (message.deletedAt == null) ...<Widget>[
          Icon(
            Icons.lock_outline,
            size: 12,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
        ],
        Text(parts.join(' · '), style: theme.textTheme.labelSmall),
      ],
    );
  }
}

/// The ciphertext, drawn honestly: bars where the text would be.
///
/// This replaces the identical lock icon + `Encrypted message` row that used
/// to render in every bubble and turned a thread into a stack of identical
/// grey blocks (`docs/design.md` §2). It degrades correctly — when the
/// mobile MLS path lands, real text replaces the bars in the same bubble and
/// nothing else about the layout moves.
class _RedactedBars extends StatelessWidget {
  const _RedactedBars({
    required this.byteLength,
    required this.contentWidth,
    required this.color,
  });

  final int byteLength;
  final double contentWidth;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fractions = redactedBarFractions(byteLength);
    // Scale the bar height with the text scale so the block keeps the
    // proportions of the text it stands in for at 200% scale.
    final scale = MediaQuery.textScalerOf(context).scale(14.5) / 14.5;
    final barHeight = 10.0 * scale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < fractions.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: 6.0 * scale),
          Container(
            width: math.max(24.0, contentWidth * fractions[i]),
            height: barHeight,
            decoration: BoxDecoration(
              color: color.withValues(alpha: isDark ? 0.20 : 0.16),
              borderRadius: BorderRadius.circular(barHeight / 2),
            ),
          ),
        ],
      ],
    );
  }
}

/// One rounded pill holding the attachment button, the field and send
/// (`docs/design.md` §4), rather than a bordered row of three separate
/// Material controls.
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
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BoneSpacing.md,
          BoneSpacing.sm,
          BoneSpacing.md,
          BoneSpacing.md,
        ),
        child: Container(
          padding: const EdgeInsets.all(BoneSpacing.xs),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(BoneRadii.pill),
            border: Border.all(color: scheme.outlineVariant),
          ),
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
                  style: theme.textTheme.bodyMedium,
                  // The field's own fill and border are cleared: the pill
                  // around it is the input surface now, and the theme's
                  // `inputDecorationTheme` would otherwise draw a rounded box
                  // inside a rounded box.
                  decoration: InputDecoration(
                    hintText: 'Message',
                    filled: false,
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: BoneSpacing.xs,
                      vertical: 12,
                    ),
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: BoneSpacing.xs),
              IconButton.filled(
                onPressed: enabled && !busy ? () => onSend() : null,
                icon: busy
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.send),
                tooltip: 'Send',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
