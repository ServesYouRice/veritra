import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

/// Makes the reason a visible-but-disabled control is unavailable reachable
/// without a mouse.
///
/// A disabled button drops out of keyboard traversal, and its tooltip only
/// opened on hover or long-press, so a keyboard user met a control that did
/// nothing and said nothing. This wrapper is focusable in its own right: it
/// shows the reason when it gains focus or is activated with Enter or Space,
/// paints a focus ring, and on touch opens on a tap. The reason is also the
/// node's semantic tooltip, so a screen reader announces it with the control.
///
/// The wrapped control stays disabled; this explains a gate, it never opens
/// one.
class UnavailableReason extends StatefulWidget {
  const UnavailableReason({
    required this.message,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(BoneRadii.pill)),
    super.key,
  });

  final String message;
  final Widget child;

  /// Shape of the focus ring, to match the control it surrounds.
  final BorderRadius borderRadius;

  @override
  State<UnavailableReason> createState() => _UnavailableReasonState();
}

class _UnavailableReasonState extends State<UnavailableReason> {
  final _tooltip = GlobalKey<TooltipState>();
  bool _focused = false;

  void _show() => _tooltip.currentState?.ensureTooltipVisible();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter ||
            event.logicalKey == LogicalKeyboardKey.space)) {
      _show();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) _show();
      },
      onKeyEvent: _onKey,
      child: Tooltip(
        key: _tooltip,
        message: widget.message,
        triggerMode: TooltipTriggerMode.tap,
        // The reason is put on the control's own node below rather than on
        // a parent node, so a screen reader reads it with the control.
        excludeFromSemantics: true,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border:
                _focused ? Border.all(color: scheme.primary, width: 2) : null,
          ),
          child: MergeSemantics(
            child: Semantics(tooltip: widget.message, child: widget.child),
          ),
        ),
      ),
    );
  }
}
