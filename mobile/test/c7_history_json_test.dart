import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/crypto_service.dart';

// The history and former-member rows exactly as the server writes them
// (server/internal/storage/c7_history_json_test.go marshals its structs to
// the same text).
const _historyRow =
    '{"message_id":"msg_1","sender_device_id":"dev_1","action_id":"act_1","channel_id":"chan_1","created_at":"2026-11-12T10:00:00.123456789Z","epoch":7,"body":"AQID"}';
const _groupLevelRow =
    '{"message_id":"msg_2","sender_device_id":"dev_1","action_id":"act_2","created_at":"2026-11-12T10:00:00Z","body":"BAU="}';
const _formerMemberKey =
    '{"device_id":"dev_9","account_id":"acct_9","signing_key":"BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=","revoked":true}';

Map<String, Object?> _json(String text) =>
    Map<String, Object?>.from(jsonDecode(text) as Map);

void main() {
  test('a channel row parses with its route epoch and body', () {
    final row = C7HistoryRow.fromJson(_json(_historyRow));
    expect(row.messageId, 'msg_1');
    expect(row.senderDeviceId, 'dev_1');
    expect(row.actionId, 'act_1');
    expect(row.channelId, 'chan_1');
    expect(row.epoch, 7);
    expect(row.body, <int>[1, 2, 3]);
    expect(row.createdAt.isUtc, isTrue);
    expect(row.createdAt.year, 2026);
  });

  test('a group-level row names no channel and may name no epoch', () {
    final row = C7HistoryRow.fromJson(_json(_groupLevelRow));
    expect(row.channelId, isNull);
    expect(row.epoch, isNull);
    expect(row.body, <int>[4, 5]);
  });

  test('a former-member key parses; a malformed one is null', () {
    final key = C7FormerKey.tryParse(_json(_formerMemberKey))!;
    expect(key.deviceId, 'dev_9');
    expect(key.accountId, 'acct_9');
    expect(key.signingKey, List<int>.filled(32, 7));
    expect(
        C7FormerKey.tryParse(<String, Object?>{
          'device_id': 'dev_9',
          'account_id': 'acct_9',
          'signing_key': base64Encode(<int>[1, 2]),
        }),
        isNull);
  });

  test('a malformed row is refused', () {
    final bad = _json(_historyRow)..['epoch'] = '7';
    expect(() => C7HistoryRow.fromJson(bad), throwsFormatException);
  });
}
