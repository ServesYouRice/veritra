import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/admin_models.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/admin_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _AdminApi extends ApiClient {
  _AdminApi() : super(baseUrl: 'https://example.test');

  bool needsReauth = true;
  final List<bool> statusCalls = <bool>[];
  bool bobSuspended = false;

  @override
  Future<AdminPage<AdminAccount>> listAdminAccounts(
    String token, {
    String? after,
    int limit = 50,
  }) async {
    return AdminPage<AdminAccount>(<AdminAccount>[
      AdminAccount(
        id: 'acct_me',
        username: 'alice',
        role: 'owner',
        status: 'active',
      ),
      AdminAccount(
        id: 'acct_bob',
        username: 'bob',
        role: 'member',
        status: bobSuspended ? 'suspended' : 'active',
        deviceCount: 2,
      ),
    ], null);
  }

  @override
  Future<AdminPage<AdminAuditEvent>> listAdminAuditEvents(
    String token, {
    String? after,
    int limit = 50,
  }) async {
    return AdminPage<AdminAuditEvent>(<AdminAuditEvent>[
      AdminAuditEvent(
        id: 1,
        eventType: 'account.status.updated',
        metadata: const <String, String>{'status': 'suspended'},
      ),
    ], null);
  }

  @override
  Future<void> setAdminAccountStatus(
    String token,
    String accountId, {
    required bool suspended,
  }) async {
    statusCalls.add(suspended);
    if (needsReauth) {
      throw ApiException(401, '{"error":"recent_auth_required"}');
    }
    bobSuspended = suspended;
  }
}

class _FakeSyncService implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _events.close();
}

void main() {
  testWidgets('lists accounts, suspends after reauth, shows the audit log',
      (tester) async {
    final api = _AdminApi();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _FakeSyncService(),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'acct_me',
        deviceId: 'dev_current',
        username: 'alice',
        role: 'owner',
      );
    var reauths = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdminScreen(
          state: state,
          reauthenticate: (_) async {
            reauths++;
            api.needsReauth = false;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('@bob'), findsOneWidget);
    // The signed-in owner cannot suspend themselves from here.
    expect(find.text('Suspend'), findsOneWidget);

    await tester.tap(find.text('Suspend'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
    await tester.pumpAndSettle();

    expect(reauths, 1);
    expect(api.statusCalls, <bool>[true, true]);
    expect(find.text('SUSPENDED'), findsOneWidget);
    expect(find.text('Reactivate'), findsOneWidget);

    await tester.tap(find.text('Audit log'));
    await tester.pumpAndSettle();
    expect(find.text('account.status.updated'), findsOneWidget);
  });
}
