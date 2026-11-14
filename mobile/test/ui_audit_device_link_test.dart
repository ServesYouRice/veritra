// U3 and U22 (UI audit 2026-11-14): linking a device in three steps.
//
// The existing device shows scan, compare, done; at the compare step the
// warning "never use a code you were sent or read" stands whole above eight
// code boxes, at 360 dp and at text scale 2.0, and the code itself is never
// shown there. The new device shows the same steps, with the code to compare
// as the largest thing on its screen. The native checks behind the code are
// covered with the real engine in device_link_v3_flow_test.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/auth/connect_screen.dart';
import 'package:private_messenger/features/settings/device_link_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/theme.dart';

import 'test_crypto_service.dart';

const _warning = 'Never use a code someone sent you or read out to you. '
    "Type only the code you see yourself on the new device's screen.";

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

void _view(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

AppState _signedIn() => AppState(
      apiClientFactory: (url) => ApiClient(baseUrl: url),
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _QuietSync(),
    )..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'acct_0123456789abcdef',
        deviceId: 'dev_current',
        username: 'alice',
        role: 'member',
      );

String _stepLabel(WidgetTester tester) => tester
    .getSemantics(find.byKey(const ValueKey<String>('device-link-steps')))
    .label;

void main() {
  group('existing device', () {
    for (final scale in <double>[1.0, 2.0]) {
      testWidgets(
          'U3: the warning shows whole above eight boxes at 360 dp, '
          'scale $scale', (tester) async {
        // Tall enough that the list builds every row.
        _view(tester, const Size(360, 2400));
        final handle = tester.ensureSemantics();
        final state = _signedIn()
          ..activeDeviceLink = DeviceLinkV3View(
            id: 'dl_1',
            state: 'claimed',
            verificationCode: '24681357',
            claimedDeviceName: 'Linked pixel',
            expiresAt: DateTime.utc(2030),
          );
        await tester
            .pumpWidget(_app(DeviceLinkScreen(state: state), textScale: scale));
        await tester.pump();
        expect(tester.takeException(), isNull);

        final warning = find.text(_warning);
        expect(warning, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(warning);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(tester.widget<Text>(warning).maxLines, isNull);
        final warningBox = tester
            .getRect(find.byKey(const ValueKey<String>('device-link-warning')));
        expect(warningBox.right, lessThanOrEqualTo(360));

        final field = tester.getRect(
            find.byKey(const ValueKey<String>('device-link-code-field')));
        expect(warningBox.bottom, lessThanOrEqualTo(field.top),
            reason: 'the warning is read before the code is typed');

        for (var i = 0; i < deviceLinkCodeLength; i++) {
          final box = tester
              .getRect(find.byKey(ValueKey<String>('device-link-code-box-$i')));
          expect(box.right, lessThanOrEqualTo(360));
          expect(box.center.dy, closeTo(field.center.dy, 1));
        }
        expect(find.byKey(const ValueKey<String>('device-link-code-box-8')),
            findsNothing);

        // This device never shows the code it is about to check.
        expect(find.textContaining('2468'), findsNothing);
        expect(_stepLabel(tester), 'Step 2 of 3: Compare');
        handle.dispose();
      });
    }

    testWidgets('U3: typed digits fill the boxes in order', (tester) async {
      _view(tester, const Size(360, 2400));
      final state = _signedIn()
        ..activeDeviceLink = DeviceLinkV3View(
          id: 'dl_1',
          state: 'claimed',
          verificationCode: '24681357',
          expiresAt: DateTime.utc(2030),
        );
      await tester.pumpWidget(_app(DeviceLinkScreen(state: state)));
      await tester.enterText(
          find.byKey(const ValueKey<String>('device-link-code-field')), '123');
      await tester.pump();
      String boxText(int i) => tester
          .widget<Text>(find.descendant(
              of: find.byKey(ValueKey<String>('device-link-code-box-$i')),
              matching: find.byType(Text)))
          .data!;
      expect(<String>[for (var i = 0; i < 8; i++) boxText(i)],
          <String>['1', '2', '3', '', '', '', '', '']);
    });

    testWidgets('U22: before a link, step 1 offers to create one',
        (tester) async {
      _view(tester, const Size(360, 800));
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(DeviceLinkScreen(state: _signedIn())));
      expect(_stepLabel(tester), 'Step 1 of 3: Scan');
      expect(find.text('Create link'), findsOneWidget);
      expect(find.text('Scan'), findsOneWidget);
      expect(find.text('Compare'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('U22: a link this device cannot show any more has ended',
        (tester) async {
      _view(tester, const Size(360, 800));
      // No secret is held, so there is no QR and no typed code to show.
      final state = _signedIn()
        ..activeDeviceLink = DeviceLinkV3View(
          id: 'dl_1',
          state: 'pending',
          expiresAt: DateTime.utc(2030),
        );
      await tester.pumpWidget(_app(DeviceLinkScreen(state: state)));
      expect(find.byKey(const ValueKey<String>('device-link-ended')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('device-link-cannot-scan')),
          findsNothing);
      expect(find.text('Create new link'), findsOneWidget);
    });

    testWidgets('U22: an approved link shows done', (tester) async {
      _view(tester, const Size(360, 800));
      final handle = tester.ensureSemantics();
      final state = _signedIn()
        ..activeDeviceLink = DeviceLinkV3View(
          id: 'dl_1',
          state: 'approved',
          expiresAt: DateTime.utc(2030),
        );
      await tester.pumpWidget(_app(DeviceLinkScreen(state: state)));
      expect(find.byKey(const ValueKey<String>('device-link-done')),
          findsOneWidget);
      expect(_stepLabel(tester), 'Step 3 of 3: Done');
      handle.dispose();
    });

    testWidgets('U22: the screen checks a waiting link by itself',
        (tester) async {
      _view(tester, const Size(360, 800));
      // A link without its secret is never polled: there is nothing a
      // claim could be checked against.
      final state = _CountingState()
        ..activeDeviceLink = DeviceLinkV3View(
          id: 'dl_1',
          state: 'pending',
          expiresAt: DateTime.utc(2030),
        );
      await tester.pumpWidget(_app(DeviceLinkScreen(state: state)));
      await tester.pump(deviceLinkStatusPollInterval * 3);
      expect(tester.takeException(), isNull);
      expect(state.errorFor(Ops.deviceLink), isNull);
      // Leaving stops the timer (a pending timer fails the test).
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('new device', () {
    Future<_LinkingState> openLinkMode(WidgetTester tester,
        {required String code, double textScale = 1.0}) async {
      _view(tester, const Size(360, 2400));
      final state = _LinkingState()
        ..pendingDeviceLinkClaim = DeviceLinkClaimView(
          state: 'claimed',
          verificationCode: code,
          expiresAt: DateTime.utc(2030),
        );
      addTearDown(state.dispose);
      await tester
          .pumpWidget(_app(ConnectScreen(state: state), textScale: textScale));
      // A claim already waiting takes the connect screen straight to the
      // link step (U20), past the welcome choices.
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey<String>('welcome-account')), findsNothing);
      return state;
    }

    for (final scale in <double>[1.0, 2.0]) {
      testWidgets(
          'U22: the code to compare is the largest thing on the screen '
          '(scale $scale)', (tester) async {
        final handle = tester.ensureSemantics();
        await openLinkMode(tester, code: '24681357', textScale: scale);
        expect(tester.takeException(), isNull);
        expect(_stepLabel(tester), 'Step 2 of 3: Compare');
        final halves = <Finder>[
          find.byKey(const ValueKey<String>('connect-link-code-0')),
          find.byKey(const ValueKey<String>('connect-link-code-1')),
        ];
        expect(<String>[
          for (final half in halves) tester.widget<Text>(half).data!
        ], <String>[
          '2468',
          '1357'
        ]);
        for (final half in halves) {
          expect(tester.getRect(half).right, lessThanOrEqualTo(360));
        }
        // The painted size of the largest letter: the font size, the text
        // scale, and any scaling on the way (a FittedBox).
        double paintedFontSize(Element element) {
          final widget = element.widget as RichText;
          final paragraph = element.renderObject! as RenderParagraph;
          var largest = 0.0;
          widget.text.visitChildren((span) {
            final size = span.style?.fontSize ?? 0;
            if (size > largest) largest = size;
            return true;
          });
          final rect = MatrixUtils.transformRect(
              paragraph.getTransformTo(null), Offset.zero & paragraph.size);
          return widget.textScaler.scale(largest) *
              rect.height /
              paragraph.size.height;
        }

        final codeElements = <Element>[
          for (final half in halves)
            find
                .descendant(of: half, matching: find.byType(RichText))
                .evaluate()
                .single,
        ];
        final codeSize =
            codeElements.map(paintedFontSize).reduce((a, b) => a < b ? a : b);
        for (final element in find.byType(RichText).evaluate()) {
          final paragraph = element.renderObject! as RenderParagraph;
          if (codeElements.contains(element) ||
              !paragraph.hasSize ||
              paragraph.size.isEmpty) {
            continue;
          }
          expect(paintedFontSize(element), lessThan(codeSize),
              reason: '${(element.widget as RichText).text.toPlainText()} '
                  'is as large as the code');
        }
        // The link code has done its work; it is not asked for again.
        expect(find.text('LINK CODE'), findsNothing);
        handle.dispose();
      });
    }

    testWidgets('U22: before the code arrives the step is still scan',
        (tester) async {
      final handle = tester.ensureSemantics();
      await openLinkMode(tester, code: '');
      expect(_stepLabel(tester), 'Step 1 of 3: Scan');
      expect(find.byKey(const ValueKey<String>('connect-link-code-display')),
          findsNothing);
      expect(find.textContaining('The code to confirm appears here'),
          findsOneWidget);
      handle.dispose();
    });
  });
}

/// A signed-in state that counts link refreshes.
class _CountingState extends AppState {
  _CountingState()
      : super(
          apiClientFactory: (url) => ApiClient(baseUrl: url),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _QuietSync(),
        );
}

/// A signed-out device on a reachable server it has not linked to.
class _LinkingState extends AppState {
  _LinkingState()
      : super(
          apiClientFactory: (url) => ApiClient(baseUrl: url),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  @override
  Future<SetupProbeResult> probeSetup(String baseUrl) async =>
      const SetupProbeResult(
          state: SetupProbeState.reachable, setupRequired: false);

  @override
  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async => false;

  @override
  Future<bool> hasStoredDeviceIdentity() async => false;
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
