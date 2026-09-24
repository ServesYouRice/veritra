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

/// Shows the conversation's safety number so members can compare it in
/// person or by scanning each other's code.
///
/// The number is derived from the MLS group itself (its id, epoch and every
/// member's credential and signature key), never from server-provided
/// identity. It changes whenever the group's keys or members change, so a
/// stored verification turns into "changed" after any such update.
class SafetyNumberScreen extends StatefulWidget {
  const SafetyNumberScreen({
    required this.state,
    required this.conversation,
    super.key,
  });

  final AppState state;
  final Conversation conversation;

  @override
  State<SafetyNumberScreen> createState() => _SafetyNumberScreenState();
}

class _SafetyNumberScreenState extends State<SafetyNumberScreen> {
  ConversationSafetyNumber? _safety;
  PeerVerificationStatus? _status;
  bool _failed = false;
  bool _working = false;

  String? get _peerAccountId =>
      widget.conversation.isDm ? widget.conversation.peerAccountId : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final id = widget.conversation.id;
      final safety = await widget.state.conversationSafetyNumber(id);
      final peer = _peerAccountId;
      final status = peer == null
          ? null
          : await widget.state.peerVerificationStatus(id, peer);
      if (!mounted) return;
      setState(() {
        _safety = safety;
        _status = status;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _markVerified() async {
    final peer = _peerAccountId;
    if (peer == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark as verified?'),
        content: const Text(
          'Only do this after comparing the number with the other person '
          'in person or over a call you trust. Both of you must see exactly '
          'the same twelve digits.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('They match'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _saveVerification(peer);
  }

  Future<void> _saveVerification(String peer) async {
    setState(() => _working = true);
    try {
      await widget.state.markPeerVerified(widget.conversation.id, peer);
    } catch (_) {
      _showMessage('The verification could not be saved. Try again.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
    await _load();
  }

  Future<void> _scan() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const QrScanScreen(title: 'Scan safety code'),
      ),
    );
    if (scanned == null || !mounted) return;
    final bool matches;
    try {
      matches =
          await widget.state.safetyCodeMatches(widget.conversation.id, scanned);
    } catch (_) {
      _showMessage('The safety number could not be read. Try again.');
      return;
    }
    if (!mounted) return;
    if (!matches) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Codes do not match'),
          content: const Text(
            'This is not the same safety code. Make sure you scanned the code '
            'for this conversation and that both devices have received the '
            'latest messages, then try again. If it still does not match, '
            'do not treat this conversation as verified.',
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final peer = _peerAccountId;
    if (peer == null) {
      _showMessage('The codes match.');
      return;
    }
    await _saveVerification(peer);
    _showMessage('The codes match. Marked as verified.');
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final safety = _safety;
    final canScan = Platform.isAndroid || Platform.isIOS;
    return Scaffold(
      appBar: const LargeTitleBar(title: 'Safety number'),
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
                ? 'Every member of this group sees the same number. Compare '
                    'it in person or scan each other\'s code.'
                : 'Compare this number with '
                    '${accountLabel(_peerAccountId!, widget.conversation.peerUsername)} '
                    'in person, or scan each other\'s code.',
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
                  title: const Text('Safety number unavailable'),
                  subtitle: const Text(
                    'This device has not joined the encrypted group yet, or '
                    'its group state could not be read.',
                  ),
                  trailing: TextButton(
                    onPressed: _load,
                    child: const Text('Retry'),
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
                        label:
                            'Safety number ${safety.digits.split('').join(' ')}',
                        excludeSemantics: true,
                        child: SelectableText(
                          _groupDigits(safety.digits),
                          textAlign: TextAlign.center,
                          style: BoneType.mono.copyWith(
                            fontSize: 28,
                            letterSpacing: 2,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(height: BoneSpacing.lg),
                      Semantics(
                        label: 'QR code of this safety number. The other '
                            'person can scan it to compare.',
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
                    title: const Text('Status'),
                    subtitle: Text(switch (_status!) {
                      PeerVerificationStatus.verified =>
                        'You verified this number.',
                      PeerVerificationStatus.changed =>
                        'The group\'s keys or members changed since you '
                            'verified. Compare the new number again.',
                      PeerVerificationStatus.unverified => 'Not verified yet.',
                    }),
                    trailing: StatusPill(
                      label: switch (_status!) {
                        PeerVerificationStatus.verified => 'Verified',
                        PeerVerificationStatus.changed => 'Changed',
                        PeerVerificationStatus.unverified => 'Not verified',
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
                label: const Text('Scan their code'),
              ),
            if (_peerAccountId != null &&
                _status != PeerVerificationStatus.verified) ...<Widget>[
              const SizedBox(height: BoneSpacing.sm),
              OutlinedButton(
                onPressed: _working ? null : _markVerified,
                child: const Text('Mark as verified'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Groups the twelve digits in fours so they are easier to read aloud.
String _groupDigits(String digits) {
  final groups = <String>[];
  for (var start = 0; start < digits.length; start += 4) {
    final end = start + 4 < digits.length ? start + 4 : digits.length;
    groups.add(digits.substring(start, end));
  }
  return groups.join(' ');
}
