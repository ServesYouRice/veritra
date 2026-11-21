// U38: what one entry of the screen-photograph catalogue is.
//
// An entry names the Dart class it photographs ([className]), which the guard
// test (screen_catalog_guard_test.dart) checks against lib/features, and says
// how to reach it:
//   * [PhotoScreen.shell]   through the app shell, as a person would
//                           (the same screens as the goldens);
//   * [PhotoScreen.direct]  by mounting the widget as the home of a
//                           MaterialApp, with fixtures built by [build];
//   * [PhotoScreen.skipped] not built at all, with the reason.
// Several entries may name one class (a state of the same screen).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';

/// What a [PhotoScreen.build] gets: the tester, and a place to register
/// things the harness must dispose after the photograph.
class PhotoEnv {
  PhotoEnv(this.tester);

  final WidgetTester tester;
  final List<Listenable> listenables = <Listenable>[];

  /// The state [PhotoScreen.build] made, for [PhotoScreen.open] to use.
  AppState? state;

  /// Disposes [value] after the test, and returns it.
  T own<T extends ChangeNotifier>(T value) {
    addTearDown(value.dispose);
    return value;
  }

  /// Waits [ms] of real time (a screen doing real I/O or image decoding),
  /// then pumps once.
  Future<void> realTime([int ms = 100]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump();
  }
}

typedef PhotoBuild = Future<Widget> Function(PhotoEnv env);
typedef PhotoOpen = Future<void> Function(WidgetTester tester, PhotoEnv env);

class PhotoScreen {
  /// Reached through the app shell. [connected] picks the signed-in fixture
  /// of the goldens or the connect screen.
  const PhotoScreen.shell(
    this.name,
    this.className, {
    required bool this.connected,
    this.open,
  })  : build = null,
        skipReason = null;

  /// Mounted by itself. [open] runs after the first frame (to tap a button
  /// or show a dialog).
  const PhotoScreen.direct(
    this.name,
    this.className,
    PhotoBuild this.build, {
    this.open,
  })  : connected = null,
        skipReason = null;

  /// Not photographed. [reason] says why, and what covers it instead.
  const PhotoScreen.skipped(this.name, this.className, String this.skipReason)
      : connected = null,
        build = null,
        open = null;

  /// The file name stem of the photograph.
  final String name;

  /// The exact Dart class (or dialog or sheet widget) this entry shows.
  final String className;
  final bool? connected;
  final PhotoBuild? build;
  final PhotoOpen? open;
  final String? skipReason;

  bool get isSkipped => skipReason != null;
}

/// The widget [tester] sees as the context for showing a dialog or sheet.
BuildContext photoContext(WidgetTester tester) =>
    tester.element(find.byType(Navigator).first);
