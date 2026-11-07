import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/crypto/app_payload.dart';
import 'package:private_messenger/crypto/link_preview.dart';
import 'package:private_messenger/crypto/message_format.dart';
import 'package:private_messenger/storage/encrypted_database.dart';
import 'package:private_messenger/storage/history_snapshot.dart';

/// A PNG-shaped byte string: the signature and an IHDR chunk are real, the
/// rest is filler. The receiver checks only the header before drawing.
Uint8List fakePng(int width, int height, {int extra = 40}) {
  final header = ByteData(25)
    ..setUint32(0, 13)
    ..setUint32(8, width)
    ..setUint32(12, height);
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
    ...List<int>.filled(extra, 7),
  ]);
}

const text = 'read https://github.com/ServesYouRice/veritra?utm_source=x now';
const url = 'https://github.com/ServesYouRice/veritra';

void main() {
  group('URL helpers', () {
    test('stripTracking removes campaign parameters and the fragment', () {
      expect(
        stripTracking('https://a.example/p?id=7&utm_medium=m&fbclid=z#top'),
        'https://a.example/p?id=7',
      );
      expect(stripTracking('https://a.example/p?UTM_x=1&gclid=2'),
          'https://a.example/p');
      expect(stripTracking('https://a.example/p?a=1&&b'),
          'https://a.example/p?a=1&b');
    });

    test('links are found in order and lose trailing punctuation', () {
      expect(
        linksInText('a (https://x.example/a_(b)). then http://y.example/c, ok'),
        <String>['https://x.example/a_(b)', 'http://y.example/c'],
      );
      expect(firstLinkInText('no link here'), isNull);
    });

    test('only public-looking https hosts are accepted', () {
      expect(parsePreviewUrl('https://en.wikipedia.org/wiki/X'), isNotNull);
      expect(parsePreviewUrl('https://example.com:443/x'), isNotNull);
      for (final bad in <String>[
        'http://example.com/',
        'https://example.com:8443/',
        'https://user:pw@example.com/',
        'https://127.0.0.1/',
        'https://10.0.0.5/',
        'https://[::1]/',
        'https://localhost/',
        'https://printer.local/',
        'https://intranet/',
        'https://bücher.example/',
        'https://example.com/a b',
        'https://2130706433/',
        '',
      ]) {
        expect(parsePreviewUrl(bad), isNull, reason: bad);
      }
      expect(parsePreviewUrl('https://a.example/${'x' * 2100}'), isNull);
    });

    test('preview text drops control and bidi characters and is bounded', () {
      expect(cleanPreviewText('  A‮b\u0000c \n\t d  ', 50), 'Abc d');
      expect(cleanPreviewText('​‮ ', 50), isNull);
      expect(cleanPreviewText(5, 50), isNull);
      // The cut never leaves half of a surrogate pair.
      expect(cleanPreviewText('ab😀cd', 3), 'ab');
      expect(cleanPreviewText('abcdef', 3), 'abc');
    });
  });

  group('wire form', () {
    Map<String, Object?> wire({String? link}) => <String, Object?>{
          'url': link ?? url,
          'title': 'Veritra',
          'description': 'A messenger',
        };

    test('a preview that matches a link in the text is kept', () {
      final preview = LinkPreview.fromWire(wire(), text: text)!;
      expect(preview.url, url);
      expect(preview.title, 'Veritra');
      expect(preview.host, 'github.com');
      expect(LinkPreview.fromWire(preview.toWire(), text: text)!.toWire(),
          preview.toWire());
    });

    test('a preview that does not name a link of the message is dropped', () {
      expect(
        LinkPreview.fromWire(wire(link: 'https://bank.example/'), text: text),
        isNull,
      );
      expect(LinkPreview.fromWire(wire(), text: 'no links'), isNull);
      expect(LinkPreview.fromWire(wire(), text: ''), isNull);
    });

    test('http, tracking, fragments, ports and odd shapes are dropped', () {
      const plain = 'see http://github.com/a and https://github.com/a?utm_x=1';
      for (final link in <String>[
        'http://github.com/a',
        'https://github.com/a?utm_x=1',
        'https://github.com/a#frag',
        'https://github.com:444/a',
      ]) {
        expect(LinkPreview.fromWire(wire(link: link), text: plain), isNull,
            reason: link);
      }
      expect(LinkPreview.fromWire('x', text: text), isNull);
      expect(LinkPreview.fromWire(<String, Object?>{'url': 5}, text: text),
          isNull);
      expect(
        LinkPreview.fromWire(<String, Object?>{'url': url}, text: text),
        isNull,
        reason: 'nothing to show',
      );
    });

    test('long fields are cut to their limits', () {
      final preview = LinkPreview.fromWire(
        <String, Object?>{
          'url': url,
          'title': 't' * 1000,
          'description': 'd' * 5000,
        },
        text: text,
      )!;
      expect(preview.title!.length, linkPreviewMaxTitleUnits);
      expect(preview.description!.length, linkPreviewMaxDescriptionUnits);
    });

    test('a bad thumbnail is dropped alone', () {
      Map<String, Object?> thumb(Uint8List png, {int? w, int? h}) =>
          <String, Object?>{
            'mime': 'image/png',
            'width': w ?? 64,
            'height': h ?? 48,
            'data': base64.encode(png),
          };
      LinkPreview? parse(Object? raw) =>
          LinkPreview.fromWire(<String, Object?>{...wire(), 'thumb': raw},
              text: text);
      expect(parse(thumb(fakePng(64, 48)))!.thumbnail!.width, 64);
      for (final bad in <Object?>[
        thumb(fakePng(64, 48), w: 65),
        thumb(fakePng(500, 48), w: 500),
        thumb(Uint8List.fromList(List<int>.filled(60, 1))),
        thumb(fakePng(64, 48, extra: linkPreviewMaxThumbnailBytes)),
        <String, Object?>{...thumb(fakePng(64, 48)), 'mime': 'image/jpeg'},
        <String, Object?>{...thumb(fakePng(64, 48)), 'data': '***'},
        'x',
      ]) {
        final preview = parse(bad)!;
        expect(preview.thumbnail, isNull);
        expect(preview.title, 'Veritra');
      }
    });

    test('the size budget drops the thumbnail first, then the preview', () {
      final preview = LinkPreview(
        url: url,
        title: 'Veritra',
        thumbnail: LinkPreviewThumbnail(
          png: fakePng(64, 48, extra: 12 * 1024),
          width: 64,
          height: 48,
        ),
      );
      final small = <String, Object?>{'text': text};
      expect(bodyWithLinkPreview(small, preview)['link_preview'],
          preview.toWire());

      final big = <String, Object?>{'text': 'x' * (40 * 1024)};
      final noThumb = bodyWithLinkPreview(big, preview)['link_preview'] as Map;
      expect(noThumb.containsKey('thumb'), isFalse);
      expect(noThumb['title'], 'Veritra');

      final huge = <String, Object?>{'text': 'x' * (48 * 1024)};
      expect(bodyWithLinkPreview(huge, preview), huge);
    });
  });

  group('payload', () {
    final codec = AppPayloadCodec(random: Random(3));
    const conversation = 'conv_1', device = 'dev_1', action = 'action_1';

    DecryptedAppPayload roundTrip(Uint8List padded) {
      final outcome = codec.classify(
        padded,
        conversationId: conversation,
        senderDeviceId: device,
        actionId: action,
      );
      return (outcome as DecodedAppPayload).payload;
    }

    Uint8List encode(AppPayloadType type, Map<String, Object?> body) =>
        codec.encode(
          type: type,
          conversationId: conversation,
          senderDeviceId: device,
          actionId: action,
          body: body,
        );

    Map<String, Object?> innerJson(Uint8List padded) {
      final length = ByteData.sublistView(padded).getUint32(4);
      return jsonDecode(utf8.decode(padded.sublist(8, 8 + length)))
          as Map<String, Object?>;
    }

    test('a link_preview body is written as v2 and survives classify', () {
      final preview = LinkPreview(url: url, title: 'Veritra');
      final body = bodyWithLinkPreview(
        <String, Object?>{'text': text},
        preview,
      );
      final padded = encode(AppPayloadType.text, body);
      expect(innerJson(padded)['v'], 2);
      final payload = roundTrip(padded);
      expect(payload.type, AppPayloadType.text);
      final decoration = messageDecoration(payload.body);
      expect(decoration['link_preview'], preview.toWire());
    });

    test('a plain text payload stays v1 and carries no preview', () {
      final padded = encode(
        AppPayloadType.text,
        <String, Object?>{'text': text},
      );
      expect(innerJson(padded)['v'], 1);
      expect(messageDecoration(roundTrip(padded).body), isEmpty);
    });

    test('a reply can carry a preview too', () {
      final body = <String, Object?>{
        ...bodyWithLinkPreview(
          <String, Object?>{'text': text},
          LinkPreview(url: url, description: 'A messenger'),
        ),
        'reply_to_id': 'msg_1',
      };
      final payload = roundTrip(encode(AppPayloadType.reply, body));
      expect(messageDecoration(payload.body)['link_preview'], isNotNull);
    });

    test('a received preview for another site never reaches the row', () {
      final body = <String, Object?>{
        'text': text,
        'link_preview': <String, Object?>{
          'url': 'https://bank.example/login',
          'title': 'Bank',
        },
      };
      final payload = roundTrip(encode(AppPayloadType.text, body));
      // The message itself is still valid; only the card disappears.
      expect(payload.body['text'], text);
      expect(messageDecoration(payload.body), isEmpty);
    });

    test('a preview keeps formatting and mentions in the decoration', () {
      final decoration = messageDecoration(<String, Object?>{
        'text': text,
        'entities': <Object?>[
          <String, Object?>{'type': 'bold', 'offset': 0, 'length': 4},
        ],
        'link_preview': <String, Object?>{'url': url, 'title': 'Veritra'},
      });
      expect(
        decoration.keys,
        containsAll(<String>['entities', 'link_preview']),
      );
    });
  });

  group('history snapshot', () {
    LocalMessage row(String? formatJson) => LocalMessage(
          key: 'dev:a',
          conversationId: 'conv',
          senderAccountId: 'bob',
          senderDeviceId: 'dev',
          kind: 'text',
          body: text,
          createdAt: 1000,
          state: 'received',
          formatJson: formatJson,
          senderHidden: false,
        );

    HistorySnapshot snapshot(LocalMessage message) => HistorySnapshot(
          accountId: 'alice',
          sourceDeviceId: 'dev',
          counter: 1,
          createdAt: 2000,
          conversations: const <HistoryConversation>[
            HistoryConversation('conv', 'dm', title: 'historical'),
          ],
          messages: <LocalMessage>[message],
          reactions: const <LocalMessageReaction>[],
          pins: const <LocalPin>[],
          starred: const <String, int>{},
          preferences: const <LocalConversationPref>[],
        );

    test('a stored preview survives an export and import', () {
      final preview = LinkPreview(
        url: url,
        title: 'Veritra',
        thumbnail: LinkPreviewThumbnail(
          png: fakePng(64, 48),
          width: 64,
          height: 48,
        ),
      );
      final stored = jsonEncode(<String, Object?>{
        'link_preview': preview.toWire(),
      });
      final copy = HistorySnapshot.decode(snapshot(row(stored)).encode());
      final back = jsonDecode(copy.messages.single.formatJson!) as Map;
      expect(back['link_preview'], preview.toWire());
    });

    test('an import drops a preview that no longer matches the text', () {
      final stored = jsonEncode(<String, Object?>{
        'link_preview': <String, Object?>{
          'url': 'https://bank.example/',
          'title': 'Bank',
        },
        'entities': <Object?>[
          <String, Object?>{'type': 'bold', 'offset': 0, 'length': 4},
        ],
      });
      final copy = HistorySnapshot.decode(snapshot(row(stored)).encode());
      final back = jsonDecode(copy.messages.single.formatJson!) as Map;
      expect(back.containsKey('link_preview'), isFalse);
      expect(back.containsKey('entities'), isTrue);
    });
  });
}
