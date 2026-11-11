import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/report_key_announcer.dart';
import 'package:private_messenger/crypto/report_key_announcement.dart';
import 'package:private_messenger/storage/local_store.dart';

/// C6: when a moderator's device announces its report key in a community's
/// shared group (docs/designs/C6-reports-franking.md, "Moderator keys over
/// MLS"). No MLS here: the send and the server's listing are injected.

const _community = 'comm_1';
const _group = 'conv_shared';

void main() {
  final key = List<int>.filled(32, 3);
  final encoded = base64Encode(key);
  late MemoryLocalStore store;
  late List<String> sent;
  late Map<String, List<int>?> listed;
  late Map<String, String> unlisted;
  late DateTime now;
  var sendOk = true;
  var lookups = 0;

  ReportKeyAnnouncer announcer() => ReportKeyAnnouncer(
        store: store,
        listedKey: (communityId) async {
          lookups++;
          return listed[communityId];
        },
        send: (group, key) async {
          if (!sendOk) return false;
          sent.add('$group:$key');
          return true;
        },
        clock: () => now,
      );

  Future<int> run({bool Function()? active}) => announcer().run(
      key: encoded,
      moderated: const [(_community, _group)],
      unlisted: unlisted,
      active: active);

  setUp(() {
    store = MemoryLocalStore();
    sent = [];
    listed = {_community: key};
    unlisted = {};
    now = DateTime.utc(2026, 11, 11, 12);
    sendOk = true;
    lookups = 0;
  });

  test('announces once, then only to answer a new request', () async {
    expect(await run(), 1);
    expect(sent, ['$_group:$encoded']);
    expect(await run(), 0, reason: 'already announced');

    // A request naming this account arrives (committed with the MLS state).
    await store.saveSetting(reportKeyRequestSetting(_group), '17');
    expect(await run(), 0, reason: 'too soon after the last announcement');
    now = now.add(reportKeyAnswerSpacing);
    expect(await run(), 1);
    expect(await run(), 0, reason: 'that request is answered');
    now = now.add(reportKeyAnswerSpacing);
    await store.saveSetting(reportKeyRequestSetting(_group), '18');
    expect(await run(), 1);
    expect(sent, hasLength(3));
  });

  test(
      'a key the server does not list is never announced, nor looked up '
      'again for the same key', () async {
    // Another device of this account replaced the key.
    listed[_community] = List<int>.filled(32, 9);
    expect(await run(), 0);
    expect(unlisted, {_group: encoded});
    expect(await run(), 0);
    expect(lookups, 1);
    // Nothing published in this community at all.
    unlisted.clear();
    listed[_community] = null;
    expect(await run(), 0);
    expect(sent, isEmpty);
  });

  test('a send that queued nothing is tried again', () async {
    sendOk = false;
    expect(await run(), 0);
    expect(await store.loadSetting(reportKeySentSetting(_group)), isNull);
    sendOk = true;
    expect(await run(), 1);
  });

  test('a new key on this device is announced at once', () async {
    expect(await run(), 1);
    final other = List<int>.filled(32, 5);
    listed[_community] = other;
    expect(
        await announcer().run(
            key: base64Encode(other),
            moderated: const [(_community, _group)],
            unlisted: unlisted),
        1);
    expect(sent.last, '$_group:${base64Encode(other)}');
  });

  test('an ended session stops the pass', () async {
    expect(await run(active: () => false), 0);
    expect(sent, isEmpty);
  });
}
