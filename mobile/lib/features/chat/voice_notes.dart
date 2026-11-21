import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/attachments.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import 'attachment_views.dart'
    show deleteOpenedCopy, newOpenedCopy, openedFilesDirectory;
import 'loopback_clip_server.dart';
import 'voice_recorder.dart';

/// "1:05" for a voice note position or length.
String formatVoiceDuration(Duration d) {
  final seconds = d.inSeconds;
  final two = (seconds % 60).toString().padLeft(2, '0');
  return '${seconds ~/ 60}:$two';
}

/// The bar above the composer while a voice note is being recorded: a
/// discard button, the running time and a stop button that puts the
/// recording on the tray.
class VoiceRecorderBar extends StatelessWidget {
  const VoiceRecorderBar({
    required this.controller,
    required this.onStop,
    super.key,
  });

  final VoiceRecorderController controller;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isRecording) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final time = formatVoiceDuration(controller.elapsed);
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            BoneSpacing.md,
            BoneSpacing.sm,
            BoneSpacing.md,
            0,
          ),
          child: Semantics(
            liveRegion: true,
            label: context.l10n.voiceNoteRecording(time),
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: context.l10n.voiceNoteDiscard,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: controller.cancel,
                ),
                Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
                const SizedBox(width: BoneSpacing.xs),
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(
                      context.l10n.voiceNoteRecording(time),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                IconButton.filled(
                  tooltip: context.l10n.voiceNoteStop,
                  icon: const Icon(Icons.stop),
                  onPressed: onStop,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum VoicePlaybackState { stopped, playing, paused }

/// The audio output, behind an interface so tests need no plugin.
abstract class VoicePlayback {
  Stream<VoicePlaybackState> get states;
  Stream<Duration> get positions;
  Stream<Duration> get durations;
  Future<void> play(String path);

  /// Whether [playBytes] works on this platform (D134).
  bool get supportsBytes;

  /// Plays a note held in memory, with no file (D134). It throws if it
  /// cannot, and the caller then plays from a temp file instead.
  Future<void> playBytes(Uint8List bytes, {String? mimeType});
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

/// Starts the loopback server that feeds a clip to a player that cannot play
/// bytes. A seam so tests need no socket.
typedef ClipServerStarter = Future<LoopbackClipServer> Function(
  Uint8List bytes, {
  String? mimeType,
});

/// [VoicePlayback] on the `audioplayers` plugin.
///
/// A note in memory plays through `BytesSource` on Android and Windows. The
/// plugin has no bytes source on iOS, macOS or Linux, so there the bytes are
/// served to it by a [LoopbackClipServer] (127.0.0.1, one unguessable path,
/// closed when playback stops). Nothing is written to disk either way.
class AudioPlayersPlayback implements VoicePlayback {
  AudioPlayersPlayback({
    AudioPlayer? player,
    TargetPlatform? platform,
    ClipServerStarter startServer = LoopbackClipServer.start,
  })  : _player = player ?? AudioPlayer(),
        _nativeBytes = _hasNativeBytes(platform ?? defaultTargetPlatform),
        _startServer = startServer;

  final AudioPlayer _player;
  final bool _nativeBytes;
  final ClipServerStarter _startServer;
  LoopbackClipServer? _server;

  static bool _hasNativeBytes(TargetPlatform platform) =>
      platform == TargetPlatform.android || platform == TargetPlatform.windows;

  @override
  Stream<VoicePlaybackState> get states =>
      _player.onPlayerStateChanged.map(_mapState);

  static VoicePlaybackState _mapState(PlayerState state) {
    if (state == PlayerState.playing) return VoicePlaybackState.playing;
    if (state == PlayerState.paused) return VoicePlaybackState.paused;
    return VoicePlaybackState.stopped;
  }

  @override
  Stream<Duration> get positions => _player.onPositionChanged;

  @override
  Stream<Duration> get durations => _player.onDurationChanged;

  @override
  Future<void> play(String path) => _player.play(DeviceFileSource(path));

  @override
  bool get supportsBytes => true;

  @override
  Future<void> playBytes(Uint8List bytes, {String? mimeType}) async {
    if (_nativeBytes) {
      await _player.play(BytesSource(bytes, mimeType: mimeType));
      return;
    }
    await _closeServer();
    final server = await _startServer(bytes, mimeType: mimeType);
    _server = server;
    await _player.play(UrlSource(server.url.toString(), mimeType: mimeType));
  }

  Future<void> _closeServer() async {
    final server = _server;
    _server = null;
    if (server != null) await server.close();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } finally {
      await _closeServer();
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _closeServer();
    } finally {
      await _player.dispose();
    }
  }
}

/// A decrypted voice note: the bytes of one that plays from memory, or a
/// private temp file for one that does not (D134).
class DecryptedVoice {
  DecryptedVoice.bytes(Uint8List this.bytes) : file = null;
  DecryptedVoice.file(File this.file) : bytes = null;

  final Uint8List? bytes;
  final File? file;

  /// Wipes the bytes or deletes the file's folder. Call once playback is
  /// finished with it.
  Future<void> discard() async {
    bytes?.fillRange(0, bytes!.length, 0);
    final copy = file;
    if (copy != null) await deleteOpenedCopy(copy);
  }
}

/// Decrypts [entry] for playback. With [inMemory] the note stays in memory
/// and no file is written; otherwise it goes to a private temporary file in
/// the same cache folder other opened attachments use (purged at startup and
/// by the hourly sweep). The caller calls [DecryptedVoice.discard] when
/// playback ends.
Future<DecryptedVoice> decryptVoiceNote(
  AppState state,
  AttachmentEntry entry, {
  required String conversationId,
  required bool inMemory,
}) async {
  if (inMemory) {
    return DecryptedVoice.bytes(
      await state.loadAttachment(entry, conversationId: conversationId),
    );
  }
  final root = await openedFilesDirectory();
  final copy = await newOpenedCopy(root, entry.fileName);
  try {
    await state.decryptAttachmentToFile(
      entry,
      copy.path,
      conversationId: conversationId,
    );
  } catch (_) {
    await deleteOpenedCopy(copy);
    rethrow;
  }
  return DecryptedVoice.file(copy);
}

/// One voice note in a message bubble: play and pause, a progress bar and
/// the length. The note is downloaded and decrypted on the first play. A
/// small one plays from memory where the platform can ([attachmentMemoryLimit]);
/// otherwise its plaintext copy is deleted when playback ends or the tile
/// goes away.
class VoiceNoteTile extends StatefulWidget {
  const VoiceNoteTile({
    required this.entry,
    required this.load,
    this.playbackFactory = AudioPlayersPlayback.new,
    super.key,
  });

  final AttachmentEntry entry;

  /// Decrypts the voice note, in memory when [inMemory] is true and to a
  /// temporary file otherwise.
  final Future<DecryptedVoice> Function(bool inMemory) load;
  final VoicePlayback Function() playbackFactory;

  @override
  State<VoiceNoteTile> createState() => _VoiceNoteTileState();
}

class _VoiceNoteTileState extends State<VoiceNoteTile> {
  /// Only one voice note plays at a time.
  static _VoiceNoteTileState? _active;

  VoicePlayback? _playback;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  DecryptedVoice? _voice;
  VoicePlaybackState _state = VoicePlaybackState.stopped;
  Duration _position = Duration.zero;
  Duration? _length;
  bool _loading = false;
  bool _failed = false;

  @override
  void dispose() {
    if (identical(_active, this)) _active = null;
    unawaited(_release());
    super.dispose();
  }

  Future<void> _release() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    final playback = _playback;
    _playback = null;
    if (playback != null) {
      try {
        await playback.stop();
      } catch (_) {}
      try {
        await playback.dispose();
      } catch (_) {}
    }
    final voice = _voice;
    _voice = null;
    if (voice != null) await voice.discard();
  }

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  Future<void> _toggle() async {
    if (_loading) return;
    final playback = _playback;
    if (playback != null && _state == VoicePlaybackState.playing) {
      await playback.pause();
      return;
    }
    if (playback != null && _state == VoicePlaybackState.paused) {
      await _stopOthers();
      await playback.resume();
      return;
    }
    await _start();
  }

  Future<void> _stopOthers() async {
    final other = _active;
    if (other != null && !identical(other, this)) await other._pause();
    _active = this;
  }

  Future<void> _pause() async {
    try {
      await _playback?.pause();
    } catch (_) {}
  }

  Future<void> _start() async {
    _set(() {
      _loading = true;
      _failed = false;
    });
    try {
      await _stopOthers();
      await _release();
      try {
        await _open(allowMemory: true);
      } catch (_) {
        // Playing from memory can fail where the platform refuses a loopback
        // server. Then the note plays from a private temp copy, as before.
        final wasMemory = _voice?.bytes != null;
        await _release();
        if (!wasMemory) rethrow;
        await _open(allowMemory: false);
      }
    } catch (_) {
      await _release();
      _set(() => _failed = true);
    } finally {
      _set(() => _loading = false);
    }
  }

  Future<void> _open({required bool allowMemory}) async {
    final playback = widget.playbackFactory();
    _playback = playback;
    final voice = await widget.load(
      allowMemory && playback.supportsBytes && widget.entry.opensFromMemory,
    );
    if (!mounted) {
      await voice.discard();
      return;
    }
    _voice = voice;
    _subs.add(playback.states.listen(_onState));
    _subs.add(playback.positions.listen(_onPosition));
    _subs.add(playback.durations.listen(_onLength));
    final bytes = voice.bytes;
    if (bytes != null) {
      await playback.playBytes(bytes, mimeType: widget.entry.mediaType);
    } else {
      await playback.play(voice.file!.path);
    }
  }

  void _onState(VoicePlaybackState next) {
    _set(() => _state = next);
    if (next == VoicePlaybackState.stopped) {
      _set(() => _position = Duration.zero);
      unawaited(_dropCopy());
    }
  }

  void _onPosition(Duration position) => _set(() => _position = position);

  void _onLength(Duration length) => _set(() => _length = length);

  /// Playback finished: the plaintext is not needed until the next play,
  /// which decrypts again.
  Future<void> _dropCopy() async {
    final voice = _voice;
    _voice = null;
    final playback = _playback;
    _playback = null;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    if (playback != null) {
      try {
        await playback.dispose();
      } catch (_) {}
    }
    if (voice != null) await voice.discard();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final size = formatFileSize(context, widget.entry.plaintextSize);
    final playing = _state == VoicePlaybackState.playing;
    final length = _length;
    final progress = length == null || length.inMilliseconds <= 0
        ? 0.0
        : (_position.inMilliseconds / length.inMilliseconds).clamp(0.0, 1.0);
    final String label;
    if (_failed) {
      label = l10n.voiceNotePlayFailed;
    } else if (length == null) {
      label = size;
    } else {
      final at = formatVoiceDuration(_position);
      label = '$at / ${formatVoiceDuration(length)}';
    }
    return Semantics(
      button: true,
      onTap: _toggle,
      label: '${l10n.voiceNoteSemantics(size)}, '
          '${playing ? l10n.voiceNotePause : l10n.voiceNotePlay}',
      excludeSemantics: true,
      child: InkWell(
        onTap: _toggle,
        borderRadius: BorderRadius.circular(BoneRadii.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox.square(
                dimension: 40,
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        playing ? Icons.pause_circle : Icons.play_circle,
                        size: 36,
                        color: scheme.primary,
                      ),
              ),
              const SizedBox(width: BoneSpacing.sm),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 140,
                      child: LinearProgressIndicator(value: progress),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _failed ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
