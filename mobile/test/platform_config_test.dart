import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS declares why device-link QR scanning needs the camera', () {
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(infoPlist, contains('<key>NSCameraUsageDescription</key>'));
    expect(
      infoPlist,
      contains('Veritra uses the camera to scan device-link QR codes.'),
    );
  });
}
