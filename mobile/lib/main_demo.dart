import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/app_state.dart';
import 'core/client_config.dart';
import 'core/receipts_state.dart';
import 'core/transport_policy.dart';
import 'crypto/attachment_crypto.dart';
import 'desktop/desktop_services.dart';
import 'crypto/backup_service.dart';
import 'crypto/native_crypto_bindings.dart';
import 'crypto/native_crypto_service.dart';
import 'features/chat/attachment_views.dart' show purgeOpenedAttachments;
import 'features/chat/composer_attachments.dart' show purgePastedImages;
import 'main.dart' show VeritraApp, StartupFailureApp;
import 'push/background_wake_runner.dart';
import 'push/push_service.dart';
import 'push/wake_worker_bridge.dart';
import 'push/wake_launch_coordinator.dart';
import 'storage/local_store.dart';
import 'sync/sync_service.dart';

/// Demo entry point (decision D11). Never used for release builds.
///
/// It wires the real OpenMLS crypto service, which has not been independently
/// reviewed yet, and accepts plain HTTP to this machine only (D12). Release
/// builds use `main.dart`, which keeps crypto unavailable, so
/// `scripts/release-readiness.sh` still blocks any release.
///
/// Run with:
/// `flutter run -t lib/main_demo.dart --dart-define=VERITRA_DEMO=true`
///
/// Desktop builds accept `--profile <name>` (with `flutter run`, pass
/// `--dart-entrypoint-args=--profile=<name>`), so two accounts can run side
/// by side on one machine, each with its own data and keys.
const bool _demoBuild = bool.fromEnvironment('VERITRA_DEMO');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!_demoBuild) {
    runApp(const _Message('This is the demo entry point. Build it with '
        '--dart-define=VERITRA_DEMO=true, or use lib/main.dart.'));
    return;
  }
  final String? profile;
  try {
    profile = demoProfileFromArgs(args);
  } on FormatException catch (error) {
    runApp(_Message(error.message));
    return;
  }
  final namespace = profile == null ? 'demo' : 'demo-$profile';
  final bridge = PlatformWakeWorkerBridge();
  // One store and one AppState per process (D52 contract): a background
  // wake and the UI share them, so two owners never race on MLS state.
  SecureLocalStore? localStore;
  AppState? appState;
  AppState build({required bool background}) {
    final existing = appState;
    if (existing != null) return existing;
    // A cold background start opens only existing protected state: no key,
    // database or profile is created for a push.
    final store = localStore =
        SecureLocalStore(namespace: namespace, existingOnly: background);
    final bindings = NativeCryptoBindings.load();
    final state = AppState(
      apiClientFactory: (baseUrl) => ApiClient(baseUrl: baseUrl),
      cryptoService: NativeCryptoService(
        bindings: bindings,
        localStore: store,
      ),
      localStore: store,
      backupService: BackupService(
        bindings: bindings,
        localStore: store,
        clientFactory: (baseUrl) {
          // A recovery code names its server; demo builds still accept only
          // HTTPS or loopback (D12).
          if (!TransportPolicy.demo.allows(baseUrl)) {
            throw StateError('recovery code names a server this build refuses');
          }
          return ApiClient(baseUrl: baseUrl);
        },
      ),
      attachmentService: AttachmentCryptoService(bindings),
      receiptPreferences: ReceiptPreferences(SecureReceiptPreferenceStore()),
      syncServiceFactory: (baseUrl, token) =>
          WebSocketSyncService(baseUrl: baseUrl, token: token),
      pushService: Platform.isAndroid || Platform.isIOS
          ? PlatformMobilePushService()
          : DisabledMobilePushService(),
      config: ClientConfig(
        demo: true,
        transport: TransportPolicy.demo,
        deviceName:
            profile == null ? _deviceName() : '${_deviceName()} ($profile)',
        defaultServerUrl: 'http://localhost:8080',
        syncWhileUnfocused:
            Platform.isWindows || Platform.isLinux || Platform.isMacOS,
      ),
    );
    // A headless engine has no view: never treat it as resumed.
    if (background) state.handleAppLifecycleState(AppLifecycleState.detached);
    return appState = state;
  }

  BackgroundWakeRunner? runner;
  final launch = WakeLaunchCoordinator(
    bridge: bridge,
    profile: namespace,
    // Reached only when native reports a background launch bound to this
    // compiled profile with its silent path installed. Native cold execution
    // and server opt-in stay disabled (can_opt_in:false), so today this runs
    // nowhere; it is the guarded D52 wiring for the later reviewed enablement.
    onBackground: () async {
      final state = build(background: true);
      final worker = runner = BackgroundWakeRunner(
        profile: namespace,
        bridge: bridge,
        restoreExisting: state.restoreForBackgroundWake,
        catchUp: state.catchUpForBackgroundWake,
        mayStart: () => !state.foregroundActive,
      );
      // Sign-out revokes the native permit and scheduled work before the
      // private notice state is cleared. It cancels without draining: the
      // session generation already fences any late commit, and waiting here
      // could wait on a restore queued behind this very sign-out. The worker
      // stays uninstalled until the next process start.
      state.beforeLocalSessionClear = () async {
        worker.cancelForForeground();
        await bridge.uninstall(namespace);
      };
      final installed = await bridge.install(
          profile: namespace, onRun: worker.run, onCancel: worker.cancel);
      if (!installed) {
        state.beforeLocalSessionClear = null;
        runner = null;
      }
    },
    // The UI takes over: cancel any wake first, then wait for its atomic
    // work to drain before the foreground owner starts.
    beforeUi: () async {
      final worker = runner;
      if (worker == null) return;
      worker.cancelForForeground();
      await worker.drain();
    },
    onUi: () async {
      final state = build(background: false);
      localStore?.allowForegroundInitialization();
      final desktop = await DesktopServices.startIfSupported(state);
      runApp(VeritraApp(state: state, desktop: desktop));
      unawaited(purgeOpenedAttachments());
      unawaited(purgePastedImages());
      unawaited(state.tryRestoreSession());
    },
    onUiError: () => runApp(const StartupFailureApp()),
  );
  await launch.start();
}

String _deviceName() {
  if (Platform.isAndroid) return 'Android demo device';
  if (Platform.isIOS) return 'iOS demo device';
  if (Platform.isWindows) return 'Windows demo device';
  if (Platform.isLinux) return 'Linux demo device';
  if (Platform.isMacOS) return 'macOS demo device';
  return 'Demo device';
}

/// Reads `--profile <name>` or `--profile=<name>`. Names are 1-20 lowercase
/// letters or digits, because they become part of file and key names.
String? demoProfileFromArgs(List<String> args) {
  String? value;
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--profile' && index + 1 < args.length) {
      value = args[++index];
    } else if (arg.startsWith('--profile=')) {
      value = arg.substring('--profile='.length);
    } else if (arg == '--profile') {
      throw const FormatException('--profile needs a name.');
    }
  }
  if (value == null) return null;
  if (!RegExp(r'^[a-z0-9]{1,20}$').hasMatch(value)) {
    throw const FormatException(
        'Profile names are 1-20 lowercase letters or digits.');
  }
  return value;
}

/// A single message instead of the app: shown when `main_demo.dart` is built
/// without `--dart-define=VERITRA_DEMO=true`, so the demo wiring cannot end
/// up in a build by accident, or when the arguments are invalid.
class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(text, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
