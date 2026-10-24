import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/l10n/l10n.dart';

/// Card T44C: every locale translates exactly the English messages, with the
/// same placeholders and ICU structure, so no screen silently falls back to
/// English or loses a value.

const _serbianLatin =
    Locale.fromSubtags(languageCode: 'sr', scriptCode: 'Latn');

Map<String, Object?> _readArb(String name) =>
    jsonDecode(File('lib/l10n/$name').readAsStringSync())
        as Map<String, Object?>;

Map<String, String> _messages(Map<String, Object?> arb) => <String, String>{
      for (final entry in arb.entries)
        if (!entry.key.startsWith('@')) entry.key: entry.value! as String,
    };

/// One `{name}` or `{name, plural|select, ...}` argument of a message.
class _Argument {
  _Argument(this.name, this.kind, this.cases);

  final String name;

  /// `plural`, `select`, or null for a plain placeholder.
  final String? kind;

  /// Case key to case message, for `plural` and `select`.
  final Map<String, List<_Argument>> cases;

  String get shape =>
      kind == null ? name : '$name, $kind, ${cases.keys.toList()..sort()}';
}

/// A small ICU MessageFormat reader for what gen-l10n accepts here (no
/// `use-escaping`, so every `{` opens an argument). Returns the top-level
/// arguments; nested ones sit in [_Argument.cases].
List<_Argument> _parse(String message) {
  var index = 0;

  Never fail(String why) => throw FormatException('$why in "$message"');

  String readUntil(String stops) {
    final start = index;
    while (index < message.length && !stops.contains(message[index])) {
      index++;
    }
    if (index >= message.length) fail('unterminated argument');
    return message.substring(start, index).trim();
  }

  late List<_Argument> Function({required bool nested}) readMessage;

  _Argument readArgument() {
    index++; // {
    final name = readUntil(',}');
    if (message[index] == '}') {
      index++;
      return _Argument(name, null, const <String, List<_Argument>>{});
    }
    index++; // ,
    final kind = readUntil(',}');
    if (kind != 'plural' && kind != 'select') fail('unexpected type $kind');
    if (message[index] == '}') fail('$kind without cases');
    index++; // ,
    final cases = <String, List<_Argument>>{};
    while (true) {
      final key = readUntil('{}');
      if (message[index] == '}') {
        if (key.isNotEmpty) fail('case "$key" without a message');
        index++;
        return _Argument(name, kind, cases);
      }
      if (key.isEmpty) fail('case without a key');
      if (cases.containsKey(key)) fail('duplicate case $key');
      index++; // {
      cases[key] = readMessage(nested: true);
      index++; // }
    }
  }

  readMessage = ({required bool nested}) {
    final arguments = <_Argument>[];
    while (index < message.length) {
      final char = message[index];
      if (char == '{') {
        arguments.add(readArgument());
      } else if (char == '}') {
        if (!nested) fail('unmatched }');
        return arguments;
      } else {
        index++;
      }
    }
    if (nested) fail('unterminated case');
    return arguments;
  };

  return readMessage(nested: false);
}

/// Every argument name used anywhere in [arguments], nested ones included.
Set<String> _names(List<_Argument> arguments) => <String>{
      for (final argument in arguments) ...<String>{
        argument.name,
        for (final nested in argument.cases.values) ..._names(nested),
      },
    };

List<_Argument> _flatten(List<_Argument> arguments) => <_Argument>[
      for (final argument in arguments) ...<_Argument>[
        argument,
        for (final nested in argument.cases.values) ..._flatten(nested),
      ],
    ];

/// For each argument name, how it is used: as a plain placeholder (`value`),
/// a `plural` or a `select`.
Map<String, Set<String>> _kinds(List<_Argument> arguments) {
  final kinds = <String, Set<String>>{};
  for (final argument in _flatten(arguments)) {
    kinds.putIfAbsent(argument.name, () => <String>{}).add(
          argument.kind ?? 'value',
        );
  }
  return kinds;
}

/// The CLDR plural categories Serbian uses for integers.
const _serbianPluralCases = <String>{'one', 'few', 'other'};

