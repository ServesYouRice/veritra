import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';

/// C4 leave proof in the commit (ABI 24): the shared vector
/// testing/vectors/c4-leave-proof-v1.json, which Rust checks in full
/// (`leave_proof::tests::shared_vector_matches`). Dart never signs or
/// verifies a statement; it frames what it stores and the `VCL1` list it
/// hands to Rust, and validates the `member_leave_signed` body.
void main() {
  final vector = jsonDecode(
          File('../testing/vectors/c4-leave-proof-v1.json').readAsStringSync())
      as Map<String, Object?>;
  Uint8List unhex(Object? value) {
    final text = value as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  final statement = unhex(vector['statement_hex']);
  final second = unhex(vector['second_statement_hex']);

  test('the VCL1 list matches the vector byte for byte', () {
    expect(isLeaveStatement(statement), isTrue);
    expect(isLeaveStatement(second), isTrue);
    expect(leaveStatementLeaf(statement), vector['leaf_index']);
    expect(statement.length, leaveStatementBytes);
    expect(encodeLeaveProofs([statement, second]), unhex(vector['aad_hex']));
  });

  test('the list refuses what Rust would refuse', () {
    expect(() => encodeLeaveProofs(const []), throwsArgumentError);
    expect(
        () => encodeLeaveProofs([statement, statement]), throwsArgumentError);
    expect(
        () => encodeLeaveProofs([statement.sublist(1)]), throwsArgumentError);
    final badLength = Uint8List.fromList(statement)..[5] = 63;
    expect(() => encodeLeaveProofs([badLength]), throwsArgumentError);
    final many = [
      for (var leaf = 0; leaf <= leaveStatementsMax; leaf++)
        Uint8List.fromList(statement)..[3] = leaf,
    ];
    expect(encodeLeaveProofs(many.sublist(0, leaveStatementsMax)).length,
        5 + leaveStatementsMax * leaveStatementBytes);
    expect(() => encodeLeaveProofs(many), throwsArgumentError);
  });

  test('member_leave_signed is hidden, marked, unfranked, exact', () {
    const type = AppPayloadType.memberLeaveSigned;
    expect(type.wireName, 'member_leave_signed');
    expect(type.sendsHidden, isTrue);
    expect(leaveNoticePayloadTypes, contains(type));
    expect(FrankingPolicy.unfrankedPayloadTypes, contains(type.name));
    final body = {'statement': base64.encode(statement)};
    expect(isValidLeaveSignedBody(body), isTrue);
    for (final bad in <Map<String, Object?>>[
      {},
      {'statement': base64.encode(statement), 'epoch': 1},
      {'statement': base64.encode(statement.sublist(1))},
      {'statement': base64Url.encode(statement).replaceAll('=', '')},
      {'statement': 1},
      {'statement': base64.encode(Uint8List.fromList(statement)..[4] = 1)},
    ]) {
      expect(isValidLeaveSignedBody(bad), isFalse, reason: '$bad');
    }
    final encoded = AppPayloadCodec().encode(
      type: type,
      conversationId: 'conv_1',
      senderDeviceId: 'dev_bob',
      actionId: 'act_1',
      body: body,
      hidden: true,
    );
    final decoded = AppPayloadCodec().decode(encoded,
        conversationId: 'conv_1', senderDeviceId: 'dev_bob', actionId: 'act_1');
    expect(decoded.type, type);
    expect(decoded.body, body);
    expect(
        () => AppPayloadCodec().encode(
              type: type,
              conversationId: 'conv_1',
              senderDeviceId: 'dev_bob',
              actionId: 'act_1',
              body: const {'epoch': 1},
              hidden: true,
            ),
        throwsFormatException);
  });
}
