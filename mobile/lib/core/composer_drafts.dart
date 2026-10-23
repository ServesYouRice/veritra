import '../storage/encrypted_database.dart' show LocalMessage;

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
class ComposerDrafts {
  final Map<String, String> _text = <String, String>{};
  final Map<String, LocalMessage> _replyTo = <String, LocalMessage>{};

  /// The unsent text of [conversationId], or an empty string.
  String textFor(String conversationId) => _text[conversationId] ?? '';

  void setText(String conversationId, String text) {
    if (text.isEmpty) {
      _text.remove(conversationId);
    } else {
      _text[conversationId] = text;
    }
  }

  /// The message the next send in [conversationId] replies to, if any.
  LocalMessage? replyTargetFor(String conversationId) =>
      _replyTo[conversationId];

  void setReplyTarget(String conversationId, LocalMessage? message) {
    if (message == null) {
      _replyTo.remove(conversationId);
    } else {
      _replyTo[conversationId] = message;
    }
  }

  /// After [text] (trimmed, as sent) was accepted for sending: clears the
  /// draft unless it was edited since, and the reply target unless another
  /// one was chosen. Works when the chat screen has already closed.
  void clearSent(
    String conversationId, {
    required String text,
    LocalMessage? replyTo,
  }) {
    if (textFor(conversationId).trim() == text) _text.remove(conversationId);
    if (identical(_replyTo[conversationId], replyTo)) {
      _replyTo.remove(conversationId);
    }
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
