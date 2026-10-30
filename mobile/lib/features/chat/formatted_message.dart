import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../crypto/message_format.dart';

class FormattedMessage extends StatefulWidget {
  const FormattedMessage(
      {required this.text,
      required this.formatJson,
      this.style,
      this.onMention,
      super.key});
  final String text;
  final String? formatJson;
  final TextStyle? style;
  final void Function(String accountId)? onMention;
  @override
  State<FormattedMessage> createState() => _FormattedMessageState();
}

class _FormattedMessageState extends State<FormattedMessage> {
  bool _reveal = false;
  final List<TapGestureRecognizer> _recognizers = [];
  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void didUpdateWidget(FormattedMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.formatJson != widget.formatJson) _reveal = false;
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final decoration = messageDecoration(
        {...decodeDecoration(widget.formatJson), 'text': widget.text});
    final entities = (decoration['entities'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    final mentions = (decoration['mentions'] as List? ?? const [])
        .cast<Map<String, Object?>>();
    final boundaries = <int>{0, widget.text.length};
    for (final range in [...entities, ...mentions]) {
      boundaries.add(range['offset'] as int);
      boundaries.add((range['offset'] as int) + (range['length'] as int));
    }
    final ordered = boundaries.toList()..sort();
    final spans = <TextSpan>[];
    for (var i = 0; i < ordered.length - 1; i++) {
      final start = ordered[i], end = ordered[i + 1];
      bool contains(Map<String, Object?> e) =>
          (e['offset'] as int) <= start &&
          (e['offset'] as int) + (e['length'] as int) >= end;
      final types = entities.where(contains).map((e) => e['type']).toSet();
      final mention = mentions.where(contains).firstOrNull;
      final concealed = types.contains('spoiler') && !_reveal;
      var style = widget.style ?? DefaultTextStyle.of(context).style;
      if (types.contains('bold'))
        style = style.copyWith(fontWeight: FontWeight.bold);
      if (types.contains('italic'))
        style = style.copyWith(fontStyle: FontStyle.italic);
      if (types.contains('strikethrough'))
        style = style.copyWith(decoration: TextDecoration.lineThrough);
      if (types.contains('code') || types.contains('code_block'))
        style = style.copyWith(
            fontFamily: 'monospace',
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest);
      TapGestureRecognizer? recognizer;
      if (types.contains('spoiler') || mention != null) {
        recognizer = TapGestureRecognizer()
          ..onTap = () {
            if (types.contains('spoiler')) {
              setState(() => _reveal = !_reveal);
            } else {
              widget.onMention?.call(mention!['account_id'] as String);
            }
          };
        _recognizers.add(recognizer);
      }
      if (mention != null && !concealed)
        style = style.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600);
      spans.add(TextSpan(
          text: concealed
              ? '█' * widget.text.substring(start, end).runes.length
              : widget.text.substring(start, end),
          style: style,
          recognizer: recognizer));
    }
    return SelectableText.rich(TextSpan(children: spans));
  }
}
