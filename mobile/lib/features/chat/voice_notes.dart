import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_state.dart';
import '../../core/attachments.dart';
import '../../l10n/l10n.dart';
import '../../ui/format.dart';
import '../../ui/tokens.dart';
import 'attachment_views.dart' show newOpenedCopy;
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
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

/// [VoicePlayback] on the `audioplayers` plugin, playing a local file only.
class AudioPlayersPlayback implements VoicePlayback {
  final AudioPlayer _player = AudioPlayer();

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
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

/// Decrypts [entry] to a private temporary file for playback, in the same
/// cache folder other opened attachments use (purged at startup). The caller
/// deletes its folder when playback ends.
Future<File> decryptVoiceNote(
  AppState state,
  AttachmentEntry entry, {
  required String conversationId,
}) async {
  final cache = await getTemporaryDirectory();
  final root = Directory('${cache.path}${Platform.pathSeparator}veritra-open');
  final copy = await newOpenedCopy(root, entry.fileName);
  try {
    await state.saveAttachment(
      entry,
      copy.path,
      conversationId: conversationId,
    );
  } catch (_) {
    await deleteVoiceCopy(copy);
    rethrow;
  }
  return copy;
}

Future<void> deleteVoiceCopy(File copy) async {
  try {
    await copy.parent.delete(recursive: true);
  } on FileSystemException {
    // Purged at the next start instead.
  }
}

/// One voice note in a message bubble: play and pause, a progress bar and
/// the length. The file is downloaded and decrypted on the first play and
/// its plaintext copy is deleted when playback ends or the tile goes away.
class VoiceNoteTile extends StatefulWidget {
  const VoiceNoteTile({
    required this.entry,
    required this.load,
    this.playbackFactory = AudioPlayersPlayback.new,
    super.key,
  });

  final AttachmentEntry entry;

  /// Decrypts the voice note to a temporary file.
  final Future<File> Function() load;
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
  File? _copy;
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
    final copy = _copy;
    _copy = null;
    if (copy != null) await deleteVoiceCopy(copy);
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
      final copy = await widget.load();
      if (!mounted) {
        await deleteVoiceCopy(copy);
        return;
      }
      _copy = copy;
      final playback = widget.playbackFactory();
      _playback = playback;
      _subs.add(playback.states.listen(_onState));
      _subs.add(playback.positions.listen(_onPosition));
      _subs.add(playback.durations.listen(_onLength));
      await playback.play(copy.path);
    } catch (_) {
      await _release();
      _set(() => _failed = true);
    } finally {
      _set(() => _loading = false);
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

  /// Playback finished: the plaintext copy is not needed until the next
  /// play, which decrypts again.
  Future<void> _dropCopy() async {
    final copy = _copy;
    _copy = null;
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
    if (copy != null) await deleteVoiceCopy(copy);
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
