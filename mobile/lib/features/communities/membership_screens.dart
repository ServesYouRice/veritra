import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/avatar.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../settings/stacked_trailing_tile.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/tile_group.dart';
import '../chat/conversation_details_screen.dart' show roleLabel;
import 'moderation_screen.dart';

/// C1: joining through an invitation link, and managing invitations, join
/// requests and members of a group or community.
///
/// What these screens show is the server's membership record. Approving a
/// request or removing a member changes that record at once; the matching
/// encrypted group update follows separately, and the copy says so instead of
/// implying cryptographic access has changed.

String _kindLabel(AppLocalizations l10n, InviteTargetKind kind) =>
    kind == InviteTargetKind.community
        ? l10n.joinKindCommunity
        : l10n.joinKindGroup;

IconData _kindIcon(InviteTargetKind kind) => kind == InviteTargetKind.community
    ? Icons.groups_outlined
    : Icons.group_outlined;

class _InlineError extends StatelessWidget {
  const _InlineError(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: BoneSpacing.sm),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}

/// The message a failed membership call left under [Ops.membership].
///
/// Every membership call clears that shared slot when it starts, and the
/// panels on a page reload after each other's actions. A page that read the
/// slot while drawing therefore lost its message within a frame (UI audit
/// U4). Each widget copies the message into its own state right after its own
/// action fails, and clears the copy only when its next action starts.
String? _failureOf(AppState state) => state.errorFor(Ops.membership);

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(dialogContext.l10n.commonCancel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  foregroundColor: Theme.of(dialogContext).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Paste an invitation link, see what it leads to, and ask to join. Lists the
/// account's own requests, so a waiting, approved or declined one is visible.
class JoinByLinkScreen extends StatefulWidget {
  const JoinByLinkScreen({required this.state, super.key});

  final AppState state;

  @override
  State<JoinByLinkScreen> createState() => _JoinByLinkScreenState();
}

class _JoinByLinkScreenState extends State<JoinByLinkScreen> {
  final TextEditingController _controller = TextEditingController();
  ({MembershipInviteLink link, InvitePreview preview})? _preview;
  bool _requested = false;
  List<JoinRequest> _requests = const <JoinRequest>[];

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRequests());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadRequests() async {
    final requests = await state.loadOwnJoinRequests();
    if (!mounted || requests == null) return;
    setState(() => _requests = requests);
  }

  Future<void> _check() async {
    _checked = _controller.text.trim();
    setState(() {
      _preview = null;
      _requested = false;
    });
    final result = await state.previewInviteLink(_controller.text);
    if (!mounted) return;
    setState(() => _preview = result);
  }

  /// The text the last check ran on, so one link is never checked twice.
  String? _checked;
  int _length = 0;

  /// A pasted link checks itself: once the field holds a well-formed link of
  /// this server, or a paste of text that is not one (which then says so under
  /// the field). Typing by hand still waits for the button.
  void _onChanged(String value) {
    final pasted = value.length - _length > 8;
    _length = value.length;
    setState(() {
      _preview = null;
      _requested = false;
    });
    final text = value.trim();
    // Not gated on busy: membership calls queue, and a paste right after
    // the screen opens (its own request list is loading) must not be lost.
    if (text.isEmpty || text == _checked) return;
    final origin = state.api?.baseUrl;
    final wellFormed = origin != null &&
        MembershipInviteLink.tryParse(text, expectedOrigin: origin) != null;
    if (wellFormed || pasted) unawaited(_check());
  }

  Future<void> _request() async {
    final link = _preview?.link;
    if (link == null) return;
    final request = await state.requestToJoin(link);
    if (!mounted || request == null) return;
    // The secret is not needed any more: drop it from the field.
    _controller.clear();
    _checked = null;
    _length = 0;
    setState(() => _requested = true);
    await _loadRequests();
  }

  Future<void> _cancel(JoinRequest request) async {
    if (await state.cancelJoinRequest(request.id)) {
      await _loadRequests();
    }
  }

  String _statusText(AppLocalizations l10n, JoinRequestStatus status) {
    switch (status) {
      case JoinRequestStatus.pending:
        return l10n.joinStatusPending;
      case JoinRequestStatus.approved:
        return l10n.joinStatusApproved;
      case JoinRequestStatus.rejected:
        return l10n.joinStatusRejected;
      case JoinRequestStatus.cancelled:
        return l10n.joinStatusCancelled;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final busy = state.isBusy(Ops.membership);
        final error = state.errorFor(Ops.membership);
        final preview = _preview?.preview;
        return Scaffold(
          appBar: LargeTitleBar(title: l10n.joinTitle),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xl,
            ),
            children: <Widget>[
              TextField(
                controller: _controller,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l10n.joinLinkLabel,
                  hintText: l10n.joinLinkHint,
                ),
                onChanged: _onChanged,
                onSubmitted: (_) {
                  if (!busy && _controller.text.trim().isNotEmpty) _check();
                },
              ),
              const SizedBox(height: BoneSpacing.md),
              FilledButton(
                onPressed:
                    busy || _controller.text.trim().isEmpty ? null : _check,
                child: Text(l10n.joinCheck),
              ),
              if (error != null) _InlineError(error),
              if (preview != null) ...<Widget>[
                const SizedBox(height: BoneSpacing.lg),
                TileGroup(
                  children: <Widget>[
                    ListTile(
                      leading: Icon(_kindIcon(preview.kind)),
                      title: Text(
                        preview.targetName.isEmpty
                            ? _kindLabel(l10n, preview.kind)
                            : preview.targetName,
                      ),
                      subtitle: Text(
                        l10n.joinInvitedBy(preview.inviterUsername),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: BoneSpacing.md),
                if (preview.alreadyMember)
                  Text(l10n.joinAlreadyMember)
                else if (_requested)
                  Text(l10n.joinRequestSent)
                else ...<Widget>[
                  Text(l10n.joinRequestNote, style: muted),
                  const SizedBox(height: BoneSpacing.md),
                  FilledButton(
                    onPressed: busy ? null : _request,
                    child: Text(l10n.joinRequestButton),
                  ),
                ],
              ],
              SectionHeader(l10n.joinYourRequests),
              if (_requests.isEmpty)
                Text(l10n.joinNoRequests, style: muted)
              else
                TileGroup(
                  children: <Widget>[
                    for (final request in _requests)
                      ListTile(
                        leading: Icon(_kindIcon(request.kind)),
                        title: Text(
                          request.targetName ?? _kindLabel(l10n, request.kind),
                        ),
                        subtitle: Text(_statusText(l10n, request.status)),
                        trailing: request.status == JoinRequestStatus.pending
                            ? TextButton(
                                onPressed: busy ? null : () => _cancel(request),
                                child: Text(l10n.joinCancelRequest),
                              )
                            : null,
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Invitation links of a group or community, for its owners and admins:
/// create one, copy it once, revoke it. The link is shown only here, right
/// after it is made: the server keeps no copy and cannot show it again.
class MembershipInvitesPanel extends StatefulWidget {
  const MembershipInvitesPanel({
    required this.state,
    required this.kind,
    required this.targetId,
    super.key,
  });

  final AppState state;
  final InviteTargetKind kind;
  final String targetId;

  @override
  State<MembershipInvitesPanel> createState() => _MembershipInvitesPanelState();
}

class _MembershipInvitesPanelState extends State<MembershipInvitesPanel> {
  List<MembershipInvite> _invites = const <MembershipInvite>[];
  String? _link;

  /// This panel's own copy of the last failure (see [_failureOf]).
  String? _error;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final invites =
        await state.loadMembershipInvites(widget.kind, widget.targetId);
    if (!mounted) return;
    if (invites == null) {
      setState(() => _error = _failureOf(state));
      return;
    }
    setState(() => _invites = invites);
  }

  Future<void> _create() async {
    setState(() => _error = null);
    final url = await state.createInviteLink(widget.kind, widget.targetId);
    if (!mounted) return;
    if (url == null) {
      setState(() => _error = _failureOf(state));
      return;
    }
    setState(() => _link = url);
    await _load();
  }

  Future<void> _revoke(MembershipInvite invite) async {
    final l10n = context.l10n;
    // U16: turning a link off asks first.
    final confirmed = await _confirm(
      context,
      title: l10n.membInviteTurnOffTitle,
      message: l10n.membInviteTurnOffMessage,
      confirmLabel: l10n.membInviteTurnOff,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _error = null);
    final done = await state.revokeMembershipInvite(invite.id);
    if (!mounted) return;
    if (!done) {
      setState(() => _error = _failureOf(state));
      return;
    }
    await _load();
  }

  void _copy(String link) {
    Clipboard.setData(ClipboardData(text: link));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.membInviteCopied)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final busy = state.isBusy(Ops.membership);
        final error = _error;
        final link = _link;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(l10n.membInviteSection),
            TileGroup(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.link),
                  title: Text(l10n.membInviteCreate),
                  subtitle: Text(l10n.membInviteCreateDetail),
                  onTap: busy ? null : _create,
                ),
                if (link != null)
                  ListTile(
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: SelectableText(link),
                    subtitle: Text(l10n.membInviteCreatedNote),
                    trailing: IconButton(
                      tooltip: l10n.membInviteCopy,
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () => _copy(link),
                    ),
                  ),
                if (_invites.isEmpty)
                  ListTile(
                    leading: const Icon(Icons.link_off),
                    title: Text(l10n.membInviteNone),
                  )
                else
                  for (final invite in _invites)
                    // U16: a labelled "Turn off", not a bare icon. It drops under
                    // the text at large sizes (U2).
                    StackedTrailingTile(
                      leading: const Icon(Icons.schedule_outlined),
                      title: Text(
                        l10n.membInviteUses(
                          invite.uses,
                          invite.maxUses,
                          formatDate(context, invite.expiresAt),
                        ),
                      ),
                      trailingWidth:
                          measureTextWidth(context, l10n.membInviteTurnOff) +
                              32,
                      trailing: TextButton(
                        key: ValueKey<String>('invite-turn-off-${invite.id}'),
                        style: TextButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: busy ? null : () => _revoke(invite),
                        child: Text(l10n.membInviteTurnOff),
                      ),
                    ),
              ],
            ),
            if (error != null) _InlineError(error),
          ],
        );
      },
    );
  }
}

