import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/profile_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

void main() {
  testWidgets('profile exposes account and current-device identity',
      (tester) async {
    final state = AppState(
      apiClientFactory: (_) => ApiClient(baseUrl: 'https://example.test'),
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _FakeSyncService(),
    )
      ..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'acct_0123456789abcdef',
        deviceId: 'dev_current',
        username: 'alice',
        role: 'owner',
      )
      ..devices = <Device>[
        Device(
          id: 'dev_current',
          accountId: 'acct_0123456789abcdef',
          name: 'Alice phone',
          createdAt: DateTime.utc(2026),
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(home: ProfileScreen(state: state)),
    );

    expect(find.text('@alice'), findsWidgets);
    expect(find.text('Alice phone'), findsOneWidget);
    expect(find.text('owner'), findsOneWidget);
    expect(find.byTooltip('Copy Account ID'), findsOneWidget);
    expect(find.byTooltip('Copy Current device'), findsOneWidget);
    expect(find.text('Encryption identity pending'), findsOneWidget);
  });
}

class _FakeSyncService implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() => _events.close();
}
