import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/communities/channel_conversion.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

// Owner answer 2026-11-12 (C3 conversion): earlier posts carry into the
// new channel, so making a private channel open asks first and says they
// become visible to everyone who can read the open channel. Making an open
// channel private lists its readers, all ticked; the admin unticks whoever
// should not stay, and only the ticked are passed on to be added (owner
// answer 2026-11-12, "Admin picks during switch").

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _State extends AppState {
  _State()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://example.test'),
          syncServiceFactory: (_, __) => _Sync(),
          localStore: MemoryLocalStore(),
          cryptoService: UnavailableCryptoService(),
        );

  final conversions = <(String, bool, String)>[];

  /// Channel history on, and the channel's setting as this device holds
  /// it.
  var c7 = true;
  C7ChannelView? view =
      const C7ChannelView(full: true, status: 'ok', pending: false);

  @override
  bool get channelHistoryAvailable => c7;

  @override
  Future<C7ChannelView?> channelHistory(Channel channel) async => view;
  var refuse = <String>[];
  var readerLoads = 0;
  Future<List<ConversationMember>> Function() readers =
      () async => <ConversationMember>[
            ConversationMember(
                accountId: 'acct_bob', role: 'member', username: 'bob'),
            ConversationMember(
                accountId: 'acct_carol', role: 'member', username: 'carol'),
            ConversationMember(
                accountId: 'acct_dave', role: 'member', username: 'dave'),
          ];

  @override
  Future<List<ConversationMember>> channelReaders(Channel channel) {
    readerLoads++;
    return readers();
  }

  @override
  Future<bool> convertChannel(Channel channel,
      {required bool toPrivate,
      List<String> members = const <String>[],
      String? requestId}) async {
    conversions.add((channel.id, toPrivate, members.join(',')));
    channelConversionNotAdded = <String>[
      for (final member in members)
        if (refuse.contains(member)) member,
    ];
    return true;
  }
}

Channel _channel(String kind) => Channel(
    id: 'chan_$kind',
    communityId: 'community',
    name: '',
    kind: kind,
    conversationId: kind == 'private' ? 'conv_private' : 'conv_shared',
    layoutGeneration: 1);

/// The action inside a dialog, as in the channel's settings.
Future<void> _open(WidgetTester tester, _State state, Channel channel) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
                content:
                    ChannelConversionAction(state: state, channel: channel)),
          ),
          child: const Text('settings'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('settings'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'making a private channel open warns that earlier posts become '
      'visible; cancelling converts nothing', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await _open(tester, state, _channel('private'));
    await tester.tap(find.text('Make this channel open'));
    await tester.pumpAndSettle();
    expect(find.text('Make this channel open?'), findsOneWidget);
    expect(
        find.textContaining('Earlier posts in this channel will become '
            'visible to everyone who can read the open channel'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.conversions, isEmpty);
    expect(find.byType(ChannelConversionAction), findsOneWidget);
    await tester.tap(find.text('Make this channel open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make open'));
    await tester.pumpAndSettle();
    expect(state.conversions, [('chan_private', false, '')]);
    // Converted: the settings it sat in close.
    expect(find.byType(ChannelConversionAction), findsNothing);
  });

  for (final (name, c7, view, open) in <(String, bool, C7ChannelView?, bool)>[
    (
      'its full history',
      true,
      const C7ChannelView(full: true, status: 'ok', pending: false),
      true
    ),
    ('channel history off', false, null, false),
    (
      'a channel that keeps posts from each join',
      true,
      const C7ChannelView(full: false, status: 'ok', pending: false),
      false
    ),
    (
      'its setting changing',
      true,
      const C7ChannelView(full: false, status: 'ok', pending: true),
      true
    ),
    ('its setting unknown', true, null, true),
  ]) {
    testWidgets(
        'the warning before making a private channel open says whether its '
        'earlier posts open for everyone: $name (review INFO)', (tester) async {
      final state = _State()
        ..c7 = c7
        ..view = view;
      addTearDown(state.dispose);
      await _open(tester, state, _channel('private'));
      await tester.tap(find.text('Make this channel open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('will become visible to everyone'),
          open ? findsOneWidget : findsNothing);
      expect(find.textContaining('stay with the people who already had them'),
          open ? findsNothing : findsOneWidget);
    });
  }

  testWidgets(
      'making an open channel private lists its readers all ticked; only '
      'the ones left ticked are added', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await _open(tester, state, _channel('open'));
    await tester.tap(find.text('Make this channel private'));
    await tester.pumpAndSettle();
    expect(find.text('Make this channel private?'), findsOneWidget);
    final boxes = find.byType(CheckboxListTile);
    expect(boxes, findsNWidgets(3));
    for (final name in ['@bob', '@carol', '@dave']) {
      final tile = find.widgetWithText(CheckboxListTile, name);
      expect(tester.widget<CheckboxListTile>(tile).value, isTrue);
    }
    await tester.tap(find.text('@carol'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, '@carol'))
            .value,
        isFalse);
    await tester.tap(find.text('Make private'));
    await tester.pumpAndSettle();
    expect(state.conversions, [('chan_open', true, 'acct_bob,acct_dave')]);
    expect(find.byType(ChannelConversionAction), findsNothing);
  });

  testWidgets(
      'ticked readers the server refused are named before the settings '
      'close', (tester) async {
    final state = _State()..refuse = <String>['acct_dave'];
    addTearDown(state.dispose);
    await _open(tester, state, _channel('open'));
    await tester.tap(find.text('Make this channel private'));
    await tester.pumpAndSettle();
    expect(state.readerLoads, 1);
    await tester.tap(find.text('Make private'));
    await tester.pumpAndSettle();
    expect(state.conversions,
        [('chan_open', true, 'acct_bob,acct_carol,acct_dave')]);
    expect(find.byType(ChannelConversionAction), findsNothing);
    expect(find.textContaining('could not be added: @dave.'), findsOneWidget);
  });

  testWidgets('cancelling the reader list converts nothing', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await _open(tester, state, _channel('open'));
    await tester.tap(find.text('Make this channel private'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.conversions, isEmpty);
    expect(find.byType(ChannelConversionAction), findsOneWidget);
  });

  testWidgets(
      'a reader list that fails to load cannot be accepted as an empty one',
      (tester) async {
    final state = _State()..readers = () async => throw StateError('down');
    addTearDown(state.dispose);
    await _open(tester, state, _channel('open'));
    await tester.tap(find.text('Make this channel private'));
    await tester.pumpAndSettle();
    expect(find.text("Could not load who reads this channel. Try again."),
        findsOneWidget);
    await tester.tap(find.text('Make private'));
    await tester.pumpAndSettle();
    expect(state.conversions, isEmpty);
  });
}
