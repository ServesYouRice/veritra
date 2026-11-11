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

/// A length in seconds as a short, language-neutral label: "30 s", "5 min",
/// "6 h", "7 d".
String shortDuration(int seconds) {
  if (seconds < 60) return '$seconds s';
  if (seconds < 3600) return '${seconds ~/ 60} min';
  if (seconds < 86400) return '${seconds ~/ 3600} h';
  return '${seconds ~/ 86400} d';
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
  Map<String, String> _names = const <String, String>{};
  bool _failed = false;

  AppState get state => widget.state;
  String get _communityId => widget.community.id;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final results = await Future.wait<Object?>(<Future<Object?>>[
      state.loadModerationState(_communityId),
      state.loadCommunityBans(_communityId),
      widget.canManageInvites
          ? state.loadModerationEvents(_communityId)
          : Future<Object?>.value(null),
      state.loadCommunityMembers(_communityId),
    ]);
    if (!mounted) return;
    final members = results[3] as List<ConversationMember>?;
    setState(() {
      _moderation = results[0] as ModerationState?;
      _bans = results[1] as List<CommunityBan>?;
      _events = results[2] as List<ModerationEvent>?;
      _failed = _moderation == null || _bans == null;
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
    return _names[accountId] ?? accountLabel(accountId, ban?.username);
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
      label: (s) => s == 0 ? l10n.moderationSlowOff : shortDuration(s),
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
      label: shortDuration,
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
        final moderation = _moderation;
        final paused = moderation?.invitesPausedUntil;
        final channels =
            state.channelsByCommunity[_communityId] ?? const <Channel>[];
        final bans = _bans ?? const <CommunityBan>[];
        final events = _events ?? const <ModerationEvent>[];
        return Scaffold(
          appBar: LargeTitleBar(title: l10n.moderationTitle),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              BoneSpacing.gutter,
              BoneSpacing.sm,
              BoneSpacing.gutter,
              BoneSpacing.xl,
            ),
            children: <Widget>[
              if (_failed)
                ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: Text(l10n.detailsMembersUnavailable),
                ),
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
                        paused == null
                            ? Icons.link
                            : Icons.pause_circle_outline,
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
                      leading: Icon(
                        paused == null ? Icons.pause : Icons.play_arrow,
                      ),
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
                            : l10n.moderationSlowEvery(shortDuration(
                                moderation!.slowModeSeconds[channel.id]!)),
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
                                tooltip:
                                    l10n.moderationUnban(_name(ban.accountId)),
                                onPressed: busy ? null : () => _unban(ban),
                                icon: const Icon(Icons.undo),
                              )
                            : null,
                      ),
                ],
              ),
              if (widget.canManageInvites) ...<Widget>[
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
                              formatDateTime(context, e.createdAt.toLocal())),
                        ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
