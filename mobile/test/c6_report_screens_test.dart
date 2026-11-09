import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/report_models.dart';
import 'package:private_messenger/core/report_seed_store.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/features/reports/owner_reports_screen.dart';
import 'package:private_messenger/features/reports/report_message_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// C6 step 4: the report screens. A stand-in for the report seal keeps these
/// widget tests off the native library (the real seal is exercised in
/// c6_reports_service_test.dart): the "sealed" bytes are the key then the
/// plaintext, which is enough for the screens to open what they filed.
class _FakeReportCrypto extends TestOnlyCryptoService
    implements ReportCryptoService {
  int seeds = 0;

  @override
  Future<Uint8List> generateReportKeySeed() async =>
      Uint8List.fromList(List<int>.filled(32, ++seeds));

  @override
  Future<Uint8List> reportPublicKey(Uint8List seed) async =>
      Uint8List.fromList(seed);

  @override
  Future<Uint8List> sealReport({
    required List<int> recipientPublicKey,
    required List<int> aad,
    required Uint8List plaintext,
  }) async =>
      Uint8List.fromList([...recipientPublicKey, ...plaintext]);

  @override
  Future<Uint8List> openReport({
    required Uint8List seed,
    required List<int> aad,
    required List<int> sealed,
  }) async =>
      Uint8List.fromList(sealed.sublist(32));

  @override
  Future<Uint8List> frankCommit({
    required Uint8List key,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Uint8List payload,
  }) async =>
      Uint8List.fromList(List<int>.filled(32, 4));
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');

  String kind = 'instance_owner';
  List<ReportInboxRecipient> recipients = [];
  final List<ReportCopyRow> rows = [];
  final List<List<int>> published = [];
  int filed = 0;

  @override
  Future<ReportInbox> getReportInbox(
          String token, String conversationId) async =>
      ReportInbox(kind: kind, recipients: recipients);

  @override
  Future<ReportInboxRecipient?> getOwnReportKey(String token) async =>
      published.isEmpty
          ? null
          : ReportInboxRecipient(
              inboxId: 'acct_me', publicKey: published.last, keyRev: 1);

  @override
  Future<int> putInstanceReportKey(String token, List<int> publicKey) async {
    published.add(publicKey);
    return 1;
  }

  @override
  Future<List<ReportCopyRow>> listOwnerReports(String token,
          {String? afterId, int limit = 50}) async =>
      rows;

  @override
  Future<void> createReport(
    String token, {
    required String conversationId,
    required String reportId,
    required List<Map<String, Object?>> copies,
  }) async {
    filed++;
  }
}

class _Sync implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() => _events.close();
}

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

({AppState state, _Api api, _Store store}) _harness({
  required String role,
  ReportCryptoService? crypto,
}) {
  final api = _Api();
  final store = _Store();
  final state = AppState(
    apiClientFactory: (_) => api,
    cryptoService: (crypto ?? _FakeReportCrypto()) as CryptoService,
    localStore: store,
    syncServiceFactory: (_, __) => _Sync(),
    reportSeedStore: MemoryReportSeedStore(),
  )
    ..api = api
    ..session = Session(
      baseUrl: 'https://example.test',
      token: 'acct_me',
      accountId: 'acct_me',
      deviceId: 'dev_current',
      username: 'me',
      role: role,
    );
  return (state: state, api: api, store: store);
}

class _Store extends MemoryLocalStore {
  FrankReveal? reveal;
  @override
  Future<FrankReveal?> loadFrankReveal(String messageKey) async =>
      reveal != null && reveal!.messageKey == messageKey ? reveal : null;
}

