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

  test('Android keeps all app data out of backups and device transfers', () {
    // Android 12+ device-to-device transfer ignores allowBackup="false";
    // only the data extraction rules keep data out of it.
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));

    const domains = <String>[
      'root',
      'file',
      'database',
      'sharedpref',
      'external',
      'device_root',
      'device_file',
      'device_database',
      'device_sharedpref',
    ];
    final excludeAll = <String>[
      for (final domain in domains) '<exclude domain="$domain" path="." />',
    ];
    String section(String xml, String tag) {
      final start = xml.indexOf('<$tag>');
      final end = xml.indexOf('</$tag>');
      expect(start, isNonNegative, reason: tag);
      expect(end, greaterThan(start), reason: tag);
      return xml.substring(start, end);
    }

    final rules = File('android/app/src/main/res/xml/data_extraction_rules.xml')
        .readAsStringSync();
    final legacy = File('android/app/src/main/res/xml/backup_rules.xml')
        .readAsStringSync();
    for (final (name, body) in <(String, String)>[
      ('cloud-backup', section(rules, 'cloud-backup')),
      ('device-transfer', section(rules, 'device-transfer')),
      ('full-backup-content', section(legacy, 'full-backup-content')),
    ]) {
      for (final exclude in excludeAll) {
        expect(body, contains(exclude), reason: name);
      }
      // An include would bring files back in.
      expect(body, isNot(contains('<include')), reason: name);
    }
  });

  test('iOS excludes the local database from backups through the Runner', () {
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final dart = File('lib/storage/backup_exclusion.dart').readAsStringSync();
    const channel = 'org.veritra.private_messenger/storage';
    expect(delegate, contains('name: "$channel"'));
    expect(dart, contains("MethodChannel('$channel')"));
    expect(delegate, contains('call.method == "excludeFromBackup"'));
    expect(dart, contains("'excludeFromBackup'"));
    expect(delegate, contains('values.isExcludedFromBackup = true'));
    // The shared engine (D52) registers the storage channel in the same
    // main-thread turn that starts it, before any Dart bootstrap call runs.
    final shared = delegate.substring(delegate.indexOf('func sharedEngine('),
        delegate.indexOf('func setWakeUIAttached('));
    expect(shared, contains('registerStorageChannel(engine)'));
    expect(shared.indexOf('registerStorageChannel(engine)'),
        lessThan(shared.indexOf('return engine')));
    // Every path is tried: a failure is counted inside the loop, never
    // returned from it, and reported once after it.
    final handler = delegate.substring(
        delegate.indexOf('for path in paths where'),
        delegate.indexOf('func onListen('));
    final loop = handler.substring(0, handler.indexOf('if failures > 0'));
    expect(loop, contains('failures += 1'));
    expect(loop, isNot(contains('return')));
    expect(loop, isNot(contains('result(')));
    expect(handler.substring(loop.length),
        contains('FlutterError(code: "exclude_failed"'));
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
