import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:private_messenger/features/communities/edit_info_dialog.dart';
import 'package:private_messenger/features/communities/community_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/crypto/community_info_codec.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'native_test_env.dart';

// Exercise the dialog through real encrypted-record writes and local storage.

const _session = Session(
    baseUrl: 'https://example.test',
    token: 'token',
    accountId: 'alice',
    deviceId: 'dev');

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Roles implements VerifiedRoleSource {
  _Roles(this.state);
  final GovernanceState? state;
  final asked = <String>[];
  @override
  GovernanceState? governanceOf(String conversationId) {
    asked.add(conversationId);
    return state;
  }

  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
}

/// Real record encryption with the messaging release gate still closed.
class _InfoCrypto extends UnavailableCryptoService
    implements CommunityInfoCryptoService {
  _InfoCrypto(this.bindings);
  final NativeCryptoBindings bindings;
  @override
  CommunityInfoCodec get communityInfoCodec => CommunityInfoCodec(bindings);
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');
  int puts = 0;
  bool fail = false;
  Completer<void>? pending;
  final putTokens = <String>[];
  void Function()? onPut;

  final records = <String, ({int version, String keyId, Uint8List blob})>{};

  @override
  Future<({int version, String keyId, Uint8List blob})?> getInfoRecord(
          String token,
          {required String kind,
          required String subjectId,
          String? communityId}) async =>
      records['$kind|$subjectId'];

  @override
  Future<int> putInfoRecord(String token,
      {required String kind,
      required String subjectId,
      String? communityId,
      required String keyId,
      required List<int> blob,
      required int expectedVersion}) async {
    puts++;
    await pending?.future;
    if (fail) throw ApiException(503, 'untrusted server text');
    putTokens.add(token);
    final version = expectedVersion + 1;
    records['$kind|$subjectId'] =
        (version: version, keyId: keyId, blob: Uint8List.fromList(blob));
    onPut?.call();
    return version;
  }
}

const _communityId = 'comm_11111111111111111111111111111111';
final _community = Community(
    id: _communityId, name: 'Club', sharedConversationId: 'conv_shared');
final _channel = Channel(
    id: 'chan_22222222222222222222222222222222',
    communityId: _communityId,
    name: 'Secret',
    kind: 'private',
    conversationId: 'conv_private',
    layoutGeneration: 1);

Future<({AppState state, _Api api})> _fixture() async {
  final api = _Api();
  final state = AppState(
      apiClientFactory: (_) => api,
      syncServiceFactory: (_, __) => _QuietSync(),
      localStore: MemoryLocalStore(),
      cryptoService:
          _InfoCrypto(NativeCryptoBindings.open(requireNativeCryptoLibrary())));
  state.session = _session;
  state.api = api;
  state.communities = [_community];
  state.channelsByCommunity = {
    _communityId: [_channel]
  };
  state.debugInfoRoleSource = _Roles(GovernanceState(
      rev: 1, owner: 'alice', ownerRev: 1, joined: const {'alice': 1}));
  expect(
      await state.publishCommunityInfo(_communityId, name: 'Club', mint: true),
      isTrue);
  expect(
      await state.publishChannelInfo(_channel,
          name: 'Secret', topic: 'Topic', mint: true),
      isTrue);
  api.puts = 0;
  return (state: state, api: api);
}

