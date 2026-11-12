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
  Future<List<ConversationMember>> channelReaders(Channel channel) => readers();

  @override
  Future<bool> convertChannel(Channel channel,
      {required bool toPrivate,
      List<String> members = const <String>[]}) async {
    conversions.add((channel.id, toPrivate, members.join(',')));
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
