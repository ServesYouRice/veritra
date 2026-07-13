import 'dart:async';

import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/api_client.dart';
import 'crypto/crypto_service.dart';
import 'push/push_service.dart';
import 'push/background_push.dart';
import 'storage/local_store.dart';
import 'sync/sync_service.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(
    apiClientFactory: (baseUrl) => ApiClient(baseUrl: baseUrl),
    cryptoService: UnavailableCryptoService(),
    localStore: SecureLocalStore(),
    syncServiceFactory: (baseUrl, token) =>
        WebSocketSyncService(baseUrl: baseUrl, token: token),
    pushService: PlatformMobilePushService(),
  );
  // Best-effort: restore a previously stored session so the user doesn't have
  // to re-authenticate on every cold start. If the call fails (corrupt
  // keystore entry, missing secure storage on a new platform) we silently
  // fall through to the connect screen.
  runApp(VeritraApp(state: state));
  unawaited(state.tryRestoreSession());
}

@pragma('vm:entry-point')
Future<void> pushBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await performBackgroundPushCatchUp();
}

class VeritraApp extends StatelessWidget {
  const VeritraApp({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return MaterialApp(
          title: 'Veritra',
          theme: veritraLightTheme(),
          darkTheme: veritraDarkTheme(),
          themeMode: ThemeMode.system,
          home: AppShell(state: state),
        );
      },
    );
  }
}
