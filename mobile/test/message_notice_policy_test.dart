import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/push/message_notice_policy.dart';
import 'package:private_messenger/storage/encrypted_database.dart';

void main() {
  final now = DateTime.utc(2026, 10, 27, 12);
  const session = Session(
      baseUrl: 'https://example.test',
      token: 'fixture',
      accountId: 'me',
      deviceId: 'my_device');
  final envelope = ReceivedMessageEnvelope(
      id: 'server_message',
      conversationId: 'chat',
      senderAccountId: 'friend',
      senderDeviceId: 'their_device',
      idempotencyKey: 'action',
      ciphertext: const [1],
      cryptoProtocol: 'mls10-openmls-v1',
      createdAt: now);
  final local = LocalMessage(
      key: 'their_device:action',
      serverMessageId: 'server_message',
      conversationId: 'chat',
      senderAccountId: 'friend',
      senderDeviceId: 'their_device',
      kind: LocalMessageKind.text,
      body: '@me hello',
      createdAt: now.millisecondsSinceEpoch,
      state: LocalMessageState.received,
      formatJson: jsonEncode({
        'mentions': [
          {'account_id': 'me', 'offset': 0, 'length': 3}
        ]
      }));
  MessageNoticeCandidate? decide(
          {LocalMessage? row,
          bool blocked = false,
          bool accepted = true,
          DateTime? at,
          ReceivedMessageEnvelope? event,
          Session identity = session}) =>
      messageNoticeCandidate(
          session: identity,
          envelope: event ?? envelope,
          message: row ?? local,
          now: at ?? now,
          blocked: blocked,
          conversationAccepted: accepted);

  test('only an authenticated valid-range account mention overrides mute', () {
    final mention = decide()!;
    expect(mention.mentionsAccount, isTrue);
    expect(mention.allowedWhenMuted(mentionsInMutedChats: true), isTrue);
    expect(mention.allowedWhenMuted(mentionsInMutedChats: false), isFalse);
    for (final decoration in [
      null,
      jsonEncode({
        'mentions': [
          {'account_id': 'me', 'offset': 99, 'length': 3}
        ]
      }),
      jsonEncode({
        'mentions': [
          {'account_id': 'other', 'offset': 0, 'length': 3}
        ]
      }),
      jsonEncode({
        'mentions': [
          {'account_id': 'me', 'offset': 4, 'length': 3}
        ]
      }),
    ]) {
      final ordinary =
          decide(row: local.copyWith(formatJson: Value(decoration)))!;
      expect(ordinary.mentionsAccount, isFalse);
      expect(ordinary.allowedWhenMuted(mentionsInMutedChats: true), isFalse);
    }
  });

  test('blocks, requests and absent identity fail closed', () {
    expect(decide(blocked: true), isNull);
    expect(decide(accepted: false), isNull);
    expect(
        decide(
            identity: const Session(
                baseUrl: 'https://example.test', token: 'fixture')),
        isNull);
    expect(
        decide(
            identity: const Session(
                baseUrl: 'https://example.test',
                token: 'fixture',
                accountId: 'friend',
                deviceId: 'different')),
        isNull);
  });

  test('actions, hidden or changed rows and expired content never notify', () {
    for (final kind in [
      LocalMessageKind.action,
      LocalMessageKind.attachment,
      LocalMessageKind.invalid,
      LocalMessageKind.unverifiable,
      LocalMessageKind.unsupported
    ]) {
      expect(decide(row: local.copyWith(kind: kind)), isNull, reason: kind);
    }
    for (final row in [
      local.copyWith(hiddenAt: const Value(1)),
      local.copyWith(deletedAt: const Value(1)),
      local.copyWith(editedAt: const Value(1)),
      local.copyWith(senderHidden: const Value(true)),
      local.copyWith(body: const Value(null)),
      local.copyWith(expiresAt: Value(now.millisecondsSinceEpoch)),
    ]) {
      expect(decide(row: row), isNull);
    }
    expect(decide(at: now.add(const Duration(minutes: 11))), isNull);
  });

  test('a matching server ID alone cannot substitute sender or context', () {
    for (final row in [
      local.copyWith(key: 'their_device:other'),
      local.copyWith(conversationId: 'another_chat'),
      local.copyWith(senderAccountId: 'stranger'),
      local.copyWith(senderDeviceId: 'another_device')
    ]) {
      expect(decide(row: row), isNull);
    }
  });

  test(
      'copied history and substituted creation times cannot become new notices',
      () {
    expect(
        decide(row: local.copyWith(state: LocalMessageState.restored)), isNull);
    expect(decide(row: local.copyWith(createdAt: local.createdAt - 1)), isNull);
    expect(decide(at: now.subtract(const Duration(minutes: 3))), isNull);
  });

  test('phone attachment notices are generic and never override a mute', () {
    final result = messageNoticeCandidate(
        session: session,
        envelope: envelope,
        message: local.copyWith(kind: LocalMessageKind.attachment),
        now: now,
        blocked: false,
        conversationAccepted: true,
        includeGenericAttachments: true)!;
    expect(result.text, isEmpty);
    expect(result.mentionsAccount, isFalse);
    expect(result.allowedWhenMuted(mentionsInMutedChats: true), isFalse);
  });

  test('spoiler preview is derived from valid entities, not raw JSON text', () {
    final spoiler = decide(
        row: local.copyWith(
            formatJson: Value(jsonEncode({
      'entities': [
        {'type': 'spoiler', 'offset': 0, 'length': 3}
      ]
    }))))!;
    expect(spoiler.concealsSpoiler, isTrue);
    final invalid = decide(
        row: local.copyWith(
            formatJson: Value(jsonEncode({
      'entities': [
        {'type': 'spoiler', 'offset': 99, 'length': 3}
      ]
    }))))!;
    expect(invalid.concealsSpoiler, isFalse);
  });
}
