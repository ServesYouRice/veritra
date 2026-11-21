import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/api_client.dart';
import 'package:private_messenger/core/app_state.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/core/roles/governance.dart';
import 'package:private_messenger/core/roles/posting_verdict.dart';
import 'package:private_messenger/crypto/community_info_codec.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/storage/local_store.dart';
import 'package:private_messenger/sync/sync_service.dart';

import 'native_test_env.dart';

// C3 (docs/designs/C3-private-channels-and-info.md, step 4): community,
// channel and category names and topics never leave the device in
// plaintext. The create routes carry no name at all, and the info records
// the app uploads are sealed, so the secret's bytes appear nowhere in what
// reaches the server: not the path, the query, a header or the body.

const _communityName = 'Zebra Orchard Society';
const _channelName = 'Velvet Lantern Room';
const _channelTopic = 'Quiet plans for the harvest';

/// Every byte sequence a leak could take: UTF-8 of each secret, and its
/// lowercase and JSON-escaped forms.
List<List<int>> get _needles => [
      for (final secret in [_communityName, _channelName, _channelTopic])
        for (final form in {
          secret,
          secret.toLowerCase(),
          jsonEncode(secret),
          Uri.encodeComponent(secret),
          Uri.encodeQueryComponent(secret),
        })
          utf8.encode(form),
    ];

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

void _expectNoSecret(List<int> bytes, String where) {
  for (final needle in _needles) {
    expect(
      _contains(bytes, needle),
      isFalse,
      reason: '$where carries "${utf8.decode(needle)}"',
    );
  }
}

class _RealHttp extends HttpOverrides {}

class _QuietSync implements SyncService {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> connect() async {}
  @override
  Future<void> dispose() async {}
}

class _Roles implements VerifiedRoleSource {
  @override
  GovernanceState? governanceOf(String conversationId) =>
      GovernanceState.genesis('alice');
  @override
  bool serverRestrictsPosting(String conversationId, String? channelId) =>
      false;
}

/// Seals info records with the native codec; no MLS.
class _InfoCrypto extends UnavailableCryptoService
    implements CommunityInfoCryptoService {
  _InfoCrypto(this.bindings);
  final NativeCryptoBindings bindings;
  @override
  CommunityInfoCodec get communityInfoCodec => CommunityInfoCodec(bindings);
}

/// Keeps every info blob the app uploads, as the server would store it.
class _Api extends ApiClient {
  _Api() : super(baseUrl: 'https://example.test');

  final records = <String, ({int version, String keyId, Uint8List blob})>{};
  final uploads = <List<int>>[];
  final paths = <String>[];

  @override
  Future<({int version, String keyId, Uint8List blob})?> getInfoRecord(
    String token, {
    required String kind,
    required String subjectId,
    String? communityId,
  }) async =>
      records['$kind|$subjectId'];

  @override
  Future<int> putInfoRecord(
    String token, {
    required String kind,
    required String subjectId,
    String? communityId,
    required String keyId,
    required List<int> blob,
    required int expectedVersion,
  }) async {
    uploads.add(List<int>.of(blob));
    paths.add('$kind/$subjectId/$keyId');
    final version = expectedVersion + 1;
    records['$kind|$subjectId'] = (
      version: version,
      keyId: keyId,
      blob: Uint8List.fromList(blob),
    );
    return version;
  }

  @override
  Future<List<ConversationMember>> communityMembers(
    String token,
    String communityId,
  ) async =>
      [ConversationMember(accountId: 'alice', role: 'owner')];

  @override
  Future<List<({String kind, String id, int version, String keyId})>>
      infoVersions(
    String token, {
    List<String> communityIds = const [],
    List<String> categoryIds = const [],
    List<String> channelIds = const [],
  }) async =>
          [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the create routes send no name, whatever the user typed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen =
        <({String method, String uri, String headers, List<int> body})>[];
    server.listen((request) async {
      final body = <int>[];
      await for (final chunk in request) {
        body.addAll(chunk);
      }
      final headers = StringBuffer();
      request.headers.forEach((name, values) {
        headers.writeln('$name: ${values.join(',')}');
      });
      seen.add((
        method: request.method,
        uri: request.uri.toString(),
        headers: headers.toString(),
        body: body,
      ));
      final response = request.response..headers.contentType = ContentType.json;
      final path = request.uri.path;
      if (path == '/api/v1/communities') {
        response.write(
          jsonEncode({'id': 'comm_1', 'name': '', 'created_by': 'alice'}),
        );
      } else {
        response.write(
          jsonEncode({
            'channel': {
              'id': 'chan_1',
              'community_id': 'comm_1',
              'name': '',
              'kind': 'private',
            },
            'conversation': {'id': 'conv_1', 'kind': 'community_channel'},
            'skipped_members': 0,
          }),
        );
      }
      await response.close();
    });
    // A real socket: the test binding's HttpClient answers 400 to all.
    final client = HttpOverrides.runWithHttpOverrides(
      () => ApiClient(
        baseUrl: 'http://${server.address.address}:${server.port}',
      ),
      _RealHttp(),
    );
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });

    await client.createCommunity('t', _communityName);
    for (final kind in ['private', 'open', 'announcement']) {
      await client.createChannel('t', 'comm_1', _channelName, kind: kind);
    }
    expect(seen, hasLength(4));
    for (final request in seen) {
      final where = '${request.method} ${request.uri}';
      _expectNoSecret(utf8.encode(request.uri), '$where (uri)');
      _expectNoSecret(utf8.encode(request.headers), '$where (headers)');
      _expectNoSecret(request.body, '$where (body)');
    }
  });

  test(
    'the info records the app uploads are sealed: no name or topic in them',
    () async {
      final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
      final api = _Api();
      final store = MemoryLocalStore();
      final state = AppState(
        apiClientFactory: (_) => api,
        syncServiceFactory: (_, __) => _QuietSync(),
        localStore: store,
        cryptoService: _InfoCrypto(bindings),
      );
      addTearDown(state.dispose);
      state.session = const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'alice',
        deviceId: 'dev',
      );
      state.api = api;
      state.debugInfoRoleSource = _Roles();
      final id = 'comm_${'1' * 32}';
      final channel = Channel(
        id: 'chan_${'2' * 32}',
        communityId: id,
        name: '',
        kind: 'private',
        conversationId: 'conv_private',
        layoutGeneration: 1,
      );
      state.communities = [
        Community(id: id, name: '', sharedConversationId: 'conv_shared'),
      ];
      state.channelsByCommunity = {
        id: [channel],
      };
      state.communitiesLoaded = true;

      expect(
        await state.publishCommunityInfo(id, name: _communityName, mint: true),
        isTrue,
      );
      expect(
        await state.publishChannelInfo(
          channel,
          name: _channelName,
          topic: _channelTopic,
          mint: true,
        ),
        isTrue,
      );
      // Not vacuous: the app shows what it sealed.
      expect(
          state.communityDisplayName(state.communities.single), _communityName);
      expect(state.channelDisplayName(channel), _channelName);
      expect(state.channelTopic(channel), _channelTopic);

      expect(api.uploads, hasLength(2));
      for (final (index, blob) in api.uploads.indexed) {
        _expectNoSecret(blob, 'upload ${api.paths[index]}');
        _expectNoSecret(utf8.encode(api.paths[index]), 'route');
      }
    },
    skip: nativeCryptoSkip(),
  );
}
