import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/features/settings/recovery_key_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/ui/theme.dart';

import 'k0_recovery_fakes.dart';

/// K0 R5 review fixes: Stop against a poll in flight, a bare 404 keeps the
/// claim, a recovered device keeps the restored history, the leak warning
/// belongs to one account, an already-ended cancel says so, Cyrillic
/// look-alikes in a typed key, and the server's recovery address.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = englishL10n;
  late K0Server server;
  late MemoryLocalStore store;
  late K0Crypto crypto;
  late AppState state;

  setUp(() {
    server = K0Server();
    store = MemoryLocalStore();
    crypto = K0Crypto();
    state = k0App(server, store, crypto);
  });

  tearDown(() => state.dispose());

  Future<void> claim() async {
    final ok = await state.startAccountRecovery(
      baseUrl: k0Origin,
      username: 'alice',
      password: 'pw',
      recoveryKey: k0Display,
    );
    expect(ok, isTrue, reason: state.errorFor(Ops.accountRecovery));
  }

  Future<PendingAccountRecovery?> persisted() async =>
      PendingAccountRecovery.decode(
          await store.loadSetting('k0.pending_recovery'));

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(done(), isTrue);
  }

  const completed = AccountRecoveryStatus(
    phase: AccountRecoveryPhase.completed,
    accountId: 'acct_me',
    deviceId: 'dev_new',
    username: 'alice',
    role: 'member',
    token: 'tok_new',
  );

  group('N1 Stop while a poll is in flight', () {
    test('a completion that lands first is kept', () async {
      await claim();
      server.statusGate = Completer<void>();
      server.statusAnswers.add(completed);
      final poll = state.checkAccountRecovery();
      await until(() => server.recoveryPolls == 1);
      final stop = state.abandonAccountRecovery(requestId: 'arr_1');
      server.statusGate!.complete();
      expect(await poll, isTrue, reason: state.errorFor(Ops.accountRecovery));
      await stop;
      expect(state.session?.token, 'tok_new');
      expect(state.session?.deviceSecret, 'secret_new');
      expect(crypto.abandons, 0);
      expect(crypto.activated.last.deviceId, 'dev_new');
      expect((await store.loadSession())?.token, 'tok_new');
    });

    test('a waiting answer still lets Stop drop the claim', () async {
      await claim();
      server.statusGate = Completer<void>();
      final poll = state.checkAccountRecovery();
      await until(() => server.recoveryPolls == 1);
      final stop = state.abandonAccountRecovery(requestId: 'arr_1');
      server.statusGate!.complete();
      await poll;
      await stop;
      expect(state.pendingAccountRecovery, isNull);
      expect(await persisted(), isNull);
      expect(crypto.abandons, 1);
    });

    test('Stop for an older claim keeps the newer one', () async {
      await claim();
      await state.abandonAccountRecovery(requestId: 'arr_0');
      expect(state.pendingAccountRecovery?.requestId, 'arr_1');
      expect(crypto.abandons, 0);
    });
  });

  group('N2 which status errors end the claim', () {
    test('a 404 without this server\'s error body keeps the claim', () async {
      await claim();
      server.statusAnswers.add(ApiException(404, '<html>Not Found</html>'));
      expect(await state.checkAccountRecovery(), isFalse);
      expect(state.pendingAccountRecovery, isNotNull);
      expect(await persisted(), isNotNull);
      expect(crypto.abandons, 0);
    });

    test('the server\'s not_found ends it', () async {
      await claim();
      server.statusAnswers.add(k0Error(404, 'not_found'));
      expect(await state.checkAccountRecovery(), isFalse);
      expect(state.errorFor(Ops.accountRecovery), l10n.recoveryRequestEnded);
      expect(state.pendingAccountRecovery, isNull);
      expect(crypto.abandons, 1);
    });
  });

  group('N4 the leak warning belongs to one account', () {
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);

    Future<void> signIn() async {
      await store.saveSession(k0SignedIn);
      await state.tryRestoreSession();
    }

    test('another account\'s or an unscoped warning is not shown', () async {
      await store.saveSetting(
          'k0.password_leak_day', '$k0Origin\u0000acct_other\u0000$today');
      await signIn();
      await state.refreshRecoveryNotices();
      expect(state.passwordLeakWarningDay, isNull);

      await store.saveSetting('k0.password_leak_day', today);
      await state.refreshRecoveryNotices();
      expect(state.passwordLeakWarningDay, isNull);

      await store.saveSetting(
          'k0.password_leak_day', '$k0Origin\u0000acct_me\u0000$today');
      await state.refreshRecoveryNotices();
      expect(state.passwordLeakWarningDay, today);
    });

    test('a sync event is stored for the signed-in account', () async {
      server.events.add(SyncEvent(
          id: 1,
          type: 'account.password_leak_suspected',
          payload: <String, Object?>{'day': today},
          createdAt: DateTime.now().toUtc()));
      await signIn();
      for (var i = 0;
          i < 200 && await store.loadSetting('k0.password_leak_day') == null;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await store.loadSetting('k0.password_leak_day'),
          '$k0Origin\u0000acct_me\u0000$today');
    });
  });

  test('N6 cancelling a recovery that already ended says so', () async {
    await store.saveSession(k0SignedIn);
    await state.tryRestoreSession();
    server.recentAuth = true;
    server.cancelFailure = k0Error(410, 'recovery_cancelled');
    expect(await state.cancelAccountRecoveryRequest('arr_9'),
        RecoveryActionResult.alreadyEnded);
    server.cancelFailure = ApiException(404, 'proxy says no');
    expect(await state.cancelAccountRecoveryRequest('arr_9'),
        RecoveryActionResult.failed);
  });

  group('N7 Cyrillic look-alikes', () {
    test('become their Latin letters', () {
      // А В С Е Н К М О Р Т Х У Ѕ Ј І, upper and lower case.
      expect(
          normalizeRecoveryKeyInput('АВСЕ-НКМО '
              'РТХУЅЈІ'),
          'ABCEHKMOPTXYSJI');
      expect(
          normalizeRecoveryKeyInput('авсенк'
              'мортхуѕјі'),
          'ABCEHKMOPTXYSJI');
    });

    test('letters that read as digits or nothing Latin stay and fail', () {
      // З (3?), Д, Л, П, Ч, Г.
      const kept = 'ЗДЛПЧГ';
      expect(normalizeRecoveryKeyInput(kept), kept);
    });

    test('a key typed on a Cyrillic layout decodes', () async {
      // k0Display's first group ABCD with А В С in Cyrillic.
      final typed = 'АВСD${k0Display.substring(4)}';
      await store.saveSession(k0SignedIn);
      await state.tryRestoreSession();
      final draft = await state.createRecoveryKeyDraft();
      expect(await state.recoveryKeyMatches(draft, typed), isTrue);
      draft.dispose();
    });
  });

  group('server recovery address', () {
    Widget app(Widget home) =>
        MaterialApp(theme: veritraLightTheme(), home: home);

    AppState signedIn(String baseUrl) => k0App(server, store, crypto)
      ..session = Session(
          baseUrl: baseUrl,
          token: 'tok_old',
          accountId: 'acct_me',
          deviceId: 'dev_old',
          username: 'alice',
          deviceSecret: 'secret_old')
      ..api = K0Api(server, baseUrl);

    test('the status reads public_origin', () {
      final status = RecoveryKeyStatus.fromJson(<String, Object?>{
        'available': true,
        'configured': false,
        'public_origin': 'https://chat.example.org',
      });
      expect(status.publicOrigin, 'https://chat.example.org');
    });

    testWidgets('shown with the key, with no warning when it matches',
        (tester) async {
      server.status = const RecoveryKeyStatus(
          available: true, configured: false, publicOrigin: k0Origin);
      final screen = signedIn(k0Origin);
      await tester.pumpWidget(app(RecoveryKeyScreen(state: screen)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('recovery-origin-mismatch')),
          findsNothing);
      await tester.tap(find.text('Create a recovery key'));
      await tester.pumpAndSettle();
      final address = tester.widget<SelectableText>(
          find.byKey(const ValueKey<String>('recovery-server-address')));
      expect(address.data, k0Origin);
      screen.dispose();
    });

    testWidgets('another address warns and names the server\'s own',
        (tester) async {
      server.status = const RecoveryKeyStatus(
          available: true, configured: false, publicOrigin: k0Origin);
      final screen = signedIn('https://10.0.0.2:8443');
      await tester.pumpWidget(app(RecoveryKeyScreen(state: screen)));
      await tester.pumpAndSettle();
      expect(
          find.text(l10n.recoveryKeyOriginMismatch(
              'https://10.0.0.2:8443', k0Origin)),
          findsOneWidget);
      screen.dispose();
    });
  });

  group('N3 a recovered device keeps the restored history', () {
    late Directory directory;
    late List<EncryptedLocalDatabase> databases;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      directory = await Directory.systemTemp.createTemp('veritra-k0r5-');
      databases = <EncryptedLocalDatabase>[];
    });

    tearDown(() async {
      for (final database in databases) {
        await database.close();
      }
      await SecureLocalStore.releaseInstanceLocks();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    SecureLocalStore createStore(String namespace) => SecureLocalStore(
          storage: const FlutterSecureStorage(),
          directoryProvider: () async => directory,
          namespace: namespace,
          databaseFactory: (file, keyHex) {
            final database = openEncryptedLocalDatabase(file, keyHex);
            databases.add(database);
            return database;
          },
        );

    StoredCryptoState cryptoState(int counter) => StoredCryptoState(
        counter: counter,
        stateKey: List<int>.filled(32, 7),
        sealedState: utf8.encode('sealed'));

    test('completion over a restored backup keeps its messages', () async {
      final source = createStore('');
      await source.saveSession(k0SignedIn);
      await source.saveCryptoState(cryptoState(1), 10);
      await source.saveSnapshot(
          <Conversation>[Conversation(id: 'conv_1', kind: 'dm', title: 'Chat')],
          const <String, List<ReceivedMessageEnvelope>>{},
          10);
      await source.commitMlsTransition(MlsStateTransition(
        messageId: 'application:11:m1',
        conversationId: 'conv_1',
        expectedCounter: 1,
        expectedCursor: 10,
        state: cryptoState(2),
        cursor: 11,
        messageEffects: <MessageEffect>[
          InsertMessageEffect(
            key: 'dev_peer:m1',
            serverMessageId: 'm1',
            conversationId: 'conv_1',
            senderAccountId: 'acct_peer',
            senderDeviceId: 'dev_peer',
            kind: LocalMessageKind.text,
            body: 'hello',
            createdAt: DateTime.utc(2026, 10, 24).millisecondsSinceEpoch,
            state: LocalMessageState.received,
          ),
        ],
      ));
      final backup = await source.exportBackup();

      final target = createStore('recovered');
      await target.restoreBackup(backup);
      expect(isRestoredAccountSession((await target.loadSession())!), isTrue);

      final app = k0App(server, target, crypto);
      addTearDown(app.dispose);
      final ok = await app.startAccountRecovery(
        baseUrl: k0Origin,
        username: 'alice',
        password: 'pw',
        recoveryKey: k0Display,
      );
      expect(ok, isTrue, reason: app.errorFor(Ops.accountRecovery));
      server.statusAnswers.add(completed);
      expect(await app.checkAccountRecovery(), isTrue,
          reason: app.errorFor(Ops.accountRecovery));

      final session = (await target.loadSession())!;
      expect(session.deviceId, 'dev_new');
      expect(session.token, 'tok_new');
      expect((await target.loadMessages('conv_1')).single.body, 'hello');
    });
  });
}
