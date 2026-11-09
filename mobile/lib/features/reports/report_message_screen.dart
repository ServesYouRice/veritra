import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/errors.dart';
import '../../core/reports_service.dart';
import '../../crypto/report_key_pins.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';

/// C6 step 4: report one received message to the instance owners
/// (docs/designs/C6-reports-franking.md, D95).
///
/// The screen says plainly what is sent (this one message, sealed), shows the
/// owners' key codes the first time a key is seen or when it changed so a
/// person can pin it, and only then sends. A community conversation reports
/// to its moderators, whose inbox waits for community roles (C4): the screen
/// says so and offers nothing.
class ReportMessageScreen extends StatefulWidget {
  const ReportMessageScreen({
    required this.state,
    required this.conversationId,
    required this.messageKey,
    super.key,
  });

  final AppState state;
  final String conversationId;
  final String messageKey;

  @override
  State<ReportMessageScreen> createState() => _ReportMessageScreenState();
}

enum _Phase { loading, ready, sending, sent, blocked }

class _ReportMessageScreenState extends State<ReportMessageScreen> {
  ReportsService? _service;
  ReportPlan? _plan;
  _Phase _phase = _Phase.loading;
  String? _message;
  String? _preview;
  bool _pinning = false;

  @override
  void initState() {
    super.initState();
    _service = widget.state.reportsService;
    _load();
  }

  Future<void> _load() async {
    final service = _service;
    if (service == null) {
      _block(context.l10n.c6ReportUnavailable);
      return;
    }
    setState(() {
      _phase = _Phase.loading;
      _message = null;
    });
    try {
      // What is sealed is the kept proof, not the message as shown now.
      final preview = await service.previewText(widget.messageKey);
      final plan = await service.prepare(widget.conversationId);
      if (!mounted) return;
      if (plan.isCommunity) {
        _block(context.l10n.c6ReportCommunityUnavailable);
        return;
      }
      setState(() {
        _plan = plan;
        _preview = preview;
        _phase = _Phase.ready;
      });
    } catch (err) {
      if (!mounted) return;
      _block(_describe(err));
    }
  }

  void _block(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.blocked;
      _message = message;
    });
  }

  String _describe(Object err) {
    final l10n = context.l10n;
    if (err is ReportFailureException) {
      return switch (err.kind) {
        ReportFailure.communityUnavailable => l10n.c6ReportCommunityUnavailable,
        ReportFailure.noRecipients => l10n.c6ReportNoOwnerKey,
        ReportFailure.notReportable => l10n.c6ReportNotReportable,
        ReportFailure.keysNotPinned => l10n.c6ReportKeysNotPinned,
        ReportFailure.alreadyReported => l10n.c6ReportAlready,
      };
    }
    // The server answers this when no owner has published a key.
    if (err is Exception && err.toString().contains('report_inbox')) {
      return l10n.c6ReportNoOwnerKey;
    }
    return describeError(err, l10n);
  }

  Future<void> _trust() async {
    final service = _service;
    final plan = _plan;
    if (service == null || plan == null || _pinning) return;
    setState(() => _pinning = true);
    try {
      await service.pinKeys(plan);
      if (!mounted) return;
      await _load();
    } catch (err) {
      if (mounted) _block(_describe(err));
    } finally {
      if (mounted) setState(() => _pinning = false);
    }
  }

  Future<void> _send() async {
    final service = _service;
    if (service == null || _phase != _Phase.ready) return;
    setState(() => _phase = _Phase.sending);
    try {
      await service.file(
        conversationId: widget.conversationId,
        messageKey: widget.messageKey,
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.sent);
    } on ReportFailureException catch (err) {
      if (!mounted) return;
      if (err.kind == ReportFailure.keysNotPinned) {
        // A key changed since the screen loaded: show the codes again.
        await _load();
        if (mounted) setState(() => _message = _describe(err));
      } else {
        _block(_describe(err));
      }
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.ready;
        _message = _describe(err);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.c6ReportTitle),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.loading =>
            const Center(child: CircularProgressIndicator.adaptive()),
          _Phase.blocked => _Notice(
              icon: Icons.report_gmailerrorred_outlined,
              text: _message ?? l10n.errorGeneric,
              action: FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(l10n.confirmCancel),
              ),
            ),
          _Phase.sent => _Notice(
              icon: Icons.check_circle_outline,
              text: l10n.c6ReportSent,
              action: FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(MaterialLocalizations.of(context).okButtonLabel),
              ),
            ),
          _Phase.ready || _Phase.sending => ListView(
              padding: const EdgeInsets.all(BoneSpacing.gutter),
              children: <Widget>[
                Text(l10n.c6ReportIntro, style: theme.textTheme.bodyMedium),
                const SizedBox(height: BoneSpacing.lg),
                Text(l10n.c6ReportPreviewLabel,
                    style: theme.textTheme.labelLarge),
                const SizedBox(height: BoneSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(BoneSpacing.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(BoneRadii.md),
                  ),
                  child: Text(
                    _preview ?? l10n.c6ReportPreviewNoText,
                    maxLines: 12,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: BoneSpacing.lg),
                ..._recipients(context),
                if (_message != null) ...<Widget>[
                  const SizedBox(height: BoneSpacing.md),
                  Text(_message!,
                      style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: BoneSpacing.xl),
                _action(context),
              ],
            ),
        },
      ),
    );
  }

  List<Widget> _recipients(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final plan = _plan;
    if (plan == null) return const <Widget>[];
    final unsure = plan.check.recipients
        .where((r) => r.status != ReportKeyStatus.pinned)
        .toList();
    if (unsure.isEmpty && plan.check.missing.isEmpty) {
      return <Widget>[
        Text(l10n.c6ReportRecipientCount(plan.check.recipients.length),
            style: theme.textTheme.bodyMedium),
      ];
    }
    return <Widget>[
      Text(l10n.c6ReportPinTitle, style: theme.textTheme.titleMedium),
      const SizedBox(height: BoneSpacing.sm),
      Text(l10n.c6ReportPinBody, style: theme.textTheme.bodyMedium),
      const SizedBox(height: BoneSpacing.sm),
      for (final r in unsure) ...<Widget>[
        SelectableText(
          l10n.c6ReportOwnerKey(shortId(r.recipient.inboxId),
              reportKeyFingerprint(r.recipient.publicKey)),
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        if (r.status == ReportKeyStatus.changed)
          Text(l10n.c6ReportKeyChanged,
              style: TextStyle(color: theme.colorScheme.error)),
        const SizedBox(height: BoneSpacing.sm),
      ],
      if (plan.check.missing.isNotEmpty)
        Text(l10n.c6ReportKeyMissing,
            style: TextStyle(color: theme.colorScheme.error)),
    ];
  }

  Widget _action(BuildContext context) {
    final l10n = context.l10n;
    final plan = _plan;
    final needsTrust = plan != null && !plan.check.allPinned;
    if (needsTrust) {
      return FilledButton(
        onPressed: _pinning ? null : _trust,
        child: Text(l10n.c6ReportTrust),
      );
    }
    return FilledButton(
      onPressed: _phase == _Phase.sending ? null : _send,
      child: _phase == _Phase.sending
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Text(l10n.c6ReportSend),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.action});

  final IconData icon;
  final String text;
  final Widget action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(BoneSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 40),
              const SizedBox(height: BoneSpacing.md),
              Text(text, textAlign: TextAlign.center),
              const SizedBox(height: BoneSpacing.xl),
              action,
            ],
          ),
        ),
      );
}
