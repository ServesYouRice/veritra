import 'dart:async';
import 'dart:io';

import 'api_client.dart';
import '../crypto/backup_service.dart';
import '../storage/local_store.dart';

/// Sending is refused because the server rejected an MLS control message
/// for the conversation and it stays queued (I34).
class ConversationPausedException implements Exception {
  const ConversationPausedException();

  @override
  String toString() => 'Sending is paused in this conversation.';
}

/// An error whose [message] is already safe to show, for paths that hand
/// errors to widgets instead of storing [describeError] in AppState.
class UserFacingException implements Exception {
  const UserFacingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Dart core StateError texts, which are capitalised but not user-facing.
const Set<String> _dartStateErrors = <String>{
  'No element',
  'Too many elements',
  'Future already completed',
  'Stream has already been listened to.',
  'Cannot add event after closing',
  'Cannot add new events after calling close',
};

bool _isUserSentence(String message) {
  if (message.isEmpty || message.length > 200) return false;
  if (_dartStateErrors.contains(message)) return false;
  final first = message.codeUnitAt(0);
  return first >= 0x41 && first <= 0x5a;
}

/// Maps any thrown error to a sentence safe to show to end users.
///
/// AppState stores the result of this instead of `toString()`: raw exception
/// text is developer-facing, sometimes leaks internals (server error codes,
/// "Bad state: …" prefixes), and never tells the user what to do next.
String describeError(Object error) {
  if (error is OutboxFullException) {
    return 'Your encrypted message queue is full. Send or discard a pending '
        'message before composing another.';
  }
  if (error is BackupException) {
    return error.message;
  }
  if (error is ConversationPausedException) {
    return 'Sending is paused in this conversation because the server '
        'rejected an encryption update. Other conversations still work.';
  }
  if (error is UserFacingException) {
    return error.message;
  }
  if (error is ApiException) {
    return error.message;
  }
  if (error is ApiResponseException || error is ApiResponseTooLargeException) {
    return 'The server returned an unexpected response.';
  }
  if (error is StateError) {
    final message = error.message;
    if (message.contains('MLS') || message.contains('encryption')) {
      return 'This build does not include the production encryption engine '
          'yet, so this action is unavailable.';
    }
    // App-authored StateErrors that start with a capital letter are written
    // as user-facing sentences (e.g. "Password login requires this device
    // to be linked first."), so surface them without the "Bad state:"
    // prefix. Lower-case implementation messages and Dart's own StateErrors
    // never reach the UI (card T44A).
    if (_isUserSentence(message)) return message;
    if (message.contains('not available') || message.contains('unavailable')) {
      return 'This action is unavailable in this build.';
    }
    return 'Something went wrong. Please try again.';
  }
  if (error is TimeoutException) {
    return 'The server took too long to respond. Try again.';
  }
  if (error is SocketException || error is HttpException) {
    return 'Could not reach the server. Check the instance URL and your '
        'connection.';
  }
  if (error is FormatException) {
    return 'The server returned an unexpected response.';
  }
  return 'Something went wrong. Please try again.';
}