void main() {
  testWidgets('owner screen: no key, create it, community inbox unavailable',
      (tester) async {
    final h = _harness(role: 'owner');
    await tester.pumpWidget(_app(
        OwnerReportsScreen(state: h.state, reauthenticate: (_) async => true)));
    await tester.pumpAndSettle();

    expect(find.text('No reports'), findsOneWidget);
    expect(
        find.textContaining('This device has no report key'), findsOneWidget);
    expect(find.textContaining('Not available yet'), findsOneWidget);

    await tester.tap(find.text('Create report key'));
    await tester.pumpAndSettle();
    // The warning about replacing another device's key comes first.
    expect(find.text('Create a new report key here?'), findsOneWidget);
    expect(h.api.published, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Create report key'));
    await tester.pumpAndSettle();

    expect(h.api.published, hasLength(1));
    expect(find.textContaining('This device holds your report key'),
        findsOneWidget);
    expect(find.textContaining('Code: 0101-0101'), findsOneWidget);
  });

  testWidgets('owner screen: a refused reauthentication publishes nothing',
      (tester) async {
    final h = _harness(role: 'owner');
    await tester.pumpWidget(_app(OwnerReportsScreen(
        state: h.state, reauthenticate: (_) async => false)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create report key'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create report key'));
    await tester.pumpAndSettle();
    expect(h.api.published, isEmpty);
    expect(h.state.reportSeedStore, isA<MemoryReportSeedStore>());
    expect(
        await h.state.reportSeedStore.load('https://example.test', 'acct_me'),
        isNull);
  });

  testWidgets('report screen: community conversations are unavailable',
      (tester) async {
    final h = _harness(role: 'member');
    h.api.kind = 'community';
    await tester.pumpWidget(_app(ReportMessageScreen(
        state: h.state, conversationId: 'conv_1', messageKey: 'dev:a')));
    await tester.pumpAndSettle();
    expect(find.text('Reports to community moderators are not available yet.'),
        findsOneWidget);
    expect(find.text('Send report'), findsNothing);
    expect(h.api.filed, 0);
  });

  testWidgets('report screen: shows the key code, trusts it, then sends',
      (tester) async {
    final h = _harness(role: 'member');
    h.api.recipients = [
      ReportInboxRecipient(
          inboxId: 'acct_owner',
          publicKey: List<int>.filled(32, 0xab),
          keyRev: 1),
    ];
    h.store.reveal = FrankReveal(
      messageKey: 'dev_sender:a1',
      conversationId: 'conv_1',
      envelopeId: 'env_1',
      frankKey: List<int>.filled(32, 7),
      payload: utf8.encode('{"type":"text","body":{"text":"the exact words"}}'),
    );
    await tester.pumpWidget(_app(ReportMessageScreen(
        state: h.state,
        conversationId: 'conv_1',
        messageKey: 'dev_sender:a1')));
    await tester.pumpAndSettle();

    // What is sent is shown, and nothing is sent before the key is trusted.
    expect(find.text('the exact words'), findsOneWidget);
    expect(find.textContaining('ABAB-ABAB'), findsOneWidget);
    expect(find.text('Send report'), findsNothing);
    expect(h.api.filed, 0);

    await tester.tap(find.text('Trust and continue'));
    await tester.pumpAndSettle();
    expect(find.text('Send report'), findsOneWidget);
    expect(
        find.textContaining('Server owners who get a copy: 1'), findsOneWidget);

    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    expect(h.api.filed, 1);
    expect(find.text('Report sent.'), findsOneWidget);
  });

  testWidgets('report screen: a message with no proof is not reportable',
      (tester) async {
    final h = _harness(role: 'member');
    h.api.recipients = [
      ReportInboxRecipient(
          inboxId: 'acct_owner',
          publicKey: List<int>.filled(32, 0xab),
          keyRev: 1),
    ];
    await tester.pumpWidget(_app(ReportMessageScreen(
        state: h.state,
        conversationId: 'conv_1',
        messageKey: 'dev_sender:none')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trust and continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot be reported'), findsOneWidget);
    expect(h.api.filed, 0);
  });

  test('signing out deletes the report seed, and the warning knows of it',
      () async {
    final h = _harness(role: 'owner');
    expect(await h.state.holdsReportSeed(), isFalse);
    await h.state.reportSeedStore.save('https://example.test', 'acct_me',
        Uint8List.fromList(List<int>.filled(32, 3)));
    expect(await h.state.holdsReportSeed(), isTrue);
    await h.state.logout();
    expect(
        await h.state.reportSeedStore.load('https://example.test', 'acct_me'),
        isNull);
    expect(await h.state.holdsReportSeed(), isFalse);
  });

  test('a build without the reviewed engine offers no reporting', () {
    final locked = AppState(
      apiClientFactory: (_) => _Api(),
      cryptoService: UnavailableCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _Sync(),
    );
    expect(locked.reportsAvailable, isFalse);
    expect(locked.reportsService, isNull);
    final testOnly = AppState(
      apiClientFactory: (_) => _Api(),
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _Sync(),
    );
    expect(testOnly.reportsAvailable, isFalse);
  });
}
