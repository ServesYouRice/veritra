// U30: the chat details page leads with the person (photo, name, Mute, Search,
// Call). Disappearing messages is one row that opens a sheet and says why it
// is locked. IDs and the membership note sit under Advanced. A chat of two
// shows no roles.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/calls/call_controller.dart';
import 'package:private_messenger/calls/call_service.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/chat/conversation_details_screen.dart';
import 'package:private_messenger/features/search/search_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/format.dart' show shortId;

import 'call_service_fakes.dart';
import 'test_crypto_service.dart';

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  List<ConversationMember> members = <ConversationMember>[];
  final List<int?> retentionChanges = <int?>[];

  @override
  Future<Conversation> updateRetention(
    String token,
    String conversationId,
    int? retentionSeconds,
  ) async {
    retentionChanges.add(retentionSeconds);
    return Conversation(
      id: conversationId,
      kind: 'dm',
      currentRole: 'owner',
      peerAccountId: 'acct_alice',
      peerUsername: 'alice',
      retentionSeconds: retentionSeconds,
    );
  }

  @override
  Future<List<ConversationMember>> conversationMembers(
    String token,
    String conversationId,
  ) async =>
      members;

  @override
  Future<ConversationMute> conversationMute(
    String token,
    String conversationId,
  ) async =>
      const ConversationMute(muted: false);
}

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

AppState _state(_Api api, List<Conversation> conversations) {
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
    )
    ..conversations = conversations;
  addTearDown(state.dispose);
  return state;
}

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

Conversation _dm({String role = 'owner', int? retention}) => Conversation(
      id: 'conv_1',
      kind: 'dm',
      currentRole: role,
      peerAccountId: 'acct_alice',
      peerUsername: 'alice',
      createdAt: DateTime.utc(2026, 6, 1),
      retentionSeconds: retention,
    );

Conversation _group({String role = 'owner'}) => Conversation(
      id: 'conv_1',
      kind: 'group',
      title: 'Family',
      currentRole: role,
      createdAt: DateTime.utc(2026, 6, 1),
    );

