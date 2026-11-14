part of 'app_state.dart';

/// The stored switch, read like `screen_guard_chats`.
const String _chatPreviewsSetting = 'u12.chat_previews';

/// U12 (D131): the last message on a chat-list row. Everything here reads this
/// device's own decrypted history (`LocalStore.loadMessages`, or the history an
/// open or messaged chat already holds). Nothing is fetched, no key is used and
/// nothing is sent: a preview is exactly what the chat itself would show, cut
/// short. Push stays generic and never sees any of it.
extension ChatPreviews on AppState {
  /// Turns previews on or off for every row. They are on by default (D131).
  Future<void> setShowChatPreviews(bool value) async {
    showChatPreviews = value;
    await localStore.saveSetting(_chatPreviewsSetting, '$value');
    notifyListeners();
  }

  /// The row the chat list quotes for [conversationId], or null when previews
  /// are off, nothing is known yet, or the newest message is not one a row
  /// may quote. Whether a row may be shown is for `chatPreviewLine`, which
  /// refuses a request; the loader below never reads one. Re-checks
  /// `expiresAt` on every call, because the purge that removes an expired row
  /// can lag it.
  LocalMessage? chatPreviewFor(String conversationId) {
    if (!showChatPreviews) return null;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    bool live(LocalMessage? row) =>
        row == null || row.expiresAt == null || row.expiresAt! > nowMs;
    final history = _history[conversationId];
    final memo = _previewMemo[conversationId];
    if (history != null) {
      if (memo != null && identical(memo.source, history) && live(memo.row)) {
        return memo.row;
      }
      final row = history.latestForPreview(nowMs: nowMs);
      _previewMemo[conversationId] = (source: history, row: row);
      return row;
    }
    // A row read from the store earlier. One taken from a history that has
    // since gone is dropped; the loader reads it again.
    if (memo == null || memo.source != null) return null;
    return live(memo.row) ? memo.row : null;
  }

  /// Reads the newest message of every chat that has not been opened or
  /// messaged this session, so a row has a preview after a cold start. Runs
  /// once per chat until the history changes; the work is the same
  /// `loadMessages` read the chat does when it opens.
  Future<void> loadChatPreviews() async {
    if (!showChatPreviews || session == null) return;
    final generation = _sessionGeneration;
    final wanted = <String>[
      for (final conversation in conversations)
        if (conversation.lastMessageAt != null &&
            !conversation.isCommunityShared &&
            // Never a stranger's: nothing of a request is read (B8).
            requestBucket(conversation) == RequestBucket.chat &&
            !_history.containsKey(conversation.id) &&
            !_previewMemo.containsKey(conversation.id) &&
            _previewLoading.add(conversation.id))
          conversation.id,
    ];
    if (wanted.isEmpty) return;
    var changed = false;
    try {
      for (final id in wanted) {
        LocalMessage? row;
        try {
          final history = ConversationHistory(
            conversationId: id,
            messages: await localStore.loadMessages(id),
            reactions: const [],
          );
          row = history.latestForPreview(
              nowMs: DateTime.now().millisecondsSinceEpoch);
        } catch (_) {
          // A failed read is a row without a preview, not a failed list.
        }
        if (generation != _sessionGeneration || session == null) return;
        // The chat may have been opened while this read ran: its own history
        // wins, and this answer is stale.
        if (_history.containsKey(id)) continue;
        _previewMemo[id] = (source: null, row: row);
        changed = true;
      }
    } finally {
      _previewLoading.removeAll(wanted);
    }
    if (changed) notifyListeners();
  }
}
