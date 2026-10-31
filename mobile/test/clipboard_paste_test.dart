// What Ctrl+V in the desktop composer picks from the clipboard (TASK-066):
// files first, then plain text, then an image.
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/features/chat/chat_desktop.dart';

final _image = Uint8List.fromList(<int>[1, 2, 3]);

Future<({List<XFile> files, Set<String> temporary})> _read({
  List<String> files = const <String>[],
  String? text,
  Uint8List? image,
  bool textFails = false,
}) {
  return readClipboardFiles(
    readFiles: () async => files,
    readText: () async {
      if (textFails) throw StateError('no text format');
      return text;
    },
    readImage: () async => image,
    storeImage: (bytes) async => XFile('/cache/pasted.png'),
  );
}

void main() {
  test('text next to an image pastes as text', () async {
    final result = await _read(text: 'Q3 figures', image: _image);
    expect(result.files, isEmpty, reason: 'the text paste goes ahead');
    expect(result.temporary, isEmpty);
  });

  test('an image alone is attached as a temporary file', () async {
    final result = await _read(image: _image);
    expect(
        result.files.map((file) => file.path), <String>['/cache/pasted.png']);
    expect(result.temporary, <String>{'/cache/pasted.png'});
  });

  test('files win over text and an image', () async {
    final result = await _read(
      files: <String>['/home/me/a.pdf', '/home/me/b.pdf'],
      text: 'a.pdf',
      image: _image,
    );
    expect(result.files.map((file) => file.path),
        <String>['/home/me/a.pdf', '/home/me/b.pdf']);
    expect(result.temporary, isEmpty);
  });

  test('whitespace is not text', () async {
    final result = await _read(text: ' \n\t ', image: _image);
    expect(result.files, hasLength(1));
    expect(result.temporary, <String>{'/cache/pasted.png'});
  });

  test('an unreadable text format does not hide an image', () async {
    final result = await _read(textFails: true, image: _image);
    expect(result.files, hasLength(1));
  });

  test('an empty clipboard attaches nothing', () async {
    final result = await _read();
    expect(result.files, isEmpty);
    expect(result.temporary, isEmpty);
  });

  test('an empty image is not attached', () async {
    final result = await _read(image: Uint8List(0));
    expect(result.files, isEmpty);
  });

  test('a failing clipboard falls back to the text paste', () async {
    final result = await readClipboardFiles(
      readFiles: () async => throw StateError('no plugin'),
    );
    expect(result.files, isEmpty);
  });
}
