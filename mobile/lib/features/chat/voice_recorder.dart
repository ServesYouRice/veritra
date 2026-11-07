import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// The longest voice note. Recording stops by itself here, so a forgotten
/// recording stays well under the server's attachment cap.
const Duration maxVoiceNoteDuration = Duration(minutes: 10);

/// What a recording is stored as.
class VoiceFormat {
  const VoiceFormat(this.extension, this.mediaType);

  final String extension;
  final String mediaType;

  /// AAC in an MP4 container: plays on every platform the app targets.
  static const VoiceFormat aac = VoiceFormat('m4a', 'audio/mp4');

  /// Uncompressed fallback where the platform has no AAC encoder.
  static const VoiceFormat wav = VoiceFormat('wav', 'audio/wav');
}

/// What a voice note file is called: `voice-20261024-090507.m4a`.
String voiceNoteName(DateTime now, VoiceFormat format) {
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${now.year}${two(now.month)}${two(now.day)}';
  final time = '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return 'voice-$date-$time.${format.extension}';
}

/// The microphone, behind an interface so tests need no plugin.
abstract class VoiceRecorderBackend {
  Future<bool> hasPermission();

  /// The format this platform can record.
  Future<VoiceFormat> chooseFormat();

  Future<void> start(String path, VoiceFormat format);

  /// Stops and returns the file path, or null when nothing was recorded.
  Future<String?> stop();

  /// Stops and deletes the file.
  Future<void> cancel();

  Future<void> dispose();
}

/// [VoiceRecorderBackend] on the `record` plugin. Audio goes to a file in
/// the app's private cache only; nothing is streamed or sent anywhere.
class RecordPluginBackend implements VoiceRecorderBackend {
  // Created on first use: building the recorder talks to the plugin.
  AudioRecorder? _created;
  AudioRecorder get _recorder => _created ??= AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<VoiceFormat> chooseFormat() async =>
      await _recorder.isEncoderSupported(AudioEncoder.aacLc)
          ? VoiceFormat.aac
          : VoiceFormat.wav;

  @override
  Future<void> start(String path, VoiceFormat format) => _recorder.start(
        RecordConfig(
          encoder:
              format == VoiceFormat.aac ? AudioEncoder.aacLc : AudioEncoder.wav,
          // Speech: mono at 64 kbit/s keeps a minute near 480 kB.
          numChannels: 1,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: path,
      );

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() async => _created?.dispose();
}

enum VoiceRecorderState { idle, recording }

/// Why a recording did not start.
enum VoiceStartResult { started, permissionDenied, failed }

/// Records one voice note at a time and hands back the file for the
/// composer's tray, which encrypts and uploads it like any attachment.
class VoiceRecorderController extends ChangeNotifier {
  VoiceRecorderController({
    required this.backend,
    required this.newFile,
    this.maxDuration = maxVoiceNoteDuration,
    this.onAutoStop,
  });

  final VoiceRecorderBackend backend;

  /// Makes the empty file path a recording is written to.
  final Future<String> Function(VoiceFormat format) newFile;
  final Duration maxDuration;

  /// Called with the finished recording when [maxDuration] is reached.
  final void Function(XFile file)? onAutoStop;

  VoiceRecorderState _state = VoiceRecorderState.idle;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  VoiceFormat? _format;
  String? _path;
  bool _busy = false;
  bool _disposed = false;

  VoiceRecorderState get state => _state;
  bool get isRecording => _state == VoiceRecorderState.recording;
  Duration get elapsed => _elapsed;

  Future<VoiceStartResult> start() async {
    if (_busy || isRecording) return VoiceStartResult.failed;
    _busy = true;
    try {
      if (!await backend.hasPermission()) {
        return VoiceStartResult.permissionDenied;
      }
      final format = await backend.chooseFormat();
      final path = await newFile(format);
      await backend.start(path, format);
      _format = format;
      _path = path;
      _elapsed = Duration.zero;
      _state = VoiceRecorderState.recording;
      _ticker = Timer.periodic(const Duration(seconds: 1), _tick);
      _notify();
      return VoiceStartResult.started;
    } catch (_) {
      await _deleteQuietly(_path);
      _path = null;
      return VoiceStartResult.failed;
    } finally {
      _busy = false;
    }
  }

  void _tick(Timer _) {
    _elapsed += const Duration(seconds: 1);
    if (_elapsed >= maxDuration) {
      unawaited(_autoStop());
      return;
    }
    _notify();
  }

  Future<void> _autoStop() async {
    final file = await finish();
    if (file != null && !_disposed) onAutoStop?.call(file);
  }

  /// Stops and returns the recording, or null when there is none or it is
  /// empty.
  Future<XFile?> finish() async {
    if (!isRecording) return null;
    final format = _format!;
    final expected = _path;
    _end();
    String? path;
    try {
      path = await backend.stop();
    } catch (_) {
      path = null;
    }
    path ??= expected;
    if (path == null) return null;
    final file = File(path);
    try {
      if (!await file.exists() || await file.length() == 0) {
        await _deleteQuietly(path);
        return null;
      }
    } on FileSystemException {
      return null;
    }
    // XFile ignores `name` for files on disk (its name is the path's last
    // segment), so the recording itself is renamed to the voice note name.
    final name = voiceNoteName(DateTime.now(), format);
    var sentPath = path;
    try {
      final slash = sentPath.lastIndexOf(Platform.pathSeparator);
      final renamed = '${sentPath.substring(0, slash + 1)}$name';
      await file.rename(renamed);
      sentPath = renamed;
    } on FileSystemException {
      // Keep the recorder's own name; the note still sends.
    }
    return XFile(sentPath, name: name, mimeType: format.mediaType);
  }

  /// Stops and throws the recording away.
  Future<void> cancel() async {
    if (!isRecording) return;
    final path = _path;
    _end();
    try {
      await backend.cancel();
    } catch (_) {
      // The file is deleted below either way.
    }
    await _deleteQuietly(path);
  }

  void _end() {
    _ticker?.cancel();
    _ticker = null;
    _state = VoiceRecorderState.idle;
    _path = null;
    _notify();
  }

  Future<void> _deleteQuietly(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The cache is purged at the next start.
    }
  }

  Future<void> _teardown(bool recording, String? path) async {
    if (recording) {
      try {
        await backend.cancel();
      } catch (_) {
        // The file is deleted below either way.
      }
      await _deleteQuietly(path);
    }
    try {
      await backend.dispose();
    } catch (_) {
      // Nothing left to release.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final recording = isRecording;
    final path = _path;
    _ticker?.cancel();
    _ticker = null;
    _state = VoiceRecorderState.idle;
    unawaited(_teardown(recording, path));
    super.dispose();
  }
}
