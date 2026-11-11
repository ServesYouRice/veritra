import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'core/account_host.dart';
import 'core/api_client.dart';
import 'core/app_state.dart';
import 'core/client_config.dart';
import 'core/passkeys.dart';
import 'core/receipts_state.dart';
import 'core/report_seed_store.dart';
import 'core/transport_policy.dart';
import 'crypto/attachment_crypto.dart';
import 'desktop/desktop_services.dart';
import 'crypto/native_crypto_bindings.dart';
import 'crypto/native_crypto_service.dart';
import 'features/chat/attachment_views.dart'
    show purgeOpenedAttachments, useOpenedFilesScope;
import 'features/chat/composer_attachments.dart'
    show purgePastedImages, usePastedImageProfile;
import 'main.dart' show VeritraApp, StartupFailureApp;
import 'push/background_wake_runner.dart';
import 'push/push_service.dart';
import 'push/wake_worker_bridge.dart';
import 'push/wake_launch_coordinator.dart';
import 'storage/account_slots.dart';
import 'storage/local_store.dart';
import 'storage/profile_scope.dart';
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

/// D52 demo switch: on by default in demo builds (owner decision, 2026-11-08);
/// `--dart-define=VERITRA_PHONE_NOTICES=false` turns it off. Native reads the
/// same define at build time and decides on its own; this only lets the bridge
/// accept native's answer. Release (`main.dart`) has no such path.
const bool _phoneNotices =
    bool.fromEnvironment('VERITRA_PHONE_NOTICES', defaultValue: true);

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
  usePastedImageProfile(namespace);
  final kv = SecureSlotKeyValue();
  final registryStore =
      AccountRegistryStore(storage: kv, primaryNamespace: namespace);
  // A cold wake may open only the protected registry's active slot. The
  // native profile is checked against it by WakeLaunchCoordinator.
  final startupSlot = await activeAccountSlotForWake(registryStore);
  final bridge = PlatformWakeWorkerBridge(allowOptIn: _phoneNotices);
  // At most one live store and AppState per process (D52 contract): a
  // background wake and the UI share the active slot's, so two owners never
  // race on MLS state. The account switcher (B7) tears a slot down fully
  // before it builds the next.
  SecureLocalStore? liveStore;
  AppState? liveState;
  String? liveSlot;

  Future<void> closeLive() async {
    final store = liveStore;
    liveStore = null;
    liveState = null;
    liveSlot = null;
    await store?.close();
  }

  Future<AccountRuntime> buildRuntime(String slot,
      {required bool background}) async {
    final existing = liveState;
    if (liveSlot == slot && existing != null) {
      if (!background) liveStore?.allowForegroundInitialization();
      return AccountRuntime(
          namespace: slot, state: existing, closeStore: closeLive);
    }
    final scope = ProfileScope(namespace: slot, primaryNamespace: namespace);
    usePastedImageProfile(scope.pasteScope);
    useOpenedFilesScope(scope.openedFilesFolder);
    // A cold background start opens only existing protected state: no key,
    // database or profile is created for a push.
    final store = SecureLocalStore(namespace: slot, existingOnly: background);
    final bindings = NativeCryptoBindings.load();
    final state = AppState(
      apiClientFactory: (baseUrl) =>
          ApiClient(baseUrl: baseUrl, transport: TransportPolicy.demo),
      cryptoService: NativeCryptoService(
        bindings: bindings,
        localStore: store,
      ),
      localStore: store,
      reportSeedStore: SecureReportSeedStore(scope: scope),
      attachmentService: AttachmentCryptoService(bindings,
          directoryProvider: () => slotWorkingDirectory(scope)),
      receiptPreferences:
          ReceiptPreferences(SecureReceiptPreferenceStore(scope: scope)),
      syncServiceFactory: (baseUrl, token) =>
          WebSocketSyncService(baseUrl: baseUrl, token: token),
      passkeyClient: PlatformPasskeyClient(),
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
    )..historyTransferDirectory = slotHistoryTransferDirectory(scope);
    // A headless engine has no view: never treat it as resumed.
    if (background) state.handleAppLifecycleState(AppLifecycleState.detached);
    liveStore = store;
    liveState = state;
    liveSlot = slot;
    return AccountRuntime(
      namespace: slot,
      state: state,
      closeStore: closeLive,
    );
  }

  BackgroundWakeRunner? runner;

  /// Installs the native worker for [state]'s account and reports whether
  /// native allows phone notices. Used by a cold background start and, when
  /// the demo switch is on, by the UI process after sign-in.
  Future<bool> installWorker(AppState state, String slot) async {
    final worker = runner = BackgroundWakeRunner(
      profile: slot,
      bridge: bridge,
      restoreExisting: state.restoreForBackgroundWake,
      catchUp: state.catchUpForBackgroundWake,
      mayStart: () => !state.foregroundActive,
    );
    // Sign-out revokes the native permit and scheduled work before the
    // private notice state is cleared. It cancels without draining: the
    // session generation already fences any late commit, and waiting here
    // could wait on a restore queued behind this very sign-out. The worker
    // stays uninstalled until the next sign-in or process start.
    state.beforeLocalSessionClear = () async {
      worker.cancelForForeground();
      await bridge.uninstall(slot);
    };
    final installed = await bridge.install(
        profile: slot, onRun: worker.run, onCancel: worker.cancel);
    if (installed && bridge.canOptIn) return true;
    // Native did not allow phone notices (a build without them): no worker
    // may stay bound, so warm runs cannot catch up either.
    if (installed) await bridge.uninstall(slot);
    state.beforeLocalSessionClear = null;
    if (identical(runner, worker)) runner = null;
    return false;
  }

  final launch = WakeLaunchCoordinator(
    bridge: bridge,
    profile: startupSlot ?? namespace,
    // Reached only when native reports a background launch bound to this
    // compiled profile with its silent path installed. Native cold execution
    // exists only in builds made with VERITRA_PHONE_NOTICES; otherwise native
    // never starts this and nothing registers for muted-mention wakes.
    onBackground: () async {
      final slot = startupSlot;
      if (slot == null) return;
      final state = (await buildRuntime(slot, background: true)).state;
      if (await installWorker(state, slot)) state.allowPhoneNotices();
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
      final host = AccountHost(
        registryStore: registryStore,
        eraser: SlotEraser(
            storage: kv,
            scope: ProfileScope(
                namespace: namespace, primaryNamespace: namespace)),
        build: (slot) async {
          final runtime = await buildRuntime(slot, background: false);
          if (_phoneNotices && (Platform.isAndroid || Platform.isIOS)) {
            runtime.state.phoneNoticeInstaller =
                () => installWorker(runtime.state, slot);
          }
          // At start and then hourly: a crash while running leaves files too.
          runtime.state.startAttachmentOrphanSweep();
          return runtime;
        },
        primaryNamespace: namespace,
        desktopFactory: (state) => DesktopServices.startIfSupported(state,
            scope: ProfileScope(
                namespace: (state.localStore as SecureLocalStore).namespace,
                primaryNamespace: namespace)),
        inspect: slotInspectorFor(namespace),
        revoke: slotRevokerFor((baseUrl) =>
            ApiClient(baseUrl: baseUrl, transport: TransportPolicy.demo)),
        // The permit follows the active slot; uninstall fences stale wakes
        // before another runtime can install a new permit.
        beforeLeave: (runtime) async {
          final worker = runner;
          worker?.cancelForForeground();
          try {
            await bridge.uninstall(runtime.namespace);
          } finally {
            // Native failure must not skip an atomic in-flight job's drain.
            await worker?.drain();
            if (identical(runner, worker)) runner = null;
          }
        },
        afterClose: (_) async {
          await purgeOpenedAttachments(thisSlotOnly: true);
          await purgePastedImages();
        },
      );
      await host.start();
      runApp(VeritraApp(host: host));
      unawaited(purgeOpenedAttachments());
      unawaited(purgePastedImages());
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
