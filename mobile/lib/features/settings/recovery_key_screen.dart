import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
          offerSavedKeyCheck: true,
          onSaved: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.recoveryKeySaved)),
            );
            Navigator.of(context).maybePop();
          },
        ),
      ),
    );
  }
}

enum _SetupStep { overview, show, confirm, checkSaved }

/// The setup flow, also used by the forced follow-up after a recovery.
class RecoveryKeySetup extends StatefulWidget {
  const RecoveryKeySetup({
    required this.state,
    required this.onSaved,
    this.intro,
    this.onBack,
    this.offerSavedKeyCheck = false,
    super.key,
  });

  final AppState state;
  final VoidCallback onSaved;

  /// U37: offers "Check my key" for the key saved earlier, when the account
  /// has one. Settings only: the forced follow-up replaces the key.
  final bool offerSavedKeyCheck;

  /// U23: the forced follow-up's way back to its previous step, or null
  /// (Settings, or a step with nothing to go back to). Offered only on the
  /// overview while no key is held: Back must not drop a key that may
  /// already be written down, which would leave the paper wrong.
  final VoidCallback? onBack;

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

  /// U37: the last "Check my key" answered that the typed text is the key.
  bool _checkedOk = false;

  /// U37: the key saved earlier, typed to check it. Never the draft's field.
  final _savedTyped = TextEditingController();

  /// U37: what the last check of a saved key found, until the text changes.
  SavedRecoveryKeyCheck? _savedResult;

  /// U24: this screen put the key on the clipboard and has not cleared it.
  bool _onClipboard = false;

  /// Clears the copy after [_clipboardLifetime] if the person never continues.
  Timer? _clipboardTimer;
  static const Duration _clipboardLifetime = Duration(seconds: 90);

  @override
  void initState() {
    super.initState();
    unawaited(widget.state.refreshRecoveryKeyStatus());
  }

