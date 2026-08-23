import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/ui/avatar.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/tokens.dart';

/// Pure-function contracts behind the K2 · Bone chat surfaces. Nothing here
/// pumps a widget: these are the properties that are easy to break in a later
/// "cleanup" and expensive to notice by eye.
void main() {
  group('redacted bar widths', () {
    test('two messages in the same bucket are indistinguishable', () {
      // The whole point of bucketing. If this ever fails, message length has
      // become readable over the user's shoulder.
      expect(redactedBarFractions(129), redactedBarFractions(224));
      expect(redactedBarFractions(225), redactedBarFractions(384));
      expect(redactedBarFractions(641), redactedBarFractions(20000));
    });

    test('the whole length range collapses to six shapes', () {
      final shapes = <String>{};
      for (var length = 0; length <= 5000; length++) {
        shapes.add(redactedBarFractions(length).join(','));
      }
      // Six, not 5001: the mapping is bucketed, not linear.
      expect(shapes, hasLength(6));
    });

    test('no message renders more than three lines', () {
      for (var length = 0; length <= 5000; length += 7) {
        expect(redactedBarFractions(length).length, lessThanOrEqualTo(3));
      }
    });

    test('a longer message never renders narrower', () {
      double total(int length) =>
          redactedBarFractions(length).reduce((a, b) => a + b);
      var previous = total(0);
      for (var length = 0; length <= 5000; length += 13) {
        final current = total(length);
        expect(current, greaterThanOrEqualTo(previous));
        previous = current;
      }
    });

    test('every fraction stays inside the bubble', () {
      for (var length = 0; length <= 5000; length += 11) {
        for (final fraction in redactedBarFractions(length)) {
          expect(fraction, greaterThan(0));
          expect(fraction, lessThanOrEqualTo(1));
        }
      }
    });
  });

  group('avatar tints', () {
    test('the five temperatures are the ones directions.md §K names', () {
      expect(
        boneTints.map((tint) => tint.name),
        <String>['Chalk', 'Bone', 'Greige', 'Ash', 'Steel'],
      );
    });

    test('a seed maps to a fixed temperature, not a per-run one', () {
      // Pinned so a switch to String.hashCode is caught: Dart seeds string
      // hashing per process, which would re-colour every contact on launch.
      expect(boneTintFor('acct_alice').name, 'Bone');
      expect(boneTintFor('acct_bob').name, 'Ash');
      expect(boneTintFor('conv_1').name, 'Chalk');
      expect(boneTintFor('conv_2').name, 'Steel');
    });

    test('tints spread across all five temperatures', () {
      final seen = <String>{};
      for (var i = 0; i < 500; i++) {
        seen.add(boneTintFor('acct_$i').name);
      }
      expect(seen, hasLength(boneTints.length));
    });
  });

  group('retention labels', () {
    test('the chip is the compact form of the spoken label', () {
      // Same unit as the spoken label in both cases: the chip is what is
      // seen and the label is what is announced, and a chip reading `24h`
      // beside a label reading "1 day" is one fact told two ways.
      expect(retentionChipLabel(86400), '1d');
      expect(retentionLabel(86400), '1 day');
      expect(retentionChipLabel(604800), '7d');
      expect(retentionLabel(604800), '7 days');
      expect(retentionChipLabel(3600), '1h');
      expect(retentionLabel(3600), '1 hour');
      expect(retentionChipLabel(1800), '30m');
      expect(retentionLabel(1800), '30 minutes');
    });
  });

  group('non-text control contrast', () {
    test('opaque and composited boundaries clear 3:1 in both palettes', () {
      for (final theme in <ThemeData>[
        veritraLightTheme(),
        veritraDarkTheme(),
      ]) {
        final scheme = theme.colorScheme;
        final surfaces = <Color>[
          scheme.surface,
          scheme.surfaceContainerLowest,
          scheme.surfaceContainerLow,
          scheme.surfaceContainer,
          scheme.surfaceContainerHigh,
          scheme.surfaceContainerHighest,
        ];

        for (final surface in surfaces) {
          expect(
            contrastRatio(scheme.outline, surface),
            greaterThanOrEqualTo(3),
          );
          expect(
            contrastRatio(
              compositeColor(scheme.outlineVariant, surface),
              surface,
            ),
            greaterThanOrEqualTo(3),
          );
        }

        // Focused and error controls use opaque state borders. The
        // errorContainer border on ConnectionBanner is a decorative status
        // boundary, not a control-identifying edge, so it is intentionally
        // outside this outlineVariant contract.
        expect(
          contrastRatio(scheme.primary, scheme.surfaceContainer),
          greaterThanOrEqualTo(3),
        );
        expect(
          contrastRatio(scheme.error, scheme.errorContainer),
          greaterThanOrEqualTo(3),
        );
      }
    });
  });
}
