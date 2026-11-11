import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/report_key_announcement.dart';
import 'package:private_messenger/storage/device_list_records.dart';

/// C6: moderator report keys authenticated over MLS
/// (docs/designs/C6-reports-franking.md, "Moderator keys over MLS"). The
/// payload rules and the receive decision, without native crypto.

const _group = 'conv_shared';
const _self = 'acct_reporter';
const _moderator = 'acct_mod';

String _key([int fill = 7]) => base64Encode(List<int>.filled(32, fill));

DecryptedAppPayload _announcement(Map<String, Object?> body) =>
    DecryptedAppPayload(
        type: AppPayloadType.reportKey, actionId: 'a', body: body);

DecryptedAppPayload _request(List<Object?> accounts) => DecryptedAppPayload(
    type: AppPayloadType.reportKeyRequest,
    actionId: 'a',
    body: {'accounts': accounts});

Map<String, String?> _settings(
  DecryptedAppPayload payload, {
  String sender = _moderator,
  bool recordGroup = true,
  LeafVerdict? verdict = LeafVerdict.approved,
  String? self = _self,
  int event = 41,
}) =>
    reportKeySettingsFor(payload,
        conversationId: _group,
        senderAccountId: sender,
        isRecordGroup: recordGroup,
        verdict: verdict,
        selfAccountId: self,
        syncEventId: event);