  @override
  void dispose() {
    _clearClipboard();
    _draft?.dispose();
    _typed.clear();
    _typed.dispose();
    _savedTyped.clear();
    _savedTyped.dispose();
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
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
          }
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// U37: "Check my key". Runs the same [AppState.recoveryKeyMatches] as
  /// saving, but saves nothing and sends nothing.
  Future<void> _checkKey() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _working = true;
      _mismatch = null;
      _checkedOk = false;
    });
    try {
      final ok = await widget.state.recoveryKeyMatches(draft, _typed.text);
      if (!mounted) return;
      setState(() {
        _checkedOk = ok;
        if (!ok) _mismatch = context.l10n.recoveryKeyMismatch;
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// U37: "Check my key" for the key saved earlier. Checked on this device
  /// against the account's current key; nothing is saved or sent.
  Future<void> _checkSavedKey() async {
    setState(() {
      _working = true;
      _savedResult = null;
    });
    try {
      final result = await widget.state.checkSavedRecoveryKey(
        _savedTyped.text,
      );
      if (!mounted) return;
      setState(() => _savedResult = result);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Leaves the saved-key check and forgets what was typed there.
  void _leaveSavedCheck() {
    _savedTyped.clear();
    setState(() {
      _savedResult = null;
      _step = _SetupStep.overview;
    });
  }

  /// U24: the key goes to a password manager through the clipboard.
  Future<void> _copyForPasswordManager(String display) async {
    await Clipboard.setData(ClipboardData(text: groupRecoveryKey(display)));
    _onClipboard = true;
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(_clipboardLifetime, _clearClipboard);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.recoveryKeyCopied)));
  }

  /// Overwrites the copy this screen made, so the key does not stay on the
  /// clipboard and the check that follows comes from the saved copy. It is
  /// not read first: reading would show a paste notice on iOS.
  void _clearClipboard() {
    _clipboardTimer?.cancel();
    _clipboardTimer = null;
    if (!_onClipboard) return;
    _onClipboard = false;
    unawaited(Clipboard.setData(const ClipboardData(text: '')));
  }

  void _showError(Object err) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(describeError(err, context.l10n))));
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
          _SetupStep.checkSaved => _checkSaved(context),
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
          Icon(
            Icons.warning_amber_outlined,
            size: 20,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: BoneSpacing.md),
          Expanded(
            child: Text(
              context.l10n.recoveryKeyOriginMismatch(
                widget.state.session?.baseUrl ?? '',
                origin,
              ),
              key: const ValueKey<String>('recovery-origin-mismatch'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
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
      statusText = l10n.recoveryKeyStatusSet(
        formatDate(context, status.setAt!),
      );
    } else if (status.configured) {
      statusText = l10n.recoveryKeyStatusUnknown;
    } else {
      statusText = l10n.recoveryKeyStatusNotSet;
    }
    final configured = status?.configured ?? false;
    final off = status != null && !status.available;
    final otherAddress = _otherServerAddress();
    return <Widget>[
      Text(
        widget.intro ?? l10n.recoveryKeyIntro,
        style: theme.textTheme.bodyLarge,
      ),
      const SizedBox(height: BoneSpacing.lg),
      if (otherAddress != null) _originWarning(context, otherAddress),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(configured ? Icons.key : Icons.key_off_outlined),
        title: Text(l10n.recoveryKeyTitle),
        subtitle: Text(statusText),
      ),
      if (configured) ...<Widget>[
        Text(
          l10n.recoveryKeyReplaceNote,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: BoneSpacing.md),
      ],
      const SizedBox(height: BoneSpacing.lg),
      if (_draft != null)
        // U23: Back from the key keeps it, so what was written down stays
        // the key to type back.
        FilledButton.icon(
          key: const ValueKey<String>('recovery-key-show-draft'),
          onPressed:
              _working ? null : () => setState(() => _step = _SetupStep.show),
          icon: const Icon(Icons.key),
          label: Text(l10n.recoveryKeyShowAgain),
        )
      else
        FilledButton.icon(
          onPressed: _working || off ? null : _generate,
          icon: const Icon(Icons.key),
          label: Text(
            configured ? l10n.recoveryKeyReplace : l10n.recoveryKeyCreate,
          ),
        ),
      if (widget.offerSavedKeyCheck &&
          configured &&
          (status?.available ?? false)) ...<Widget>[
        const SizedBox(height: BoneSpacing.md),
        OutlinedButton.icon(
          key: const ValueKey<String>('recovery-key-check-saved'),
          onPressed: _working
              ? null
              : () => setState(() {
                    _savedTyped.clear();
                    _savedResult = null;
                    _step = _SetupStep.checkSaved;
                  }),
          icon: const Icon(Icons.fact_check_outlined),
          label: Text(l10n.recoveryKeyCheck),
        ),
      ],
      if (widget.onBack != null && _draft == null) ...<Widget>[
        const SizedBox(height: BoneSpacing.md),
        TextButton.icon(
          key: const ValueKey<String>('follow-up-back'),
          onPressed: _working ? null : widget.onBack,
          icon: const Icon(Icons.arrow_back),
          label: Text(MaterialLocalizations.of(context).backButtonTooltip),
        ),
      ],
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
          padding: const EdgeInsets.all(BoneSpacing.md),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: RecoveryKeyGroups(display: display),
        ),
      ),
      const SizedBox(height: BoneSpacing.md),
      OutlinedButton.icon(
        key: const ValueKey<String>('recovery-key-copy'),
        onPressed: display.isEmpty
            ? null
            : () => unawaited(_copyForPasswordManager(display)),
        icon: const Icon(Icons.copy_outlined),
        label: Text(l10n.recoveryKeyCopy),
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
        onPressed: () {
          _clearClipboard();
          setState(() => _step = _SetupStep.confirm);
        },
        child: Text(l10n.recoveryKeyWritten),
      ),
      TextButton(
        key: const ValueKey<String>('recovery-key-back'),
        onPressed: () {
          _clearClipboard();
          setState(() => _step = _SetupStep.overview);
        },
        child: Text(MaterialLocalizations.of(context).backButtonTooltip),
      ),
    ];
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
        onChanged: (_) {
          if (_mismatch != null || _checkedOk) {
            setState(() {
              _mismatch = null;
              _checkedOk = false;
            });
          }
        },
      ),
      const SizedBox(height: BoneSpacing.md),
      // Guidance only: saving still checks the whole key natively.
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _typed,
        builder: (context, value, _) => RecoveryKeyCheck(
          expected: _draft?.display ?? '',
          typed: value.text,
        ),
      ),
      if (_checkedOk) ...<Widget>[
        const SizedBox(height: BoneSpacing.sm),
        Semantics(
          liveRegion: true,
          child: Text(
            l10n.recoveryKeyCheckOk,
            key: const ValueKey<String>('recovery-key-check-ok'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
      const SizedBox(height: BoneSpacing.md),
      OutlinedButton.icon(
        key: const ValueKey<String>('recovery-key-check-button'),
        onPressed: _working ? null : _checkKey,
        icon: const Icon(Icons.fact_check_outlined),
        label: Text(l10n.recoveryKeyCheck),
      ),
      const SizedBox(height: BoneSpacing.sm),
      FilledButton(
        onPressed: _working ? null : _confirmAndSave,
        child: _working
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(l10n.recoveryKeySave),
      ),
      TextButton(
        onPressed: _working
            ? null
            : () => setState(() {
                  _mismatch = null;
                  _checkedOk = false;
                  _step = _SetupStep.show;
                }),
        child: Text(l10n.recoveryKeyShowAgain),
      ),
    ];
  }

  List<Widget> _checkSaved(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final result = _savedResult;
    final message = savedRecoveryKeyCheckMessage(l10n, result);
    final good = result == SavedRecoveryKeyCheck.current;
    final states = theme.extension<VeritraStateColors>() ??
        (theme.brightness == Brightness.dark
            ? VeritraStateColors.dark
            : VeritraStateColors.light);
    return <Widget>[
      Text(l10n.recoveryKeyCheckSavedTitle, style: theme.textTheme.titleLarge),
      const SizedBox(height: BoneSpacing.sm),
      Text(l10n.recoveryKeyCheckSavedDetail, style: theme.textTheme.bodyMedium),
      const SizedBox(height: BoneSpacing.lg),
      TextField(
        key: const ValueKey<String>('recovery-key-check-saved-field'),
        controller: _savedTyped,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        keyboardType: TextInputType.visiblePassword,
        textCapitalization: TextCapitalization.characters,
        minLines: 2,
        maxLines: 4,
        style: BoneType.mono,
        decoration: InputDecoration(labelText: l10n.recoveryKeyField),
        onChanged: (_) {
          if (_savedResult != null) setState(() => _savedResult = null);
        },
      ),
      if (message != null) ...<Widget>[
        const SizedBox(height: BoneSpacing.md),
        Semantics(
          liveRegion: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                good ? Icons.check_circle : Icons.error_outline,
                size: 20,
                color: good ? states.verified : theme.colorScheme.error,
              ),
              const SizedBox(width: BoneSpacing.md),
              Expanded(
                child: Text(
                  message,
                  key: const ValueKey<String>(
                    'recovery-key-check-saved-result',
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: good
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: BoneSpacing.lg),
      FilledButton.icon(
        key: const ValueKey<String>('recovery-key-check-saved-button'),
        onPressed: _working ? null : _checkSavedKey,
        icon: _working
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.fact_check_outlined),
        label: Text(l10n.recoveryKeyCheck),
      ),
      TextButton(
        key: const ValueKey<String>('recovery-key-check-saved-back'),
        onPressed: _working ? null : _leaveSavedCheck,
        child: Text(MaterialLocalizations.of(context).backButtonTooltip),
      ),
    ];
  }
}

/// U37: the answer to a check of a saved key, or null while there is none.
String? savedRecoveryKeyCheckMessage(
  AppLocalizations l10n,
  SavedRecoveryKeyCheck? result,
) =>
    switch (result) {
      null => null,
      SavedRecoveryKeyCheck.current => l10n.recoveryKeyCheckSavedCurrent,
      SavedRecoveryKeyCheck.notCurrent => l10n.recoveryKeyCheckSavedNotCurrent,
      SavedRecoveryKeyCheck.notAKey => l10n.recoveryKeyUnreadable,
      SavedRecoveryKeyCheck.unknown => l10n.recoveryKeyCheckSavedUnknown,
    };

/// The 13 groups of [display], or fewer for a shorter text.
List<String> recoveryKeyGroups(String display) =>
    display.isEmpty ? const <String>[] : groupRecoveryKey(display).split('-');

/// U24: the key as 13 numbered groups, four to a row, so it is copied and
/// checked group by group.
class RecoveryKeyGroups extends StatelessWidget {
  const RecoveryKeyGroups({required this.display, super.key});

  final String display;

  static const int perRow = 4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = recoveryKeyGroups(display);
    final rows = <Widget>[];
    for (var start = 0; start < groups.length; start += perRow) {
      final cells = <Widget>[];
      for (var i = start; i < start + perRow; i++) {
        cells.add(
          Expanded(
            child: i < groups.length
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: BoneSpacing.xs,
                      vertical: BoneSpacing.xs,
                    ),
                    child: Column(
                      children: <Widget>[
                        Text(
                          '${i + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            groups[i],
                            key: ValueKey<String>(
                              'recovery-key-group-${i + 1}',
                            ),
                            maxLines: 1,
                            style: BoneType.mono.copyWith(
                              fontSize: 20,
                              letterSpacing: 2,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        );
      }
      rows.add(
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// How one typed group compares with the key shown.
enum RecoveryGroupMark { pending, correct, wrong }

/// Typed key text as the native decoder reads it: separators dropped, upper
/// case, `O` as 0 and `I`/`L` as 1 (`crypto/rust/src/recovery.rs`).
String canonicalRecoveryKeyText(String typed) {
  final upper = normalizeRecoveryKeyInput(typed).toUpperCase();
  final out = StringBuffer();
  for (final unit in upper.split('')) {
    out.write(switch (unit) {
      'O' => '0',
      'I' || 'L' => '1',
      _ => unit,
    });
  }
  return out.toString();
}

/// One mark per group of [expected] (the canonical display) for [typed]. A
/// group still being typed is pending while it agrees so far. Guidance
/// only: it never decides whether the key is accepted.
List<RecoveryGroupMark> recoveryGroupMarks(String expected, String typed) {
  final canonical = canonicalRecoveryKeyText(typed);
  final groups = recoveryKeyGroups(expected);
  final marks = <RecoveryGroupMark>[];
  for (var i = 0; i < groups.length; i++) {
    final start = i * 4;
    if (canonical.length <= start) {
      marks.add(RecoveryGroupMark.pending);
      continue;
    }
    final end = start + groups[i].length;
    final chunk = canonical.substring(
      start,
      canonical.length < end ? canonical.length : end,
    );
    if (chunk.length == groups[i].length) {
      marks.add(
        chunk == groups[i]
            ? RecoveryGroupMark.correct
            : RecoveryGroupMark.wrong,
      );
    } else {
      marks.add(
        groups[i].startsWith(chunk)
            ? RecoveryGroupMark.pending
            : RecoveryGroupMark.wrong,
      );
    }
  }
  return marks;
}

/// U24: a tick for each group typed correctly, and the number of the first
/// wrong one. It names groups by number only and never shows the key.
class RecoveryKeyCheck extends StatelessWidget {
  const RecoveryKeyCheck({
    required this.expected,
    required this.typed,
    super.key,
  });

  /// The canonical display of the key being confirmed.
  final String expected;
  final String typed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final states = theme.extension<VeritraStateColors>() ??
        (theme.brightness == Brightness.dark
            ? VeritraStateColors.dark
            : VeritraStateColors.light);
    final marks = recoveryGroupMarks(expected, typed);
    final wrong = marks.indexOf(RecoveryGroupMark.wrong);
    final matched =
        marks.where((mark) => mark == RecoveryGroupMark.correct).length;
    final tooLong = canonicalRecoveryKeyText(typed).length > expected.length;
    final String? message;
    if (wrong >= 0) {
      message = l10n.recoveryKeyGroupWrong(wrong + 1);
    } else if (tooLong) {
      message = l10n.recoveryKeyTooLong;
    } else if (typed.trim().isEmpty) {
      message = null;
    } else {
      message = l10n.recoveryKeyGroupsMatched(matched);
    }
    final problem = wrong >= 0 || tooLong;
    return Column(
      key: const ValueKey<String>('recovery-key-check'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ExcludeSemantics(
          child: Wrap(
            spacing: BoneSpacing.xs,
            runSpacing: BoneSpacing.xs,
            children: <Widget>[
              for (var i = 0; i < marks.length; i++)
                _GroupMark(
                  key: ValueKey<String>('recovery-key-mark-${i + 1}'),
                  number: i + 1,
                  mark: marks[i],
                  correctColor: states.verified,
                ),
            ],
          ),
        ),
        if (message != null) ...<Widget>[
          const SizedBox(height: BoneSpacing.sm),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              key: const ValueKey<String>('recovery-key-check-message'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: problem
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _GroupMark extends StatelessWidget {
  const _GroupMark({
    required this.number,
    required this.mark,
    required this.correctColor,
    super.key,
  });

  final int number;
  final RecoveryGroupMark mark;
  final Color correctColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, Color color) = switch (mark) {
      RecoveryGroupMark.correct => (Icons.check_circle, correctColor),
      RecoveryGroupMark.wrong => (Icons.cancel, theme.colorScheme.error),
      RecoveryGroupMark.pending => (
          Icons.radio_button_unchecked,
          theme.colorScheme.outline,
        ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 2),
        Text(
          '$number',
          style: theme.textTheme.labelMedium?.copyWith(
            color: mark == RecoveryGroupMark.wrong
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: BoneSpacing.xs),
      ],
    );
  }
}
