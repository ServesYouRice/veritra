import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/crypto_service.dart';
import 'package:private_messenger/crypto/native_crypto_service.dart';
import 'package:private_messenger/crypto/profile_key_payload.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/local_store.dart';

/// W11 key messages and sidecars: wire shape, field rules, and who a key is
/// stored for.
final Uint8List _key = Uint8List.fromList(List.generate(32, (i) => i));
final String _keyId = ProfileRecordCodec.keyId(_key);

Map<String, Object?> _body({int version = 3}) =>
    profileKeyBody(key: _key, keyId: _keyId, version: version);

DecryptedAppPayload _payload(AppPayloadType type, Map<String, Object?> body) =>
    DecryptedAppPayload(type: type, actionId: 'action', body: body);

List<ProfileKeyEffect> _effects(
  DecryptedAppPayload payload, {
  String kind = 'group',
}) =>
    profileKeyEffects(payload,
            conversationId: 'conv_g',
            senderAccountId: 'acct_ana',
            receivedAt: 10,
            conversationKind: kind)
        .cast<ProfileKeyEffect>();

class _Authority implements ConversationAuthority {
  _Authority(this.kind);
  final String kind;
  @override
  String? roleOf(String conversationId, String accountId) => 'member';
  @override
  Set<String> memberAccounts(String conversationId) => const {};
  @override
  String? conversationKind(String conversationId) => kind;
  @override
  String? conversationChannel(String conversationId) => null;
}

