// The image viewer decodes peer-supplied bytes. It reads the declared size
// first, refuses a decompression bomb and decodes large images smaller
// (TASK-065).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/features/chat/attachment_views.dart';
import 'package:private_messenger/l10n/l10n.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

class _NoSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() async {}
}

class _ImageState extends AppState {
  _ImageState(this.bytes)
      : super(
          apiClientFactory: (_) => ApiClient(baseUrl: 'https://localhost'),
          cryptoService: TestOnlyCryptoService(),
          localStore: MemoryLocalStore(),
          syncServiceFactory: (_, __) => _NoSync(),
        );

  final Uint8List bytes;

  /// How often the image was decrypted to memory and to a file.
  int memoryLoads = 0;
  int fileDecrypts = 0;

  @override
  Future<Uint8List> loadAttachment(
    AttachmentEntry entry, {
    required String conversationId,
  }) async {
    memoryLoads++;
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> decryptAttachmentToFile(
    AttachmentEntry entry,
    String destinationPath, {
    required String conversationId,
  }) async {
    fileDecrypts++;
    await File(destinationPath).writeAsBytes(bytes);
  }
}

const _entry = AttachmentEntry(
  id: 'att_1',
  fileName: 'photo.png',
  mediaType: 'image/png',
  plaintextSize: 100,
  ciphertextSize: 130,
  manifest: <String, Object?>{},
);

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

/// A PNG whose header declares [width] x [height] pixels and whose data is a
/// few bytes: all a decompression bomb needs.
Uint8List _declaredPng(int width, int height) {
  final out = BytesBuilder();
  out.add(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  void chunk(String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    out.add(typeBytes);
    out.add(data);
    out.add(
      (ByteData(4)..setUint32(0, _crc32(<int>[...typeBytes, ...data])))
          .buffer
          .asUint8List(),
    );
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6); // RGBA
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', <int>[0x78, 0x9c, 0x63, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]);
  chunk('IEND', <int>[]);
  return out.takeBytes();
}

/// A real, fully valid PNG of [width] x [height] pixels.
Future<Uint8List> _realPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff336699),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<_ImageState> _show(
  WidgetTester tester,
  Uint8List bytes, {
  AttachmentEntry entry = _entry,
}) async {
  final state = _ImageState(bytes);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AttachmentImageScreen(
        state: state,
        entry: entry,
        conversationId: 'conv_1',
      ),
    ),
  );
  // The size probe and the decode are real engine work.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
  // A copy on disk takes several real I/O steps, one per pump.
  for (var i = 0;
      i < 40 && tester.any(find.byType(CircularProgressIndicator));
      i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  return state;
}

/// Points the path provider at a fresh cache folder and returns it.
Directory _mockCache(WidgetTester tester) {
  final cache = Directory.systemTemp.createTempSync('attachment_image_cache_');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (_) async => cache.path);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    cache.deleteSync(recursive: true);
  });
  return cache;
}

/// Every file under [directory].
List<String> _filesUnder(Directory directory) => <String>[
      for (final item in directory.listSync(recursive: true))
        if (item is File) item.path,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the declared size is read without decoding', () async {
    final size = await readImageSize(_declaredPng(30000, 30000));
    expect(size, isNotNull);
    expect(size!.width, 30000);
    expect(size.height, 30000);
    expect(await readImageSize(Uint8List.fromList(<int>[1, 2, 3])), isNull);
  });

  test('large images are decoded smaller, in proportion', () {
    expect(viewerDecodeSize(800, 600), (width: null, height: null));
    expect(viewerDecodeSize(maxViewerDecodeSide, 10), (
      width: null,
      height: null,
    ));
    expect(viewerDecodeSize(8000, 6000), (
      width: maxViewerDecodeSide,
      height: null,
    ));
    expect(viewerDecodeSize(6000, 8000), (
      width: null,
      height: maxViewerDecodeSide,
    ));
  });

  testWidgets('an image that declares too many pixels is never decoded', (
    tester,
  ) async {
    await _show(tester, _declaredPng(30000, 30000));
    expect(find.text('This image cannot be shown.'), findsOneWidget);
    expect(
      find.byType(Image),
      findsNothing,
      reason: 'no Image means nothing asked the engine to decode it',
    );
  });

  testWidgets('bytes that are not an image are not decoded either', (
    tester,
  ) async {
    await _show(tester, Uint8List.fromList(List<int>.filled(64, 7)));
    expect(find.text('This image cannot be shown.'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a normal image is shown', (tester) async {
    final bytes = (await tester.runAsync(() => _realPng(64, 48)))!;
    await _show(tester, bytes);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('This image cannot be shown.'), findsNothing);
    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(
      provider,
      isNot(isA<ResizeImage>()),
      reason: 'a small image needs no resizing',
    );
  });

  testWidgets('a wide image is decoded no wider than the viewer bound', (
    tester,
  ) async {
    final bytes = (await tester.runAsync(() => _realPng(5000, 20)))!;
    await _show(tester, bytes);
    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(provider, isA<ResizeImage>());
    expect((provider as ResizeImage).width, maxViewerDecodeSide);
    expect(provider.height, isNull);
  });

  testWidgets('a small image opens from memory and writes no file',
      (tester) async {
    final cache = _mockCache(tester);
    final bytes = (await tester.runAsync(() => _realPng(64, 48)))!;
    final state = await _show(tester, bytes);

    expect(find.byType(Image), findsOneWidget);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<MemoryImage>());
    expect(state.memoryLoads, 1);
    expect(state.fileDecrypts, 0, reason: 'no plaintext copy is made');
    expect(_filesUnder(cache), isEmpty);
    expect(Directory('${cache.path}/veritra-open').existsSync(), isFalse);
  });

  testWidgets('a big image uses a temp copy that goes when the viewer closes',
      (tester) async {
    final cache = _mockCache(tester);
    final bytes = (await tester.runAsync(() => _realPng(64, 48)))!;
    final big = AttachmentEntry(
      id: 'att_2',
      fileName: 'big.png',
      mediaType: 'image/png',
      plaintextSize: attachmentMemoryLimit + 1,
      ciphertextSize: attachmentMemoryLimit + 100,
      manifest: const <String, Object?>{},
    );
    expect(big.opensFromMemory, isFalse);
    final state = await _show(tester, bytes, entry: big);

    expect(state.memoryLoads, 0);
    expect(state.fileDecrypts, 1);
    expect(tester.widget<Image>(find.byType(Image)).image, isA<FileImage>());
    expect(_filesUnder(cache), hasLength(1),
        reason: 'the one temp copy, while the viewer is open');

    // Close the viewer.
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 100 && _filesUnder(cache).isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(_filesUnder(cache), isEmpty);
    // Its folder is gone too: nothing is left in this slot's cache folder.
    final slot = Directory('${cache.path}/veritra-open/primary');
    expect(slot.listSync(), isEmpty);
  });

  test(
      'the memory limit covers a voice note and a phone photo, not a 48 MP one',
      () {
    AttachmentEntry sized(int bytes) => AttachmentEntry(
          id: 'a',
          fileName: 'f',
          mediaType: 'image/jpeg',
          plaintextSize: bytes,
          ciphertextSize: bytes + 100,
          manifest: const <String, Object?>{},
        );
    expect(sized(4800 * 1000).opensFromMemory, isTrue);
    expect(sized(6 * 1024 * 1024).opensFromMemory, isTrue);
    expect(sized(attachmentMemoryLimit).opensFromMemory, isTrue);
    expect(sized(attachmentMemoryLimit + 1).opensFromMemory, isFalse);
  });
}
