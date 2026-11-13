import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/c7_channel_book.dart';
import 'package:private_messenger/crypto/c7_history.dart';
import 'package:private_messenger/crypto/c7_sync.dart';
import 'package:private_messenger/crypto/c7_two_part.dart';
import 'package:private_messenger/crypto/native_crypto_bindings.dart';
import 'package:private_messenger/crypto/sha256.dart';

import 'native_test_env.dart';

/// testing/vectors/c7-sync-v1.json: one whole `history_sync` as sent, made
/// by testing/vectors/c7-sync-v1.py. A live member opens it the way sync
/// does (`c7OpenLiveParts`, then body0's VAP1, then `c7OpenSlots`); Rust and
/// Go check the same file. A missing vector fails; it never skips.
void main() {
  final vector = jsonDecode(
    File('../testing/vectors/c7-sync-v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final inputs = vector['inputs'] as Map<String, dynamic>;
  final outputs = vector['outputs'] as Map<String, dynamic>;
  final channels = (inputs['channels'] as List).cast<Map<String, dynamic>>();

  Uint8List hex(Object? value) {
    final text = value as String;
    return Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
  }

  String toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  final community = inputs['community_id'] as String;
  final conversation = inputs['conversation_id'] as String;
  final sender = inputs['sender_device_id'] as String;
  final action = inputs['action_id'] as String;
  final sealed = hex(outputs['sealed_body_hex']);

  test('the lengths are the layout Dart builds and reads', () {
    final n = channels.length;
    expect(sealed.length, c7HistorySyncBodyLength(n));
    expect(c7HistorySyncChannelCount(sealed.length), n);
    expect(c7Body0PaddedLength(n) + 124, outputs['body0_sealed_length']);
    expect(toHex(sha256(sealed)), outputs['sealed_body_sha256_hex']);
    expect(c7SortedChannels(channels.map((c) => c['channel_id'] as String)),
        [for (final c in channels) c['channel_id']]);
  });

  test('a live member opens body0, its VAP1 and every slot', () {
    final bindings = NativeCryptoBindings.open(requireNativeCryptoLibrary());
    final reference = C7Reference(
        hex(inputs['body_key_hex']), Uint8List.fromList(sha256(sealed)));
    final opened = c7OpenLiveParts(
      bindings: bindings,
      reference: reference,
      sealedBody: sealed,
      conversationId: conversation,
      channelId: null,
      senderDeviceId: sender,
      actionId: action,
    )!;
    expect(toHex(opened.paddedVap1), outputs['body0_padded_vap1_hex']);
    expect(toHex(opened.signature), outputs['post_signature_hex']);
    expect(opened.trailer, hasLength(c7SlotBytes * channels.length));
    // The signature covers channel "" and gen 0 at the message's epoch.
    final fields = c7PostSignedFields(
      communityId: community,
      channelId: '',
      actionId: action,
      groupId: conversation,
      epoch: inputs['message_epoch'] as int,
      senderDeviceId: sender,
      generation: 0,
      paddedVap1: opened.paddedVap1,
    );
    expect(toHex(fields), outputs['post_signed_fields_hex']);
    expect(
        bindings.c7Verify(
          domain: c7PostSignatureDomain,
          publicKey: hex(outputs['signing_public_key_hex']),
          message: fields,
          signature: opened.signature,
        ),
        isTrue);
    final outcome = AppPayloadCodec().classify(
      opened.paddedVap1,
      conversationId: conversation,
      senderDeviceId: sender,
      actionId: action,
      communityShared: true,
      channelId: null,
    );
    final payload = (outcome as DecodedAppPayload).payload;
    expect(payload.type, AppPayloadType.historySync);
    expect(payload.body['for_epoch'], inputs['for_epoch']);
    final slots = c7OpenSlots(
      bindings: bindings,
      body: payload.body,
      trailer: opened.trailer,
      communityId: community,
      conversationId: conversation,
      senderDeviceId: sender,
      actionId: action,
    )!;
    expect(slots.map((s) => s.channelId),
        [for (final c in channels) c['channel_id']]);
    for (var i = 0; i < slots.length; i++) {
      expect(toHex(slots[i].plain), channels[i]['slot_plain_hex']);
      expect(toHex(slots[i].key), channels[i]['key_hex']);
      final entry = C7GenerationEntry.decode(slots[i].entry);
      if (entry == null) {
        expect(slots[i].headIsZero, isTrue);
        continue;
      }
      expect(entry.keyCommit, c7ChkCommitOf(slots[i].key));
      final record = C7Record.decode(slots[i].head);
      expect(utf8.decode(record.channelId), slots[i].channelId);
      expect(entry.previousEpoch, greaterThanOrEqualTo(record.epoch));
      expect(c7ChkCommitOf(entry.previousKey!), record.chkCommit);
      expect(
          c7VerifyRecord(
              bindings, record, hex(outputs['signing_public_key_hex'])),
          isTrue);
    }
    // One damaged slot: the whole history_sync is not valid.
    final damaged = Uint8List.fromList(opened.trailer)..[c7SlotBytes + 50] ^= 1;
    expect(
        c7OpenSlots(
          bindings: bindings,
          body: payload.body,
          trailer: damaged,
          communityId: community,
          conversationId: conversation,
          senderDeviceId: sender,
          actionId: action,
        ),
        isNull);
  }, skip: nativeCryptoSkip());
}
