// U38 screen photographs on demand: a test-only harness, off by default.
//
// Renders every screen listed below at 360 x 800 dp, in dark and light, with
// the real Roboto and Material Icons fonts, and writes per state
//   <out>/<screen>_<theme>.png   the picture
//   <out>/<screen>_<theme>.json  the measurements
// The JSON holds every text run (size, weight, colour, painted background,
// contrast ratio), every tappable semantics node (size, label), and the
// result of Flutter's androidTapTargetGuideline and
// labeledTapTargetGuideline.
//
// Run (from mobile/, Linux, Flutter on PATH):
//   SCREEN_PHOTOS=1 TZ=UTC flutter test test/screen_photos
//   (or flutter test --dart-define=SCREEN_PHOTOS=1 test/screen_photos)
// Long screens get one photograph per viewport (_v2, _v3, ...).
// Optional: SCREEN_PHOTOS_OUT=<dir> (default build/screen_photos),
//           SCREEN_PHOTOS_SCALE=2.0 (text scale, default 1.0; the output
//           names get a "_x2.0" suffix).
// Without the opt-in the file registers one skipped test and does nothing
// else, so the normal suite pays nothing. The output goes under build/ and
// is never compared with anything. To add a screen, append to [_screens]
// and reuse the fixtures in ../goldens/golden_harness.dart.
// See testing/evidence/UI-audit-2026-11-14.md (Method) for what the audit
// measured.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/ui/app_shell.dart';
import 'package:private_messenger/ui/appearance.dart';
import 'package:private_messenger/ui/theme.dart';

import '../goldens/golden_harness.dart';

const _dartDefine = String.fromEnvironment('SCREEN_PHOTOS');

bool get _enabled {
  final v = _dartDefine.isNotEmpty
      ? _dartDefine
      : Platform.environment['SCREEN_PHOTOS'] ?? '';
  return v.isNotEmpty && v != '0';
}

class _Screen {
  const _Screen(this.name, {required this.connected, this.open});
  final String name;
  final bool connected;
  final Future<void> Function(WidgetTester tester)? open;
}

// Same screens, reached the same way, as the goldens.
final _screens = <_Screen>[
  _Screen('chat_details', connected: true, open: (tester) async {
    await tester.tap(find.text('@alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conversation details'));
  }),
  for (final row in <String>[
    'Change password',
    'Export account data',
    'Delete account',
    'Link a new device',
  ])
    _Screen('settings_${row.toLowerCase().replaceAll(' ', '_')}',
        connected: true, open: (tester) async {
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text(row));
    }),
  const _Screen('connect', connected: false),
  const _Screen('chats', connected: true),
  _Screen(
    'chat',
    connected: true,
    open: (tester) async {
      await tester.tap(find.text('@alice'));
    },
  ),
  _Screen(
    'settings',
    connected: true,
    open: (tester) async {
      await tester.tap(find.byIcon(Icons.settings_outlined));
    },
  ),
];

const _themes = <String, ThemeMode>{
  'light': ThemeMode.light,
  'dark': ThemeMode.dark,
};

/// Real Roboto and Material Icons from the Flutter SDK (the pattern of
/// ui_audit_communities_test.dart). False when the files are missing.
Future<bool> _loadRealFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return false;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> read(String name) async =>
      ByteData.sublistView(File('$dir/$name').readAsBytesSync());
  final names = <String>[
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'MaterialIcons-Regular.otf',
  ];
  if (!names.every((n) => File('$dir/$n').existsSync())) return false;
  final roboto = FontLoader('Roboto');
  for (final n in names.take(3)) {
    roboto.addFont(read(n));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(read(names[3]));
  await icons.load();
  return true;
}

double _lin(double c) =>
    c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b);

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

/// The nearest opaque colour painted behind [node]; [fallback] when none.
Color _backgroundOf(RenderObject node, Color fallback) {
  for (RenderObject? p = node.parent; p != null; p = p.parent) {
    Color? c;
    if (p is RenderPhysicalModel) c = p.color;
    if (p is RenderPhysicalShape) c = p.color;
    if (p is RenderDecoratedBox) {
      final d = p.decoration;
      if (d is BoxDecoration) c = d.color;
    }
    if (c != null && c.a > 0.99) return c;
  }
  return fallback;
}

double _round1(double v) => double.parse(v.toStringAsFixed(1));

