import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../crypto/report_key_pins.dart' show reportKeyFingerprint;
import '../../l10n/l10n.dart';
import '../../storage/local_store.dart' show SealedKeyPin;
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';

/// L2-3: the server's sealed sender key as this app pinned it, and a changed
/// key the server shows since, which stops sealed sending until the person
/// accepts it here (`docs/crypto.md`, "Key pinning").
class SealedKeyScreen extends StatefulWidget {
  const SealedKeyScreen({required this.state, super.key});

  final AppState state;

  @override
  State<SealedKeyScreen> createState() => _SealedKeyScreenState();
}

class _SealedKeyScreenState extends State<SealedKeyScreen> {
  late Future<SealedKeyPin?> _pin;

  @override
  void initState() {
    super.initState();
    _pin = widget.state.sealedKeyPin();
  }

  Future<void> _accept() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.l2SealedKeyAccept),
        content: Text(l10n.l2SealedKeyAcceptWarning),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.l2SealedKeyAccept),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.state.acceptSealedKey();
    if (!mounted) return;
    setState(() {
      _pin = widget.state.sealedKeyPin();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.l2SealedKeyTitle),
      body: FutureBuilder<SealedKeyPin?>(
        future: _pin,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final pin = snapshot.data;
          final enabled = widget.state.sealedSender?.enabled ?? false;
          return ListView(
            padding: const EdgeInsets.all(BoneSpacing.lg),
            children: <Widget>[
              Text(l10n.l2SealedKeyIntro, style: theme.textTheme.bodyMedium),
              const SizedBox(height: BoneSpacing.lg),
              if (!enabled && pin == null)
                Text(l10n.l2SealedKeyOff)
              else if (pin == null)
                Text(l10n.l2SealedKeyNone)
              else ...<Widget>[
                Text(l10n.l2SealedKeyPinned, style: theme.textTheme.titleSmall),
                const SizedBox(height: BoneSpacing.xs),
                SelectableText(
                  reportKeyFingerprint(pin.publicKey),
                  key: const ValueKey('sealed-key-pinned'),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                if (pin.changed && pin.seenPublicKey != null) ...<Widget>[
                  const SizedBox(height: BoneSpacing.lg),
                  Text(l10n.l2SealedKeyChanged,
                      style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: BoneSpacing.sm),
                  Text(l10n.l2SealedKeyNew, style: theme.textTheme.titleSmall),
                  const SizedBox(height: BoneSpacing.xs),
                  SelectableText(
                    reportKeyFingerprint(pin.seenPublicKey!),
                    key: const ValueKey('sealed-key-seen'),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: BoneSpacing.lg),
                  FilledButton(
                    onPressed: _accept,
                    child: Text(l10n.l2SealedKeyAccept),
                  ),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}
