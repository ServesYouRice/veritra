import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_errors.dart';
import 'package:private_messenger/core/errors.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/ui/widgets/demo_banner.dart';

/// Card T44C: user-facing strings in `lib/features` and `lib/ui` come from
/// `lib/l10n/app_en.arb`. This scan fails when user-visible text is written
/// as a literal that holds a word, so a new hard-coded English string cannot
/// slip back in. It reads whole files, so a literal that `dart format`
/// wrapped onto the next line, or split into adjacent pieces, still counts.
///
/// It looks at: the positional text of `Text(` and `SelectableText(`; the
/// named arguments in [_textArguments] of any call; `message:` of
/// `Tooltip(`; and `text:` of `Tab(` and `TextSpan(`.
///
/// Literals without a run of two letters (separators, interpolation only)
/// are fine. Add to [_allowed] only text that must never be translated, as
/// `path: literal`.
const Set<String> _allowed = <String>{
  // An example server origin, the same in every language.
  'lib/features/auth/connect_screen.dart: https://chat.example.org',
};

/// Named arguments that carry user-visible text wherever they appear.
const Set<String> _textArguments = <String>{
  'tooltip',
  'hintText',
  'labelText',
  'helperText',
  'errorText',
  'counterText',
  'prefixText',
  'suffixText',
  'semanticsLabel',
  'semanticLabel',
  'label',
};

/// Named arguments that carry user-visible text only in these calls.
const Map<String, Set<String>> _calleeTextArguments = <String, Set<String>>{
  'Tooltip': <String>{'message'},
  'Tab': <String>{'text'},
  'TextSpan': <String>{'text'},
};

/// Calls whose positional string argument is shown as is.
const Set<String> _positionalText = <String>{'Text', 'SelectableText'};

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
        offenders.addAll(_scan(path, file.readAsStringSync()));
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

  group('the scan', () {
    List<String> scan(String source) => _scan('lib/ui/x.dart', source);

    final caught = <String, String>{
      'a Text literal': "child: const Text('Cancel'),",
      'a wrapped Text literal': 'child: Text(\n  "A long sentence here",\n),',
      'adjacent pieces': "Text('A long ' \n 'sentence'),",
      'SelectableText': "SelectableText('Copy me')",
      'a raw string': "Text(r'Raw words')",
      'a triple-quoted string': "Text('''Three\nlines''')",
      'a named argument first': "Text(key: k, 'After the key')",
      'a ternary': "Text(busy ? 'Saving' : 'Save')",
      'a ternary branch beside a comparison': "Text(k == 'dm' ? 'Chat' : t)",
      'tooltip': "IconButton(tooltip: 'Refresh', onPressed: null)",
      'hintText': "InputDecoration(hintText: 'Type here')",
      'labelText': "InputDecoration(labelText: 'Name')",
      'helperText': "InputDecoration(helperText: 'Help')",
      'errorText': "InputDecoration(errorText: 'Wrong')",
      'counterText': "InputDecoration(counterText: 'Left')",
      'prefixText': "InputDecoration(prefixText: 'From')",
      'suffixText': "InputDecoration(suffixText: 'Days')",
      'semanticsLabel': "Icon(i, semanticsLabel: 'Closed')",
      'semanticLabel': "Icon(i, semanticLabel: 'Closed')",
      'label': "NavigationDestination(icon: i, label: 'Chats')",
      'a wrapped label': 'Semantics(\n  label:\n      "Unread",\n  child: c)',
      'Tooltip message': "Tooltip(message: 'More', child: c)",
      'Tab text': "Tab(text: 'Users')",
      'TextSpan text': "TextSpan(text: 'Bold')",
      'words beside interpolation': r"Text('${n} messages')",
    };
    for (final entry in caught.entries) {
      test('catches ${entry.key}', () {
        expect(scan(entry.value), isNotEmpty, reason: entry.value);
      });
    }

    final ignored = <String, String>{
      'localized text': 'child: Text(context.l10n.commonCancel),',
      'interpolation only': r"Text('${a.name}: $count')",
      'nested interpolation': r"Text('${a ? 'x' : '${b}'}')",
      'a literal without a word': "Text('·')",
      'a line comment': "// child: Text('Cancel'),",
      'a block comment': "/* Text('Cancel') /* nested */ */",
      'a doc comment': "/// Shows `Text('Cancel')`.",
      'a string holding a trigger': "final s = \"Text('Cancel')\";",
      'a nested call': "Text(format('Not shown', x))",
      'a compared value': "Text(kind == 'dm' ? l10n.a : l10n.b)",
      'a key': "Text(l10n.title, key: const ValueKey('title'))",
      'message outside Tooltip': "SnackBar(message: 'Plain data')",
      'text outside Tab and TextSpan': "Foo(text: 'Data')",
    };
    for (final entry in ignored.entries) {
      test('ignores ${entry.key}', () {
        expect(scan(entry.value), isEmpty, reason: entry.value);
      });
    }

    test('reports the line of the literal and keeps URLs whole', () {
      expect(scan('a;\nb;\nText(\n  "Wrapped")'), <String>[
        'lib/ui/x.dart:4: Wrapped',
      ]);
      expect(scan("Text('A long '\n    'sentence')"),
          <String>['lib/ui/x.dart:1: A long sentence']);
      expect(scan("InputDecoration(hintText: 'https://a.example/x') // c"),
          <String>['lib/ui/x.dart:1: https://a.example/x']);
      expect(
          _scan('lib/features/auth/connect_screen.dart',
              "InputDecoration(hintText: 'https://chat.example.org')"),
          isEmpty);
    });
  });
}