/// Pending join requests of a group or community, for its owners and admins,
/// with approve and decline.
class JoinRequestsPanel extends StatefulWidget {
  const JoinRequestsPanel({
    required this.state,
    required this.kind,
    required this.targetId,
    this.onApproved,
    super.key,
  });

  final AppState state;
  final InviteTargetKind kind;
  final String targetId;

  /// Called after an approval, so the screen can read its member list again.
  final VoidCallback? onApproved;

  @override
  State<JoinRequestsPanel> createState() => _JoinRequestsPanelState();
}

class _JoinRequestsPanelState extends State<JoinRequestsPanel> {
  List<JoinRequest> _requests = const <JoinRequest>[];

  /// This panel's own copy of the last failure (see [_failureOf]).
  String? _error;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final requests = await state.loadJoinRequests(widget.kind, widget.targetId);
    if (!mounted) return;
    if (requests == null) {
      setState(() => _error = _failureOf(state));
      return;
    }
    setState(() => _requests = requests);
  }

  Future<void> _decide(JoinRequest request, {required bool approve}) async {
    setState(() => _error = null);
    final done = await state.decideJoinRequest(request, approve: approve);
    if (!mounted) return;
    if (!done) {
      // Keep the message: the reload below clears the shared slot.
      setState(() => _error = _failureOf(state));
    } else {
      final l10n = context.l10n;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          approve ? l10n.joinStatusApproved : l10n.joinReqRejectedSnack,
        ),
      ));
      if (approve) widget.onApproved?.call();
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final busy = state.isBusy(Ops.membership);
        final error = _error;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SectionHeader(l10n.joinReqSection),
            TileGroup(
              children: <Widget>[
                if (_requests.isEmpty)
                  ListTile(
                    leading: const Icon(Icons.hourglass_empty),
                    title: Text(l10n.joinReqNone),
                  )
                else
                  for (final request in _requests)
                    ListTile(
                      leading: const Icon(Icons.person_add_alt_outlined),
                      title: Text(
                        accountLabel(request.accountId ?? '', request.username),
                      ),
                      // U16: two labelled buttons under the name, not two bare
                      // icons beside it.
                      isThreeLine: true,
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.joinReqAskedAt(
                              formatDateTime(context, request.createdAt),
                            ),
                          ),
                          Wrap(
                            spacing: BoneSpacing.sm,
                            children: <Widget>[
                              TextButton(
                                key: ValueKey<String>(
                                    'join-decline-${request.id}'),
                                onPressed: busy
                                    ? null
                                    : () => _decide(request, approve: false),
                                child: Text(l10n.joinReqDeclineButton),
                              ),
                              FilledButton.tonal(
                                key: ValueKey<String>(
                                    'join-approve-${request.id}'),
                                onPressed: busy
                                    ? null
                                    : () => _decide(request, approve: true),
                                child: Text(l10n.joinReqApproveButton),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
              ],
            ),
            if (error != null) _InlineError(error),
          ],
        );
      },
    );
  }
}

