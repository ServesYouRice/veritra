import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/attachments.dart';
import '../../core/composer_drafts.dart';
import '../../core/message_history.dart';
import '../../core/models.dart';
import '../../crypto/app_payload.dart' show maxAppTextLength;
import '../../storage/encrypted_database.dart'
    show LocalMessage, LocalMessageKind, LocalMessageState;
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/motion.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/gated_explanation.dart';
import '../../ui/widgets/listenable_selector.dart';
import '../../ui/widgets/status_pill.dart';
import '../search/search_screen.dart';
import 'attachment_views.dart';
import 'chat_desktop.dart';
import 'formatted_message.dart';
import 'chat_list_screen.dart';
import 'composer_attachments.dart';
import 'conversation_details_screen.dart';
import 'emoji_picker.dart';
import 'message_request_screen.dart';
import 'message_ticks.dart';
import 'typing_line.dart';
import '../../core/receipts_state.dart' show MessageTick;

/// Conversation detail screen. Pushed from the chat list, or the detail pane
/// of the wide layout. It listens to the app state itself, and rebuilds only
/// when something it shows changes (T49C-1).
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.state,
    required this.conversationId,
    this.showBackButton = true,
    this.initialMessageKey,
    super.key,
  });

  final AppState state;
  final String conversationId;

  /// The local key of a message to scroll to and highlight when the screen
  /// opens, for a search result (W10). Ignored when this device no longer
  /// holds it.
  final String? initialMessageKey;

  /// False when the screen is the detail pane of the wide master-detail
  /// layout, where there is no route to pop back to.
  final bool showBackButton;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // The draft and reply target live in [AppState.composerDrafts], which
  // outlives this screen: switching destinations in the wide layout, or
  // between conversations, disposes it (T49C-4).
  late final TextEditingController composer =
      TextEditingController.fromValue(_draftValue(widget.conversationId));
  final scroll = ScrollController();

  /// Files waiting to be sent from this conversation (W9, B4).
  final _attachments = ComposerAttachments();

  /// The key of the message the next send replies to, if any. The message
  /// itself is read from the current history ([_replyTarget]), never kept.
  late String? _replyingTo = _drafts.replyTargetFor(widget.conversationId);

  ComposerDrafts get _drafts => widget.state.composerDrafts;

  /// True once the reader has scrolled far enough back that the newest
  /// messages are off screen.
  bool _awayFromLatest = false;

  /// Scroll distance from the newest message beyond which "Jump to latest"
  /// appears.
  static const double _awayThreshold = 480;

  // Jump to a search result (W10).
  final GlobalKey _jumpTarget = GlobalKey();
  late String? _jumpKey = widget.initialMessageKey;
  String? _highlightKey;
  bool _jumping = false;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    composer.addListener(_saveDraft);
    _lastTypedText = composer.text;
    composer.addListener(_noticeTyping);
    scroll.addListener(_maybeLoadOlder);
    scroll.addListener(_trackLatest);
    _scheduleJump();
  }

  void _scheduleJump() {
    if (_jumpKey == null || _jumping) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _runJump());
  }

  /// Where the message is in the reversed list, or null when it is not in
  /// what the chat shows (yet).
  int? _jumpIndex(String key) {
    final history = widget.state.historyFor(widget.conversationId);
    final shown = widget.state
        .timelineFor(widget.conversationId)
        .where((message) => !history.hides(message))
        .toList(growable: false);
    final at = shown.indexWhere((message) =>
        ConversationHistory.keyOf(
            message.senderDeviceId, message.idempotencyKey) ==
        key);
    return at < 0
        ? null
        : widget.state.pendingFor(widget.conversationId).length + at;
  }

  /// Scrolls until the message is built, then centres it. Rows have no fixed
  /// height, so this starts near the top and walks back in time a screen at
  /// a time: no row is shorter than [_minRowExtent], so the start is never
  /// past the message.
  Future<void> _runJump() async {
    final key = _jumpKey;
    if (key == null || _jumping || !mounted) return;
    final index = _jumpIndex(key);
    if (index == null) {
      // Still loading: wait for the next change. Once loading is over the
      // message is not held any more (expired, say), so stay put.
      if (!widget.state.isLoadingMessages(widget.conversationId)) {
        _jumpKey = null;
      }
      return;
    }
    _jumping = true;
    try {
      var offset = index * _minRowExtent;
      for (var step = 0; step < 400; step++) {
        if (!mounted || !scroll.hasClients) return;
        final target = _jumpTarget.currentContext;
        if (target != null) {
          await Scrollable.ensureVisible(target, alignment: 0.4);
          if (!mounted) return;
          setState(() => _highlightKey = key);
          _highlightTimer?.cancel();
          _highlightTimer = Timer(const Duration(seconds: 2), () {
            if (mounted) setState(() => _highlightKey = null);
          });
          return;
        }
        final position = scroll.position;
        final extentBefore = position.maxScrollExtent;
        if (offset > extentBefore) {
          offset = extentBefore;
        }
        scroll.jumpTo(offset);
        await WidgetsBinding.instance.endOfFrame;
        // The screen may have been left, or the list replaced, while the
        // frame was pending; the controller is then disposed or detached.
        if (!mounted || !scroll.hasClients) return;
        if (_jumpTarget.currentContext == null) {
          final after = scroll.position;
          if (offset >= after.maxScrollExtent &&
              after.maxScrollExtent == extentBefore) {
            return;
          }
          offset += after.viewportDimension * 0.8;
        }
      }
    } finally {
      _jumping = false;
      _jumpKey = null;
    }
  }

  static const double _minRowExtent = 40;

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId == widget.conversationId &&
        identical(oldWidget.state, widget.state)) {
      return;
    }
    // The same screen now shows another conversation: its own draft, never
    // the previous one's. The previous draft is already saved.
    composer.removeListener(_saveDraft);
    composer.removeListener(_noticeTyping);
    composer.value = _draftValue(widget.conversationId);
    _lastTypedText = composer.text;
    composer.addListener(_saveDraft);
    composer.addListener(_noticeTyping);
    _replyingTo = _drafts.replyTargetFor(widget.conversationId);
    unawaited(_attachments.clear());
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    composer.removeListener(_saveDraft);
    composer.removeListener(_noticeTyping);
    scroll.removeListener(_trackLatest);
    scroll.removeListener(_maybeLoadOlder);
    scroll.dispose();
    composer.dispose();
    unawaited(_attachments.clear());
    _attachments.dispose();
    super.dispose();
  }

  TextEditingValue _draftValue(String conversationId) {
    final text = widget.state.composerDrafts.textFor(conversationId);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _saveDraft() => _drafts.setText(widget.conversationId, composer.text);

  /// The text as of the last typing check, so a cursor move or a draft being
  /// restored is not taken for typing.
  String _lastTypedText = '';

  /// Tells the others you are typing (W5), once the text really changed and
  /// is not empty. [AppState.notifyTyping] throttles and gates by size.
  void _noticeTyping() {
    final text = composer.text;
    if (text == _lastTypedText) return;
    _lastTypedText = text;
    if (text.isNotEmpty) widget.state.notifyTyping(widget.conversationId);
  }

  void _setReplyTarget(String? messageKey) {
    _drafts.setReplyTarget(widget.conversationId, messageKey);
    setState(() => _replyingTo = messageKey);
  }

  /// The reply target as the history has it now, so an edit shows. A target
  /// that was deleted, or is no longer in the history, is dropped: the next
  /// send is then an ordinary message. Safe during build: the drafts are not
  /// listenable, and the caller draws no reply bar for it.
  LocalMessage? _replyTarget() {
    final key = _replyingTo;
    if (key == null) return null;
    final target = widget.state.historyFor(widget.conversationId).forKey(key);
    if (target != null && target.deletedAt == null) return target;
    _drafts.setReplyTarget(widget.conversationId, null);
    _replyingTo = null;
    return null;
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

  void _trackLatest() {
    if (!scroll.hasClients) return;
    final away = scroll.position.pixels > _awayThreshold;
    if (away != _awayFromLatest) setState(() => _awayFromLatest = away);
  }

  /// Returns to the newest message. The list is reversed, so that is offset
  /// zero. Only the scroll position moves: the pages of older history already
  /// loaded stay in memory, so scrolling back up again does not refetch them.
  Future<void> _jumpToLatest() async {
    if (!scroll.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      scroll.jumpTo(0);
      return;
    }
    await scroll.animateTo(
      0,
      duration: BoneDurations.standard,
      curve: BoneDurations.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableSelector<List<Object?>>(
      listenable: widget.state,
      select: () => _chatScreenSelection(widget.state, widget.conversationId),
      equals: listEquals,
      builder: (context, _, __) {
        final theme = Theme.of(context);
        final conversation = widget.state.conversations
            .where((item) => item.id == widget.conversationId)
            .firstOrNull;
        // A request shows its own screen, whichever way it was opened (list,
        // search, the wide pane). Accepting rebuilds into the chat.
        if (conversation != null &&
            widget.state.requestBucket(conversation) != RequestBucket.chat) {
          return MessageRequestScreen(
            state: widget.state,
            conversation: conversation,
            popOnResult: widget.showBackButton,
          );
        }
        final messages = widget.state.timelineFor(widget.conversationId);
        final pending = widget.state.pendingFor(widget.conversationId);
        final replyTarget = _replyTarget();
        if (_jumpKey != null) _scheduleJump();
        return ChatShortcuts(
          onEscape: _onEscape,
          onSearch: _openSearch,
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
                automaticallyImplyLeading: widget.showBackButton,
                titleSpacing: widget.showBackButton ? 0 : BoneSpacing.gutter,
                title: conversation == null
                    ? Text(context.l10n.searchTypeConversation)
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
                                  conversationTitle(context.l10n, conversation),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                // The subtitle line is the honest one-word status
                                // of the thread, in the micro style.
                                Text(
                                  widget.state.isMuted(conversation.id)
                                      ? context.l10n.chatStatusMutedEncrypted
                                      : context.l10n.chatStatusEncrypted,
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                actions: <Widget>[
                  IconButton(
                      tooltip: context.l10n.w8StarredMessages,
                      onPressed: _showStarredMessages,
                      icon: const Icon(Icons.star_outline)),
                  if (conversation != null)
                    IconButton(
                      tooltip: context.l10n.chatListDetails,
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
              body: ChatDropZone(
                enabled:
                    conversation != null && widget.state.attachmentsAvailable,
                onFiles: _addFiles,
                child: Column(
                  children: <Widget>[
                    if (widget.state.pinsFor(widget.conversationId).isNotEmpty)
                      Material(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        // Up to 50 pins per chat: about three rows show,
                        // the rest scroll, so the timeline keeps its room.
                        child: ConstrainedBox(
                            key: const ValueKey('pin-bar'),
                            constraints: const BoxConstraints(maxHeight: 144),
                            child: ListView(shrinkWrap: true, children: [
                              for (final pin in widget.state
                                  .pinsFor(widget.conversationId))
                                ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.push_pin_outlined,
                                      size: 18),
                                  title: Text(
                                      quotedPreview(
                                          context.l10n,
                                          widget.state
                                              .historyFor(widget.conversationId)
                                              .forKey(pin.targetKey)),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  onTap: () {
                                    setState(() => _jumpKey = pin.targetKey);
                                    _scheduleJump();
                                  },
                                )
                            ])),
                      ),
                    Expanded(
                      child: conversation == null
                          ? EmptyState(
                              icon: Icons.forum_outlined,
                              title: context.l10n.shellNoConversationTitle,
                              message: context.l10n.chatNoConversationMessage,
                            )
                          : _messagesPane(conversation.id, messages, pending),
                    ),
                    if (conversation != null &&
                        widget.state.mlsConversationFailed(conversation.id))
                      const _PausedConversationNotice(),
                    TypingLine(
                      state: widget.state,
                      conversationId: widget.conversationId,
                    ),
                    if (replyTarget != null)
                      _ReplyBar(
                        preview: quotedPreview(context.l10n, replyTarget),
                        onCancel: () => _setReplyTarget(null),
                      ),
                    if (widget.state.attachmentsAvailable)
                      AttachmentTray(tray: _attachments),
                    _Composer(
                      enabled: conversation != null,
                      controller: composer,
                      // Scoped to the send operation: an unrelated background task
                      // no longer disables the composer.
                      busy: widget.state.isBusy(Ops.send),
                      onSend: _send,
                      attaching: widget.state.isBusy(Ops.attachment),
                      onAttach: widget.state.attachmentsAvailable
                          ? () => pickAttachmentFiles(
                              context, widget.state, _attachments)
                          : null,
                      onPasteFiles: widget.state.attachmentsAvailable
                          ? _pasteFiles
                          : null,
                      onEditLast: widget.state.messageActionsAvailable
                          ? _editLast
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Esc: first drops a reply in progress, then leaves the chat when it is
  /// a pushed screen (the wide layout's detail pane has nowhere to go).
  void _onEscape() {
    if (_replyingTo != null) {
      _setReplyTarget(null);
    } else if (widget.showBackButton) {
      Navigator.of(context).maybePop();
    }
  }

  /// Ctrl+F: the search screen, as the chat list's search button opens it.
  void _openSearch() {
    Navigator.of(context).push(
      sharedAxisRoute<void>((_) => SearchScreen(state: widget.state)),
    );
  }

  Future<void> _addFiles(List<XFile> files, {Set<String>? temporary}) =>
      addAttachmentFiles(context, widget.state, _attachments, files,
          temporaryPaths: temporary ?? const <String>{});

  /// Ctrl+V with files or an image on the clipboard; false means the
  /// clipboard held neither and the text paste goes ahead.
  Future<bool> _pasteFiles() async {
    final clipboard = await readClipboardFiles();
    if (clipboard.files.isEmpty || !mounted) return false;
    await _addFiles(clipboard.files, temporary: clipboard.temporary);
    return true;
  }

  /// Up in an empty composer edits your newest message, as in other chats.
  Future<void> _editLast() async {
    final state = widget.state;
    final history = state.historyFor(widget.conversationId);
    final ownAccountId = state.session?.accountId;
    for (final envelope in state.timelineFor(widget.conversationId)) {
      final local = history.forEnvelope(envelope);
      if (local == null ||
          local.kind != LocalMessageKind.text ||
          local.deletedAt != null ||
          local.senderAccountId != ownAccountId) {
        continue;
      }
      await _editMessage(local);
      return;
    }
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
      return EmptyState(
        icon: Icons.lock_outline,
        title: context.l10n.chatEmptyTitle,
        message: context.l10n.chatEmptyMessage,
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
                child: Text(context.l10n.commonRetry),
              ),
            ],
          ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: _MessageList(
                  state: widget.state,
                  conversationId: conversationId,
                  controller: scroll,
                  messages: messages,
                  pending: pending,
                  jumpTarget: _jumpTarget,
                  jumpKey: _jumpKey ?? _highlightKey,
                  highlighted: _highlightKey != null,
                  onMessageActions: widget.state.messageActionsAvailable
                      ? _showMessageActions
                      : null,
                ),
              ),
              if (_awayFromLatest)
                Positioned(
                  right: BoneSpacing.gutter,
                  bottom: BoneSpacing.md,
                  child: FloatingActionButton.small(
                    // The wide layout also shows the chat list's FAB; two
                    // default hero tags on one route is an assertion.
                    heroTag: null,
                    tooltip: context.l10n.chatJumpToLatest,
                    onPressed: _jumpToLatest,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHigh,
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    child: const Icon(Icons.arrow_downward),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Long-press on mobile, right-click on desktop.
  Future<void> _showStarredMessages() async {
    final state = widget.state;
    final selected = await showModalBottomSheet<String>(
        context: context,
        builder: (sheetContext) => SafeArea(
                child: ListView(shrinkWrap: true, children: [
              ListTile(title: Text(context.l10n.w8StarredMessages)),
              for (final message
                  in state.historyFor(widget.conversationId).messages)
                if (state.starredMessages.contains(message.key) &&
                    message.hiddenAt == null &&
                    message.deletedAt == null)
                  ListTile(
                      leading: const Icon(Icons.star),
                      title: Text(quotedPreview(context.l10n, message)),
                      onTap: () => Navigator.pop(sheetContext, message.key)),
            ])));
    if (selected != null && mounted) {
      setState(() => _jumpKey = selected);
      _scheduleJump();
    }
  }

  /// Long-press on mobile, right-click on desktop.
  Future<void> _showMessageActions(LocalMessage message, bool mine) async {
    final state = widget.state;
    final conversationId = widget.conversationId;
    final actionable = message.deletedAt == null &&
        const [LocalMessageKind.text, LocalMessageKind.attachment]
            .contains(message.kind);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (actionable)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: BoneSpacing.md),
                child: Wrap(
                  spacing: BoneSpacing.xs,
                  children: <Widget>[
                    for (final reaction in quickReactions)
                      IconButton(
                        tooltip: context.l10n.chatReact(reaction),
                        onPressed: () =>
                            Navigator.of(sheetContext).pop('react:$reaction'),
                        icon: Text(reaction,
                            style: const TextStyle(fontSize: 24)),
                      ),
                    IconButton(
                      tooltip: context.l10n.chatMoreReactions,
                      onPressed: () => Navigator.of(sheetContext).pop('react:'),
                      icon: const Icon(Icons.add_reaction_outlined),
                    ),
                  ],
                ),
              ),
            if (actionable)
              ListTile(
                leading: const Icon(Icons.reply),
                title: Text(context.l10n.chatReply),
                onTap: () => Navigator.of(sheetContext).pop('reply'),
              ),
            if (actionable && message.kind == LocalMessageKind.text)
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(context.l10n.chatCopyText),
                onTap: () => Navigator.of(sheetContext).pop('copy'),
              ),
            if (actionable)
              ListTile(
                  leading: const Icon(Icons.forward_outlined),
                  title: Text(context.l10n.w8Forward),
                  onTap: () => Navigator.of(sheetContext).pop('forward')),
            ListTile(
                leading: Icon(state.starredMessages.contains(message.key)
                    ? Icons.star
                    : Icons.star_outline),
                title: Text(state.starredMessages.contains(message.key)
                    ? context.l10n.w8Unstar
                    : context.l10n.w8Star),
                onTap: () => Navigator.of(sheetContext).pop('star')),
            ListTile(
                leading: const Icon(Icons.hide_source),
                title: Text(context.l10n.w8DeleteForMe),
                onTap: () => Navigator.of(sheetContext).pop('hide')),
            if (actionable && state.canPinMessages(conversationId))
              ListTile(
                  leading: const Icon(Icons.push_pin_outlined),
                  title: Text(context.l10n.w8Pin),
                  onTap: () => Navigator.of(sheetContext).pop('pin')),
            if (mine) ...<Widget>[
              if (message.kind == LocalMessageKind.text &&
                  message.deletedAt == null)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(context.l10n.chatEdit),
                  onTap: () => Navigator.of(sheetContext).pop('edit'),
                ),
              if (const [
                    LocalMessageKind.text,
                    LocalMessageKind.attachment,
                    LocalMessageKind.unsupported
                  ].contains(message.kind) &&
                  message.deletedAt == null)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(context.l10n.chatDeleteForEveryone),
                  onTap: () => Navigator.of(sheetContext).pop('delete'),
                ),
            ],
          ],
        )),
      ),
    );
    if (!mounted || action == null) return;
    var sent = true;
    if (action.startsWith('react:')) {
      var reaction = action.substring('react:'.length);
      if (reaction.isEmpty) {
        // The "more" button: any emoji, from the picker or typed.
        final picked = await showEmojiPicker(context);
        if (!mounted || picked == null) return;
        reaction = picked;
      }
      final ownAccountId = state.session?.accountId;
      final alreadyMine = state
          .historyFor(conversationId)
          .reactionsFor(message.key, ownAccountId: ownAccountId)
          .any((item) => item.reaction == reaction && item.mine);
      // Tapping your own reaction again takes it back.
      sent = await state.react(
          conversationId, message.key, alreadyMine ? '' : reaction);
    } else if (action == 'reply') {
      _setReplyTarget(message.key);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.body ?? ''));
    } else if (action == 'star') {
      await state.toggleMessageStar(message);
    } else if (action == 'hide') {
      await state.deleteMessageForMe(message);
    } else if (action == 'forward') {
      final selected = <String>{};
      final destinations = await showDialog<List<String>>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (context, setDialogState) => AlertDialog(
                    title: Text(context.l10n.w8Forward),
                    content: SizedBox(
                        width: 360,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              for (final c in state.conversations)
                                CheckboxListTile(
                                    value: selected.contains(c.id),
                                    title: Text(
                                        conversationTitle(context.l10n, c)),
                                    onChanged: (v) => setDialogState(() {
                                          if (v == true &&
                                              selected.length <
                                                  ((message.forwardHops ?? 0) >=
                                                          5
                                                      ? 1
                                                      : 5)) {
                                            selected.add(c.id);
                                          } else {
                                            selected.remove(c.id);
                                          }
                                        }))
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: Text(context.l10n.commonCancel)),
                      FilledButton(
                          onPressed: selected.isEmpty
                              ? null
                              : () => Navigator.pop(
                                  dialogContext, selected.toList()),
                          child: Text(context.l10n.w8Forward))
                    ],
                  )));
      if (destinations != null)
        sent = await state.forwardMessage(message, destinations);
    } else if (action == 'pin') {
      final existing =
          state.pinsFor(conversationId).any((p) => p.targetKey == message.key);
      final duration = await showModalBottomSheet<int>(
          context: context,
          builder: (sheetContext) => SafeArea(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (existing)
                  ListTile(
                      title: Text(context.l10n.w8Unpin),
                      onTap: () => Navigator.pop(sheetContext, 0)),
                for (final days in [1, 7, 30])
                  ListTile(
                      title: Text(context.l10n.w8PinDays(days)),
                      onTap: () => Navigator.pop(sheetContext, days * 86400)),
              ])));
      if (duration != null)
        sent = await state.pinMessage(conversationId, message.key,
            pinned: duration != 0, durationSeconds: duration);
    } else if (action == 'edit') {
      await _editMessage(message);
      return;
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.l10n.chatDeleteTitle),
          content: Text(context.l10n.chatDeleteMessage),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(context.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(context.l10n.chatDelete),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      sent = await state.deleteMessage(conversationId, message.key);
    }
    if (!sent && mounted) {
      final error = state.errorFor(Ops.send);
      if (error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  Future<void> _editMessage(LocalMessage message) async {
    final text = await _editDialog(message.body ?? '');
    if (!mounted || text == null || text.trim().isEmpty) return;
    if (text == message.body) return;
    final sent = await widget.state
        .editMessage(widget.conversationId, message.key, text.trim());
    final error = widget.state.errorFor(Ops.send);
    if (!sent && mounted && error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<String?> _editDialog(String current) {
    final controller = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final trimmed = value.text.trim();
          final error = trimmed.isEmpty
              ? context.l10n.chatEditEmpty
              : trimmed.length > maxAppTextLength
                  ? context.l10n.validationMessageTooLong
                  : null;
          return AlertDialog(
            title: Text(context.l10n.chatEditTitle),
            content: TextField(
              controller: controller,
              autofocus: true,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(errorText: error),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(context.l10n.commonCancel),
              ),
              FilledButton(
                onPressed: error == null
                    ? () => Navigator.of(dialogContext).pop(controller.text)
                    : null,
                child: Text(context.l10n.attachmentSave),
              ),
            ],
          );
        },
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _send() async {
    final state = widget.state;
    final conversationId = widget.conversationId;
    // Each waiting file goes first, as its own encrypted attachment.
    if (_attachments.isNotEmpty) {
      if (state.isBusy(Ops.attachment)) return;
      final sentFiles = await sendPendingAttachments(
          context, state, conversationId, _attachments);
      if (!sentFiles || !mounted) return;
    }
    final text = composer.text.trim();
    if (text.isEmpty) {
      return;
    }
    final replyingTo = _replyTarget()?.key;
    final sent = replyingTo == null
        ? await state.sendMessageTo(conversationId, text)
        : await state.replyTo(conversationId, replyingTo, text);
    if (sent) {
      // Durable acceptance, rather than HTTP delivery, is the point at which
      // the submitted draft is safe to clear. Preserve newer edits. The
      // stored draft is cleared even if this screen closed meanwhile, so the
      // sent text does not come back as a draft.
      state.composerDrafts
          .clearSent(conversationId, text: text, replyTo: replyingTo);
      if (!mounted) {
        return;
      }
      if (_replyingTo == replyingTo) {
        setState(() => _replyingTo = null);
      }
      if (composer.text.trim() == text) composer.clear();
      return;
    }
    if (!mounted) {
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

/// Everything the open conversation reads from [AppState] (T49C-1). The chat
/// rebuilds only when this changes, so a notification about another
/// conversation, the device list or the connection leaves it alone.
///
/// Lists and models compare by identity: AppState replaces them instead of
/// editing them in place. A new read from the state anywhere in this file's
/// build methods must be added here, or that part of the chat stays stale.
List<Object?> _chatScreenSelection(AppState state, String conversationId) {
  final history = state.historyFor(conversationId);
  final pending = state.pendingFor(conversationId);
  final session = state.session;
  return <Object?>[
    state.conversations.where((item) => item.id == conversationId).firstOrNull,
    state.conversations
        .where((item) => item.id == conversationId)
        .map(state.requestBucket)
        .firstOrNull,
    state.messagesFor(conversationId),
    // A conversation without loaded history gets a new empty one per call;
    // every history without messages draws the same.
    history.messages.isEmpty ? null : history,
    state.membersFor(conversationId),
    session?.accountId,
    session?.deviceId,
    state.l10n,
    state.isMuted(conversationId),
    state.mlsConversationFailed(conversationId),
    state.isBusy(Ops.send),
    state.isBusy(Ops.attachment),
    state.attachmentsAvailable,
    state.messageActionsAvailable,
    state.starredMessages,
    ...state.pinsFor(conversationId),
    state.isLoadingMessages(conversationId),
    state.messageLoadError(conversationId),
    state.hasMoreHistory(conversationId),
    state.isLoadingOlder(conversationId),
    for (final envelope in pending) ...<Object?>[
      envelope,
      state.outboxState(envelope.idempotencyKey),
      state.outboxRecord(envelope.idempotencyKey),
    ],
  ];
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
              context.l10n.chatLoadFailed,
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
              label: Text(context.l10n.commonRetry),
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
    required this.jumpTarget,
    this.jumpKey,
    this.highlighted = false,
    this.onMessageActions,
  });

  /// The key put on the message named by [jumpKey], so the screen can find it
  /// once it is built (W10); [highlighted] tints it.
  final GlobalKey jumpTarget;
  final String? jumpKey;
  final bool highlighted;

  final AppState state;
  final String conversationId;
  final ScrollController controller;
  final List<ReceivedMessageEnvelope> messages;
  final List<MessageEnvelope> pending;
  final void Function(LocalMessage message, bool mine)? onMessageActions;

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
    final history = state.historyFor(conversationId);
    final ownDeviceId = state.session?.deviceId;
    // Edit, delete and reaction envelopes change other bubbles instead of
    // drawing their own.
    final messages = this
        .messages
        .where((message) => !history.hides(message))
        .toList(growable: false);
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
      // Dragging the thread puts the keyboard away so the history it hid is
      // readable; the draft stays in the composer.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
          final terminal =
              state.outboxState(key) == OutboxDeliveryState.terminal;
          final local = ownDeviceId == null
              ? null
              : history.forKey(ConversationHistory.keyOf(ownDeviceId, key));
          if (local?.kind == LocalMessageKind.action) {
            return const SizedBox.shrink();
          }
          return _PendingMessageBubble(
            text: local?.kind == LocalMessageKind.attachment
                ? _attachmentSummary(context.l10n, local!, conversationId)
                : local?.body ?? record?.draftText,
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
        final local = history.forEnvelope(message);
        // A decrypted record names its authenticated sender; the envelope's
        // sender is only what the server says.
        final senderAccountId =
            local?.senderAccountId ?? message.senderAccountId;
        final mine = senderAccountId == state.session?.accountId;
        final replyTarget =
            local?.replyTo == null ? null : history.forKey(local!.replyTo!);
        final older = messageIndex + 1 < messages.length
            ? messages[messageIndex + 1]
            : null;
        final showDay = older == null ||
            formatDate(context, older.createdAt) !=
                formatDate(context, message.createdAt);
        final isJumpTarget = jumpKey != null && local?.key == jumpKey;
        final row = Column(
          children: <Widget>[
            if (showDay)
              _DaySeparator(label: formatDate(context, message.createdAt)),
            MessageTickBuilder(
              state: state,
              conversationId: conversationId,
              createdAt: message.createdAt,
              enabled: mine &&
                  local?.state != LocalMessageState.restored &&
                  message.deletedAt == null &&
                  local?.deletedAt == null &&
                  state.ticksApply(conversationId),
              builder: (context, tick) => _MessageBubble(
                message: message,
                local: local,
                copiedHistory: local?.state == LocalMessageState.restored ||
                    (local != null && history.copiedKeys.contains(local.key)),
                replyPreview: local?.replyTo == null
                    ? null
                    : quotedPreview(context.l10n, replyTarget),
                reactions: local == null
                    ? const <({String reaction, int count, bool mine})>[]
                    : history.reactionsFor(local.key,
                        ownAccountId: state.session?.accountId),
                starred:
                    local != null && state.starredMessages.contains(local.key),
                onMention: (accountId) {
                  final member = state
                      .membersFor(conversationId)
                      .where((m) => m.accountId == accountId)
                      .firstOrNull;
                  showModalBottomSheet<void>(
                      context: context,
                      builder: (_) => SafeArea(
                          child: ListTile(
                              leading: const Icon(Icons.person_outline),
                              title: Text(member?.username ?? accountId),
                              subtitle: Text(accountId))));
                },
                mine: mine,
                tick: tick,
                onActions: onMessageActions == null ||
                        local == null ||
                        local.kind == LocalMessageKind.action ||
                        local.hiddenAt != null
                    ? null
                    : () => onMessageActions!(local, mine),
                senderLabel: _senderLabel(senderAccountId),
                onOpenAttachment: state.attachmentsAvailable
                    ? (entry) => openAttachment(
                          context,
                          state,
                          entry,
                          conversationId: conversationId,
                        )
                    : null,
                // In a DM the app bar already says who the other person is;
                // only group and channel bubbles need a per-message sender.
                showSender: !mine && !_isDm,
              ),
            ),
          ],
        );
        if (!isJumpTarget) return row;
        return KeyedSubtree(
          key: jumpTarget,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: highlighted
                  ? Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.14)
                  : null,
              borderRadius: BorderRadius.circular(BoneRadii.md),
            ),
            child: row,
          ),
        );
      },
    );
  }
}