/// Hard-coded user-facing literals in one file, as `path:line: text`.
List<String> _scan(String path, String source) {
  final lexed = _Lexer(source).run();
  final code = lexed.code;
  final offenders = <String>[];

  void report(int offset) {
    final literal = lexed.literals[offset];
    if (literal == null) return;
    // An operand of == or != is compared, not shown: `kind == 'dm' ? …`.
    final before = code.substring(0, offset).trimRight();
    final after = code.substring(literal.end).trimLeft();
    if (RegExp(r'[=!]=$').hasMatch(before) ||
        RegExp(r'^[=!]=').hasMatch(after)) {
      return;
    }
    if (!_word.hasMatch(literal.words)) return;
    if (_allowed.contains('$path: ${literal.text}')) return;
    final line = '\n'.allMatches(source.substring(0, offset)).length + 1;
    offenders.add('$path:$line: ${literal.text}');
  }

  final call = RegExp(r'([A-Za-z_$][\w$]*)\s*\(');
  for (final match in call.allMatches(code)) {
    final callee = match.group(1)!;
    final qualified = match.start > 0 && code[match.start - 1] == '.';
    final positional =
        !qualified && _positionalText.contains(callee) ? true : false;
    final names = <String>{
      ..._textArguments,
      ...?(qualified ? null : _calleeTextArguments[callee]),
    };
    for (final argument in _arguments(code, match.end)) {
      final name = argument.name;
      if (name == null ? !positional : !names.contains(name)) continue;
      for (final offset in _topLevelLiterals(code, argument)) {
        report(offset);
      }
    }
  }
  return offenders;
}

class _Argument {
  _Argument(this.name, this.start, this.end);
  final String? name;
  final int start;
  final int end;
}

final RegExp _namedArgument = RegExp(r'\s*([A-Za-z_$][\w$]*)\s*:(?!:)');

/// The arguments of the call whose `(` ends just before [start].
List<_Argument> _arguments(String code, int start) {
  final result = <_Argument>[];
  var depth = 0;
  var from = start;
  void add(int end) {
    final named = _namedArgument.matchAsPrefix(code, from);
    // `a ? b : c` is not a named argument: the name must open the argument.
    if (named != null) {
      result.add(_Argument(named.group(1), named.end, end));
    } else {
      result.add(_Argument(null, from, end));
    }
  }

  for (var i = start; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) {
        add(i);
        return result;
      }
      depth--;
    } else if (c == ',' && depth == 0) {
      add(i);
      from = i + 1;
    } else if (c == ';' && depth == 0) {
      return result; // Not a call after all.
    }
  }
  return result;
}

/// Offsets of the literals at the top level of [argument]: not inside a
/// nested call, list, map or function body.
Iterable<int> _topLevelLiterals(String code, _Argument argument) sync* {
  var depth = 0;
  for (var i = argument.start; i < argument.end; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (c == _literalMark && depth == 0) {
      yield i;
    }
  }
}

/// Marks where a literal starts in the blanked code.
const String _literalMark = '\u0001';

class _Literal {
  _Literal(this.start, this.end, this.text, this.words);
  final int start;
  final int end;

  /// The literal as written, without quotes or prefix.
  final String text;

  /// Its literal text only: interpolations and escapes become spaces.
  final String words;
}

