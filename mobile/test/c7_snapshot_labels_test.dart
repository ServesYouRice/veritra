import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/c7_import.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';

/// C7 imported rows in K1 backups and K2 link bundles: a pre-join
/// attachment placeholder (owner answer Q2) travels as itself instead of
/// breaking the export.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const conversation = 'conv_shared';
  const channel = 'chan_1';
  final now = DateTime.now().millisecondsSinceEpoch;
  const session = Session(
      baseUrl: 'https://example.test',
      token: 'token',
      accountId: 'acct_dave',
      deviceId: 'dev_dave');
  final shared = Conversation(
      id: conversation, kind: 'community_shared', communityId: 'comm_1');

  InsertMessageEffect post(String key, {String? body}) => InsertMessageEffect(
        key: 'dev_bob:$key',
        serverMessageId: 'hist_$key',
        conversationId: conversation,
        senderAccountId: 'acct_bob',
        senderDeviceId: 'dev_bob',
        kind:
            body == null ? LocalMessageKind.text : LocalMessageKind.attachment,
        body: body ?? key,
        createdAt: now - 1000,
        state: LocalMessageState.received,
        channelId: channel,
      );

  Future<MemoryLocalStore> storeWith(List<MessageEffect> effects) async {
    final store = MemoryLocalStore();
    await store.saveSession(session);
    await store.saveSnapshot(
        [shared], const <String, List<ReceivedMessageEnvelope>>{}, 0);
    if (effects.isNotEmpty) await store.importC7History(effects);
    return store;
  }

  HistoryImportContext context(HistorySnapshot snapshot) =>
      HistoryImportContext(
          origin: 'https://example.test',
          accountId: 'acct_dave',
          sourceDeviceId: 'dev_dave',
          recipientDeviceId: 'dev_new',
          transferId: 'transfer',
          snapshotCounter: snapshot.counter,
          snapshotCreatedAt: snapshot.createdAt,
          digest: 'a' * 64);

  test(
      'an imported pre-join attachment placeholder survives the export and '
      'the restore on another device', () async {
    final source = await storeWith(<MessageEffect>[
      post('text'),
      post('file', body: c7HiddenAttachmentBody),
    ]);
    final bytes = await source.exportHistorySnapshot();
    final snapshot = HistorySnapshot.decode(bytes);
    final file = snapshot.messages.firstWhere((m) => m.key == 'dev_bob:file');
    expect(file.kind, LocalMessageKind.attachment);
    expect(file.body, c7HiddenAttachmentBody);
    // K1 backups take the same export with disappearing messages left out.
    HistorySnapshot.decode(
        await source.exportHistorySnapshot(omitDisappearing: true));

    final target = MemoryLocalStore();
    await target.saveSession(const Session(
        baseUrl: 'https://example.test',
        token: 'token',
        accountId: 'acct_dave',
        deviceId: 'dev_new'));
    await target.importHistorySnapshot(bytes, context(snapshot));
    final restored = {
      for (final m in await target.loadMessages(conversation)) m.key: m,
    };
    expect(restored['dev_bob:file']!.body, c7HiddenAttachmentBody);
    expect(restored['dev_bob:text']!.body, 'text');
  });

  test('any other non-list attachment body is still refused', () async {
    final source = await storeWith(<MessageEffect>[
      post('file', body: '{"c7":"something_else"}'),
    ]);
    await expectLater(source.exportHistorySnapshot(), throwsFormatException);
  });
}
