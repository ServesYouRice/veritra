import 'package:flutter/material.dart';

import '../../core/admin_models.dart';
import '../../core/api_client.dart';
import '../../core/app_state.dart';
import '../../core/errors.dart';
import '../../l10n/l10n.dart';
import '../../ui/confirm.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/empty_state.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';

/// Instance administration for owners and admins: accounts (suspend or
/// reactivate) and the minimal audit log (D04). It shows counts and sizes
/// only; the server has no message plaintext to show.
class AdminScreen extends StatefulWidget {
  const AdminScreen({
    required this.state,
    required this.reauthenticate,
    super.key,
  });

  final AppState state;

  /// Asks for the password again and resolves true on success. Suspending is
  /// credential-sensitive: the server answers `recent_auth_required` when the
  /// last proof is too old.
  final Future<bool> Function(BuildContext context) reauthenticate;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final List<AdminAccount> _accounts = <AdminAccount>[];
  final List<AdminAuditEvent> _events = <AdminAuditEvent>[];
  String? _accountsNext;
  String? _eventsNext;
  bool _accountsLoaded = false;
  bool _eventsLoaded = false;
  bool _loading = false;
  // Each tab has its own error: one tab's failure says nothing about the
  // other, and a failed load must not read as an empty list.
  String? _accountsError;
  String? _eventsError;
  // A reload supersedes a load still in flight: the older answer is dropped
  // rather than appended to the fresh list.
  int _accountsGeneration = 0;
  int _eventsGeneration = 0;
  bool _eventsLoading = false;

  @override
  void initState() {
    super.initState();
    _loadAccounts(reset: true);
    _loadEvents(reset: true);
  }

  String? get _token => widget.state.session?.token;

