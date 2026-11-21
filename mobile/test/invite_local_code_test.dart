// The server keeps only a hash of each registration invite code and lists
// invites without one. The device that created an invite keeps its code in
// the encrypted local store, by invite id, so it can share the invite again;
// any other invite reads "Can't be shared again".
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/invite_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

/// A server that, like the real one, returns the code only when an invite is
/// created and lists invites without it.
class _HashingServer extends ApiClient {
  _HashingServer() : super(baseUrl: 'https://localhost');

  final List<Invite> live = <Invite>[];
  int _next = 0;

  /// When set, a list request waits for it before answering with the
  /// invites live when the request arrived.
  Completer<void>? holdList;

  @override
  Future<Invite> createInvite(
    String token, {
    int maxUses = 1,
    DateTime? expiresAt,
  }) async {
    _next++;
    final invite = Invite(
      id: 'inv_$_next',
      code: 'CODE${_next}ABCDEFGHIJKLMNOPQRSTU',
      maxUses: maxUses,
      uses: 0,
    );
    live.add(invite.withCode(''));
    return invite;
  }

  @override
  Future<List<Invite>> listInvites(String token) async {
    final snapshot = List<Invite>.of(live);
    final hold = holdList;
    if (hold != null) await hold.future;
    return snapshot;
  }

  @override
  Future<void> revokeInvite(String token, String inviteId) async {
    live.removeWhere((invite) => invite.id == inviteId);
  }
}

AppState _state(_HashingServer server, LocalStore store) {
  final state = AppState(
    apiClientFactory: (_) => server,
    cryptoService: TestOnlyCryptoService(),
    localStore: store,
    syncServiceFactory: (_, __) => _NoSync(),
  )
    ..api = server
    ..session = const Session(
      baseUrl: 'https://localhost',
      token: 'token',
      accountId: 'acct_admin',
      deviceId: 'dev_admin',
      role: 'admin',
    );
  addTearDown(state.dispose);
  return state;
}

Future<Map<String, Object?>> _stored(LocalStore store) async {
  final raw = await store.loadSetting(AppState.inviteCodesSetting);
  return raw == null
      ? <String, Object?>{}
      : Map<String, Object?>.from(jsonDecode(raw) as Map);
}

Future<void> _show(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: InviteScreen(state: state),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('a listed invite without a code decodes with an empty one', () {
    final invite = Invite.fromJson(<String, Object?>{
      'id': 'inv_1',
      'max_uses': 5,
      'uses': 2,
    });
    expect(invite.code, isEmpty);
    expect(invite.maxUses, 5);
  });

  testWidgets('a code created here survives a refresh and a restart', (
    tester,
  ) async {
    final server = _HashingServer();
    final store = MemoryLocalStore();
    final state = _state(server, store);

    final created = await state.createInvite(maxUses: 3);
    expect(created, isNotNull);
    expect(await _stored(store), <String, Object?>{created!.id: created.code});

    await state.refreshInvites();
    expect(state.invites.single.code, created.code);

    // A new app state over the same local store: the server still lists
    // the invite without its code; the local copy fills it in.
    final restarted = _state(server, store);
    await restarted.refreshInvites();
    expect(restarted.invites.single.id, created.id);
    expect(restarted.invites.single.code, created.code);

    await _show(tester, restarted);
    expect(find.text(created.code), findsOneWidget);
    expect(find.text(englishL10n.inviteCannotReshare), findsNothing);
    await tester.tap(find.byTooltip(englishL10n.inviteActions));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.inviteCopyLink), findsOneWidget);
  });

  testWidgets('an invite without a local code cannot be shared again', (
    tester,
  ) async {
    final server = _HashingServer();
    // Created on another device: this one never saw the code.
    await server.createInvite('token');
    final state = _state(server, MemoryLocalStore());

    await state.refreshInvites();
    expect(state.invites.single.code, isEmpty);

    await _show(tester, state);
    expect(find.text(englishL10n.inviteCannotReshare), findsOneWidget);
    await tester.tap(find.byTooltip(englishL10n.inviteActions));
    await tester.pumpAndSettle();
    expect(find.text(englishL10n.inviteCopyLink), findsNothing);
    expect(find.text(englishL10n.inviteCopyCode), findsNothing);
    expect(find.text(englishL10n.inviteTurnOff), findsOneWidget);
  });

  testWidgets('turning off, or the server dropping it, forgets the code', (
    tester,
  ) async {
    final server = _HashingServer();
    final store = MemoryLocalStore();
    final state = _state(server, store);
    final first = (await state.createInvite())!;
    final second = (await state.createInvite())!;

    await state.revokeInvite(first.id);
    expect((await _stored(store)).keys, <String>[second.id]);

    // Used up or expired elsewhere: no longer listed, so forgotten.
    server.live.clear();
    await state.refreshInvites();
    expect(await _stored(store), isEmpty);
    expect(state.invites, isEmpty);
  });

  testWidgets('a refresh in flight does not forget an invite made meanwhile', (
    tester,
  ) async {
    final server = _HashingServer();
    final store = MemoryLocalStore();
    final state = _state(server, store);

    server.holdList = Completer<void>();
    final refreshing = state.refreshInvites();
    await tester.pump();
    // Created after the list request left: the answer will not include it.
    final created = (await state.createInvite())!;
    server.holdList!.complete();
    await refreshing;

    expect(await _stored(store), <String, Object?>{created.id: created.code});
    // The next refresh lists it, with the code kept here.
    server.holdList = null;
    await state.refreshInvites();
    expect(state.invites.single.code, created.code);
  });
}
