import 'package:flutter/material.dart';

/// A top-bar action (UI audit U11): icon and word where the window is wide
/// enough, icon only with a tooltip otherwise.
///
/// Words start at the medium width class (600 dp, where the navigation rail
/// starts) and stop at text scale 1.3, as the tab labels do. The tooltip is
/// always present, so an icon-only action keeps its name for hover and
/// screen readers.
class BarAction extends StatelessWidget {
  const BarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.filled = false,
    this.wordsFromWidth = minWordsWidth,
    super.key,
  });

  /// Width from which a bar has room for words.
  static const double minWordsWidth = 600;

  static const double _maxWordsTextScale = 1.3;

  final IconData icon;
  final String label;

  /// Defaults to [label].
  final String? tooltip;
  final VoidCallback? onPressed;

  /// The one primary action of a bar gets the filled style.
  final bool filled;

  /// Use [double.infinity] where the bar sits in a pane narrower than the
  /// window, so words never push the title out.
  final double wordsFromWidth;

  /// Whether a bar in this context has room for words.
  static bool showsWords(BuildContext context, double fromWidth) {
    final width = MediaQuery.sizeOf(context).width;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return width >= fromWidth && scale <= _maxWordsTextScale;
  }

  @override
  Widget build(BuildContext context) {
    final message = tooltip ?? label;
    if (!showsWords(context, wordsFromWidth)) {
      return filled
          ? IconButton.filled(
              tooltip: message,
              onPressed: onPressed,
              icon: Icon(icon),
            )
          : IconButton(
              tooltip: message,
              onPressed: onPressed,
              icon: Icon(icon),
            );
    }
    // Plain Button widgets with a Row child, not the .icon constructors, so
    // the action is a TextButton or FilledButton like any other.
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ExcludeSemantics(child: Icon(icon, size: 20)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
    final style = ButtonStyle(
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 10),
      ),
    );
    return Tooltip(
      message: message,
      child: filled
          ? FilledButton(onPressed: onPressed, style: style, child: content)
          : TextButton(onPressed: onPressed, style: style, child: content),
    );
  }
}
