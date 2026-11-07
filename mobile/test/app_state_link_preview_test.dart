// The sender builds a link preview before encrypting (B2): only for a text
// with a link, only when the setting allows it, never twice for one tap, and
// a failure sends the message without a preview.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/link_preview_service.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/link_preview.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'test_crypto_service.dart';

const _session = Session(
  baseUrl: 'https://localhost:8080',
  token: 'token',
  accountId: 'acct_me',
  deviceId: 'dev_me',
);

const _text = 'see https://github.com/a/b';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryLocalStore store;
  late _Previews previews;
  late AppState state;

  setUp(() {
    store = MemoryLocalStore();
    previews = _Previews();
    final api = _Api();
    state = AppState(
      apiClientFactory: (_) => api,
      cryptoService: TestOnlyCryptoService(),
      localStore: store,
      syncServiceFactory: (_, __) => _NoopSync(),
    )
      ..api = api
      ..session = _session
      ..conversations = <Conversation>[
        Conversation(id: 'conv_1', kind: 'group'),
      ]
      ..linkPreviews = previews;
  });

  tearDown(() async {
    state.dispose();
    await state.backgroundWorkIdle.timeout(const Duration(seconds: 10));
  });

  test('a link is previewed first, and a second tap is refused', () async {
    expect(state.linkPreviewMode, LinkPreviewMode.allowListed);
    final first = state.sendMessageTo('conv_1', _text);
    await Future<void>.delayed(Duration.zero);
    expect(previews.texts, <String>[_text]);
    expect(previews.modes, <LinkPreviewMode>[LinkPreviewMode.allowListed]);
    expect(state.isBusy(Ops.send), isTrue);
    expect(await state.sendMessageTo('conv_1', _text), isFalse);
    previews.gate.complete(
      const LinkPreview(url: 'https://github.com/a/b', title: 'T'),
    );
    expect(await first, isTrue);
    expect(state.isBusy(Ops.send), isFalse);
  });

  test('a failed build still sends the message', () async {
    final sent = state.sendMessageTo('conv_1', _text);
    await Future<void>.delayed(Duration.zero);
    previews.gate.completeError(StateError('network down'));
    expect(await sent, isTrue);
  });

  test('no link, or the setting off, builds nothing', () async {
    expect(await state.sendMessageTo('conv_1', 'just words'), isTrue);
    await state.setLinkPreviewMode(LinkPreviewMode.off);
    expect(await state.sendMessageTo('conv_1', _text), isTrue);
    expect(previews.texts, isEmpty);
  });

  test('the setting is stored on this device', () async {
    await state.setLinkPreviewMode(LinkPreviewMode.anySite);
    expect(await store.loadSetting('b2.link_preview'), 'anySite');
  });
}

class _Previews extends LinkPreviewService {
  final List<String> texts = <String>[];
  final List<LinkPreviewMode> modes = <LinkPreviewMode>[];
  final Completer<LinkPreview?> gate = Completer<LinkPreview?>();

  @override
  Future<LinkPreview?> build(String text, LinkPreviewMode mode) {
    texts.add(text);
    modes.add(mode);
    return gate.future;
  }
}

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://localhost:8080');

  @override
  Future<void> sendEnvelope(String token, MessageEnvelope envelope) async {}

  @override
  Future<MessagePage> listMessagePage(
    String token,
    String conversationId, {
    int limit = 50,
    String? before,
  }) async =>
      const MessagePage(messages: <ReceivedMessageEnvelope>[]);
}

class _NoopSync implements SyncService {
  final _controller = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _controller.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> dispose() => _controller.close();
}
