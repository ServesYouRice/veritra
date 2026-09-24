import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/transport_policy.dart';
import 'package:private_messenger/features/auth/qr_scan_screen.dart';

void main() {
  test('release policy accepts HTTPS only', () {
    const policy = TransportPolicy.production;
    expect(policy.allows('https://chat.example.org'), isTrue);
    expect(policy.allows('https://localhost:8443'), isTrue);
    expect(policy.allows('http://localhost:8080'), isFalse);
    expect(policy.allows('http://127.0.0.1:8080'), isFalse);
    expect(policy.allows('http://[::1]:8080'), isFalse);
  });

  test('demo policy adds plain HTTP to loopback hosts only', () {
    const policy = TransportPolicy.demo;
    for (final origin in <String>[
      'http://localhost:8080',
      'http://LOCALHOST:8080',
      'http://127.0.0.1:8080',
      'http://127.10.20.30',
      'http://[::1]:8080',
      'https://chat.example.org',
    ]) {
      expect(policy.allows(origin), isTrue, reason: origin);
    }
    for (final origin in <String>[
      // The emulator host alias is a LAN address on a real device (D12).
      'http://10.0.2.2:8080',
      'http://192.168.1.20:8080',
      'http://localhost.example.com',
      'http://127.0.0.1.example.com',
      'http://128.0.0.1',
      'http://chat.example.org',
      'ftp://localhost',
      'http://localhost:8080/path',
      'not a url',
    ]) {
      expect(policy.allows(origin), isFalse, reason: origin);
    }
  });

  test('device-link QR origins stay HTTPS-only by default', () {
    expect(
      parseDeviceLinkOrigin(
          'veritra://device-link?code=abc&origin=http://localhost:8080'),
      isNull,
    );
    expect(
      parseDeviceLinkOrigin(
        'veritra://device-link?code=abc&origin=http://localhost:8080',
        transport: TransportPolicy.demo,
      ),
      'http://localhost:8080',
    );
  });
}
