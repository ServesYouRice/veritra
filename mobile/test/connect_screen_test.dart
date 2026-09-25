import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/features/auth/connect_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/theme.dart';

import 'test_crypto_service.dart';

void main() {
  testWidgets('on a fresh instance "Create owner" submits the owner form',
      (tester) async {
    // The form is a lazy ListView; lay all of it out.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _FreshInstanceState();
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      home: ConnectScreen(state: state),
    ));
    await tester.enterText(
        find.byType(TextFormField).first, 'https://chat.example.org');
    await tester.pumpAndSettle();

    // Whatever mode the form opened in, one press finds the fresh instance
    // and shows the owner form.
    if (find.text('Create owner').evaluate().isEmpty) {
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
    }
    expect(find.text('Create owner'), findsWidgets);
    expect(state.owners, isEmpty);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(1), 'owner');
    await tester.enterText(fields.at(2), 'owner-password-123');
    await tester.enterText(fields.at(3), 'owner-password-123');
    await tester.enterText(fields.at(4), 'setup-token');
    await tester.pumpAndSettle();

    // The press that used to stop at "switch to owner mode" again.
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(state.owners, <String>['owner/setup-token']);
  });
}

class _FreshInstanceState extends AppState {
  _FreshInstanceState()
      : super(
          apiClientFactory: (_) =>
              ApiClient(baseUrl: 'https://chat.example.org'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  final List<String> owners = <String>[];

  @override
  Future<SetupProbeResult> probeSetup(String baseUrl) async =>
      const SetupProbeResult(
          state: SetupProbeState.reachable, setupRequired: true);

  @override
  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async => false;

  @override
  Future<void> createOwner(String baseUrl, String username, String password,
      String setupToken) async {
    owners.add('$username/$setupToken');
  }
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() => _controller.close();
}
