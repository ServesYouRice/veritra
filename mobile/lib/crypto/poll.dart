import 'dart:convert';

/// Polls and votes (B3, `docs/crypto.md` section 5.5).
///
/// A poll is an encrypted message; the apps count the votes, and the server
/// sees only ciphertext. A poll row keeps its question, options and the votes
/// received so far as one JSON object in `LocalMessages.body`, so no schema
/// change is needed. Deleting the poll clears the body and so its votes.

const int maxPollQuestionLength = 300;
const int minPollOptions = 2;
const int maxPollOptions = 12;
const int maxPollOptionLength = 100;

/// True when [body] is a well-formed `poll` payload body: a question of 1-300
/// UTF-16 units, 2-12 unique options of 1-100 units, and a bool
/// `multiple_choice`. Unknown extra fields are ignored (v2 rule P6).
bool isValidPollBody(Map<String, Object?> body) {
  final question = body['question'];
  final options = body['options'];
  if (question is! String ||
      question.trim().isEmpty ||
      question.length > maxPollQuestionLength ||
      options is! List ||
      options.length < minPollOptions ||
      options.length > maxPollOptions ||
      body['multiple_choice'] is! bool) {
    return false;
  }
  final seen = <String>{};
  for (final option in options) {
    if (option is! String ||
        option.trim().isEmpty ||
        option.length > maxPollOptionLength ||
        !seen.add(option)) {
      return false;
    }
  }
  return true;
}

/// True when [body] has the shape of a `poll_vote`: a target key and a list
/// of at most 12 integers. Range, duplicate, single-choice and target checks
/// happen when the vote is applied, so a bad vote is an action row with no
/// effect, not an invalid message.
bool isValidPollVoteBody(Map<String, Object?> body) {
  final target = body['message_id'];
  final choices = body['choices'];
  return target is String &&
      target.length <= 128 &&
      choices is List &&
      choices.length <= maxPollOptions &&
      choices.every((choice) => choice is int);
}

/// True when [body] has the shape of a `poll_close`: a target key. Whether
/// the sender is the poll's author is checked when the close is applied.
bool isValidPollCloseBody(Map<String, Object?> body) {
  final target = body['message_id'];
  return target is String && target.length <= 128;
}

/// The text stored in a new poll row: the poll plus an empty vote table.
String pollRowBody(Map<String, Object?> body) => jsonEncode(<String, Object?>{
      'question': body['question'],
      'options': body['options'],
      'multiple_choice': body['multiple_choice'],
      'votes': <String, Object?>{},
    });

/// A poll row as shown to the person.
class PollView {
  const PollView({
    required this.question,
    required this.options,
    required this.multipleChoice,
    required this.votes,
    this.closed = false,
  });

  final String question;
  final List<String> options;
  final bool multipleChoice;

  /// Option indexes by voting account.
  final Map<String, List<int>> votes;

  /// True once the author closed the poll; later votes are ignored.
  final bool closed;

  /// Votes per option. With [members], only accounts in that roster count.
  List<int> tally({Set<String>? members}) {
    final counts = List<int>.filled(options.length, 0);
    for (final entry in votes.entries) {
      if (members != null && !members.contains(entry.key)) continue;
      for (final index in entry.value) {
        counts[index]++;
      }
    }
    return counts;
  }

  /// How many accounts voted; with [members], only roster accounts count.
  int voterCount({Set<String>? members}) => votes.keys
      .where((account) => members == null || members.contains(account))
      .length;
}

/// Reads a stored poll row body; null when it is missing or damaged.
PollView? parsePollBody(String? json) {
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final body = Map<String, Object?>.from(decoded);
    if (!isValidPollBody(body)) return null;
    final options = (body['options'] as List).cast<String>();
    final votes = <String, List<int>>{};
    final rawVotes = body['votes'];
    if (rawVotes is Map) {
      for (final entry in rawVotes.entries) {
        final value = entry.value;
        if (entry.key is String &&
            value is List &&
            value.isNotEmpty &&
            value.every((v) => v is int && v >= 0 && v < options.length)) {
          votes[entry.key as String] = value.cast<int>();
        }
      }
    }
    return PollView(
      question: body['question'] as String,
      options: options,
      multipleChoice: body['multiple_choice'] as bool,
      votes: votes,
      closed: body['closed'] == true,
    );
  } catch (_) {
    return null;
  }
}

/// The poll body after [voter] votes [choices], or null when the vote has no
/// effect at all: the body is not a poll, an index is out of range or repeated,
/// or a single-choice poll got more than one index. An empty list retracts the
/// voter's vote. The last valid vote replaces the earlier one. A closed poll
/// takes no vote.
String? applyPollVote(String? pollBody, String voter, List<int> choices) {
  final poll = parsePollBody(pollBody);
  if (poll == null || poll.closed) return null;
  if (choices.length > maxPollOptions ||
      choices.toSet().length != choices.length ||
      choices.any((index) => index < 0 || index >= poll.options.length) ||
      (!poll.multipleChoice && choices.length > 1)) {
    return null;
  }
  final votes = <String, Object?>{
    for (final entry in poll.votes.entries) entry.key: entry.value,
  };
  if (choices.isEmpty) {
    votes.remove(voter);
  } else {
    votes[voter] = List<int>.from(choices)..sort();
  }
  return _encodePoll(poll, votes, false);
}

/// The poll body after the author closes it, or null when the body is not a
/// poll or is already closed. The votes so far are kept and frozen. The caller
/// checks that the close came from the poll's author.
String? applyPollClose(String? pollBody) {
  final poll = parsePollBody(pollBody);
  if (poll == null || poll.closed) return null;
  return _encodePoll(poll, poll.votes, true);
}

String _encodePoll(PollView poll, Map<String, Object?> votes, bool closed) {
  return jsonEncode(<String, Object?>{
    'question': poll.question,
    'options': poll.options,
    'multiple_choice': poll.multipleChoice,
    'votes': votes,
    if (closed) 'closed': true,
  });
}
