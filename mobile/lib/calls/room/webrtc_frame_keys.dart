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
///
/// Receivers use aliases ([bindAlias]): one receiver cryptor per remote
/// track, created once under `rx:<track sid>`, gets the bound member's slot
/// keys copied into it, so binding and unbinding never dispose or recreate
/// a cryptor on the same RTP receiver. To copy them, the key bytes stay in
/// Dart memory while installed and are zeroed when removed or cleared.
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

  /// The installed key bytes per participant and ring index (for aliases).
  final Map<(String, int), Uint8List> _held = <(String, int), Uint8List>{};

  /// Alias -> the participant whose keys it mirrors.
  final Map<String, String> _aliases = <String, String>{};

  /// Alias -> the ring indices holding a mirrored key now.
  final Map<String, Set<int>> _aliasIndices = <String, Set<int>>{};

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
    _installed.add((participant, index));
    final old = _held.remove((participant, index));
    old?.fillRange(0, old.length, 0);
    _held[(participant, index)] = Uint8List.fromList(key);
    // The provider gets its own copy: the held one may be zeroed before
    // this step runs.
    final copy = Uint8List.fromList(key);
    final aliases = _aliasesOf(participant);
    for (final alias in aliases) {
      _aliasIndices[alias]!.add(index);
    }
    _chain(() async {
      try {
        for (final id in [participant, ...aliases]) {
          final ok =
              await provider.setKey(participantId: id, index: index, key: copy);
          if (!ok) failed.value = true;
        }
      } finally {
        copy.fillRange(0, copy.length, 0);
      }
    });
  }

  @override
  void removeKey(String participant, int index) {
    if (!_installed.remove((participant, index))) return;
    final held = _held.remove((participant, index));
    held?.fillRange(0, held.length, 0);
    // An alias mirroring it loses the key at the same moment (the 10 s
    // old-key wipe covers receivers too).
    final aliases = [
      for (final alias in _aliasesOf(participant))
        if (_aliasIndices[alias]!.remove(index)) alias,
    ];
    _junk([participant, ...aliases], index);
  }

  /// Overwrites [ids] at [index] with random bytes nobody holds.
  void _junk(List<String> ids, int index) {
    if (ids.isEmpty) return;
    _chain(() async {
      for (final id in ids) {
        await provider.setKey(
            participantId: id, index: index, key: _randomKey());
      }
    });
  }

  List<String> _aliasesOf(String participant) => [
        for (final entry in _aliases.entries)
          if (entry.value == participant) entry.key,
      ];

  /// Makes [alias] mirror [participant]: every key [participant] holds now
  /// is copied to the same ring index of [alias], later [setKey]s and
  /// [removeKey]s follow, and any index [alias] held that [participant]
  /// lacks is overwritten with random bytes. A receiver cryptor keyed by
  /// [alias] then decrypts [participant]'s frames, and nobody else's.
  void bindAlias(String alias, String participant) {
    final before = _aliasIndices[alias] ?? <int>{};
    _aliases[alias] = participant;
    final now = <int, Uint8List>{
      for (final entry in _held.entries)
        if (entry.key.$1 == participant)
          entry.key.$2: Uint8List.fromList(entry.value),
    };
    _aliasIndices[alias] = now.keys.toSet();
    final stale = before.difference(now.keys.toSet());
    _chain(() async {
      try {
        for (final entry in now.entries) {
          final ok = await provider.setKey(
              participantId: alias, index: entry.key, key: entry.value);
          if (!ok) failed.value = true;
        }
        for (final index in stale) {
          await provider.setKey(
              participantId: alias, index: index, key: _randomKey());
        }
      } finally {
        for (final key in now.values) {
          key.fillRange(0, key.length, 0);
        }
      }
    });
  }

  /// Stops [alias] mirroring anyone: every index it held is overwritten with
  /// random bytes at once, so its cryptor drops every frame.
  void unbindAlias(String alias) {
    _aliases.remove(alias);
    final held = _aliasIndices.remove(alias) ?? const <int>{};
    for (final index in held) {
      _junk([alias], index);
    }
  }

  @override
  void useSendKey(int index) {
    _chain(() async => sendIndex.value = index);
  }

  @override
  void clear() {
    final slots = [
      ..._installed,
      for (final entry in _aliasIndices.entries)
        for (final index in entry.value) (entry.key, index),
    ];
    _installed.clear();
    for (final key in _held.values) {
      key.fillRange(0, key.length, 0);
    }
    _held.clear();
    _aliases.clear();
    _aliasIndices.clear();
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
