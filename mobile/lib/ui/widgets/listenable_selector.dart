import 'package:flutter/widgets.dart';

/// Rebuilds [builder] only when [select] reads a different value, instead of
/// on every notification of [listenable] (T49C-1).
///
/// `AppState` is one [ChangeNotifier]: a refreshed device list, a message in
/// another conversation and the connection status all notify the same
/// listeners. A widget that shows one part of it selects that part here. The
/// selection is read again after each notification and compared with
/// [equals] (`==` when null); the subtree rebuilds only when it differs.
///
/// The builder may read the listenable directly, so the selection must cover
/// everything the subtree reads from it. Whatever it leaves out is drawn
/// stale until something it covers changes.
class ListenableSelector<T> extends StatefulWidget {
  const ListenableSelector({
    required this.listenable,
    required this.select,
    required this.builder,
    this.equals,
    this.child,
    super.key,
  });

  final Listenable listenable;
  final T Function() select;
  final ValueWidgetBuilder<T> builder;
  final bool Function(T previous, T next)? equals;

  /// Passed to [builder] unchanged; for a subtree that never depends on the
  /// selection.
  final Widget? child;

  @override
  State<ListenableSelector<T>> createState() => _ListenableSelectorState<T>();
}

class _ListenableSelectorState<T> extends State<ListenableSelector<T>> {
  late T _value = widget.select();

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(ListenableSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    // The parent rebuilt this widget anyway, and the new [select] may read
    // different fields (another conversation, say).
    _value = widget.select();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final next = widget.select();
    final same = widget.equals?.call(_value, next) ?? _value == next;
    if (same) {
      _value = next;
      return;
    }
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _value, widget.child);
}
