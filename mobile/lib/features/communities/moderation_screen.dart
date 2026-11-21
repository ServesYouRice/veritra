import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets/large_title_bar.dart';
import '../../ui/widgets/section_header.dart';
import '../../ui/widgets/tile_group.dart';

/// A length in seconds written in words: "30 seconds", "10 minutes",
/// "6 hours", "7 days" (U37).
String durationWords(AppLocalizations l10n, int seconds) {
  if (seconds < 60) return l10n.durationSeconds(seconds);
  if (seconds < 3600) return l10n.durationMinutes(seconds ~/ 60);
  if (seconds < 86400) return l10n.durationHours(seconds ~/ 3600);
  return l10n.durationDays(seconds ~/ 86400);
}

/// The lengths offered for a timeout and for pausing invitations.
const List<int> timeoutChoices = <int>[600, 3600, 86400, 604800];
const List<int> pauseChoices = <int>[3600, 86400, 604800];

/// The slow-mode gaps offered (the server allows up to 6 hours).
const List<int> slowModeChoices = <int>[0, 10, 30, 60, 300, 3600, 21600];

/// Asks for one of [choices] (seconds). Null when dismissed.
Future<int?> pickDuration(
  BuildContext context, {
  required String title,
  required List<int> choices,
  required String Function(int seconds) label,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(BoneSpacing.gutter),
              child: Text(
                title,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final seconds in choices)
              ListTile(
                title: Text(label(seconds)),
                onTap: () => Navigator.of(sheetContext).pop(seconds),
              ),
          ],
        ),
      ),
    ),
  );
}

/// C5: what moderators and above manage in a community: paused invitations,
/// slow mode per channel, bans and the activity log. The server enforces all
/// of it; nothing here is a reason or message text (the server stores none).
class ModerationScreen extends StatefulWidget {
  const ModerationScreen({
    required this.state,
    required this.community,
    this.canManageInvites = false,
    super.key,
  });

  final AppState state;
  final Community community;

  /// Admins and above pause invitations; moderators do the rest.
  final bool canManageInvites;

