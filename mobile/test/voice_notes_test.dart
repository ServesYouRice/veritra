// Voice notes (B1): recording state, the file handed to the attachment tray,
// the media type a received note must have, and inline playback.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/features/chat/voice_notes.dart';
import 'package:private_messenger/features/chat/voice_recorder.dart';

class _FakeBackend implements VoiceRecorderBackend {
  bool permission = true;
  bool throwOnStart = false;
  bool writeAudio = true;
  String? path;
  bool cancelled = false;
  bool disposed = false;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<VoiceFormat> chooseFormat() async => VoiceFormat.aac;

  @override
  Future<void> start(String path, VoiceFormat format) async {
    if (throwOnStart) throw StateError('no microphone');
    this.path = path;
    if (writeAudio) File(path).writeAsBytesSync(<int>[1, 2, 3]);
  }

  @override
  Future<String?> stop() async => path;

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakePlayback implements VoicePlayback {
  final _states = StreamController<VoicePlaybackState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  String? played;
  bool disposed = false;

  @override
  Stream<VoicePlaybackState> get states => _states.stream;

  @override
  Stream<Duration> get positions => _positions.stream;

  @override
  Stream<Duration> get durations => _durations.stream;

  @override
  Future<void> play(String path) async {
    played = path;
    _states.add(VoicePlaybackState.playing);
    _durations.add(const Duration(seconds: 65));
  }

  @override
  Future<void> pause() async => _states.add(VoicePlaybackState.paused);

  @override
  Future<void> resume() async => _states.add(VoicePlaybackState.playing);

  @override
  Future<void> stop() async {}

  void finish() => _states.add(VoicePlaybackState.stopped);

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

AttachmentEntry _voiceEntry({String type = 'audio/mp4'}) => AttachmentEntry(
      id: 'a1',
      fileName: 'voice-20261024-090507.m4a',
      mediaType: type,
      plaintextSize: 4096,
      ciphertextSize: 4200,
      manifest: const <String, Object?>{},
    );

void main() {
  late Directory dir;
  late _FakeBackend backend;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voice_notes');
    backend = _FakeBackend();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  VoiceRecorderController controller({
    Duration max = maxVoiceNoteDuration,
    void Function(dynamic file)? onAutoStop,
  }) =>
      VoiceRecorderController(
        backend: backend,
        maxDuration: max,
        newFile: (format) async => '${dir.path}/r.${format.extension}',
        onAutoStop: onAutoStop,
      );

  test('a recording becomes a named audio/mp4 file for the tray', () async {
    final recorder = controller();
    expect(await recorder.start(), VoiceStartResult.started);
    expect(recorder.isRecording, isTrue);
    final file = await recorder.finish();
    expect(recorder.isRecording, isFalse);
    expect(file, isNotNull);
    expect(file!.mimeType, 'audio/mp4');
    expect(file.name, matches(RegExp(r'^voice-\d{8}-\d{6}\.m4a$')));
    expect(File(file.path).existsSync(), isTrue);
    recorder.dispose();
  });

  test('a denied microphone starts nothing and leaves no file', () async {
    backend.permission = false;
    final recorder = controller();
    expect(await recorder.start(), VoiceStartResult.permissionDenied);
    expect(recorder.isRecording, isFalse);
    expect(dir.listSync(), isEmpty);
    recorder.dispose();
  });

  test('a recorder that fails to start reports it', () async {
    backend.throwOnStart = true;
    final recorder = controller();
    expect(await recorder.start(), VoiceStartResult.failed);
    expect(recorder.isRecording, isFalse);
    recorder.dispose();
  });

  test('discarding deletes the recording', () async {
    final recorder = controller();
    await recorder.start();
    await recorder.cancel();
    expect(backend.cancelled, isTrue);
    expect(recorder.isRecording, isFalse);
    expect(File('${dir.path}/r.m4a').existsSync(), isFalse);
    recorder.dispose();
  });

  test('an empty recording is dropped, not sent', () async {
    backend.writeAudio = false;
    File('${dir.path}/r.m4a').writeAsBytesSync(<int>[]);
    final recorder = controller();
    await recorder.start();
    expect(await recorder.finish(), isNull);
    expect(File('${dir.path}/r.m4a').existsSync(), isFalse);
    recorder.dispose();
  });

  test('recording stops by itself at the limit', () async {
    final done = Completer<void>();
    final recorder = controller(
      max: const Duration(seconds: 1),
      onAutoStop: (_) => done.complete(),
    );
    await recorder.start();
    await done.future.timeout(const Duration(seconds: 5));
    expect(recorder.isRecording, isFalse);
    recorder.dispose();
  });

  test('closing the screen mid-recording cancels and releases the microphone',
      () async {
    final recorder = controller();
    await recorder.start();
    recorder.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(backend.cancelled, isTrue);
    expect(backend.disposed, isTrue);
    expect(File('${dir.path}/r.m4a').existsSync(), isFalse);
  });

  test('only known audio types play inline', () {
    expect(_voiceEntry().isVoiceNote, isTrue);
    expect(_voiceEntry(type: 'audio/x-unknown').isVoiceNote, isFalse);
    expect(_voiceEntry(type: 'application/pdf').isVoiceNote, isFalse);
    expect(attachmentMediaType('a.m4a', null), 'audio/mp4');
    expect(attachmentMediaType('a.WAV', null), 'audio/wav');
  });

  test('the length reads as minutes and seconds', () {
    expect(formatVoiceDuration(const Duration(seconds: 65)), '1:05');
    expect(formatVoiceDuration(Duration.zero), '0:00');
  });

  testWidgets('tapping a voice note decrypts, plays and cleans up',
      (tester) async {
    final playback = _FakePlayback();
    final copy = File('${dir.path}/copy/voice.m4a')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceNoteTile(
          entry: _voiceEntry(),
          load: () async {
            loads++;
            return copy;
          },
          playbackFactory: () => playback,
        ),
      ),
    ));
    expect(find.byIcon(Icons.play_circle), findsOneWidget);

    await tester.tap(find.byType(VoiceNoteTile));
    await tester.pump();
    await tester.pump();
    expect(loads, 1);
    expect(playback.played, copy.path);
    expect(find.byIcon(Icons.pause_circle), findsOneWidget);

    playback.finish();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(find.byIcon(Icons.play_circle), findsOneWidget);
    expect(copy.parent.existsSync(), isFalse,
        reason: 'the plaintext copy goes when playback ends');
    expect(playback.disposed, isTrue);
  });

  testWidgets('a note that cannot be loaded says so', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceNoteTile(
          entry: _voiceEntry(),
          load: () async => throw const FileSystemException('gone'),
          playbackFactory: _FakePlayback.new,
        ),
      ),
    ));
    await tester.tap(find.byType(VoiceNoteTile));
    await tester.pump();
    await tester.pump();
    expect(find.text('The voice note could not be played.'), findsOneWidget);
  });
}
