import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chat/composer_attachments.dart';

void main() {
  test('the tray keeps files in order and deletes only temporary copies',
      () async {
    final dir = Directory.systemTemp.createTempSync('tray');
    addTearDown(() => dir.deleteSync(recursive: true));
    final keep = File('${dir.path}/keep.txt')..writeAsStringSync('a');
    final temp = File('${dir.path}/temp.png')..writeAsStringSync('b');
    final tray = ComposerAttachments();
    tray.add(PendingAttachment(path: keep.path, name: 'keep.txt', size: 1));
    tray.add(PendingAttachment(
        path: temp.path, name: 'temp.png', size: 1, temporary: true));
    expect(tray.items.map((item) => item.name), ['keep.txt', 'temp.png']);
    await tray.clear();
    expect(tray.isEmpty, isTrue);
    expect(keep.existsSync(), isTrue);
    expect(temp.existsSync(), isFalse);
  });

  test('a pasted image gets a dated png name', () {
    expect(pastedImageName(DateTime(2026, 10, 24, 9, 5, 7)),
        'image-20261024-090507.png');
  });

  group('pasted images', () {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    late Directory cache;
    late Directory temp;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      cache = Directory.systemTemp.createTempSync('paste_cache');
      temp = Directory.systemTemp.createTempSync('paste_temp');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'getApplicationCacheDirectory':
            return cache.path;
          case 'getTemporaryDirectory':
            return temp.path;
        }
        return null;
      });
    });

    tearDown(() {
      usePastedImageProfile(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      cache.deleteSync(recursive: true);
      temp.deleteSync(recursive: true);
    });

    final sep = Platform.pathSeparator;

    test('are written under the per-user cache, in a folder for the profile',
        () async {
      usePastedImageProfile('demo-alice');
      final pasted = await writePastedImage(Uint8List.fromList([1, 2, 3]));
      expect(pasted.path,
          startsWith('${cache.path}${sep}veritra-paste${sep}demo-alice$sep'));
      expect(pasted.path, isNot(startsWith(temp.path)),
          reason: 'not the shared temporary directory');
      expect(File(pasted.path).readAsBytesSync(), [1, 2, 3]);
      expect(pasted.path.split(sep).last,
          matches(RegExp(r'^[0-9a-f]+-image-\d{8}-\d{6}\.png$')));
      expect(pasted.mimeType, 'image/png');
    });

    test('the paste folders are private to their owner', () async {
      // As an older version or a permissive umask left them.
      final parent = Directory('${cache.path}${sep}veritra-paste');
      final folder = Directory('${parent.path}${sep}demo-alice')
        ..createSync(recursive: true);
      for (final path in <String>[parent.path, folder.path]) {
        final result = await Process.run('chmod', <String>['755', path]);
        expect(result.exitCode, 0);
      }
      usePastedImageProfile('demo-alice');
      await writePastedImage(Uint8List.fromList([1]));
      for (final directory in <Directory>[parent, folder]) {
        expect(directory.statSync().mode & 0x1ff, 0x1c0,
            reason: '${directory.path} is 0700');
      }
    }, skip: Platform.isLinux || Platform.isMacOS ? false : 'POSIX modes');

    test('two profiles keep their pastes apart', () async {
      usePastedImageProfile('demo-alice');
      final alice = await writePastedImage(Uint8List.fromList([1]));
      usePastedImageProfile('demo-bob');
      final bob = await writePastedImage(Uint8List.fromList([2]));
      expect(File(alice.path).parent.path, isNot(File(bob.path).parent.path));
    });

    test('the purge removes only this profile\'s folder', () async {
      usePastedImageProfile('demo-alice');
      final alice = await writePastedImage(Uint8List.fromList([1]));
      usePastedImageProfile('demo-bob');
      final bob = await writePastedImage(Uint8List.fromList([2]));

      // A second Bob starts up and purges: Alice's pending paste survives.
      await purgePastedImages();
      expect(File(bob.path).existsSync(), isFalse);
      expect(File(alice.path).existsSync(), isTrue);
    });

    test('the purge also removes the shared folder older versions used',
        () async {
      final legacy = File('${temp.path}${sep}veritra-paste${sep}old.png')
        ..createSync(recursive: true);
      usePastedImageProfile('demo-alice');
      await purgePastedImages();
      expect(legacy.existsSync(), isFalse);
      expect(
          Directory('${temp.path}${sep}veritra-paste').existsSync(), isFalse);
    });

    test('a profile name cannot leave the paste folder', () async {
      usePastedImageProfile('../../etc');
      final pasted = await writePastedImage(Uint8List.fromList([1]));
      expect(pasted.path, startsWith('${cache.path}${sep}veritra-paste$sep'));
      expect(pasted.path, isNot(contains('..')));
      usePastedImageProfile('///');
      final other = await writePastedImage(Uint8List.fromList([1]));
      expect(other.path,
          startsWith('${cache.path}${sep}veritra-paste${sep}default$sep'));
    });

    test('the purge tolerates a missing path provider', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await purgePastedImages();
    });
  });
}
