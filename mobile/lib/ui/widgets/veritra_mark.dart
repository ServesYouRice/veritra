import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The concept-06 chain-link mark, drawn rather than imported.
///
/// It is two rounded rectangles and a keyline, which a [CustomPainter] renders
/// exactly and at any size. Adding `flutter_svg` for it would mean a license
/// review and a `THIRD_PARTY_NOTICES.md` entry (`AGENTS.md`) for two shapes.
///
/// Geometry is transcribed from
/// `branding/concept-06/veritra-mark.svg`, which is authored in a
/// 512×512 box: two 90×290 rects with a 45 corner radius, stroked at 30,
/// rotated ∓35° about their own centres, the left one tucked under the right
/// along a 54-wide keyline. Note the mark's optical centre is y=238, not 256 —
/// the same reason the app-icon SVG re-centres it before scaling.
///
/// K2 · Bone draws it flat, and so does the source SVG since the family was
/// redrawn on 2026-08-18 — the direction spends no accent hue, so there is no
/// gradient to transcribe and the mark takes a single [color].
class VeritraMark extends StatelessWidget {
  const VeritraMark({
    required this.size,
    this.color,
    this.strokeWidth = 30,
    super.key,
  });

  final double size;

  /// Defaults to `onSurface`. Callers wanting line art pass a low-opacity
  /// colour; nothing here applies opacity on its own.
  final Color? color;

  /// In the 512-unit design space, so it scales with the mark.
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? Theme.of(context).colorScheme.onSurface;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _VeritraMarkPainter(
            color: resolved,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _VeritraMarkPainter extends CustomPainter {
  const _VeritraMarkPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  /// The design box the geometry below is expressed in.
  static const double _box = 512;

  /// Width of the gap the right link cuts out of the left one. 1.8× the
  /// stroke, as in the source SVG (54 against 30).
  double get _keyline => strokeWidth * 1.8;

  static final RRect _leftLink = RRect.fromRectAndRadius(
    const Rect.fromLTWH(126.5, 93, 90, 290),
    const Radius.circular(45),
  );

  static final RRect _rightLink = RRect.fromRectAndRadius(
    const Rect.fromLTWH(295.5, 93, 90, 290),
    const Radius.circular(45),
  );

  static const Offset _leftPivot = Offset(171.5, 238);
  static const Offset _rightPivot = Offset(340.5, 238);
  static const double _tilt = 35 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _box;
    canvas.save();
    canvas.translate(
      (size.width - _box * scale) / 2,
      (size.height - _box * scale) / 2,
    );
    canvas.scale(scale);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color
      ..isAntiAlias = true;

    // The left link is drawn into its own layer so the keyline can be
    // punched out of it with BlendMode.clear without touching whatever is
    // behind the mark. Erasing rather than overpainting in the background
    // colour is what lets the mark sit on any surface.
    canvas.saveLayer(const Rect.fromLTWH(0, 0, _box, _box), Paint());
    _rotated(canvas, _leftPivot, -_tilt, () {
      canvas.drawRRect(_leftLink, stroke);
    });
    _rotated(canvas, _rightPivot, _tilt, () {
      canvas.drawRRect(
        _rightLink,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _keyline
          ..blendMode = BlendMode.clear
          ..isAntiAlias = true,
      );
    });
    canvas.restore();

    _rotated(canvas, _rightPivot, _tilt, () {
      canvas.drawRRect(_rightLink, stroke);
    });

    canvas.restore();
  }

  void _rotated(
    Canvas canvas,
    Offset pivot,
    double radians,
    VoidCallback draw,
  ) {
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(radians);
    canvas.translate(-pivot.dx, -pivot.dy);
    draw();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VeritraMarkPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}
