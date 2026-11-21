import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../calls/room/room_media.dart' show roomSlotScreen;
import '../../calls/room/room_ports.dart';

/// Draws one [RoomVideoTile]'s stream with `flutter_webrtc`. The room screen
/// uses it unless a test supplies its own builder (the native video view
/// needs a real plugin). The stream is whatever the media transport handed
/// over for a track already bound through MLS, or this device's own camera.
class RtcVideoTile extends StatefulWidget {
  const RtcVideoTile({required this.tile, super.key});

  final RoomVideoTile tile;

  @override
  State<RtcVideoTile> createState() => _RtcVideoTileState();
}

class _RtcVideoTileState extends State<RtcVideoTile> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _ready = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) {
      if (_disposed) return;
      _attach();
      setState(() => _ready = true);
    });
  }

  @override
  void didUpdateWidget(RtcVideoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_ready && oldWidget.tile.stream != widget.tile.stream) _attach();
  }

  void _attach() {
    final stream = widget.tile.stream;
    _renderer.srcObject = stream is MediaStream ? stream : null;
  }

  @override
  void dispose() {
    _disposed = true;
    _renderer.srcObject = null;
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const ColoredBox(color: Colors.black);
    return RTCVideoView(
      _renderer,
      // The camera preview reads like a mirror; a shared screen never does.
      mirror: widget.tile.local,
      objectFit: widget.tile.slot == roomSlotScreen
          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
          : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }
}
