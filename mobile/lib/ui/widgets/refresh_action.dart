import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// A refresh button for desktop, where there is no pull-to-refresh gesture.
/// Renders nothing on phones, which keep the pull gesture.
class RefreshAction extends StatelessWidget {
  const RefreshAction({required this.onRefresh, super.key});

  final Future<void> Function() onRefresh;

  static bool get shown =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    if (!shown) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Refresh',
      onPressed: () => onRefresh(),
      icon: const Icon(Icons.refresh),
    );
  }
}
