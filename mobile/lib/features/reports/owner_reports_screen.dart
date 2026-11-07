import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/errors.dart';
import '../../core/reports_service.dart';
import '../../crypto/report_key_pins.dart';
import '../../l10n/l10n.dart';
import '../../ui/confirm.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';

/// C6 step 4: the instance owner's report inbox (docs/designs/C6-reports-
/// franking.md, D95). Shows this device's report key (its code, for people
/// who pin it), the reports sent to this owner and, per report, the revealed
/// message and a check against the server's record. The community moderator
/// inbox waits for community roles (C4) and is shown as unavailable.
class OwnerReportsScreen extends StatefulWidget {
  const OwnerReportsScreen({
    required this.state,
    required this.reauthenticate,
    super.key,
  });

  final AppState state;

  /// Publishing a key is credential-sensitive (the server answers
  /// `recent_auth_required`), so the person proves themselves first.
  final Future<bool> Function(BuildContext context) reauthenticate;

  @override
  State<OwnerReportsScreen> createState() => _OwnerReportsScreenState();
}

class _OwnerReportsScreenState extends State<OwnerReportsScreen> {
  ReportsService? _service;
  OwnerReportKeyStatus? _key;
  List<OpenedReport>? _reports;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service = widget.state.reportsService;
    _load();
  }

  Future<void> _load() async {
    final service = _service;
    if (service == null) {
      setState(() => _error = context.l10n.c6ReportUnavailable);
      return;
    }
    try {
      final key = await service.keyStatus();
      final rows = await service.list();
      final opened = <OpenedReport>[
        for (final row in rows) await service.open(row),
      ];
      if (!mounted) return;
      setState(() {
        _key = key;
        _reports = opened;
        _error = null;
      });
    } catch (err) {
      if (mounted) setState(() => _error = describeError(err, context.l10n));
    }
  }

  Future<void> _publish({required bool create, required bool replace}) async {
    final service = _service;
    if (service == null || _busy) return;
    final l10n = context.l10n;
    if (create) {
      final ok = await confirmAction(
        context,
        title: l10n.c6ReportsKeyCreateTitle,
        message: l10n.c6ReportsKeyCreateBody,
        confirmLabel:
            replace ? l10n.c6ReportsKeyReplace : l10n.c6ReportsKeyCreate,
        destructive: replace,
      );
      if (!ok || !mounted) return;
    }
    if (!await widget.reauthenticate(context) || !mounted) return;
    setState(() => _busy = true);
    try {
      if (create) {
        await service.createKey(replace: replace);
      } else {
        await service.publishKey();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.c6ReportsKeyReady)));
      await _load();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(err, l10n))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDetail(OpenedReport report) async {
    final service = _service;
    if (service == null) return;
    final dismissed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            OwnerReportDetailScreen(service: service, report: report),
      ),
    );
    if (dismissed == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final reports = _reports;
    final key = _key;
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.c6ReportsTitle),
      body: SafeArea(
        child: _error != null && reports == null
            ? Center(child: Text(_error!, textAlign: TextAlign.center))
            : reports == null || key == null
                ? const Center(child: CircularProgressIndicator.adaptive())
                : ListView(
                    children: <Widget>[
                      SectionHeader(l10n.c6ReportsKeySection),
                      _keyTile(context, key),
                      SectionHeader(l10n.c6ReportsTitle),
                      if (reports.isEmpty)
                        EmptyState(
                          icon: Icons.flag_outlined,
                          title: l10n.c6ReportsEmpty,
                          message: l10n.c6ReportsEmptyDetail,
                        )
                      else
                        TileGroup(children: <Widget>[
                          for (final report in reports)
                            ListTile(
                              leading: Icon(report.isOpen
                                  ? Icons.flag_outlined
                                  : Icons.lock_outline),
                              title: Text(
                                report.text ??
                                    (report.isOpen
                                        ? l10n.c6ReportsNoText
                                        : l10n.c6ReportsLocked),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(l10n.c6ReportsFiled(formatDateTime(
                                  context, report.row.createdAt))),
                              onTap: () => _openDetail(report),
                            ),
                        ]),
                      SectionHeader(l10n.c6ReportsCommunity),
                      TileGroup(children: <Widget>[
                        ListTile(
                          enabled: false,
                          leading: const Icon(Icons.groups_outlined),
                          title: Text(l10n.c6ReportsCommunity),
                          subtitle: Text(l10n.c6ReportsCommunityUnavailable),
                        ),
                      ]),
                    ],
                  ),
      ),
    );
  }

  Widget _keyTile(BuildContext context, OwnerReportKeyStatus key) {
    final l10n = context.l10n;
    final active = key.state == OwnerReportKeyState.active;
    return TileGroup(children: <Widget>[
      ListTile(
        leading: Icon(active ? Icons.key : Icons.key_off_outlined),
        title: Text(active ? l10n.c6ReportsKeyActive : l10n.c6ReportsKeyNone),
        subtitle: active && key.publicKey != null
            ? SelectableText(
                l10n.c6ReportsKeyCode(reportKeyFingerprint(key.publicKey!)))
            : null,
      ),
      if (!active)
        ListTile(
          leading: const Icon(Icons.add),
          title: Text(l10n.c6ReportsKeyCreate),
          enabled: !_busy,
          onTap: () => _publish(create: true, replace: false),
        )
      else ...<Widget>[
        ListTile(
          leading: const Icon(Icons.publish_outlined),
          title: Text(l10n.c6ReportsKeyPublish),
          enabled: !_busy,
          onTap: () => _publish(create: false, replace: false),
        ),
        ListTile(
          leading: const Icon(Icons.autorenew),
          title: Text(l10n.c6ReportsKeyReplace),
          enabled: !_busy,
          onTap: () => _publish(create: true, replace: true),
        ),
      ],
    ]);
  }
}

