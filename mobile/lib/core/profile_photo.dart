import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../crypto/profile_record_codec.dart';

/// W11 photos (docs/designs/W11-profiles.md, "Photos"). Made on the device
/// with `dart:ui` only, no new dependency: decode, crop to a centred square,
/// scale to 256x256 and re-encode as PNG. Re-encoding drops EXIF data,
/// including GPS location; the original bytes are never uploaded.

/// Sides tried in turn until the PNG fits [profileMaxPhotoBytes].
const List<int> profilePhotoSides = <int>[256, 192, 128];

/// Largest picture file read at all, so a huge file is refused up front.
const int profilePhotoMaxSourceBytes = 32 * 1024 * 1024;

class ProfilePhotoException implements Exception {
  const ProfilePhotoException();
  @override
  String toString() => 'ProfilePhotoException';
}

/// Turns the bytes of a picture into a profile photo, or throws
/// [ProfilePhotoException] when they are not a picture this device can read
/// or no size fits.
Future<ProfilePhoto> prepareProfilePhoto(Uint8List source) async {
  if (source.isEmpty || source.length > profilePhotoMaxSourceBytes) {
    throw const ProfilePhotoException();
  }
  final ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(source);
  } on Object {
    throw const ProfilePhotoException();
  }
  ui.Image? image;
  try {
    final frame = await codec.getNextFrame();
    image = frame.image;
    for (final side in profilePhotoSides) {
      final png = await _squarePng(image, side);
      if (png.length <= profileMaxPhotoBytes) {
        return ProfilePhoto(png: png, width: side, height: side);
      }
    }
    throw const ProfilePhotoException();
  } on ProfilePhotoException {
    rethrow;
  } on Object {
    throw const ProfilePhotoException();
  } finally {
    image?.dispose();
    codec.dispose();
  }
}

Future<Uint8List> _squarePng(ui.Image image, int side) async {
  final shortSide = image.width < image.height ? image.width : image.height;
  if (shortSide <= 0) throw const ProfilePhotoException();
  final source = ui.Rect.fromLTWH(
    (image.width - shortSide) / 2,
    (image.height - shortSide) / 2,
    shortSide.toDouble(),
    shortSide.toDouble(),
  );
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    image,
    source,
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final scaled = await picture.toImage(side, side);
  try {
    final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw const ProfilePhotoException();
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    scaled.dispose();
    picture.dispose();
  }
}

/// A stored photo's dimensions are in its PNG header; this reads them so a
/// name-only edit can keep the photo it already has. Null if it is not a PNG
/// this app would accept.
ProfilePhoto? profilePhotoFromPng(Uint8List png) {
  if (png.length < 33 || png.length > profileMaxPhotoBytes) return null;
  const signature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (var i = 0; i < signature.length; i++) {
    if (png[i] != signature[i]) return null;
  }
  final view = ByteData.sublistView(png);
  final width = view.getUint32(16);
  final height = view.getUint32(20);
  if (width == 0 ||
      height == 0 ||
      width > profileMaxPhotoSide ||
      height > profileMaxPhotoSide) {
    return null;
  }
  return ProfilePhoto(png: png, width: width, height: height);
}
