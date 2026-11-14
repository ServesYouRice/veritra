import 'package:flutter/material.dart';

/// The narrowest a row's text may be laid out (U2). Below this the title
/// breaks into one or two letters per line.
const double kMinRowTextWidth = 120;

/// Width of [text] at the current text scale, for [StackedTrailingTile].
double measureTextWidth(BuildContext context, String text, {TextStyle? style}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: style ?? DefaultTextStyle.of(context).style,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// A [ListTile] with a trailing control that moves under the text when the
/// control would leave the title narrower than [kMinRowTextWidth] (U2). At
/// normal text it is an ordinary trailing control.
///
/// [trailingWidth] is the control's own width at the current text scale
/// (use [measureTextWidth] plus its padding and icons).
class StackedTrailingTile extends StatelessWidget {
  const StackedTrailingTile({
    required this.title,
    required this.trailing,
    required this.trailingWidth,
    this.leading,
    this.subtitle,
    super.key,
  });

  final Widget? leading;
  final Widget title;
  final Widget? subtitle;
  final Widget trailing;
  final double trailingWidth;

  // ListTile's default horizontal padding (16 + 16), its leading slot (40)
  // and the gap before a trailing widget (16).
  static const double _chrome = 32 + 40 + 16;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth - _chrome - trailingWidth;
        if (room >= kMinRowTextWidth) {
          return ListTile(
            leading: leading,
            title: title,
            subtitle: subtitle,
            trailing: trailing,
          );
        }
        return ListTile(
          leading: leading,
          title: title,
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (subtitle != null) subtitle!,
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: trailing,
              ),
            ],
          ),
        );
      },
    );
  }
}
