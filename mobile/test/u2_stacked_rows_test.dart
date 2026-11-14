// U2: at large text a row with a trailing control puts the control under the
// text, so the title is never laid out narrower than 120 dp.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/link_preview_service.dart';
import 'package:private_messenger/features/settings/link_preview_tile.dart';
import 'package:private_messenger/l10n/app_localizations.dart';

Widget _app(double scale) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: LinkPreviewTile(
        mode: LinkPreviewMode.allowListed,
        onChanged: (_) {},
      ),
    ),
  ),
);

void main() {
  const sizes = <Size>[
    Size(320, 640),
    Size(360, 800),
    Size(800, 360),
    Size(820, 1180),
  ];
  for (final size in sizes) {
    testWidgets('Link previews title stays 120 dp wide at 200% on $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(2.0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final title = tester.getSize(find.text('Link previews'));
      expect(title.width, greaterThanOrEqualTo(120));
      // The control is still there, under or beside the text.
      expect(find.byKey(const Key('link-preview-mode')), findsOneWidget);
    });
  }

  testWidgets('at normal text the control stays beside the text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(820, 1180);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(1.0));
    await tester.pumpAndSettle();
    final title = tester.getTopRight(find.text('Link previews'));
    final control = tester.getTopLeft(
      find.byKey(const Key('link-preview-mode')),
    );
    // Beside the text, not under it.
    expect(control.dx, greaterThan(title.dx));
  });
}