void main() {
  final english = _readArb('app_en.arb');
  final englishMessages = _messages(english);
  final translations = <String, Map<String, Object?>>{
    for (final file in Directory('lib/l10n')
        .listSync()
        .whereType<File>()
        .map((file) => file.uri.pathSegments.last)
        .where((name) => name.endsWith('.arb') && name != 'app_en.arb'))
      file: _readArb(file),
  };

  test('the ARB files are English, Serbian and Serbian Latin', () {
    expect(english['@@locale'], 'en');
    expect(
        translations.keys.toSet(), <String>{'app_sr.arb', 'app_sr_Latn.arb'});
    for (final entry in translations.entries) {
      final locale = entry.key.substring(4, entry.key.length - 4);
      expect(entry.value['@@locale'], locale, reason: entry.key);
    }
  });

  test('every English message parses', () {
    for (final entry in englishMessages.entries) {
      expect(() => _parse(entry.value), returnsNormally, reason: entry.key);
    }
  });

  for (final file in translations.keys) {
    group(file, () {
      final messages = _messages(translations[file]!);

      test('has exactly the English keys, in the same order', () {
        expect(messages.keys.toList(), englishMessages.keys.toList());
      });

      test('keeps every placeholder and ICU structure', () {
        for (final key in englishMessages.keys) {
          final source = _parse(englishMessages[key]!);
          final translated = _parse(messages[key]!);
          expect(_names(translated), _names(source), reason: key);
          expect(
            translated.map((argument) => argument.kind).toList(),
            source.map((argument) => argument.kind).toList(),
            reason: '$key keeps its top-level arguments',
          );
          // `{count}` inside a plural on `count` is fine; using `count` as a
          // select, or dropping its plural, is not.
          expect(_kinds(translated), _kinds(source), reason: key);
        }
      });

      test('selects keep their cases and plurals use Serbian categories', () {
        for (final key in englishMessages.keys) {
          final source = <String, _Argument>{
            for (final argument in _flatten(_parse(englishMessages[key]!)))
              if (argument.kind != null) argument.name: argument,
          };
          for (final argument in _flatten(_parse(messages[key]!))) {
            if (argument.kind == 'select') {
              expect(argument.cases.keys.toSet(),
                  source[argument.name]!.cases.keys.toSet(),
                  reason: key);
            } else if (argument.kind == 'plural') {
              final english = source[argument.name]!.cases.keys.toSet();
              final exact = english.where((name) => name.startsWith('='));
              expect(
                argument.cases.keys.toSet(),
                <String>{
                  ..._serbianPluralCases,
                  // A literal =0 says something other than "0 items".
                  ...exact.where((name) => name == '=0'),
                },
                reason: '$key: ${argument.shape}',
              );
            }
          }
        }
      });
    });
  }

  test('the Latin file holds no Cyrillic letters', () {
    final cyrillic = RegExp('[Ѐ-ӿ]');
    for (final entry in _messages(translations['app_sr_Latn.arb']!).entries) {
      expect(cyrillic.hasMatch(entry.value), isFalse, reason: entry.key);
    }
  });

  test('supported locales are en, sr and sr_Latn', () {
    expect(AppLocalizations.supportedLocales, <Locale>[
      const Locale('en'),
      const Locale('sr'),
      _serbianLatin,
    ]);
    expect(lookupAppLocalizations(const Locale('sr')).localeName, 'sr');
    expect(lookupAppLocalizations(_serbianLatin).localeName, 'sr_Latn');
    // A region alone does not change the script.
    expect(lookupAppLocalizations(const Locale('sr', 'RS')).localeName, 'sr');
  });

  test('iOS declares the same languages', () {
    // iOS offers only the languages the bundle lists, in its per-app
    // language setting too.
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final declared = RegExp(
      r'<key>CFBundleLocalizations</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist);
    expect(declared, isNotNull);
    expect(
      RegExp(r'<string>([^<]*)</string>')
          .allMatches(declared!.group(1)!)
          .map((match) => match.group(1))
          .toList(),
      AppLocalizations.supportedLocales
          .map((locale) => locale.toLanguageTag())
          .toList(),
    );
  });

  test('Serbian plurals pick the right form', () {
    final sr = lookupAppLocalizations(const Locale('sr'));
    expect(sr.durationDays(1), '1 дан');
    expect(sr.durationDays(2), '2 дана');
    expect(sr.durationDays(7), '7 дана');
    expect(sr.durationDays(21), '21 дан');
    expect(sr.durationHours(1), '1 сат');
    expect(sr.durationHours(24), '24 сата');
    expect(sr.durationHours(5), '5 сати');
    expect(sr.durationHours(11), '11 сати');
    expect(sr.durationMinutes(12), '12 минута');
    expect(sr.communityChannelCount(3), '3 канала');
    expect(sr.chatListUnreadSpoken(1), '1 непрочитана порука');
    expect(sr.chatListUnreadSpoken(3), '3 непрочитане поруке');
    expect(sr.chatListUnreadSpoken(5), '5 непрочитаних порука');
    expect(sr.deviceLinkState('pending'), 'на чекању');
    expect(sr.deviceLinkState('revoked'), 'revoked');

    final latin = lookupAppLocalizations(_serbianLatin);
    expect(latin.durationDays(21), '21 dan');
    expect(latin.chatListUnreadSpoken(3), '3 nepročitane poruke');
    expect(latin.settingsTitle, 'Podešavanja');
  });

  testWidgets('Material, Cupertino and Widgets strings exist for both scripts',
      (tester) async {
    final seen = <String, List<String>>{};
    for (final locale in <Locale>[const Locale('sr'), _serbianLatin]) {
      expect(GlobalMaterialLocalizations.delegate.isSupported(locale), isTrue);
      expect(GlobalCupertinoLocalizations.delegate.isSupported(locale), isTrue);
      expect(GlobalWidgetsLocalizations.delegate.isSupported(locale), isTrue);
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (context) {
          seen[locale.toLanguageTag()] = <String>[
            MaterialLocalizations.of(context).cancelButtonLabel,
            CupertinoLocalizations.of(context).cutButtonLabel,
            Directionality.of(context).name,
            context.l10n.commonCancel,
          ];
          return const SizedBox();
        }),
      ));
    }
    expect(seen['sr'], <String>['Откажи', 'Исеци', 'ltr', 'Откажи']);
    expect(seen['sr-Latn'], <String>['Otkaži', 'Iseci', 'ltr', 'Otkaži']);
  });
}