/// Invitation links and join requests of one group, on a page of their own so
/// the conversation details screen makes no request for them.
class MembershipManageScreen extends StatelessWidget {
  const MembershipManageScreen({
    required this.state,
    required this.kind,
    required this.targetId,
    super.key,
  });

  final AppState state;
  final InviteTargetKind kind;
  final String targetId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LargeTitleBar(title: context.l10n.membInviteManage),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          BoneSpacing.gutter,
          BoneSpacing.sm,
          BoneSpacing.gutter,
          BoneSpacing.xl,
        ),
        children: <Widget>[
          MembershipInvitesPanel(state: state, kind: kind, targetId: targetId),
          JoinRequestsPanel(
            state: state,
            kind: kind,
            targetId: targetId,
            onApproved: () => state.loadConversationMembers(targetId),
          ),
        ],
      ),
    );
  }
}

/// A community's members, its invitation links and join requests (for owners
/// and admins), and leaving it.
class CommunityDetailsScreen extends StatefulWidget {
  const CommunityDetailsScreen({
    required this.state,
    required this.community,
    super.key,
  });

  final AppState state;
  final Community community;

  @override
  State<CommunityDetailsScreen> createState() => _CommunityDetailsScreenState();
}

class _CommunityDetailsScreenState extends State<CommunityDetailsScreen> {
  List<ConversationMember>? _members;
  bool _failed = false;

