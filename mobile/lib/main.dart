import 'dart:async';

import 'package:flutter/material.dart';

import 'core/account_host.dart';
import 'core/app_state.dart';
import 'core/api_client.dart';
import 'core/passkeys.dart';
import 'core/receipts_state.dart';
import 'crypto/crypto_service.dart';
import 'desktop/desktop_services.dart';
import 'features/calls/call_host.dart';
import 'l10n/l10n.dart';
import 'push/push_service.dart';
import 'push/wake_worker_bridge.dart';
import 'push/wake_launch_coordinator.dart';
import 'features/chat/attachment_views.dart'
    show purgeOpenedAttachments, useOpenedFilesScope;
import 'features/chat/composer_attachments.dart'
    show purgePastedImages, usePastedImageProfile;
import 'storage/account_slots.dart';
import 'storage/local_store.dart';
import 'storage/profile_scope.dart';
import 'sync/sync_service.dart';
import 'ui/about.dart';
import 'ui/app_shell.dart';
import 'ui/appearance.dart';
import 'ui/theme.dart';

/// The release entry point's runtime for one account slot (B7). Every slot
/// holds [UnavailableCryptoService] and the release transport: no slot code
/// chooses a crypto service or a transport by itself.
Future<AccountRuntime> buildReleaseRuntime(String namespace) async {
  final scope = ProfileScope(namespace: namespace);
  final store = SecureLocalStore(namespace: namespace);
  usePastedImageProfile(scope.pasteScope);
  useOpenedFilesScope(scope.openedFilesFolder);
  final state = AppState(
    apiClientFactory: (baseUrl) => ApiClient(baseUrl: baseUrl),
    cryptoService: UnavailableCryptoService(),
    localStore: store,
    syncServiceFactory: (baseUrl, token) =>
        WebSocketSyncService(baseUrl: baseUrl, token: token),
    pushService: PlatformMobilePushService(),
    receiptPreferences:
        ReceiptPreferences(SecureReceiptPreferenceStore(scope: scope)),
    passkeyClient: PlatformPasskeyClient(),
  )..historyTransferDirectory = slotHistoryTransferDirectory(scope);
  return AccountRuntime(
      namespace: namespace, state: state, closeStore: store.close);
}

/// The account switcher for the release entry point. The existing install is
/// the primary slot (the empty namespace).
AccountHost buildReleaseHost({
  SlotKeyValue? keyValue,
  AccountRuntimeBuilder? build,
}) {
  final kv = keyValue ?? SecureSlotKeyValue();
  return AccountHost(
    registryStore: AccountRegistryStore(storage: kv),
    eraser: SlotEraser(storage: kv, scope: const ProfileScope()),
    build: build ?? buildReleaseRuntime,
    primaryNamespace: '',
    desktopFactory: DesktopServices.startIfSupported,
    inspect: slotInspectorFor(''),
    revoke: slotRevokerFor((baseUrl) => ApiClient(baseUrl: baseUrl)),
    afterClose: (_) async {
      await purgeOpenedAttachments(thisSlotOnly: true);
      await purgePastedImages();
    },
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = PlatformWakeWorkerBridge();
  final launch = WakeLaunchCoordinator(
    bridge: bridge,
    profile: 'release', // Fixed alias for the existing empty store namespace.
    onUi: () async {
      // Restore is represented by an explicit startup state while the app
      // shell remains mounted; failures enter recovery instead of flashing
      // logout or resetting the durable cursor. The host restores each
      // account it opens.
      final host = buildReleaseHost();
      await host.start();
      runApp(VeritraApp(host: host));
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
  /// Either a fixed [state] (as before the account switcher), or a [host]
  /// that owns the live account and swaps it on a switch (B7).
  const VeritraApp({
    this.state,
    this.host,
    this.appearance,
    this.desktop,
    super.key,
  }) : assert((state == null) != (host == null));

  final AppState? state;

  /// The account switcher's host; the desktop services then belong to it.
  final AccountHost? host;

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

  /// The AppState that last heard the lifecycle (host mode: each switch
  /// gives the new runtime the current state).
  AppState? _lifecycleOwner;

  @override
  void initState() {
    super.initState();
    unawaited(_appearance.load());
    widget.desktop?.attach();
    WidgetsBinding.instance.addObserver(this);
    widget.host?.addListener(_hostChanged);
    _hostChanged();
  }

  AppState? get _currentState => widget.state ?? widget.host?.runtime?.state;

  void _hostChanged() {
    final state = _currentState;
    if (state == null || identical(state, _lifecycleOwner)) return;
    _lifecycleOwner = state;
    state.handleAppLifecycleState(
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _currentState?.handleAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.host?.removeListener(_hostChanged);
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
        final host = widget.host;
        if (host == null) return _app(widget.state!, widget.desktop, null);
        // A switch replaces the whole MaterialApp, so no route or widget
        // state of one account can outlive it in the next.
        return ListenableBuilder(
          listenable: host,
          builder: (context, _) {
            final runtime = host.runtime;
            if (runtime == null) {
              return _app(null, null, host);
            }
            return _app(runtime.state, runtime.desktop, host,
                slot: runtime.namespace);
          },
        );
      },
    );
  }

  Widget _app(AppState? state, DesktopServices? desktop, AccountHost? host,
      {String? slot}) {
    return wrapDesktopScope(
        desktop,
        AppearanceScope(
          controller: _appearance,
          child: MaterialApp(
            key: slot == null ? null : ValueKey<String>('slot-$slot'),
            title: veritraProductName,
            theme: veritraLightTheme(),
            darkTheme: veritraDarkTheme(),
            themeMode: _appearance.mode,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: state == null
                ? const Scaffold(
                    body: Center(child: CircularProgressIndicator()))
                : AppShell(state: state),
            builder: (context, child) {
              var content = child ?? const SizedBox.shrink();
              // Demo builds only: call UI above every route.
              if (state != null && state.config.demo) {
                content = CallHost(state: state, child: content);
              }
              if (host == null) return content;
              return AccountHostScope(
                host: host,
                child: Stack(
                  children: <Widget>[
                    content,
                    if (host.switching) const _SwitchingOverlay(),
                  ],
                ),
              );
            },
          ),
        ));
  }
}

/// Blocks the whole app while one account is torn down and the next opens.
class _SwitchingOverlay extends StatelessWidget {
  const _SwitchingOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Semantics(
        liveRegion: true,
        child: Stack(
          children: <Widget>[
            ModalBarrier(
                dismissible: false, color: scheme.scrim.withValues(alpha: 0.5)),
            Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 16),
                      Text(context.l10n.accountsSwitching),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