@visibleForTesting
String quotedPreview(AppLocalizations l10n, LocalMessage? target) {
  if (target == null) return l10n.chatReplyEarlier;
  // Their bodies are raw JSON or empty, never text to quote.
  if (target.kind == LocalMessageKind.unsupported && target.deletedAt == null) {
    return l10n.chatMessageUnsupported;
  }
  if ((target.kind == LocalMessageKind.invalid ||
          target.kind == LocalMessageKind.unverifiable) &&
      target.deletedAt == null) {
    return l10n.chatMessageInvalid;
  }
  if (target.deletedAt != null || target.body == null) {
    return l10n.chatReplyDeleted;
  }
  if (target.formatJson?.contains('spoiler') == true)
    return l10n.w8HiddenSpoiler;
  if (target.kind == LocalMessageKind.attachment) {
    return _attachmentSummary(l10n, target, target.conversationId);
  }
  final text = target.body!.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Cut by user-perceived character: a UTF-16 cut can leave half a surrogate
  // pair (text Flutter's paragraph builder rejects) or split an emoji
  // sequence.
  final characters = text.characters;
  return characters.length <= 80 ? text : '${characters.take(80)}…';
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
                label: Text(context.l10n.chatLoadOlder),
              ),
      ),
    );
  }
}

class _PendingMessageBubble extends StatelessWidget {
  const _PendingMessageBubble({
    required this.state,
    required this.onRetry,
    this.text,
    this.failureMessage,
    this.onCopy,
    this.onDiscard,
  });

