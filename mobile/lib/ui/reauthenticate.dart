import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../l10n/l10n.dart';

/// Asks for the password and proves a recent sign-in to the server, for a
/// credential-sensitive route (`recent_auth_required`). False when the person
/// cancels or the password is refused (the error is shown).
Future<bool> promptReauthenticate(BuildContext context, AppState state) async {
  final controller = TextEditingController();
  try {
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.settingsReauthTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          autofillHints: const <String>[AutofillHints.password],
          decoration: InputDecoration(
            labelText: dialogContext.l10n.settingsReauthField,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(dialogContext.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(dialogContext.l10n.commonContinue),
          ),
        ],
      ),
    );
    if (password == null || password.isEmpty) {
      return false;
    }
    final ok = await state.reauthenticate(password);
    if (!ok && context.mounted && state.error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(state.error!)));
    }
    return ok;
  } finally {
    controller.dispose();
  }
}
