import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/device_link_code.dart';
import 'package:private_messenger/features/auth/qr_scan_screen.dart';
import 'package:private_messenger/features/settings/device_link_screen.dart';

void main() {
  test('base32 codes round trip and accept manual grouping', () {
    final random = Random(42);
    for (var i = 0; i < 100; i++) {
      final secret = List<int>.generate(16, (_) => random.nextInt(256));
      final code = encodeDeviceLinkSecret(secret);
      expect(code, hasLength(26));
      expect(decodeDeviceLinkSecret(code), secret);
      final grouped = '${code.substring(0, 13)}-${code.substring(13)}';
      expect(decodeDeviceLinkSecret(grouped.toLowerCase()), secret);
      expect(parseDeviceLinkCode(deviceLinkQrPayload(code)!), code);
    }
    expect(encodeDeviceLinkSecret(List<int>.filled(16, 0)), 'A' * 26);
    expect(encodeDeviceLinkSecret(List<int>.filled(16, 255)), '${'7' * 25}4');
  });

  test('invalid or legacy codes fail without carrying their input', () {
    for (final invalid in [
      '',
      'PAIRCODE',
      'A' * 25,
      'A' * 27,
      '${'A' * 25}B',
      '${'A' * 25}0',
    ]) {
      try {
        decodeDeviceLinkSecret(invalid);
        fail('Invalid code accepted');
      } on FormatException catch (error) {
        expect(error.source, isNull);
      }
      expect(parseDeviceLinkCode(invalid), isEmpty);
    }
  });
}
