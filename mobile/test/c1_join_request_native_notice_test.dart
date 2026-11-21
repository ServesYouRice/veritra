import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// C1, owner decision 2026-11-21: the "New join request" phone notice is worded
// by native code in the device language. These are text checks of native
// code no test here builds (no Android SDK, no Xcode): they keep the native
// words in step with the app's own, and the method name the same on all three
// sides. The Java rules have a JVM test (`android/wake-tests/.../WakeRulesTest.java`).

String read(String path) => File(path).readAsStringSync();

String arb(String locale, String key) =>
    (jsonDecode(read('lib/l10n/app_$locale.arb')) as Map)[key] as String;

String androidString(String values, String name) {
  final match = RegExp('<string name="$name">([^<]*)</string>')
      .firstMatch(read('android/app/src/main/res/$values/strings.xml'));
  expect(match, isNotNull, reason: '$values/$name');
  return match!.group(1)!;
}

String iosString(String lproj, String key) {
  final match = RegExp('"$key" = "([^"]*)";')
      .firstMatch(read('ios/Runner/$lproj.lproj/Localizable.strings'));
  expect(match, isNotNull, reason: '$lproj/$key');
  return match!.group(1)!;
}

void main() {
  const kotlin = 'android/app/src/main/kotlin/org/veritra/private_messenger';
  const locales = <(String, String, String)>[
    ('en', 'values', 'en'),
    ('sr', 'values-sr', 'sr'),
    ('sr_Latn', 'values-b+sr+Latn', 'sr-Latn'),
  ];

  test('the native notice says exactly what the app says, in every locale', () {
    for (final (locale, values, lproj) in locales) {
      final text = arb(locale, 'joinRequestNoticeText');
      expect(androidString(values, 'notification_join_request'), text);
      expect(iosString(lproj, 'veritra.notification.join_request'), text);
      expect(
        androidString(values, 'notification_channel_join_requests'),
        arb(locale, 'joinReqSection'),
      );
    }
  });

  test('Dart, Kotlin and Swift name the same notice method', () {
    const method = "'presentJoinRequestNotice'";
    expect(read('lib/push/wake_worker_bridge.dart'), contains(method));
    expect(
      read(
          'android/app/src/main/java/org/veritra/private_messenger/WakeRules.java'),
      contains('"presentJoinRequestNotice"'),
    );
    expect(
      read('$kotlin/WakeWorkerCoordinator.kt'),
      contains('"presentJoinRequestNotice" ->'),
    );
    final swift = read('ios/Runner/AppDelegate.swift');
    expect(swift, contains('"presentJoinRequestNotice":'));
    expect(swift, contains('"veritra.notification.join_request"'));
  });

  test('the native notice is built from resources, never from arguments', () {
    final kotlinText = read('$kotlin/MainActivity.kt');
    expect(kotlinText, contains('R.string.notification_join_request'));
    // Only the permit, profile and opaque ID reach native.
    final rules = read(
      'android/app/src/main/java/org/veritra/private_messenger/WakeRules.java',
    );
    expect(
      rules,
      contains('keys("protocol", "permit", "profile", "notice_id")'),
    );
  });
}
