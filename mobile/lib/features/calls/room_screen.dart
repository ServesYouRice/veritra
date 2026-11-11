import 'dart:async';

import 'package:flutter/material.dart';

import '../../calls/room/room_engine.dart';
import '../../calls/room/room_ports.dart';
import '../../l10n/l10n.dart';

/// B6 group call and voice room screen. It shows the call group's MLS
/// roster (never the server's list), the end-to-end note, mute and screen
/// share when the build has a media transport, and Leave. Phones are
/// foreground only until T42B (O5): the app leaves the room when it goes to
/// the background, which the host wires with [RoomScreen.leaveOnBackground].
class RoomScreen extends StatefulWidget {
  const RoomScreen({
    required this.engine,
    required this.nameFor,
    this.controls,
    super.key,
  });

  final RoomEngine engine;

  /// A display name for an account id (the app's contact names).
  final String Function(String accountId) nameFor;
  final RoomMediaControls? controls;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive && _isPhone) {
      unawaited(widget.engine.leave());
    }
  }

  bool get _isPhone {
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
                  child: Text(_status(),
                      key: const Key('room-status'),
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (engine.phase == RoomPhase.active)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(l10n.roomPeople(roster.length),
                          key: const Key('room-count'),
                          style: Theme.of(context).textTheme.labelMedium),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(l10n.roomEncryptedNote,
                      key: const Key('room-e2e-note'),
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Expanded(
                  child: ListView(
                    key: const Key('room-roster'),
                    children: <Widget>[
                      for (final member in roster)
                        ListTile(
                          key: Key('room-member-${member.id}'),
                          leading: CircleAvatar(
                            child: Text(_initial(member)),
                          ),
                          title: Text(_isSelf(member)
                              ? l10n.roomYou
                              : widget.nameFor(member.accountId)),
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
                              controls.setMicMuted(!controls.micMuted)),
                          icon: Icon(
                              controls.micMuted ? Icons.mic_off : Icons.mic),
                          label: Text(controls.micMuted
                              ? l10n.roomUnmute
                              : l10n.roomMute),
                        ),
                      if (controls != null && controls.canShareScreen && !ended)
                        FilledButton.tonalIcon(
                          key: const Key('room-share'),
                          onPressed: () => unawaited(controls
                              .setSharingScreen(!controls.sharingScreen)),
                          icon: const Icon(Icons.screen_share_outlined),
                          label: Text(controls.sharingScreen
                              ? l10n.roomStopSharing
                              : l10n.roomShareScreen),
                        ),
                      FilledButton.icon(
                        key: const Key('room-leave'),
                        style: FilledButton.styleFrom(
                            backgroundColor:
                                Theme.of(context).colorScheme.error,
                            foregroundColor:
                                Theme.of(context).colorScheme.onError),
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

  bool _isSelf(CallMember member) =>
      member.accountId == widget.engine.selfAccountId &&
      member.deviceId == widget.engine.selfDeviceId;

  String _initial(CallMember member) {
    final name = widget.nameFor(member.accountId);
    return name.isEmpty ? '?' : name.characters.first.toUpperCase();
  }
}
