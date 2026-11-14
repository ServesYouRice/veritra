// U21: join with one invite link. A pasted link fills the server and the
// code; step 2 asks for name and password and shows Join without scrolling at
// 360 x 800; errors sit under their field and clear on edit; typing the
// address and code stays possible; "Confirm password" stays.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/account_invite_link.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/features/auth/connect_screen.dart';
import 'package:private_messenger/features/auth/qr_scan_screen.dart';
import 'package:private_messenger/features/settings/invite_screen.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';
import 'package:private_messenger/ui/theme.dart';

import 'test_crypto_service.dart';

const _origin = 'https://chat.example.org';
const _code = 'MFRGGZDFMZTWQ2LKNNWG23TPOA';
const _link = '$_origin/invite#v1.$_code';

void main() {
  Finder key(String value) => find.byKey(ValueKey<String>(value));

  /// The error text shown under the field with [fieldKey], if any.
  String? errorUnder(WidgetTester tester, Finder field) {
    final decorator = tester.widget<InputDecorator>(
        find.descendant(of: field, matching: find.byType(InputDecorator)));
    return decorator.decoration.errorText;
  }

  Future<_JoinState> openJoin(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final state = _JoinState();
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: veritraLightTheme(),
      home: ConnectScreen(state: state),
    ));
    await tester.pumpAndSettle();
    await tester.tap(key('welcome-invite'));
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> pasteLink(WidgetTester tester, String text) async {
    await tester.enterText(key('connect-invite-link'), text);
    await tester.tap(key('connect-join-continue'));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
  }

  Future<void> fillAccount(WidgetTester tester,
      {String name = 'alice', String password = 'correct-horse-1'}) async {
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), name);
    await tester.enterText(fields.at(1), password);
    await tester.enterText(fields.at(2), password);
    await tester.pump();
  }

  Future<void> join(WidgetTester tester) async {
    await tester.tap(key('connect-submit'));
    await tester.pumpAndSettle();
  }

  testWidgets('one pasted link fills the server and the code', (tester) async {
    final state = await openJoin(tester);
    expect(find.text('JOIN WITH AN INVITE'), findsOneWidget);
    await pasteLink(tester, '  $_link\n');

    // Step 2: the server named, then name, password and its confirmation.
    expect(find.text('Joining chat.example.org'), findsOneWidget);
    expect(find.text('CHOOSE A USERNAME AND PASSWORD'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(3));
    expect(find.text('CONFIRM PASSWORD'), findsOneWidget);
    expect(state.probes, <String>[_origin],
        reason: 'only the setup probe reaches the server before Join');

    await fillAccount(tester);
    await join(tester);
    expect(state.joins, <String>['$_origin|$_code|alice|correct-horse-1']);
  });

  testWidgets('a scanned link fills the server and the code', (tester) async {
    await openJoin(tester);
    await tester.tap(key('connect-invite-scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // The scanner pops with what the camera read.
    Navigator.of(tester.element(find.byType(QrScanScreen))).pop(_link);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('Joining chat.example.org'), findsOneWidget);
  });

  testWidgets('Join is visible without scrolling at 360 x 800', (tester) async {
    await openJoin(tester);
    await pasteLink(tester, _link);
    final submit = key('connect-submit');
    expect(submit.hitTestable(), findsOneWidget);
    final rect = tester.getRect(submit);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(800));
    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scrollable.position.pixels, 0);
  });

  testWidgets(
      'a link that is not an invitation: error under it, cleared on '
      'edit', (tester) async {
    final state = await openJoin(tester);
    await pasteLink(tester, '$_origin/join#v1.$_code');
    final field = key('connect-invite-link');
    expect(errorUnder(tester, field), englishL10n.connectInviteLinkInvalid);
    expect(find.text('CHOOSE A USERNAME AND PASSWORD'), findsNothing);
    expect(state.probes, isEmpty);

    await tester.enterText(field, '$_origin/invite#v1.');
    await tester.pump();
    expect(
        errorUnder(tester, field), isNot(englishL10n.connectInviteLinkInvalid));
  });

  testWidgets('a plain-HTTP link is refused outside demo builds',
      (tester) async {
    await openJoin(tester);
    await pasteLink(tester, 'http://chat.example.org/invite#v1.$_code');
    expect(errorUnder(tester, key('connect-invite-link')),
        englishL10n.connectInviteLinkInvalid);
  });

  testWidgets('typing the address and code by hand still works',
      (tester) async {
    final state = await openJoin(tester);
    await tester.tap(key('connect-invite-manual'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    // The code right after the address: the probe line that appears between
    // them must not take the code field's focus (it used to, by shifting the
    // list's children).
    await tester.enterText(fields.at(0), _origin);
    await tester.enterText(fields.at(1), 'TYPEDCODE123');
    await tester.tap(key('connect-join-continue'));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('Joining chat.example.org'), findsOneWidget);
    await fillAccount(tester);
    await join(tester);
    expect(
        state.joins, <String>['$_origin|TYPEDCODE123|alice|correct-horse-1']);
  });

  testWidgets('an invite the server refuses goes back under the link',
      (tester) async {
    final state = await openJoin(tester);
    state.answer = englishL10n.apiErrorInvalidInvite;
    await pasteLink(tester, _link);
    await fillAccount(tester);
    await join(tester);

    final field = key('connect-invite-link');
    expect(field, findsOneWidget, reason: 'back on step 1');
    expect(errorUnder(tester, field), englishL10n.apiErrorInvalidInvite);
    // Once, under its field: not again in the card.
    expect(find.text(englishL10n.apiErrorInvalidInvite), findsOneWidget);

    await tester.enterText(field, '$_link ');
    await tester.pump();
    expect(errorUnder(tester, field), isNull);
  });

  testWidgets('a password the server refuses sits under the password',
      (tester) async {
    final state = await openJoin(tester);
    state.answer = englishL10n.apiErrorWeakPassword;
    await pasteLink(tester, _link);
    await fillAccount(tester);
    await join(tester);

    final password = find.byType(TextFormField).at(1);
    expect(errorUnder(tester, password), englishL10n.apiErrorWeakPassword);
    expect(find.text(englishL10n.apiErrorWeakPassword), findsOneWidget);

    await tester.enterText(password, 'another-password-2');
    await tester.pump();
    expect(errorUnder(tester, password), isNull);
  });

  testWidgets('any other failure stays in the card', (tester) async {
    final state = await openJoin(tester);
    state.answer = englishL10n.errorUnreachable;
    await pasteLink(tester, _link);
    await fillAccount(tester);
    await join(tester);
    expect(find.text(englishL10n.errorUnreachable), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      expect(errorUnder(tester, find.byType(TextFormField).at(i)), isNull);
    }
  });

  testWidgets('a username the server would refuse is caught under its field',
      (tester) async {
    final state = await openJoin(tester);
    await pasteLink(tester, _link);
    await fillAccount(tester, name: 'al ice');
    await join(tester);
    expect(errorUnder(tester, find.byType(TextFormField).at(0)),
        englishL10n.connectUsernameInvalid);
    expect(state.joins, isEmpty);
  });

  testWidgets('Change and back return to step 1 with the link kept',
      (tester) async {
    await openJoin(tester);
    await pasteLink(tester, _link);
    await tester.tap(key('connect-join-change'));
    await tester.pumpAndSettle();
    expect(find.text(_link), findsOneWidget);
    await tester.tap(key('connect-join-continue'));
    await tester.pumpAndSettle();
    await tester.tap(key('connect-step-back'));
    await tester.pumpAndSettle();
    expect(key('connect-invite-link'), findsOneWidget);
    await tester.tap(key('connect-step-back'));
    await tester.pumpAndSettle();
    expect(find.text('I have an invite'), findsOneWidget);
  });

  testWidgets('both join steps meet the tap-target and contrast guidelines',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await openJoin(tester);
    Future<void> check() async {
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    }

    await check();
    await pasteLink(tester, _link);
    await check();
    semantics.dispose();
  });

  group('through the real registration path', () {
    // The screen places an error by its message, so these run the real
    // registerWithInvite (its _run and describeError) against a client that
    // answers as the server does.
    Future<void> joinAgainst(WidgetTester tester, String serverCode) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final state = AppState(
        apiClientFactory: (_) => _RefusingApi(serverCode),
        cryptoService: TestOnlyCryptoService(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => _QuietSync(),
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: veritraLightTheme(),
        home: ConnectScreen(state: state),
      ));
      await tester.pumpAndSettle();
      await tester.tap(key('welcome-invite'));
      await tester.pumpAndSettle();
      await pasteLink(tester, _link);
      await fillAccount(tester);
      await join(tester);
      expect(state.error, isNotNull);
    }

    testWidgets('400 invalid_invite lands under the link', (tester) async {
      await joinAgainst(tester, 'invalid_invite');
      expect(errorUnder(tester, key('connect-invite-link')),
          englishL10n.apiErrorInvalidInvite);
      expect(find.text(englishL10n.apiErrorInvalidInvite), findsOneWidget);
    });

    testWidgets('400 weak_password lands under the password', (tester) async {
      await joinAgainst(tester, 'weak_password');
      expect(errorUnder(tester, find.byType(TextFormField).at(1)),
          englishL10n.apiErrorWeakPassword);
      expect(find.text(englishL10n.apiErrorWeakPassword), findsOneWidget);
    });
  });

  group('the invitations page', () {
    testWidgets('copies the invitation as one link that the joiner reads back',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final state = AppState(
        apiClientFactory: (_) => ApiClient(baseUrl: _origin),
        cryptoService: TestOnlyCryptoService(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => _QuietSync(),
      )
        ..session = const Session(baseUrl: '$_origin/', token: 'token')
        ..invites = <Invite>[
          Invite(id: 'inv_1', code: _code, maxUses: 5, uses: 1),
        ]
        ..invitesLoaded = true;
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: veritraLightTheme(),
        home: InviteScreen(state: state),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(englishL10n.inviteActions));
      await tester.pumpAndSettle();
      expect(find.text(englishL10n.inviteCopyCode), findsOneWidget,
          reason: 'the bare code stays for typing');
      await tester.tap(key('invite-copy-link'));
      await tester.pumpAndSettle();
      expect(copied, _link);
      final read = AccountInviteLink.tryParse(copied!,
          transport: TransportPolicy.production)!;
      expect(read.origin, _origin);
      expect(read.code, _code);

      await tester.tap(find.byTooltip(englishL10n.inviteActions));
      await tester.pumpAndSettle();
      await tester.tap(key('invite-show-qr'));
      await tester.pumpAndSettle();
      expect(find.text(englishL10n.inviteQrTitle), findsOneWidget);
    });

    testWidgets('offers no link for a code that cannot travel in one',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(
        apiClientFactory: (_) => ApiClient(baseUrl: _origin),
        cryptoService: TestOnlyCryptoService(),
        localStore: MemoryLocalStore(),
        syncServiceFactory: (_, __) => _QuietSync(),
      )
        ..session = const Session(baseUrl: _origin, token: 'token')
        ..invites = <Invite>[
          Invite(id: 'inv_1', code: 'AB CD', maxUses: 5, uses: 1),
        ]
        ..invitesLoaded = true;
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: veritraLightTheme(),
        home: InviteScreen(state: state),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(englishL10n.inviteActions));
      await tester.pumpAndSettle();
      expect(key('invite-copy-link'), findsNothing);
      expect(find.text(englishL10n.inviteCopyCode), findsOneWidget);
    });
  });
}

