import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// The two native WebRTC entry points [NativeCallService] needs, behind an
/// interface so tests can run the service against fakes (calls stay behind
/// interfaces, AGENTS.md).
abstract interface class CallMediaFactory {
  Future<webrtc.RTCPeerConnection> createPeer(
      Map<String, Object?> configuration);
  Future<webrtc.MediaStream> getUserMedia(Map<String, Object?> constraints);
}

/// The production factory: flutter_webrtc's own functions. It touches no
/// platform channel until a method is called.
class FlutterWebRtcMediaFactory implements CallMediaFactory {
  const FlutterWebRtcMediaFactory();

  @override
  Future<webrtc.RTCPeerConnection> createPeer(
          Map<String, Object?> configuration) =>
      webrtc.createPeerConnection(configuration);

  @override
  Future<webrtc.MediaStream> getUserMedia(Map<String, Object?> constraints) =>
      webrtc.navigator.mediaDevices.getUserMedia(constraints);
}
