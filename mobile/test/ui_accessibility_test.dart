import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/features/auth/connect_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/app_shell.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/tokens.dart';
import 'package:private_messenger/ui/widgets/section_header.dart';
import 'package:private_messenger/ui/widgets/status_pill.dart';

import 'test_crypto_service.dart';

void main() {
  test('compact navigation keeps labels in semantics, not layout', () {
    expect(
      shouldShowFloatingNavLabels(width: 320, textScale: 1),
      isFalse,
    );
    expect(
      shouldShowFloatingNavLabels(width: 500, textScale: 1),
      isTrue,
    );
    expect(
      shouldShowFloatingNavLabels(width: 500, textScale: 2.0),
      isFalse,
    );
  });

  test('the micro type remains readable at the accessibility floor', () {
    expect(BoneType.micro.fontSize, 11);
  });

  testWidgets('shared headings and pills expose stable semantic labels',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: veritraLightTheme(),
        home: const Column(
          children: <Widget>[
            SectionHeader('Notifications'),
            StatusPill(
              label: '1d',
              semanticsLabel: 'Expires after 1 day',
            ),
          ],
        ),
      ),
    );

    expect(find.bySemanticsLabel('NOTIFICATIONS'), findsWidgets);
    expect(find.bySemanticsLabel('Expires after 1 day'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('connect fields expose labels independent of their hints',
      (tester) async {
    final semantics = tester.ensureSemantics();
    // ConnectScreen's form is a lazy ListView. On the default 800x600 test
    // surface the credential fields fall below the fold and are never built,
    // so give the test enough height to lay the whole form out.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = AppState(
      apiClientFactory: (_) => ApiClient(baseUrl: 'https://chat.example.org'),
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _TestSyncService(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: veritraLightTheme(),
        home: ConnectScreen(state: state),
      ),
    );

    expect(find.bySemanticsLabel('Username'), findsWidgets);
    expect(find.bySemanticsLabel('Password'), findsWidgets);
    semantics.dispose();
    state.dispose();
  });

  testWidgets('shared text surfaces build at 320dp and 200 percent text',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: veritraLightTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(320, 640),
            textScaler: TextScaler.linear(2.0),
          ),
          child: const SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SectionHeader('A very long settings section'),
                StatusPill(label: 'Verified device'),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}

class _TestSyncService implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() {
    _events.close();
  }
}
