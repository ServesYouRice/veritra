import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/chat/safety_number_screen.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

/// Stage 1: conversation safety-number display and confirmation (demo builds).
void main() {
  final dm = Conversation(
    id: 'conv_dm',
    kind: 'dm',
    peerAccountId: 'acct_peer',
    peerUsername: 'sam',
  );

  testWidgets('a DM number is shown grouped and can be marked verified',
      (tester) async {
    _phoneSizedView(tester);
    final mls = _FakeMls();
    final store = MemoryLocalStore();
    final state = _state(store, mls);
    expect(state.safetyNumbersAvailable, isTrue);

    await tester.pumpWidget(MaterialApp(
      home: SafetyNumberScreen(state: state, conversation: dm),
    ));
    await tester.pumpAndSettle();
    expect(find.text(_shown), findsOneWidget);
    expect(find.text('NOT VERIFIED'), findsOneWidget);
    expect(
        find.textContaining('Compare this number with @sam'), findsOneWidget);

    await tester.tap(find.text('Mark as verified'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    expect(find.text('VERIFIED'), findsOneWidget);
    expect(find.text('Mark as verified'), findsNothing);
    expect(await store.loadPeerVerification('conv_dm', 'acct_peer'),
        <int>[2, ...mls.hash]);
  });

  testWidgets('cancelling the confirmation leaves the DM unverified',
      (tester) async {
    _phoneSizedView(tester);
    final store = MemoryLocalStore();
    final state = _state(store, _FakeMls());
    await tester.pumpWidget(MaterialApp(
      home: SafetyNumberScreen(state: state, conversation: dm),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as verified'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('NOT VERIFIED'), findsOneWidget);
    expect(await store.loadPeerVerification('conv_dm', 'acct_peer'), isNull);
  });

  testWidgets('a number that changed after verification says so',
      (tester) async {
    _phoneSizedView(tester);
    final mls = _FakeMls();
    final store = MemoryLocalStore();
    await store.savePeerVerification(
        'conv_dm', 'acct_peer', <int>[2, ...List<int>.filled(32, 9)]);
    await tester.pumpWidget(MaterialApp(
      home: SafetyNumberScreen(state: _state(store, mls), conversation: dm),
    ));
    await tester.pumpAndSettle();
    expect(find.text('CHANGED'), findsOneWidget);
    expect(find.textContaining('replaced since you verified'), findsOneWidget);
    expect(find.text('Mark as verified'), findsOneWidget);
  });

  testWidgets('a verification made under another version is not trusted',
      (tester) async {
    _phoneSizedView(tester);
    final mls = _FakeMls();
    final store = MemoryLocalStore();
    // Same hash, but tagged with the epoch-bound version 1 derivation.
    await store
        .savePeerVerification('conv_dm', 'acct_peer', <int>[1, ...mls.hash]);
    await tester.pumpWidget(MaterialApp(
      home: SafetyNumberScreen(state: _state(store, mls), conversation: dm),
    ));
    await tester.pumpAndSettle();
    expect(find.text('NOT VERIFIED'), findsOneWidget);
    expect(find.text('CHANGED'), findsNothing);
  });

  testWidgets('a group shows the shared number without a per-peer status',
      (tester) async {
    _phoneSizedView(tester);
    await tester.pumpWidget(MaterialApp(
      home: SafetyNumberScreen(
        state: _state(MemoryLocalStore(), _FakeMls()),
        conversation: Conversation(id: 'conv_group', kind: 'group'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(_shown), findsOneWidget);
    expect(find.textContaining('Every member of this group'), findsOneWidget);
    expect(find.text('Mark as verified'), findsNothing);
    expect(find.text('NOT VERIFIED'), findsNothing);
  });

  testWidgets('a group state that cannot be read offers a retry',
      (tester) async {
    _phoneSizedView(tester);
    final mls = _FakeMls()..fail = true;
    await tester.pumpWidget(MaterialApp(
      home: SafetyNumberScreen(
          state: _state(MemoryLocalStore(), mls), conversation: dm),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Safety number unavailable'), findsOneWidget);

    mls.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text(_shown), findsOneWidget);
  });

  test('only the exact safety code of this conversation matches', () async {
    final state = _state(MemoryLocalStore(), _FakeMls());
    final own = (await state.conversationSafetyNumber('conv_dm')).qrPayload;
    expect(await state.safetyCodeMatches('conv_dm', own), isTrue);
    expect(await state.safetyCodeMatches('conv_dm', ' $own\n'), isTrue);
    expect(await state.safetyCodeMatches('conv_dm', '${own}x'), isFalse);
    expect(
        await state.safetyCodeMatches(
            'conv_dm', own.replaceFirst('conv_dm', 'conv_other')),
        isFalse);
    expect(await state.safetyCodeMatches('conv_dm', ''), isFalse);
  });
}

AppState _state(MemoryLocalStore store, _FakeMls mls) => AppState(
      apiClientFactory: (url) => ApiClient(baseUrl: url),
      cryptoService: mls,
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
    );

class _FakeMls implements MlsConversationCryptoService {
  final List<int> hash = List<int>.generate(32, (index) => index);
  bool fail = false;

  @override
  Future<ConversationSafetyNumber> conversationSafetyNumber(
      String conversationId) async {
    if (fail) throw StateError('group missing');
    return ConversationSafetyNumber(
      digits: '0123456789' * 6,
      transcriptHash: hash,
      qrPayload: 'veritra-safety:v2:$conversationId:AAECAwQ',
    );
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  void dispose() => _controller.close();
}

/// How the fake's sixty digits appear: twelve groups of five, four a line.
const _shown = '01234 56789 01234 56789\n'
    '01234 56789 01234 56789\n'
    '01234 56789 01234 56789';

/// A tall phone-width view, so the whole screen is built without scrolling.
void _phoneSizedView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4200);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}
