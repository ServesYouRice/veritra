import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/server_origin.dart';
import '../../core/errors.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import 'reauth_dialog.dart';

/// K0 R3: set or replace the account's recovery key
/// (docs/designs/K0-recovery-enrollment.md, "Setup"). The key is generated
/// on this device, shown once to be written down, typed back to confirm,
/// and only its verification key and id go to the server.
class RecoveryKeyScreen extends StatelessWidget {
  const RecoveryKeyScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.recoveryKeyTitle)),
      body: SafeArea(
        child: RecoveryKeySetup(
          state: state,
          onSaved: () {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.l10n.recoveryKeySaved)));
            Navigator.of(context).maybePop();
          },
        ),
      ),
    );
  }
}

enum _SetupStep { overview, show, confirm }

/// The setup flow, also used by the forced follow-up after a recovery.
class RecoveryKeySetup extends StatefulWidget {
  const RecoveryKeySetup({
    required this.state,
    required this.onSaved,
    this.intro,
    super.key,
  });

  final AppState state;
  final VoidCallback onSaved;

  /// Replaces the usual introduction (the follow-up explains why).
  final String? intro;

  @override
  State<RecoveryKeySetup> createState() => _RecoveryKeySetupState();
}

class _RecoveryKeySetupState extends State<RecoveryKeySetup> {
  final _typed = TextEditingController();
  _SetupStep _step = _SetupStep.overview;
  RecoveryKeyDraft? _draft;
  bool _working = false;
  String? _mismatch;

  @override
  void initState() {
    super.initState();
    unawaited(widget.state.refreshRecoveryKeyStatus());
  }