List<Map<String, Object?>> _textRuns(WidgetTester tester, Color fallback) {
  final runs = <Map<String, Object?>>[];
  void visit(RenderObject node) {
    if (node is RenderParagraph) {
      final text = node.text.toPlainText(includePlaceholders: false);
      final style = node.text.style;
      final color = style?.color;
      // Icon glyphs are private-use characters, not text.
      final isIcon = (style?.fontFamily ?? '').contains('MaterialIcons');
      if (text.trim().isNotEmpty && color != null && !isIcon) {
        final bg = _backgroundOf(node, fallback);
        final shown = Color.alphaBlend(color, bg);
        runs.add(<String, Object?>{
          'text': text,
          'size': style?.fontSize,
          'effectiveSize': style?.fontSize == null
              ? null
              : _round1(node.textScaler.scale(style!.fontSize!)),
          'weight': style?.fontWeight?.value,
          'family': style?.fontFamily,
          'color': _hex(shown),
          'background': _hex(bg),
          'contrast': double.parse(_contrast(shown, bg).toStringAsFixed(2)),
          'width': _round1(node.size.width),
          'height': _round1(node.size.height),
        });
      }
    }
    node.visitChildren(visit);
  }

  visit(tester.binding.renderViews.first);
  return runs;
}

Matrix4 _toRoot(SemanticsNode node) {
  final m = Matrix4.identity();
  final chain = <SemanticsNode>[];
  for (SemanticsNode? n = node; n != null; n = n.parent) {
    chain.add(n);
  }
  for (final n in chain.reversed) {
    final t = n.transform;
    if (t != null) m.multiply(t);
  }
  return m;
}

List<Map<String, Object?>> _tapTargets(WidgetTester tester) {
  final out = <Map<String, Object?>>[];
  final root =
      tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  if (root == null) return out;
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.hasAction(SemanticsAction.tap) ||
        data.hasAction(SemanticsAction.longPress)) {
      final rect = MatrixUtils.transformRect(_toRoot(node), node.rect);
      out.add(<String, Object?>{
        'label': data.label.isNotEmpty ? data.label : data.tooltip,
        'width': _round1(rect.width),
        'height': _round1(rect.height),
        'left': _round1(rect.left),
        'top': _round1(rect.top),
      });
    }
    node.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(root);
  return out;
}

Future<void> _writePng(WidgetTester tester, File file) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  if (!_enabled) {
    test(
      'screen photographs (opt in with SCREEN_PHOTOS=1)',
      () {},
      skip: 'off by default; see the comment block at the top of this file',
    );
    return;
  }

  final outDir = Directory(
    Platform.environment['SCREEN_PHOTOS_OUT'] ?? 'build/screen_photos',
  );
  final scale =
      double.tryParse(Platform.environment['SCREEN_PHOTOS_SCALE'] ?? '') ?? 1.0;
  final suffix = scale == 1.0 ? '' : '_x$scale';
  var realFonts = false;

  setUpAll(() async {
    outDir.createSync(recursive: true);
    realFonts = await _loadRealFonts();
    if (!realFonts) {
      stdout.writeln(
        'screen photos: real fonts not found '
        '(FLUTTER_ROOT unset?); text is drawn in the test font.',
      );
    }
  });

  for (final screen in _screens) {
    for (final theme in _themes.entries) {
      final name = '${screen.name}_${theme.key}$suffix';
      testWidgets('photograph $name', (tester) async {
        setWindowSize(tester, phoneSize);
        final semantics = tester.ensureSemantics();
        // Real shadows: widget tests switch them off by default.
        debugDisableShadows = false;
        final AppState state =
            screen.connected ? await connectedState() : disconnectedState();
        addTearDown(state.dispose);
        await tester.pumpWidget(
          RepaintBoundary(
            child: _photoApp(
              state: state,
              themeMode: theme.value,
              textScale: scale,
              disableAnimations: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (screen.open != null) {
          await screen.open!(tester);
          await _settle(tester);
        }

        // One photograph per viewport: the first scrollable is dragged by
        // 90% of the window until it stops moving (at most 8 viewports).
        for (var view = 1; view <= 8; view++) {
          final viewName = view == 1 ? name : '${name}_v$view';
          await _capture(tester, outDir, viewName, screen.name, theme.key,
              scale, realFonts, view);
          final scrollable = find.byType(Scrollable);
          if (scrollable.evaluate().isEmpty) break;
          // A dialog or menu is open: its page behind must not scroll.
          if (find.byType(ModalBarrier).evaluate().length > 1) break;
          final position =
              tester.state<ScrollableState>(scrollable.first).position;
          if (position.pixels >= position.maxScrollExtent - 1) break;
          position.jumpTo(
            math.min(position.pixels + phoneSize.height * 0.9,
                position.maxScrollExtent),
          );
          await _settle(tester);
        }
        debugDisableShadows = true;
        semantics.dispose();
      });
    }
  }
}

Future<void> _capture(
  WidgetTester tester,
  Directory outDir,
  String name,
  String screen,
  String theme,
  double scale,
  bool realFonts,
  int viewport,
) async {
  final context = tester.element(find.byType(Scaffold).first);
  final fallback = Theme.of(context).colorScheme.surface;
  final android = await androidTapTargetGuideline.evaluate(tester);
  final labeled = await labeledTapTargetGuideline.evaluate(tester);
  final runs = _textRuns(tester, fallback);
  final targets = _tapTargets(tester);
  await _writePng(tester, File('${outDir.path}/$name.png'));
  File('${outDir.path}/$name.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'screen': screen,
      'theme': theme,
      'viewport': viewport,
      'window': '${phoneSize.width.toInt()}x${phoneSize.height.toInt()}',
      'textScale': scale,
      'realFonts': realFonts,
      'textRuns': runs,
      'tapTargets': targets,
      'guidelines': <String, Object?>{
        'androidTapTarget': <String, Object?>{
          'passed': android.passed,
          'reason': android.reason,
        },
        'labeledTapTarget': <String, Object?>{
          'passed': labeled.passed,
          'reason': labeled.reason,
        },
      },
    }),
  );
  expect(runs, isNotEmpty);
}

