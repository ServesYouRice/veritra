import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';
import '../settings/reauth_dialog.dart';
import '../settings/recovery_key_screen.dart';

/// The forced steps after a recovery, before any chat opens (design, client
/// flow step 6): replace the recovery key, then the password. Both may be
/// known to someone else. The old key stays valid until the new one is
/// saved, so stopping halfway never locks the user out.
class RecoveryFollowUpScreen extends StatelessWidget {
  const RecoveryFollowUpScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final l10n = context.l10n;
        final step = state.recoveryFollowUp;
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Text(l10n.recoveryFollowUpTitle),
          ),
          body: SafeArea(
            child: switch (step) {
              RecoveryFollowUpStep.password => _NewPasswordStep(state: state),
              _ => RecoveryKeySetup(
                  state: state,
                  intro: l10n.recoveryFollowUpKeyDetail,
                  onSaved: () {},
                ),
            },
          ),
        );
      },
    );
  }
}

class _NewPasswordStep extends StatefulWidget {
  const _NewPasswordStep({required this.state});

  final AppState state;

  @override
  State<_NewPasswordStep> createState() => _NewPasswordStepState();
}

class _NewPasswordStepState extends State<_NewPasswordStep> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _working = false;

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _confirmation.clear();
    _confirmation.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    final l10n = context.l10n;
    final raw = value ?? '';
    if (raw.isEmpty) return l10n.settingsPasswordRequired;
    final bytes = utf8.encode(raw).length;
    if (bytes < 12) return l10n.settingsPasswordTooShort;
    if (bytes > 72) return l10n.settingsPasswordTooLong;
    return null;
  }

  Future<void> _submit() async {
    if (_working || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _working = true);
    try {
      // The password change needs recent authentication, which completion
      // never grants.
      if (!await confirmPasswordForRecentAuth(context, widget.state)) return;
      await widget.state.changePassword(_password.text);
      if (!mounted) return;
      final error = widget.state.error;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error ?? context.l10n.settingsPasswordChanged)));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(BoneSpacing.xl),
        children: <Widget>[
          Text(l10n.recoveryFollowUpPasswordDetail,
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: BoneSpacing.lg),
          TextFormField(
            controller: _password,
            obscureText: true,
            autofillHints: const <String>[AutofillHints.newPassword],
            validator: _validate,
            decoration: InputDecoration(
              labelText: l10n.settingsNewPassword,
              helperText: l10n.settingsNewPasswordHelper,
            ),
          ),
          const SizedBox(height: BoneSpacing.md),
          TextFormField(
            controller: _confirmation,
            obscureText: true,
            validator: (value) => (value ?? '') != _password.text
                ? l10n.settingsPasswordsMismatch
                : null,
            decoration:
                InputDecoration(labelText: l10n.settingsConfirmNewPassword),
          ),
          const SizedBox(height: BoneSpacing.xl),
          FilledButton(
            onPressed: _working ? null : _submit,
            child: Text(l10n.settingsChangePassword),
          ),
        ],
      ),
    );
  }
}
