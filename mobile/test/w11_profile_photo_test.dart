import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/profile_photo.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';

/// The photo is made on the device: square, at most 256x256, PNG, small.
Future<Uint8List> _picture(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xff3366cc));
  canvas.drawCircle(ui.Offset(w / 2, h / 2), h / 4,
      ui.Paint()..color = const ui.Color(0xffffcc00));
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('a wide picture becomes a centred 256x256 PNG', (tester) async {
    await tester.runAsync(() async {
      final photo = await prepareProfilePhoto(await _picture(1200, 600));
      expect(photo.width, 256);
      expect(photo.height, 256);
      expect(photo.png.sublist(0, 8),
          [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      expect(photo.png.length, lessThanOrEqualTo(profileMaxPhotoBytes));
    });
  });

  testWidgets('a tall and a small picture also come out square',
      (tester) async {
    await tester.runAsync(() async {
      for (final size in [(300, 900), (40, 40)]) {
        final photo =
            await prepareProfilePhoto(await _picture(size.$1, size.$2));
        expect((photo.width, photo.height), (256, 256));
      }
    });
  });

  testWidgets('the header says what the record will claim', (tester) async {
    await tester.runAsync(() async {
      final photo = await prepareProfilePhoto(await _picture(500, 500));
      final view = ByteData.sublistView(photo.png);
      // IHDR width and height are what the codec compares with the record.
      expect(view.getUint32(16), photo.width);
      expect(view.getUint32(20), photo.height);
      final again = profilePhotoFromPng(photo.png)!;
      expect((again.width, again.height), (photo.width, photo.height));
      expect(profilePhotoFromPng(Uint8List(40)), isNull);
      expect(profilePhotoFromPng(Uint8List(0)), isNull);
    });
  });

  testWidgets('bytes that are not a picture are refused', (tester) async {
    await tester.runAsync(() async {
      await expectLater(prepareProfilePhoto(Uint8List.fromList([1, 2, 3, 4])),
          throwsA(isA<ProfilePhotoException>()));
      await expectLater(prepareProfilePhoto(Uint8List(0)),
          throwsA(isA<ProfilePhotoException>()));
    });
  });
}
