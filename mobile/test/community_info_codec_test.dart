import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/community_info_codec.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';

import 'native_test_env.dart';

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List _png(int w, int h) {
  final out = BytesBuilder();
  out.add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  final ihdr = ByteData(25);
  ihdr.setUint32(0, 13);
  ihdr.buffer.asUint8List().setRange(4, 8, utf8.encode('IHDR'));
  ihdr.setUint32(8, w);
  ihdr.setUint32(12, h);
  out.add(ihdr.buffer.asUint8List());
  return out.toBytes();
}

String _id(String prefix, int n) =>
    '${prefix}_${n.toRadixString(16).padLeft(32, '0')}';

Matcher _fails(ProfileRecordFailure failure) => throwsA(
    isA<ProfileRecordException>().having((e) => e.failure, 'failure', failure));

void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
  const keyId = '5a7f7bb0d6bff19bebf7bfc3f05a9ed5';
  final nonce = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
  final community = _id('comm', 1);
  final cat = _id('cat', 2);
  final chan = _id('chan', 3);

  CommunityInfoCodec codec({int seed = 7}) =>
      CommunityInfoCodec(bindings, random: Random(seed));

  setUp(() {
    if (skip != false) return;
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
  });

  test('subject IDs and the AEAD context are W11 with three more kinds', () {
    expect(validInfoSubject(infoKindCommunity, community), isTrue);
    expect(validInfoSubject(infoKindCategory, cat), isTrue);
    expect(validInfoSubject(infoKindChannel, chan), isTrue);
    expect(validInfoSubject(infoKindChannel, community), isFalse);
    expect(validInfoSubject(infoKindCategory, 'cat_ABC'), isFalse);
    expect(validInfoSubject('account', _id('acct', 1)), isFalse);
    expect(
      utf8.decode(ProfileRecordCodec.context(infoKindChannel, chan, keyId)),
      'veritra-profile-v1\u0000channel\u0000$chan\u0000$keyId',
    );
  });

  CommunityInfoRecord communityRecord({int revision = 1}) =>
      CommunityInfoRecord(
        kind: infoKindCommunity,
        subjectId: community,
        revision: revision,
        name: 'Club',
        categories: [cat],
        channels: [
          InfoChannelPlace(channelId: chan, categoryId: cat),
          InfoChannelPlace(channelId: _id('chan', 4)),
        ],
      );

  test('vectors: each kind seals deterministically and opens', () {
    final records = <String, CommunityInfoRecord>{
      'community': communityRecord(),
      'category': CommunityInfoRecord(
          kind: infoKindCategory, subjectId: cat, revision: 1, name: 'Games'),
      'channel': CommunityInfoRecord(
          kind: infoKindChannel,
          subjectId: chan,
          revision: 2,
          name: 'general',
          topic: 'Say hi'),
    };
    final digests = <String, String>{};
    for (final entry in records.entries) {
      final blob =
          codec().seal(key: key, record: entry.value, noncePrefix: nonce);
      expect(blob.length, 4 + 8 + profileSmallBucket + 16);
      // Same inputs, same bytes.
      expect(codec().seal(key: key, record: entry.value, noncePrefix: nonce),
          blob);
      digests[entry.key] = CommunityInfoCodec.recordSha256(blob);
      final opened = codec().open(
        key: key,
        servedKeyId: keyId,
        servedVersion: entry.value.revision,
        kind: entry.value.kind,
        subjectId: entry.value.subjectId,
        blob: blob,
      );
      expect(opened.name, entry.value.name);
      expect(opened.topic, entry.value.topic);
      expect(opened.revision, entry.value.revision);
    }
    // Pinned so a change to the framing, JSON or AEAD context shows up here.
    expect(digests, {
      'community':
          '212b37271672828c828ce61e4d96b5a28baa6d10d501128ade06edb05714157d',
      'category':
          '2e1df1b9bcebf5f04f8212d7d6a3bf8cdd8a8e56accdbacfec28c90a76b9541a',
      'channel':
          '56aaad8f8566d092d7fcbaccf3a9cc188ec9267d1e52a7bc09f92522799f7380',
    });
    final opened = codec().open(
      key: key,
      servedKeyId: keyId,
      servedVersion: 1,
      kind: infoKindCommunity,
      subjectId: community,
      blob:
          codec().seal(key: key, record: communityRecord(), noncePrefix: nonce),
    );
    expect(opened.categories, [cat]);
    expect(opened.channels, [
      InfoChannelPlace(channelId: chan, categoryId: cat),
      InfoChannelPlace(channelId: _id('chan', 4)),
    ]);
  }, skip: skip);

  test('a private channel carries its own place; a tombstone has nothing', () {
    final private = CommunityInfoRecord(
      kind: infoKindChannel,
      subjectId: chan,
      revision: 1,
      name: 'staff',
      topic: '',
      icon: ProfilePhoto(png: _png(64, 64), width: 64, height: 64),
      privatePlace: InfoPrivatePlace(categoryId: cat, position: 3),
    );
    final opened = codec().open(
      key: key,
      servedKeyId: keyId,
      servedVersion: 1,
      kind: infoKindChannel,
      subjectId: chan,
      blob: codec().seal(key: key, record: private),
    );
    expect(opened.privatePlace?.categoryId, cat);
    expect(opened.privatePlace?.position, 3);
    expect(opened.icon?.width, 64);
    expect(opened.topic, '');
    expect(opened.isTombstone, isFalse);

    final tomb = codec().open(
      key: key,
      servedKeyId: keyId,
      servedVersion: 2,
      kind: infoKindChannel,
      subjectId: chan,
      blob: codec().seal(
          key: key,
          record: CommunityInfoRecord(
              kind: infoKindChannel, subjectId: chan, revision: 2)),
    );
    expect(tomb.isTombstone, isTrue);
    // A tombstone with a topic or icon left is not one.
    expect(
        () => codec().seal(
            key: key,
            record: CommunityInfoRecord(
                kind: infoKindChannel,
                subjectId: chan,
                revision: 2,
                topic: 'x')),
        _fails(ProfileRecordFailure.badName));
    // A community is never a tombstone.
    expect(
        () => codec().seal(
            key: key,
            record: CommunityInfoRecord(
                kind: infoKindCommunity,
                subjectId: community,
                revision: 2,
                categories: const [],
                channels: const [])),
        _fails(ProfileRecordFailure.badFraming));
  }, skip: skip);

  test('a big community goes into the large bucket', () {
    final big = CommunityInfoRecord(
      kind: infoKindCommunity,
      subjectId: community,
      revision: 1,
      name: 'Big',
      categories: [for (var i = 0; i < infoMaxCategories; i++) _id('cat', i)],
      channels: [
        for (var i = 0; i < infoMaxChannels; i++)
          InfoChannelPlace(channelId: _id('chan', i), categoryId: _id('cat', 0))
      ],
    );
    final blob = codec().seal(key: key, record: big);
    expect(blob.length, 4 + 8 + profileLargeBucket + 16);
    final opened = codec().open(
        key: key,
        servedKeyId: keyId,
        servedVersion: 1,
        kind: infoKindCommunity,
        subjectId: community,
        blob: blob);
    expect(opened.channels!.length, infoMaxChannels);
  }, skip: skip);

  test('the receiver refuses what the design forbids', () {
    final blob = codec().seal(key: key, record: communityRecord(revision: 3));
    // Wrong key id, wrong subject, wrong kind, wrong version, rollback.
    expect(
        () => codec().open(
            key: key,
            servedKeyId: '0' * 32,
            servedVersion: 3,
            kind: infoKindCommunity,
            subjectId: community,
            blob: blob),
        _fails(ProfileRecordFailure.keyMismatch));
    expect(
        () => codec().open(
            key: key,
            servedKeyId: keyId,
            servedVersion: 3,
            kind: infoKindCommunity,
            subjectId: _id('comm', 9),
            blob: blob),
        _fails(ProfileRecordFailure.authFailed));
    expect(
        () => codec().open(
            key: key,
            servedKeyId: keyId,
            servedVersion: 4,
            kind: infoKindCommunity,
            subjectId: community,
            blob: blob),
        _fails(ProfileRecordFailure.revisionMismatch));
    expect(
        () => codec().open(
            key: key,
            servedKeyId: keyId,
            servedVersion: 3,
            kind: infoKindCommunity,
            subjectId: community,
            blob: blob,
            cachedRevision: 4),
        _fails(ProfileRecordFailure.rollback));
    // Content rules, checked before sealing too.
    void refuses(CommunityInfoRecord r, ProfileRecordFailure f) =>
        expect(() => codec().seal(key: key, record: r), _fails(f));
    refuses(
        CommunityInfoRecord(
            kind: infoKindCategory,
            subjectId: cat,
            revision: 1,
            name: 'a' * (infoNameMax + 1)),
        ProfileRecordFailure.badName);
    refuses(
        CommunityInfoRecord(
            kind: infoKindChannel,
            subjectId: chan,
            revision: 1,
            name: 'x',
            topic: 'line\nbreak'),
        ProfileRecordFailure.badName);
    refuses(
        CommunityInfoRecord(
            kind: infoKindCommunity,
            subjectId: community,
            revision: 1,
            name: 'x',
            categories: const [],
            channels: [InfoChannelPlace(channelId: chan, categoryId: cat)]),
        ProfileRecordFailure.badFraming);
    refuses(
        CommunityInfoRecord(
            kind: infoKindCommunity,
            subjectId: community,
            revision: 1,
            name: 'x',
            categories: [cat, cat],
            channels: const []),
        ProfileRecordFailure.badFraming);
    refuses(
        CommunityInfoRecord(
            kind: infoKindCategory, subjectId: chan, revision: 1, name: 'x'),
        ProfileRecordFailure.badInput);
    refuses(
        CommunityInfoRecord(
            kind: infoKindChannel,
            subjectId: chan,
            revision: 1,
            name: 'x',
            icon: ProfilePhoto(png: _png(300, 300), width: 300, height: 300)),
        ProfileRecordFailure.badPhoto);
  }, skip: skip);

  test('unknown keys are ignored; keys of another kind are refused', () {
    Map<String, Object?> category(Map<String, Object?> extra) => {
          'v': 1,
          'kind': infoKindCategory,
          'subject_id': cat,
          'revision': 1,
          'name': 'Games',
          ...extra,
        };
    expect(
        CommunityInfoCodec.checkContent(category({'later_field': 1}),
                kind: infoKindCategory, subjectId: cat)
            .name,
        'Games');
    expect(
        () => CommunityInfoCodec.checkContent(category({'topic': 'x'}),
            kind: infoKindCategory, subjectId: cat),
        _fails(ProfileRecordFailure.badFraming));
    expect(
        () => CommunityInfoCodec.checkContent(category({'v': 2}),
            kind: infoKindCategory, subjectId: cat),
        _fails(ProfileRecordFailure.badFraming));
    // A channel record must say its topic and icon, even as null.
    expect(
        () => CommunityInfoCodec.checkContent({
              'v': 1,
              'kind': infoKindChannel,
              'subject_id': chan,
              'revision': 1,
              'name': 'general',
            }, kind: infoKindChannel, subjectId: chan),
        _fails(ProfileRecordFailure.badFraming));
  });
}
