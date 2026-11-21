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
import 'package:private_messenger/core/reports_service.dart' show OpenedReport;
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/franking.dart'
    show reportInboxInstanceOwner;
import 'package:private_messenger/crypto/owner_key_watch.dart';
import 'package:private_messenger/crypto/owner_proof_pins.dart';
import 'package:private_messenger/crypto/report_body.dart';
import 'package:private_messenger/crypto/report_key_pins.dart';
import 'package:private_messenger/features/reports/owner_reports_screen.dart';
import 'package:private_messenger/features/reports/report_message_screen.dart';
import 'package:private_messenger/l10n/app_localizations.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/widgets/tile_group.dart';

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

  /// The copies of the last report filed, as the server would get them.
  List<Map<String, Object?>> lastCopies = const [];

  @override
  Future<ReportInbox> getReportInbox(
    String token,
    String conversationId,
  ) async =>
      ReportInbox(kind: kind, recipients: recipients);

  @override
  Future<ReportInboxRecipient?> getOwnReportKey(String token) async =>
      published.isEmpty
          ? null
          : ReportInboxRecipient(
              inboxId: 'acct_me',
              publicKey: published.last,
              keyRev: 1,
            );

  /// The expectation each publish carried (compare-and-swap).
  final List<List<int>?> expectations = [];

  @override
  Future<int> putInstanceReportKey(
    String token,
    List<int> publicKey, {
    required List<int>? expected,
  }) async {
    expectations.add(expected);
    // The server's rule: the same key again is a no-op; otherwise the
    // listed key must be the expected one (none when null).
    final current = published.isEmpty ? null : published.last;
    if (current != null && _eq(current, publicKey)) return 1;
    final matches = expected == null
        ? current == null
        : current != null && _eq(current, expected);
    if (!matches) throw ApiException(409, '{"error":"report_key_changed"}');
    published.add(publicKey);
    return 1;
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<List<ReportCopyRow>> listOwnerReports(
    String token, {
    String? afterId,
    int limit = 50,
  }) async =>
      rows;

  /// What the server's record of an envelope answers; null is "gone" (404).
  ReportEnvelopeRecord? record;

  @override
  Future<ReportEnvelopeRecord> getReportEnvelope(
    String token,
    String reportId,
    String envelopeId,
  ) async {
    final found = record;
    if (found == null) throw ApiException(404, '{"error":"not_found"}');
    return found;
  }

  @override
  Future<void> createReport(
    String token, {
    required String conversationId,
    required String reportId,
    required List<Map<String, Object?>> copies,
  }) async {
    filed++;
    lastCopies = copies;
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
  testWidgets('owner screen: no key, create it, community inbox unavailable', (
    tester,
  ) async {
    final h = _harness(role: 'owner');
    await tester.pumpWidget(
      _app(
        OwnerReportsScreen(state: h.state, reauthenticate: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No reports'), findsOneWidget);
    expect(
      find.textContaining('This device has no report key'),
      findsOneWidget,
    );
    // Community reports go to each community's moderators (C6, one sealed
    // copy per verified moderator), not to this inbox.
    expect(
      find.text(
        'Reports about a community go to its moderators. '
        'A moderator opens them from the community.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Create report key'));
    await tester.pumpAndSettle();
    // The warning about replacing another device's key comes first.
    expect(find.text('Create a new report key here?'), findsOneWidget);
    expect(h.api.published, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Create report key'));
    await tester.pumpAndSettle();

    expect(h.api.published, hasLength(1));
    expect(
      find.textContaining('This device holds your report key'),
      findsOneWidget,
    );
    expect(find.textContaining('Code: 0101-0101'), findsOneWidget);
  });

  testWidgets(
      'owner screen: a key another device published meanwhile is not '
      'overwritten; the screen reloads it', (tester) async {
    final h = _harness(role: 'owner');
    await tester.pumpWidget(
      _app(
        OwnerReportsScreen(state: h.state, reauthenticate: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This device has no report key'),
      findsOneWidget,
    );
    // Another device of the account publishes its key after this screen
    // loaded, while the person is deciding.
    final other = List<int>.filled(32, 9);
    h.api.published.add(other);

    await tester.tap(find.text('Create report key'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create report key'));
    await tester.pumpAndSettle();

    // The publish expected "no key" (what the person saw) and was refused:
    // the other device's key stays, this device keeps no seed for a key the
    // server never listed, and the screen shows the key listed now.
    expect(h.api.expectations, [null]);
    expect(h.api.published, [other]);
    expect(
      await h.state.reportSeedStore.load('https://example.test', 'acct_me'),
      isNull,
    );
    expect(
      find.text(
        'Another device changed your report key while you were deciding. '
        'Nothing was changed here. Check the key below and choose again.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Your report key is held on another device'),
      findsOneWidget,
    );
    expect(find.textContaining('Code: 0909-0909'), findsOneWidget);

    // Deciding again from what is listed now replaces it, expecting it.
    await tester.pump(const Duration(seconds: 5)); // The notice goes away.
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create report key'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Replace key'));
    await tester.pumpAndSettle();
    expect(h.api.expectations.last, other);
    expect(h.api.published, hasLength(2));
    expect(
      find.textContaining('This device holds your report key'),
      findsOneWidget,
    );
  });

  testWidgets('owner screen: a refused reauthentication publishes nothing', (
    tester,
  ) async {
    final h = _harness(role: 'owner');
    await tester.pumpWidget(
      _app(
        OwnerReportsScreen(state: h.state, reauthenticate: (_) async => false),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create report key'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create report key'));
    await tester.pumpAndSettle();
    expect(h.api.published, isEmpty);
    expect(h.state.reportSeedStore, isA<MemoryReportSeedStore>());
    expect(
      await h.state.reportSeedStore.load('https://example.test', 'acct_me'),
      isNull,
    );
  });

  testWidgets('report screen: community conversations are unavailable', (
    tester,
  ) async {
    final h = _harness(role: 'member');
    h.api.kind = 'community';
    await tester.pumpWidget(
      _app(
        ReportMessageScreen(
          state: h.state,
          conversationId: 'conv_1',
          messageKey: 'dev:a',
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Without a verified role record (C4) the app cannot tell who the
    // moderators are, so nothing can be sealed.
    expect(
      find.text(
        'This community has no verified roles, so the app can\'t '
        'tell who its moderators are.',
      ),
      findsOneWidget,
    );
    expect(find.text('Send report'), findsNothing);
    expect(h.api.filed, 0);
  });

  testWidgets('report screen: shows the key code, trusts it, then sends', (
    tester,
  ) async {
    _tallView(tester);
    final h = _harness(role: 'member');
    h.api.recipients = [
      ReportInboxRecipient(
        inboxId: 'acct_owner',
        publicKey: List<int>.filled(32, 0xab),
        keyRev: 1,
      ),
    ];
    h.store.reveal = FrankReveal(
      messageKey: 'dev_sender:a1',
      conversationId: 'conv_1',
      envelopeId: 'env_1',
      frankKey: List<int>.filled(32, 7),
      payload: utf8.encode('{"type":"text","body":{"text":"the exact words"}}'),
    );
    await tester.pumpWidget(
      _app(
        ReportMessageScreen(
          state: h.state,
          conversationId: 'conv_1',
          messageKey: 'dev_sender:a1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // What is sent is shown, and nothing is sent before the key is trusted.
    expect(find.text('the exact words'), findsOneWidget);
    expect(find.textContaining('ABAB-ABAB'), findsOneWidget);
    expect(find.text('Send report'), findsNothing);
    expect(h.api.filed, 0);

    // U33: the reason is chosen first and survives the reload that trusting
    // a key causes.
    expect(find.text('Why are you reporting it?'), findsOneWidget);
    await _tapVisible(tester, find.text('Harassment or bullying'));
    await _tapVisible(tester, find.text('Trust and continue'));
    expect(find.text('Send report'), findsOneWidget);
    expect(
      find.textContaining('Server owners who get a copy: 1'),
      findsOneWidget,
    );
    expect(_selectedReason(tester), ReportReason.harassment);

    await _tapVisible(tester, find.text('Send report'));
    expect(h.api.filed, 1);
    expect(find.text('Report sent.'), findsOneWidget);
    // The body sealed in the copy is v3 and carries the chosen reason.
    final body = _filedBody(h.api);
    expect(body.reason, ReportReason.harassment);
    expect(body.envelopeId, 'env_1');
  });

  // U33: the form offers a fixed list of reasons, and Send waits for one.
  testWidgets('report screen: send waits for a reason from the fixed list', (
    tester,
  ) async {
    _tallView(tester);
    final h = _harness(role: 'member');
    final key = List<int>.filled(32, 0xab);
    h.api.recipients = [
      ReportInboxRecipient(inboxId: 'acct_owner', publicKey: key, keyRev: 1),
    ];
    // Already trusted, so Send shows at once.
    await tester.runAsync(
      () => h.state.reportsService!.pins.pin(
        ReportRecipientKey(inboxId: 'acct_owner', publicKey: key, keyRev: 1),
      ),
    );
    h.store.reveal = FrankReveal(
      messageKey: 'dev_sender:a1',
      conversationId: 'conv_1',
      envelopeId: 'env_1',
      frankKey: List<int>.filled(32, 7),
      payload: utf8.encode('{"type":"text","body":{"text":"the exact words"}}'),
    );
    await tester.pumpWidget(
      _app(
        ReportMessageScreen(
          state: h.state,
          conversationId: 'conv_1',
          messageKey: 'dev_sender:a1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in [
      'Spam or scam',
      'Harassment or bullying',
      'Hate speech',
      'Threats or violence',
      'Sexual content',
      'Puts a child at risk',
      'Self-harm or suicide',
      "Shares someone's private information",
      'Something else',
    ]) {
      await tester.ensureVisible(find.text(label));
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // No free-text field.
    expect(find.byType(TextField), findsNothing);
    final send = find.widgetWithText(FilledButton, 'Send report');
    await tester.ensureVisible(send);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(h.api.filed, 0);

    await _tapVisible(tester, find.text('Something else'));
    await _tapVisible(tester, find.text('Spam or scam'));
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    await _tapVisible(tester, send);
    expect(h.api.filed, 1);
    expect(_filedBody(h.api).reason, ReportReason.spam);
  });

  // L2-3, owner decision 2026-11-12 ("Keep reports manual"): a key pinned
  // on first use for sealed-message proofs does not skip the comparison.
  testWidgets('report screen: a key pinned on first use still shows the code', (
    tester,
  ) async {
    _tallView(tester);
    final h = _harness(role: 'member');
    final key = List<int>.filled(32, 0xab);
    h.api.recipients = [
      ReportInboxRecipient(inboxId: 'acct_owner', publicKey: key, keyRev: 1),
    ];
    h.store.reveal = FrankReveal(
      messageKey: 'dev_sender:a1',
      conversationId: 'conv_1',
      envelopeId: 'env_1',
      frankKey: List<int>.filled(32, 7),
      payload: utf8.encode('{"type":"text","body":{"text":"the exact words"}}'),
    );
    await tester.runAsync(() async {
      expect(
        await OwnerKeyWatch(h.store, 'https://example.test').observe(
          ReportInbox(
            kind: reportInboxInstanceOwner,
            recipients: h.api.recipients,
          ),
        ),
        isTrue,
      );
      expect(
        (await OwnerProofPins(
          h.store,
          'https://example.test',
        ).effective())
            .single
            .publicKey,
        key,
      );
    });
    await tester.pumpWidget(
      _app(
        ReportMessageScreen(
          state: h.state,
          conversationId: 'conv_1',
          messageKey: 'dev_sender:a1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('ABAB-ABAB'), findsOneWidget);
    expect(find.text('Trust and continue'), findsOneWidget);
    expect(find.text('Send report'), findsNothing);
    expect(h.api.filed, 0);

    await _tapVisible(tester, find.text('Trust and continue'));
    await _tapVisible(tester, find.text('Hate speech'));
    await _tapVisible(tester, find.text('Send report'));
    expect(h.api.filed, 1);
  });

  testWidgets('report screen: a message with no proof is not reportable', (
    tester,
  ) async {
    _tallView(tester);
    final h = _harness(role: 'member');
    h.api.recipients = [
      ReportInboxRecipient(
        inboxId: 'acct_owner',
        publicKey: List<int>.filled(32, 0xab),
        keyRev: 1,
      ),
    ];
    await tester.pumpWidget(
      _app(
        ReportMessageScreen(
          state: h.state,
          conversationId: 'conv_1',
          messageKey: 'dev_sender:none',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('Trust and continue'));
    await _tapVisible(tester, find.text('Something else'));
    await _tapVisible(tester, find.text('Send report'));
    expect(find.textContaining('cannot be reported'), findsOneWidget);
    expect(h.api.filed, 0);
  });

  test(
    'signing out deletes the report seed, and the warning knows of it',
    () async {
      final h = _harness(role: 'owner');
      expect(await h.state.holdsReportSeed(), isFalse);
      await h.state.reportSeedStore.save(
        'https://example.test',
        'acct_me',
        Uint8List.fromList(List<int>.filled(32, 3)),
      );
      expect(await h.state.holdsReportSeed(), isTrue);
      await h.state.logout();
      expect(
        await h.state.reportSeedStore.load('https://example.test', 'acct_me'),
        isNull,
      );
      expect(await h.state.holdsReportSeed(), isFalse);
    },
  );

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

  // U33 / U8: the inbox leads with the reports, has the 16 dp gutter and
  // names the reporter.
  testWidgets('owner inbox: reports first, 16 dp gutter, reporter in the row', (
    tester,
  ) async {
    final h = _harness(role: 'owner');
    h.api.rows.add(_row());
    await tester.pumpWidget(
      _app(
        OwnerReportsScreen(state: h.state, reauthenticate: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();

    final reports = tester.getTopLeft(find.text('REPORTS')).dy;
    final key = tester.getTopLeft(find.text('REPORT KEY')).dy;
    expect(reports, lessThan(key), reason: 'the inbox leads with reports');
    expect(find.textContaining('Reported by '), findsOneWidget);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final box in tester.elementList(find.byType(TileGroup))) {
      final rect = tester.getRect(find.byElementPredicate((e) => e == box));
      expect(rect.left, 16);
      expect(rect.right, width - 16);
    }
  });

  // U33: names, the channel, a plain verdict with "Why not certain?" and the
  // next step beside Dismiss. The wording never claims more than C6.
  testWidgets('report detail: names, verdict, why not certain, next step', (
    tester,
  ) async {
    final h = _harness(role: 'owner');
    h.state.conversations = <Conversation>[
      Conversation(id: 'conv_1', kind: 'group', title: 'Team'),
    ];
    final service = h.state.reportsService!;
    await tester.pumpWidget(
      _app(
        OwnerReportDetailScreen(
          service: service,
          state: h.state,
          report: _opened(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Reported by '), findsOneWidget);
    expect(find.text('In Team'), findsOneWidget);
    expect(find.text('the exact words'), findsOneWidget);
    // Before the check, the next step sits beside Dismiss.
    final dismiss = find.byKey(const Key('report-dismiss'));
    final next = find.byKey(const Key('report-next-check'));
    expect(tester.getCenter(dismiss).dy, tester.getCenter(next).dy);

    // The server no longer has the message: the verdict is plain, and
    // "Why not certain?" holds the careful wording.
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('Cannot be checked'), findsOneWidget);
    expect(find.text('Why not certain?'), findsOneWidget);
    expect(find.textContaining('only as trustworthy'), findsNothing);
    await tester.ensureVisible(find.text('Why not certain?'));
    await tester.tap(find.text('Why not certain?'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no longer has this message'), findsOneWidget);
    expect(
      find.textContaining('only as trustworthy as that record'),
      findsOneWidget,
    );
    // A gone record proves nothing either way, so the report is not called
    // unbacked. The next step is gone, Dismiss stays.
    expect(
      find.text('Nothing here backs this report up. You can dismiss it.'),
      findsNothing,
    );
    expect(find.byKey(const Key('report-next-copy')), findsNothing);
    expect(dismiss, findsOneWidget);
  });

  // U33: only a record that contradicts the report says nothing backs it up.
  testWidgets('report detail: a mismatch says nothing backs the report up', (
    tester,
  ) async {
    final h = _harness(role: 'owner');
    h.api.record = ReportEnvelopeRecord(
      envelopeId: 'env_1',
      conversationId: 'conv_1',
      senderAccountId: 'acct_sender',
      senderDeviceId: 'dev_sender',
      frankCommit: List<int>.filled(32, 1),
      createdAt: DateTime.utc(2026, 11, 7),
    );
    await tester.pumpWidget(
      _app(
        OwnerReportDetailScreen(
          service: h.state.reportsService!,
          state: h.state,
          report: _opened(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('report-next-check')));
    await tester.pumpAndSettle();
    expect(
      find.text('Nothing here backs this report up. You can dismiss it.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('report-next-copy')), findsNothing);
    expect(find.byKey(const Key('report-dismiss')), findsOneWidget);
  });

  // U33: the inbox shows the reporter's reason, opened through the real
  // open and decode path, and says the check does not cover it. A body
  // written before reasons (literal v1 bytes) still opens.
  testWidgets('owner inbox: shows the reason, and an old body has none', (
    tester,
  ) async {
    final h = _harness(role: 'owner');
    await tester.runAsync(
      () => h.state.reportSeedStore.save(
        'https://example.test',
        'acct_me',
        Uint8List.fromList(List<int>.filled(32, 1)),
      ),
    );
    final v3 = ReportBody(
      envelopeId: 'env_1',
      conversationId: 'conv_1',
      senderDeviceId: 'dev_sender',
      actionId: 'a1',
      payload: utf8.encode('{"type":"text","body":{"text":"new words"}}'),
      frankKey: List<int>.filled(32, 7),
      reason: ReportReason.privateInfo,
    ).encode();
    final v1 = utf8.encode(
      '{"v":1,"envelope_id":"env_2",'
      '"conversation_id":"conv_1","sender_device_id":"dev_sender",'
      '"action_id":"a2","payload":"${base64Encode(utf8.encode('{"type":"text","body":{"text":"old words"}}'))}",'
      '"frank_key":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="}',
    );
    h.api.rows
      ..add(_sealedRow('row_new', v3))
      ..add(_sealedRow('row_old', v1));
    await tester.pumpWidget(
      _app(
        OwnerReportsScreen(state: h.state, reauthenticate: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();

    // The row leads its second line with the reason.
    expect(
      find.textContaining(
        "Reporter's reason: Shares someone's private information\n",
      ),
      findsOneWidget,
    );
    expect(find.text('old words'), findsOneWidget);

    await tester.tap(find.text('new words'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Reason given by the reporter: Shares someone's private "
        'information',
      ),
      findsOneWidget,
    );
    expect(
      find.text('The check covers the message only, not the reason.'),
      findsOneWidget,
    );
    // The reason sits with the reporter, above the message and the verdict.
    expect(
      tester.getTopLeft(find.byKey(const Key('report-reason'))).dy,
      lessThan(tester.getTopLeft(find.text('new words')).dy),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('old words'));
    await tester.pumpAndSettle();
    expect(
      find.text('No reason given. Reports from older app versions carry none.'),
      findsOneWidget,
    );
    expect(
      find.text('The check covers the message only, not the reason.'),
      findsNothing,
    );
  });

  // U33: a v3 body naming a reason outside the list is refused whole, never
  // shown with a guessed reason.
  testWidgets('owner inbox: an unknown reason makes the report unreadable', (
    tester,
  ) async {
    final h = _harness(role: 'owner');
    await tester.runAsync(
      () => h.state.reportSeedStore.save(
        'https://example.test',
        'acct_me',
        Uint8List.fromList(List<int>.filled(32, 1)),
      ),
    );
    final good = jsonDecode(
      utf8.decode(
        ReportBody(
          envelopeId: 'env_1',
          conversationId: 'conv_1',
          senderDeviceId: 'dev_sender',
          actionId: 'a1',
          payload: utf8.encode(
            '{"type":"text","body":{"text":"new words"}}',
          ),
          frankKey: List<int>.filled(32, 7),
          reason: ReportReason.spam,
        ).encode(),
      ),
    ) as Map<String, Object?>;
    h.api.rows.add(
      _sealedRow('row_bad', utf8.encode(jsonEncode({...good, 'reason': 10}))),
    );
    await tester.pumpWidget(
      _app(
        OwnerReportsScreen(state: h.state, reauthenticate: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('new words'), findsNothing);
    expect(find.text('Cannot open'), findsOneWidget);
    await tester.tap(find.text('Cannot open'));
    await tester.pumpAndSettle();
    expect(
      find.text('This report is damaged or was not meant for you.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('report-reason')), findsNothing);
  });
}

/// A view tall enough that the report form (intro, preview, key codes, the
/// nine reasons and Send) is built in one piece.
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Scrolls [finder] into view, taps it and settles.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The reason the report form's radio group holds now.
ReportReason? _selectedReason(WidgetTester tester) => tester
    .widget<RadioGroup<ReportReason>>(find.byType(RadioGroup<ReportReason>))
    .groupValue;

/// The body sealed in the first copy of the last report the fake server
/// got: [_FakeReportCrypto] "seals" as the 32-byte key then the plaintext.
ReportBody _filedBody(_Api api) {
  final sealed = base64Decode(api.lastCopies.first['sealed']! as String);
  return ReportBody.decode(sealed.sublist(32));
}

/// A copy for this owner (`acct_me`, key 32 x 1) that the fake seal opens to
/// [plaintext].
ReportCopyRow _sealedRow(String id, List<int> plaintext) => ReportCopyRow(
      id: id,
      reportId: 'rep_$id',
      inboxKind: 'instance_owner',
      inboxId: 'acct_me',
      keyRev: 1,
      recipientPublicKey: List<int>.filled(32, 1),
      conversationId: 'conv_1',
      reporterAccountId: 'acct_reporter',
      sealed: <int>[...List<int>.filled(32, 1), ...plaintext],
      createdAt: DateTime.utc(2026, 11, 7),
    );

ReportCopyRow _row() => ReportCopyRow(
      id: 'row_1',
      reportId: 'rep_1',
      inboxKind: 'instance_owner',
      inboxId: 'acct_me',
      keyRev: 1,
      recipientPublicKey: List<int>.filled(32, 1),
      conversationId: 'conv_1',
      reporterAccountId: 'acct_reporter',
      sealed: List<int>.filled(40, 2),
      createdAt: DateTime.utc(2026, 11, 7),
    );

OpenedReport _opened() => OpenedReport(
      _row(),
      body: ReportBody(
        envelopeId: 'env_1',
        conversationId: 'conv_1',
        senderDeviceId: 'dev_sender',
        actionId: 'a1',
        payload:
            utf8.encode('{"type":"text","body":{"text":"the exact words"}}'),
        frankKey: List<int>.filled(32, 7),
      ),
      text: 'the exact words',
    );
