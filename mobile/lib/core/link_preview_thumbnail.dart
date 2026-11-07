import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../crypto/link_preview.dart';

const List<int> _sides = <int>[128, 96, 64];

/// A fetched picture is decoded only when it is at most this many pixels.
const int _maxSourcePixels = 16 * 1000 * 1000;

/// Downscales [source] and re-encodes it as a PNG of at most
/// [linkPreviewMaxThumbnailBytes], trying smaller sizes until it fits.
/// Re-encoding drops all metadata (EXIF, ICC, text chunks). Null when the
/// bytes are not a decodable image or nothing small enough comes out.
Future<LinkPreviewThumbnail?> encodePngThumbnail(Uint8List source) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(source);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (width < 1 || height < 1) return null;
    if (width * height > _maxSourcePixels) return null;
    final longest = math.max(width, height);
    for (final side in _sides) {
      final scale = longest <= side ? 1.0 : side / longest;
      final targetWidth = math.max(1, (width * scale).round());
      final targetHeight = math.max(1, (height * scale).round());
      final codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) continue;
          final png = Uint8List.fromList(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
          if (png.length <= linkPreviewMaxThumbnailBytes) {
            return LinkPreviewThumbnail(
              png: png,
              width: image.width,
              height: image.height,
            );
          }
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
