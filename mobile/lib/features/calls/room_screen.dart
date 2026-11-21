import 'dart:async';

import 'package:flutter/material.dart';

import '../../calls/room/room_engine.dart';
import '../../calls/room/room_media.dart' show roomSlotScreen;
import '../../calls/room/room_ports.dart';
import '../../l10n/l10n.dart';
import 'room_video_tile.dart';

/// B6 group call and voice room screen. It shows the call group's MLS
/// roster (never the server's list), the end-to-end note, mute and screen
/// camera and screen share when the build has a media transport, and Leave.
/// Phones are foreground only until T42B (O5): the room is left when the app
/// goes to the background, except while an OS permission or capture-consent
/// screen is up (it pauses the app too, and must not end the call the person
/// just asked to add video to).
class RoomScreen extends StatefulWidget {
  const RoomScreen({
    required this.engine,
    required this.nameFor,
    this.controls,
    this.videoTileBuilder,
    super.key,
  });

  final RoomEngine engine;

  /// A display name for an account id (the app's contact names).
  final String Function(String accountId) nameFor;
  final RoomMediaControls? controls;

  /// Draws a video tile's stream. The default is [RtcVideoTile]; tests supply
  /// their own because the native video view needs the real plugin.
  final Widget Function(BuildContext context, RoomVideoTile tile)?
      videoTileBuilder;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> with WidgetsBindingObserver {
  AppLifecycleState? _lifecycle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controls?.addListener(_maybeLeave);
  }

