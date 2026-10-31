// The selected NavigationBar destination must be legible: the indicator is
// the accent colour, so the selected icon cannot keep the default
// secondary-container colour (TASK-091).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/tokens.dart';

void main() {
  const selected = <WidgetState>{WidgetState.selected};
  const unselected = <WidgetState>{};

  for (final entry in <String, ThemeData>{
    'light': veritraLightTheme(),
    'dark': veritraDarkTheme(),
  }.entries) {
    final theme = entry.value;
    final bar = theme.navigationBarTheme;
    final indicator = bar.indicatorColor!;

    test('${entry.key}: the selected icon clears 3:1 on the indicator', () {
      final icon = bar.iconTheme?.resolve(selected)?.color;
      expect(icon, isNotNull,
          reason: 'without an iconTheme Material applies onSecondaryContainer');
      expect(contrastRatio(icon!, indicator), greaterThanOrEqualTo(3));
    });

    test('${entry.key}: the selected label differs from the others', () {
      final on = bar.labelTextStyle!.resolve(selected)!;
      final off = bar.labelTextStyle!.resolve(unselected)!;
      expect(on, isNot(off));
      // Stronger, not just another colour: it stands out from the muted rest.
      final background = bar.backgroundColor!;
      expect(contrastRatio(on.color!, background),
          greaterThan(contrastRatio(off.color!, background)));
    });

    test('${entry.key}: the unselected look keeps the muted label', () {
      final off = bar.labelTextStyle!.resolve(unselected)!;
      final muted = theme.textTheme.labelSmall!;
      expect(off.color, muted.color);
      expect(off.fontSize, muted.fontSize);
      expect(off.fontWeight, muted.fontWeight);
      expect(off.letterSpacing, muted.letterSpacing);
    });

    test('${entry.key}: the labels stay readable on the bar', () {
      for (final states in <Set<WidgetState>>[selected, unselected]) {
        final label = bar.labelTextStyle!.resolve(states)!.color!;
        expect(contrastRatio(label, bar.backgroundColor!),
            greaterThanOrEqualTo(4.5),
            reason: '${entry.key} $states');
      }
    });
  }
}
