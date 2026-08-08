import 'package:flutter/material.dart';

import '../tokens.dart';

/// The app bar every top-level screen uses.
///
/// `docs/design.md` §8 asks for a large title in place of the fixed 20px
/// Material `AppBar`. It does **not** collapse on scroll: a collapsing sliver
/// has to own the scroll view, which means every screen using one also has to
/// hand it their `RefreshIndicator` and their list. The title size is where
/// nearly all of the difference is, and this way it is one line per screen
/// instead of a restructure.
class LargeTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const LargeTitleBar({
    required this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    super.key,
  });

  final String title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;

  static const double height = 64;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppBar(
      toolbarHeight: height,
      titleSpacing: BoneSpacing.gutter,
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      title: Text(title, style: theme.textTheme.displaySmall),
      actions: <Widget>[
        ...?actions,
        const SizedBox(width: BoneSpacing.sm),
      ],
    );
  }
}