  @override
  void didUpdateWidget(RoomScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controls != widget.controls) {
      oldWidget.controls?.removeListener(_maybeLeave);
      widget.controls?.addListener(_maybeLeave);
    }
  }

  @override
  void dispose() {
    widget.controls?.removeListener(_maybeLeave);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _maybeLeave();
  }

  /// Leaves when the app is away (O5), unless the OS is asking for a
  /// permission or capture consent (microphone, camera, screen): that pauses
  /// the app only while the question is up. It is checked again when the
  /// question ends, so a person who went home meanwhile still leaves.
  void _maybeLeave() {
    final away = _lifecycle == AppLifecycleState.paused ||
        _lifecycle == AppLifecycleState.inactive && _isPhone;
    if (!away) return;
    if (widget.controls?.requestingPermission ?? false) return;
    unawaited(widget.engine.leave());
  }

  bool get _isPhone {
    if (!mounted) return false;
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  String _status() {
    final l10n = context.l10n;
    final engine = widget.engine;
    return switch (engine.phase) {
      RoomPhase.idle || RoomPhase.joining => l10n.roomJoining,
      RoomPhase.active => l10n.roomConnected,
      RoomPhase.left => l10n.roomFailedOther,
      RoomPhase.failed => switch (engine.failure) {
          RoomFailure.full => l10n.roomFailedFull,
          RoomFailure.unavailable => l10n.roomFailedUnavailable,
          RoomFailure.welcomeRefused ||
          RoomFailure.welcomeTimeout =>
            l10n.roomFailedWelcome,
          RoomFailure.cryptorNotFailClosed => l10n.roomFailedCryptor,
          _ => l10n.roomFailedOther,
        },
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final controls = widget.controls;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.engine,
        if (controls != null) controls,
      ]),
      builder: (context, _) {
        final engine = widget.engine;
        final roster = engine.roster;
        final ended =
            engine.phase == RoomPhase.failed || engine.phase == RoomPhase.left;
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.roomTitle),
            leading: IconButton(
              key: const Key('room-leave-back'),
              icon: const Icon(Icons.close),
              tooltip: l10n.roomLeave,
              onPressed: () async {
                final navigator = Navigator.of(context);
                await engine.leave();
                navigator.maybePop();
              },
            ),
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    _status(),
                    key: const Key('room-status'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (engine.phase == RoomPhase.active)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l10n.roomPeople(roster.length),
                        key: const Key('room-count'),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    l10n.roomEncryptedNote,
                    key: const Key('room-e2e-note'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (controls != null && controls.notice != null)
                  _NoticeBanner(
                    text: _noticeText(controls.notice!),
                    onDismiss: controls.dismissNotice,
                  ),
                if (controls != null && controls.sharingScreen && !ended)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l10n.roomSharingYou,
                        key: const Key('room-sharing-note'),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ),
                if (controls != null && controls.videoTiles.isNotEmpty)
                  _videoStrip(context, controls.videoTiles),
                Expanded(
                  child: ListView(
                    key: const Key('room-roster'),
                    children: <Widget>[
                      for (final member in roster)
                        ListTile(
                          key: Key('room-member-${member.id}'),
                          leading: CircleAvatar(child: Text(_initial(member))),
                          title: Text(
                            _isSelf(member)
                                ? l10n.roomYou
                                : widget.nameFor(member.accountId),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: <Widget>[
                      if (controls != null && !ended)
                        FilledButton.tonalIcon(
                          key: const Key('room-mute'),
                          onPressed: () => unawaited(
                            controls.setMicMuted(!controls.micMuted),
                          ),
                          icon: Icon(
                            controls.micMuted ? Icons.mic_off : Icons.mic,
                          ),
                          label: Text(
                            controls.micMuted ? l10n.roomUnmute : l10n.roomMute,
                          ),
                        ),
                      if (controls != null && controls.canUseCamera && !ended)
                        FilledButton.tonalIcon(
                          key: const Key('room-camera'),
                          onPressed: () => unawaited(
                            controls.setCameraOn(!controls.cameraOn),
                          ),
                          icon: Icon(
                            controls.cameraOn
                                ? Icons.videocam
                                : Icons.videocam_off_outlined,
                          ),
                          label: Text(
                            controls.cameraOn
                                ? l10n.roomCameraOff
                                : l10n.roomCameraOn,
                          ),
                        ),
                      if (controls != null && controls.canShareScreen && !ended)
                        FilledButton.tonalIcon(
                          key: const Key('room-share'),
                          onPressed: () => unawaited(_toggleShare(controls)),
                          icon: const Icon(Icons.screen_share_outlined),
                          label: Text(
                            controls.sharingScreen
                                ? l10n.roomStopSharing
                                : l10n.roomShareScreen,
                          ),
                        ),
                      FilledButton.icon(
                        key: const Key('room-leave'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onError,
                        ),
                        onPressed: () async {
                          final navigator = Navigator.of(context);
                          await engine.leave();
                          navigator.maybePop();
                        },
                        icon: const Icon(Icons.call_end),
                        label: Text(l10n.roomLeave),
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

  String _noticeText(RoomMediaNotice notice) {
    final l10n = context.l10n;
    return switch (notice) {
      RoomMediaNotice.cameraUnavailable => l10n.roomNoticeCamera,
      RoomMediaNotice.screenUnavailable => l10n.roomNoticeScreen,
      RoomMediaNotice.screenNoSource => l10n.roomNoticeNoSource,
      RoomMediaNotice.videoRoomFull => l10n.roomNoticeVideoFull,
    };
  }

  /// Stops a share, or starts one: on desktop after the person picks a
  /// screen or window here (names only), on Android through the system's own
  /// consent screen.
  Future<void> _toggleShare(RoomMediaControls controls) async {
    if (controls.sharingScreen) {
      await controls.setSharingScreen(false);
      return;
    }
    if (!controls.screenNeedsSource) {
      await controls.setSharingScreen(true);
      return;
    }
    final sources = await controls.screenSources();
    if (!mounted) return;
    if (sources.isEmpty) {
      // No source: the transport sets the "nothing to share" notice.
      await controls.setSharingScreen(true);
      return;
    }
    final picked = await showDialog<ScreenSource>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('room-source-picker'),
        title: Text(context.l10n.roomPickSourceTitle),
        children: <Widget>[
          for (final source in sources)
            SimpleDialogOption(
              key: Key('room-source-${source.id}'),
              onPressed: () => Navigator.of(context).pop(source),
              child: Row(
                children: <Widget>[
                  Icon(
                    source.isWindow
                        ? Icons.web_asset_outlined
                        : Icons.desktop_windows_outlined,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      source.name.isEmpty
                          ? (source.isWindow
                              ? context.l10n.roomSourceWindow
                              : context.l10n.roomSourceScreen)
                          : source.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null) {
      await controls.setSharingScreen(true, sourceId: picked.id);
    }
  }

  Widget _videoStrip(BuildContext context, List<RoomVideoTile> tiles) {
    final l10n = context.l10n;
    final build = widget.videoTileBuilder ??
        (BuildContext context, RoomVideoTile tile) => RtcVideoTile(tile: tile);
    return SizedBox(
      key: const Key('room-videos'),
      height: 220,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: <Widget>[
          for (final tile in tiles)
            Padding(
              key: Key('room-video-${tile.id}'),
              padding: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      build(context, tile),
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.all(Radius.circular(4)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              _tileLabel(l10n, tile),
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _tileLabel(AppLocalizations l10n, RoomVideoTile tile) {
    final id = tile.memberId;
    if (id == null) return l10n.roomYou;
    final name = widget.nameFor(id.split('/').first);
    return tile.slot == roomSlotScreen ? l10n.roomTileScreen(name) : name;
  }

  bool _isSelf(CallMember member) =>
      member.accountId == widget.engine.selfAccountId &&
      member.deviceId == widget.engine.selfDeviceId;

  String _initial(CallMember member) {
    final name = widget.nameFor(member.accountId);
    return name.isEmpty ? '?' : name.characters.first.toUpperCase();
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.text, required this.onDismiss});

  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        key: const Key('room-notice'),
        children: <Widget>[
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          IconButton(
            key: const Key('room-notice-dismiss'),
            icon: const Icon(Icons.close),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
