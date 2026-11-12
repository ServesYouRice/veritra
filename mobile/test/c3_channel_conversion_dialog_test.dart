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
// channel private asks nothing.

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

  final conversions = <(String, bool)>[];

  @override
  Future<bool> convertChannel(Channel channel,
      {required bool toPrivate}) async {
    conversions.add((channel.id, toPrivate));
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
    expect(state.conversions, [('chan_private', false)]);
    // Converted: the settings it sat in close.
    expect(find.byType(ChannelConversionAction), findsNothing);
  });

  testWidgets('making an open channel private asks nothing', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    await _open(tester, state, _channel('open'));
    await tester.tap(find.text('Make this channel private'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(state.conversions, [('chan_open', true)]);
  });
}
