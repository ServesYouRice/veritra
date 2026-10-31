// snippetFor builds its excerpt from UTF-16 offsets; the window edges and the
// truncation point must never fall between the two halves of an emoji
// (TASK-088).
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/storage/message_search.dart';

/// Whether [text] is well-formed UTF-16: every surrogate has its partner.
bool _wellFormed(String text) {
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (i + 1 >= units.length) return false;
      final next = units[i + 1];
      if (next < 0xdc00 || next > 0xdfff) return false;
      i++;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

/// The algorithm as it was before surrogate-aware edges, for text that has no
/// astral characters (where the two must agree).
String _reference(String text, List<String> terms, {int radius = 48}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final lower = flat.toLowerCase();
  if (lower.length != flat.length) {
    return flat.length <= 2 * radius
        ? flat
        : '${flat.substring(0, 2 * radius)}…';
  }
  var first = -1;
  for (final term in terms) {
    final at = lower.indexOf(term);
    if (at >= 0 && (first < 0 || at < first)) first = at;
  }
  final start = first <= radius ? 0 : first - radius;
  final end =
      flat.length <= start + 2 * radius ? flat.length : start + 2 * radius;
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

void main() {
  const smile = '\u{1F600}'; // two UTF-16 units
  const terms = <String>['needle'];

  test('no edge of the window splits an emoji, wherever it falls', () {
    for (final radius in <int>[4, 5, 6, 7, 48]) {
      for (var before = 0; before <= 2 * radius + 4; before++) {
        for (var after = 0; after <= 2 * radius + 4; after++) {
          final text = '${smile * before}needle${smile * after}';
          final snippet = snippetFor(text, terms, radius: radius);
          expect(_wellFormed(snippet), isTrue,
              reason: 'radius $radius, $before before, $after after: $snippet');
        }
      }
    }
  });

  test('emoji mixed with letters at every offset stay whole', () {
    for (var lead = 0; lead < 40; lead++) {
      for (var gap = 0; gap < 6; gap++) {
        final text =
            '${'a' * lead}$smile${'b' * gap}${smile * 30}needle ${smile * 30}';
        final snippet = snippetFor(text, terms, radius: 8);
        expect(_wellFormed(snippet), isTrue,
            reason: 'lead $lead, gap $gap: $snippet');
      }
    }
  });

  test('a match that runs into the window end is clipped whole', () {
    // The term itself holds an astral character that straddles the end.
    for (var lead = 0; lead < 24; lead++) {
      final text = '${'a' * lead}x${smile}x${'a' * 60}';
      final snippet = snippetFor(text, <String>['x${smile}x'], radius: 6);
      expect(_wellFormed(snippet), isTrue,
          reason: 'lead $lead produced $snippet');
    }
  });

  test('text whose lower-case changes length is cut on a character', () {
    // "İ" lower-cases to two code units, which disables the marked window.
    for (final radius in <int>[4, 5, 6]) {
      for (var lead = 0; lead <= 2 * radius + 2; lead++) {
        final text = '${'a' * lead}İ${smile * 40}';
        final snippet = snippetFor(text, terms, radius: radius);
        expect(_wellFormed(snippet), isTrue,
            reason: 'radius $radius lead $lead produced $snippet');
        expect(snippet, endsWith('…'));
      }
    }
  });

  test('the window moves by at most one unit at each edge', () {
    final text = '${smile * 60}needle${smile * 60}';
    final plain = 'a' * 60;
    for (var radius = 4; radius < 10; radius++) {
      final snippet = snippetFor(text, terms, radius: radius);
      final body = snippet
          .replaceAll('…', '')
          .replaceAll(snippetMatchStart, '')
          .replaceAll(snippetMatchEnd, '');
      expect(body.length, inInclusiveRange(2 * radius - 2, 2 * radius + 2));
    }
    expect(plain, isNotEmpty);
  });

  test('text without astral characters is unchanged', () {
    final samples = <String>[
      'needle',
      'a needle in a haystack',
      '${'word ' * 30}needle${' word' * 30}',
      'Needle at the START and needle later ${'x' * 120}',
      'čćšđž ${'ž' * 70} needle ${'ć' * 70}',
      'short',
    ];
    for (final sample in samples) {
      for (final radius in <int>[3, 8, 20, 48]) {
        expect(snippetFor(sample, terms, radius: radius),
            _reference(sample, terms, radius: radius),
            reason: '"$sample" radius $radius');
      }
    }
  });

  test('matches are still marked', () {
    final snippet = snippetFor('see the needle ${smile * 10}', terms);
    expect(snippet, contains('${snippetMatchStart}needle$snippetMatchEnd'));
  });
}