  /// This page's own copy of the last failure (see [_failureOf]).
  String? _error;

  AppState get state => widget.state;
  String get _communityId => widget.community.id;

  static const Map<String, int> _rank = <String, int>{
    'owner': 4,
    'admin': 3,
    'moderator': 2,
    'member': 1,
  };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final members = await state.loadCommunityMembers(_communityId);
    if (!mounted) return;
    setState(() {
      _members = members;
      _failed = members == null;
    });
  }

  /// This account's role in the community, from the last roster that loaded.
  /// Kept across a failed reload so the Invites and Requests tabs (and the
  /// panels in them) are not torn down and rebuilt.
  String? _lastRole;

  String? get _myRole {
    final me = state.session?.accountId;
    for (final member in _members ?? const <ConversationMember>[]) {
      if (member.accountId == me) return _lastRole = member.role;
    }
    return _members == null ? _lastRole : null;
  }

  Future<void> _remove(ConversationMember member) async {
    final label = accountLabel(member.accountId, member.username);
    final l10n = context.l10n;
    final confirmed = await _confirm(
      context,
      title: l10n.communityRemoveTitle(label),
      message: l10n.communityRemoveMessage,
      confirmLabel: l10n.communityRemoveConfirm,
      destructive: true, // U15
    );
    if (!confirmed || !mounted) return;
    setState(() => _error = null);
    if (await state.removeCommunityMember(_communityId, member.accountId)) {
      await _load();
    } else if (mounted) {
      setState(() => _error = _failureOf(state));
    }
  }

  Future<void> _ban(ConversationMember member) async {
    final label = accountLabel(member.accountId, member.username);
    final l10n = context.l10n;
    final confirmed = await _confirm(
      context,
      title: l10n.banTitle(label),
      message: l10n.banMessage,
      confirmLabel: l10n.banConfirm,
      destructive: true, // U15
    );
    if (!confirmed || !mounted) return;
    setState(() => _error = null);
    if (await state.banCommunityMember(_communityId, member.accountId)) {
      await _load();
    } else if (mounted) {
      setState(() => _error = _failureOf(state));
    }
  }

  Future<void> _timeout(ConversationMember member, {required bool lift}) async {
    final label = accountLabel(member.accountId, member.username);
    final l10n = context.l10n;
    final seconds = lift
        ? 0
        : await pickDuration(
            context,
            title: l10n.timeoutTitle(label),
            choices: timeoutChoices,
            label: (s) => durationWords(l10n, s),
          );
    if (seconds == null || !mounted) return;
    setState(() => _error = null);
    final done = await state.timeoutCommunityMember(
        _communityId, member.accountId, seconds);
    if (!mounted) return;
    if (!done) {
      setState(() => _error = _failureOf(state));
    } else if (!lift) {
      // A timeout is reversible, so it can say so: Undo lifts it. (A removal
      // or ban is not offered Undo: nothing here can give the person back
      // the access it ended.)
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(l10n.timeoutDone),
          persist: false,
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: l10n.commonUndo,
            onPressed: () => unawaited(_timeout(member, lift: true)),
          ),
        ));
    }
  }

  Future<void> _leave() async {
    final l10n = context.l10n;
    final confirmed = await _confirm(
      context,
      title: l10n.communityLeaveTitle,
      message: l10n.communityLeaveDetail,
      confirmLabel: l10n.communityLeaveConfirm,
    );
    if (!confirmed || !mounted) return;
    setState(() => _error = null);
    final done = await state.leaveCommunity(_communityId);
    if (!mounted) return;
    if (done) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      setState(() => _error = _failureOf(state));
    }
  }

  static const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(
    BoneSpacing.gutter,
    BoneSpacing.sm,
    BoneSpacing.gutter,
    BoneSpacing.xl,
  );

  /// The shared record's timeout for [accountId], while it is running.
  DateTime? _timedOutUntil(String accountId) {
    final shared = widget.community.sharedConversationId;
    if (shared == null) return null;
    final until = state.governanceOf(shared)?.timeouts[accountId]?.untilMs;
    if (until == null) return null;
    final end = DateTime.fromMillisecondsSinceEpoch(until);
    return end.isAfter(DateTime.now()) ? end : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final myRole = _myRole;
        final canInvite =
            myRole != null && const <String>{'owner', 'admin'}.contains(myRole);
        final title = state.communityDisplayName(widget.community) ??
            l10n.communityPlaceholderName;
        // Members, Invites and Requests are tabs for owners and admins; a
        // plain member or a moderator sees the member page alone.
        if (!canInvite) {
          return Scaffold(
            appBar: LargeTitleBar(title: title),
            body: _membersTab(context),
          );
        }
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: LargeTitleBar(title: title),
            body: Column(
              children: <Widget>[
                TabBar(
                  tabs: <Widget>[
                    Tab(text: l10n.detailsSectionMembers),
                    Tab(text: l10n.communityTabInvites),
                    Tab(text: l10n.communityTabRequests),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      _membersTab(context),
                      // Kept alive: leaving a tab must not rebuild its panel,
                      // which would reload it and lose its message (U4).
                      _KeepAlive(
                        child: ListView(
                          padding: _pagePadding,
                          children: <Widget>[
                            MembershipInvitesPanel(
                              state: state,
                              kind: InviteTargetKind.community,
                              targetId: _communityId,
                            ),
                          ],
                        ),
                      ),
                      _KeepAlive(
                        child: ListView(
                          padding: _pagePadding,
                          children: <Widget>[
                            JoinRequestsPanel(
                              state: state,
                              kind: InviteTargetKind.community,
                              targetId: _communityId,
                              onApproved: _load,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The members, the moderation entry and leaving.
  Widget _membersTab(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final busy = state.isBusy(Ops.membership);
    final error = _error;
    final members = _members;
    final myRole = _myRole;
    final me = state.session?.accountId;
    final canManageMembers = myRole != null &&
        const <String>{'owner', 'admin', 'moderator'}.contains(myRole);
    final canInvite =
        myRole != null && const <String>{'owner', 'admin'}.contains(myRole);
    return _KeepAlive(
      child: ListView(
        padding: _pagePadding,
        children: <Widget>[
          SectionHeader(l10n.detailsSectionMembers),
          TileGroup(
            children: <Widget>[
              if (members == null && !_failed)
                ListTile(
                  leading: const SizedBox.square(
                    dimension: 24,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  title: Text(l10n.detailsLoadingMembers),
                )
              else if (members == null || members.isEmpty)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(l10n.detailsMembersUnavailable),
                  subtitle: Text(l10n.detailsMembersUnavailableDetail),
                )
              else
                for (final member in members)
                  _MemberRow(
                    member: member,
                    isSelf: member.accountId == me,
                    timedOutUntil: _timedOutUntil(member.accountId),
                    canRemove: canManageMembers &&
                        member.accountId != me &&
                        (_rank[myRole] ?? 0) > (_rank[member.role] ?? 0),
                    busy: busy,
                    onRemove: () => _remove(member),
                    onBan: () => _ban(member),
                    onTimeout: () => _timeout(member, lift: false),
                    onLiftTimeout: () => _timeout(member, lift: true),
                  ),
            ],
          ),
          if (error != null) _InlineError(error),
          const SizedBox(height: BoneSpacing.sm),
          Text(l10n.detailsMembershipNote, style: muted),
          if (canManageMembers) ...<Widget>[
            const SizedBox(height: BoneSpacing.lg),
            TileGroup(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: Text(l10n.moderationTitle),
                  subtitle: Text(l10n.moderationDetail),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ModerationScreen(
                        state: state,
                        community: widget.community,
                        canManageInvites: canInvite,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: BoneSpacing.lg),
          TileGroup(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(l10n.communityLeave),
                subtitle: Text(l10n.communityLeaveDetail),
                onTap: busy ? null : _leave,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Keeps a tab's page (and the state of what it holds) alive while another
/// tab shows.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isSelf,
    required this.timedOutUntil,
    required this.canRemove,
    required this.busy,
    required this.onRemove,
    required this.onBan,
    required this.onTimeout,
    required this.onLiftTimeout,
  });

  final ConversationMember member;
  final bool isSelf;

  /// When a running timeout ends, from the verified role record; else null.
  final DateTime? timedOutUntil;
  final bool canRemove;
  final bool busy;
  final VoidCallback onRemove;
  final VoidCallback onBan;
  final VoidCallback onTimeout;
  final VoidCallback onLiftTimeout;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = accountLabel(member.accountId, member.username);
    final colors = avatarColorsFor(context, member.accountId);
    // U15: the role shows under the name, in words.
    final details = <String>[
      roleLabel(l10n, member.role),
      if (isSelf) l10n.detailsYou,
      if (member.joinedAt != null)
        l10n.detailsJoined(formatDate(context, member.joinedAt!)),
      if (timedOutUntil != null)
        l10n.memberTimedOutUntil(formatDateTime(context, timedOutUntil!)),
    ];
    return MergeSemantics(
      child: ListTile(
        leading: ExcludeSemantics(
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.fill,
              shape: BoxShape.circle,
              border: Border.all(color: colors.ring),
            ),
            child: Text(
              accountInitials(member.accountId, member.username),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: colors.glyph,
              ),
            ),
          ),
        ),
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(details.join(' · ')),
        trailing: canRemove
            ? PopupMenuButton<VoidCallback>(
                tooltip: l10n.memberModerateTooltip(label),
                enabled: !busy,
                onSelected: (action) => action(),
                itemBuilder: (_) => <PopupMenuEntry<VoidCallback>>[
                  PopupMenuItem<VoidCallback>(
                    value: onRemove,
                    child: Text(l10n.communityRemoveConfirm),
                  ),
                  PopupMenuItem<VoidCallback>(
                    value: onBan,
                    child: Text(l10n.memberBanAction),
                  ),
                  PopupMenuItem<VoidCallback>(
                    value: onTimeout,
                    child: Text(l10n.memberTimeoutAction),
                  ),
                  // U9: only a member who is timed out has a timeout to lift.
                  if (timedOutUntil != null)
                    PopupMenuItem<VoidCallback>(
                      value: onLiftTimeout,
                      child: Text(l10n.memberTimeoutLift),
                    ),
                ],
              )
            : null,
      ),
    );
  }
}