void main() {
  Future<void> open(WidgetTester tester, AppState state,
      {bool community = false}) async {
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showDialog<bool>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => EditInfoDialog(
                          state: state,
                          community: _community,
                          channel: community ? null : _channel)),
                  child: const Text('open')))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null;

  testWidgets(
      'failed encrypted save retains the draft and retries successfully',
      (tester) async {
    final f = await _fixture();
    await open(tester, f.state);
    await tester.enterText(find.byType(TextField).first, ' Renamed ');
    await tester.enterText(find.byType(TextField).last, ' New topic ');
    f.api.fail = true;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(EditInfoDialog), findsOneWidget);
    expect(find.text(' Renamed '), findsOneWidget);
    expect(find.text('untrusted server text'), findsNothing);
    expect(find.text('Could not save the info. Try again.'), findsOneWidget);
    expect(f.state.channelDisplayName(_channel), 'Secret');
    f.api.fail = false;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(EditInfoDialog), findsNothing);
    expect(f.state.channelDisplayName(_channel), 'Renamed');
    expect(f.state.channelTopic(_channel), 'New topic');
    expect(f.api.puts, 2);
    final stored = f.api.records['channel|${_channel.id}']!;
    final keys = await f.state.localStore.loadCommunityInfoEvents(
        CommunityInfoEventKind.key, 'channel', _channel.id);
    final record = CommunityInfoCodec(
            NativeCryptoBindings.open(requireNativeCryptoLibrary()))
        .open(
            key: keys.single.key!,
            servedKeyId: stored.keyId,
            servedVersion: stored.version,
            kind: 'channel',
            subjectId: _channel.id,
            blob: stored.blob);
    expect(record.name, 'Renamed');
    expect(record.topic, 'New topic');
  }, skip: nativeCryptoSkip() != false);

  testWidgets('blank and control text disable save; empty topic is valid',
      (tester) async {
    final f = await _fixture();
    await open(tester, f.state);
    for (final value in [' ', 'bad\u202ename']) {
      await tester.enterText(find.byType(TextField).first, value);
      await tester.pump();
      expect(saveEnabled(tester), isFalse);
    }
    await tester.enterText(find.byType(TextField).first, 'Valid');
    await tester.enterText(find.byType(TextField).last, '');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(f.state.channelTopic(_channel), isNull);
  }, skip: nativeCryptoSkip() != false);

  testWidgets('pending saves disable repeat submit and dismissal',
      (tester) async {
    final f = await _fixture();
    await open(tester, f.state);
    f.api.pending = Completer<void>();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(saveEnabled(tester), isFalse);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(EditInfoDialog), findsOneWidget);
    expect(f.api.puts, 1);
    f.api.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(EditInfoDialog), findsNothing);
  }, skip: nativeCryptoSkip() != false);

  testWidgets('cancel leaves the encrypted record unchanged', (tester) async {
    final f = await _fixture();
    await open(tester, f.state);
    await tester.enterText(find.byType(TextField).first, 'Discard');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(f.api.puts, 0);
    expect(f.state.channelDisplayName(_channel), 'Secret');
  }, skip: nativeCryptoSkip() != false);

  testWidgets('community editor uses the encrypted community record',
      (tester) async {
    final f = await _fixture();
    await open(tester, f.state, community: true);
    expect(find.text('Edit community'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'New club');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(f.api.puts, 1);
    expect(f.state.communityDisplayName(_community), 'New club');
    expect(_community.name, 'Club');
  }, skip: nativeCryptoSkip() != false);

  testWidgets('lost verified permission disables an open editor',
      (tester) async {
    final f = await _fixture();
    await open(tester, f.state, community: true);
    f.state.debugInfoRoleSource = _Roles(null);
    f.state.notifyListeners();
    await tester.pump();
    expect(saveEnabled(tester), isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(f.api.puts, 0);
  }, skip: nativeCryptoSkip() != false);

  testWidgets('a session change disables the old draft', (tester) async {
    final f = await _fixture();
    await open(tester, f.state);
    f.state.session = null;
    f.state.notifyListeners();
    await tester.pump();
    expect(saveEnabled(tester), isFalse);
    expect(f.api.puts, 0);
  }, skip: nativeCryptoSkip() != false);

  testWidgets('channel card opens the shared editor with its existing draft',
      (tester) async {
    final f = await _fixture();
    addTearDown(f.state.dispose);
    f.state.conversations = [
      Conversation(
          id: 'conv_private',
          kind: 'community_channel',
          communityId: _communityId,
          createdBy: 'alice'),
    ];
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommunityScreen(state: f.state)));
    await tester.tap(find.byTooltip('Edit channel'));
    await tester.pumpAndSettle();
    expect(find.byType(EditInfoDialog), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Secret');
    expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Topic');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(f.api.puts, 0);
  }, skip: nativeCryptoSkip() != false);

  testWidgets(
      'community card exposes editor only with verified admin permission',
      (tester) async {
    final f = await _fixture();
    addTearDown(f.state.dispose);
    await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommunityScreen(state: f.state)));
    expect(find.byTooltip('Edit community'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit community'));
    await tester.pumpAndSettle();
    expect(find.byType(EditInfoDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    f.state.debugInfoRoleSource = _Roles(GovernanceState(
        rev: 2, owner: 'bob', ownerRev: 1, joined: const {'alice': 1}));
    f.state.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit community'), findsNothing);
  }, skip: nativeCryptoSkip() != false);
}
