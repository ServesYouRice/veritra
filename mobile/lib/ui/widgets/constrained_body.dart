import 'package:flutter/material.dart';

import '../tokens.dart';

/// Centers a scrollable or column body inside a comfortable reading width on
/// wide screens while remaining full-width on compact phones.
class ConstrainedBody extends StatelessWidget {
  const ConstrainedBody({
    required this.child,
    this.maxWidth = BoneSpacing.maxReadingWidth,
    super.key,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
