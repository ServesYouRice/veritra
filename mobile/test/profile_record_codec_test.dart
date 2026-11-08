import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/profile_record_codec.dart';

import 'native_test_env.dart';

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
Uint8List _unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

Uint8List _png(int w, int h, {int extra = 0}) {
  final out = BytesBuilder();
  out.add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  final ihdr = ByteData(25);
  ihdr.setUint32(0, 13);
  ihdr.buffer.asUint8List().setRange(4, 8, utf8.encode('IHDR'));
  ihdr.setUint32(8, w);
  ihdr.setUint32(12, h);
  out.add(ihdr.buffer.asUint8List());
  out.add(Uint8List(extra));
  return out.toBytes();
}

void main() {
  final skip = nativeCryptoSkip();
  late NativeCryptoBindings bindings;
  late ProfileRecordCodec codec;
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
  const keyId = '5a7f7bb0d6bff19bebf7bfc3f05a9ed5';
  const acct = 'acct_11111111111111111111111111111111';
  const other = 'acct_22222222222222222222222222222222';
  const conv = 'conv_55555555555555555555555555555555';

  setUp(() {
    if (skip != false) return;
    bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    codec = ProfileRecordCodec(bindings);
  });

  test('key id and context vectors', () {
    expect(ProfileRecordCodec.keyId(key), keyId);
    expect(
      _hex(ProfileRecordCodec.context(profileKindAccount, acct, keyId)),
      '766572697472612d70726f66696c652d7631006163636f756e7400616363745f3131313131313131313131313131313131313131313131313131313131313131003561376637626230643662666631396265626637626663336630356139656435',
    );
    expect(
        ProfileRecordCodec.context(profileKindConversation, conv, keyId).length,
        102);
    expect(() => ProfileRecordCodec.keyId(Uint8List(31)),
        throwsA(isA<ProfileRecordException>()));
  });

  test('AEAD vectors through the ABI, and a wrong subject fails', () {
    final nonce = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final plain = utf8.encode('veritra profile vector');
    final account = bindings.encryptAttachmentChunk(
      key: key,
      noncePrefix: nonce,
      chunkIndex: 0,
      context: ProfileRecordCodec.context(profileKindAccount, acct, keyId),
      plaintext: plain,
    );
    expect(_hex(account),
        'fc7a5cd9f965944bfcbabb3b1d92aa76d7cb852c0473474d91bd81f77bc0a445926c9dd158d5');
    final group = bindings.encryptAttachmentChunk(
      key: key,
      noncePrefix: nonce,
      chunkIndex: 0,
      context: ProfileRecordCodec.context(profileKindConversation, conv, keyId),
      plaintext: plain,
    );
    expect(_hex(group),
        'fc7a5cd9f965944bfcbabb3b1d92aa76d7cb852c0473958f58b7673fe89ace181486b26b73e8');
    expect(
      () => bindings.decryptAttachmentChunk(
        key: key,
        noncePrefix: nonce,
        chunkIndex: 0,
        context: ProfileRecordCodec.context(profileKindAccount, other, keyId),
        ciphertext: account,
      ),
      throwsA(isA<NativeCryptoException>()),
    );
    expect(_unhex(_hex(account)), account);
  }, skip: skip);

  ProfileRecord rec(
          {String? name = 'Ana',
          ProfilePhoto? photo,
          int revision = 1,
          String kind = profileKindAccount,
          String subject = acct}) =>
      ProfileRecord(
          kind: kind,
          subjectId: subject,
          revision: revision,
          name: name,
          photo: photo);

  Uint8List seal(ProfileRecord r) => codec.seal(key: key, record: r);
  ProfileRecord open(Uint8List blob,
          {int version = 1,
          String kind = profileKindAccount,
          String subject = acct,
          int cached = 0,
          int floor = 0,
          String? served}) =>
      codec.open(
          key: key,
          servedKeyId: served ?? keyId,
          servedVersion: version,
          kind: kind,
          subjectId: subject,
          blob: blob,
          cachedRevision: cached,
          versionFloor: floor);

  void refuses(void Function() f, ProfileRecordFailure why) {
    try {
      f();
      fail('expected $why');
    } on ProfileRecordException catch (e) {
      expect(e.failure, why);
    }
  }

  test('round trip: name only is the small bucket, with photo the large', () {
    final small = seal(rec());
    expect(small.length, 4 * 1024 + 28);
    expect(utf8.decode(small.sublist(0, 4)), 'VPE1');
    final r = open(small);
    expect(r.name, 'Ana');
    expect(r.photo, isNull);
    final png = _png(256, 256, extra: 5000);
    final big = seal(rec(
        photo: ProfilePhoto(png: png, width: 256, height: 256), revision: 4));
    expect(big.length, 256 * 1024 + 28);
    final back = open(big, version: 4);
    expect(back.photo!.png, png);
    expect(back.revision, 4);
    // Fresh nonce every upload: two seals of one record differ.
    expect(seal(rec()), isNot(small));
    // Group records use their own kind.
    final g = codec.seal(
        key: key,
        record:
            rec(kind: profileKindConversation, subject: conv, name: 'Club'));
    expect(open(g, kind: profileKindConversation, subject: conv).name, 'Club');
  }, skip: skip);

  test('a removed record opens as removed', () {
    final r = open(seal(rec(name: null, revision: 2)), version: 2);
    expect(r.isRemoved, isTrue);
  }, skip: skip);

  test('wrong subject, kind, key id, key and tampering are refused', () {
    final blob = seal(rec());
    refuses(() => open(blob, subject: other), ProfileRecordFailure.authFailed);
    refuses(() => open(blob, kind: profileKindConversation, subject: conv),
        ProfileRecordFailure.authFailed);
    // A key id that is not derived from the key.
    refuses(
        () => open(blob, served: '0' * 32), ProfileRecordFailure.keyMismatch);
    final tampered = Uint8List.fromList(blob)..[100] ^= 1;
    refuses(() => open(tampered), ProfileRecordFailure.authFailed);
    refuses(() => open(Uint8List.fromList(blob.sublist(1))),
        ProfileRecordFailure.badBlob);
    final badMagic = Uint8List.fromList(blob)..[0] = 0x58;
    refuses(() => open(badMagic), ProfileRecordFailure.badBlob);
    final wrongKey = Uint8List.fromList(List<int>.generate(32, (i) => 31 - i));
    refuses(
      () => codec.open(
          key: wrongKey,
          servedKeyId: ProfileRecordCodec.keyId(wrongKey),
          servedVersion: 1,
          kind: profileKindAccount,
          subjectId: acct,
          blob: blob),
      ProfileRecordFailure.authFailed,
    );
  }, skip: skip);

  test('the record must name the asked subject (a copied record is refused)',
      () {
    // Sealed for `other`, then served as `acct`: the AEAD context already
    // differs, so decrypting as acct fails.
    final forOther = seal(rec(subject: other));
    refuses(
        () => open(forOther, subject: acct), ProfileRecordFailure.authFailed);
    expect(open(forOther, subject: other).subjectId, other);
  }, skip: skip);

  test('revision must equal the version; rollback is refused', () {
    final blob = seal(rec(revision: 3));
    refuses(
        () => open(blob, version: 4), ProfileRecordFailure.revisionMismatch);
    refuses(
        () => open(blob, version: 3, cached: 4), ProfileRecordFailure.rollback);
    refuses(
        () => open(blob, version: 3, floor: 5), ProfileRecordFailure.rollback);
    expect(open(blob, version: 3, cached: 3, floor: 3).revision, 3);
  }, skip: skip);

  test('names: controls, bidi and length are refused on send and on receive',
      () {
    for (final bad in <String>[
      '',
      '   ',
      'a\u0007b',
      'a${String.fromCharCode(0x202e)}b',
      'a${String.fromCharCode(0x2066)}b',
      'a‎b',
      'a؜b',
      'a\u0085b',
      'x' * 65
    ]) {
      expect(
          ProfileRecordCodec.validName(bad, kind: profileKindAccount), isFalse,
          reason: bad.codeUnits.toString());
      refuses(() => seal(rec(name: bad)), ProfileRecordFailure.badName);
    }
    expect(ProfileRecordCodec.validName('x' * 64, kind: profileKindAccount),
        isTrue);
    expect(
        ProfileRecordCodec.validName('x' * 100, kind: profileKindConversation),
        isTrue);
    expect(
        ProfileRecordCodec.validName('x' * 101, kind: profileKindConversation),
        isFalse);
    expect(
        ProfileRecordCodec.validName('Ana Marić 🎉', kind: profileKindAccount),
        isTrue);
    // A hostile peer bypasses seal(): build the plaintext by hand.
    final blob = _handSealed(bindings, key, {
      'v': 1,
      'kind': 'account',
      'subject_id': acct,
      'revision': 1,
      'name': 'ev${String.fromCharCode(0x202e)}il',
      'photo': null,
    });
    refuses(() => open(blob), ProfileRecordFailure.badName);
  }, skip: skip);

  test('surrogates, bad subject ids and the group floor', () {
    for (final bad in <String>[
      'ab${String.fromCharCode(0xd800)}',
      '${String.fromCharCode(0xdc00)}ab',
      'a${String.fromCharCode(0x2028)}b',
    ]) {
      expect(
          ProfileRecordCodec.validName(bad, kind: profileKindAccount), isFalse);
    }
    expect(
        ProfileRecordCodec.validName('ok \u{1F389}', kind: profileKindAccount),
        isTrue);
    final lone = _handSealed(bindings, key, {
      'v': 1,
      'kind': 'account',
      'subject_id': acct,
      'revision': 1,
      'name': 'ab${String.fromCharCode(0xd800)}',
      'photo': null,
    });
    refuses(() => open(lone), ProfileRecordFailure.badName);
    refuses(() => seal(rec(name: 'ab${String.fromCharCode(0xd800)}')),
        ProfileRecordFailure.badName);
    refuses(() => open(seal(rec()), subject: 'acct_${'a' * 600}'),
        ProfileRecordFailure.badInput);
    refuses(() => open(seal(rec()), kind: profileKindConversation),
        ProfileRecordFailure.badInput);
    // A group record ignores the floor (any member can send a high hint).
    final g = codec.seal(
        key: key,
        record:
            rec(kind: profileKindConversation, subject: conv, name: 'Club'));
    expect(
        open(g, kind: profileKindConversation, subject: conv, floor: 99).name,
        'Club');
  }, skip: skip);

  test('photos: signature, size, dimensions and declared size are checked', () {
    ProfilePhoto photo(Uint8List png, int w, int h) =>
        ProfilePhoto(png: png, width: w, height: h);
    refuses(() => seal(rec(photo: photo(_png(600, 600), 600, 600))),
        ProfileRecordFailure.badPhoto);
    refuses(() => seal(rec(photo: photo(_png(256, 256), 128, 128))),
        ProfileRecordFailure.badPhoto);
    refuses(
        () => seal(
            rec(photo: photo(_png(256, 256, extra: 192 * 1024), 256, 256))),
        ProfileRecordFailure.badPhoto);
    refuses(() => seal(rec(photo: photo(Uint8List(64), 256, 256))),
        ProfileRecordFailure.badPhoto);
    // A hostile peer declares a small photo but ships a huge IHDR.
    final blob = _handSealed(
      bindings,
      key,
      {
        'v': 1,
        'kind': 'account',
        'subject_id': acct,
        'revision': 1,
        'name': 'Ana',
        'photo': {'media_type': 'image/png', 'width': 256, 'height': 256}
      },
      photo: _png(4000, 4000),
    );
    refuses(() => open(blob), ProfileRecordFailure.badPhoto);
  }, skip: skip);

  test('framing: a photo length without a photo field is refused', () {
    final blob = _handSealed(
      bindings,
      key,
      {
        'v': 1,
        'kind': 'account',
        'subject_id': acct,
        'revision': 1,
        'name': 'Ana',
        'photo': null
      },
      photo: _png(8, 8),
    );
    refuses(() => open(blob), ProfileRecordFailure.badFraming);
  }, skip: skip);

  test('unknown JSON fields are ignored', () {
    final blob = _handSealed(bindings, key, {
      'v': 1,
      'kind': 'account',
      'subject_id': acct,
      'revision': 1,
      'name': 'Ana',
      'photo': null,
      'about': 'later',
    });
    expect(open(blob).name, 'Ana');
  }, skip: skip);

  test('new keys are 32 random bytes', () {
    if (skip != false) return;
    final a = codec.newKey();
    expect(a.length, 32);
    expect(codec.newKey(), isNot(a));
  }, skip: skip);
}

/// Builds a blob the way a hostile peer could, skipping seal()'s checks.
Uint8List _handSealed(
    NativeCryptoBindings b, Uint8List key, Map<String, Object?> json,
    {Uint8List? photo}) {
  final j = utf8.encode(jsonEncode(json));
  final p = photo ?? Uint8List(0);
  final bucket = photo == null ? profileSmallBucket : profileLargeBucket;
  final plain = Uint8List(bucket);
  final v = ByteData.sublistView(plain);
  plain.setRange(0, 4, utf8.encode('VPR1'));
  v.setUint32(4, j.length);
  plain.setRange(8, 8 + j.length, j);
  v.setUint32(8 + j.length, p.length);
  plain.setRange(12 + j.length, 12 + j.length + p.length, p);
  final id = ProfileRecordCodec.keyId(key);
  final nonce = Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9]);
  final sealed = b.encryptAttachmentChunk(
    key: key,
    noncePrefix: nonce,
    chunkIndex: 0,
    context: ProfileRecordCodec.context(
        json['kind'] as String, json['subject_id'] as String, id),
    plaintext: plain,
  );
  return Uint8List.fromList([...utf8.encode('VPE1'), ...nonce, ...sealed]);
}
