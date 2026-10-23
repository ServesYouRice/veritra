// T43C responsive, text-scale and reduced-motion checks on the same screens
// the goldens cover. These run on every platform: a RenderFlex overflow or
// any other layout error during build, navigation or scrolling fails the
// test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/features/chat/chat_screen.dart';
import 'package:private_messenger/ui/app_shell.dart';

import 'goldens/golden_harness.dart';

typedef _Open = Future<void> Function(WidgetTester tester);

Future<void> _openChat(WidgetTester tester) async {
  await tester.tap(find.text('@alice'));
  await tester.pumpAndSettle();
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await tester.pumpAndSettle();
}

/// Drags every vertical list on screen to its end so lazily built rows are
/// laid out too, not just the first screenful.
Future<void> _scrollThrough(WidgetTester tester) async {
  final lists = find.byWidgetPredicate((widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down);
  final count = lists.evaluate().length;
  for (var i = 0; i < count; i++) {
    for (var step = 0; step < 6; step++) {
      await tester.drag(lists.at(i), const Offset(0, -400),
          warnIfMissed: false);
      await tester.pump();
    }
  }
  await tester.pumpAndSettle();
}

class _Viewport {
  const _Viewport(this.name, this.size, this.textScale);

  final String name;
  final Size size;
  final double textScale;
}

const _viewports = <_Viewport>[
  _Viewport('320 px', narrowPhoneSize, 1.0),
  _Viewport('320 px at 200% text', narrowPhoneSize, 2.0),
  _Viewport('phone at 200% text', phoneSize, 2.0),
  _Viewport('landscape phone', landscapePhoneSize, 1.0),
  _Viewport('landscape phone at 200% text', landscapePhoneSize, 2.0),
  _Viewport('tablet', tabletSize, 1.0),
  _Viewport('tablet at 200% text', tabletSize, 2.0),
  _Viewport('desktop at 200% text', wideSize, 2.0),
];

final _screens = <String, ({bool connected, _Open? open})>{
  'connect': (connected: false, open: null),
  'chat list': (connected: true, open: null),
  'chat': (connected: true, open: _openChat),
  'settings': (connected: true, open: _openSettings),
};

void main() {
  for (final viewport in _viewports) {
    group(viewport.name, () {
      for (final screen in _screens.entries) {
        testWidgets('${screen.key} lays out without overflow', (tester) async {
          setWindowSize(tester, viewport.size);
          final AppState state = screen.value.connected
              ? await connectedState()
              : disconnectedState();
          await tester.pumpWidget(veritraTestApp(
            state: state,
            textScale: viewport.textScale,
          ));
          await tester.pumpAndSettle();
          await screen.value.open?.call(tester);
          await _scrollThrough(tester);

          expect(tester.takeException(), isNull);
        });
      }
    });
  }

  testWidgets('the compact nav keeps destination names in semantics at 320 px',
      (tester) async {
    final semantics = tester.ensureSemantics();
    setWindowSize(tester, narrowPhoneSize);
    await tester.pumpWidget(veritraTestApp(state: await connectedState()));
    await tester.pumpAndSettle();

    expect(shellLayoutFor(narrowPhoneSize.width), ShellLayout.compact);
    for (final label in <String>['Chats', 'Communities', 'Settings']) {
      expect(find.bySemanticsLabel(label), findsWidgets);
    }
    // The floating nav once filled the whole screen and covered the list.
    expect(find.text('@alice').hitTestable(), findsOneWidget);
    semantics.dispose();
  });

  group('reduced motion', () {
    Future<double> chatLeftEdgeOneFrameAfterOpening(
      WidgetTester tester, {
      required bool disableAnimations,
    }) async {
      setWindowSize(tester, phoneSize);
      await tester.pumpWidget(veritraTestApp(
        state: await connectedState(),
        disableAnimations: disableAnimations,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('@alice'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final left = tester.getTopLeft(find.byType(ChatScreen)).dx;
      await tester.pumpAndSettle();
      return left;
    }

    testWidgets('opening a chat slides in by default', (tester) async {
      final left = await chatLeftEdgeOneFrameAfterOpening(tester,
          disableAnimations: false);
      expect(left, greaterThan(0));
    });

    testWidgets('opening a chat does not move when animations are off',
        (tester) async {
      final left = await chatLeftEdgeOneFrameAfterOpening(tester,
          disableAnimations: true);
      expect(left, 0);
    });
  });
}
