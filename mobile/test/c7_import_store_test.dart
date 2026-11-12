import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/c7_import.dart';
import 'package:private_messenger/storage/encrypted_database.dart';

/// C7 import on the encrypted database (decision 10): "Load earlier posts"
/// pages backward, so an author's delete or edit can arrive one page before
/// its target. Both wait as deferred effects and apply when the target
/// comes; a re-run adds nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = 'chan_1';
  InsertMessageEffect post(String key, String text, {String? body}) =>
      InsertMessageEffect(
        key: 'dev_bob:$key',
        serverMessageId: 'hist_$key',
        conversationId: 'conv_shared',
        senderAccountId: 'acct_bob',
        senderDeviceId: 'dev_bob',
        kind:
            body == null ? LocalMessageKind.text : LocalMessageKind.attachment,
        body: body ?? text,
        createdAt: 1000,
        state: LocalMessageState.received,
        channelId: channel,
        c7Gen: 'ab' * 32,
      );
  InsertMessageEffect action(String key) => InsertMessageEffect(
        key: 'dev_bob:$key',
        serverMessageId: 'hist_$key',
        conversationId: 'conv_shared',
        senderAccountId: 'acct_bob',
        senderDeviceId: 'dev_bob',
        kind: LocalMessageKind.action,
        createdAt: 2000,
        state: LocalMessageState.received,
        channelId: channel,
      );

  test(
      'a delete and an edit imported before their targets apply when the '
      'targets come, and nothing doubles', () async {
    final database = EncryptedLocalDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.writeSessionJson(jsonEncode(<String, Object?>{
      'base_url': 'https://example.test',
      'token': 'token',
      'account_id': 'acct_dave',
      'device_id': 'dev_dave',
    }));
    // Page one (newest): the author's delete and edit, without targets.
    final newer = <MessageEffect>[
      action('del'),
      const DeleteMessageEffect(
        targetKey: 'dev_bob:gone',
        deleterAccountId: 'acct_bob',
        at: 2000,
        conversationId: 'conv_shared',
        channelId: channel,
      ),
      action('edit'),
      const EditMessageEffect(
        targetKey: 'dev_bob:kept',
        editorAccountId: 'acct_bob',
        body: 'kept, edited',
        at: 2000,
        conversationId: 'conv_shared',
        channelId: channel,
      ),
    ];
    await database.importC7History(newer);
    // Page two (older): the targets, and a pre-join attachment.
    final older = <MessageEffect>[
      post('gone', 'deleted later'),
      post('kept', 'kept'),
      post('file', '', body: c7HiddenAttachmentBody),
    ];
    await database.importC7History(older);
    // The same pages again (a crash before the app saw the result).
    await database.importC7History(newer);
    await database.importC7History(older);
    final rows = <String, LocalMessage>{
      for (final row in await database.readMessages('conv_shared'))
        row.key: row,
    };
    final gone = rows['dev_bob:gone'];
    expect(gone == null || gone.deletedAt != null, isTrue,
        reason: 'the deleted post never shows');
    expect(gone?.body, anyOf(isNull, isEmpty));
    expect(rows['dev_bob:kept']!.body, 'kept, edited');
    expect(rows['dev_bob:kept']!.c7Gen, 'ab' * 32);
    expect(rows['dev_bob:kept']!.state, LocalMessageState.received);
    expect(rows['dev_bob:file']!.body, c7HiddenAttachmentBody);
    expect(rows.keys.where((key) => key == 'dev_bob:kept'), hasLength(1));
    expect(rows, hasLength(5));
  });
}