  final OutboxDeliveryState state;
  final VoidCallback? onRetry;
  final String? text;
  final String? failureMessage;
  final VoidCallback? onCopy;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final sending = state == OutboxDeliveryState.sending;
    final terminal = state == OutboxDeliveryState.terminal;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return Semantics(
      liveRegion: true,
      label: sending
          ? l10n.chatPendingSendingSemantics
          : terminal
              ? l10n.chatPendingTerminalSemantics
              : l10n.chatPendingFailedSemantics,
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
              if (text != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: BoneSpacing.xs),
                  child: Text(
                    text!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color:
                          sending ? scheme.onSurface : scheme.onErrorContainer,
                    ),
                  ),
                ),
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
                        ? l10n.chatPendingSending
                        : terminal
                            ? l10n.chatPendingTerminal
                            : l10n.chatPendingFailed,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color:
                          sending ? scheme.onSurface : scheme.onErrorContainer,
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
                        child: Text(l10n.commonRetry),
                      ),
                    if (onCopy != null)
                      TextButton(
                        onPressed: onCopy,
                        child: Text(l10n.commonCopy),
                      ),
                    if (onDiscard != null)
                      TextButton(
                        onPressed: onDiscard,
                        child: Text(l10n.chatDiscard),
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
    this.local,
    this.replyPreview,
    this.reactions = const <({String reaction, int count, bool mine})>[],
    this.tick,
    this.onActions,
    this.onOpenAttachment,
    this.onMention,
    this.starred = false,
    this.copiedHistory = false,
  });

  /// Sent, delivered or read, for a message of yours; null otherwise.
  final MessageTick? tick;

  /// Opens the reply/edit/delete/react menu; null when none apply.
  final VoidCallback? onActions;

  /// Opens one attachment of an attachment message.
  final void Function(AttachmentEntry entry)? onOpenAttachment;
  final void Function(String accountId)? onMention;
  final bool starred;
  final bool copiedHistory;

  final ReceivedMessageEnvelope message;

  /// The decrypted record, when this device could decrypt the envelope.
  final LocalMessage? local;
  final String? replyPreview;
  final List<({String reaction, int count, bool mine})> reactions;
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
    final deleted = message.deletedAt != null || local?.deletedAt != null;
    final unverifiable = local?.kind == LocalMessageKind.unverifiable;
    final isAttachment = local?.kind == LocalMessageKind.attachment;
    // An attachment row's body is its manifest list, never text to show.
    final placeholder = _isPlaceholder;
    // Placeholder rows hold no content to show; an unsupported row's body is
    // raw JSON kept for a later version.
    final text = deleted || unverifiable || isAttachment || placeholder
        ? null
        : local?.body;
    // Bone keeps sent bubbles **on tone**: a near-white accent tiled down a
    // whole column would blow out the plum ground the direction is built on
    // (`docs/design.md` §K). Mine and theirs separate by one tonal step
    // plus a hairline, not by fill colour.
    final background =
        mine ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow;
    final foreground = scheme.onSurface;
    final sender = mine ? context.l10n.chatSenderYou : senderLabel;
    return Listener(
        onPointerDown: (event) {
          if (event.buttons & kSecondaryMouseButton != 0) onActions?.call();
        },
        child: GestureDetector(
          onLongPress: onActions,
          child: _bubble(context, theme, scheme, background, foreground, sender,
              deleted, unverifiable, text),
        ));
  }

  bool get _isPlaceholder =>
      local?.kind == LocalMessageKind.unsupported ||
      local?.kind == LocalMessageKind.invalid;

  /// A peer message this device can never decrypt (D54). NativeCryptoService
  /// stores it as an `invalid` row, which holds no content and offers no
  /// action, keyed `undecryptable:<sync event>:<server id>`.
  bool get _isUndecryptable =>
      local?.kind == LocalMessageKind.invalid &&
      local!.key.startsWith(_undecryptableKeyPrefix);

  static const _undecryptableKeyPrefix = 'undecryptable:';

  String _placeholderLabel(AppLocalizations l10n) => _isUndecryptable
      ? l10n.chatMessageUndecryptable
      : local?.kind == LocalMessageKind.invalid
          ? l10n.chatMessageInvalid
          : l10n.chatMessageUnsupported;

  /// The attachments of an attachment message. Entries that fail to parse,
  /// or name another conversation, are left out rather than shown.
  List<Widget> _attachmentTiles(BuildContext context) {
    final entries = AttachmentEntry.listFromBody(local?.body,
        conversationId: message.conversationId);
    if (entries.isEmpty) {
      return <Widget>[
        Text(
          context.l10n.chatAttachmentUnopenable,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ];
    }
    return <Widget>[
      for (final entry in entries)
        AttachmentTile(
          entry: entry,
          onOpen:
              onOpenAttachment == null ? null : () => onOpenAttachment!(entry),
        ),
    ];
  }

  Widget _bubble(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    Color background,
    Color foreground,
    String sender,
    bool deleted,
    bool unverifiable,
    String? text,
  ) {
    final l10n = context.l10n;
    final placeholder = _isPlaceholder;
    final time = formatTimeOfDay(context, message.createdAt);
    // An attachment bubble keeps its attachment tiles as nodes of their own
    // (file name, size and a tap action); excluding descendants would leave
    // the merged bubble with no way to open them. Everything else in such a
    // bubble stays covered by the bubble's label.
    final tileNodes = local?.kind == LocalMessageKind.attachment &&
        !deleted &&
        !unverifiable &&
        onOpenAttachment != null &&
        AttachmentEntry.listFromBody(local?.body,
                conversationId: message.conversationId)
            .isNotEmpty;
    Widget quiet(Widget child) =>
        tileNodes ? ExcludeSemantics(child: child) : child;
    return Semantics(
      container: tileNodes,
      excludeSemantics: !tileNodes,
      onLongPress: onActions,
      onLongPressHint: onActions == null ? null : l10n.chatMessageActions,
      label: (deleted
              ? l10n.chatDeletedSemantics(sender)
              : unverifiable
                  ? l10n.chatUnverifiedSemantics(time)
                  : placeholder
                      ? _placeholderLabel(l10n)
                      : text != null
                          ? (local?.formatJson?.contains('spoiler') == true
                              ? l10n.w8HiddenSpoiler
                              : l10n.chatMessageSemantics(sender, time, text))
                          : local?.kind == LocalMessageKind.attachment
                              ? l10n.chatAttachmentSemantics(sender, time)
                              : l10n.chatEncryptedSemantics(sender, time)) +
          (tick == null ? '' : ', ${messageTickLabel(l10n, tick!)}'),
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
                    if (starred) quiet(const Icon(Icons.star, size: 14)),
                    if (copiedHistory)
                      quiet(Text(l10n.k2CopiedHistory,
                          style: theme.textTheme.labelSmall)),
                    if (local?.forwardHops != null)
                      quiet(Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                              local!.forwardHops! >= 5
                                  ? l10n.w8ForwardedMany
                                  : l10n.w8Forwarded,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(fontStyle: FontStyle.italic)))),
                    if (showSender)
                      quiet(Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(
                          senderLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )),
                    if (replyPreview != null && !deleted)
                      quiet(Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.only(left: 8),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                                color: scheme.outlineVariant, width: 3),
                          ),
                        ),
                        child: Text(
                          replyPreview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )),
                    if (deleted)
                      Text(
                        l10n.chatMessageDeleted,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    else if (unverifiable)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.gpp_maybe_outlined,
                              size: 16, color: scheme.error),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              l10n.chatSenderUnverified,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.error,
                              ),
                            ),
                          ),
                        ],
                      )
                    else if (placeholder)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                              _isUndecryptable
                                  ? Icons.lock_outline
                                  : local?.kind == LocalMessageKind.invalid
                                      ? Icons.warning_amber_outlined
                                      : Icons.update_outlined,
                              size: 16,
                              color: scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _placeholderLabel(l10n),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        ],
                      )
                    else if (local?.kind == LocalMessageKind.attachment)
                      ..._attachmentTiles(context)
                    else if (text != null)
                      FormattedMessage(
                        text: text,
                        formatJson: local?.formatJson,
                        onMention: onMention,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: foreground),
                      )
                    else
                      _RedactedBars(
                        byteLength: message.ciphertext.length,
                        contentWidth: maxWidth - _insetX,
                        color: foreground,
                      ),
                    if (reactions.isNotEmpty && !deleted)
                      quiet(Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: <Widget>[
                            for (final item in reactions)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: item.mine
                                      ? scheme.secondaryContainer
                                      : scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  item.count > 1
                                      ? l10n.chatReactionCount(
                                          item.reaction,
                                          item.count,
                                        )
                                      : item.reaction,
                                  style: theme.textTheme.labelSmall,
                                ),
                              ),
                          ],
                        ),
                      )),
                    const SizedBox(height: 6),
                    quiet(_metaLine(context, scheme)),
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
      if (message.editedAt != null || local?.editedAt != null)
        context.l10n.chatEdited,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (message.deletedAt == null && local?.deletedAt == null) ...<Widget>[
          Icon(
            Icons.lock_outline,
            size: 12,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
        ],
        Text(parts.join(' · '), style: theme.textTheme.labelSmall),
        if (tick != null) ...<Widget>[
          const SizedBox(width: 4),
          MessageTickIcon(tick: tick!),
        ],
      ],
    );
  }
}

