import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// What the desktop window needs from the platform: a tray icon, closing to
/// the tray, and whether the window is in front. Behind an interface so tests
/// can fake it and Android and iOS never touch the desktop plugins.
abstract class DesktopShell {
  /// Sets up the tray icon and makes closing the window hide it. [openLabel],
  /// [quitLabel] and [tooltip] are the localized tray texts.
  Future<void> start({
    required String openLabel,
    required String quitLabel,
    required String tooltip,
  });

  /// True while the window is visible, not minimized and has focus.
  Future<bool> isWindowActive();

  Future<void> showWindow();

  /// Really exits the app, unlike closing the window.
  Future<void> quit();

  Future<void> dispose();
}

/// A shell with no window of its own: Android, iOS and tests.
class NoopDesktopShell implements DesktopShell {
  const NoopDesktopShell();

  @override
  Future<void> start({
    required String openLabel,
    required String quitLabel,
    required String tooltip,
  }) async {}

  @override
  Future<bool> isWindowActive() async => true;

  @override
  Future<void> showWindow() async {}

  @override
  Future<void> quit() async {}

  @override
  Future<void> dispose() async {}
}

bool get desktopShellSupported =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// The real shell, on `window_manager` and `tray_manager`.
class PluginDesktopShell
    with WindowListener, TrayListener
    implements DesktopShell {
  static const _openKey = 'open';
  static const _quitKey = 'quit';

  bool _quitting = false;

  @override
  Future<void> start({
    required String openLabel,
    required String quitLabel,
    required String tooltip,
  }) async {
    try {
      await windowManager.ensureInitialized();
      // The tray comes first: closing the window only hides it, which is safe
      // only while there is a tray icon to bring it back. If any step fails
      // the window must keep its normal close.
      await trayManager.setIcon(
        Platform.isWindows
            ? 'assets/tray/veritra.ico'
            : 'assets/tray/veritra.png',
      );
      if (!Platform.isLinux) await trayManager.setToolTip(tooltip);
      await trayManager.setContextMenu(Menu(items: <MenuItem>[
        MenuItem(key: _openKey, label: openLabel),
        MenuItem.separator(),
        MenuItem(key: _quitKey, label: quitLabel),
      ]));
      trayManager.addListener(this);
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
    } catch (_) {
      await _undoStart();
      rethrow;
    }
  }

  /// Puts the window back to its normal close after a failed [start]. Every
  /// step is tried on its own, so one that fails does not skip the rest, and
  /// none of them replaces the error being reported.
  Future<void> _undoStart() async {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {}
  }

  @override
  Future<bool> isWindowActive() async {
    return await windowManager.isVisible() &&
        !await windowManager.isMinimized() &&
        await windowManager.isFocused();
  }

  @override
  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> quit() async {
    _quitting = true;
    await trayManager.destroy();
    await windowManager.destroy();
  }

  @override
  Future<void> dispose() async {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
  }

  // Closing the window keeps the app (and sync) running in the tray.
  @override
  void onWindowClose() {
    if (_quitting) return;
    unawaited(windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() => unawaited(showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _openKey:
        unawaited(showWindow());
      case _quitKey:
        unawaited(quit());
    }
  }
}

/// Raises a system notification. Text is passed in already built on this
/// device; nothing here talks to the network.
abstract class DesktopNotifier {
  Future<void> show({required String title, required String body});
}

class NoopDesktopNotifier implements DesktopNotifier {
  const NoopDesktopNotifier();

  @override
  Future<void> show({required String title, required String body}) async {}
}

/// Windows toasts and the Linux and macOS equivalents, on `local_notifier`.
class PluginDesktopNotifier implements DesktopNotifier {
  PluginDesktopNotifier({required this.appName, this.onClick});

  final String appName;

  /// Called when the person clicks a notification.
  final void Function()? onClick;

  bool _ready = false;

  Future<void> _setup() async {
    if (_ready) return;
    await localNotifier.setup(
      appName: appName,
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
    _ready = true;
  }

  @override
  Future<void> show({required String title, required String body}) async {
    try {
      await _setup();
      final notification = LocalNotification(title: title, body: body);
      notification.onClick = onClick;
      await notification.show();
    } catch (_) {
      // A notification that cannot be shown is dropped; never log its text.
    }
  }
}
