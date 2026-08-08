import 'package:flutter/material.dart';

import 'tokens.dart';

/// Navigation motion for the app (`docs/design.md` §10).
///
/// Every route in the app was a default `MaterialPageRoute`, which on Android
/// is a bottom-up slide — a sheet gesture used for a lateral move. This is a
/// shared-axis X transition instead: the incoming screen enters from the
/// trailing edge while the outgoing one steps back, which is what "forward
/// along this axis" reads as.
///
/// Written by hand rather than taken from `package:animations`. It is one
/// `PageRouteBuilder`, and a dependency would need a license review and a
/// `THIRD_PARTY_NOTICES.md` entry (`AGENTS.md`) to save it.
Route<T> sharedAxisRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    transitionDuration: BoneDurations.standard,
    reverseTransitionDuration: BoneDurations.standard,
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // Users who have asked the platform for reduced motion get the route
      // change with no transition at all, not a faster one.
      if (MediaQuery.disableAnimationsOf(context)) {
        return child;
      }
      final curve = CurveTween(curve: BoneDurations.curve);
      // CurveTween.animate rather than CurvedAnimation: it needs no disposal,
      // and a transitionsBuilder runs on every frame of the transition.
      final incoming = Tween<Offset>(
        begin: const Offset(0.06, 0),
        end: Offset.zero,
      ).chain(curve).animate(animation);
      final outgoing = Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.04, 0),
      ).chain(curve).animate(secondaryAnimation);
      return SlideTransition(
        position: incoming,
        child: FadeTransition(
          opacity: curve.animate(animation),
          child: SlideTransition(position: outgoing, child: child),
        ),
      );
    },
  );
}

/// Hero tag for a conversation's avatar on its list → detail flight.
///
/// **Only safe on the narrow layout.** In the wide master-detail workspace the
/// embedded chat list and the open conversation are on the *same* route, so
/// two widgets would carry this tag at once and Flutter asserts. Callers pass
/// it only when they are a pushed route — see the `heroTag` arguments in
/// `chat_list_screen.dart` and `chat_screen.dart`.
String conversationAvatarHeroTag(String conversationId) =>
    'conversation-avatar-$conversationId';
