import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/app_state.dart';
import 'core/client_config.dart';
import 'core/transport_policy.dart';
import 'crypto/native_crypto_bindings.dart';
import 'crypto/native_crypto_service.dart';
import 'main.dart' show VeritraApp;
import 'push/push_service.dart';
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
const bool _demoBuild = bool.fromEnvironment('VERITRA_DEMO');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!_demoBuild) {
    runApp(const _NotADemoBuild());
    return;
  }
  final localStore = SecureLocalStore(namespace: 'demo');
  final state = AppState(
    apiClientFactory: (baseUrl) => ApiClient(baseUrl: baseUrl),
    cryptoService: NativeCryptoService(
      bindings: NativeCryptoBindings.load(),
      localStore: localStore,
    ),
    localStore: localStore,
    syncServiceFactory: (baseUrl, token) =>
        WebSocketSyncService(baseUrl: baseUrl, token: token),
    pushService: Platform.isAndroid || Platform.isIOS
        ? PlatformMobilePushService()
        : DisabledMobilePushService(),
    config: ClientConfig(
      demo: true,
      transport: TransportPolicy.demo,
      deviceName: _deviceName(),
      defaultServerUrl: 'http://localhost:8080',
    ),
  );
  runApp(VeritraApp(state: state));
  unawaited(state.tryRestoreSession());
}

String _deviceName() {
  if (Platform.isAndroid) return 'Android demo device';
  if (Platform.isIOS) return 'iOS demo device';
  if (Platform.isWindows) return 'Windows demo device';
  if (Platform.isLinux) return 'Linux demo device';
  if (Platform.isMacOS) return 'macOS demo device';
  return 'Demo device';
}

/// Shown when `main_demo.dart` is built without `--dart-define=VERITRA_DEMO=true`,
/// so the demo wiring cannot end up in a build by accident.
class _NotADemoBuild extends StatelessWidget {
  const _NotADemoBuild();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'This is the demo entry point. Build it with '
              '--dart-define=VERITRA_DEMO=true, or use lib/main.dart.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
