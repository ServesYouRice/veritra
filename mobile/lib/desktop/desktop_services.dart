import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import '../core/app_state.dart';
import '../l10n/l10n.dart';
import '../ui/about.dart';
import 'desktop_shell.dart';
import 'message_notifications.dart';

/// The desktop shell features (W3, W4) wired together: tray, closing to the
/// tray, one window, and notifications for messages that arrive while the
/// window is not in front. Absent on Android and iOS.
class DesktopServices {
  DesktopServices({
    required this.state,
    required this.shell,
    required this.notifier,
    required this.settings,
  });

  final AppState state;
  final DesktopShell shell;
  final DesktopNotifier notifier;
  final NotificationSettings settings;
  late final MessageNotifier _messages = MessageNotifier(
    state: state,
    shell: shell,
    notifier: notifier,
    settings: settings,
    l10n: deviceL10n,
  );

  /// Starts the real shell on Windows, Linux and macOS. Returns null on
  /// other platforms and when the shell cannot start, so the app still runs
  /// as a normal window.
  static Future<DesktopServices?> startIfSupported(AppState state) async {
    if (!desktopShellSupported) return null;
    try {
      final shell = PluginDesktopShell();
      final strings = deviceL10n();
      await shell.start(
        openLabel: strings.trayOpen,
        quitLabel: strings.trayQuit,
        tooltip: veritraProductName,
      );
      final settings = NotificationSettings(SecureNotificationSettingsStore());
      unawaited(settings.load());
      return DesktopServices(
        state: state,
        shell: shell,
        notifier: PluginDesktopNotifier(
          appName: veritraProductName,
          onClick: () => unawaited(shell.showWindow()),
        ),
        settings: settings,
      );
    } catch (_) {
      return null;
    }
  }

  void attach() => _messages.attach();

  void detach() {
    _messages.detach();
    unawaited(shell.dispose());
  }
}

/// The strings for the device language, for texts built outside the widget
/// tree (the tray menu, notifications).
AppLocalizations deviceL10n() {
  final locale = PlatformDispatcher.instance.locale;
  if (AppLocalizations.supportedLocales.contains(locale)) {
    return lookupAppLocalizations(locale);
  }
  for (final supported in AppLocalizations.supportedLocales) {
    if (supported.languageCode == locale.languageCode) {
      return lookupAppLocalizations(supported);
    }
  }
  return englishL10n;
}

/// Offers the notification settings to the settings screen when running on
/// desktop.
Widget wrapDesktopScope(DesktopServices? desktop, Widget child) {
  if (desktop == null) return child;
  return NotificationSettingsScope(settings: desktop.settings, child: child);
}
