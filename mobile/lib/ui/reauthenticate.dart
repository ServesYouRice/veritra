import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../l10n/l10n.dart';

/// Asks for the password and proves a recent sign-in to the server, for a
/// credential-sensitive route (`recent_auth_required`). False when the person
/// cancels, or when the session ended while asking. A refused password keeps
/// the dialog open with the error under the field, so the person can retry
/// without starting the action again (U9).
Future<bool> promptReauthenticate(BuildContext context, AppState state) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _ReauthDialog(state: state),
  );
  return ok ?? false;
}

class _ReauthDialog extends StatefulWidget {
  const _ReauthDialog({required this.state});

  final AppState state;

  @override
  State<_ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends State<_ReauthDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _controller.text;
    if (_busy || password.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = widget.state;
    final succeeded = await state.reauthenticate(password);
    if (!mounted) return;
    if (succeeded) {
      Navigator.of(context).pop(true);
    } else if (state.session == null || state.error == null) {
      // The session ended (or changed) while asking: there is nothing left
      // to retry here.
      Navigator.of(context).pop(false);
    } else {
      setState(() {
        _busy = false;
        _error = state.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.settingsReauthTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: true,
        enabled: !_busy,
        autofillHints: const <String>[AutofillHints.password],
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: l10n.settingsReauthField,
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.commonContinue),
        ),
      ],
    );
  }
}
