import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/ui/about.dart';

void main() {
  test('every platform presents the product as Veritra under AGPL', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: $veritraVersion+'));
    expect(pubspec, isNot(contains('Private Messenger')));

    final names = <String, String>{
      'android/app/src/main/AndroidManifest.xml': 'android:label="Veritra"',
      'ios/Runner/Info.plist': '<string>Veritra</string>',
      'macos/Runner/Configs/AppInfo.xcconfig': 'PRODUCT_NAME = Veritra',
      'windows/runner/Runner.rc': '"ProductName", "Veritra"',
      'windows/runner/main.cpp': 'L"Veritra"',
      'linux/runner/my_application.cc': '"Veritra"',
    };
    names.forEach((path, expected) {
      expect(File(path).readAsStringSync(), contains(expected), reason: path);
    });
    for (final path in <String>[
      'macos/Runner/Configs/AppInfo.xcconfig',
      'windows/runner/Runner.rc',
    ]) {
      final text = File(path).readAsStringSync();
      expect(text, isNot(contains('All rights reserved')), reason: path);
      expect(text, contains('AGPL-3.0-or-later'), reason: path);
    }
  });

  test('no platform claims the veritra: scheme, so the app never shows it', () {
    // Device-link URIs are only read by the in-app scanner. If a platform
    // starts handling the scheme, it needs origin/capability validation and
    // the same on the other platform first (card I44).
    expect(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      isNot(contains('android:scheme')),
    );
    expect(
      File('ios/Runner/Info.plist').readAsStringSync(),
      isNot(contains('CFBundleURLTypes')),
    );
    final linkScreen = File(
      'lib/features/settings/device_link_screen.dart',
    ).readAsStringSync();
    expect(linkScreen, isNot(contains('link.linkUri')));
  });

  test('iOS declares why device-link QR scanning needs the camera', () {
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(infoPlist, contains('<key>NSCameraUsageDescription</key>'));
    expect(
      infoPlist,
      contains('Veritra uses the camera to scan device-link QR codes.'),
    );
  });
}
