// B7 S3: passkeys on the phone (docs/designs/B7-passkeys.md). A fake
// PasskeyClient stands in for the platform; the JSON shapes come from the Go
// server tests (test/fixtures/api/v1/passkeys.json).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passkeys/types.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/passkeys.dart';

import 'b7_passkey_fakes.dart';

Future<void> _settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('condition not reached');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  androidBuildTests();

  group('the server answer shapes', () {
    test('setup status names the passkey settings', () {
      final info =
          PasskeyServerInfo.fromStatus(pkMap(pkFixture()['setup_status']))!;
      expect(info.rpId, 'chat.example.com');
      expect(info.android, isTrue);
      expect(info.apple, isTrue);
    });

    test('a missing or malformed passkeys object means no passkeys', () {
      expect(PasskeyServerInfo.fromStatus(<String, Object?>{}), isNull);
      for (final bad in <Object?>[
        'x',
        <String, Object?>{'rp_id': '', 'android': true, 'apple': true},
        <String, Object?>{
          'rp_id': 'a.example',
          'android': 'yes',
          'apple': true
        },
        <String, Object?>{'rp_id': 'a.example'},
      ]) {
        expect(PasskeyServerInfo.fromStatus(<String, Object?>{'passkeys': bad}),
            isNull);
      }
    });

    test('the plugin parses the server\'s options as they are', () {
      final reg = pkMap(pkMap(pkFixture()['register_options'])['public_key']);
      final request = RegisterRequestType.fromJson(reg);
      expect(request.relyingParty.id, 'chat.example.com');
      expect(request.user.name, 'owner');
      expect(request.pubKeyCredParams, hasLength(3));
      final login = pkMap(pkMap(pkFixture()['login_options'])['public_key']);
      final auth = AuthenticateRequestType.fromJson(login);
      expect(auth.relyingPartyId, 'chat.example.com');
      expect(auth.allowCredentials, hasLength(1));
    });

    test('a passkey row parses, a null last use included', () {
      final rows = (pkMap(pkFixture()['list'])['passkeys'] as List);
      final record = PasskeyRecord.tryParse(rows.single)!;
      expect(record.name, 'Passkey 1');
      expect(record.lastUsedAt, isNull);
      expect(record.synced, isFalse);
      expect(PasskeyRecord.tryParse(<String, Object?>{'id': 'x'}), isNull);
      expect(PasskeyRecord.tryParse('x'), isNull);
    });

    test('the API client speaks the documented routes', () async {
      HttpOverrides.global = null;
      final requests = <String>[];
      final bodies = <Object?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final fixture = pkFixture();
      server.listen((request) async {
        final text = await utf8.decoder.bind(request).join();
        requests.add('${request.method} ${request.uri.path}');
        bodies.add(text.isEmpty ? null : jsonDecode(text));
        final path = request.uri.path;
        Object? answer;
        if (path == '/api/v1/auth/passkey/options') {
          answer = fixture['login_options'];
        } else if (path == '/api/v1/auth/passkey') {
          answer = fixture['login'];
        } else if (path == '/api/v1/account/passkeys/options') {
          answer = fixture['register_options'];
        } else if (path == '/api/v1/account/passkeys' &&
            request.method == 'POST') {
          answer = fixture['register_response'];
        } else if (path == '/api/v1/account/passkeys') {
          answer = fixture['list'];
        }
        request.response.headers.contentType = ContentType.json;
        if (answer == null) {
          request.response.statusCode = 204;
        } else {
          request.response.write(jsonEncode(answer));
        }
        await request.response.close();
      });
      final client =
          ApiClient(baseUrl: 'http://${server.address.address}:${server.port}');
      addTearDown(client.close);

      final options = await client.passkeyLoginOptions(
          deviceId: 'dev_1', deviceSecret: 'secret');
      expect(options.id, isNotEmpty);
      expect(options.publicKey['rpId'], 'chat.example.com');
      final session = await client.passkeyLogin(
        ceremonyId: options.id,
        deviceId: 'dev_1',
        deviceSecret: 'secret',
        credential: <String, Object?>{'id': 'c'},
        fallbackUsername: 'owner',
      );
      expect(session.token, 'token-from-passkey');
      expect(session.username, 'owner');
      expect(session.deviceSecret, 'secret');
      expect((await client.passkeys('tok')).single.name, 'Passkey 1');
      final reg = await client.passkeyRegisterOptions('tok');
      expect(reg.publicKey['rp'], isA<Map>());
      expect(
          await client.passkeyRegister('tok',
              ceremonyId: reg.id, name: 'P', credential: <String, Object?>{}),
          startsWith('pk_'));
      await client.renamePasskey('tok', 'pk_a/b', 'New');
      await client.deletePasskey('tok', 'pk_a');
      expect(requests, <String>[
        'POST /api/v1/auth/passkey/options',
        'POST /api/v1/auth/passkey',
        'GET /api/v1/account/passkeys',
        'POST /api/v1/account/passkeys/options',
        'POST /api/v1/account/passkeys',
        'PATCH /api/v1/account/passkeys/pk_a%2Fb',
        'DELETE /api/v1/account/passkeys/pk_a',
      ]);
      // No username goes to the sign-in routes.
      expect((bodies[0] as Map).keys, <String>['device_id', 'device_secret']);
      expect((bodies[1] as Map).keys,
          <String>['ceremony_id', 'device_id', 'device_secret', 'credential']);
    });
  });

  group('where the button shows', () {
    bool offered(PasskeyPlatform p,
            {PasskeyServerInfo? info = pkInfo,
            String host = 'chat.example.com',
            List<String> domains = const <String>[]}) =>
        passkeysOffered(
            platform: p, info: info, serverHost: host, appleDomains: domains);

    test('Linux and other platforms never', () {
      expect(offered(PasskeyPlatform.linux), isFalse);
      expect(offered(PasskeyPlatform.other), isFalse);
    });

    test('a server without passkeys, or for another host, never', () {
      expect(offered(PasskeyPlatform.android, info: null), isFalse);
      expect(
          offered(PasskeyPlatform.android, host: 'other.example.com'), isFalse);
    });

    test('Android needs the operator\'s Android list', () {
      expect(offered(PasskeyPlatform.android), isTrue);
      expect(
          offered(PasskeyPlatform.android,
              info: const PasskeyServerInfo(
                  rpId: 'chat.example.com', android: false, apple: true)),
          isFalse);
    });

    test('Apple platforms need the operator\'s list and a compiled-in host',
        () {
      expect(offered(PasskeyPlatform.ios), isFalse);
      expect(offered(PasskeyPlatform.ios, domains: <String>['a.example']),
          isFalse);
      expect(
          offered(PasskeyPlatform.ios, domains: <String>['chat.example.com']),
          isTrue);
      expect(
          offered(PasskeyPlatform.macos, domains: <String>['chat.example.com']),
          isTrue);
      expect(
          offered(PasskeyPlatform.ios,
              info: const PasskeyServerInfo(
                  rpId: 'chat.example.com', android: true, apple: false),
              domains: <String>['chat.example.com']),
          isFalse);
    });

    test('Windows needs nothing more', () {
      expect(offered(PasskeyPlatform.windows), isTrue);
    });

    test('domain list parsing', () {
      expect(parsePasskeyDomains(''), isEmpty);
      expect(parsePasskeyDomains(' A.example , ,b.example'),
          <String>['a.example', 'b.example']);
    });

    test('the target platform maps one to one', () {
      expect(passkeyPlatformOf(TargetPlatform.linux), PasskeyPlatform.linux);
      expect(
          passkeyPlatformOf(TargetPlatform.windows), PasskeyPlatform.windows);
      expect(passkeyPlatformOf(TargetPlatform.iOS), PasskeyPlatform.ios);
    });

    test('the plugin client is unsupported on Linux', () async {
      final client = PlatformPasskeyClient(platform: PasskeyPlatform.linux);
      expect(client.platformSupported, isFalse);
      await expectLater(
          client.get(<String, Object?>{}), throwsA(isA<PasskeyUnavailable>()));
      expect(
          PlatformPasskeyClient(platform: PasskeyPlatform.windows)
              .platformSupported,
          isTrue);
    });

    test('the probe feeds the button decision', () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      final probe = await h.state.probeSetup(pkOrigin);
      expect(probe.passkeys?.rpId, 'chat.example.com');
      expect(h.state.passkeysOfferedFor(probe), isTrue);
      h.api.status = <String, Object?>{'setup_required': false};
      expect(h.state.passkeysOfferedFor(await h.state.probeSetup(pkOrigin)),
          isFalse);
      final linux = PkHarness(supported: false);
      addTearDown(linux.dispose);
      expect(
          linux.state
              .passkeysOfferedFor(await linux.state.probeSetup(pkOrigin)),
          isFalse);
      final ios = PkHarness(platform: PasskeyPlatform.ios);
      addTearDown(ios.dispose);
      expect(ios.state.passkeysOfferedFor(await ios.state.probeSetup(pkOrigin)),
          isTrue);
    });
  });

  group('the RP ID pin', () {
    test('accepts the server\'s own host', () {
      pinPasskeyRp(
        publicKey: pkMap(pkMap(pkFixture()['register_options'])['public_key']),
        registration: true,
        serverHost: 'chat.example.com',
        info: pkInfo,
      );
      pinPasskeyRp(
        publicKey: pkMap(pkMap(pkFixture()['login_options'])['public_key']),
        registration: false,
        serverHost: 'chat.example.com',
        info: pkInfo,
      );
    });

    test('refuses every mismatch', () {
      final reg = <String, Object?>{
        'rp': <String, Object?>{'id': 'evil.example', 'name': 'x'},
      };
      expect(
          () => pinPasskeyRp(
              publicKey: reg,
              registration: true,
              serverHost: 'chat.example.com',
              info: pkInfo),
          throwsA(isA<PasskeyPinException>()));
      expect(
          () => pinPasskeyRp(
              publicKey: <String, Object?>{'rpId': 'chat.example.com'},
              registration: false,
              serverHost: 'chat.example.com',
              info: const PasskeyServerInfo(
                  rpId: 'other.example.com', android: true, apple: true)),
          throwsA(isA<PasskeyPinException>()));
      for (final missing in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{'rp': 'chat.example.com'},
        <String, Object?>{'rpId': 7},
      ]) {
        expect(
            () => pinPasskeyRp(
                publicKey: missing,
                registration: missing.containsKey('rp'),
                serverHost: 'chat.example.com',
                info: pkInfo),
            throwsA(isA<PasskeyPinException>()));
      }
    });
  });

  group('passkey sign-in', () {
    test('signs in like login and keeps the cursor of the same device',
        () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled(cursor: 9);

      await h.state.signInWithPasskey(pkOrigin);

      expect(h.state.error, isNull);
      expect(h.state.session?.token, 'token-passkey');
      expect(h.state.session?.username, 'owner');
      expect((await h.store.loadSession())?.token, 'token-passkey');
      expect(await h.store.loadSyncCursor(), 9);
      expect(h.passkeys.asked, hasLength(1));
      expect(
          h.api.trace,
          containsAllInOrder(<String>[
            'login-options:dev_owner:device-secret',
            'login:cer_login:dev_owner',
          ]));
    });

    test('without MLS state the cursor restarts, as login does', () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled();
      await h.store.saveSyncCursor(9);
      await h.state.signInWithPasskey(pkOrigin);
      expect(h.state.session, isNotNull);
      expect(await h.store.loadSyncCursor(), 0);
    });

    test('a cancelled sheet is silent and signs nothing in', () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled();
      h.passkeys.failure = const PasskeyCancelled();

      await h.state.signInWithPasskey(pkOrigin);

      expect(h.state.error, isNull);
      expect(h.state.session, isNull);
      expect(h.api.trace.where((c) => c.startsWith('login:')), isEmpty);
    });

    test('the pin refuses before the platform is called', () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled();
      h.api.loginPublicKey = <String, Object?>{
        ...h.api.loginPublicKey,
        'rpId': 'evil.example',
      };

      await h.state.signInWithPasskey(pkOrigin);

      expect(h.passkeys.asked, isEmpty,
          reason: 'the platform must not be asked');
      expect(h.state.session, isNull);
      expect(h.state.error, isNotNull);
    });

    test('an unavailable platform is an error, not a crash', () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled();
      h.passkeys.failure = const PasskeyUnavailable();
      await h.state.signInWithPasskey(pkOrigin);
      expect(h.state.error, isNotNull);
      expect(h.state.session, isNull);
    });

    test('Linux and unconfigured servers never reach the server', () async {
      final linux = PkHarness(supported: false);
      addTearDown(linux.dispose);
      await linux.enrolled();
      await linux.state.signInWithPasskey(pkOrigin);
      expect(linux.state.error, isNotNull);
      expect(linux.api.trace, isEmpty);

      final off = PkHarness();
      addTearDown(off.dispose);
      await off.enrolled();
      off.api.status = <String, Object?>{'setup_required': false};
      await off.state.signInWithPasskey(pkOrigin);
      expect(off.state.error, isNotNull);
      expect(off.api.trace, isEmpty);
    });

    test('an unenrolled device is told to link first', () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.state.signInWithPasskey(pkOrigin);
      expect(h.state.error, isNotNull);
      expect(h.api.trace, isEmpty);
      expect(h.passkeys.asked, isEmpty);
    });

    test('a server refusal gives the plain message and keeps the device',
        () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled();
      h.api.loginFailure = ApiException(401, '{"error":"invalid_credentials"}');
      await h.state.signInWithPasskey(pkOrigin);
      expect(h.state.session, isNull);
      expect(h.state.error, isNotNull);
      expect(await h.store.loadSession(), isNotNull,
          reason: 'the device identity stays for a retry');
    });
  });

  group('managing passkeys', () {
    Future<PkHarness> signedIn() async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled();
      await h.state.signInWithPasskey(pkOrigin);
      await _settle();
      return h;
    }

    test('adds one: pin, platform, register, refresh', () async {
      final h = await signedIn();
      expect(await h.state.addPasskey('Passkey 1'), isTrue);
      expect(h.passkeys.created, hasLength(1));
      expect(h.state.passkeyList.single.name, 'Passkey 1');
      expect(h.api.trace, contains('register:cer_reg:Passkey 1'));
    });

    test('a cancelled registration adds nothing and says nothing', () async {
      final h = await signedIn();
      h.passkeys.failure = const PasskeyCancelled();
      expect(await h.state.addPasskey('Passkey 1'), isFalse);
      expect(h.state.errorFor(Ops.passkeys), isNull);
      expect(h.api.trace.where((c) => c.startsWith('register:')), isEmpty);
    });

    test('a hostile registration pin is refused before the platform', () async {
      final h = await signedIn();
      h.api.registerPublicKey = <String, Object?>{
        'rp': <String, Object?>{'id': 'evil.example', 'name': 'Veritra'},
      };
      expect(await h.state.addPasskey('Passkey 1'), isFalse);
      expect(h.passkeys.created, isEmpty);
      expect(h.state.errorFor(Ops.passkeys), isNotNull);
    });

    test('a server refusal such as the limit is reported', () async {
      final h = await signedIn();
      h.api.registerFailure = ApiException(409, '{"error":"passkey_limit"}');
      expect(await h.state.addPasskey('Passkey 1'), isFalse);
      expect(h.state.errorFor(Ops.passkeys), isNotNull);
    });

    test('removes and renames', () async {
      final h = await signedIn();
      await h.state.addPasskey('Passkey 1');
      expect(await h.state.renamePasskey('pk_new', 'Laptop'), isTrue);
      expect(await h.state.removePasskey('pk_new'), isTrue);
      expect(h.state.passkeyList, isEmpty);
      expect(h.api.trace,
          containsAll(<String>['rename:pk_new:Laptop', 'delete:pk_new']));
    });

    test('names are suggested, never a device model', () {
      expect(
          suggestPasskeyName('Passkey', const <PasskeyRecord>[]), 'Passkey 1');
      expect(
          suggestPasskeyName('Passkey', <PasskeyRecord>[
            PasskeyRecord(
                id: 'a', name: 'Passkey 1', createdAt: DateTime.utc(2026)),
          ]),
          'Passkey 2');
    });
  });

  group('notices from sync', () {
    SyncEvent event(int id, String type, String passkeyId) => SyncEvent(
          id: id,
          type: type,
          createdAt: DateTime.utc(2026, 11, 8),
          payload: <String, Object?>{'passkey_id': passkeyId},
        );

    test('another device adds and removes a passkey: a notice each time',
        () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled();
      h.api.events.add(event(1, 'account.passkey_added', 'pk_other'));
      await h.state.signInWithPasskey(pkOrigin);
      await _waitFor(() => h.state.passkeyNotice == PasskeyNotice.added);
      expect(await h.store.loadSyncCursor(), greaterThanOrEqualTo(0));

      h.state.dismissPasskeyNotice();
      expect(h.state.passkeyNotice, isNull);
    });

    test('an unknown account event is skipped and the cursor moves on',
        () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled();
      h.api.events.add(event(1, 'account.something_new', 'x'));
      h.api.events.add(event(2, 'account.passkey_removed', 'pk_other'));
      await h.state.signInWithPasskey(pkOrigin);
      await _waitFor(() => h.state.passkeyNotice == PasskeyNotice.removed);
      await _waitFor(() => h.state.error == null);
      expect(h.state.session, isNotNull);
    });

    test('this device\'s own change raises no notice', () async {
      final h = PkHarness();
      addTearDown(h.dispose);
      await h.enrolled();
      await h.state.signInWithPasskey(pkOrigin);
      await _settle();
      await h.state.addPasskey('Passkey 1');
      h.api.events.add(event(1, 'account.passkey_added', 'pk_new'));
      await h.state.signInWithPasskey(pkOrigin);
      await _settle();
      expect(h.state.passkeyNotice, isNull);
    });
  });
}

void androidBuildTests() {
  test('Android minSdk is not pinned below the passkey plugin\'s 23', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final pinned = RegExp(r'minSdk\s*=\s*(\d+)').firstMatch(gradle)?.group(1);
    if (pinned == null) {
      // Flutter's own default (24 in Flutter 3.44, and D41 needs 24 for
      // release APKs) applies.
      expect(gradle, contains('minSdk = flutter.minSdkVersion'));
    } else {
      expect(int.parse(pinned), greaterThanOrEqualTo(23));
    }
  });

  test('the debug-mode doctor is never turned on', () {
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      expect(file.readAsStringSync(), isNot(contains('debugMode: true')),
          reason: file.path);
    }
  });
}
