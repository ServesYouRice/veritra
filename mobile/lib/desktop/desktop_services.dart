import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

import '../core/app_state.dart';
import '../l10n/l10n.dart';
import '../ui/about.dart';
import '../storage/profile_scope.dart';
import 'desktop_shell.dart';
import 'message_notifications.dart';
import 'update_service.dart';

/// The desktop shell features (W3, W4) wired together: tray, closing to the
/// tray, one window, notifications, and update checks (W12). Absent on Android
/// and iOS.
class DesktopServices {
  DesktopServices({
    required this.state,
    required this.shell,
    required this.notifier,
    required this.settings,
    required this.updateSettings,
    required this.updateService,
  });

  final AppState state;
  final DesktopShell shell;
  final DesktopNotifier notifier;
  final NotificationSettings settings;
  final UpdateSettings updateSettings;
  final UpdateService updateService;
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
  static Future<DesktopServices?> startIfSupported(AppState state,
      {ProfileScope scope = const ProfileScope()}) async {
    if (!desktopShellSupported) return null;
    try {
      final shell = PluginDesktopShell();
      final strings = deviceL10n();
      await shell.start(
        openLabel: strings.trayOpen,
        quitLabel: strings.trayQuit,
        tooltip: veritraProductName,
      );
      final settings =
          NotificationSettings(SecureNotificationSettingsStore(scope: scope));
      unawaited(settings.load());
      final updateSettings =
          UpdateSettings(SecureUpdateSettingsStore(scope: scope));
      await updateSettings.load();
      final updateService = UpdateService(
        settings: updateSettings,
        currentBuild: veritraBuildNumber,
      );
      if (updateSettings.autoCheckEnabled) {
        unawaited(updateService.checkForUpdatesIfEnabled());
      }
      return DesktopServices(
        state: state,
        shell: shell,
        notifier: PluginDesktopNotifier(
          appName: veritraProductName,
          onClick: () => unawaited(shell.showWindow()),
        ),
        settings: settings,
        updateSettings: updateSettings,
        updateService: updateService,
      );
    } catch (_) {
      return null;
    }
  }

  void attach() => _messages.attach();

  Future<void> detach() async {
    _messages.detach();
    if (notifier case final PluginDesktopNotifier plugin) await plugin.clear();
    await shell.dispose();
    settings.dispose();
    updateSettings.dispose();
    updateService.dispose();
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

/// Offers the notification settings and update service to the settings screen
/// when running on desktop.
Widget wrapDesktopScope(DesktopServices? desktop, Widget child) {
  if (desktop == null) return child;
  return NotificationSettingsScope(
    settings: desktop.settings,
    child: UpdateSettingsScope(
      settings: desktop.updateSettings,
      service: desktop.updateService,
      child: child,
    ),
  );
}
