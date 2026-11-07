import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/core/link_preview_html.dart';
import 'package:private_messenger/core/link_preview_service.dart';
import 'package:private_messenger/crypto/link_preview.dart';

const page = '''
<!doctype html><html><head>
<title>Fallback title</title>
<meta name="description" content="Fallback description">
<meta property="og:title" content="  Veritra &amp; friends ">
<meta property="og:description" content="A private messenger">
<meta property="og:image" content="/img/card.png">
</head><body>ignored</body></html>
''';

LinkPreviewResponse html(String body, {int status = 200, String? type}) =>
    LinkPreviewResponse(
      status: status,
      body: Uint8List.fromList(utf8.encode(body)),
      contentType: type ?? 'text/html',
    );

LinkPreviewResponse redirect(String to) => LinkPreviewResponse(
      status: 302,
      body: Uint8List(0),
      location: to,
    );

LinkPreviewResponse image() => LinkPreviewResponse(
      status: 200,
      body: Uint8List.fromList(<int>[1, 2, 3]),
      contentType: 'image/png',
    );

class FakeTransport implements LinkPreviewTransport {
  FakeTransport(this.routes);

  final Map<String, LinkPreviewResponse> routes;
  final List<String> requests = <String>[];
  Object? failure;

  @override
  Future<LinkPreviewResponse> get(
    Uri uri, {
    required int maxBytes,
    required String accept,
    required Duration timeout,
  }) async {
    requests.add(uri.toString());
    if (failure != null) throw failure!;
    return routes[uri.toString()] ?? html('', status: 404);
  }
}

Future<LinkPreviewThumbnail?> fakeEncoder(Uint8List bytes) async =>
    bytes.length == 3
        ? LinkPreviewThumbnail(png: Uint8List(40), width: 8, height: 8)
        : null;

