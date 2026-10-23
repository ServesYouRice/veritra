// Card I38: the client streams bounded export pages into one local file. It
// never prints or logs the payload, keeps none of it in shared state, and a
// failed export leaves no partial file behind.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _sentinel = 'EXPORT_SENTINEL_ciphertext_7c1d';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('account_export_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => tempDir.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<(String?, List<String>, AppState)> runExport(_ExportApi api) async {
    final printed = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint =
        (String? message, {int? wrapWidth}) => printed.add(message ?? '');
    try {
      return await runZoned(
        () async {
          final state = AppState(
            apiClientFactory: (_) => api,
            cryptoService: TestOnlyCryptoService(),
            localStore: MemoryLocalStore(),
            syncServiceFactory: (_, __) => _QuietSync(),
          )
            ..api = api
            ..session = const Session(
              baseUrl: 'https://localhost:8080',
              token: 'owner-token',
              accountId: 'acct_owner',
              deviceId: 'dev_owner',
            );
          final path = await state.exportAccount();
          return (path, printed, state);
        },
        zoneSpecification: ZoneSpecification(
          print: (_, __, ___, line) => printed.add(line),
        ),
      );
    } finally {
      debugPrint = originalDebugPrint;
    }
  }

  test('pages stream to one file and nothing is printed', () async {
    final api = _ExportApi();
    final (path, printed, state) = await runExport(api);

    expect(path, isNotNull);
    expect(api.befores, <String?>[null, 'msg_page_1']);
    final file = File(path!);
    final decoded = jsonDecode(await file.readAsString()) as Map;
    expect(decoded['manifest_version'], 'v2');
    expect(decoded['pages'], hasLength(2));
    expect(await File('$path.part').exists(), isFalse);
    expect(printed.join('\n'), isNot(contains(_sentinel)));
    expect(state.error, isNull);
    state.dispose();
  });

  test('a failed export leaves no file and no payload in the error', () async {
    final api = _ExportApi()..failSecondPage = true;
    final (path, printed, state) = await runExport(api);

    expect(path, isNull);
    final leftovers = tempDir
        .listSync()
        .where((entry) => entry.path.contains('veritra-account-export'));
    expect(leftovers, isEmpty);
    expect(state.error, isNotNull);
    expect(state.error, isNot(contains(_sentinel)));
    expect(printed.join('\n'), isNot(contains(_sentinel)));
    state.dispose();
  });
}

class _ExportApi extends ApiClient {
  _ExportApi() : super(baseUrl: 'https://localhost:8080');

  bool failSecondPage = false;
  final List<String?> befores = <String?>[];

  @override
  Future<Map<String, Object?>> exportAccountPage(
    String token, {
    int limit = 250,
    String? before,
  }) async {
    befores.add(before);
    if (before != null && failSecondPage) {
      throw ApiException(500, '{"error":"export_audit_failed"}');
    }
    return <String, Object?>{
      'manifest_version': 'v2',
      'messages': <Object?>[
        <String, Object?>{
          'id': 'msg_page_${befores.length}',
          'ciphertext': _sentinel
        },
      ],
      if (before == null) 'next_before': 'msg_page_1',
    };
  }
}

class _QuietSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
