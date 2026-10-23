import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_errors.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/ui/widgets/demo_banner.dart';

/// Card T44C: user-facing strings in `lib/features` and `lib/ui` come from
/// `lib/l10n/app_en.arb`. This scan fails when a `Text('…')` (or a tooltip,
/// hint, label text or semantics label) is written as a literal that holds a
/// word, so a new hard-coded English string cannot slip back in.
///
/// Literals without letters (separators, interpolation only) are fine. Add
/// to [_allowed] only text that must never be translated, as
/// `path: literal`.
const Set<String> _allowed = <String>{
  // An example server origin, the same in every language.
  'lib/features/auth/connect_screen.dart: https://chat.example.org',
};

final RegExp _literal = RegExp(
  r'''(?:\bText|\btooltip:|\bhintText:|\blabelText:|\bhelperText:|'''
  r'''\bsemanticsLabel:|\bsemanticLabel:)\s*\(?\s*(?:const\s+)?'''
  r'''(['"])((?:(?!\1).)*)\1''',
);

final RegExp _word = RegExp(r'[A-Za-z]{2,}');

void main() {
  test('no hard-coded user-facing literals in lib/features or lib/ui', () {
    final offenders = <String>[];
    for (final root in <String>['lib/features', 'lib/ui']) {
      final files = Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      for (final file in files) {
        final path = file.path.replaceAll(r'\', '/');
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          for (final match in _literal.allMatches(line)) {
            final text = match.group(2)!;
            // Interpolated values are data; only literal words count.
            final literalPart =
                text.replaceAll(RegExp(r'\$\{[^}]*\}|\$\w+'), '');
            if (!_word.hasMatch(literalPart)) continue;
            if (_allowed.contains('$path: $text')) continue;
            offenders.add('$path:${i + 1}: $text');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Move these strings into lib/l10n/app_en.arb and read them '
          'through context.l10n.',
    );
  });

  test('the demo banner label stays in the English strings', () {
    expect(englishL10n.demoBannerLabel, DemoBanner.label);
    expect(
      englishL10n.demoBannerNotice(englishL10n.demoBannerLabel),
      '${DemoBanner.label}. Not for real conversations.',
    );
  });

  test('typed errors read their text from the localizations', () {
    expect(
      describeError(TimeoutException('slow'), englishL10n),
      englishL10n.errorTimeout,
    );
    expect(
      ApiException(401, '{"error":"unauthorized"}').message,
      englishL10n.apiErrorSessionInvalid,
    );
  });

  test('the scan catches a hard-coded Text literal', () {
    expect(_literal.hasMatch("child: const Text('Cancel'),"), isTrue);
    expect(_literal.hasMatch("tooltip: 'Refresh',"), isTrue);
    expect(
        _literal.hasMatch('child: Text(context.l10n.commonCancel),'), isFalse);
  });
}
