// U10: no text under 12 logical pixels on the screens the goldens cover.
//
// The golden PNGs are not touched. This renders the same fixture widget trees
// in a normal widget test and reads the font size of every painted text.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/ui/tokens.dart';

import 'goldens/golden_harness.dart';

const double _minFontSize = 12;

/// Collects `(text, size)` for every run in [span]; a run without its own
/// size inherits the parent's.
void _collect(InlineSpan span, double inherited, List<(String, double)> out) {
  if (span is! TextSpan) return;
  final size = span.style?.fontSize ?? inherited;
  final text = span.text;
  if (text != null && text.trim().isNotEmpty) out.add((text, size));
  for (final child in span.children ?? const <InlineSpan>[]) {
    _collect(child, size, out);
  }
}

List<(String, double)> _paintedText(WidgetTester tester) {
  final out = <(String, double)>[];
  void visit(RenderObject node) {
    if (node is RenderParagraph) {
      _collect(node.text, 14, out);
    } else if (node is RenderEditable) {
      _collect(node.text!, 14, out);
    }
    node.visitChildren(visit);
  }

  visit(tester.binding.renderViews.first);
  return out;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

final _screens =
    <String, ({bool connected, Future<void> Function(WidgetTester)? open})>{
  'connect': (connected: false, open: null),
  'chat list': (connected: true, open: null),
  'chat': (
    connected: true,
    open: (tester) => _tap(tester, find.text('@alice')),
  ),
  'settings': (
    connected: true,
    open: (tester) => _tap(tester, find.byIcon(Icons.settings_outlined)),
  ),
};

void main() {
  test('every BoneType style is at least 12', () {
    for (final style in <TextStyle>[
      BoneType.display,
      BoneType.title,
      BoneType.body,
      BoneType.label,
      BoneType.caption,
      BoneType.micro,
      BoneType.mono,
    ]) {
      expect(style.fontSize, greaterThanOrEqualTo(_minFontSize));
    }
    expect(BoneType.body.fontSize, 16);
    expect(BoneType.label.fontSize, 16);
    expect(BoneType.caption.fontSize, 13.5);
    expect(BoneType.micro.fontSize, 12.5);
  });

  for (final screen in _screens.entries) {
    for (final theme in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      testWidgets('${screen.key} (${theme.name}) has no text under 12', (
        tester,
      ) async {
        setWindowSize(tester, phoneSize);
        final AppState state = screen.value.connected
            ? await connectedState()
            : disconnectedState();
        await tester.pumpWidget(
          veritraTestApp(
            state: state,
            themeMode: theme,
            disableAnimations: true,
          ),
        );
        await tester.pumpAndSettle();
        await screen.value.open?.call(tester);

        final texts = _paintedText(tester);
        expect(texts, isNotEmpty);
        final small = texts.where((t) => t.$2 < _minFontSize).toList();
        expect(small, isEmpty, reason: 'text under $_minFontSize: $small');
      });
    }
  }
}
