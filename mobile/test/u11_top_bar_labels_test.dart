// UI audit 2026-11-14, U11: top-bar actions carry a word where the window is
// wide enough. The helper shows icon and word from 600 dp at text scale 1.3 or
// below, and icon only, with a tooltip, otherwise. The chat list is the sample
// screen: its title must stay whole at both widths.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/chat_list_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/widgets/bar_action.dart';

import 'test_crypto_service.dart';

Widget _app(Widget home, {double textScale = 1.0}) => MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

void _phone(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

class _Api extends ApiClient {
  _Api(this.list) : super(baseUrl: 'https://localhost:8080');

  final List<Conversation> list;

  @override
  Future<List<Conversation>> conversations(String token) async => list;
}

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

Future<AppState> _state(WidgetTester tester) async {
  final api = _Api(<Conversation>[
    Conversation(
      id: 'mine',
      kind: 'dm',
      peerAccountId: 'acct_pal',
      peerUsername: 'pal',
      createdBy: 'acct_me',
      createdAt: DateTime.utc(2026, 6, 1),
    ),
  ]);
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: TestOnlyCryptoService(),
    localStore: MemoryLocalStore(),
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..api = api
    ..session = const Session(
      baseUrl: 'https://localhost:8080',
      token: 'token',
      accountId: 'acct_me',
      deviceId: 'dev_me',
    );
  addTearDown(state.dispose);
  await tester.runAsync(state.refreshConversations);
  return state;
}

void main() {
  group('BarAction', () {
    Widget bar() => Scaffold(
          appBar: AppBar(
            title: const Text('Title'),
            actions: <Widget>[
              BarAction(
                icon: Icons.add,
                label: 'New chat',
                onPressed: () {},
              ),
            ],
          ),
        );

    testWidgets('icon only with a tooltip at 360 dp, icon and word at 600 dp',
        (tester) async {
      _phone(tester, 360);
      await tester.pumpWidget(_app(bar()));
      await tester.pump();
      expect(find.byTooltip('New chat'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byIcon(Icons.add), findsOneWidget);

      _phone(tester, 600);
      await tester.pumpWidget(_app(bar()));
      await tester.pump();
      expect(find.widgetWithText(TextButton, 'New chat'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.byTooltip('New chat'), findsOneWidget);
    });

    testWidgets('large text keeps the icon only, even at 600 dp',
        (tester) async {
      _phone(tester, 600);
      await tester.pumpWidget(_app(bar(), textScale: 1.5));
      await tester.pump();
      expect(find.byType(TextButton), findsNothing);
      expect(find.byTooltip('New chat'), findsOneWidget);
    });

    testWidgets('a tap runs the action in both forms', (tester) async {
      var taps = 0;
      _phone(tester, 360);
      await tester.pumpWidget(_app(Scaffold(
        body: BarAction(
          icon: Icons.add,
          label: 'New chat',
          onPressed: () => taps++,
        ),
      )));
      await tester.tap(find.byType(IconButton));
      _phone(tester, 600);
      await tester.pumpWidget(_app(Scaffold(
        body: BarAction(
          icon: Icons.add,
          label: 'New chat',
          onPressed: () => taps++,
        ),
      )));
      await tester.tap(find.widgetWithText(TextButton, 'New chat'));
      expect(taps, 2);
    });
  });

  testWidgets(
      'U11 chat list: icons with tooltips at 360 dp, words at 600 dp, and the '
      'title stays whole at both', (tester) async {
    for (final width in <double>[360, 600]) {
      _phone(tester, width);
      final state = await _state(tester);
      await tester.pumpWidget(_app(ChatListScreen(state: state)));
      await tester.pump();

      expect(tester.takeException(), isNull, reason: 'at $width dp');
      expect(find.text(englishL10n.navChats), findsOneWidget);
      expect(find.byTooltip(englishL10n.chatListNewChat), findsOneWidget);
      expect(find.byTooltip(englishL10n.w8ArchivedChats), findsOneWidget);

      final words =
          find.widgetWithText(TextButton, englishL10n.w8ArchivedChats);
      if (width >= BarAction.minWordsWidth) {
        expect(words, findsOneWidget, reason: 'words at $width dp');
      } else {
        expect(words, findsNothing, reason: 'icon only at $width dp');
        expect(find.byType(TextButton), findsNothing);
      }
    }
  });
}
