import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/models.dart';
import 'package:private_messenger/crypto/link_preview.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';
import 'package:private_messenger/storage/local_store.dart';

/// B2 stores up to about 22 KiB of base64 thumbnail in every previewed row's
/// `format_json`. The K2 snapshot and the backup both cap at 64 MiB, so a long
/// history with previews must export without them: whole `link_preview` key
/// out, nothing else changed.

const _cap = 64 * 1024 * 1024;
const _rows = 3500;
const _text = 'read https://github.com/ServesYouRice/veritra now';

/// A PNG-shaped byte string at the thumbnail limit: a real signature and
/// IHDR, filler after it.
Uint8List _png() {
  final header = ByteData(25)
    ..setUint32(0, 13)
    ..setUint32(8, 160)
    ..setUint32(12, 120);
  header.setUint8(4, 0x49);
  header.setUint8(5, 0x48);
  header.setUint8(6, 0x44);
  header.setUint8(7, 0x52);
  return Uint8List.fromList(<int>[
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    ...header.buffer.asUint8List(),
    ...List<int>.filled(linkPreviewMaxThumbnailBytes - 33, 7),
  ]);
}

/// Every second row also carries a bold entity, which must survive.
String _format(int index, Map<String, Object?> preview) {
  return jsonEncode(<String, Object?>{
    if (index.isEven)
      'entities': <Object?>[
        <String, Object?>{'type': 'bold', 'offset': 0, 'length': 4},
      ],
    'link_preview': preview,
  });
}

List<LocalMessage> _history() {
  final preview = LinkPreview(
    url: 'https://github.com/ServesYouRice/veritra',
    title: 'Veritra',
    thumbnail: LinkPreviewThumbnail(png: _png(), width: 160, height: 120),
  ).toWire();
  return <LocalMessage>[
    for (var i = 0; i < _rows; i++)
      LocalMessage(
        key: 'dev:m$i',
        conversationId: 'conv',
        senderAccountId: 'bob',
        senderDeviceId: 'dev',
        kind: 'text',
        body: _text,
        createdAt: 1000 + i,
        state: 'received',
        formatJson: _format(i, preview),
        senderHidden: false,
      ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rows = _history();
  final rawBytes =
      rows.fold<int>(0, (sum, m) => sum + utf8.encode(m.formatJson!).length);

  test('the fixture really is over the cap without the fix', () {
    expect(rawBytes, greaterThan(_cap));
  });

  test('a K2 snapshot of thousands of previewed rows stays under the cap', () {
    final snapshot = HistorySnapshot(
      accountId: 'alice',
      sourceDeviceId: 'dev',
      counter: 1,
      createdAt: 2000,
      conversations: const <HistoryConversation>[
        HistoryConversation('conv', 'dm', title: 'historical'),
      ],
      messages: rows,
      reactions: const <LocalMessageReaction>[],
      pins: const <LocalPin>[],
      starred: const <String, int>{},
      preferences: const <LocalConversationPref>[],
    );
    final bytes = snapshot.encode();
    expect(bytes.length, lessThan(_cap));
    expect(utf8.decode(bytes), isNot(contains('link_preview')));
    final back = HistorySnapshot.decode(bytes).messages;
    expect(back.length, _rows);
    expect(back[0].formatJson, contains('"entities"'));
    expect(back[1].formatJson, isNull);
  });

  test(
      'a stored history snapshot of thousands of previewed rows stays under the cap',
      () async {
    final store = MemoryLocalStore();
    await store.saveSession(const Session(
      baseUrl: 'https://chat.example.org',
      token: 'tok',
      accountId: 'acct_1',
      deviceId: 'dev_own',
      deviceSecret: 'secret',
    ));
    StoredCryptoState state(int counter) => StoredCryptoState(
        counter: counter,
        stateKey: List<int>.filled(32, 7),
        sealedState: <int>[counter, 2, 3]);
    await store.saveCryptoState(state(1), 10);
    await store.saveSnapshot(
        <Conversation>[Conversation(id: 'conv', kind: 'dm', title: 'Chat')],
        const <String, List<ReceivedMessageEnvelope>>{},
        10);
    final effects = <MessageEffect>[
      for (final m in rows)
        InsertMessageEffect(
          key: m.key,
          serverMessageId: 'srv_${m.key}',
          conversationId: m.conversationId,
          senderAccountId: m.senderAccountId,
          senderDeviceId: m.senderDeviceId,
          kind: m.kind,
          body: m.body,
          createdAt: m.createdAt,
          state: m.state,
          formatJson: m.formatJson,
        ),
    ];
    await store.commitMlsTransition(MlsStateTransition(
      messageId: 'application:11:m',
      conversationId: 'conv',
      expectedCounter: 1,
      expectedCursor: 10,
      state: state(2),
      cursor: 11,
      messageEffects: effects,
    ));
    final backup = await store.exportHistorySnapshot();
    expect(backup.length, lessThan(_cap));
    expect(utf8.decode(backup), isNot(contains('link_preview')));
    final restored = HistorySnapshot.decode(backup).messages;
    expect(restored.length, _rows);
    final byKey = {for (final m in restored) m.key: m};
    expect(byKey['dev:m0']!.formatJson, contains('"entities"'));
    expect(byKey['dev:m1']!.formatJson, isNull);
    expect(byKey['dev:m1']!.body, _text);
  });
}