  @override
  State<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends State<ModerationScreen> {
  ModerationState? _moderation;
  List<CommunityBan>? _bans;
  List<ModerationEvent>? _events;

  /// Running timeouts of people who left (admins and above only).
  List<DepartedTimeout>? _departed;
  Map<String, String> _names = const <String, String>{};

  /// True until the first read finishes, so no default ("Nobody is banned",
  /// "Off", "Invitation links work normally") shows before the data is here.
  bool _loading = true;
  bool _failed = false;

  AppState get state => widget.state;
  String get _communityId => widget.community.id;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_failed) {
      setState(() {
        _failed = false;
        _loading = true;
      });
    }
    final results = await Future.wait<Object?>(<Future<Object?>>[
      state.loadModerationState(_communityId),
      state.loadCommunityBans(_communityId),
      widget.canManageInvites
          ? state.loadModerationEvents(_communityId)
          : Future<Object?>.value(null),
      state.loadCommunityMembers(_communityId),
      widget.canManageInvites
          ? state.loadDepartedTimeouts(_communityId)
          : Future<Object?>.value(null),
    ]);
    if (!mounted) return;
    final members = results[3] as List<ConversationMember>?;
    setState(() {
      _moderation = results[0] as ModerationState?;
      _bans = results[1] as List<CommunityBan>?;
      _events = results[2] as List<ModerationEvent>?;
      _departed = results[4] as List<DepartedTimeout>?;
      _loading = false;
      // Any part that did not load fails the whole screen: a missing list
      // must never read as an empty one.
      _failed = _moderation == null ||
          _bans == null ||
          (widget.canManageInvites && (_events == null || _departed == null));
      _names = <String, String>{
        for (final member in members ?? const <ConversationMember>[])
          member.accountId: accountLabel(member.accountId, member.username),
      };
    });
  }

  String _name(String? accountId) {
    if (accountId == null) return '';
    final ban = (_bans ?? const <CommunityBan>[])
        .where((b) => b.accountId == accountId)
        .firstOrNull;
    final departed = (_departed ?? const <DepartedTimeout>[])
        .where((d) => d.accountId == accountId)
        .firstOrNull;
    return _names[accountId] ??
        accountLabel(accountId, ban?.username ?? departed?.username);
  }

  /// The channel's encrypted name, else a placeholder (C3: the server keeps
  /// none).
  String _channelName(Channel channel) =>
      state.channelDisplayName(channel) ?? context.l10n.channelPlaceholderName;

  Future<void> _setSlowMode(Channel channel) async {
    final l10n = context.l10n;
    final seconds = await pickDuration(
      context,
      title: l10n.moderationSlowTitle(_channelName(channel)),
      choices: slowModeChoices,
      label: (s) => s == 0 ? l10n.moderationSlowOff : durationWords(l10n, s),
    );
    if (seconds == null || !mounted) return;
    if (await state.setChannelSlowMode(_communityId, channel.id, seconds)) {
      await _load();
    }
  }

  Future<void> _pauseInvites() async {
    final l10n = context.l10n;
    final seconds = await pickDuration(
      context,
      title: l10n.moderationPauseInvites,
      choices: pauseChoices,
      label: (s) => durationWords(l10n, s),
    );
    if (seconds == null || !mounted) return;
    if (await state.setInvitesPaused(_communityId, seconds)) await _load();
  }

  Future<void> _resumeInvites() async {
    if (await state.setInvitesPaused(_communityId, 0)) await _load();
  }

  Future<void> _unban(CommunityBan ban) async {
    if (await state.unbanCommunityMember(_communityId, ban.accountId)) {
      await _load();
    }
  }

  /// Lifts the timeout of someone who left, so a rejoin starts without it
  /// (owner decision 2026-11-21; admins and above).
  Future<void> _liftDeparted(DepartedTimeout timeout) async {
    if (await state.timeoutCommunityMember(
      _communityId,
      timeout.accountId,
      0,
    )) {
      await _load();
    }
  }

  String _eventText(AppLocalizations l10n, ModerationEvent e) {
    final actor = _name(e.actor);
    final target = _name(e.target);
    return switch (e.action) {
      'kick' => l10n.moderationLogKick(actor, target),
      'ban' => l10n.moderationLogBan(actor, target),
      'unban' => l10n.moderationLogUnban(actor, target),
      'timeout' => l10n.moderationLogTimeout(actor, target),
      'timeout_cleared' => l10n.moderationLogTimeoutCleared(actor, target),
      'slow_mode' => l10n.moderationLogSlowMode(actor),
      'invites_paused' => l10n.moderationLogInvitesPaused(actor),
      'invites_resumed' => l10n.moderationLogInvitesResumed(actor),
      _ => actor,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final busy = state.isBusy(Ops.membership);
        final error = state.errorFor(Ops.membership);
        return Scaffold(
          appBar: LargeTitleBar(title: l10n.moderationTitle),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _failed
                  ? _LoadFailed(onRetry: _load)
                  : _content(context, l10n, busy: busy, error: error),
        );
      },
    );
  }

  Widget _content(
    BuildContext context,
    AppLocalizations l10n, {
    required bool busy,
    required String? error,
  }) {
    final moderation = _moderation;
    final paused = moderation?.invitesPausedUntil;
    final channels =
        state.channelsByCommunity[_communityId] ?? const <Channel>[];
    final bans = _bans ?? const <CommunityBan>[];
    final events = _events ?? const <ModerationEvent>[];
    final departed = _departed ?? const <DepartedTimeout>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        BoneSpacing.gutter,
        BoneSpacing.sm,
        BoneSpacing.gutter,
        BoneSpacing.xl,
      ),
      children: <Widget>[
        if (error != null)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (widget.canManageInvites) ...<Widget>[
          SectionHeader(l10n.moderationSectionInvites),
          TileGroup(
            children: <Widget>[
              ListTile(
                leading: Icon(
                  paused == null ? Icons.link : Icons.pause_circle_outline,
                ),
                title: Text(
                  paused == null
                      ? l10n.moderationInvitesOpen
                      : l10n.moderationInvitesPaused(
                          formatDateTime(context, paused.toLocal()),
                        ),
                ),
              ),
              ListTile(
                leading: Icon(paused == null ? Icons.pause : Icons.play_arrow),
                title: Text(
                  paused == null
                      ? l10n.moderationPauseInvites
                      : l10n.moderationResumeInvites,
                ),
                onTap: busy
                    ? null
                    : (paused == null ? _pauseInvites : _resumeInvites),
              ),
            ],
          ),
        ],
        SectionHeader(l10n.moderationSectionSlow),
        TileGroup(
          children: <Widget>[
            for (final channel in channels)
              ListTile(
                leading: const Icon(Icons.speed_outlined),
                title: Text(_channelName(channel)),
                subtitle: Text(
                  (moderation?.slowModeSeconds[channel.id] ?? 0) == 0
                      ? l10n.moderationSlowOff
                      : l10n.moderationSlowEvery(
                          durationWords(
                            l10n,
                            moderation!.slowModeSeconds[channel.id]!,
                          ),
                        ),
                ),
                onTap: busy ? null : () => _setSlowMode(channel),
              ),
          ],
        ),
        SectionHeader(l10n.moderationSectionBans),
        TileGroup(
          children: <Widget>[
            if (bans.isEmpty)
              ListTile(title: Text(l10n.moderationNoBans))
            else
              for (final ban in bans)
                ListTile(
                  leading: const Icon(Icons.block),
                  title: Text(_name(ban.accountId)),
                  // The server lets admins and above lift bans.
                  trailing: widget.canManageInvites
                      ? IconButton(
                          tooltip: l10n.moderationUnban(_name(ban.accountId)),
                          onPressed: busy ? null : () => _unban(ban),
                          icon: const Icon(Icons.undo),
                        )
                      : null,
                ),
          ],
        ),
        if (widget.canManageInvites) ...<Widget>[
          SectionHeader(l10n.moderationSectionDepartedTimeouts),
          TileGroup(
            children: <Widget>[
              if (departed.isEmpty)
                ListTile(title: Text(l10n.moderationNoDepartedTimeouts))
              else ...<Widget>[
                ListTile(
                  dense: true,
                  title: Text(l10n.moderationDepartedTimeoutsNote),
                ),
                for (final timeout in departed)
                  ListTile(
                    leading: const Icon(Icons.timer_off_outlined),
                    title: Text(_name(timeout.accountId)),
                    subtitle: Text(
                      l10n.moderationDepartedTimeoutUntil(
                        formatDateTime(context, timeout.timeoutUntil.toLocal()),
                      ),
                    ),
                    trailing: IconButton(
                      key: ValueKey<String>(
                        'lift-departed-${timeout.accountId}',
                      ),
                      tooltip: l10n.moderationLiftTimeout(
                        _name(timeout.accountId),
                      ),
                      onPressed: busy ? null : () => _liftDeparted(timeout),
                      icon: const Icon(Icons.undo),
                    ),
                  ),
              ],
            ],
          ),
          SectionHeader(l10n.moderationSectionLog),
          TileGroup(
            children: <Widget>[
              if (events.isEmpty)
                ListTile(title: Text(l10n.moderationNoEvents))
              else
                for (final e in events)
                  ListTile(
                    dense: true,
                    title: Text(_eventText(l10n, e)),
                    subtitle: Text(
                      formatDateTime(context, e.createdAt.toLocal()),
                    ),
                  ),
            ],
          ),
        ],
      ],
    );
  }
}

/// What the screen shows when moderation data did not load: one message and
/// Retry, in place of any default that would pass for real data.
class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(BoneSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: BoneSpacing.sm),
            Text(l10n.moderationLoadFailed, textAlign: TextAlign.center),
            const SizedBox(height: BoneSpacing.md),
            FilledButton(onPressed: onRetry, child: Text(l10n.commonRetry)),
          ],
        ),
      ),
    );
  }
}
