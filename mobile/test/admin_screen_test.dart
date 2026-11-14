import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/admin_models.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/admin_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/l10n/l10n.dart' show englishL10n;
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _AdminApi extends ApiClient {
  _AdminApi() : super(baseUrl: 'https://example.test');

  bool needsReauth = true;
  final List<bool> statusCalls = <bool>[];
  bool bobSuspended = false;
  bool failAccounts = false;
  bool failEvents = false;
  bool emptyEvents = false;

  @override
  Future<AdminPage<AdminAccount>> listAdminAccounts(
    String token, {
    String? after,
    int limit = 50,
  }) async {
    if (failAccounts) throw const SocketException('offline');
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
    String? before,
    int limit = 50,
  }) async {
    if (failEvents) throw const SocketException('offline');
    if (emptyEvents)
      return AdminPage<AdminAuditEvent>(<AdminAuditEvent>[], null);
    return AdminPage<AdminAuditEvent>(<AdminAuditEvent>[
      AdminAuditEvent(
        id: 1,
        eventType: 'account.status.updated',
        actorAccountId: 'acct_me',
        metadata: const <String, String>{
          'status': 'suspended',
          'target_account_id': 'acct_bob',
        },
      ),
      // An event type with no wording of its own is spaced out, not shown
      // as a code.
      AdminAuditEvent(
        id: 2,
        eventType: 'report.dismissed',
        actorAccountId: 'acct_bob',
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
      throw ApiException(403, '{"error":"recent_auth_required"}');
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
  testWidgets('lists accounts, suspends after reauth, shows the audit log', (
    tester,
  ) async {
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
    // U34: Suspend is not in the list; it lives on the person's page.
    expect(find.text('Suspend'), findsNothing);
    await tester.tap(find.text('@bob'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin-account-toggle')), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin-account-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
    await tester.pumpAndSettle();

    expect(reauths, 1);
    expect(api.statusCalls, <bool>[true, true]);
    expect(find.text('SUSPENDED'), findsOneWidget);
    await tester.tap(find.text('@bob'));
    await tester.pumpAndSettle();
    expect(find.text('Reactivate'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Audit log'));
    await tester.pumpAndSettle();
    // The log reads as sentences with names.
    expect(find.text('@alice suspended @bob'), findsOneWidget);
    expect(find.text('@bob: report dismissed'), findsOneWidget);
    expect(find.text('account.status.updated'), findsNothing);
  });

  Future<void> openAs(
    WidgetTester tester,
    _AdminApi api, {
    required String accountId,
    required String role,
  }) async {
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _FakeSyncService(),
    )
      ..api = api
      ..session = Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: accountId,
        deviceId: 'dev_current',
        username: 'someone',
        role: role,
      );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdminScreen(state: state, reauthenticate: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
  }

  final toggle = find.byKey(const Key('admin-account-toggle'));

  Future<void> openPerson(WidgetTester tester, String name) async {
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  testWidgets('an admin can suspend a member but not an owner', (tester) async {
    // Rows: alice (owner) and bob (member).
    await openAs(tester, _AdminApi(), accountId: 'acct_admin', role: 'admin');
    await openPerson(tester, '@bob');
    expect(toggle, findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await openPerson(tester, '@alice');
    expect(toggle, findsNothing);
  });

  testWidgets('a second owner cannot suspend an owner', (tester) async {
    await openAs(tester, _AdminApi(), accountId: 'acct_owner2', role: 'owner');
    await openPerson(tester, '@alice');
    expect(toggle, findsNothing);
  });

  group('each tab keeps its own error', () {
    final unreachable = englishL10n.errorUnreachable;

    Future<void> openWith(WidgetTester tester, _AdminApi api) async {
      await openAs(tester, api, accountId: 'acct_me', role: 'owner');
    }

    Future<void> pullToRefresh(WidgetTester tester) async {
      // Refresh the tab on screen: the first indicator is the accounts tab's
      // and the last the audit tab's, and only the visible one is hittable.
      final indicator = find.byType(RefreshIndicator).hitTestable();
      await tester.drag(indicator.first, const Offset(0, 400));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'a failed audit load is not an empty log after the accounts '
        'tab refreshes', (tester) async {
      final api = _AdminApi()..failEvents = true;
      await openWith(tester, api);
      await tester.tap(find.text('Audit log'));
      await tester.pumpAndSettle();
      expect(find.text(unreachable), findsOneWidget);
      expect(find.text(englishL10n.adminNoEvents), findsNothing);

      await tester.tap(find.text('Accounts'));
      await tester.pumpAndSettle();
      await pullToRefresh(tester);
      expect(find.text('@bob'), findsOneWidget);

      await tester.tap(find.text('Audit log'));
      await tester.pumpAndSettle();
      expect(
        find.text(unreachable),
        findsOneWidget,
        reason: 'the audit tab still says its load failed',
      );
      expect(find.text(englishL10n.adminNoEvents), findsNothing);
    });

    testWidgets('an accounts error is not shown on the audit tab', (
      tester,
    ) async {
      final api = _AdminApi()..failAccounts = true;
      await openWith(tester, api);
      expect(find.text(unreachable), findsOneWidget);
      expect(find.text('@bob'), findsNothing);
      expect(find.text(englishL10n.adminNoAccounts), findsNothing);

      await tester.tap(find.text('Audit log'));
      await tester.pumpAndSettle();
      // Without the accounts the names fall back to short ids.
      expect(find.textContaining('suspended'), findsOneWidget);
      expect(find.text(unreachable), findsNothing);
    });

    testWidgets('a successful audit refresh clears the audit error', (
      tester,
    ) async {
      final api = _AdminApi()..failEvents = true;
      await openWith(tester, api);
      await tester.tap(find.text('Audit log'));
      await tester.pumpAndSettle();
      expect(find.text(unreachable), findsOneWidget);

      api.failEvents = false;
      await pullToRefresh(tester);
      expect(find.text(unreachable), findsNothing);
      expect(find.text('@alice suspended @bob'), findsOneWidget);
    });

    testWidgets('a log that really is empty says so', (tester) async {
      final api = _AdminApi()..emptyEvents = true;
      await openWith(tester, api);
      await tester.tap(find.text('Audit log'));
      await tester.pumpAndSettle();
      expect(find.text(englishL10n.adminNoEvents), findsOneWidget);
      expect(find.text(unreachable), findsNothing);
    });

    testWidgets('retrying one tab reloads only that tab', (tester) async {
      final api = _AdminApi()..failEvents = true;
      await openWith(tester, api);
      api.failAccounts = true;
      // Refreshing the accounts tab fails on its own; the audit error stays
      // on the audit tab only.
      await pullToRefresh(tester);
      expect(find.text(unreachable), findsOneWidget);
      await tester.tap(find.text('Audit log'));
      await tester.pumpAndSettle();
      expect(find.text(unreachable), findsOneWidget);
      expect(find.text('@bob'), findsNothing);
    });
  });
}