Future<void> _open(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    _app(ConversationDetailsScreen(state: state, conversationId: 'conv_1')),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a chat of two leads with the person and the three actions', (
    tester,
  ) async {
    final state = _state(_Api(), <Conversation>[_dm()]);
    await _open(tester, state);

    // Name first, and the page begins with it.
    expect(find.text('@alice'), findsWidgets);
    expect(find.byKey(const Key('details-mute')), findsOneWidget);
    expect(find.byKey(const Key('details-search')), findsOneWidget);
    expect(find.text(englishL10n.detailsActionMute), findsOneWidget);
    expect(find.text(englishL10n.chatListSearch), findsOneWidget);
    // The name sits above the actions, which sit above everything else.
    final nameTop = tester.getTopLeft(find.text('@alice').first).dy;
    final muteTop = tester.getTopLeft(find.byKey(const Key('details-mute'))).dy;
    final retentionTop =
        tester.getTopLeft(find.byKey(const Key('details-retention'))).dy;
    expect(nameTop, lessThan(muteTop));
    expect(muteTop, lessThan(retentionTop));
    // No call stack in this build: no Call.
    expect(find.byKey(const Key('details-call')), findsNothing);
  });

  testWidgets(
    'Call shows for a chat of two when calls exist, not for a group',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async => throw PlatformException(code: 'none'),
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'),
          null,
        ),
      );
      final log = <String>[];
      final incoming = StreamController<IncomingCallSignal>.broadcast();
      late CallController controller;
      await tester.runAsync(() async {
        controller = CallController(
          service: NativeCallService(
            api: FakeCallApi(log),
            token: 't',
            crypto: FakeCallCrypto(log),
            incoming: incoming.stream,
            media: FakeMediaFactory(log),
          ),
          selfAccountId: 'acct_me',
        );
      });
      addTearDown(controller.dispose);

      final dm = _state(_Api(), <Conversation>[_dm()]);
      dm.callController.value = controller;
      await _open(tester, dm);
      expect(find.byKey(const Key('details-call')), findsOneWidget);
      expect(find.text(englishL10n.detailsActionCall), findsOneWidget);

      final group = _state(_Api(), <Conversation>[_group()]);
      group.callController.value = controller;
      await _open(tester, group);
      expect(find.byKey(const Key('details-call')), findsNothing);
    },
  );

  testWidgets('the actions fit 320 dp at twice the text size', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state(_Api(), <Conversation>[_dm()]);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      _app(ConversationDetailsScreen(state: state, conversationId: 'conv_1')),
    );
    await tester.pumpAndSettle();
    // No overflow, and every action is still there to tap.
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('details-mute')), findsOneWidget);
    expect(find.byKey(const Key('details-search')), findsOneWidget);
    for (final key in const <Key>[Key('details-mute'), Key('details-search')]) {
      expect(tester.getSize(find.byKey(key)).width, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('Search opens the message search', (tester) async {
    final state = _state(_Api(), <Conversation>[_dm()]);
    await _open(tester, state);
    await tester.tap(find.byKey(const Key('details-search')));
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);
  });

  testWidgets('Mute opens the mute choices', (tester) async {
    final state = _state(_Api(), <Conversation>[_dm()]);
    await _open(tester, state);
    await tester.tap(find.byKey(const Key('details-mute')));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.muteEightHours), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('a chat of two shows no members and no roles', (tester) async {
    final api = _Api()
      ..members = <ConversationMember>[
        ConversationMember(accountId: 'acct_me', username: 'me', role: 'owner'),
        ConversationMember(
          accountId: 'acct_alice',
          username: 'alice',
          role: 'member',
        ),
      ];
    final state = _state(api, <Conversation>[_dm()]);
    await _open(tester, state);
    expect(
      find.text(englishL10n.detailsSectionMembers.toUpperCase()),
      findsNothing,
    );
    expect(find.text('@me'), findsNothing);
    expect(find.text('OWNER'), findsNothing);
    expect(find.text('MEMBER'), findsNothing);
    expect(find.byKey(const Key('roles-tile')), findsNothing);
  });

  testWidgets('a group keeps its members, roles and roles screen', (
    tester,
  ) async {
    final api = _Api()
      ..members = <ConversationMember>[
        ConversationMember(accountId: 'acct_me', username: 'me', role: 'owner'),
        ConversationMember(
          accountId: 'acct_alice',
          username: 'alice',
          role: 'member',
        ),
      ];
    final state = _state(api, <Conversation>[_group()]);
    await _open(tester, state);
    expect(find.text('Family'), findsWidgets);
    expect(find.text(englishL10n.conversationPrivateGroup), findsOneWidget);
    expect(
      find.text(englishL10n.detailsSectionMembers.toUpperCase()),
      findsOneWidget,
    );
    expect(find.text('@alice'), findsOneWidget);
    // U15: the role shows under the name, in words.
    expect(find.textContaining(englishL10n.roleOwner), findsOneWidget);
  });

  testWidgets('IDs and the membership note sit under Advanced', (tester) async {
    final state = _state(_Api(), <Conversation>[_dm()]);
    await _open(tester, state);

    // Last on the page, so scroll to it. Collapsed: neither the ID nor the
    // note is anywhere on the page.
    await tester.scrollUntilVisible(
      find.byKey(const Key('details-advanced')),
      300,
    );
    expect(find.text(englishL10n.detailsConversationIdLabel), findsNothing);
    expect(find.text(englishL10n.detailsMembershipNote), findsNothing);
    expect(find.text(shortId('conv_1')), findsNothing);

    await tester.tap(find.byKey(const Key('details-advanced')));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.detailsConversationIdLabel), findsOneWidget);
    expect(find.text(englishL10n.detailsMembershipNote), findsOneWidget);
  });

  group('disappearing messages', () {
    testWidgets('one row with the current value opens a sheet of timers', (
      tester,
    ) async {
      final state = _state(_Api(), <Conversation>[_dm(retention: 86400)]);
      await _open(tester, state);

      expect(find.byType(RadioListTile<int?>), findsNothing);
      expect(find.byKey(const Key('details-retention')), findsOneWidget);
      expect(find.text(englishL10n.detailsSectionDisappearing), findsOneWidget);
      expect(find.text('1 day'), findsOneWidget);

      await tester.tap(find.byKey(const Key('details-retention')));
      await tester.pumpAndSettle();
      expect(find.byType(RadioListTile<int?>), findsNWidgets(5));
      expect(find.byKey(const Key('retention-locked')), findsNothing);
      expect(find.text(englishL10n.detailsDisappearingNote), findsOneWidget);
    });

    testWidgets('choosing a timer confirms, then applies it', (tester) async {
      final api = _Api();
      final state = _state(api, <Conversation>[_dm()]);
      await _open(tester, state);

      await tester.tap(find.byKey(const Key('details-retention')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('7 days'));
      await tester.pumpAndSettle();
      // The sheet is gone and a confirmation asks first.
      expect(find.byType(RadioListTile<int?>), findsNothing);
      expect(api.retentionChanges, isEmpty);
      await tester.tap(find.text(englishL10n.detailsApply));
      await tester.pumpAndSettle();
      expect(api.retentionChanges, <int?>[604800]);
      expect(find.text('7 days'), findsOneWidget);
    });

    testWidgets('locked in a chat of two, the reason names no role', (
      tester,
    ) async {
      final state = _state(_Api(), <Conversation>[_dm(role: 'member')]);
      await _open(tester, state);
      await tester.tap(find.byKey(const Key('details-retention')));
      await tester.pumpAndSettle();
      expect(find.text(englishL10n.detailsRetentionLockedDm), findsOneWidget);
      expect(find.text(englishL10n.detailsRetentionLocked), findsNothing);
    });

    testWidgets('locked, the sheet says why and offers nothing to change', (
      tester,
    ) async {
      // A plain member cannot change the timer.
      final state = _state(_Api(), <Conversation>[_group(role: 'member')]);
      await _open(tester, state);

      await tester.tap(find.byKey(const Key('details-retention')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('retention-locked')), findsOneWidget);
      expect(find.text(englishL10n.detailsRetentionLocked), findsOneWidget);
      final tiles = tester.widgetList<RadioListTile<int?>>(
        find.byType(RadioListTile<int?>),
      );
      expect(tiles, hasLength(5));
      expect(tiles.every((tile) => tile.enabled == false), isTrue);
    });
  });
}
