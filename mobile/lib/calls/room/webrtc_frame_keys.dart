import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'room_ports.dart';

/// The frame cryptor could not be set up fail closed (B6): the call is
/// refused rather than joined without end-to-end media encryption.
class FrameEncryptionUnavailable implements Exception {
  const FrameEncryptionUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'FrameEncryptionUnavailable: $reason';
}

/// The HKDF salt the native key provider derives each frame key with, the
/// same on every device. The raw key is `K(s,t)` from the MLS core.
final Uint8List b6FrameSalt =
    Uint8List.fromList(utf8.encode('veritra-b6-frame-v1'));

/// The exact key provider options B6 requires (design, "Required cryptor
/// settings"): discard frames with no key, no magic bytes (no frame skips
/// decryption), per-participant keys, HKDF, no ratchet (MLS epochs are the
/// only rekey) and a ring of 16. Throws for settings that are not fail
/// closed.
KeyProviderOptions b6KeyProviderOptions(RoomCryptorSettings settings) {
  if (!settings.failClosed) {
    throw const FrameEncryptionUnavailable('settings are not fail closed');
  }
  return KeyProviderOptions(
    sharedKey: false,
    ratchetSalt: b6FrameSalt,
    ratchetWindowSize: 0,
    uncryptedMagicBytes: null,
    keyRingSize: settings.keyRingSize,
    discardFrameWhenCryptorNotReady: true,
    keyDerivationAlgorithm: KeyDerivationAlgorithm.kHKDF,
  );
}

/// Creates a key provider; the default is flutter_webrtc's native one.
typedef KeyProviderCreator = Future<KeyProvider> Function(
    KeyProviderOptions options);

Future<KeyProvider> _nativeProvider(KeyProviderOptions options) =>
    frameCryptorFactory.createDefaultKeyProvider(options);

/// [FrameKeySink] over libwebrtc's frame cryptor key provider. The engine
/// calls it synchronously; the native calls run in order on one chain, so a
/// send-index switch never overtakes the keys installed before it. A key
/// the provider refuses fails the call ([failed]).
///
/// The provider cannot delete a key: "removed" overwrites the slot with
/// random bytes nobody holds, so frames under the old key fail and are
/// dropped. Keys also live in libwebrtc's own memory, which Dart cannot zero
/// (design, "Switching keys").
class WebRtcFrameKeys implements FrameKeySink {
  WebRtcFrameKeys._(this.provider, this.settings);

  /// Opens the provider with [b6KeyProviderOptions]. Throws
  /// [FrameEncryptionUnavailable] when the platform cannot provide one.
  static Future<WebRtcFrameKeys> open({
    RoomCryptorSettings settings = const RoomCryptorSettings(),
    KeyProviderCreator create = _nativeProvider,
  }) async {
    final options = b6KeyProviderOptions(settings);
    final KeyProvider provider;
    try {
      provider = await create(options);
    } catch (error) {
      throw FrameEncryptionUnavailable('no key provider: $error');
    }
    return WebRtcFrameKeys._(provider, settings);
  }

  final KeyProvider provider;

  @override
  final RoomCryptorSettings settings;

  /// The key-ring index this device sends with, set after its keys are in.
  final ValueNotifier<int?> sendIndex = ValueNotifier<int?>(null);

  /// Set when the provider refused a key: the media transport leaves.
  final ValueNotifier<bool> failed = ValueNotifier<bool>(false);

  final Set<(String, int)> _installed = <(String, int)>{};
  final Random _random = Random.secure();
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;

  /// Completes when every call made so far has reached the provider.
  Future<void> get idle => _tail;

  void _chain(Future<void> Function() step) {
    _tail = _tail.then((_) async {
      if (_disposed) return;
      try {
        await step();
      } catch (_) {
        failed.value = true;
      }
    });
  }

  Uint8List _randomKey() =>
      Uint8List.fromList(List<int>.generate(32, (_) => _random.nextInt(256)));

  @override
  void setKey(String participant, int index, Uint8List key) {
    final copy = Uint8List.fromList(key);
    _installed.add((participant, index));
    _chain(() async {
      final ok = await provider.setKey(
          participantId: participant, index: index, key: copy);
      copy.fillRange(0, copy.length, 0);
      if (!ok) failed.value = true;
    });
  }

  @override
  void removeKey(String participant, int index) {
    if (!_installed.remove((participant, index))) return;
    final junk = _randomKey();
    _chain(() async {
      await provider.setKey(
          participantId: participant, index: index, key: junk);
    });
  }

  @override
  void useSendKey(int index) {
    _chain(() async => sendIndex.value = index);
  }

  @override
  void clear() {
    final slots = _installed.toList();
    _installed.clear();
    _chain(() async {
      sendIndex.value = null;
      for (final (participant, index) in slots) {
        await provider.setKey(
            participantId: participant, index: index, key: _randomKey());
      }
    });
  }

  /// Clears every key and releases the native provider.
  Future<void> dispose() async {
    clear();
    await _tail;
    _disposed = true;
    try {
      await provider.dispose();
    } catch (_) {}
    sendIndex.dispose();
    failed.dispose();
  }
}
