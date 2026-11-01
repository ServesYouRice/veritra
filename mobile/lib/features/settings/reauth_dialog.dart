import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';

/// Asks for the password and proves it again with the device secret
/// (`POST /auth/reauth`), for actions that need recent authentication.
/// Returns whether it succeeded; a failure is shown as a snack bar.
Future<bool> confirmPasswordForRecentAuth(
    BuildContext context, AppState state) async {
  final password = await showDialog<String>(
    context: context,
    builder: (_) => const _PasswordDialog(),
  );
  if (password == null || password.isEmpty) return false;
  final ok = await state.reauthenticate(password);
  if (!ok && context.mounted && state.error != null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(state.error!)));
  }
  return ok;
}

/// Owns its field, so the field outlives the dialog's closing animation.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.settingsReauthTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: true,
        autofillHints: const <String>[AutofillHints.password],
        decoration:
            InputDecoration(labelText: context.l10n.settingsReauthField),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(context.l10n.commonContinue),
        ),
      ],
    );
  }
}
