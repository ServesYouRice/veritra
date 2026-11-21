// Decrypted copies handed to other apps (TASK-064): every open gets its own
// path and its own expiry, so an earlier timer cannot delete a later copy.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/attachments.dart';
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

  test(
    'the first copy\'s expiry leaves a later copy of the same name alone',
    () async {
      final first = await open('report.pdf', 'first');
      expireOpenedCopy(first, lifetime: const Duration(milliseconds: 200));

      await Future<void>.delayed(const Duration(milliseconds: 120));
      final second = await open('report.pdf', 'second');
      expireOpenedCopy(second, lifetime: const Duration(milliseconds: 200));

      // The first timer has fired (at 200 ms); the second has not (at 320 ms).
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(await first.exists(), isFalse);
      expect(
        await second.exists(),
        isTrue,
        reason: 'a newer copy must live its own lifetime',
      );
      expect(await second.readAsString(), 'second');

      // Every copy is still deleted after its own lifetime.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(await second.exists(), isFalse);
      expect(
        await root.list().toList(),
        isEmpty,
        reason: 'no empty folder is left behind',
      );
    },
  );

  test('the expiry of an already purged copy is harmless', () async {
    final copy = await open('report.pdf', 'x');
    await copy.parent.delete(recursive: true);
    final timer = expireOpenedCopy(
      copy,
      lifetime: const Duration(milliseconds: 10),
    );
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
    final opened = Directory(
      '${cache.path}${Platform.pathSeparator}'
      'veritra-open',
    );
    final one = await newOpenedCopy(opened, 'a.pdf');
    final two = await newOpenedCopy(opened, 'a.pdf');
    await one.writeAsString('1');
    await two.writeAsString('2');

    await purgeOpenedAttachments();

    expect(await opened.exists(), isFalse);
  });

  group('a big file for another app', () {
    Future<void> gone(File copy) async {
      for (var i = 0; i < 100 && copy.parent.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    void lifecycle(AppLifecycleState state) =>
        WidgetsBinding.instance.handleAppLifecycleStateChanged(state);

    test('its copy goes when the app is back in front after the viewer',
        () async {
      final copy = await open('report.pdf', 'x');
      deleteCopyWhenViewerCloses(copy, lifetime: const Duration(minutes: 5));

      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.paused);
      expect(await copy.exists(), isTrue, reason: 'the viewer is still open');
      lifecycle(AppLifecycleState.hidden);
      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);

      await gone(copy);
      expect(await copy.parent.exists(), isFalse);
    });

    test('a dialog that only dims the app does not delete the copy', () async {
      final copy = await open('report.pdf', 'x');
      final stop = deleteCopyWhenViewerCloses(copy,
          lifetime: const Duration(minutes: 5));

      lifecycle(AppLifecycleState.inactive);
      lifecycle(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(await copy.exists(), isTrue);
      stop();
    });

    test('with no sign of the viewer closing, the timer still deletes it',
        () async {
      final copy = await open('report.pdf', 'x');
      final stop = deleteCopyWhenViewerCloses(copy,
          lifetime: const Duration(milliseconds: 80));
      await gone(copy);
      expect(await copy.parent.exists(), isFalse);
      stop();
    });
  });

  group('the hourly sweep of opened copies', () {
    late Directory cache;
    late Directory opened;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('attachment_sweep_');
      addTearDown(() => cache.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => cache.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      opened = Directory('${cache.path}${Platform.pathSeparator}veritra-open');
    });

    test('removes a copy older than the limit, in any slot, and no younger',
        () async {
      final first =
          await newOpenedCopy(Directory('${opened.path}/primary'), 'a.pdf');
      final second =
          await newOpenedCopy(Directory('${opened.path}/other'), 'b.pdf');
      await first.writeAsString('x');
      await second.writeAsString('x');
      final now = DateTime.now();

      await purgeStaleOpenedCopies(
        attachmentOrphanMinAge,
        now: now.add(const Duration(minutes: 30)),
      );
      expect(await first.exists(), isTrue, reason: 'younger than an hour');
      expect(await second.exists(), isTrue);

      await purgeStaleOpenedCopies(
        attachmentOrphanMinAge,
        now: now.add(const Duration(hours: 2)),
      );
      expect(await first.parent.exists(), isFalse);
      expect(await second.parent.exists(), isFalse);
    });

    test('does nothing when no copy was ever made', () async {
      await purgeStaleOpenedCopies(attachmentOrphanMinAge);
      expect(await opened.exists(), isFalse);
    });

    test('the attachment sweeper runs it with its own age limit', () async {
      final working = await Directory.systemTemp.createTemp('sweep_work_');
      addTearDown(() => working.delete(recursive: true));
      final stale =
          await newOpenedCopy(Directory('${opened.path}/primary'), 'a.pdf');
      await stale.writeAsString('x');

      final sweeper = AttachmentOrphanSweeper(
        () async => working,
        alsoSweep: (minAge) => purgeStaleOpenedCopies(
          minAge,
          now: DateTime.now().add(const Duration(hours: 2)),
        ),
      );
      await sweeper.sweep();
      sweeper.stop();

      expect(await stale.parent.exists(), isFalse);
    });
  });
}