void main() {
  final codec = AppPayloadCodec();

  test('the key id vector from the design', () {
    final id = ProfileRecordCodec.keyId(List.generate(32, (i) => i));
    expect(id, '5a7f7bb0d6bff19bebf7bfc3f05a9ed5');
  });

  group('wire shape', () {
    test('both key types are hidden, v2 and snake_case', () {
      expect(AppPayloadType.profileKey.wireName, 'profile_key');
      expect(AppPayloadType.groupProfileKey.wireName, 'group_profile_key');
      expect(AppPayloadType.profileKey.sendsHidden, isTrue);
      expect(AppPayloadType.groupProfileKey.sendsHidden, isTrue);
    });

    for (final type in [
      AppPayloadType.profileKey,
      AppPayloadType.groupProfileKey
    ]) {
      test('${type.wireName} round-trips through classify', () {
        final padded = codec.encodeFranked(
          type: type,
          conversationId: 'conv_g',
          senderDeviceId: 'dev',
          actionId: 'action',
          body: _body(),
          frankKey: Uint8List(32),
          hidden: true,
        );
        final outcome = codec.classify(padded.padded,
            conversationId: 'conv_g',
            senderDeviceId: 'dev',
            actionId: 'action');
        expect(outcome, isA<DecodedAppPayload>());
        final decoded = (outcome as DecodedAppPayload).payload;
        expect(decoded.type, type);
        expect(decoded.body['key_id'], _keyId);
      });
    }

    test('an older reader keeps a key message as an unsupported hidden row',
        () {
      // A v1-only app does not know the type: it must store the row hidden.
      final padded = codec.encode(
        type: AppPayloadType.profileKey,
        conversationId: 'conv_g',
        senderDeviceId: 'dev',
        actionId: 'action',
        body: _body(),
        hidden: true,
      );
      final inner = utf8.decode(
          padded.sublist(8, 8 + ByteData.sublistView(padded).getUint32(4)));
      final json = jsonDecode(inner) as Map;
      expect(json['v'], 2);
      expect(json['hidden'], isTrue);
      expect(json['type'], 'profile_key');
    });

    test('a sidecar on a text keeps the text valid', () {
      final padded = codec.encode(
        type: AppPayloadType.text,
        conversationId: 'conv_g',
        senderDeviceId: 'dev',
        actionId: 'action',
        body: {'text': 'hi', profileKeyBodyName: _body()},
      );
      final decoded = codec.decode(padded,
          conversationId: 'conv_g', senderDeviceId: 'dev', actionId: 'action');
      expect(decoded.body['text'], 'hi');
      expect(decoded.body[profileKeyBodyName], isA<Map>());
    });
  });

  group('field rules', () {
    test('a good key parses', () {
      final parsed = parseProfileKey(_body())!;
      expect(parsed.key, _key);
      expect(parsed.keyId, _keyId);
      expect(parsed.version, 3);
    });

    test('version 0 is allowed, negative is not', () {
      expect(parseProfileKey(_body(version: 0)), isNotNull);
      expect(parseProfileKey(_body(version: -1)), isNull);
    });

    test('a short key, a wrong key id, junk and non-maps are dropped', () {
      expect(parseProfileKey({..._body(), 'key': base64.encode(Uint8List(31))}),
          isNull);
      expect(parseProfileKey({..._body(), 'key_id': '0' * 32}), isNull);
      expect(parseProfileKey({..._body(), 'key': '!!not base64'}), isNull);
      expect(parseProfileKey({..._body(), 'version': '3'}), isNull);
      expect(parseProfileKey({..._body(), 'version': 1.5}), isNull);
      expect(parseProfileKey({..._body()}..remove('key_id')), isNull);
      expect(parseProfileKey('x'), isNull);
      expect(parseProfileKey(null), isNull);
    });
  });

  group('who a key is stored for', () {
    test('profile_key is the sender account\'s own key', () {
      final effects = _effects(_payload(AppPayloadType.profileKey, _body()));
      expect(effects, hasLength(1));
      expect(effects.single.kind, profileSubjectAccount);
      expect(effects.single.subjectId, 'acct_ana');
      expect(effects.single.raisesFloor, isTrue);
      expect(effects.single.version, 3);
    });

    test('group_profile_key is the conversation\'s key and never a floor', () {
      final effects =
          _effects(_payload(AppPayloadType.groupProfileKey, _body()));
      expect(effects.single.kind, profileSubjectConversation);
      expect(effects.single.subjectId, 'conv_g');
      expect(effects.single.raisesFloor, isFalse);
    });

    test('a group key in a DM, community or channel is dropped', () {
      for (final kind in ['dm', 'community_shared', 'channel', 'weird']) {
        expect(
            _effects(_payload(AppPayloadType.groupProfileKey, _body()),
                kind: kind),
            isEmpty,
            reason: kind);
      }
    });

    test('an account key works in any conversation kind', () {
      for (final kind in ['dm', 'group', 'community_shared']) {
        expect(
            _effects(_payload(AppPayloadType.profileKey, _body()), kind: kind),
            hasLength(1));
      }
    });

    test('sidecars on every carrier type give both keys', () {
      for (final type in [
        AppPayloadType.text,
        AppPayloadType.reply,
        AppPayloadType.attachmentManifest,
        AppPayloadType.poll,
      ]) {
        final effects = _effects(_payload(type, {
          profileKeyBodyName: _body(),
          groupProfileKeyBodyName: _body(version: 9),
        }));
        expect(effects.map((e) => e.kind),
            [profileSubjectAccount, profileSubjectConversation],
            reason: type.name);
      }
    });

    test('a bad sidecar is dropped alone', () {
      final effects = _effects(_payload(AppPayloadType.text, {
        'text': 'hi',
        profileKeyBodyName: {..._body(), 'key_id': '0' * 32},
        groupProfileKeyBodyName: _body(),
      }));
      expect(effects.map((e) => e.kind), [profileSubjectConversation]);
    });

    test('other types carry no keys even with a sidecar member', () {
      expect(
          _effects(_payload(AppPayloadType.reaction, {
            'message_id': 'm',
            'reaction': '+',
            profileKeyBodyName: _body(),
          })),
          isEmpty);
    });
  });

  group('messageEffectsFor', () {
    List<MessageEffect> run(DecryptedAppPayload payload,
            {String state = LocalMessageState.received,
            String kind = 'group'}) =>
        messageEffectsFor(payload,
            conversationId: 'conv_g',
            senderAccountId: 'acct_ana',
            senderDeviceId: 'dev',
            createdAt: 10,
            state: state,
            authority: _Authority(kind));

    test('a key message makes a hidden action row and the key', () {
      final effects = run(_payload(AppPayloadType.profileKey, _body()));
      final row = effects.whereType<InsertMessageEffect>().single;
      expect(row.kind, LocalMessageKind.action);
      expect(effects.whereType<ProfileKeyEffect>(), hasLength(1));
    });

    test('a text with a sidecar keeps its row and gains the key', () {
      final effects = run(_payload(
          AppPayloadType.text, {'text': 'hi', profileKeyBodyName: _body()}));
      expect(effects.whereType<InsertMessageEffect>().single.body, 'hi');
      expect(effects.whereType<ProfileKeyEffect>(), hasLength(1));
    });

    test('a key this device sent itself is not stored again', () {
      final effects = run(_payload(AppPayloadType.profileKey, _body()),
          state: LocalMessageState.pending);
      expect(effects.whereType<ProfileKeyEffect>(), isEmpty);
      expect(effects.whereType<InsertMessageEffect>(), hasLength(1));
    });

    test('a malformed key message is still a hidden action row', () {
      final effects = run(_payload(AppPayloadType.profileKey, {'key': 'x'}));
      expect(effects.whereType<InsertMessageEffect>().single.kind,
          LocalMessageKind.action);
      expect(effects.whereType<ProfileKeyEffect>(), isEmpty);
    });

    test('the memory store keeps the key from a committed message', () async {
      final store = MemoryLocalStore();
      await store.saveSession(const Session(
          baseUrl: 'https://example.test',
          token: 'token',
          accountId: 'acct_bob',
          deviceId: 'dev_bob'));
      await store.saveCryptoState(
          StoredCryptoState(
              counter: 1, stateKey: List.filled(32, 1), sealedState: [1]),
          0);
      final state = (await store.loadCryptoState())!;
      await store.commitMlsTransition(MlsStateTransition(
          messageId: 'event:1',
          conversationId: 'conv_g',
          expectedCounter: state.counter,
          expectedCursor: 0,
          state: StoredCryptoState(
              counter: 2, stateKey: state.stateKey, sealedState: [2]),
          cursor: 1,
          messageEffects:
              run(_payload(AppPayloadType.profileKey, _body(version: 5)))));
      final keys =
          await store.loadProfileKeys(profileSubjectAccount, 'acct_ana');
      expect(keys.single.keyId, _keyId);
      expect(
          (await store.loadProfile(profileSubjectAccount, 'acct_ana'))
              ?.versionFloor,
          5);
    });
  });
}
