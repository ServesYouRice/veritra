// Decrypted copies handed to other apps (TASK-064): every open gets its own
// path and its own expiry, so an earlier timer cannot delete a later copy.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chat/attachment_views.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('attachment_open_test_');
  });

  tearDown(() => root.delete(recursive: true));

  Future<File> open(String name, String content) async {
    final copy = await newOpenedCopy(root, name);
    await copy.writeAsString(content);
    return copy;
  }

  test('a copy keeps its file name but never shares a path', () async {
    final first = await open('report.pdf', 'first');
    final second = await open('report.pdf', 'second');
    expect(first.path, isNot(second.path));
    expect(first.uri.pathSegments.last, 'report.pdf');
    expect(second.uri.pathSegments.last, 'report.pdf');
    expect(await first.readAsString(), 'first');
    expect(await second.readAsString(), 'second');
  });

  test('the first copy\'s expiry leaves a later copy of the same name alone',
      () async {
    final first = await open('report.pdf', 'first');
    expireOpenedCopy(first, lifetime: const Duration(milliseconds: 200));

    await Future<void>.delayed(const Duration(milliseconds: 120));
    final second = await open('report.pdf', 'second');
    expireOpenedCopy(second, lifetime: const Duration(milliseconds: 200));

    // The first timer has fired (at 200 ms); the second has not (at 320 ms).
    await Future<void>.delayed(const Duration(milliseconds: 130));
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isTrue,
        reason: 'a newer copy must live its own lifetime');
    expect(await second.readAsString(), 'second');

    // Every copy is still deleted after its own lifetime.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await second.exists(), isFalse);
    expect(await root.list().toList(), isEmpty,
        reason: 'no empty folder is left behind');
  });

  test('the expiry of an already purged copy is harmless', () async {
    final copy = await open('report.pdf', 'x');
    await copy.parent.delete(recursive: true);
    final timer =
        expireOpenedCopy(copy, lifetime: const Duration(milliseconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(timer.isActive, isFalse);
  });

  test('the startup purge removes every copy', () async {
    final cache = await Directory.systemTemp.createTemp('attachment_cache_');
    addTearDown(() => cache.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => cache.path,
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );
    final opened = Directory('${cache.path}${Platform.pathSeparator}'
        'veritra-open');
    final one = await newOpenedCopy(opened, 'a.pdf');
    final two = await newOpenedCopy(opened, 'a.pdf');
    await one.writeAsString('1');
    await two.writeAsString('2');

    await purgeOpenedAttachments();

    expect(await opened.exists(), isFalse);
  });
}
