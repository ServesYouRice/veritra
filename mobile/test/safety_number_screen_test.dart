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

  group('leaving the screen', () {
    for (final fails in <bool>[false, true]) {
      testWidgets(
          'while a save is pending (${fails ? 'fails' : 'succeeds'}) '
          'causes no error', (tester) async {
        _phoneSizedView(tester);
        final store = _SlowStore()..failSave = fails;
        final state = _state(store, _FakeMls());
        await tester.pumpWidget(MaterialApp(
          home: SafetyNumberScreen(state: state, conversation: dm),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mark as verified'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('They match'));
        await tester.pump();
        expect(store.saves, 1);

        // The person leaves while the save is still running.
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        store.release.complete();
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('after scanning their code', () {
    const own = 'veritra-safety:v2:conv_dm:AAECAwQ';

    Future<void> openAndScan(
      WidgetTester tester,
      AppState state, {
      String scanned = own,
      Conversation? conversation,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: SafetyNumberScreen(
          state: state,
          conversation: conversation ?? dm,
          scanCode: (_) async => scanned,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan their code'));
      await tester.pumpAndSettle();
    }

    testWidgets('a verification that cannot be saved is not reported as done',
        (tester) async {
      _phoneSizedView(tester);
      final store = _SlowStore()
        ..failSave = true
        ..release.complete();
      await openAndScan(tester, _state(store, _FakeMls()));
      expect(find.text('The verification could not be saved. Try again.'),
          findsOneWidget);
      expect(find.text('The codes match. Marked as verified.'), findsNothing);
      expect(find.text('VERIFIED'), findsNothing);
    });

    testWidgets('a matching code is stored and reported', (tester) async {
      _phoneSizedView(tester);
      final mls = _FakeMls();
      final store = MemoryLocalStore();
      await openAndScan(tester, _state(store, mls));
      expect(find.text('The codes match. Marked as verified.'), findsOneWidget);
      expect(find.text('VERIFIED'), findsOneWidget);
      expect(await store.loadPeerVerification('conv_dm', 'acct_peer'),
          <int>[2, ...mls.hash]);
    });

    testWidgets('a number that changed after the match is not stored',
        (tester) async {
      _phoneSizedView(tester);
      // Read 1 loads the screen, read 2 checks the code, read 3 would store.
      final mls = _FakeMls()..flipAfter = 2;
      final store = MemoryLocalStore();
      await openAndScan(tester, _state(store, mls));
      expect(find.textContaining('changed while you were comparing'),
          findsOneWidget);
      expect(find.text('The codes match. Marked as verified.'), findsNothing);
      expect(await store.loadPeerVerification('conv_dm', 'acct_peer'), isNull);
    });

    testWidgets('a code for another number stores nothing', (tester) async {
      _phoneSizedView(tester);
      final store = MemoryLocalStore();
      await openAndScan(tester, _state(store, _FakeMls()),
          scanned: 'veritra-safety:v2:conv_dm:OTHER');
      expect(find.text('Codes do not match'), findsOneWidget);
      expect(await store.loadPeerVerification('conv_dm', 'acct_peer'), isNull);
    });

    testWidgets('a group only reports that the codes match', (tester) async {
      _phoneSizedView(tester);
      final store = MemoryLocalStore();
      await openAndScan(
        tester,
        _state(store, _FakeMls()),
        scanned: 'veritra-safety:v2:conv_group:AAECAwQ',
        conversation: Conversation(id: 'conv_group', kind: 'group'),
      );
      expect(find.text('The codes match.'), findsOneWidget);
      expect(find.text('The codes match. Marked as verified.'), findsNothing);
    });

    testWidgets('leaving during the save after a scan causes no error',
        (tester) async {
      _phoneSizedView(tester);
      final store = _SlowStore();
      final state = _state(store, _FakeMls());
      await tester.pumpWidget(MaterialApp(
        home: SafetyNumberScreen(
          state: state,
          conversation: dm,
          scanCode: (_) async => own,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan their code'));
      await tester.pump();
      await tester.pump();
      expect(store.saves, 1);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      store.release.complete();
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('a verification is bound to the number that was compared', () {
    testWidgets('a number that changed while confirming is not stored',
        (tester) async {
      _phoneSizedView(tester);
      final mls = _FakeMls();
      final store = MemoryLocalStore();
      await tester.pumpWidget(MaterialApp(
        home: SafetyNumberScreen(state: _state(store, mls), conversation: dm),
      ));
      await tester.pumpAndSettle();
      expect(find.text(_shown), findsOneWidget);

      await tester.tap(find.text('Mark as verified'));
      await tester.pumpAndSettle();
      // A device joins while the confirmation is open.
      mls.change();
      await tester.tap(find.text('They match'));
      await tester.pumpAndSettle();

      expect(await store.loadPeerVerification('conv_dm', 'acct_peer'), isNull,
          reason: 'nothing may be stored for a number nobody compared');
      expect(find.textContaining('changed while you were comparing'),
          findsOneWidget);
      expect(find.text('VERIFIED'), findsNothing);
    });

    testWidgets('an unchanged number is stored as compared', (tester) async {
      _phoneSizedView(tester);
      final mls = _FakeMls();
      final store = MemoryLocalStore();
      await tester.pumpWidget(MaterialApp(
        home: SafetyNumberScreen(state: _state(store, mls), conversation: dm),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as verified'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('They match'));
      await tester.pumpAndSettle();
      expect(await store.loadPeerVerification('conv_dm', 'acct_peer'),
          <int>[2, ...mls.hash]);
      expect(find.text('VERIFIED'), findsOneWidget);
    });

    test('the state refuses a compared code that is no longer current',
        () async {
      final mls = _FakeMls();
      final store = MemoryLocalStore();
      final state = _state(store, mls);
      final shown = (await state.conversationSafetyNumber('conv_dm')).qrPayload;
      mls.change();
      expect(
          await state.markPeerVerifiedIfMatches('conv_dm', 'acct_peer', shown),
          isFalse);
      expect(await store.loadPeerVerification('conv_dm', 'acct_peer'), isNull);

      final now = (await state.conversationSafetyNumber('conv_dm')).qrPayload;
      expect(
          await state.markPeerVerifiedIfMatches(
              'conv_dm', 'acct_peer', ' $now\n'),
          isTrue);
      expect(await store.loadPeerVerification('conv_dm', 'acct_peer'),
          <int>[2, ...mls.hash]);
    });
  });

  group('while the screen is open', () {
    testWidgets('a changed number and status replace the shown ones',
        (tester) async {
      _phoneSizedView(tester);
      final mls = _FakeMls();
      final store = MemoryLocalStore();
      await store
          .savePeerVerification('conv_dm', 'acct_peer', <int>[2, ...mls.hash]);
      final state = _state(store, mls) as _PokableState;
      await tester.pumpWidget(MaterialApp(
        home: SafetyNumberScreen(state: state, conversation: dm),
      ));
      await tester.pumpAndSettle();
      expect(find.text(_shown), findsOneWidget);
      expect(find.text('VERIFIED'), findsOneWidget);

      // A device is replaced: new number, so the stored verification is stale.
      mls.change();
      state.poke();
      await tester.pumpAndSettle();
      expect(find.text(_shown), findsNothing);
      expect(find.text(_shownLater), findsOneWidget);
      expect(find.text('CHANGED'), findsOneWidget);
      expect(find.text('Mark as verified'), findsOneWidget);
    });

    testWidgets('an older load cannot overwrite a newer one', (tester) async {
      _phoneSizedView(tester);
      final mls = _FakeMls();
      final state = _state(MemoryLocalStore(), mls) as _PokableState;
      await tester.pumpWidget(MaterialApp(
        home: SafetyNumberScreen(state: state, conversation: dm),
      ));
      await tester.pumpAndSettle();
      expect(find.text(_shown), findsOneWidget);

      // A reload starts and waits; it has already read the number as it is.
      mls.gate = Completer<void>();
      final older = mls.gate!;
      state.poke();
      await tester.pump();

      // The number changes. The person confirms the number they were looking
      // at; it is refused, and the load that follows reads the new number.
      mls
        ..gate = null
        ..change();
      await tester.tap(find.text('Mark as verified'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('They match'));
      await tester.pumpAndSettle();
      expect(find.text(_shownLater), findsOneWidget);

      // The older answer, from before the change, arrives last.
      older.complete();
      await tester.pumpAndSettle();
      expect(find.text(_shownLater), findsOneWidget);
      expect(find.text(_shown), findsNothing);
    });

    testWidgets('notifications do not pile up loads', (tester) async {
      _phoneSizedView(tester);
      final mls = _FakeMls();
      final state = _state(MemoryLocalStore(), mls) as _PokableState;
      await tester.pumpWidget(MaterialApp(
        home: SafetyNumberScreen(state: state, conversation: dm),
      ));
      await tester.pumpAndSettle();
      final before = mls.reads;
      mls.gate = Completer<void>();
      for (var i = 0; i < 20; i++) {
        state.poke();
      }
      await tester.pump();
      expect(mls.reads - before, 1, reason: 'one load in flight at a time');
      mls.gate!.complete();
      mls.gate = null;
      await tester.pumpAndSettle();
      expect(mls.reads - before, lessThanOrEqualTo(2));
    });

    testWidgets('leaving the screen stops listening', (tester) async {
      _phoneSizedView(tester);
      final mls = _FakeMls();
      final state = _state(MemoryLocalStore(), mls) as _PokableState;
      await tester.pumpWidget(MaterialApp(
        home: SafetyNumberScreen(state: state, conversation: dm),
      ));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final reads = mls.reads;
      state.poke();
      await tester.pumpAndSettle();
      expect(mls.reads, reads);
      expect(tester.takeException(), isNull);
    });
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

AppState _state(MemoryLocalStore store, _FakeMls mls) => _PokableState(
      apiClientFactory: (url) => ApiClient(baseUrl: url),
      cryptoService: mls,
      localStore: store,
      syncServiceFactory: (_, __) => _QuietSync(),
    );

/// An [AppState] a test can make announce a change.
class _PokableState extends AppState {
  _PokableState({
    required super.apiClientFactory,
    required super.cryptoService,
    required super.localStore,
    required super.syncServiceFactory,
  });

  void poke() => notifyListeners();
}

/// A store whose verification save waits for the test, then succeeds or fails.
class _SlowStore extends MemoryLocalStore {
  final Completer<void> release = Completer<void>();
  bool failSave = false;
  int saves = 0;

  @override
  Future<void> savePeerVerification(
      String conversationId, String peerAccountId, List<int> value) async {
    saves++;
    await release.future;
    if (failSave) throw StateError('disk full');
    await super.savePeerVerification(conversationId, peerAccountId, value);
  }
}

class _FakeMls implements MlsConversationCryptoService {
  List<int> hash = List<int>.generate(32, (index) => index);
  String digits = '0123456789' * 6;
  String code = 'AAECAwQ';
  bool fail = false;
  int reads = 0;

  /// After this many reads the number becomes [laterDigits] (a device joined
  /// between two steps of one flow).
  int? flipAfter;
  String laterDigits = '9876543210' * 6;

  /// While set, reads wait for it.
  Completer<void>? gate;

  void change({String? newDigits, String? newCode}) {
    digits = newDigits ?? '9876543210' * 6;
    code = newCode ?? 'ZZYXWVU';
    hash = List<int>.generate(32, (index) => 255 - index);
  }

  @override
  Future<ConversationSafetyNumber> conversationSafetyNumber(
      String conversationId) async {
    reads++;
    final waiting = gate;
    if (waiting != null) {
      // The number is read now; the answer arrives when the gate opens.
      final answer = ConversationSafetyNumber(
        digits: digits,
        transcriptHash: hash,
        qrPayload: 'veritra-safety:v2:$conversationId:$code',
      );
      await waiting.future;
      if (fail) throw StateError('group missing');
      return answer;
    }
    if (fail) throw StateError('group missing');
    if (flipAfter != null && reads > flipAfter!) {
      change(newDigits: laterDigits);
    }
    return ConversationSafetyNumber(
      digits: digits,
      transcriptHash: hash,
      qrPayload: 'veritra-safety:v2:$conversationId:$code',
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
  Future<void> dispose() => _controller.close();
}

/// How the fake's sixty digits appear: twelve groups of five, four a line.
const _shown = '01234 56789 01234 56789\n'
    '01234 56789 01234 56789\n'
    '01234 56789 01234 56789';

/// How the fake's digits read after [_FakeMls.change].
const _shownLater = '98765 43210 98765 43210\n'
    '98765 43210 98765 43210\n'
    '98765 43210 98765 43210';

/// A tall phone-width view, so the whole screen is built without scrolling.
void _phoneSizedView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4200);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}
