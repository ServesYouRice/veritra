// The push status row claims "active" only when push is registered and the
// system allows notifications (TASK-087).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/settings_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/push/push_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/theme.dart';
import 'package:private_messenger/ui/tokens.dart' show VeritraStateColors;

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

Future<void> _show(
  WidgetTester tester, {
  required PushState push,
  required NotificationPermission permission,
}) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState(
    apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..session = const Session(
      baseUrl: 'https://localhost',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    )
    ..pushState = push
    ..notificationPermission = permission;
  addTearDown(state.dispose);
  await tester.pumpWidget(MaterialApp(
    theme: veritraLightTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SettingsScreen(state: state)),
  ));
  // Settings keeps a spinner running while it loads, so settle by hand.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  final l10n = englishL10n;
  final states = VeritraStateColors.light;

  Color tintOf(WidgetTester tester, IconData icon) =>
      tester.widget<Icon>(find.byIcon(icon)).color!;

  testWidgets('granted permission shows push as active', (tester) async {
    await _show(
      tester,
      push: PushState.registered,
      permission: NotificationPermission.granted,
    );
    expect(find.text(l10n.settingsPushActiveTitle), findsOneWidget);
    expect(
        tintOf(tester, Icons.notifications_active_outlined), states.verified);
    expect(find.text(l10n.settingsAllowNotifications), findsNothing);
  });

  testWidgets('permission not asked yet is not shown as active',
      (tester) async {
    await _show(
      tester,
      push: PushState.registered,
      permission: NotificationPermission.notDetermined,
    );
    expect(find.text(l10n.settingsPushActiveTitle), findsNothing);
    expect(find.text(l10n.settingsPushNotAllowedTitle), findsOneWidget);
    expect(find.text(l10n.settingsPushNotAllowedDetail), findsOneWidget);
    expect(tintOf(tester, Icons.notifications_paused_outlined), states.warning);
    // The tile that asks for permission is still offered.
    expect(find.text(l10n.settingsAllowNotifications), findsOneWidget);
  });

  testWidgets('denied permission keeps its own message', (tester) async {
    await _show(
      tester,
      push: PushState.registered,
      permission: NotificationPermission.denied,
    );
    expect(find.text(l10n.settingsPushDeniedTitle), findsOneWidget);
    expect(find.text(l10n.settingsPushActiveTitle), findsNothing);
    expect(tintOf(tester, Icons.notifications_off_outlined), states.warning);
  });

  testWidgets('a permission the device cannot confirm is not shown as active',
      (tester) async {
    await _show(
      tester,
      push: PushState.registered,
      permission: NotificationPermission.unsupported,
    );
    expect(find.text(l10n.settingsPushActiveTitle), findsNothing);
    expect(find.text(l10n.settingsPushUnconfirmedTitle), findsOneWidget);
    expect(
        tintOf(tester, Icons.notification_important_outlined), states.warning);
  });

  testWidgets('other push states are unchanged by the permission',
      (tester) async {
    await _show(
      tester,
      push: PushState.noDistributor,
      permission: NotificationPermission.granted,
    );
    expect(find.text(l10n.settingsPushNoDistributorTitle), findsOneWidget);
    expect(find.text(l10n.settingsPushActiveTitle), findsNothing);
  });
}
