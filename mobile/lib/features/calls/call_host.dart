import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../calls/call_controller.dart';
import '../../calls/call_service.dart';
import '../../core/app_state.dart';
import '../../crypto/crypto_service.dart';
import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';
import '../chat/chat_list_screen.dart' show conversationTitle;

/// Demo builds only (D11): owns the [NativeCallService] and [CallController]
/// for the signed-in session and draws incoming-call, call and notice UI
/// above every route. Release builds (`config.demo` false) never create one,
/// so messaging and calls stay off there.
class CallHost extends StatefulWidget {
  const CallHost({required this.state, required this.child, super.key});

  final AppState state;
  final Widget child;

  @override
  State<CallHost> createState() => _CallHostState();
}

class _CallHostState extends State<CallHost> {
  NativeCallService? _service;
  CallController? _controller;
  String? _token;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(CallHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_sync);
      _teardown();
      widget.state.addListener(_sync);
      _sync();
    }
  }

  /// Follows the session: one service per signed-in token, dropped on
  /// sign-out so a hung-up or abandoned call cannot outlive its account.
  void _sync() {
    final state = widget.state;
    final session = state.session;
    final api = state.api;
    final crypto = state.cryptoService;
    final token = state.config.demo &&
            session != null &&
            api != null &&
            crypto is MlsConversationCryptoService
        ? session.token
        : null;
    if (token == _token) return;
    _teardown();
    _token = token;
    if (token == null) return;
    final service = NativeCallService(
        api: api!,
        token: token,
        crypto: crypto as MlsConversationCryptoService,
        incoming: state.callSignals);
    final controller = CallController(
        service: service,
        selfAccountId: session!.accountId,
        speakerSupported: Platform.isAndroid || Platform.isIOS);
    _service = service;
    _controller = controller;
    state.callController.value = controller;
    if (mounted) setState(() {});
  }

  void _teardown() {
    final controller = _controller;
    final service = _service;
    _controller = null;
    _service = null;
    _token = null;
    if (widget.state.callController.value == controller) {
      widget.state.callController.value = null;
    }
    controller?.dispose();
    if (service != null) service.dispose();
  }

  @override
  void dispose() {
    widget.state.removeListener(_sync);
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return widget.child;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: widget.child),
        Positioned.fill(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => _overlay(context, controller),
          ),
        ),
      ],
    );
  }

  Widget _overlay(BuildContext context, CallController controller) {
    final title = _title(context, controller);
    if (controller.phase != CallPhase.idle) {
      return CallScreen(controller: controller, title: title);
    }
    final notice = controller.notice;
    if (notice == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(BoneSpacing.gutter),
          child: CallNoticeCard(
            notice: notice,
            title: _titleFor(context, notice.conversationId),
            onDismiss: controller.dismissNotice,
          ),
        ),
      ),
    );
  }

  String _title(BuildContext context, CallController controller) =>
      _titleFor(context, controller.conversationId);

  String _titleFor(BuildContext context, String? conversationId) {
    final conversation = widget.state.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    return conversation == null
        ? context.l10n.callUnknownContact
        : conversationTitle(context.l10n, conversation);
  }
}

/// The missed / declined / failed notice after a call.
class CallNoticeCard extends StatelessWidget {
  const CallNoticeCard(
      {required this.notice,
      required this.title,
      required this.onDismiss,
      super.key});

