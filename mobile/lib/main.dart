import 'dart:async';

import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/api_client.dart';
import 'core/receipts_state.dart';
import 'crypto/crypto_service.dart';
import 'desktop/desktop_services.dart';
import 'l10n/app_localizations.dart';
import 'push/push_service.dart';
import 'push/wake_worker_bridge.dart';
import 'push/wake_launch_coordinator.dart';
import 'storage/local_store.dart';
import 'sync/sync_service.dart';
import 'ui/about.dart';
import 'ui/app_shell.dart';
import 'ui/appearance.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = PlatformWakeWorkerBridge();
  final launch = WakeLaunchCoordinator(
    bridge: bridge,
    profile: 'release', // Fixed alias for the existing empty store namespace.
    onUi: () async {
      final state = AppState(
        apiClientFactory: (baseUrl) => ApiClient(baseUrl: baseUrl),
        cryptoService: UnavailableCryptoService(),
        localStore: SecureLocalStore(),
        syncServiceFactory: (baseUrl, token) =>
            WebSocketSyncService(baseUrl: baseUrl, token: token),
        pushService: PlatformMobilePushService(),
        receiptPreferences: ReceiptPreferences(SecureReceiptPreferenceStore()),
      );
      // Restore is represented by an explicit startup state while the app shell
      // remains mounted; failures enter recovery instead of flashing logout or
      // resetting the durable cursor.
      final desktop = await DesktopServices.startIfSupported(state);
      runApp(VeritraApp(state: state, desktop: desktop));
      unawaited(state.tryRestoreSession());
    },
    // Unavailable production crypto never installs a background worker or
    // constructs protected storage on a cold wake. Actual UI may start later.
    onUiError: () => runApp(const StartupFailureApp()),
  );
  await launch.start();
}

/// A sanitized startup failure; no platform diagnostic, path or secret appears.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
            builder: (context) => Scaffold(
                    body: Center(
                  child: Text(AppLocalizations.of(context)!.errorGeneric),
                ))),
      );
}

class VeritraApp extends StatefulWidget {
  const VeritraApp({
    required this.state,
    this.appearance,
    this.desktop,
    super.key,
  });

  final AppState state;

  /// The System/Light/Dark choice. Defaults to one kept in the keystore.
  final AppearanceController? appearance;

  /// Tray, one window and notifications on desktop; null elsewhere.
  final DesktopServices? desktop;

  @override
  State<VeritraApp> createState() => _VeritraAppState();
}

class _VeritraAppState extends State<VeritraApp> with WidgetsBindingObserver {
  late final AppearanceController _appearance =
      widget.appearance ?? AppearanceController(SecureAppearanceStore());

  @override
  void initState() {
    super.initState();
    unawaited(_appearance.load());
    widget.desktop?.attach();
    WidgetsBinding.instance.addObserver(this);
    widget.state.handleAppLifecycleState(
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.state.handleAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.desktop?.detach();
    if (widget.appearance == null) _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Only the appearance rebuilds the root. AppState changes are heard by
    // the shell and by each screen for the parts it shows (T49C-1), so a
    // notification no longer rebuilds the Navigator and every route.
    return ListenableBuilder(
      listenable: _appearance,
      builder: (context, _) {
        return wrapDesktopScope(
            widget.desktop,
            AppearanceScope(
              controller: _appearance,
              child: MaterialApp(
                title: veritraProductName,
                theme: veritraLightTheme(),
                darkTheme: veritraDarkTheme(),
                themeMode: _appearance.mode,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: AppShell(state: widget.state),
              ),
            ));
      },
    );
  }
}
