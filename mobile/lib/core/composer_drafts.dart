/// Unsent composer text and the message it replies to, per conversation
/// (T49C-4).
///
/// A chat screen reads its conversation's draft when it opens and writes it
/// back as it changes, so leaving the conversation (another destination in
/// the wide layout, another conversation, or back to the list) keeps what
/// was typed.
///
/// Drafts are message text before encryption. They live in this object's
/// memory and, through [onChanged], in the encrypted local database so they
/// survive a restart (W6): never written anywhere else, never sent to the
/// server, never logged, and cleared when the session ends. It is not a
/// listenable on purpose: typing must not notify the app state.
///
/// The reply target is held as the message's key, not as a copy of the
/// message: whoever draws or sends it reads the message from the current
/// history, so an edit shows and a deleted or vanished target is dropped.
class ComposerDrafts {
  final Map<String, String> _text = <String, String>{};
  final Map<String, String> _replyTo = <String, String>{};

  /// Called with the conversation whose draft or reply target changed, after
  /// each change the user (or a send) makes. Not called by [load] or [clear].
  void Function(String conversationId)? onChanged;

  /// Puts drafts read from the local database back, without reporting them as
  /// changes. Replaces whatever was held.
  void load(Map<String, ({String text, String? replyTo})> stored) {
    _text.clear();
    _replyTo.clear();
    for (final entry in stored.entries) {
      if (entry.value.text.isNotEmpty) _text[entry.key] = entry.value.text;
      final reply = entry.value.replyTo;
      if (reply != null) _replyTo[entry.key] = reply;
    }
  }

  /// The unsent text of [conversationId], or an empty string.
  String textFor(String conversationId) => _text[conversationId] ?? '';

  void setText(String conversationId, String text) {
    if (textFor(conversationId) == text) return;
    if (text.isEmpty) {
      _text.remove(conversationId);
    } else {
      _text[conversationId] = text;
    }
    onChanged?.call(conversationId);
  }

  /// The key of the message the next send in [conversationId] replies to,
  /// if any.
  String? replyTargetFor(String conversationId) => _replyTo[conversationId];

  void setReplyTarget(String conversationId, String? messageKey) {
    if (_replyTo[conversationId] == messageKey) return;
    if (messageKey == null) {
      _replyTo.remove(conversationId);
    } else {
      _replyTo[conversationId] = messageKey;
    }
    onChanged?.call(conversationId);
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
    var changed = false;
    if (textFor(conversationId).trim() == text) {
      changed = _text.remove(conversationId) != null;
    }
    if (_replyTo[conversationId] == replyTo) {
      changed = _replyTo.remove(conversationId) != null || changed;
    }
    if (changed) onChanged?.call(conversationId);
  }

  /// Forgets one conversation, for example after leaving it.
  void remove(String conversationId) {
    final hadText = _text.remove(conversationId) != null;
    final hadReply = _replyTo.remove(conversationId) != null;
    if (hadText || hadReply) onChanged?.call(conversationId);
  }

  /// Forgets every conversation not in [conversationIds]: one that left the
  /// conversation list another way (removed by an admin, or missing after a
  /// refresh) takes its draft with it.
  void retainOnly(Iterable<String> conversationIds) {
    final keep = conversationIds.toSet();
    final gone = <String>{
      ..._text.keys.where((id) => !keep.contains(id)),
      ..._replyTo.keys.where((id) => !keep.contains(id)),
    };
    for (final id in gone) {
      remove(id);
    }
  }

  /// Forgets every draft in memory. Called whenever the session ends; the
  /// local database wipes its own copy with the rest of the data.
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
