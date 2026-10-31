// The invite screen tells an admin when revoking or loading invites failed
// (TASK-086), instead of ignoring it or saying there are no invites.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/invite_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

class _InviteApi extends ApiClient {
  _InviteApi() : super(baseUrl: 'https://localhost');

  bool failList = false;
  bool failRevoke = false;
  List<Invite> invites = <Invite>[];
  final List<String> revoked = <String>[];

  @override
  Future<List<Invite>> listInvites(String token) async {
    if (failList) throw const SocketException('offline');
    return invites;
  }

  @override
  Future<void> revokeInvite(String token, String inviteId) async {
    if (failRevoke) throw const SocketException('offline');
    revoked.add(inviteId);
  }
}

Invite _invite(String id, String code) =>
    Invite(id: id, code: code, maxUses: 5, uses: 1);

Future<(AppState, _InviteApi)> _open(
  WidgetTester tester, {
  List<Invite> invites = const <Invite>[],
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _InviteApi();
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost',
      token: 'token',
      accountId: 'acct_admin',
      deviceId: 'dev_admin',
      role: 'admin',
    )
    ..invites = invites
    ..invitesLoaded = true;
  addTearDown(state.dispose);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: InviteScreen(state: state),
  ));
  await tester.pumpAndSettle();
  return (state, api);
}

Future<void> _revokeFirst(WidgetTester tester) async {
  await tester.tap(find.byTooltip(englishL10n.inviteActions).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Revoke').last);
  await tester.pumpAndSettle();
  // The confirmation dialog.
  await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
  await tester.pumpAndSettle();
}

Future<void> _pullToRefresh(WidgetTester tester) async {
  // The same refresh a pull gesture runs.
  unawaited(tester
      .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
      .show());
  await tester.pumpAndSettle();
}

void main() {
  final unreachable = englishL10n.errorUnreachable;

  testWidgets('a failed revoke is shown and the invite stays', (tester) async {
    final (state, api) = await _open(
      tester,
      invites: <Invite>[_invite('inv_1', 'ABCD-1234')],
    );
    api.failRevoke = true;
    await _revokeFirst(tester);
    expect(find.text(unreachable), findsOneWidget);
    expect(find.text('ABCD-1234'), findsOneWidget);
    expect(state.invites, hasLength(1));
  });

  testWidgets('a successful revoke removes the invite quietly', (tester) async {
    final (state, api) = await _open(
      tester,
      invites: <Invite>[_invite('inv_1', 'ABCD-1234')],
    );
    // An unrelated earlier failure is not reported as this revoke's.
    state.error = 'Something old went wrong';
    await _revokeFirst(tester);
    expect(api.revoked, <String>['inv_1']);
    expect(find.text('ABCD-1234'), findsNothing);
    expect(find.text('Something old went wrong'), findsNothing);
    expect(find.text(unreachable), findsNothing);
  });

  testWidgets('leaving during a failing revoke causes no error',
      (tester) async {
    final (_, api) = await _open(
      tester,
      invites: <Invite>[_invite('inv_1', 'ABCD-1234')],
    );
    api.failRevoke = true;
    await tester.tap(find.byTooltip(englishL10n.inviteActions).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    // Gone before the answer is handled.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed refresh is not "no invites yet"', (tester) async {
    final (_, api) = await _open(tester);
    expect(find.text(englishL10n.inviteEmptyTitle), findsOneWidget);

    api.failList = true;
    await _pullToRefresh(tester);
    expect(find.text(englishL10n.inviteLoadFailed), findsOneWidget);
    expect(find.text(englishL10n.inviteEmptyTitle), findsNothing);

    // Retrying works and clears the error.
    api
      ..failList = false
      ..invites = <Invite>[_invite('inv_9', 'WXYZ-9999')];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('WXYZ-9999'), findsOneWidget);
    expect(find.text(englishL10n.inviteLoadFailed), findsNothing);
  });

  testWidgets('a refresh that succeeds with nothing says there are none',
      (tester) async {
    final (_, _) = await _open(tester);
    await _pullToRefresh(tester);
    expect(find.text(englishL10n.inviteEmptyTitle), findsOneWidget);
    expect(find.text(englishL10n.inviteLoadFailed), findsNothing);
  });
}
