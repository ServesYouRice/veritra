// U38 guard: every screen of lib/features is in the screen-photograph
// catalogue, or skipped there with a reason.
//
// This runs in the normal suite (it only reads source files). It fails when
//   * a Screen, Page, Dialog or Sheet class is added under lib/features with
//     no entry in screen_catalog.dart, and no PhotoScreen.skipped for it;
//   * an entry names a class that no longer exists (a rename or a delete);
//   * two entries share a file name, or a skip has no reason.
// Fix a failure by adding a PhotoScreen.direct to screen_catalog.dart (see
// the comment at its top). Skipping is for a screen that truly cannot be
// built offline, and the reason must say why.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'screen_catalog.dart';

/// Classes that are screens, pages, dialogs or sheets by name. Dart 3 class
/// modifiers are allowed; a name ending in "State" (a widget's State class)
/// does not match because the suffix must end the name.
final _classPattern = RegExp(
  r'^(?:(?:abstract|base|final|sealed|interface|mixin)\s+)*class\s+'
  r'(_?[A-Za-z0-9]*(?:Screen|Page|Dialog|Sheet))\b',
  multiLine: true,
);

/// Entries that name a function or a private form the sheet shows, not a
/// class that has its own declaration with a matching name. Each is checked
/// to exist as an identifier in lib/features.
Set<String> _declaredIdentifiers(String source) =>
    RegExp(r'[A-Za-z_][A-Za-z0-9_]*')
        .allMatches(source)
        .map((m) => m.group(0)!)
        .toSet();

void main() {
  final features = Directory('lib/features');

  test('lib/features is where the test expects it', () {
    expect(features.existsSync(), isTrue, reason: 'run from mobile/');
  });

  final files = features
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final declared = <String, String>{}; // class name -> file
  final identifiers = <String>{};
  for (final file in files) {
    final source = file.readAsStringSync();
    for (final match in _classPattern.allMatches(source)) {
      declared[match.group(1)!] = file.path;
    }
    identifiers.addAll(_declaredIdentifiers(source));
  }

  test('the scan finds the screens it should', () {
    // A broken regex would pass the guard by finding nothing.
    expect(
        declared.keys,
        containsAll(<String>[
          'ChatScreen',
          'SettingsScreen',
          'ConnectScreen',
          'CommunityScreen',
        ]));
    expect(declared.length, greaterThan(40));
  });

  test('every Screen, Page, Dialog and Sheet has a photograph or a skip', () {
    final covered = photoScreens.map((s) => s.className).toSet();
    final missing = <String>[
      for (final entry in declared.entries)
        if (!covered.contains(entry.key)) '${entry.key} (${entry.value})',
    ]..sort();
    expect(
      missing,
      isEmpty,
      reason: 'Add a PhotoScreen.direct to test/screen_photos/'
          'screen_catalog.dart for each, or a PhotoScreen.skipped with the '
          'reason it cannot be built offline.',
    );
  });

  test('no entry names a class that is gone', () {
    final stale = <String>[
      for (final screen in photoScreens)
        if (!identifiers.contains(screen.className)) screen.className,
    ]..sort();
    expect(
      stale,
      isEmpty,
      reason: 'These names no longer appear in lib/features; rename or '
          'remove their entries in screen_catalog.dart.',
    );
  });

  test('file names are unique and skips say why', () {
    final names = <String>{};
    for (final screen in photoScreens) {
      expect(
        names.add(screen.name),
        isTrue,
        reason: 'two entries are named ${screen.name}',
      );
      if (screen.isSkipped) {
        expect(
          screen.skipReason!.trim().length,
          greaterThan(20),
          reason: '${screen.className} is skipped without a real reason',
        );
      }
    }
  });
}
