/// Unsent composer text and the message it replies to, per conversation
/// (T49C-4).
///
/// A chat screen reads its conversation's draft when it opens and writes it
/// back as it changes, so leaving the conversation (another destination in
/// the wide layout, another conversation, or back to the list) keeps what
/// was typed.
///
/// Drafts are message text before encryption. They stay in this object's
/// memory only: never written to the local database, never sent to the
/// server, never logged, and cleared when the session ends. It is not a
/// listenable on purpose: typing must not notify the app state.
///
/// The reply target is held as the message's key, not as a copy of the
/// message: whoever draws or sends it reads the message from the current
/// history, so an edit shows and a deleted or vanished target is dropped.
class ComposerDrafts {
  final Map<String, String> _text = <String, String>{};
  final Map<String, String> _replyTo = <String, String>{};

  /// The unsent text of [conversationId], or an empty string.
  String textFor(String conversationId) => _text[conversationId] ?? '';

  void setText(String conversationId, String text) {
    if (text.isEmpty) {
      _text.remove(conversationId);
    } else {
      _text[conversationId] = text;
    }
  }

  /// The key of the message the next send in [conversationId] replies to,
  /// if any.
  String? replyTargetFor(String conversationId) => _replyTo[conversationId];

  void setReplyTarget(String conversationId, String? messageKey) {
    if (messageKey == null) {
      _replyTo.remove(conversationId);
    } else {
      _replyTo[conversationId] = messageKey;
    }
  }

  /// After [text] (trimmed, as sent) was accepted for sending, replying to
  /// the message keyed [replyTo]: clears the draft unless it was edited
  /// since, and the reply target unless another one was chosen. Works when
  /// the chat screen has already closed.
  void clearSent(
    String conversationId, {
    required String text,
    String? replyTo,
  }) {
    if (textFor(conversationId).trim() == text) _text.remove(conversationId);
    if (_replyTo[conversationId] == replyTo) _replyTo.remove(conversationId);
  }

  /// Forgets one conversation, for example after leaving it.
  void remove(String conversationId) {
    _text.remove(conversationId);
    _replyTo.remove(conversationId);
  }

  /// Forgets every draft. Called whenever the session ends.
  void clear() {
    _text.clear();
    _replyTo.clear();
  }

  bool get isEmpty => _text.isEmpty && _replyTo.isEmpty;

  /// Counts only: draft text must never reach a log.
  @override
  String toString() =>
      'ComposerDrafts(${_text.length} drafts, ${_replyTo.length} replies)';
}