/// Settles, but accepts screens with a looping animation (a spinner).
Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
  } on FlutterError {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Like [veritraTestApp], but the themes name Roboto outright. A real phone
/// resolves a style with no family to Roboto; the test binding draws it in
/// its square-glyph font, which turned list and dialog titles into blocks.
Widget _photoApp({
  required AppState state,
  required ThemeMode themeMode,
  required double textScale,
  required bool disableAnimations,
}) {
  TextStyle? f(TextStyle? s) => s?.copyWith(fontFamily: 'Roboto');
  WidgetStateProperty<TextStyle?>? fp(WidgetStateProperty<TextStyle?>? p) =>
      p == null
          ? null
          : WidgetStateProperty.resolveWith((s) => f(p.resolve(s)));
  ButtonStyle? bs(ButtonStyle? b) => b?.copyWith(textStyle: fp(b.textStyle));
  ThemeData roboto(ThemeData t) => t.copyWith(
        textTheme: t.textTheme.apply(fontFamily: 'Roboto'),
        primaryTextTheme: t.primaryTextTheme.apply(fontFamily: 'Roboto'),
        appBarTheme: t.appBarTheme.copyWith(
          titleTextStyle: f(t.appBarTheme.titleTextStyle),
        ),
        inputDecorationTheme: t.inputDecorationTheme.copyWith(
          hintStyle: f(t.inputDecorationTheme.hintStyle),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: bs(t.filledButtonTheme.style),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: bs(t.outlinedButtonTheme.style),
        ),
        textButtonTheme:
            TextButtonThemeData(style: bs(t.textButtonTheme.style)),
        chipTheme: t.chipTheme.copyWith(labelStyle: f(t.chipTheme.labelStyle)),
        snackBarTheme: t.snackBarTheme.copyWith(
          contentTextStyle: f(t.snackBarTheme.contentTextStyle),
        ),
        dialogTheme: t.dialogTheme.copyWith(
          titleTextStyle: f(t.dialogTheme.titleTextStyle),
          contentTextStyle: f(t.dialogTheme.contentTextStyle),
        ),
        navigationBarTheme: t.navigationBarTheme.copyWith(
          labelTextStyle: fp(t.navigationBarTheme.labelTextStyle),
        ),
        listTileTheme: t.listTileTheme.copyWith(
          titleTextStyle: f(t.listTileTheme.titleTextStyle),
          subtitleTextStyle: f(t.listTileTheme.subtitleTextStyle),
        ),
      );
  final appearance = AppearanceController(MemoryAppearanceStore(themeMode));
  appearance.load();
  return AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[state, appearance]),
    builder: (context, _) => AppearanceScope(
      controller: appearance,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: roboto(veritraLightTheme()),
        darkTheme: roboto(veritraDarkTheme()),
        themeMode: themeMode,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
            alwaysUse24HourFormat: true,
          ),
          child: child!,
        ),
        home: AppShell(state: state),
      ),
    ),
  );
}
