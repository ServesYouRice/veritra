import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../crypto/crypto_service.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';
import '../auth/qr_scan_screen.dart';
import '../../l10n/l10n.dart';

/// Shows the conversation's safety number so members can compare it in
/// person or by scanning each other's code.
///
/// The number (v2) is derived from the MLS group itself: its id and every
/// member device's credential and signature key, never server-provided
/// identity. Routine commits keep it; a device that joins, leaves or changes
/// its signing key changes it, so a stored verification reads "changed".
/// Groups show the number for a live comparison only; only DMs store it.
class SafetyNumberScreen extends StatefulWidget {
  const SafetyNumberScreen({
    required this.state,
    required this.conversation,
    this.scanCode,
    super.key,
  });

  final AppState state;
  final Conversation conversation;

  /// Opens the camera and returns the scanned code. Replaced in tests; the
  /// scan button only appears on phones, or when this is given.
  @visibleForTesting
  final Future<String?> Function(BuildContext context)? scanCode;

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

/// How a try to store a verification ended.
enum _Saved { saved, numberChanged, failed }

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  ConversationSafetyNumber? _safety;
  PeerVerificationStatus? _status;
  bool _failed = false;
  bool _working = false;

  /// Bumped by every load; an answer from an older one is dropped.
  int _loadGeneration = 0;
  bool _loading = false;
  bool _reloadAfter = false;

  String? get _peerAccountId =>
      widget.conversation.isDm ? widget.conversation.peerAccountId : null;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  /// A device can join, leave or change its signing key through a commit
  /// applied in the background, which changes the number and what a stored
  /// verification means. The app announces many unrelated changes, so loads
  /// never overlap: one runs, and one more follows if anything was announced
  /// meanwhile.
  void _onStateChanged() {
    if (_loading) {
      _reloadAfter = true;
      return;
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    _loading = true;
    if (mounted && _failed) setState(() => _failed = false);
    try {
      final id = widget.conversation.id;
      final safety = await widget.state.conversationSafetyNumber(id);
      final peer = _peerAccountId;
      final status = peer == null
          ? null
          : await widget.state.peerVerificationStatus(id, peer);
      if (!mounted || generation != _loadGeneration) return;
      final unchanged = _safety?.qrPayload == safety.qrPayload &&
          _safety?.digits == safety.digits &&
          _status == status;
      if (!unchanged) {
        setState(() {
          _safety = safety;
          _status = status;
        });
      }
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _failed = true);
    } finally {
      if (generation == _loadGeneration) {
        _loading = false;
        if (_reloadAfter) {
          _reloadAfter = false;
          if (mounted) unawaited(_load());
        }
      }
    }
  }

  Future<void> _markVerified() async {
    final peer = _peerAccountId;
    // The number the person is looking at when they start. If the screen
    // shows a different one by the time they confirm, or the app's own
    // number differs when it stores, nothing is saved.
    final compared = _safety;
    if (peer == null || compared == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.safetyMarkTitle),
        content: Text(context.l10n.safetyMarkMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.safetyTheyMatch),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = _safety?.qrPayload == compared.qrPayload
        ? await _saveVerification(peer, compared.qrPayload)
        : _Saved.numberChanged;
    _reportSave(result);
  }

  /// Stores the verification for the number whose code is [comparedCode].
  /// Never touches the screen once it is gone.
  Future<_Saved> _saveVerification(String peer, String comparedCode) async {
    if (mounted) setState(() => _working = true);
    try {
      final stored = await widget.state.markPeerVerifiedIfMatches(
          widget.conversation.id, peer, comparedCode);
      return stored ? _Saved.saved : _Saved.numberChanged;
    } catch (_) {
      return _Saved.failed;
    } finally {
      if (mounted) setState(() => _working = false);
      if (mounted) unawaited(_load());
    }
  }

  /// Says what a refused or failed save means; a success shows in the status.
  void _reportSave(_Saved result, {String Function(AppLocalizations)? saved}) {
    switch (result) {
      case _Saved.saved:
        if (saved != null) _showMessage(saved);
      case _Saved.numberChanged:
        _showMessage((l10n) => l10n.safetyChangedWhileComparing);
      case _Saved.failed:
        _showMessage((l10n) => l10n.safetySaveFailed);
    }
  }

