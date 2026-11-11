import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/communities/create_channel_dialog.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

class _Sync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');
  late _State owner;
  @override
  Future<List<ConversationMember>> communityMembers(
      String token, String id) async {
    final members = await owner.roster();
    if (members == null) throw ApiException(503, '');
    return members;
  }
}

class _State extends AppState {
  _State() : this.withApi(_Api());
  _State.withApi(_Api client)
      : super(
          apiClientFactory: (_) => client,
          syncServiceFactory: (_, __) => _Sync(),
          localStore: MemoryLocalStore(),
          cryptoService: UnavailableCryptoService(),
        ) {
    api = client;
    client.owner = this;
    session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'alice',
        deviceId: 'device');
  }

  String role = 'owner';
  bool loadFails = false;
  bool createFails = false;
  int creates = 0;
  String? chosenKind;
  String? chosenName;
  final adds = <String>[];
  final failAdds = <String>{};
  Completer<void>? saving;

  Future<List<ConversationMember>?> roster() async => loadFails
      ? null
      : [
          ConversationMember(accountId: 'alice', role: role, username: 'Alice'),
          ConversationMember(accountId: 'bob', role: 'member', username: 'Bob'),
          ConversationMember(
              accountId: 'carol', role: 'member', username: 'Carol'),
        ];

  @override
  Future<Channel?> createChannel(String communityId, String name,
      {String? kind}) async {
    creates++;
    chosenKind = kind;
    chosenName = name;
    await saving?.future;
    return createFails
        ? null
        : Channel(
            id: 'channel',
            communityId: communityId,
            name: '',
            kind: kind!,
            conversationId: kind == 'private' ? 'private-group' : 'shared',
            layoutGeneration: 1);
  }

  @override
  Future<bool> addConversationMember(String conversationId, String accountId,
      {String role = 'member'}) async {
    expect(conversationId, 'private-group');
    adds.add(accountId);
    return !failAdds.contains(accountId);
  }
}

void main() {
  Future<void> open(WidgetTester tester, _State state,
      {bool legacy = false}) async {
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => CreateChannelDialog(
                state: state,
                community: Community(
                    id: 'community',
                    name: '',
                    sharedConversationId: legacy ? null : 'shared'),
              ),
            ),
            child: const Text('open'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('open is the shared layout default; it never adds selected peers',
      (tester) async {
    final state = _State();
    await open(tester, state);
    expect(find.text('Every community member can see this channel.'),
        findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.enterText(find.byType(TextField), ' general ');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(state.chosenKind, 'open');
    expect(state.chosenName, 'general');
    expect(state.adds, isEmpty);
    expect(find.byType(CreateChannelDialog), findsNothing);
  });

  testWidgets('private picker excludes self and adds only selected members',
      (tester) async {
    final state = _State();
    await open(tester, state);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('The server can see who is in it.'),
        findsOneWidget);
    expect(find.text('Alice'), findsNothing);
    await tester.tap(find.text('Bob'));
    await tester.enterText(find.byType(TextField), 'private');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(state.chosenKind, 'private');
    expect(state.adds, ['bob']);
    expect(state.creates, 1);
  });

  testWidgets(
      'partial add retries failed peers without creating a second channel',
      (tester) async {
    final state = _State()..failAdds.add('carol');
    await open(tester, state);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob'));
    await tester.tap(find.text('Carol'));
    await tester.enterText(find.byType(TextField), 'private');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Some members could not be added.'),
        findsOneWidget);
    state.failAdds.clear();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(state.creates, 1);
    expect(state.adds, ['bob', 'carol', 'carol']);
    expect(find.byType(CreateChannelDialog), findsNothing);
  });

  testWidgets('failed roster can be retried; moderators cannot create',
      (tester) async {
    final state = _State()..loadFails = true;
    await open(tester, state);
    await tester.enterText(find.byType(TextField), 'general');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    state
      ..loadFails = false
      ..role = 'moderator';
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Only owners and admins can create channels.'),
        findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(state.creates, 0);
  });

  testWidgets(
      'saving disables submission and cancel; create errors keep the form',
      (tester) async {
    final state = _State()
      ..createFails = true
      ..saving = Completer<void>();
    await open(tester, state);
    await tester.enterText(find.byType(TextField), 'general');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull);
    state.saving!.complete();
    await tester.pumpAndSettle();
    expect(
        find.text('Could not create the channel. Try again.'), findsOneWidget);
    expect(find.text('general'), findsOneWidget);
    expect(state.adds, isEmpty);
  });

  testWidgets(
      'a session ending during creation prevents subsequent member adds',
      (tester) async {
    final state = _State()..saving = Completer<void>();
    await open(tester, state);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob'));
    await tester.enterText(find.byType(TextField), 'private');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pump();
    state.session = null;
    state.saving!.complete();
    await tester.pumpAndSettle();
    expect(state.creates, 1);
    expect(state.adds, isEmpty);
  });
}