  Future<void> _loadAccounts({bool reset = false}) async {
    final client = widget.state.api;
    final token = _token;
    if (client == null || token == null) return;
    if (_loading && !reset) return;
    final generation = reset ? ++_accountsGeneration : _accountsGeneration;
    setState(() {
      _loading = true;
      _accountsError = null;
    });
    try {
      final page = await client.listAdminAccounts(
        token,
        after: reset ? null : _accountsNext,
      );
      if (!mounted || generation != _accountsGeneration) return;
      setState(() {
        if (reset) _accounts.clear();
        _accounts.addAll(page.rows);
        _accountsNext = page.nextAfter;
        _accountsLoaded = true;
      });
    } catch (err) {
      if (generation == _accountsGeneration) {
        _fail(err, accounts: true);
      }
    } finally {
      if (mounted && generation == _accountsGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadEvents({bool reset = false}) async {
    final client = widget.state.api;
    final token = _token;
    if (client == null || token == null) return;
    if (_eventsLoading && !reset) return;
    final generation = reset ? ++_eventsGeneration : _eventsGeneration;
    _eventsLoading = true;
    if (_eventsError != null) setState(() => _eventsError = null);
    try {
      final page = await client.listAdminAuditEvents(
        token,
        before: reset ? null : _eventsNext,
      );
      if (!mounted || generation != _eventsGeneration) return;
      setState(() {
        if (reset) _events.clear();
        _events.addAll(page.rows);
        _eventsNext = page.nextAfter;
        _eventsLoaded = true;
      });
    } catch (err) {
      if (generation == _eventsGeneration) _fail(err, accounts: false);
    } finally {
      if (generation == _eventsGeneration) _eventsLoading = false;
    }
  }

  /// Records that the load of one tab failed. The tab's loaded flag is not
  /// set: only a page that arrived makes an empty list mean "nothing here".
  void _fail(Object err, {required bool accounts}) {
    if (!mounted) return;
    final message = describeError(err, context.l10n);
    setState(() {
      if (accounts) {
        _accountsError = message;
      } else {
        _eventsError = message;
      }
    });
  }

  Future<void> _toggle(AdminAccount account) async {
    final l10n = context.l10n;
    final suspend = !account.suspended;
    final confirmed = await confirmAction(
      context,
      title: suspend ? l10n.adminSuspendTitle : l10n.adminUnsuspendTitle,
      message: suspend
          ? l10n.adminSuspendMessage(account.username)
          : l10n.adminUnsuspendMessage(account.username),
      confirmLabel: suspend ? l10n.adminSuspend : l10n.adminUnsuspend,
      destructive: suspend,
    );
    if (!confirmed || !mounted) return;
    var reauthed = false;
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = widget.state.api;
      final token = _token;
      if (client == null || token == null) return;
      try {
        await client.setAdminAccountStatus(
          token,
          account.id,
          suspended: suspend,
        );
        if (!mounted) return;
        await _loadAccounts(reset: true);
        await _loadEvents(reset: true);
        return;
      } on ApiException catch (err) {
        if (err.serverCode == 'recent_auth_required' && !reauthed) {
          reauthed = true;
          if (!mounted || !await widget.reauthenticate(context)) return;
          continue;
        }
        _showError(err);
        return;
      } catch (err) {
        _showError(err);
        return;
      }
    }
  }

  void _showError(Object err) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(describeError(err, context.l10n))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: LargeTitleBar(title: l10n.settingsAdmin),
        body: Column(
          children: <Widget>[
            TabBar(
              tabs: <Widget>[
                Tab(text: l10n.adminAccountsTab),
                Tab(text: l10n.adminAuditTab),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: <Widget>[_accountsTab(context), _auditTab(context)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner(BuildContext context, String message) => Padding(
        padding: const EdgeInsets.all(BoneSpacing.lg),
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );

  Widget _accountsTab(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () => _loadAccounts(reset: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(BoneSpacing.gutter),
        children: <Widget>[
          if (_accountsError != null) _errorBanner(context, _accountsError!),
          if (_accounts.isEmpty && _accountsLoaded && _accountsError == null)
            EmptyState(
              icon: Icons.people_outline,
              title: l10n.adminNoAccounts,
              message: '',
            )
          else if (_accounts.isEmpty && _accountsError == null)
            const Center(child: CircularProgressIndicator())
          else
            TileGroup(
              children: <Widget>[
                for (final account in _accounts)
                  ListTile(
                    title: Row(
                      children: <Widget>[
                        Flexible(child: Text('@${account.username}')),
                        if (account.suspended) ...<Widget>[
                          const SizedBox(width: BoneSpacing.sm),
                          StatusPill(
                            label: l10n.adminSuspendedPill,
                            tone: StatusTone.warning,
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      l10n.adminAccountSummary(
                        account.role,
                        account.deviceCount,
                        formatFileSize(context, account.storageBytes),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    // Only accounts of a lower rank than the signed-in one;
                    // the server enforces the same rule.
                    trailing: account.id == widget.state.session?.accountId ||
                            roleRank(widget.state.session?.role) <=
                                roleRank(account.role)
                        ? null
                        : TextButton(
                            onPressed: () => _toggle(account),
                            child: Text(
                              account.suspended
                                  ? l10n.adminUnsuspend
                                  : l10n.adminSuspend,
                            ),
                          ),
                  ),
              ],
            ),
          if (_accountsNext != null)
            TextButton(
              onPressed: _loading ? null : () => _loadAccounts(),
              child: Text(l10n.adminLoadMore),
            ),
        ],
      ),
    );
  }

  Widget _auditTab(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () => _loadEvents(reset: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(BoneSpacing.gutter),
        children: <Widget>[
          if (_eventsError != null) _errorBanner(context, _eventsError!),
          if (_events.isEmpty && _eventsLoaded && _eventsError == null)
            EmptyState(
              icon: Icons.history,
              title: l10n.adminNoEvents,
              message: '',
            )
          else if (_events.isEmpty && _eventsError == null)
            const Center(child: CircularProgressIndicator())
          else
            TileGroup(
              children: <Widget>[
                for (final event in _events)
                  ListTile(
                    title: Text(
                      event.eventType,
                      style: BoneType.mono.copyWith(fontSize: 14),
                    ),
                    subtitle: Text(
                      <String>[
                        if (event.createdAt != null)
                          formatDateTime(context, event.createdAt!.toLocal()),
                        if (event.actorAccountId != null)
                          l10n.adminEventBy(event.actorAccountId!),
                        for (final entry in event.metadata.entries)
                          '${entry.key}: ${entry.value}',
                      ].join('\n'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    isThreeLine: true,
                  ),
              ],
            ),
          if (_eventsNext != null)
            TextButton(
              onPressed: () => _loadEvents(),
              child: Text(l10n.adminLoadMore),
            ),
        ],
      ),
    );
  }
}