void main() {
  group('wire', () {
    final codec = AppPayloadCodec();

    AppPayloadOutcome roundTrip(
            AppPayloadType type, Map<String, Object?> body) =>
        codec.classify(
          codec.encode(
            type: type,
            conversationId: _group,
            senderDeviceId: 'dev_1',
            actionId: 'act_1',
            body: body,
            channelId: 'chan_1',
            hidden: true,
          ),
          conversationId: _group,
          senderDeviceId: 'dev_1',
          actionId: 'act_1',
          channelId: 'chan_1',
          communityShared: true,
        );

    test('names, hidden, never franked', () {
      expect(AppPayloadType.reportKey.wireName, 'report_key');
      expect(AppPayloadType.reportKeyRequest.wireName, 'report_key_request');
      for (final type in reportKeyPayloadTypes) {
        expect(type.sendsHidden, isTrue, reason: type.name);
        expect(FrankingPolicy.unfrankedPayloadTypes, contains(type.name));
      }
    });

    test('a valid announcement and request round-trip in the shared group', () {
      final key = roundTrip(AppPayloadType.reportKey, {'key': _key()});
      expect(key, isA<DecodedAppPayload>());
      expect((key as DecodedAppPayload).payload.type, AppPayloadType.reportKey);
      final request = roundTrip(AppPayloadType.reportKeyRequest, {
        'accounts': [_moderator, 'acct_mod2']
      });
      expect((request as DecodedAppPayload).payload.type,
          AppPayloadType.reportKeyRequest);
    });

    test('malformed bodies are refused', () {
      for (final body in <Map<String, Object?>>[
        {},
        {'key': base64Encode(List<int>.filled(31, 1))},
        {'key': base64Encode(List<int>.filled(33, 1))},
        // Not canonical: no padding.
        {'key': _key().replaceAll('=', '')},
        {'key': 'not base64!'},
        {'key': _key(), 'extra': 1},
      ]) {
        expect(isValidReportKeyBody(body), isFalse, reason: '$body');
        expect(() => roundTrip(AppPayloadType.reportKey, body),
            throwsFormatException);
      }
      for (final body in <Map<String, Object?>>[
        {},
        {'accounts': <String>[]},
        {
          'accounts': [_moderator, _moderator]
        },
        {
          'accounts': ['']
        },
        {
          'accounts': ['a' * 129]
        },
        {
          'accounts': [1]
        },
        {
          'accounts':
              List.generate(maxReportKeyRequestAccounts + 1, (i) => 'acct_$i')
        },
        {
          'accounts': [_moderator],
          'extra': true
        },
      ]) {
        expect(isValidReportKeyRequestBody(body), isFalse, reason: '$body');
      }
      expect(
          isValidReportKeyRequestBody({
            'accounts':
                List.generate(maxReportKeyRequestAccounts, (i) => 'acct_$i')
          }),
          isTrue);
    });
  });

  group('receive', () {
    test('an approved leaf in the record group sets its own account key', () {
      expect(_settings(_announcement({'key': _key()})), {
        reportKeyAnnouncementSetting(_group, _moderator): _key(),
      });
    });

    test('the key is filed under the MLS sender, never another account', () {
      final settings =
          _settings(_announcement({'key': _key()}), sender: 'acct_other');
      expect(settings.keys.single,
          reportKeyAnnouncementSetting(_group, 'acct_other'));
    });

    test('nothing is kept outside a record group or from an unapproved leaf',
        () {
      final payload = _announcement({'key': _key()});
      expect(_settings(payload, recordGroup: false), isEmpty);
      for (final verdict in <LeafVerdict?>[
        null,
        LeafVerdict.removed,
        LeafVerdict.unapproved,
        LeafVerdict.checking,
      ]) {
        expect(_settings(payload, verdict: verdict), isEmpty,
            reason: '$verdict');
      }
      expect(_settings(payload, sender: ''), isEmpty);
    });

    test('a request is kept only when it names this account', () {
      expect(_settings(_request([_self, _moderator]), event: 99), {
        reportKeyRequestSetting(_group): '99',
      });
      expect(_settings(_request([_moderator])), isEmpty);
      expect(_settings(_request([_self]), sender: _self), isEmpty,
          reason: 'never from this account itself');
      expect(_settings(_request([_self]), self: null), isEmpty);
      expect(_settings(_request([_self]), verdict: LeafVerdict.unapproved),
          isEmpty);
    });

    test('settings are keyed by group and escaped account', () {
      expect(reportKeyAnnouncementSetting('g', 'a.b:c'),
          'c6.report_key.g.a.b%3Ac');
      expect(reportKeyAnnouncementSetting('g1', 'a'),
          isNot(reportKeyAnnouncementSetting('g2', 'a')));
    });
  });

  group('announcing', () {
    final now = DateTime.utc(2026, 11, 11, 12);
    final at = now.millisecondsSinceEpoch;

    test('due when never announced, or the key changed', () {
      expect(
          reportKeyAnnouncementDue(
              key: _key(), sent: null, request: null, now: now),
          isTrue);
      expect(
          reportKeyAnnouncementDue(
              key: _key(2),
              sent: ReportKeySent(key: _key(1), atMs: at),
              request: null,
              now: now),
          isTrue);
      expect(
          reportKeyAnnouncementDue(
              key: _key(),
              sent: ReportKeySent(key: _key(), atMs: at),
              request: null,
              now: now),
          isFalse);
    });

    test('a new request is answered once, after the spacing', () {
      final sent = ReportKeySent(key: _key(), atMs: at, answered: '10');
      bool due(String? request, Duration later) => reportKeyAnnouncementDue(
          key: _key(), sent: sent, request: request, now: now.add(later));
      expect(due('10', const Duration(days: 1)), isFalse,
          reason: 'already answered');
      expect(due('11', Duration.zero), isFalse, reason: 'too soon');
      expect(due('11', reportKeyAnswerSpacing), isTrue);
    });

    test('a request is due when never asked, the set changed, or a week passed',
        () {
      final asked = ReportKeyAsked(accounts: const ['a', 'b'], atMs: at);
      bool due(List<String> missing, Duration later) => reportKeyRequestDue(
          missing: missing, asked: asked, now: now.add(later));
      expect(reportKeyRequestDue(missing: const ['a'], asked: null, now: now),
          isTrue);
      expect(due(const [], Duration.zero), isFalse);
      expect(due(const ['a', 'b'], const Duration(days: 1)), isFalse);
      expect(due(const ['a'], Duration.zero), isTrue);
      expect(due(const ['a', 'c'], Duration.zero), isTrue);
      expect(due(const ['a', 'b'], reportKeyReaskInterval), isTrue);
      final back = ReportKeyAsked.decode(asked.encode())!;
      expect(back.accounts, ['a', 'b']);
      expect(back.atMs, at);
      expect(ReportKeyAsked.decode('{}'), isNull);
    });

    test('the sent record survives encoding', () {
      final sent = ReportKeySent(key: _key(), atMs: at, answered: '7');
      final back = ReportKeySent.decode(sent.encode())!;
      expect((back.key, back.atMs, back.answered), (_key(), at, '7'));
      expect(ReportKeySent.decode('nonsense'), isNull);
      expect(ReportKeySent.decode(null), isNull);
    });
  });
}
