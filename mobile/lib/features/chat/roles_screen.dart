import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/roles/governance.dart';
import '../../crypto/crypto_service.dart' show GovernanceView;
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/status_pill.dart';
import '../../ui/widgets/tile_group.dart';
import 'conversation_details_screen.dart' show roleLabel;

/// C4: the group's verified roles (its signed role record), the actions the
/// local account's role allows, and the owner election (D81). Every action
/// is a commit every member's app checks; the server's roles are not used.
class RolesScreen extends StatefulWidget {
  const RolesScreen({
    required this.state,
    required this.conversationId,
    super.key,
  });

  final AppState state;
  final String conversationId;

  @override
  State<RolesScreen> createState() => _RolesScreenState();
}

class _RolesScreenState extends State<RolesScreen> {
  GovernanceView? _view;
  bool _loaded = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    state.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final view = await state.governanceViewFor(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _view = view;
      _loaded = true;
    });
  }

  String _name(String accountId) {
    final group = state.recordGroupFor(widget.conversationId);
    final member = state
        .membersFor(group ?? widget.conversationId)
        .where((m) => m.accountId == accountId)
        .firstOrNull;
    final account = accountLabel(accountId, member?.username);
    final profile = state.profileNameOf(accountId);
    return profile == null ? account : '$profile ($account)';
  }

  Future<void> _run(Future<bool> Function() action) async {
    await action();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final view = _view;
    final self = state.session?.accountId;
    final busy = state.isBusy(Ops.members);
    final error = state.errorFor(Ops.members);
    final children = <Widget>[];
    if (!_loaded) {
      children.add(const Center(child: CircularProgressIndicator()));
    } else if (view == null) {
      children.add(Text(l10n.rolesNoRecord));
    } else {
      final record = view.record;
      children.add(Text(
        l10n.rolesDetail,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ));
      if (error != null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: BoneSpacing.sm),
          child: Text(error, style: TextStyle(color: theme.colorScheme.error)),
        ));
      }
      final accounts = view.roster.toList()
        ..sort((a, b) {
          final byRank = record.rankOf(b).compareTo(record.rankOf(a));
          if (byRank != 0) return byRank;
          final ja = record.joined[a] ?? 1 << 62;
          final jb = record.joined[b] ?? 1 << 62;
          return ja == jb ? a.compareTo(b) : ja.compareTo(jb);
        });
      children.add(SectionHeader(l10n.rolesTitle));
      children.add(TileGroup(children: <Widget>[
        for (final account in accounts)
          _RoleTile(
            label: account == self
                ? l10n.rolesYou(_name(account))
                : _name(account),
            role: record.roleOf(account),
            elector: record.electors.contains(account),
            actions: busy || self == null
                ? const <_RoleAction>[]
                : _actionsFor(context, record, view.roster, self, account),
          ),
      ]));
      children.add(SectionHeader(l10n.rolesOwnership));
      children.add(_ownership(context, record, view, self, busy));
    }
    return Scaffold(
      appBar: LargeTitleBar(title: l10n.rolesTitle),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(BoneSpacing.gutter, BoneSpacing.sm,
            BoneSpacing.gutter, BoneSpacing.xl),
        children: children,
      ),
    );
  }

  /// What [self] may do to [account] under the record: the receivers' own
  /// rules (`validateTransition`), so a refused commit is never offered.
  List<_RoleAction> _actionsFor(BuildContext context, GovernanceState record,
      Set<String> roster, String self, String account) {
    final l10n = context.l10n;
    final id = widget.conversationId;
    final actions = <_RoleAction>[];
    if (account == self) {
      if (record.roleOf(self) != BuiltInRole.owner &&
          record.roleOf(self) != BuiltInRole.member) {
        actions.add(_RoleAction(
            l10n.rolesStepDown,
            () => _run(
                () => state.setVerifiedRole(id, self, BuiltInRole.member))));
      }
      return actions;
    }
    final actor = record.rankOf(self);
    final target = record.rankOf(account);
    if (actor >= BuiltInRole.moderator.rank && target < actor) {
      for (final role in const <BuiltInRole>[
        BuiltInRole.admin,
        BuiltInRole.moderator,
        BuiltInRole.member,
      ]) {
        if (role.rank > actor || role == record.roleOf(account)) continue;
        final label = switch (role) {
          BuiltInRole.admin => l10n.rolesMakeAdmin,
          BuiltInRole.moderator => l10n.rolesMakeModerator,
          _ => l10n.rolesMakeMember,
        };
        actions.add(_RoleAction(
            label, () => _run(() => state.setVerifiedRole(id, account, role))));
      }
    }
    if (record.owner == self && record.admins.containsKey(account)) {
      final elector = record.electors.contains(account);
      actions.add(_RoleAction(
          elector ? l10n.rolesElectorOff : l10n.rolesElectorOn,
          () => _run(() => state.setElector(id, account, !elector))));
      actions.add(_RoleAction(l10n.rolesTransfer, () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            content: Text(l10n.rolesTransferConfirm(_name(account))),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child:
                    Text(MaterialLocalizations.of(context).cancelButtonLabel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.rolesTransfer),
              ),
            ],
          ),
        );
        if (ok == true) await _run(() => state.transferOwnership(id, account));
      }));
    }
    return actions;
  }

  Widget _ownership(BuildContext context, GovernanceState record,
      GovernanceView view, String? self, bool busy) {
    final l10n = context.l10n;
    final id = widget.conversationId;
    final election = record.election;
    final tiles = <Widget>[];
    if (election == null) {
      tiles.add(ListTile(title: Text(l10n.rolesElectionNone)));
      // Offered where the local rules would build it; the command checks
      // the 30 days against this device's own clock and refuses otherwise.
      final observed = view.observations;
      final admins = record.admins.keys.where(view.roster.contains).toList();
      final mayOpen = self != null &&
          self != record.owner &&
          observed != null &&
          mayOpenElectionNow(
              now: DateTime.now().toUtc(),
              lastOwnerActivity: observed.lastOwnerActivity) &&
          (admins.isEmpty || record.admins.containsKey(self));
      if (mayOpen) {
        tiles.add(ListTile(
          leading: const Icon(Icons.how_to_vote_outlined),
          title: Text(l10n.rolesStartElection),
          onTap: busy ? null : () => _run(() => state.openOwnerElection(id)),
        ));
      }
    } else {
      tiles.add(ListTile(
        title: Text(l10n.rolesElectionOpen(
            '${election.votes.length}', '${election.electorate.length}')),
      ));
      if (self != null && self == record.owner) {
        tiles.add(ListTile(subtitle: Text(l10n.rolesOwnerCancelNote)));
      }
      final voter = self != null &&
          election.electorate.contains(self) &&
          !election.votes.containsKey(self);
      if (voter) {
        final admins = record.admins.keys.where(view.roster.contains).toList()
          ..sort();
        final candidates = admins.isEmpty ? <String>[self] : admins;
        for (final candidate in candidates) {
          tiles.add(ListTile(
            leading: const Icon(Icons.how_to_vote_outlined),
            title: Text(l10n.rolesVoteFor(_name(candidate))),
            onTap: busy
                ? null
                : () => _run(() => state.voteForOwner(id, candidate)),
          ));
        }
      }
      if (self != null &&
          (self == record.owner || election.electorate.contains(self))) {
        tiles.add(ListTile(
          leading: const Icon(Icons.close),
          title: Text(l10n.rolesCloseElection),
          onTap: busy ? null : () => _run(() => state.closeOwnerElection(id)),
        ));
      }
    }
    return TileGroup(children: tiles);
  }
}

class _RoleAction {
  const _RoleAction(this.label, this.run);
  final String label;
  final Future<void> Function() run;
}

class _RoleTile extends StatelessWidget {
  const _RoleTile({
    required this.label,
    required this.role,
    required this.elector,
    required this.actions,
  });

  final String label;
  final BuiltInRole role;
  final bool elector;
  final List<_RoleAction> actions;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      title: Row(children: <Widget>[
        Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: BoneSpacing.sm),
        StatusPill(label: roleLabel(l10n, role.name)),
      ]),
      subtitle: elector ? Text(l10n.rolesElector) : null,
      trailing: actions.isEmpty
          ? null
          : PopupMenuButton<int>(
              onSelected: (index) => actions[index].run(),
              itemBuilder: (context) => <PopupMenuEntry<int>>[
                for (var i = 0; i < actions.length; i++)
                  PopupMenuItem<int>(value: i, child: Text(actions[i].label)),
              ],
            ),
    );
  }
}