void main() {
  const link = 'https://github.com/ServesYouRice/veritra';

  group('parsing', () {
    test('Open Graph tags win and relative images resolve', () {
      final meta = extractPageMetadata(page, Uri.parse(link));
      expect(meta.title, '  Veritra & friends ');
      expect(meta.description, 'A private messenger');
      expect(meta.imageUrl.toString(), 'https://github.com/img/card.png');
    });

    test('title and meta description are the fallback', () {
      final meta = extractPageMetadata(
        '<title>Only title</title><meta name="description" content="Desc">',
        Uri.parse(link),
      );
      expect(meta.title, 'Only title');
      expect(meta.description, 'Desc');
      expect(meta.imageUrl, isNull);
    });

    test('broken markup does not throw', () {
      final meta = extractPageMetadata(
        '<<<meta property=og:title',
        Uri.parse(link),
      );
      expect(meta.imageUrl, isNull);
    });
  });

  group('policy', () {
    test('the allow-list matches whole labels only', () {
      const mode = LinkPreviewMode.allowListed;
      expect(linkPreviewHostAllowed('github.com', mode), isTrue);
      expect(linkPreviewHostAllowed('Gist.GitHub.com', mode), isTrue);
      expect(linkPreviewHostAllowed('evilgithub.com', mode), isFalse);
      expect(linkPreviewHostAllowed('github.com.evil.example', mode), isFalse);
      expect(linkPreviewHostAllowed('example.org', mode), isFalse);
      expect(linkPreviewHostAllowed('example.org', LinkPreviewMode.anySite),
          isTrue);
      expect(
        linkPreviewHostAllowed('github.com', LinkPreviewMode.off),
        isFalse,
      );
    });

    test('the default is the allow-list and unknown names fall back to it', () {
      expect(linkPreviewModeFromName(null), LinkPreviewMode.allowListed);
      expect(linkPreviewModeFromName('junk'), LinkPreviewMode.allowListed);
      expect(linkPreviewModeFromName('off'), LinkPreviewMode.off);
      expect(linkPreviewModeFromName('anySite'), LinkPreviewMode.anySite);
    });

    test('only public addresses may be fetched', () {
      const good = <String>['8.8.8.8', '93.184.216.34', '2606:4700::1111'];
      for (final ok in good) {
        expect(isPublicAddress(InternetAddress(ok)), isTrue, reason: ok);
      }
      for (final bad in <String>[
        '0.0.0.0',
        '10.1.2.3',
        '100.64.0.1',
        '127.0.0.1',
        '169.254.169.254',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.1',
        '198.18.0.1',
        '224.0.0.1',
        '255.255.255.255',
        '::',
        '::1',
        'fc00::1',
        'fd12:3456::1',
        'fe80::1',
        'ff02::1',
        '2001:db8::1',
        '::ffff:10.0.0.1',
        '::ffff:127.0.0.1',
        '64:ff9b::7f00:1',
      ]) {
        expect(isPublicAddress(InternetAddress(bad)), isFalse, reason: bad);
      }
      expect(isPublicAddress(InternetAddress('::ffff:8.8.8.8')), isTrue);
    });
  });

  group('building', () {
    LinkPreviewService service(FakeTransport transport, {int redirects = 3}) =>
        LinkPreviewService(
          transport: transport,
          thumbnailEncoder: fakeEncoder,
          maxRedirects: redirects,
        );

    test('an allow-listed link gets a title, text and thumbnail', () async {
      final transport = FakeTransport(<String, LinkPreviewResponse>{
        link: html(page),
        'https://github.com/img/card.png': image(),
      });
      final preview = await service(transport).build(
        'look $link?utm_source=chat&fbclid=1#readme',
        LinkPreviewMode.allowListed,
      );
      expect(preview!.url, link);
      expect(preview.title, 'Veritra & friends');
      expect(preview.description, 'A private messenger');
      expect(preview.thumbnail!.width, 8);
      // Tracking was removed before the page was requested.
      expect(transport.requests, <String>[
        link,
        'https://github.com/img/card.png',
      ]);
    });

    test('off, an unknown site and an http link fetch nothing', () async {
      final transport = FakeTransport(<String, LinkPreviewResponse>{
        'https://example.org/a': html(page),
        link: html(page),
      });
      final builder = service(transport);
      expect(await builder.build(link, LinkPreviewMode.off), isNull);
      expect(
        await builder.build(
          'https://example.org/a',
          LinkPreviewMode.allowListed,
        ),
        isNull,
      );
      expect(
        await builder.build('http://github.com/a', LinkPreviewMode.anySite),
        isNull,
      );
      expect(await builder.build('no link', LinkPreviewMode.anySite), isNull);
      expect(transport.requests, isEmpty);
    });

    test('any-site mode fetches an unknown public site', () async {
      final transport = FakeTransport(<String, LinkPreviewResponse>{
        'https://example.org/a': html(page),
        'https://example.org/img/card.png': image(),
      });
      final preview = await service(transport)
          .build('https://example.org/a', LinkPreviewMode.anySite);
      expect(preview!.title, 'Veritra & friends');
      expect(preview.thumbnail, isNotNull);
    });

    test('up to three redirects are followed, a fourth is refused', () async {
      final routes = <String, LinkPreviewResponse>{
        'https://github.com/r0': redirect('/r1'),
        'https://github.com/r1': redirect('https://github.com/r2'),
        'https://github.com/r2': redirect('/r3#frag'),
        'https://github.com/r3': html(page),
        'https://github.com/r4': redirect('/r5'),
        'https://github.com/r5': redirect('/r6'),
        'https://github.com/r6': redirect('/r7'),
        'https://github.com/r7': redirect('/r3'),
      };
      final transport = FakeTransport(routes);
      final ok = await service(transport)
          .build('https://github.com/r0', LinkPreviewMode.allowListed);
      expect(ok!.title, 'Veritra & friends');
      expect(transport.requests.take(4).toList(), <String>[
        'https://github.com/r0',
        'https://github.com/r1',
        'https://github.com/r2',
        'https://github.com/r3',
      ]);
      final refused = await service(FakeTransport(routes))
          .build('https://github.com/r4', LinkPreviewMode.allowListed);
      expect(refused, isNull);
    });

    test('every hop must be https and inside the mode', () async {
      final transport = FakeTransport(<String, LinkPreviewResponse>{
        'https://github.com/a': redirect('http://github.com/b'),
        'https://github.com/c': redirect('https://example.org/d'),
        'https://github.com/e': redirect('https://github.com:8443/f'),
        'https://github.com/g': redirect('https://127.0.0.1/h'),
        'https://example.org/d': html(page),
      });
      final builder = service(transport);
      for (final start in <String>['a', 'c', 'e', 'g']) {
        expect(
          await builder.build(
              'https://github.com/$start', LinkPreviewMode.allowListed),
          isNull,
          reason: start,
        );
      }
      expect(transport.requests, isNot(contains('https://example.org/d')));
      // The same off-list redirect is fine when any site is allowed.
      final any = await builder.build(
          'https://github.com/c', LinkPreviewMode.anySite);
      expect(any!.title, 'Veritra & friends');
    });

    test('an image host outside the allow-list is not fetched', () async {
      final transport = FakeTransport(<String, LinkPreviewResponse>{
        link: html(
          '<meta property="og:title" content="T">'
          '<meta property="og:image" content="https://cdn.example.net/i.png">',
        ),
        'https://cdn.example.net/i.png': image(),
      });
      final preview =
          await service(transport).build(link, LinkPreviewMode.allowListed);
      expect(preview!.title, 'T');
      expect(preview.thumbnail, isNull);
      expect(transport.requests, <String>[link]);
    });

    test('failures and odd responses mean no preview', () async {
      Future<LinkPreview?> build(LinkPreviewResponse response) => service(
              FakeTransport(<String, LinkPreviewResponse>{link: response}))
          .build(link, LinkPreviewMode.allowListed);
      expect(await build(html(page, status: 404)), isNull);
      expect(await build(html(page, status: 500)), isNull);
      expect(await build(html(page, type: 'application/pdf')), isNull);
      expect(await build(html(page, type: 'image/png')), isNull);
      expect(await build(html('<html></html>')), isNull);
      expect(await build(redirect('')), isNull);

      final broken = FakeTransport(<String, LinkPreviewResponse>{})
        ..failure = const SocketException('down');
      expect(
        await service(broken).build(link, LinkPreviewMode.allowListed),
        isNull,
      );
    });

    test('a preview with only a bad image is dropped', () async {
      final transport = FakeTransport(<String, LinkPreviewResponse>{
        link: html('<meta property="og:image" content="/i.png">'),
        'https://github.com/i.png': LinkPreviewResponse(
          status: 200,
          body: Uint8List(5),
          contentType: 'image/png',
        ),
      });
      expect(
        await service(transport).build(link, LinkPreviewMode.allowListed),
        isNull,
      );
    });

    test('the total time is bounded', () async {
      final builder = LinkPreviewService(
        transport: _SlowTransport(),
        timeout: const Duration(milliseconds: 50),
      );
      expect(await builder.build(link, LinkPreviewMode.allowListed), isNull);
    });
  });
}

class _SlowTransport implements LinkPreviewTransport {
  @override
  Future<LinkPreviewResponse> get(
    Uri uri, {
    required int maxBytes,
    required String accept,
    required Duration timeout,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return html(page);
  }
}
