// Voice notes (B1): recording state, the file handed to the attachment tray,
// the media type a received note must have, and inline playback.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/features/chat/loopback_clip_server.dart';
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
  Uint8List? playedBytes;
  bool disposed = false;

  /// What [playBytes] throws, if anything.
  Object? bytesError;

  @override
  bool supportsBytes = false;

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
  Future<void> playBytes(Uint8List bytes, {String? mimeType}) async {
    final error = bytesError;
    if (error != null) throw error;
    playedBytes = bytes;
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

class _RealHttp extends HttpOverrides {}

/// Only what [AudioPlayersPlayback.playBytes] touches; any other call fails.
class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final List<Source> played = <Source>[];
  bool throwOnPlay = false;
  bool stopped = false;
  bool disposed = false;

  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    if (throwOnPlay) throw StateError('player refused');
    played.add(source);
  }

  @override
  Future<void> stop() async => stopped = true;

  @override
  Future<void> dispose() async => disposed = true;
}

AttachmentEntry _voiceEntry({
  String type = 'audio/mp4',
  int size = 4096,
}) =>
    AttachmentEntry(
      id: 'a1',
      fileName: 'voice-20261024-090507.m4a',
      mediaType: type,
      plaintextSize: size,
      ciphertextSize: size + 104,
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

  test(
    'closing the screen mid-recording cancels and releases the microphone',
    () async {
      final recorder = controller();
      await recorder.start();
      recorder.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(backend.cancelled, isTrue);
      expect(backend.disposed, isTrue);
      expect(File('${dir.path}/r.m4a').existsSync(), isFalse);
    },
  );

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

  testWidgets('tapping a voice note decrypts, plays and cleans up', (
    tester,
  ) async {
    final playback = _FakePlayback();
    final copy = File('${dir.path}/copy/voice.m4a')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoiceNoteTile(
            entry: _voiceEntry(),
            load: (inMemory) async {
              loads++;
              expect(
                inMemory,
                isFalse,
                reason: 'this player cannot play from bytes',
              );
              return DecryptedVoice.file(copy);
            },
            playbackFactory: () => playback,
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.play_circle), findsOneWidget);

    await tester.tap(find.byType(VoiceNoteTile));
    await tester.pump();
    await tester.pump();
    expect(loads, 1);
    expect(playback.played, copy.path);
    expect(find.byIcon(Icons.pause_circle), findsOneWidget);

    playback.finish();
    await tester.pump();
    // The delete is real file I/O whose continuation runs in the fake-async
    // zone, so alternate real waiting with pumps until it has finished.
    for (var i = 0; i < 100 && copy.parent.existsSync(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.byIcon(Icons.play_circle), findsOneWidget);
    expect(
      copy.parent.existsSync(),
      isFalse,
      reason: 'the plaintext copy goes when playback ends',
    );
    expect(playback.disposed, isTrue);
  });

  testWidgets('a small note plays from memory and no file is made',
      (tester) async {
    final playback = _FakePlayback()..supportsBytes = true;
    final audio = Uint8List.fromList(<int>[9, 8, 7]);
    final asked = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceNoteTile(
          entry: _voiceEntry(),
          load: (inMemory) async {
            asked.add(inMemory);
            return DecryptedVoice.bytes(audio);
          },
          playbackFactory: () => playback,
        ),
      ),
    ));
    await tester.tap(find.byType(VoiceNoteTile));
    await tester.pump();
    await tester.pump();

    expect(asked, <bool>[true]);
    expect(playback.playedBytes, audio);
    expect(playback.played, isNull, reason: 'nothing was played from a path');

    // The bytes are wiped once playback ends.
    playback.finish();
    await tester.pump();
    for (var i = 0; i < 100 && !audio.every((b) => b == 0); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(audio, <int>[0, 0, 0]);
  });

  testWidgets('a big note plays from a temp copy even where bytes play',
      (tester) async {
    final playback = _FakePlayback()..supportsBytes = true;
    final copy = File('${dir.path}/big/voice.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    final asked = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceNoteTile(
          entry:
              _voiceEntry(type: 'audio/wav', size: attachmentMemoryLimit + 1),
          load: (inMemory) async {
            asked.add(inMemory);
            return DecryptedVoice.file(copy);
          },
          playbackFactory: () => playback,
        ),
      ),
    ));
    await tester.tap(find.byType(VoiceNoteTile));
    await tester.pump();
    await tester.pump();
    expect(asked, <bool>[false]);
    expect(playback.played, copy.path);

    // Closing the tile deletes the copy at once.
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 100 && copy.parent.existsSync(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(copy.parent.existsSync(), isFalse);
  });

  group('AudioPlayersPlayback.playBytes', () {
    final audio = Uint8List.fromList(<int>[1, 2, 3, 4]);

    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.windows,
    ]) {
      test('plays a BytesSource on $platform, with no server', () async {
        final player = _FakeAudioPlayer();
        final playback = AudioPlayersPlayback(
          player: player,
          platform: platform,
          startServer: (bytes, {mimeType}) async =>
              throw StateError('no server expected'),
        );
        expect(playback.supportsBytes, isTrue);
        await playback.playBytes(audio, mimeType: 'audio/mp4');
        final source = player.played.single as BytesSource;
        expect(source.bytes, audio);
        expect(source.mimeType, 'audio/mp4');
      });
    }

    for (final platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      test('plays a loopback UrlSource on $platform and closes it on stop',
          () async {
        final player = _FakeAudioPlayer();
        final servers = <LoopbackClipServer>[];
        final playback = AudioPlayersPlayback(
          player: player,
          platform: platform,
          startServer: (bytes, {mimeType}) async {
            final server =
                await LoopbackClipServer.start(bytes, mimeType: mimeType);
            servers.add(server);
            return server;
          },
        );
        addTearDown(() async {
          for (final server in servers) {
            await server.close();
          }
        });
        expect(playback.supportsBytes, isTrue);
        await playback.playBytes(audio, mimeType: 'audio/mp4');

        final source = player.played.single as UrlSource;
        expect(source.mimeType, 'audio/mp4');
        final url = Uri.parse(source.url);
        expect(url.host, '127.0.0.1');
        expect(url.toString(), servers.single.url.toString());

        // The widget test binding mocks HttpClient; this needs a real one.
        final body = await HttpOverrides.runWithHttpOverrides(() async {
          final client = HttpClient();
          try {
            final response = await (await client.getUrl(url)).close();
            final data = <int>[];
            await for (final chunk in response) {
              data.addAll(chunk);
            }
            return data;
          } finally {
            client.close(force: true);
          }
        }, _RealHttp());
        expect(body, audio);

        await playback.stop();
        expect(player.stopped, isTrue);
        expect(servers.single.isClosed, isTrue);
      });
    }

    test('a second note replaces the first server, dispose closes the last',
        () async {
      final player = _FakeAudioPlayer();
      final servers = <LoopbackClipServer>[];
      final playback = AudioPlayersPlayback(
        player: player,
        platform: TargetPlatform.linux,
        startServer: (bytes, {mimeType}) async {
          final server = await LoopbackClipServer.start(bytes);
          servers.add(server);
          return server;
        },
      );
      await playback.playBytes(audio);
      await playback.playBytes(audio);
      expect(servers[0].isClosed, isTrue);
      expect(servers[1].isClosed, isFalse);
      await playback.dispose();
      expect(servers[1].isClosed, isTrue);
      expect(player.disposed, isTrue);
    });

    test('a server that cannot bind throws, so the caller can fall back',
        () async {
      final player = _FakeAudioPlayer();
      final playback = AudioPlayersPlayback(
        player: player,
        platform: TargetPlatform.macOS,
        startServer: (bytes, {mimeType}) async =>
            throw const SocketException('operation not permitted'),
      );
      await expectLater(
        playback.playBytes(audio),
        throwsA(
          isA<LoopbackPlaybackException>().having(
            (e) => e.cause,
            'cause',
            isA<SocketException>(),
          ),
        ),
      );
      expect(player.played, isEmpty);
    });

    test('a player that refuses the URL closes the server at once', () async {
      final player = _FakeAudioPlayer()..throwOnPlay = true;
      late LoopbackClipServer server;
      final playback = AudioPlayersPlayback(
        player: player,
        platform: TargetPlatform.iOS,
        startServer: (bytes, {mimeType}) async =>
            server = await LoopbackClipServer.start(bytes),
      );
      await expectLater(
        playback.playBytes(audio),
        throwsA(isA<LoopbackPlaybackException>()),
      );
      expect(server.isClosed, isTrue);
      // Its message never carries the cause, which names the token URL.
      expect(
        const LoopbackPlaybackException('http://127.0.0.1:1/secret').toString(),
        isNot(contains('secret')),
      );
    });

    test('a native bytes failure is not a loopback failure (no file retry)',
        () async {
      final player = _FakeAudioPlayer()..throwOnPlay = true;
      final playback = AudioPlayersPlayback(
        player: player,
        platform: TargetPlatform.android,
      );
      await expectLater(playback.playBytes(audio), throwsStateError);
    });

    for (final (name, end) in <(String, Future<void> Function(VoicePlayback))>[
      ('stop', (p) => p.stop()),
      ('dispose', (p) => p.dispose()),
    ]) {
      test('$name while the server is still binding closes it when it binds',
          () async {
        final player = _FakeAudioPlayer();
        final gate = Completer<void>();
        LoopbackClipServer? server;
        final playback = AudioPlayersPlayback(
          player: player,
          platform: TargetPlatform.linux,
          startServer: (bytes, {mimeType}) async {
            final started = await LoopbackClipServer.start(bytes);
            server = started;
            await gate.future;
            return started;
          },
        );
        addTearDown(() async => server?.close());
        final playing = playback.playBytes(audio);
        // Let the real bind finish, then stop before the seam returns.
        while (server == null) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await end(playback);
        gate.complete();
        // Not a LoopbackPlaybackException: a stopped note is not retried
        // from a file.
        await expectLater(playing, throwsStateError);
        expect(server!.isClosed, isTrue);
        expect(player.played, isEmpty);
      });
    }

    test('the app going to the background stops and closes the server',
        () async {
      final binding = TestWidgetsFlutterBinding.instance;
      final player = _FakeAudioPlayer();
      late LoopbackClipServer server;
      final playback = AudioPlayersPlayback(
        player: player,
        platform: TargetPlatform.iOS,
        startServer: (bytes, {mimeType}) async =>
            server = await LoopbackClipServer.start(bytes),
      );
      await playback.playBytes(audio);
      // A minimised desktop window (hidden) keeps playing.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await pumpEventQueue();
      expect(server.isClosed, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(player.stopped, isTrue);
      expect(server.isClosed, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await playback.dispose();
    });
  });

  testWidgets('a note whose memory playback fails plays from a temp copy',
      (tester) async {
    final memory = _FakePlayback()
      ..supportsBytes = true
      ..bytesError = const LoopbackPlaybackException(
        SocketException('operation not permitted'),
      );
    final filePlayback = _FakePlayback();
    final players = <_FakePlayback>[memory, filePlayback];
    final copy = File('${dir.path}/fallback/voice.m4a')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    final audio = Uint8List.fromList(<int>[9, 8, 7]);
    final asked = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceNoteTile(
          entry: _voiceEntry(),
          load: (inMemory) async {
            asked.add(inMemory);
            return inMemory
                ? DecryptedVoice.bytes(audio)
                : DecryptedVoice.file(copy);
          },
          playbackFactory: () => players.removeAt(0),
        ),
      ),
    ));
    await tester.tap(find.byType(VoiceNoteTile));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(asked, <bool>[true, false]);
    expect(audio, <int>[0, 0, 0], reason: 'the failed attempt is wiped');
    expect(memory.disposed, isTrue);
    expect(filePlayback.played, copy.path);
    expect(
      find.text('The voice note could not be played.'),
      findsNothing,
    );
  });

  testWidgets('a memory failure that is not the loopback path writes no file',
      (tester) async {
    final memory = _FakePlayback()
      ..supportsBytes = true
      ..bytesError = StateError('codec');
    final audio = Uint8List.fromList(<int>[9, 8, 7]);
    final asked = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VoiceNoteTile(
          entry: _voiceEntry(),
          load: (inMemory) async {
            asked.add(inMemory);
            return DecryptedVoice.bytes(audio);
          },
          playbackFactory: () => memory,
        ),
      ),
    ));
    await tester.tap(find.byType(VoiceNoteTile));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(asked, <bool>[true]);
    expect(audio, <int>[0, 0, 0]);
    expect(memory.disposed, isTrue);
    expect(find.text('The voice note could not be played.'), findsOneWidget);
  });

  testWidgets('a note that cannot be loaded says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoiceNoteTile(
            entry: _voiceEntry(),
            load: (_) async => throw const FileSystemException('gone'),
            playbackFactory: _FakePlayback.new,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(VoiceNoteTile));
    await tester.pump();
    await tester.pump();
    expect(find.text('The voice note could not be played.'), findsOneWidget);
  });

  test('the audio plugin never prints sources (they hold the secret path)', () {
    AudioLogger.logLevel = AudioLogLevel.info;
    AudioPlayersPlayback(
      player: _FakeAudioPlayer(),
      platform: TargetPlatform.linux,
    );
    expect(AudioLogger.logLevel, AudioLogLevel.none);
  });
}