/// A reachable server with users, on which this device has no identity. The
/// registration answers with [answer] as the app-wide error, or succeeds.
class _JoinState extends AppState {
  _JoinState()
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: _origin),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _QuietSync(),
        );

  final List<String> probes = <String>[];
  final List<String> joins = <String>[];
  String? answer;

  @override
  Future<SetupProbeResult> probeSetup(String baseUrl) async {
    probes.add(baseUrl);
    return const SetupProbeResult(
        state: SetupProbeState.reachable, setupRequired: false);
  }

  @override
  Future<bool> hasStoredDeviceIdentityForOrigin(String baseUrl) async => false;

  @override
  Future<void> registerWithInvite(String baseUrl, String inviteCode,
      String username, String password) async {
    joins.add('$baseUrl|$inviteCode|$username|$password');
    error = answer;
    notifyListeners();
  }
}

/// A server with users that refuses the registration with [code] (HTTP 400),
/// the way `POST /api/v1/register/enrollment` answers.
class _RefusingApi extends ApiClient {
  _RefusingApi(this.code) : super(baseUrl: _origin);

  final String code;

  @override
  Future<Map<String, Object?>> setupStatus() async =>
      <String, Object?>{'setup_required': false};

  @override
  Future<EnrollmentReservation> reserveRegistrationEnrollment(
      String inviteCode) async {
    throw ApiException(400, '{"error":"$code"}');
  }
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
