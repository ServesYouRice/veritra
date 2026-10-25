import 'dart:async';

import 'package:flutter/foundation.dart';

/// Largest conversation that shows or sends typing signals (W5). Past it a
/// "someone is typing" line is noise and every keystroke would fan out to
/// that many sockets.
const int typingMaxMembers = 20;

/// How long a person stays "typing" after their last signal. The sender
/// repeats about every [typingSendInterval] while they keep typing.
const Duration typingExpiry = Duration(seconds: 5);

/// The least gap between two typing signals this device sends for one
/// conversation. The server admits one per two seconds and answers 429 to
/// more, so this stays just above that.
const Duration typingSendInterval = Duration(milliseconds: 2500);

/// Who is typing, per conversation (W5). Memory only: a typing signal is
/// never stored, on the server or here, and carries no content.
class TypingState extends ChangeNotifier {
  TypingState({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  // One timer per typer. A map keeps insertion order; a fresh signal moves
  // its typer to the end, so the list reads oldest signal first.
  final Map<String, Map<String, Timer>> _typers =
      <String, Map<String, Timer>>{};
  final Map<String, DateTime> _lastSent = <String, DateTime>{};
  bool _disposed = false;

  /// Accounts typing in [conversationId] right now, oldest signal first.
  List<String> typersIn(String conversationId) =>
      List<String>.unmodifiable(_typers[conversationId]?.keys ?? const []);

  /// A typing signal arrived for [accountId].
  void remoteTyping(String conversationId, String accountId) {
    if (_disposed) return;
    final typers = _typers.putIfAbsent(conversationId, () => <String, Timer>{});
    final previous = typers.remove(accountId);
    previous?.cancel();
    typers[accountId] = Timer(typingExpiry, () {
      if (_disposed) return;
      if (_typers[conversationId]?.remove(accountId) != null) {
        notifyListeners();
      }
    });
    // Cheap: the one listener is the typing line, a single Text.
    notifyListeners();
  }

  /// [accountId] sent a message, so they are no longer typing.
  void stoppedTyping(String conversationId, String accountId) {
    final timer = _typers[conversationId]?.remove(accountId);
    if (timer != null) {
      timer.cancel();
      if (!_disposed) notifyListeners();
    }
  }

  /// True when a signal for [conversationId] may go out now; records it.
  bool takeSendSlot(String conversationId) {
    final now = _now();
    final last = _lastSent[conversationId];
    if (last != null && now.difference(last) < typingSendInterval) {
      return false;
    }
    _lastSent[conversationId] = now;
    return true;
  }

  void _cancelAll() {
    for (final typers in _typers.values) {
      for (final timer in typers.values) {
        timer.cancel();
      }
    }
    _typers.clear();
  }

  /// Forgets everything, e.g. on sign-out.
  void clear() {
    _cancelAll();
    _lastSent.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAll();
    super.dispose();
  }
}
