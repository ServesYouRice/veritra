// U8 (UI audit 2026-11-14): phone-width fixes on the screens this card
// owns. The QR-scanner permission page keeps its text inside the page and
// offers "Open settings"; the safety number is a fixed four-by-three grid; a
// long title fits its bar; a field error wraps to two lines.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:private_messenger/features/auth/qr_scan_screen.dart';
import 'package:private_messenger/features/chat/safety_number_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/widgets/large_title_bar.dart';

Widget _app(Widget home, {double textScale = 1.0}) => MaterialApp(
      theme: veritraLightTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

void _phone(WidgetTester tester, {Size size = const Size(360, 800)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('QR scanner without the camera', () {
    for (final scale in <double>[1.0, 2.0]) {
      testWidgets('permission text stays inside the page at scale $scale',
          (tester) async {
        _phone(tester);
        var opened = 0;
        await tester.pumpWidget(_app(
          Scaffold(
            body: QrScannerError(
              error: const MobileScannerException(
                  errorCode: MobileScannerErrorCode.permissionDenied),
              openSettings: () async {
                opened++;
                return true;
              },
            ),
          ),
          textScale: scale,
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final message = tester
            .getRect(find.byKey(const ValueKey<String>('qr-error-message')));
        expect(message.left, greaterThanOrEqualTo(0));
        expect(message.right, lessThanOrEqualTo(360));

        final settings = find.byKey(const ValueKey<String>('qr-open-settings'));
        await tester.scrollUntilVisible(settings, 100);
        expect(find.text('Open settings'), findsOneWidget);
        await tester.tap(settings);
        await tester.pump();
        expect(opened, 1);
        expect(find.text('Enter code manually'), findsOneWidget);
      });
    }

    testWidgets('settings that cannot open say where to go', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(Scaffold(
        body: QrScannerError(
          error: const MobileScannerException(
              errorCode: MobileScannerErrorCode.permissionDenied),
          openSettings: () async => false,
        ),
      )));
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Allow the camera for Veritra'), findsOneWidget);
    });

    testWidgets('other camera failures offer no settings', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(const Scaffold(
        body: QrScannerError(
          error: MobileScannerException(
              errorCode: MobileScannerErrorCode.unsupported),
        ),
      )));
      expect(find.text('Open settings'), findsNothing);
      expect(find.text('Enter code manually'), findsOneWidget);
    });
  });

  group('safety number grid', () {
    for (final (width, scale) in <(double, double)>[
      (320, 1.0),
      (360, 1.0),
      (360, 2.0),
    ]) {
      testWidgets('is four groups by three rows at $width dp, scale $scale',
          (tester) async {
        _phone(tester, size: Size(width, 800));
        await tester.pumpWidget(_app(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(32),
              child: SafetyDigitsGrid(digits: '0123456789' * 6),
            ),
          ),
          textScale: scale,
        ));
        expect(tester.takeException(), isNull);
        Rect cell(int i) =>
            tester.getRect(find.byKey(ValueKey<String>('safety-group-$i')));
        for (var row = 0; row < 3; row++) {
          final first = cell(row * 4);
          for (var column = 1; column < 4; column++) {
            final next = cell(row * 4 + column);
            expect(next.center.dy, closeTo(first.center.dy, 0.5),
                reason: 'group ${row * 4 + column} is on row $row');
            expect(next.left,
                greaterThanOrEqualTo(cell(row * 4 + column - 1).right + 4));
          }
          if (row > 0) {
            expect(first.top, greaterThan(cell((row - 1) * 4).bottom - 0.5));
          }
        }
        expect(find.byKey(const ValueKey<String>('safety-group-12')),
            findsNothing);
        expect(cell(3).right, lessThanOrEqualTo(width));
      });
    }
  });

  testWidgets('a long title fits its bar at 360 dp', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(Navigator(
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: SizedBox()),
      ),
    )));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(
        appBar: LargeTitleBar(title: 'Invitations and join requests'),
      ),
    ));
    await tester.pumpAndSettle();
    final title = find.text('Invitations and join requests');
    expect(title, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(title);
    expect(paragraph.didExceedMaxLines, isFalse);
    // The whole title is painted inside the bar, after the back button.
    final box = tester
        .getRect(find.ancestor(of: title, matching: find.byType(FittedBox)));
    expect(box.right, lessThanOrEqualTo(360));
    expect(box.left, greaterThanOrEqualTo(48));
  });

  testWidgets('a field error wraps to a second line', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const Scaffold(
      body: Padding(
        padding: EdgeInsets.all(16),
        child: TextField(
          decoration: InputDecoration(
            errorText: 'Use the server address only, like '
                'https://chat.example.org, without a path or a port.',
          ),
        ),
      ),
    )));
    final error = find.textContaining('Use the server address only');
    expect(tester.widget<Text>(error).maxLines, 2);
  });
}
