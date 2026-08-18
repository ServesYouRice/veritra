import 'dart:async';

import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/api_client.dart';
import 'crypto/crypto_service.dart';
import 'push/push_service.dart';
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
  // Restore is represented by an explicit startup state while the app shell
  // remains mounted; failures enter recovery instead of flashing logout or
  // resetting the durable cursor.
  runApp(VeritraApp(state: state));
  unawaited(state.tryRestoreSession());
}

class VeritraApp extends StatefulWidget {
  const VeritraApp({required this.state, super.key});

  final AppState state;

  @override
  State<VeritraApp> createState() => _VeritraAppState();
}

class _VeritraAppState extends State<VeritraApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return MaterialApp(
          title: 'Veritra',
          theme: veritraLightTheme(),
          darkTheme: veritraDarkTheme(),
          themeMode: ThemeMode.system,
          home: AppShell(state: widget.state),
        );
      },
    );
  }
}
