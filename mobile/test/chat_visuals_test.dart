import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/features/chat/sender_colors.dart';
import 'package:private_messenger/l10n/l10n.dart';
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

  group('avatar colours', () {
    // The twelve fills and their initials colours, as the evidence file lists
    // them (UI audit 2026-11-14, D131). Changing one means redoing its checks.
    const dark = <String, (int, int)>{
      'Olive': (0xff8d9d0a, 0xff16111f),
      'Teal': (0xff0e9a94, 0xff16111f),
      'Iris': (0xff465dbb, 0xffffffff),
      'Lilac': (0xffa878db, 0xff16111f),
      'Plum': (0xff94457d, 0xffffffff),
      'Ochre': (0xffa35e16, 0xffffffff),
    };
    const light = <String, (int, int)>{
      'Olive': (0xff90a013, 0xff16111f),
      'Teal': (0xff16aba4, 0xff16111f),
      'Iris': (0xff8ca6fb, 0xff16111f),
      'Lilac': (0xff9868ca, 0xff16111f),
      'Plum': (0xffe882c8, 0xff16111f),
      'Ochre': (0xffe2a16b, 0xff16111f),
    };

    test('the six hues are the ones the evidence file names, in order', () {
      expect(avatarHues.map((hue) => hue.name), <String>[
        'Olive',
        'Teal',
        'Iris',
        'Lilac',
        'Plum',
        'Ochre',
      ]);
    });

    test('the twelve fills and initials colours are pinned', () {
      for (final hue in avatarHues) {
        expect(hue.darkFill.toARGB32(), dark[hue.name]!.$1, reason: hue.name);
        expect(
          hue.darkInitials.toARGB32(),
          dark[hue.name]!.$2,
          reason: hue.name,
        );
        expect(hue.lightFill.toARGB32(), light[hue.name]!.$1, reason: hue.name);
        expect(
          hue.lightInitials.toARGB32(),
          light[hue.name]!.$2,
          reason: hue.name,
        );
      }
    });

    test('initials clear 4.5:1 on every fill', () {
      for (final hue in avatarHues) {
        expect(
          contrastRatio(hue.darkInitials, hue.darkFill),
          greaterThanOrEqualTo(4.5),
          reason: '${hue.name} dark',
        );
        expect(
          contrastRatio(hue.lightInitials, hue.lightFill),
          greaterThanOrEqualTo(4.5),
          reason: '${hue.name} light',
        );
      }
    });

    test('no fill sits near a state colour of its theme', () {
      // Euclidean in OKLab x 100. The evidence file measured 17 or more in
      // dark and 16 or more in light against verified, warning, error, info.
      void check(
        List<Color> fills,
        List<Color> states,
        double floor,
        String theme,
      ) {
        for (final fill in fills) {
          for (final state in states) {
            expect(
              _oklabDistance(fill, state),
              greaterThanOrEqualTo(floor),
              reason: '$theme ${fill.toARGB32().toRadixString(16)} vs '
                  '${state.toARGB32().toRadixString(16)}',
            );
          }
        }
      }

      check(
        <Color>[for (final hue in avatarHues) hue.darkFill],
        <Color>[
          VeritraStateColors.dark.verified,
          VeritraStateColors.dark.warning,
          VeritraStateColors.dark.info,
          BoneColors.darkError,
        ],
        17,
        'dark',
      );
      check(
        <Color>[for (final hue in avatarHues) hue.lightFill],
        <Color>[
          VeritraStateColors.light.verified,
          VeritraStateColors.light.warning,
          VeritraStateColors.light.info,
          BoneColors.lightError,
        ],
        16,
        'light',
      );
    });

    test('no two fills of a theme sit close together', () {
      for (final fills in <List<Color>>[
        <Color>[for (final hue in avatarHues) hue.darkFill],
        <Color>[for (final hue in avatarHues) hue.lightFill],
      ]) {
        for (var i = 0; i < fills.length; i++) {
          for (var j = i + 1; j < fills.length; j++) {
            expect(
              _oklabDistance(fills[i], fills[j]),
              greaterThanOrEqualTo(15),
              reason: '$i vs $j',
            );
          }
        }
      }
    });

    test('a seed maps to a fixed hue, not a per-run one', () {
      // Pinned so a switch to String.hashCode is caught: Dart seeds string
      // hashing per process, which would re-colour every contact on launch.
      expect(avatarHueFor('acct_alice').name, 'Ochre');
      expect(avatarHueFor('acct_bob').name, 'Iris');
      expect(avatarHueFor('conv_1').name, 'Teal');
      expect(avatarHueFor('conv_2').name, 'Olive');
    });

    test('hues spread across all six slots', () {
      final seen = <String>{};
      for (var i = 0; i < 500; i++) {
        seen.add(avatarHueFor('acct_$i').name);
      }
      expect(seen, hasLength(avatarHues.length));
    });

    test('a name gives up to two initials, and nothing gives none', () {
      expect(nameInitials('Family'), 'F');
      expect(nameInitials('book club'), 'BC');
      expect(nameInitials('  ·· Ana  Maria Lopez'), 'AM');
      expect(nameInitials('Жика'), 'Ж');
      expect(nameInitials('🙂'), isNull);
      expect(nameInitials(''), isNull);
      expect(nameInitials(null), isNull);
    });
  });

  group('retention labels', () {
    test('the chip is the compact form of the spoken label', () {
      // Same unit as the spoken label in both cases: the chip is what is
      // seen and the label is what is announced, and a chip reading `24h`
      // beside a label reading "1 day" is one fact told two ways.
      expect(retentionChipLabel(englishL10n, 86400), '1d');
      expect(retentionLabel(englishL10n, 86400), '1 day');
      expect(retentionChipLabel(englishL10n, 604800), '7d');
      expect(retentionLabel(englishL10n, 604800), '7 days');
      expect(retentionChipLabel(englishL10n, 3600), '1h');
      expect(retentionLabel(englishL10n, 3600), '1 hour');
      expect(retentionChipLabel(englishL10n, 1800), '30m');
      expect(retentionLabel(englishL10n, 1800), '30 minutes');
    });
  });

  group('own bubble tint (U14)', () {
    test('text on your own bubble clears 4.5:1 in both themes', () {
      for (final theme in <ThemeData>[
        veritraLightTheme(),
        veritraDarkTheme(),
      ]) {
        final scheme = theme.colorScheme;
        final own = BoneColors.ownBubble(theme.brightness);
        // Body text, muted text (meta line, reply preview, placeholders) and
        // the accent used by links and mentions all read on the fill.
        expect(contrastRatio(scheme.onSurface, own), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(scheme.onSurfaceVariant, own),
            greaterThanOrEqualTo(4.5));
        expect(contrastRatio(scheme.primary, own), greaterThanOrEqualTo(4.5));
        // The read tick is a glyph, so 3:1.
        expect(contrastRatio(scheme.primary, own), greaterThanOrEqualTo(3));
      }
    });

    test('the tint is not the surface tone of their bubbles', () {
      for (final theme in <ThemeData>[
        veritraLightTheme(),
        veritraDarkTheme(),
      ]) {
        expect(BoneColors.ownBubble(theme.brightness),
            isNot(theme.colorScheme.surfaceContainerLow));
        expect(BoneColors.ownBubble(theme.brightness),
            isNot(theme.colorScheme.surfaceContainerHigh));
      }
    });
  });

  group('sender name colours (U36)', () {
    test('every colour reads as text on its theme, 4.5:1 or better', () {
      for (final theme in <ThemeData>[
        veritraLightTheme(),
        veritraDarkTheme(),
      ]) {
        final scheme = theme.colorScheme;
        final palette = theme.brightness == Brightness.dark
            ? senderNameColorsDark
            : senderNameColorsLight;
        expect(palette, hasLength(6));
        for (final color in palette) {
          // Their bubble, the canvas and the highlight of a jumped-to row.
          for (final surface in <Color>[
            scheme.surfaceContainerLow,
            scheme.surface,
            compositeColor(scheme.primary.withValues(alpha: 0.14),
                scheme.surfaceContainerLow),
          ]) {
            expect(contrastRatio(color, surface), greaterThanOrEqualTo(4.5),
                reason: '$color on $surface');
          }
        }
        expect(palette.toSet(), hasLength(6));
      }
    });

    test('an account keeps its colour, and the slots spread', () {
      expect(senderColorSlot('acct_alice'), senderColorSlot('acct_alice'));
      final slots = <int>{
        for (var i = 0; i < 300; i++) senderColorSlot('acct_$i'),
      };
      expect(slots, hasLength(6));
      expect(senderNameColor('acct_alice', Brightness.dark),
          isNot(senderNameColor('acct_alice', Brightness.light)));
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

/// Euclidean distance between two sRGB colours in OKLab, times 100 (the
/// measure the avatar palette was computed with).
double _oklabDistance(Color a, Color b) {
  final (l1, a1, b1) = _oklab(a);
  final (l2, a2, b2) = _oklab(b);
  final dl = l1 - l2, da = a1 - a2, db = b1 - b2;
  return 100 * math.sqrt(dl * dl + da * da + db * db);
}

(double, double, double) _oklab(Color color) {
  double linear(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  final r = linear(color.r), g = linear(color.g), bl = linear(color.b);
  final l = math
      .pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl, 1 / 3)
      .toDouble();
  final m = math
      .pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl, 1 / 3)
      .toDouble();
  final s = math
      .pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl, 1 / 3)
      .toDouble();
  return (
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  );
}