/// Reactions offered in the message menu.
const List<String> quickReactions = <String>[
  '👍',
  '❤️',
  '😂',
  '🎉',
  '😮',
  '😢'
];

/// Shown above the composer while a reply is being written.
class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.preview, required this.onCancel});

  final String preview;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          BoneSpacing.lg, BoneSpacing.sm, BoneSpacing.sm, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.reply,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: BoneSpacing.sm),
          Expanded(
            child: Text(
              context.l10n.chatReplyingTo(preview),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            tooltip: context.l10n.chatCancelReply,
            onPressed: onCancel,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
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

bool get _enterSends =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

class _Composer extends StatelessWidget {
  const _Composer({
    required this.enabled,
    required this.controller,
    required this.busy,
    required this.onSend,
    this.onAttach,
    this.attaching = false,
    this.onPasteFiles,
    this.onEditLast,
  });

  final bool enabled;
  final TextEditingController controller;
  final bool busy;
  final Future<void> Function() onSend;

  /// Picks and sends a file; null where attachments are unavailable.
  final VoidCallback? onAttach;
  final bool attaching;

  /// Ctrl+V attaches files or an image from the clipboard (desktop); the
  /// result is false when it held none.
  final Future<bool> Function()? onPasteFiles;

  /// Up in an empty field edits the newest own message.
  final VoidCallback? onEditLast;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => _build(context, value.text),
    );
  }

  /// Desktop input extras around the field: paste of files, Up to edit.
  Widget _wrapDesktopInput(Widget field) {
    final paste = onPasteFiles;
    final editLast = onEditLast;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (editLast != null &&
            event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowUp &&
            controller.text.isEmpty) {
          editLast();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: paste == null
          ? field
          : PasteFilesInterceptor(onPaste: paste, child: field),
    );
  }

  Widget _build(BuildContext context, String text) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final length = text.trim().length;
    final nearLimit = length > maxAppTextLength * 0.9;
    final overLimit = length > maxAppTextLength;
    final canSend = enabled && !busy && !overLimit;
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
              if (onAttach == null)
                // Attachments need the MLS path (demo builds); elsewhere the
                // control stays visible but disabled, and the reason is
                // reachable by focus, tap and screen reader.
                GatedExplanation(
                  message: context.l10n.gatedAttachmentsUnavailable,
                  child: const IconButton(
                    onPressed: null,
                    icon: Icon(Icons.attach_file),
                  ),
                )
              else
                IconButton(
                  onPressed: enabled && !attaching ? onAttach : null,
                  icon: attaching
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.attach_file),
                  tooltip: attaching
                      ? context.l10n.chatSendingFile
                      : context.l10n.chatAttachFile,
                ),
              Expanded(
                // On desktop, Enter sends and Shift+Enter starts a new line.
                child: CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    if (_enterSends)
                      const SingleActivator(LogicalKeyboardKey.enter): () {
                        if (canSend) onSend();
                      },
                  },
                  child: _wrapDesktopInput(TextField(
                    controller: controller,
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    textCapitalization: TextCapitalization.sentences,
                    style: theme.textTheme.bodyMedium,
                    // The field's own fill and border are cleared: the pill
                    // around it is the input surface now, and the theme's
                    // `inputDecorationTheme` would otherwise draw a rounded box
                    // inside a rounded box.
                    decoration: InputDecoration(
                      hintText: context.l10n.chatComposerHint,
                      filled: false,
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: BoneSpacing.xs,
                        vertical: 12,
                      ),
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      // Silent only until the draft nears the limit; past it
                      // the count turns into an error and Send disables.
                      // Nothing is truncated, so a long paste is never lost.
                      counterText: nearLimit
                          ? context.l10n
                              .chatComposerCounter(length, maxAppTextLength)
                          : null,
                      counterStyle: overLimit
                          ? theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.error)
                          : theme.textTheme.bodySmall,
                      errorText: overLimit
                          ? context.l10n.validationMessageTooLong
                          : null,
                    ),
                  )),
                ),
              ),
              const SizedBox(width: BoneSpacing.xs),
              IconButton.filled(
                onPressed: canSend ? () => onSend() : null,
                icon: busy
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.send),
                tooltip: context.l10n.attachmentSend,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the server rejected an encryption update for this
/// conversation (I34). The update stays queued so later messages cannot
/// overtake it; sending here is paused until the device recovers.
class _PausedConversationNotice extends StatelessWidget {
  const _PausedConversationNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        color: scheme.errorContainer,
        padding: const EdgeInsets.symmetric(
          horizontal: BoneSpacing.gutter,
          vertical: BoneSpacing.sm,
        ),
        child: Text(
          context.l10n.chatPausedNotice,
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
  }
}

/// One line naming an attachment message's files, for previews and pending
/// bubbles.
String _attachmentSummary(
  AppLocalizations l10n,
  LocalMessage message,
  String conversationId,
) {
  final entries = AttachmentEntry.listFromBody(message.body,
      conversationId: conversationId);
  if (entries.isEmpty) return l10n.chatAttachment;
  final first = entries.first.fileName;
  return entries.length == 1
      ? l10n.chatAttachmentOne(first)
      : l10n.chatAttachmentMany(first, entries.length - 1);
}
