import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import 'connect_screen.dart' show exampleServerOrigin;
import '../../core/server_origin.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';

/// K0 R4: "Lost all your devices?" (docs/designs/K0-recovery-enrollment.md,
/// client flow). Server, username, password and recovery key start a claim;
/// the device then waits ([AccountRecoveryWaitingScreen]).
class AccountRecoveryStartScreen extends StatefulWidget {
  const AccountRecoveryStartScreen({
    required this.state,
    this.initialServer = '',
    super.key,
  });

  final AppState state;
  final String initialServer;

  @override
  State<AccountRecoveryStartScreen> createState() =>
      _AccountRecoveryStartScreenState();
}

class _AccountRecoveryStartScreenState
    extends State<AccountRecoveryStartScreen> {
  final _formKey = GlobalKey<FormState>();
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _recoveryKey = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _server.text = widget.initialServer;
    unawaited(_prefillFromRestore());
  }

  /// A restored backup names its account: recovery continues that account
  /// so its history is kept (design, client flow step 1).
  Future<void> _prefillFromRestore() async {
    final restored = await widget.state.restoredAccountForRecovery();
    if (!mounted || restored == null) return;
    setState(() {
      if (_server.text.trim().isEmpty) _server.text = restored.baseUrl;
      if (_username.text.trim().isEmpty) {
        _username.text = restored.username ?? '';
      }
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    // Typed secrets leave the controllers before they go.
    _password.clear();
    _password.dispose();
    _recoveryKey.clear();
    _recoveryKey.dispose();
    super.dispose();
  }

  String? _validateServer(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return context.l10n.connectUrlRequired;
    try {
      canonicalizeServerOrigin(raw);
    } on FormatException {
      return context.l10n.connectUrlInvalid;
    }
    if (!widget.state.config.transport.allows(raw)) {
      return widget.state.config.transport.allowLoopbackHttp
          ? context.l10n.connectUrlLoopbackOnly
          : context.l10n.connectUrlHttpsRequired;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_submitting || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);
    final password = _password.text;
    final key = _recoveryKey.text;
    try {
      final ok = await widget.state.startAccountRecovery(
        baseUrl: _server.text.trim(),
        username: _username.text.trim(),
        password: password,
        recoveryKey: key,
      );
      if (!mounted) return;
      if (ok) {
        _password.clear();
        _recoveryKey.clear();
        Navigator.of(context).maybePop();
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.recoveryStartTitle)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) {
            final busy =
                _submitting || widget.state.isBusy(Ops.accountRecovery);
            final error = widget.state.errorFor(Ops.accountRecovery);
            return Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(BoneSpacing.xl),
                children: <Widget>[
                  Text(l10n.recoveryStartDetail,
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: BoneSpacing.xl),
                  TextFormField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    validator: _validateServer,
                    decoration: InputDecoration(
                      labelText: l10n.connectInstanceUrl,
                      hintText: exampleServerOrigin,
                      prefixIcon: const Icon(Icons.dns_outlined),
                    ),
                  ),
                  const SizedBox(height: BoneSpacing.lg),
                  TextFormField(
                    controller: _username,
                    autocorrect: false,
                    autofillHints: const <String>[AutofillHints.username],
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? l10n.connectUsernameRequired
                        : null,
                    decoration: InputDecoration(
                      labelText: l10n.connectUsername,
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: BoneSpacing.lg),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const <String>[AutofillHints.password],
                    validator: (value) => (value ?? '').isEmpty
                        ? l10n.connectPasswordRequired
                        : null,
                    decoration: InputDecoration(
                      labelText: l10n.connectPassword,
                      prefixIcon: const Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: BoneSpacing.lg),
                  TextFormField(
                    key: const ValueKey<String>('recovery-key-field'),
                    controller: _recoveryKey,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    keyboardType: TextInputType.visiblePassword,
                    textCapitalization: TextCapitalization.characters,
                    minLines: 2,
                    maxLines: 4,
                    style: BoneType.mono,
                    validator: (value) => (value ?? '').trim().isEmpty
                        ? l10n.recoveryKeyRequired
                        : null,
                    decoration: InputDecoration(
                      labelText: l10n.recoveryKeyField,
                      prefixIcon: const Icon(Icons.key),
                    ),
                  ),
                  const SizedBox(height: BoneSpacing.xl),
                  FilledButton.icon(
                    onPressed: busy ? null : _submit,
                    icon: busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.restore),
                    label: Text(l10n.recoveryStartSubmit),
                  ),
                  if (error != null) ...<Widget>[
                    const SizedBox(height: BoneSpacing.lg),
                    Text(error,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error)),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Shown instead of the sign-in screen while this device holds a recovery
/// claim: when it finishes, a check now, stopping it, and the password
/// sign-in that finishes a claim whose answer was lost.
class AccountRecoveryWaitingScreen extends StatefulWidget {
  const AccountRecoveryWaitingScreen({required this.state, super.key});

  final AppState state;

  @override
  State<AccountRecoveryWaitingScreen> createState() =>
      _AccountRecoveryWaitingScreenState();
}

class _AccountRecoveryWaitingScreenState
    extends State<AccountRecoveryWaitingScreen> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirmAbandon() async {
    final l10n = context.l10n;
    final pending = widget.state.pendingAccountRecovery;
    if (pending == null || pending.needsLogin) return;
    final requestId = pending.requestId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.recoveryAbandonTitle),
        content: Text(l10n.recoveryAbandonMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.recoveryAbandon),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.state.abandonAccountRecovery(requestId: requestId);
    }
  }

  Future<void> _signIn() async {
    final password = _password.text;
    if (password.isEmpty) return;
    if (await widget.state.finishAccountRecoveryWithPassword(password)) {
      _password.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final pending = widget.state.pendingAccountRecovery;
    final busy = widget.state.isBusy(Ops.accountRecovery);
    final error = widget.state.errorFor(Ops.accountRecovery);
    final ready =
        pending != null && !pending.readyAt.isAfter(DateTime.now().toUtc());
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(BoneSpacing.xl),
              children: <Widget>[
                Icon(
                    pending?.needsLogin ?? false
                        ? Icons.login
                        : Icons.hourglass_top_outlined,
                    size: 48),
                const SizedBox(height: BoneSpacing.lg),
                Text(
                  pending?.needsLogin ?? false
                      ? l10n.recoveryLoginTitle
                      : l10n.recoveryWaitingTitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                if (pending != null) ...<Widget>[
                  const SizedBox(height: BoneSpacing.sm),
                  Text(l10n.recoveryAccountLabel(pending.username),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: BoneSpacing.lg),
                  if (pending.needsLogin) ...<Widget>[
                    Text(l10n.recoveryLoginDetail, textAlign: TextAlign.center),
                    const SizedBox(height: BoneSpacing.lg),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: const <String>[AutofillHints.password],
                      decoration:
                          InputDecoration(labelText: l10n.connectPassword),
                      onSubmitted: (_) => _signIn(),
                    ),
                    const SizedBox(height: BoneSpacing.lg),
                    FilledButton(
                      onPressed: busy ? null : _signIn,
                      child: Text(l10n.recoveryLoginSubmit),
                    ),
                  ] else ...<Widget>[
                    Text(
                      ready
                          ? l10n.recoveryReadyDetail
                          : l10n.recoveryWaitingDetail(formatDateTime(
                              context, pending.readyAt.toLocal())),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: BoneSpacing.lg),
                    FilledButton.icon(
                      onPressed:
                          busy ? null : widget.state.checkAccountRecovery,
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.sync),
                      label: Text(l10n.recoveryCheckNow),
                    ),
                  ],
                  // Once the server enrolled this device, the claim's
                  // device secret is the only way in: no Stop.
                  if (!pending.needsLogin)
                    TextButton(
                      onPressed: busy ? null : _confirmAbandon,
                      child: Text(l10n.recoveryAbandon),
                    ),
                ],
                if (error != null) ...<Widget>[
                  const SizedBox(height: BoneSpacing.lg),
                  Text(error,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
