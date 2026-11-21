import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/desktop/update_installer.dart';
import 'package:private_messenger/desktop/update_service.dart';
import 'package:private_messenger/desktop/update_trust.dart';
import 'package:private_messenger/desktop/update_verifier.dart';

/// W12: the Ed25519 verifier's guards, the desktop wiring (owner decision
/// 2026-11-21: checks on by default once the key exists, fail closed while
/// it is empty), the per-user install rule, certutil by absolute path, and
/// redirects that never leave https. The real signature check is in
/// update_feed_native_test.dart.
void main() {
  final key = 'ab' * 32;
  final feed = Uint8List.fromList('{"version":"0.2.0"}'.codeUnits);
  final signature = Uint8List(64);
  const perUserExe = r'C:\Users\u\AppData\Local\Programs\Veritra\veritra.exe';
  const env = {
    'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
    'SystemRoot': r'C:\Windows',
  };

  group('Ed25519UpdateSignatureVerifier', () {
    test('is configured only by 64 lowercase hex characters', () {
      expect(updateFeedPublicKeyHex, isEmpty, reason: 'no key is set yet');
      expect(Ed25519UpdateSignatureVerifier().isConfigured, isFalse);
      for (final bad in [
        '',
        'ab' * 31,
        'ab' * 33,
        'AB' * 32,
        '${'ab' * 31}zz',
        ' ${'ab' * 32}',
      ]) {
        expect(
          Ed25519UpdateSignatureVerifier(publicKeyHex: bad).isConfigured,
          isFalse,
          reason: bad,
        );
      }
      expect(
        Ed25519UpdateSignatureVerifier(publicKeyHex: key).isConfigured,
        isTrue,
      );
    });

    test('passes the key, the exact bytes and the signature to the native call',
        () async {
      List<int>? seenKey, seenMessage, seenSignature;
      final verifier = Ed25519UpdateSignatureVerifier(
        publicKeyHex: key,
        verify: ({
          required List<int> publicKey,
          required List<int> message,
          required List<int> signature,
        }) {
          seenKey = publicKey;
          seenMessage = message;
          seenSignature = signature;
          return true;
        },
      );
      expect(await verifier.verify(data: feed, signature: signature), isTrue);
      expect(seenKey, List<int>.filled(32, 0xab));
      // The domain is added natively; Dart hands over the feed as received.
      expect(seenMessage, feed);
      expect(seenSignature, signature);
    });

    test('never calls the native check for a missing or misshaped input',
        () async {
      var calls = 0;
      bool count({
        required List<int> publicKey,
        required List<int> message,
        required List<int> signature,
      }) {
        calls++;
        return true;
      }

      final verifier =
          Ed25519UpdateSignatureVerifier(publicKeyHex: key, verify: count);
      expect(await verifier.verify(data: feed, signature: null), isFalse);
      expect(
        await verifier.verify(data: feed, signature: Uint8List(63)),
        isFalse,
      );
      expect(
        await verifier.verify(data: feed, signature: Uint8List(65)),
        isFalse,
      );
      expect(
        await verifier.verify(data: const [], signature: signature),
        isFalse,
      );
      expect(
        await verifier.verify(
          data: Uint8List(maxUpdateFeedBytes + 1),
          signature: signature,
        ),
        isFalse,
      );
      final unkeyed = Ed25519UpdateSignatureVerifier(verify: count);
      expect(await unkeyed.verify(data: feed, signature: signature), isFalse);
      expect(calls, 0);
    });

    test('a native refusal or failure is false, never an exception', () async {
      final refusing = Ed25519UpdateSignatureVerifier(
        publicKeyHex: key,
        verify: ({
          required List<int> publicKey,
          required List<int> message,
          required List<int> signature,
        }) =>
            false,
      );
      expect(await refusing.verify(data: feed, signature: signature), isFalse);
      final throwing = Ed25519UpdateSignatureVerifier(
        publicKeyHex: key,
        verify: ({
          required List<int> publicKey,
          required List<int> message,
          required List<int> signature,
        }) =>
            throw StateError('library missing'),
      );
      expect(await throwing.verify(data: feed, signature: signature), isFalse);
    });

    test('the build uses fail-closed while the key is empty', () {
      expect(
        updateSignatureVerifierForBuild(),
        isA<FailClosedUpdateSignatureVerifier>(),
      );
      expect(
        updateSignatureVerifierForBuild(publicKeyHex: 'AB' * 32),
        isA<FailClosedUpdateSignatureVerifier>(),
      );
      expect(
        updateSignatureVerifierForBuild(publicKeyHex: key),
        isA<Ed25519UpdateSignatureVerifier>(),
      );
    });
  });

  group('desktop wiring (checks on by default once the key exists)', () {
    Future<(UpdateStatus, int)> startUp({
      required String publicKeyHex,
      bool? saved,
      bool isWindows = true,
    }) async {
      var fetches = 0;
      final settings = UpdateSettings(MemoryUpdateSettingsStore(saved));
      await settings.load();
      final service = createDesktopUpdateService(
        settings: settings,
        isWindows: isWindows,
        executable: perUserExe,
        environment: env,
        currentBuild: 1,
        publicKeyHex: publicKeyHex,
        verify: ({
          required List<int> publicKey,
          required List<int> message,
          required List<int> signature,
        }) =>
            false,
        client: _CountingClient(() => fetches++),
      );
      addTearDown(service.dispose);
      addTearDown(settings.dispose);
      // DesktopServices.startIfSupported calls this at launch when the
      // setting is on; called here either way, it still asks for nothing
      // while the switch is off.
      await service.checkForUpdatesIfEnabled();
      return (service.status, fetches);
    }

    test('a fresh install with a key checks at launch', () async {
      final (status, fetches) = await startUp(publicKeyHex: key);
      expect(fetches, 1);
      // The fake native check rejects, so the result is an error, not an offer.
      expect(status.kind, UpdateStatusKind.error);
    });

    test('without a key nothing is requested, even with checks on', () async {
      final (status, fetches) = await startUp(publicKeyHex: '');
      expect(fetches, 0);
      expect(status.kind, UpdateStatusKind.unavailable);
    });

    test('the Settings switch turns the launch check off', () async {
      final (status, fetches) = await startUp(publicKeyHex: key, saved: false);
      expect(fetches, 0);
      expect(status.kind, UpdateStatusKind.disabled);
    });

    test('only Windows has the channel', () async {
      final (status, fetches) =
          await startUp(publicKeyHex: key, isWindows: false);
      expect(fetches, 0);
      expect(status.kind, UpdateStatusKind.unavailable);
    });

    test('only a per-user install may download and start an installer', () {
      UpdateService build(String exe, {bool isWindows = true}) {
        final settings = UpdateSettings(MemoryUpdateSettingsStore());
        final service = createDesktopUpdateService(
          settings: settings,
          isWindows: isWindows,
          executable: exe,
          environment: env,
          currentBuild: 1,
          publicKeyHex: key,
        );
        addTearDown(service.dispose);
        addTearDown(settings.dispose);
        return service;
      }

      expect(build(perUserExe).canInstall, isTrue);
      expect(
          build(r'C:\Program Files\Veritra\veritra.exe').canInstall, isFalse);
      expect(build(perUserExe, isWindows: false).canInstall, isFalse);
    });
  });

  group('isPerUserWindowsInstall', () {
    bool perUser(String exe, [Map<String, String> environment = env]) =>
        isPerUserWindowsInstall(executable: exe, environment: environment);

    test('under %LOCALAPPDATA% only', () {
      expect(perUser(perUserExe), isTrue);
      expect(perUser(perUserExe.toUpperCase()), isTrue);
      expect(perUser(perUserExe.replaceAll(r'\', '/')), isTrue);
      expect(
        perUser(perUserExe, {'LOCALAPPDATA': r'C:\Users\u\AppData\Local\'}),
        isTrue,
      );
      expect(perUser(r'C:\Program Files\Veritra\veritra.exe'), isFalse);
      expect(perUser(r'C:\Users\u\AppData\LocalEvil\veritra.exe'), isFalse);
      expect(
        perUser(r'C:\Users\u\AppData\Local\..\..\..\Program Files\v.exe'),
        isFalse,
      );
      expect(perUser(perUserExe, const {}), isFalse);
      expect(perUser(perUserExe, const {'LOCALAPPDATA': ''}), isFalse);
      expect(perUser(perUserExe, const {'LOCALAPPDATA': r'\'}), isFalse);
      expect(perUser(perUserExe, const {'LOCALAPPDATA': 'relative'}), isFalse);
    });
  });

  group('CertutilFileDigester', () {
    test('runs certutil only by its absolute System32 path', () async {
      final calls = <String>[];
      final digester = CertutilFileDigester(
        environment: env,
        run: (exe, args) async {
          calls.add(exe);
          return ProcessResult(
            0,
            0,
            'SHA256 hash of x:\r\n${'c' * 64}\r\nCertUtil: done\r\n',
            '',
          );
        },
      );
      expect(await digester.sha256Hex(File('x.exe')), 'c' * 64);
      expect(calls, [r'C:\Windows\System32\certutil.exe']);
    });

    test('refuses to run without a plain SystemRoot', () async {
      for (final environment in [
        const <String, String>{},
        const {'SystemRoot': ''},
        const {'SystemRoot': 'Windows'},
        const {'SystemRoot': r'C:\Windows\..\Temp'},
        const {'SystemRoot': r'\\server\share'},
      ]) {
        var ran = false;
        final digester = CertutilFileDigester(
          environment: environment,
          run: (exe, args) async {
            ran = true;
            return ProcessResult(0, 0, '', '');
          },
        );
        await expectLater(
          digester.sha256Hex(File('x.exe')),
          throwsA(isA<ProcessException>()),
          reason: '$environment',
        );
        expect(ran, isFalse);
      }
    });
  });

  group('https-only redirects', () {
    late _TlsFixture tls;
    setUpAll(() async => tls = await _TlsFixture.start());
    tearDownAll(() async => tls.close());

    test('the feed and its signature follow an https redirect', () async {
      final client = HttpUpdateClient(client: tls.client());
      final fetched = await client.fetchUpdate(tls.uri('/hop/update.json'));
      expect(String.fromCharCodes(fetched.jsonBytes), '{"feed":true}');
      expect(fetched.signatureBytes, List<int>.filled(64, 7));
    });

    test('a redirect to http is refused before any http request', () async {
      final client = HttpUpdateClient(client: tls.client());
      await expectLater(
        client.fetchUpdate(tls.uri('/downgrade/update.json')),
        throwsFormatException,
      );
      final dir = Directory.systemTemp.createTempSync('veritra-redirect-');
      addTearDown(() => dir.deleteSync(recursive: true));
      await expectLater(
        HttpUpdateDownloader(client: tls.client()).download(
          tls.uri('/downgrade/setup.exe'),
          File('${dir.path}/setup.exe'),
          maxBytes: 1024,
        ),
        throwsFormatException,
      );
      expect(tls.plainHits, 0);
    });

    test('a redirect loop stops', () async {
      final client = HttpUpdateClient(client: tls.client());
      await expectLater(
        client.fetchUpdate(tls.uri('/loop/update.json')),
        throwsA(isA<HttpException>()),
      );
    });

    test('a body over the cap is refused', () async {
      final client = HttpUpdateClient(client: tls.client(), maxBytes: 8);
      await expectLater(
        client.fetchUpdate(tls.uri('/update.json')),
        throwsFormatException,
      );
    });
  }, skip: _TlsFixture.skipReason());
}

class _CountingClient implements UpdateClient {
  _CountingClient(this.onFetch);
  final void Function() onFetch;

  @override
  Future<({Uint8List jsonBytes, Uint8List? signatureBytes})> fetchUpdate(
    Uri feedUri,
  ) async {
    onFetch();
    return (
      jsonBytes: Uint8List.fromList('{}'.codeUnits),
      signatureBytes: Uint8List(64),
    );
  }
}

/// A loopback https server with a throwaway self-signed certificate (made
/// with openssl, so the group is skipped where openssl is missing), and a
/// plain http server that counts every request it gets.
class _TlsFixture {
  _TlsFixture(this._secure, this._plain, this._dir);

  final HttpServer _secure;
  final HttpServer _plain;
  final Directory _dir;
  int plainHits = 0;

  static Object skipReason() {
    try {
      final result = Process.runSync('openssl', ['version']);
      return result.exitCode == 0 ? false : 'openssl is not available';
    } catch (_) {
      return 'openssl is not available';
    }
  }

  static Future<_TlsFixture> start() async {
    final dir = Directory.systemTemp.createTempSync('veritra-tls-');
    final result = Process.runSync('openssl', [
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:prime256v1',
      '-nodes',
      '-keyout',
      '${dir.path}/key.pem',
      '-out',
      '${dir.path}/cert.pem',
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=DNS:localhost',
    ]);
    if (result.exitCode != 0) {
      throw StateError('openssl failed: ${result.stderr}');
    }
    final context = SecurityContext()
      ..useCertificateChain('${dir.path}/cert.pem')
      ..usePrivateKey('${dir.path}/key.pem');
    final secure =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _TlsFixture(secure, plain, dir);
    plain.listen((request) {
      fixture.plainHits++;
      request.response
        ..statusCode = HttpStatus.ok
        ..write('{"feed":true}');
      request.response.close();
    });
    secure.listen((request) {
      final path = request.uri.path;
      final response = request.response;
      void redirect(String location) {
        response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, location);
      }

      if (path.startsWith('/hop/')) {
        redirect(path.substring('/hop'.length));
      } else if (path.startsWith('/downgrade/')) {
        redirect('http://localhost:${plain.port}${path.substring(10)}');
      } else if (path.startsWith('/loop/')) {
        redirect(path);
      } else if (path == '/update.json') {
        response.write('{"feed":true}');
      } else if (path == '/update.json.sig') {
        response.add(List<int>.filled(64, 7));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      response.close();
    });
    return fixture;
  }

  Uri uri(String path) => Uri.parse('https://localhost:${_secure.port}$path');

  HttpClient client() => HttpClient()
    ..badCertificateCallback =
        (cert, host, port) => host == 'localhost' && port == _secure.port;

  Future<void> close() async {
    await _secure.close(force: true);
    await _plain.close(force: true);
    _dir.deleteSync(recursive: true);
  }
}
