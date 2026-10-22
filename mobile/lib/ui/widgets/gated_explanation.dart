import 'package:flutter/material.dart';

/// Makes the reason a control is unavailable reachable by keyboard, touch and
/// screen reader, while the control itself stays disabled.
///
/// A disabled `IconButton` takes no focus, so a tooltip on it is invisible to
/// keyboard users and easy to miss by touch. This wrapper owns the focus
/// instead: focusing it (Tab), activating it (Enter/Space) or tapping it
/// shows [message]. The wrapped [child] must already be disabled and must not
/// carry its own tooltip.
class GatedExplanation extends StatefulWidget {
  const GatedExplanation({
    required this.message,
    required this.child,
    super.key,
  });

  final String message;
  final Widget child;

  @override
  State<GatedExplanation> createState() => _GatedExplanationState();
}

class _GatedExplanationState extends State<GatedExplanation> {
  final _tooltip = GlobalKey<TooltipState>();
  bool _highlight = false;

  void _show() => _tooltip.currentState?.ensureTooltipVisible();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      key: _tooltip,
      message: widget.message,
      triggerMode: TooltipTriggerMode.tap,
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _highlight = value),
        onFocusChange: (focused) {
          if (focused) _show();
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _show();
              return null;
            },
          ),
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: _highlight ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
