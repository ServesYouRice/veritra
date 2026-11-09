import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A round picture from an accepted profile record (W11). The bytes were
/// checked before they were stored (PNG signature, a header of at most
/// 512x512, at most 192 KiB), and are decoded no larger than 256 pixels. A
/// picture that still fails to decode shows [fallback], never an error.
class PhotoAvatar extends StatelessWidget {
  const PhotoAvatar({
    required this.png,
    required this.radius,
    required this.fallback,
    super.key,
  });

  final Uint8List png;
  final double radius;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    return ExcludeSemantics(
      child: ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: Image.memory(
            png,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: 256,
            cacheHeight: 256,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => fallback,
          ),
        ),
      ),
    );
  }
}
