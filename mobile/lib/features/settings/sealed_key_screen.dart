import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../crypto/owner_key_watch.dart';
import '../../crypto/report_key_pins.dart' show reportKeyFingerprint;
import '../../l10n/l10n.dart';
import '../../storage/local_store.dart' show SealedKeyPin;
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';

/// L2-3: the server's sealed sender key as this app pinned it, and a changed
/// key the server shows since, which stops sealed sending until the person
/// accepts it here (`docs/crypto.md`, "Key pinning"); and the differences
/// between the owners' report keys the server lists and the proof
/// recipients this app pinned (`owner_proof_pins.dart`), for the person to
/// accept or reject (until accepted, sealed messages are tagged only to the
/// proof recipients from before). Nothing here reaches a report: reporting
/// still asks for a code comparison (D95).
class SealedKeyScreen extends StatefulWidget {
  const SealedKeyScreen({required this.state, super.key});

  final AppState state;

  @override
  State<SealedKeyScreen> createState() => _SealedKeyScreenState();
}

class _SealedKeyScreenState extends State<SealedKeyScreen> {
  late Future<SealedKeyPin?> _pin;
  late Future<int> _owners;
  late Future<List<OwnerKeyReviewItem>> _review;

  @override
  void initState() {
    super.initState();
    _pin = widget.state.sealedKeyPin();
    _owners = widget.state.sealedProvableOwnerCount();
    _review = widget.state.loadOwnerKeyReview();
  }

  Future<void> _decide(OwnerKeyReviewItem item, {required bool accept}) async {
    final l10n = context.l10n;
    if (accept) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.l2OwnerKeyAccept),
          content: Text(l10n.l2OwnerKeyAcceptWarning),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              key: const ValueKey('owner-key-accept-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.l2OwnerKeyAccept),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final done = accept
        ? await widget.state.acceptOwnerKey(item)
        : await widget.state.rejectOwnerKey(item);
    if (!mounted) return;
    if (!done) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(l10n.l2OwnerKeyStale)));
    }
    setState(() {
      _owners = widget.state.sealedProvableOwnerCount();
      _review = widget.state.loadOwnerKeyReview();
    });
  }

  Widget _reviewItem(BuildContext context, OwnerKeyReviewItem item) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final pin = item.pin;
    final listed = item.listed;
    return Padding(
      key: ValueKey('owner-key-review-${item.inboxId}'),
      padding: const EdgeInsets.only(top: BoneSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            switch (item.change) {
              OwnerKeyChange.changed => l10n.l2OwnerKeyChanged(item.inboxId),
              OwnerKeyChange.added => l10n.l2OwnerKeyAdded(item.inboxId),
              OwnerKeyChange.missing => l10n.l2OwnerKeyMissing(item.inboxId),
            },
            style: TextStyle(color: theme.colorScheme.error),
          ),
          if (pin != null) ...<Widget>[
            const SizedBox(height: BoneSpacing.xs),
            Text(l10n.l2SealedKeyPinned, style: theme.textTheme.titleSmall),
            SelectableText(
              reportKeyFingerprint(pin.publicKey),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
          if (listed != null) ...<Widget>[
            const SizedBox(height: BoneSpacing.xs),
            Text(l10n.l2SealedKeyNew, style: theme.textTheme.titleSmall),
            SelectableText(
              reportKeyFingerprint(listed.publicKey),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
          const SizedBox(height: BoneSpacing.sm),
          Wrap(
            spacing: BoneSpacing.sm,
            children: <Widget>[
              OutlinedButton(
                key: ValueKey('owner-key-reject-${item.inboxId}'),
                onPressed: () => _decide(item, accept: false),
                child: Text(l10n.l2OwnerKeyReject),
              ),
              FilledButton(
                key: ValueKey('owner-key-accept-${item.inboxId}'),
                onPressed: () => _decide(item, accept: true),
                child: Text(l10n.l2OwnerKeyAccept),
              ),
            ],
          ),
        ],
      ),
    );
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
              // L2-3: the owner report keys that differ from the pins.
              FutureBuilder<List<OwnerKeyReviewItem>>(
                future: _review,
                builder: (context, review) {
                  final items = review.data ?? const <OwnerKeyReviewItem>[];
                  if (items.isEmpty) return const SizedBox.shrink();
                  return Column(
                    key: const ValueKey('owner-key-review'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SizedBox(height: BoneSpacing.lg),
                      Text(l10n.l2OwnerKeysReviewIntro,
                          style: TextStyle(color: theme.colorScheme.error)),
                      for (final item in items) _reviewItem(context, item),
                    ],
                  );
                },
              ),
              // L2-3: who can be shown a sealed message's proof (only owners
              // whose report key this app pinned; none, no one).
              if (enabled || pin != null) ...<Widget>[
                const SizedBox(height: BoneSpacing.lg),
                FutureBuilder<int>(
                  future: _owners,
                  builder: (context, owners) {
                    final count = owners.data ?? 0;
                    return Text(
                      count == 0
                          ? l10n.l2SealedProvableNone
                          : l10n.l2SealedProvableOwners(count),
                      key: const ValueKey('sealed-provable-owners'),
                    );
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
