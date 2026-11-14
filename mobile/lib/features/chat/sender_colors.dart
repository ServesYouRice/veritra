import 'package:flutter/material.dart';

/// The colour of a sender's name above their bubble in a group (U36).
///
/// Six hues, one per person, picked from the account ID. They are the six
/// hues of the avatar palette (Olive, Teal, Iris, Lilac, Plum, Ochre, in that
/// order), set at a lightness where each reads as text: 6:1 or better on the
/// bubble and the canvas of its theme, where the avatar fills only reach 3:1.
/// The colour is a hint to tell voices apart; the name carries the identity,
/// and a look-alike account matches one time in six.
///
/// Dark values are measured on `#211A2D` and `#16111F`, light values on
/// `#FFFFFF` and `#F8F6F1`; `chat_visuals_test.dart` pins the ratios.
const List<Color> senderNameColorsDark = <Color>[
  Color(0xffabbc4a), // Olive
  Color(0xff0dcbc3), // Teal
  Color(0xff93adfe), // Iris
  Color(0xffc699f8), // Lilac
  Color(0xffeb8ccd), // Plum
  Color(0xfff19a4b), // Ochre
];

/// The same six hues for the light theme, darker so they read on paper.
const List<Color> senderNameColorsLight = <Color>[
  Color(0xff576207), // Olive
  Color(0xff056965), // Teal
  Color(0xff3d52a8), // Iris
  Color(0xff6e4199), // Lilac
  Color(0xff8b3473), // Plum
  Color(0xff864900), // Ochre
];

/// Which of the six colours [accountId] gets. FNV-1a, 32-bit, as the avatar
/// colours use: stable between launches, unlike `String.hashCode`.
int senderColorSlot(String accountId) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < accountId.length; i++) {
    hash ^= accountId.codeUnitAt(i) & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % senderNameColorsDark.length;
}

/// The name colour of [accountId] for [brightness].
Color senderNameColor(String accountId, Brightness brightness) {
  final palette = brightness == Brightness.dark
      ? senderNameColorsDark
      : senderNameColorsLight;
  return palette[senderColorSlot(accountId)];
}