  Future<void> _scan() async {
    final scanner = widget.scanCode;
    final scanned = scanner != null
        ? await scanner(context)
        : await Navigator.of(context).push<String>(
            MaterialPageRoute<String>(
              builder: (_) => QrScanScreen(title: context.l10n.safetyScanTitle),
            ),
          );
    if (scanned == null || !mounted) return;
    final bool matches;
    try {
      matches =
          await widget.state.safetyCodeMatches(widget.conversation.id, scanned);
    } catch (_) {
      _showMessage((l10n) => l10n.safetyReadFailed);
      return;
    }
    if (!mounted) return;
    if (!matches) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.safetyMismatchTitle),
          content: Text(context.l10n.safetyMismatchMessage),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.commonOk),
            ),
          ],
        ),
      );
      return;
    }
    final peer = _peerAccountId;
    if (peer == null) {
      _showMessage((l10n) => l10n.safetyCodesMatch);
      return;
    }
    // The scanned code is what was compared; it is stored only if it is still
    // the conversation's number.
    final result = await _saveVerification(peer, scanned);
    _reportSave(result, saved: (l10n) => l10n.safetyCodesMatchVerified);
  }

  /// Shows [text] unless the screen is gone; the strings are read only then.
  void _showMessage(String Function(AppLocalizations l10n) text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text(context.l10n))));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final safety = _safety;
    final canScan =
        widget.scanCode != null || Platform.isAndroid || Platform.isIOS;
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.safetyTitle),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          BoneSpacing.gutter,
          BoneSpacing.sm,
          BoneSpacing.gutter,
          BoneSpacing.xl,
        ),
        children: <Widget>[
          Text(
            _peerAccountId == null
                ? l10n.safetyGroupIntro
                : l10n.safetyPeerIntro(
                    accountLabel(
                      _peerAccountId!,
                      widget.conversation.peerUsername,
                    ),
                  ),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: BoneSpacing.lg),
          if (_failed)
            TileGroup(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(l10n.safetyUnavailable),
                  subtitle: Text(l10n.safetyUnavailableDetail),
                  trailing: TextButton(
                    onPressed: _load,
                    child: Text(l10n.commonRetry),
                  ),
                ),
              ],
            )
          else if (safety == null)
            const Center(child: CircularProgressIndicator())
          else ...<Widget>[
            TileGroup(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(BoneSpacing.lg),
                  child: Column(
                    children: <Widget>[
                      Semantics(
                        label: l10n.safetyDigitsSemantics(
                          _digitGroups(safety.digits).join(', '),
                        ),
                        excludeSemantics: true,
                        child: SelectableText(
                          _digitLines(safety.digits),
                          textAlign: TextAlign.center,
                          style: BoneType.mono.copyWith(
                            fontSize: 22,
                            height: 1.5,
                            letterSpacing: 1,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(height: BoneSpacing.lg),
                      Semantics(
                        label: l10n.safetyQrSemantics,
                        child: Container(
                          // QR codes need a light, uniform quiet zone to scan
                          // reliably, independent of app theme.
                          padding: const EdgeInsets.all(BoneSpacing.md),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(BoneRadii.md),
                          ),
                          child: QrImageView(
                            data: safety.qrPayload,
                            version: QrVersions.auto,
                            size: 200,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_status != null) ...<Widget>[
              const SizedBox(height: BoneSpacing.lg),
              TileGroup(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: Text(l10n.backupSectionStatus),
                    subtitle: Text(switch (_status!) {
                      PeerVerificationStatus.verified =>
                        l10n.safetyVerifiedDetail,
                      PeerVerificationStatus.changed =>
                        l10n.safetyChangedDetail,
                      PeerVerificationStatus.unverified =>
                        l10n.safetyUnverifiedDetail,
                    }),
                    trailing: StatusPill(
                      label: switch (_status!) {
                        PeerVerificationStatus.verified => l10n.safetyVerified,
                        PeerVerificationStatus.changed => l10n.safetyChanged,
                        PeerVerificationStatus.unverified =>
                          l10n.safetyUnverified,
                      },
                      tone: switch (_status!) {
                        PeerVerificationStatus.verified => StatusTone.verified,
                        PeerVerificationStatus.changed => StatusTone.warning,
                        PeerVerificationStatus.unverified => StatusTone.neutral,
                      },
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: BoneSpacing.lg),
            if (canScan)
              FilledButton.icon(
                onPressed: _working ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(l10n.safetyScanTheirCode),
              ),
            if (_peerAccountId != null &&
                _status != PeerVerificationStatus.verified) ...<Widget>[
              const SizedBox(height: BoneSpacing.sm),
              OutlinedButton(
                onPressed: _working ? null : _markVerified,
                child: Text(l10n.safetyMarkVerified),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The digits in groups of five, the size people read aloud and compare.
List<String> _digitGroups(String digits) => <String>[
      for (var start = 0; start < digits.length; start += 5)
        digits.substring(
            start, start + 5 < digits.length ? start + 5 : digits.length),
    ];

/// Four groups per line, so sixty digits fit a phone in three lines.
String _digitLines(String digits) {
  final groups = _digitGroups(digits);
  return <String>[
    for (var start = 0; start < groups.length; start += 4)
      groups
          .sublist(start, start + 4 < groups.length ? start + 4 : groups.length)
          .join(' '),
  ].join('\n');
}
