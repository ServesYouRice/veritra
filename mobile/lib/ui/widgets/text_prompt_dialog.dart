import 'package:flutter/material.dart';

/// Asks for one value in a dialog and validates it inline.
///
/// The prompts this replaces closed on an empty or malformed value and did
/// nothing, so a mis-tap read as success. Here a failed check keeps the
/// dialog open and says what is wrong under the field, re-checking as the
/// user types once they have tried to submit. Returns the value, trimmed
/// unless [trim] is false, or null when cancelled.
Future<String?> showTextPromptDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String confirmLabel,
  required String? Function(String value) validator,
  String initialValue = '',
  String? hintText,
  String? helperText,
  bool obscureText = false,
  bool trim = true,
  TextInputType? keyboardType,
  Iterable<String>? autofillHints,
  int maxLines = 1,
  TextStyle? style,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(
      title: title,
      label: label,
      confirmLabel: confirmLabel,
      validator: validator,
      initialValue: initialValue,
      hintText: hintText,
      helperText: helperText,
      obscureText: obscureText,
      trim: trim,
      keyboardType: keyboardType,
      autofillHints: autofillHints,
      maxLines: maxLines,
      style: style,
    ),
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    required this.validator,
    required this.initialValue,
    required this.obscureText,
    required this.trim,
    required this.maxLines,
    this.hintText,
    this.helperText,
    this.keyboardType,
    this.autofillHints,
    this.style,
  });

  final String title;
  final String label;
  final String confirmLabel;
  final String? Function(String value) validator;
  final String initialValue;
  final String? hintText;
  final String? helperText;
  final bool obscureText;
  final bool trim;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final int maxLines;
  final TextStyle? style;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  bool _attempted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _value => widget.trim ? _controller.text.trim() : _controller.text;

  void _submit() {
    if (!_attempted) setState(() => _attempted = true);
    if (_form.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      // Scrolls rather than overflowing when the keyboard and a large text
      // scale leave little height for the field and its error.
      scrollable: true,
      content: Form(
        key: _form,
        autovalidateMode: _attempted
            ? AutovalidateMode.onUserInteraction
            : AutovalidateMode.disabled,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          obscureText: widget.obscureText,
          keyboardType: widget.keyboardType,
          autofillHints: widget.autofillHints,
          minLines: 1,
          maxLines: widget.obscureText ? 1 : widget.maxLines,
          style: widget.style,
          textInputAction: widget.maxLines == 1
              ? TextInputAction.done
              : TextInputAction.newline,
          onFieldSubmitted: widget.maxLines == 1 ? (_) => _submit() : null,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hintText,
            helperText: widget.helperText,
            helperMaxLines: 3,
            errorMaxLines: 3,
          ),
          validator: (_) => widget.validator(_value),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
