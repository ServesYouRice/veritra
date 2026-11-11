import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/attachments.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/attachment_crypto.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

/// TASK-107: with an attachment service present, the request gate and the
/// manifest binding in `AppState.loadAttachment` are each what refuses
/// their own case. Before, the request test had no attachment service, so
/// every case failed on "attachments are unavailable".
void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('veritra-req-att-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Matcher refusedWith(String text) => throwsA(isA<StateError>()
      .having((error) => error.message, 'message', contains(text)));

  AttachmentEntry entry(Map<String, Object?> manifest) => AttachmentEntry(
        id: 'att',
        fileName: 'a.png',
        mediaType: 'image/png',
        plaintextSize: 5,
        ciphertextSize: 4,
        manifest: manifest,
      );

  test('a request refuses attachments; after acceptance the manifest decides',
      () async {
    final api = _Api();
    final state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: MemoryLocalStore(),
      syncServiceFactory: (_, __) => _FakeSync(),
      attachmentService: _FakeAttachmentCrypto(directory),
    )
      ..api = api
      ..session = const Session(
        baseUrl: 'https://localhost:8080',
        token: 'token',
        accountId: 'acct_me',
        deviceId: 'dev_me',
      );
    addTearDown(state.dispose);
    await state.refreshConversations();
    expect(state.isMessageRequestId('new'), isTrue);

    final matching = entry(<String, Object?>{'conversation_id': 'new'});
    final other = entry(<String, Object?>{'conversation_id': 'other'});
    final empty = entry(const <String, Object?>{});

    // While a request, the gate refuses even a matching manifest.
    await expectLater(state.loadAttachment(matching, conversationId: 'new'),
        refusedWith('wait until the request is accepted'));

    expect(await state.acceptMessageRequest('new'), isTrue);
    expect(state.isMessageRequestId('new'), isFalse);

    // Past the gate, only the manifest binding refuses these.
    await expectLater(state.loadAttachment(other, conversationId: 'new'),
        refusedWith('belongs to another conversation'));
    await expectLater(state.loadAttachment(empty, conversationId: 'new'),
        refusedWith('belongs to another conversation'));
    expect(api.downloads, 0);

    // And a matching manifest now loads.
    expect(await state.loadAttachment(matching, conversationId: 'new'),
        <int>[104, 101, 108, 108, 111]);
    expect(api.downloads, 1);
  });
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  int downloads = 0;

  @override
  Future<List<Conversation>> conversations(String token) async =>
      <Conversation>[
        Conversation(
          id: 'new',
          kind: 'dm',
          peerAccountId: 'acct_stranger',
          peerUsername: 'stranger',
          createdBy: 'acct_stranger',
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      ];

  @override
  Future<Stream<List<int>>> downloadEncryptedAttachment(
      String token, String attachmentId) async {
    downloads++;
    return Stream<List<int>>.value(<int>[1, 2, 3, 4]);
  }
}

class _FakeAttachmentCrypto implements AttachmentCryptoService {
  _FakeAttachmentCrypto(this.directory);

  final Directory directory;

  @override
  Future<Directory> workingDirectory() async => directory;

  @override
  Future<void> decryptFile({
    required String ciphertextPath,
    required String destinationPath,
    required Map<String, Object?> manifest,
    AttachmentCancellationToken? cancellation,
  }) =>
      File(destinationPath).writeAsString('hello');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeSync implements SyncService {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _events.close();
}
