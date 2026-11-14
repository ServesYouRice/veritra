import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../crypto/owner_key_watch.dart';
import '../../crypto/report_key_pins.dart' show reportKeyFingerprint;
import '../../l10n/l10n.dart';
import '../../storage/local_store.dart' show SealedKeyPin;
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';

/// L2-3: the server's sealed sender key as this app pinned it, and a changed
/// key the server shows since, which stops sealed sending until the person
/// accepts it here (`docs/crypto.md`, "Key pinning"); and the differences
/// between the owners' report keys the server lists and the proof
/// recipients this app pinned (`owner_proof_pins.dart`), for the person to
/// accept or reject (until accepted, sealed messages are tagged only to the
/// proof recipients from before). Nothing here reaches a report: reporting
/// still asks for a code comparison (D95).
///
/// U26: the screen leads with On or Off and one line; a change asks a
/// question a person can answer, with the safe answer (keep what was
/// pinned) as the main button; the key codes wait under "Technical
/// details".
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
  bool _showCodes = false;

  /// The person answered "no" to the changed server key on this visit. It
  /// changes nothing stored: the changed key stays refused, as it was.
  bool _keptOldKey = false;

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

  /// A key code, shown only under "Technical details".
  Widget _code(BuildContext context, String label, List<int> key,
      {Key? valueKey}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: BoneSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: theme.textTheme.titleSmall),
          SelectableText(
            reportKeyFingerprint(key),
            key: valueKey,
            style: BoneType.mono.copyWith(color: theme.colorScheme.onSurface),
          ),
        ],
      ),
    );
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            switch (item.change) {
              OwnerKeyChange.changed => l10n.l2OwnerKeyChanged(item.inboxId),
              OwnerKeyChange.added => l10n.l2OwnerKeyAdded(item.inboxId),
              OwnerKeyChange.missing => l10n.l2OwnerKeyMissing(item.inboxId),
            },
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: BoneSpacing.xs),
          Text(l10n.l2OwnerKeyQuestion, style: theme.textTheme.titleSmall),
          if (_showCodes) ...<Widget>[
            if (pin != null)
              _code(context, l10n.l2SealedKeyPinned, pin.publicKey),
            if (listed != null)
              _code(context, l10n.l2SealedKeyNew, listed.publicKey),
          ],
          const SizedBox(height: BoneSpacing.sm),
          // The safe answer is the main button: keep what was pinned.
          FilledButton(
            key: ValueKey('owner-key-reject-${item.inboxId}'),
            onPressed: () => _decide(item, accept: false),
            child: Text(l10n.l2OwnerKeyReject),
          ),
          const SizedBox(height: BoneSpacing.xs),
          OutlinedButton(
            key: ValueKey('owner-key-accept-${item.inboxId}'),
            onPressed: () => _decide(item, accept: true),
            child: Text(l10n.l2OwnerKeyAcceptAnswer),
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

  /// The changed server key, as a question. Its codes are under "Technical
  /// details".
  List<Widget> _keyQuestion(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (_keptOldKey) {
      return <Widget>[
        Text(l10n.l2SealedKeyKept,
            key: const ValueKey('sealed-key-kept'),
            style: theme.textTheme.bodyMedium),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => setState(() => _keptOldKey = false),
            child: Text(l10n.l2SealedKeyChangeAnswer),
          ),
        ),
      ];
    }
    return <Widget>[
      Text(l10n.l2SealedKeyQuestion,
          key: const ValueKey('sealed-key-question'),
          style: theme.textTheme.titleMedium),
      const SizedBox(height: BoneSpacing.xs),
      Text(l10n.l2SealedKeyChanged, style: theme.textTheme.bodyMedium),
      const SizedBox(height: BoneSpacing.md),
      // The safe answer is the main button: the changed key stays refused.
      FilledButton(
        key: const ValueKey('sealed-key-keep'),
        onPressed: () => setState(() => _keptOldKey = true),
        child: Text(l10n.l2SealedKeyKeep),
      ),
      const SizedBox(height: BoneSpacing.xs),
      OutlinedButton(
        key: const ValueKey('sealed-key-accept'),
        onPressed: _accept,
        child: Text(l10n.l2SealedKeyAcceptAnswer),
      ),
    ];
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
          final changed =
              pin != null && pin.changed && pin.seenPublicKey != null;
          final on = enabled && pin != null && !changed;
          final summary = switch ((pin, enabled)) {
            _ when changed => l10n.l2SealedSummaryChanged,
            (null, false) => l10n.l2SealedKeyOff,
            (null, true) => l10n.l2SealedKeyNone,
            (_, false) => l10n.l2SealedSummaryNotOffered,
            _ => l10n.l2SealedSummaryOn,
          };
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xl,
            ),
            children: <Widget>[
              TileGroup(
                children: <Widget>[
                  ListTile(
                    key: const ValueKey('sealed-status'),
                    title: Text(l10n.l2SealedKeyTile),
                    subtitle:
                        Text(summary, key: const ValueKey('sealed-summary')),
                    trailing: StatusPill(
                      label: on ? l10n.l2SealedOn : l10n.l2SealedOff,
                      tone: on
                          ? StatusTone.verified
                          : changed
                              ? StatusTone.warning
                              : StatusTone.neutral,
                    ),
                  ),
                ],
              ),
              if (changed) ...<Widget>[
                const SizedBox(height: BoneSpacing.lg),
                ..._keyQuestion(context),
              ],
              // L2-3: the owner report keys that differ from the pins.
              FutureBuilder<List<OwnerKeyReviewItem>>(
                future: _review,
                builder: (context, review) {
                  final items = review.data ?? const <OwnerKeyReviewItem>[];
                  if (items.isEmpty) return const SizedBox.shrink();
                  return Column(
                    key: const ValueKey('owner-key-review'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const SizedBox(height: BoneSpacing.xl),
                      Text(l10n.l2OwnerKeysReviewIntro,
                          style: theme.textTheme.bodyMedium),
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
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: BoneSpacing.lg),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('sealed-technical-details'),
                  onPressed: () => setState(() => _showCodes = !_showCodes),
                  icon:
                      Icon(_showCodes ? Icons.expand_less : Icons.expand_more),
                  label: Text(l10n.l2SealedTechnicalDetails),
                ),
              ),
              if (_showCodes) ...<Widget>[
                Text(l10n.l2SealedKeyIntro, style: theme.textTheme.bodySmall),
                if (pin != null)
                  _code(context, l10n.l2SealedKeyPinned, pin.publicKey,
                      valueKey: const ValueKey('sealed-key-pinned')),
                if (changed)
                  _code(context, l10n.l2SealedKeyNew, pin.seenPublicKey!,
                      valueKey: const ValueKey('sealed-key-seen')),
              ],
            ],
          );
        },
      ),
    );
  }
}
