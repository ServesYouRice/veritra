import 'dart:io';

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
}