  final CallNotice notice;
  final String title;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = switch (notice.kind) {
      CallNoticeKind.missed => l10n.callNoticeMissed(title),
      CallNoticeKind.declined => l10n.callNoticeDeclined(title),
      CallNoticeKind.noAnswer => l10n.callNoticeNoAnswer(title),
      CallNoticeKind.busy => l10n.callNoticeBusy(title),
      CallNoticeKind.failed => l10n.callNoticeFailed,
    };
    final icon = notice.kind == CallNoticeKind.missed
        ? Icons.phone_missed
        : Icons.phone_disabled;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: BoneSpacing.lg, vertical: BoneSpacing.sm),
        child: Row(
          children: <Widget>[
            Icon(icon),
            const SizedBox(width: BoneSpacing.md),
            Expanded(child: Text(text, key: const Key('call-notice-text'))),
            TextButton(
              key: const Key('call-notice-dismiss'),
              onPressed: onDismiss,
              child: Text(l10n.callDismiss),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen incoming, outgoing and in-call UI.
class CallScreen extends StatefulWidget {
  const CallScreen({required this.controller, required this.title, super.key});

  final CallController controller;
  final String title;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final RTCVideoRenderer _remote = RTCVideoRenderer();
  final RTCVideoRenderer _local = RTCVideoRenderer();
  bool _renderersReady = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    try {
      await _remote.initialize();
      await _local.initialize();
    } catch (_) {
      return; // No renderer on this platform: audio still works.
    }
    if (_disposed) {
      await _remote.dispose();
      await _local.dispose();
      return;
    }
    _renderersReady = true;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    if (_renderersReady) {
      _remote.srcObject = null;
      _local.srcObject = null;
      _remote.dispose();
      _local.dispose();
    }
    super.dispose();
  }

  String _status(CallController c) {
    final l10n = context.l10n;
    return switch (c.phase) {
      CallPhase.ringingIn =>
        c.video ? l10n.callIncomingVideo : l10n.callIncoming,
      CallPhase.ringingOut => l10n.callRinging,
      CallPhase.connecting => l10n.callConnecting,
      CallPhase.active => l10n.callInProgress,
      CallPhase.idle => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final showVideo = _renderersReady && c.video && c.remoteStream != null;
    if (_renderersReady) {
      _remote.srcObject = c.remoteStream;
      _local.srcObject = c.phase == CallPhase.active || c.hasLocalVideo
          ? (c.hasLocalVideo ? c.localStream : null)
          : null;
    }
    return Material(
      color: theme.colorScheme.surface,
      child: Semantics(
        container: true,
        label: _status(c),
        child: SafeArea(
          child: Stack(
            children: <Widget>[
              if (showVideo)
                Positioned.fill(
                    child: RTCVideoView(_remote,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)),
              Column(
                children: <Widget>[
                  const SizedBox(height: BoneSpacing.xl * 2),
                  if (!showVideo)
                    CircleAvatar(
                        radius: 48,
                        child: Text(
                            widget.title.isEmpty
                                ? '?'
                                : widget.title.characters.first.toUpperCase(),
                            style: theme.textTheme.displaySmall)),
                  const SizedBox(height: BoneSpacing.lg),
                  Text(widget.title,
                      key: const Key('call-title'),
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center),
                  const SizedBox(height: BoneSpacing.sm),
                  Text(_status(c),
                      key: const Key('call-status'),
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: BoneSpacing.sm),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: BoneSpacing.xl),
                    child: Text(
                      l10n.callRelayNote,
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Spacer(),
                  if (c.phase == CallPhase.ringingIn)
                    _incomingButtons(c)
                  else
                    _controls(c),
                  const SizedBox(height: BoneSpacing.xl * 2),
                ],
              ),
              if (_renderersReady && c.hasLocalVideo && !c.cameraOff)
                Positioned(
                  top: BoneSpacing.lg,
                  right: BoneSpacing.lg,
                  width: 96,
                  height: 128,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RTCVideoView(_local,
                        mirror: true,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _incomingButtons(CallController c) {
    final l10n = context.l10n;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        _RoundButton(
            key: const Key('call-decline'),
            icon: Icons.call_end,
            label: l10n.callDecline,
            color: Colors.red,
            onPressed: c.decline),
        _RoundButton(
            key: const Key('call-accept'),
            icon: c.video ? Icons.videocam : Icons.call,
            label: l10n.callAccept,
            color: Colors.green,
            onPressed: c.accept),
      ],
    );
  }

  Widget _controls(CallController c) {
    final l10n = context.l10n;
    final canControl = c.phase == CallPhase.active ||
        c.phase == CallPhase.connecting ||
        c.phase == CallPhase.ringingOut;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        _RoundButton(
            key: const Key('call-mute'),
            icon: c.muted ? Icons.mic_off : Icons.mic,
            label: c.muted ? l10n.callUnmute : l10n.callMute,
            selected: c.muted,
            onPressed: canControl ? c.toggleMute : null),
        if (c.speakerSupported)
          _RoundButton(
              key: const Key('call-speaker'),
              icon: c.speakerOn ? Icons.volume_up : Icons.volume_down,
              label: l10n.callSpeaker,
              selected: c.speakerOn,
              onPressed: canControl ? c.toggleSpeaker : null),
        if (c.video)
          _RoundButton(
              key: const Key('call-camera'),
              icon: c.cameraOff ? Icons.videocam_off : Icons.videocam,
              label: c.cameraOff ? l10n.callCameraOn : l10n.callCameraOff,
              selected: c.cameraOff,
              onPressed: canControl ? c.toggleCamera : null),
        _RoundButton(
            key: const Key('call-hangup'),
            icon: Icons.call_end,
            label: l10n.callHangUp,
            color: Colors.red,
            onPressed: c.hangUp),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton(
      {required this.icon,
      required this.label,
      required this.onPressed,
      this.color,
      this.selected = false,
      super.key});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton.filled(
          tooltip: label,
          iconSize: 28,
          style: IconButton.styleFrom(
            minimumSize: const Size(64, 64),
            backgroundColor: color ??
                (selected ? scheme.primary : scheme.surfaceContainerHighest),
            foregroundColor: color != null
                ? Colors.white
                : (selected ? scheme.onPrimary : scheme.onSurface),
          ),
          onPressed: onPressed,
          icon: Icon(icon),
        ),
        const SizedBox(height: BoneSpacing.xs),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}