class _Lexed {
  _Lexed(this.code, this.literals);

  /// The source with comments and string literals blanked (same length, so
  /// offsets still match); a literal's first character is [_literalMark].
  final String code;

  /// Literals by start offset; adjacent pieces are merged into the first.
  final Map<int, _Literal> literals;
}

/// Splits Dart source into code and string literals. It knows quotes,
/// triple quotes, raw strings, escapes, interpolation (with nested strings
/// and braces), line comments and nested block comments.
class _Lexer {
  _Lexer(this.source) : code = source.codeUnits.toList();

  final String source;
  final List<int> code;
  final List<_Literal> pieces = <_Literal>[];

  _Lexed run() {
    _code(0, record: true);
    final literals = <int, _Literal>{};
    _Literal? head;
    for (final piece in pieces) {
      final between = head == null
          ? null
          : String.fromCharCodes(code, head.end, piece.start);
      if (head != null && between!.trim().isEmpty) {
        head = _Literal(head.start, piece.end, head.text + piece.text,
            '${head.words}${piece.words}');
        code[piece.start] = 0x20;
      } else {
        head = piece;
      }
      literals[head.start] = head;
    }
    return _Lexed(String.fromCharCodes(code), literals);
  }

  void _blank(int from, int to) {
    for (var i = from; i < to; i++) {
      if (code[i] != 0x0a) code[i] = 0x20;
    }
  }

  static bool _identifier(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      c == 0x5f ||
      c == 0x24;

  bool _quote(int i) =>
      i < source.length && (source[i] == "'" || source[i] == '"');

  /// Code from [start] up to a `}` that closes an interpolation (when
  /// [interpolation]) or the end. Returns the offset after it.
  int _code(int start, {required bool record, bool interpolation = false}) {
    var i = start;
    var depth = 0;
    while (i < source.length) {
      final c = source[i];
      if (source.startsWith('//', i)) {
        final newline = source.indexOf('\n', i);
        final end = newline < 0 ? source.length : newline;
        _blank(i, end);
        i = end;
      } else if (source.startsWith('/*', i)) {
        var nesting = 0;
        var j = i;
        do {
          if (source.startsWith('/*', j)) {
            nesting++;
            j += 2;
          } else if (source.startsWith('*/', j)) {
            nesting--;
            j += 2;
          } else {
            j++;
          }
        } while (nesting > 0 && j < source.length);
        _blank(i, j);
        i = j;
      } else if (_quote(i) ||
          (c == 'r' &&
              _quote(i + 1) &&
              (i == 0 || !_identifier(source.codeUnitAt(i - 1))))) {
        i = _string(i, record: record);
      } else if (c == '{') {
        depth++;
        i++;
      } else if (c == '}') {
        if (interpolation && depth == 0) return i + 1;
        depth--;
        i++;
      } else {
        i++;
      }
    }
    return i;
  }

  /// The string literal whose prefix or opening quote is at [start].
  int _string(int start, {required bool record}) {
    var i = start;
    final raw = source[i] == 'r';
    if (raw) i++;
    final quote = source[i];
    final close = source.startsWith(quote * 3, i) ? quote * 3 : quote;
    i += close.length;
    final contentStart = i;
    var contentEnd = source.length;
    final words = StringBuffer();
    while (i < source.length) {
      if (source.startsWith(close, i)) {
        contentEnd = i;
        i += close.length;
        break;
      }
      final c = source[i];
      if (close.length == 1 && c == '\n') {
        contentEnd = i; // Unterminated; stop at the line end.
        break;
      }
      if (!raw && c == r'\') {
        words.write(' ');
        i += 2;
      } else if (!raw && source.startsWith(r'${', i)) {
        words.write(' ');
        i = _code(i + 2, record: false, interpolation: true);
      } else if (!raw &&
          c == r'$' &&
          i + 1 < source.length &&
          _identifier(source.codeUnitAt(i + 1))) {
        words.write(' ');
        i++;
        while (i < source.length && _identifier(source.codeUnitAt(i))) {
          i++;
        }
      } else {
        words.write(c);
        i++;
      }
    }
    final end = i > source.length ? source.length : i;
    _blank(start, end);
    if (record) {
      code[start] = _literalMark.codeUnitAt(0);
      pieces.add(_Literal(
          start,
          end,
          source.substring(contentStart, contentEnd.clamp(contentStart, end)),
          '$words'));
    }
    return end;
  }
}
