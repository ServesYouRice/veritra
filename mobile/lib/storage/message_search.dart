/// Search over the message text this device holds (W10). Everything here runs
/// against the encrypted local database; no query, term or result leaves the
/// device.
library;

/// Marks the start and end of a matched term inside [MessageSearchHit.snippet].
/// Control characters, so no message text can contain them by accident.
const String snippetMatchStart = '\u0001';
const String snippetMatchEnd = '\u0002';

/// One message that matched a search.
class MessageSearchHit {
  const MessageSearchHit({
    required this.key,
    required this.conversationId,
    required this.senderAccountId,
    required this.createdAt,
    required this.snippet,
  });

  /// The local history key of the message.
  final String key;
  final String conversationId;
  final String senderAccountId;

  /// Epoch milliseconds.
  final int createdAt;

  /// An excerpt of the text with each matched term between
  /// [snippetMatchStart] and [snippetMatchEnd].
  final String snippet;
}

/// The words of a search, at most [maxSearchTerms]. Anything that is not a
/// letter or a digit separates words, so no input can form FTS syntax.
List<String> searchTerms(String query) {
  final terms = <String>[];
  for (final match in RegExp(r'[\p{L}\p{N}]+', unicode: true)
      .allMatches(query.toLowerCase())) {
    final term = match.group(0)!;
    if (!terms.contains(term)) terms.add(term);
    if (terms.length == maxSearchTerms) break;
  }
  return terms;
}

const int maxSearchTerms = 8;

/// The FTS5 query for [terms]: every term must appear, the last may be a
/// prefix of a longer word (search as you type). Terms are quoted, so they
/// are always read as plain words.
String ftsQueryFor(List<String> terms) {
  final parts = <String>[
    for (final term in terms) '"${term.replaceAll('"', '""')}"',
  ];
  if (parts.isNotEmpty) parts[parts.length - 1] = '${parts.last}*';
  return parts.join(' ');
}

/// [index] moved back one when it falls between the two halves of a
/// surrogate pair (an emoji or other character outside the BMP), so that an
/// excerpt cut there keeps the character whole or leaves it out.
int _wholeCharacterAt(String text, int index) {
  if (index <= 0 || index >= text.length) return index;
  final unit = text.codeUnitAt(index);
  final before = text.codeUnitAt(index - 1);
  final splits =
      unit >= 0xdc00 && unit <= 0xdfff && before >= 0xd800 && before <= 0xdbff;
  return splits ? index - 1 : index;
}

/// An excerpt of [text] around the first matched term, with matches marked,
/// built the way the database builds it. Used where there is no FTS index.
/// The window edges never split a surrogate pair, so it can be a code unit
/// shorter or longer at each end than 2 * [radius].
String snippetFor(String text, List<String> terms, {int radius = 48}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final lower = flat.toLowerCase();
  // A few letters change length when lower-cased; their offsets would not
  // line up, so such text is shown without marks.
  if (lower.length != flat.length) {
    return flat.length <= 2 * radius
        ? flat
        : '${flat.substring(0, _wholeCharacterAt(flat, 2 * radius))}…';
  }
  var first = -1;
  for (final term in terms) {
    final at = lower.indexOf(term);
    if (at >= 0 && (first < 0 || at < first)) first = at;
  }
  final start = first <= radius ? 0 : _wholeCharacterAt(flat, first - radius);
  final end = flat.length <= start + 2 * radius
      ? flat.length
      : _wholeCharacterAt(flat, start + 2 * radius);
  final buffer = StringBuffer();
  if (start > 0) buffer.write('…');
  var index = start;
  while (index < end) {
    var matched = 0;
    for (final term in terms) {
      if (term.length > matched &&
          index + term.length <= flat.length &&
          lower.startsWith(term, index)) {
        matched = term.length;
      }
    }
    if (matched > 0) {
      final stop = index + matched > end ? end : index + matched;
      buffer
        ..write(snippetMatchStart)
        ..write(flat.substring(index, stop))
        ..write(snippetMatchEnd);
      index = stop;
    } else {
      buffer.write(flat[index]);
      index++;
    }
  }
  if (end < flat.length) buffer.write('…');
  return buffer.toString();
}
