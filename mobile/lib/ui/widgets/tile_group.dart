import 'package:flutter/material.dart';

import '../tokens.dart';

/// A group of rows on one tinted, hairlined surface.
///
/// `docs/design.md` §6 describes settings as "six `Card`s of `ListTile` +
/// `Divider` + trailing chevron — generic by construction". This is the
/// replacement: one raised surface per group, rows separated by an inset
/// hairline rather than a full-width `Divider`, and **no chevrons** — a
/// tappable row does not need an arrow to say so, and twelve of them down a
/// screen is most of what made it look like a settings template.
///
/// Corners are clipped so an `InkWell` ripple stays inside the group.
///
/// The surface is a [Material], **not** a `Container` with a `BoxDecoration`.
/// `ListTile` paints its background and ink splashes onto the nearest
/// `Material` ancestor, so a decorated box between the two hides both — Flutter
/// asserts on exactly that arrangement in debug builds. Keep the colour, the
/// border and the radius on the `Material` itself.
class TileGroup extends StatelessWidget {
  const TileGroup({required this.children, this.dividerIndent = 56, super.key});

  final List<Widget> children;

  /// Where the hairline between rows starts. 56 clears a leading icon, which
  /// is what most of these rows have.
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(
          height: 1,
          thickness: 1,
          indent: dividerIndent,
          color: scheme.outlineVariant,
        ));
      }
      rows.add(children[i]);
    }
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BoneRadii.lg),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: rows),
    );
  }
}