/// One opened report: the revealed message, who filed and who sent it, and a
/// check against the server's record, on request (it tells the server which
/// message the report is about, so it is never automatic).
class OwnerReportDetailScreen extends StatefulWidget {
  const OwnerReportDetailScreen({
    required this.service,
    required this.report,
    super.key,
  });

  final ReportsService service;
  final OpenedReport report;

  @override
  State<OwnerReportDetailScreen> createState() =>
      _OwnerReportDetailScreenState();
}

class _OwnerReportDetailScreenState extends State<OwnerReportDetailScreen> {
  ReportVerification? _verification;
  bool _checking = false;
  String? _error;

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final result = await widget.service.verify(widget.report);
      if (mounted) setState(() => _verification = result);
    } catch (err) {
      if (mounted) setState(() => _error = describeError(err, context.l10n));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _dismiss() async {
    final l10n = context.l10n;
    final ok = await confirmAction(
      context,
      title: l10n.c6ReportsDismissTitle,
      message: l10n.c6ReportsDismissBody,
      confirmLabel: l10n.c6ReportsDismiss,
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await widget.service.dismiss(widget.report.row);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.c6ReportsDismissed)));
      Navigator.of(context).pop(true);
    } catch (err) {
      if (mounted) setState(() => _error = describeError(err, l10n));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final report = widget.report;
    final row = report.row;
    final lockedText = switch (report.failure) {
      ReportOpenFailure.noSeed => l10n.c6ReportsLockedNoSeed,
      ReportOpenFailure.otherKey => l10n.c6ReportsLockedOtherKey,
      ReportOpenFailure.cannotOpen ||
      ReportOpenFailure.invalidBody =>
        l10n.c6ReportsLockedDamaged,
      null => null,
    };
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.c6ReportsTitle),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(BoneSpacing.gutter),
          children: <Widget>[
            Text(l10n.c6ReportsFiled(formatDateTime(context, row.createdAt)),
                style: theme.textTheme.labelLarge),
            const SizedBox(height: BoneSpacing.sm),
            Text(l10n.c6ReportsReporter(shortId(row.reporterAccountId))),
            const SizedBox(height: BoneSpacing.lg),
            if (lockedText != null)
              Text(lockedText)
            else ...<Widget>[
              Text(l10n.c6ReportsMessageLabel,
                  style: theme.textTheme.labelLarge),
              const SizedBox(height: BoneSpacing.sm),
              Container(
                padding: const EdgeInsets.all(BoneSpacing.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(BoneRadii.md),
                ),
                child: SelectableText(report.text ?? l10n.c6ReportsNoText),
              ),
              const SizedBox(height: BoneSpacing.lg),
              if (_verification case final verification?)
                ..._verdict(context, verification)
              else ...<Widget>[
                Text(l10n.c6ReportsCheckNote, style: theme.textTheme.bodySmall),
                const SizedBox(height: BoneSpacing.sm),
                FilledButton(
                  onPressed: _checking ? null : _check,
                  child: Text(
                      _checking ? l10n.c6ReportsChecking : l10n.c6ReportsCheck),
                ),
              ],
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: BoneSpacing.md),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: BoneSpacing.xl),
            OutlinedButton(
              onPressed: _dismiss,
              child: Text(l10n.c6ReportsDismiss),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _verdict(BuildContext context, ReportVerification result) {
    final l10n = context.l10n;
    final (label, detail, tone) = switch (result.verdict) {
      ReportVerdict.verified => (
          l10n.c6VerdictVerified,
          l10n.c6VerdictVerifiedDetail,
          StatusTone.verified
        ),
      ReportVerdict.mismatch => (
          l10n.c6VerdictMismatch,
          l10n.c6VerdictMismatchDetail,
          StatusTone.error
        ),
      ReportVerdict.recordGone => (
          l10n.c6VerdictGone,
          l10n.c6VerdictGoneDetail,
          StatusTone.warning
        ),
      ReportVerdict.unfranked => (
          l10n.c6VerdictUnfranked,
          l10n.c6VerdictUnfrankedDetail,
          StatusTone.warning
        ),
    };
    final record = result.record;
    return <Widget>[
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: StatusPill(label: label, tone: tone, uppercase: false),
      ),
      const SizedBox(height: BoneSpacing.sm),
      Text(detail),
      if (record != null) ...<Widget>[
        const SizedBox(height: BoneSpacing.sm),
        Text(l10n.c6ReportsSender(shortId(record.senderAccountId))),
      ],
    ];
  }
}