  @override
  void dispose() {
    _draft?.dispose();
    _typed.clear();
    _typed.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() => _working = true);
    try {
      final draft = await widget.state.createRecoveryKeyDraft();
      if (!mounted) {
        draft.dispose();
        return;
      }
      _draft?.dispose();
      setState(() {
        _draft = draft;
        _step = _SetupStep.show;
      });
    } catch (err) {
      _showError(err);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _confirmAndSave() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _working = true;
      _mismatch = null;
    });
    try {
      if (!await widget.state.recoveryKeyMatches(draft, _typed.text)) {
        if (mounted) {
          setState(() => _mismatch = context.l10n.recoveryKeyMismatch);
        }
        return;
      }
      var result = await widget.state.saveRecoveryKey(draft);
      if (result == RecoveryActionResult.needsRecentAuth && mounted) {
        // No spinner behind the password dialog.
        setState(() => _working = false);
        if (!await confirmPasswordForRecentAuth(context, widget.state)) return;
        if (!mounted) return;
        setState(() => _working = true);
        result = await widget.state.saveRecoveryKey(draft);
      }
      if (!mounted) return;
      switch (result) {
        case RecoveryActionResult.done:
          _typed.clear();
          draft.dispose();
          setState(() {
            _draft = null;
            _step = _SetupStep.overview;
          });
          widget.onSaved();
        case RecoveryActionResult.needsRecentAuth:
        case RecoveryActionResult.alreadyEnded:
          break;
        case RecoveryActionResult.failed:
          final message = widget.state.errorFor(Ops.recoveryKey);
          if (message != null) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(message)));
          }
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _showError(Object err) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(describeError(err, context.l10n))));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(BoneSpacing.xl),
        children: switch (_step) {
          _SetupStep.overview => _overview(context),
          _SetupStep.show => _show(context),
          _SetupStep.confirm => _confirm(context),
        },
      ),
    );
  }

  /// The address to write down with the key: the one the server checks
  /// claims against, else the one this device uses.
  String? _serverAddress() =>
      widget.state.recoveryKeyStatus?.publicOrigin ??
      widget.state.session?.baseUrl;

  /// The server's own address when this device reaches it under another
  /// one, where a claim made the same way would be refused.
  String? _otherServerAddress() {
    final origin = widget.state.recoveryKeyStatus?.publicOrigin;
    final current = widget.state.session?.baseUrl;
    if (origin == null || current == null) return null;
    String canonical(String value) {
      try {
        return canonicalizeServerOrigin(value);
      } on FormatException {
        return value;
      }
    }

    return canonical(current) == canonical(origin) ? null : origin;
  }

  Widget _originWarning(BuildContext context, String origin) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: BoneSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.warning_amber_outlined,
              size: 20, color: theme.colorScheme.error),
          const SizedBox(width: BoneSpacing.md),
          Expanded(
            child: Text(
              context.l10n.recoveryKeyOriginMismatch(
                  widget.state.session?.baseUrl ?? '', origin),
              key: const ValueKey<String>('recovery-origin-mismatch'),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _overview(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final status = widget.state.recoveryKeyStatus;
    final String statusText;
    if (status == null) {
      statusText = l10n.recoveryKeyStatusUnknown;
    } else if (!status.available) {
      statusText = l10n.recoveryKeyStatusOff;
    } else if (status.configured && status.setAt != null) {
      statusText =
          l10n.recoveryKeyStatusSet(formatDate(context, status.setAt!));
    } else if (status.configured) {
      statusText = l10n.recoveryKeyStatusUnknown;
    } else {
      statusText = l10n.recoveryKeyStatusNotSet;
    }
    final configured = status?.configured ?? false;
    final off = status != null && !status.available;
    final otherAddress = _otherServerAddress();
    return <Widget>[
      Text(widget.intro ?? l10n.recoveryKeyIntro,
          style: theme.textTheme.bodyLarge),
      const SizedBox(height: BoneSpacing.lg),
      if (otherAddress != null) _originWarning(context, otherAddress),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(configured ? Icons.key : Icons.key_off_outlined),
        title: Text(l10n.recoveryKeyTitle),
        subtitle: Text(statusText),
      ),
      if (configured) ...<Widget>[
        Text(l10n.recoveryKeyReplaceNote,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: BoneSpacing.md),
      ],
      const SizedBox(height: BoneSpacing.lg),
      FilledButton.icon(
        onPressed: _working || off ? null : _generate,
        icon: const Icon(Icons.key),
        label:
            Text(configured ? l10n.recoveryKeyReplace : l10n.recoveryKeyCreate),
      ),
    ];
  }

  List<Widget> _show(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final display = _draft?.display ?? '';
    final address = _serverAddress();
    final otherAddress = _otherServerAddress();
    return <Widget>[
      Text(l10n.recoveryKeyShowTitle, style: theme.textTheme.titleLarge),
      const SizedBox(height: BoneSpacing.sm),
      Text(l10n.recoveryKeyShowDetail, style: theme.textTheme.bodyMedium),
      const SizedBox(height: BoneSpacing.xl),
      Semantics(
        // Read group by group, never as one 52-letter word.
        label: groupRecoveryKey(display).split('').join(' '),
        excludeSemantics: true,
        child: Container(
          key: const ValueKey<String>('recovery-key-display'),
          padding: const EdgeInsets.all(BoneSpacing.lg),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _displayLines(display),
            textAlign: TextAlign.center,
            style: BoneType.mono.copyWith(
              fontSize: 20,
              height: 1.6,
              letterSpacing: 2,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
      if (address != null) ...<Widget>[
        const SizedBox(height: BoneSpacing.lg),
        Text(l10n.recoveryKeyServerAddress, style: theme.textTheme.bodyMedium),
        const SizedBox(height: BoneSpacing.xs),
        SelectableText(
          address,
          key: const ValueKey<String>('recovery-server-address'),
          style: BoneType.mono.copyWith(color: theme.colorScheme.onSurface),
        ),
      ],
      if (otherAddress != null) ...<Widget>[
        const SizedBox(height: BoneSpacing.md),
        _originWarning(context, otherAddress),
      ],
      const SizedBox(height: BoneSpacing.xl),
      FilledButton(
        onPressed: () => setState(() => _step = _SetupStep.confirm),
        child: Text(l10n.recoveryKeyWritten),
      ),
    ];
  }

  /// Four groups of four per line, so the key is copied line by line.
  static String _displayLines(String display) {
    final groups = groupRecoveryKey(display).split('-');
    final lines = <String>[];
    for (var i = 0; i < groups.length; i += 4) {
      lines.add(groups
          .sublist(i, i + 4 > groups.length ? groups.length : i + 4)
          .join(' '));
    }
    return lines.join('\n');
  }

  List<Widget> _confirm(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return <Widget>[
      Text(l10n.recoveryKeyConfirmTitle, style: theme.textTheme.titleLarge),
      const SizedBox(height: BoneSpacing.sm),
      Text(l10n.recoveryKeyConfirmDetail, style: theme.textTheme.bodyMedium),
      const SizedBox(height: BoneSpacing.lg),
      TextField(
        key: const ValueKey<String>('recovery-key-confirm-field'),
        controller: _typed,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        keyboardType: TextInputType.visiblePassword,
        textCapitalization: TextCapitalization.characters,
        minLines: 2,
        maxLines: 4,
        style: BoneType.mono,
        decoration: InputDecoration(
          labelText: l10n.recoveryKeyField,
          errorText: _mismatch,
        ),
      ),
      const SizedBox(height: BoneSpacing.lg),
      FilledButton(
        onPressed: _working ? null : _confirmAndSave,
        child: _working
            ? const SizedBox.square(
                dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(l10n.recoveryKeySave),
      ),
      TextButton(
        onPressed: _working
            ? null
            : () => setState(() {
                  _mismatch = null;
                  _step = _SetupStep.show;
                }),
        child: Text(l10n.recoveryKeyShowAgain),
      ),
    ];
  }
}
