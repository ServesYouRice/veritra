import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/link_preview.dart';
import 'link_preview_html.dart';

/// Which links the sender's app may fetch to build a preview (B2).
enum LinkPreviewMode {
  /// Never fetch.
  off,

  /// Fetch only the sites in [linkPreviewAllowList]. The default.
  allowListed,

  /// Fetch any public https site.
  anySite,
}

LinkPreviewMode linkPreviewModeFromName(String? name) {
  for (final mode in LinkPreviewMode.values) {
    if (mode.name == name) return mode;
  }
  return LinkPreviewMode.allowListed;
}

/// Sites whose links get a preview while the setting is "allow-listed". A
/// host matches when it equals an entry or is a subdomain of one. Picture
/// hosts of these sites are listed too, because the image is fetched under
/// the same rule.
const List<String> linkPreviewAllowList = <String>[
  'wikipedia.org',
  'wikimedia.org',
  'github.com',
  'githubassets.com',
  'githubusercontent.com',
  'gitlab.com',
  'codeberg.org',
  'openstreetmap.org',
  'arxiv.org',
];

bool linkPreviewHostAllowed(String host, LinkPreviewMode mode) {
  final lower = host.toLowerCase();
  return switch (mode) {
    LinkPreviewMode.off => false,
    LinkPreviewMode.anySite => true,
    LinkPreviewMode.allowListed => linkPreviewAllowList.any(
        (site) => lower == site || lower.endsWith('.$site'),
      ),
  };
}

bool _publicIpv4(List<int> b) {
  final first = b[0], second = b[1], third = b[2];
  if (first == 0 || first == 10 || first == 127 || first >= 224) return false;
  if (first == 100 && second >= 64 && second <= 127) return false;
  if (first == 169 && second == 254) return false;
  if (first == 172 && second >= 16 && second <= 31) return false;
  if (first == 192 && second == 168) return false;
  if (first == 192 && second == 0 && (third == 0 || third == 2)) return false;
  if (first == 198 && (second == 18 || second == 19)) return false;
  if (first == 198 && second == 51 && third == 100) return false;
  if (first == 203 && second == 0 && third == 113) return false;
  return true;
}

bool _allZero(List<int> bytes) => bytes.every((value) => value == 0);

/// Whether [address] is a public unicast address. Loopback, private,
/// link-local, shared, documentation, multicast and unspecified addresses are
/// not, so a pasted link cannot make the app probe the sender's own network.
bool isPublicAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (b.length == 4) return _publicIpv4(b);
  if (b.length != 16) return false;
  final mapped = _allZero(b.sublist(0, 10)) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) return _publicIpv4(b.sublist(12));
  // 64:ff9b::/96 (NAT64) embeds an IPv4 address.
  final nat64 = b[0] == 0x00 &&
      b[1] == 0x64 &&
      b[2] == 0xff &&
      b[3] == 0x9b &&
      _allZero(b.sublist(4, 12));
  if (nat64) return _publicIpv4(b.sublist(12));
  if (_allZero(b.sublist(0, 15)) && b[15] <= 1) return false;
  if ((b[0] & 0xfe) == 0xfc) return false;
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false;
  if (b[0] == 0xff) return false;
  return !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8);
}

/// One HTTP response, without redirects followed or a body past the cap.
class LinkPreviewResponse {
  const LinkPreviewResponse({
    required this.status,
    required this.body,
    this.location,
    this.contentType,
  });

  final int status;
  final Uint8List body;
  final String? location;

  /// The lower-case media type without parameters.
  final String? contentType;
}

class LinkPreviewRefused implements Exception {
  const LinkPreviewRefused();
}

/// The network edge of the preview builder, so tests never touch a network.
abstract class LinkPreviewTransport {
  /// One GET of [uri] (https only), reading at most [maxBytes] of the body
  /// within [timeout]. It must not follow redirects.
  Future<LinkPreviewResponse> get(
    Uri uri, {
    required int maxBytes,
    required String accept,
    required Duration timeout,
  });
}

const String linkPreviewUserAgent = 'Mozilla/5.0 (compatible; LinkPreview/1.0)';

/// `dart:io` transport: no redirects, no cookies, no referrer, a generic
/// user agent, certificate checks left on, and only public addresses.
///
/// The host is resolved and checked before the request. A name that changes
/// its answer between that check and the connection (DNS rebinding) is a
/// known residual; the checked ports and the https-only rule bound it.
class IoLinkPreviewTransport implements LinkPreviewTransport {
  IoLinkPreviewTransport({
    Future<List<InternetAddress>> Function(String host)? resolver,
  }) : _resolve = resolver ?? InternetAddress.lookup;

  final Future<List<InternetAddress>> Function(String host) _resolve;

  @override
  Future<LinkPreviewResponse> get(
    Uri uri, {
    required int maxBytes,
    required String accept,
    required Duration timeout,
  }) async {
    if (!uri.isScheme('https')) throw const LinkPreviewRefused();
    final addresses = await _resolve(uri.host).timeout(timeout);
    if (addresses.isEmpty || !addresses.every(isPublicAddress)) {
      throw const LinkPreviewRefused();
    }
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = linkPreviewUserAgent;
    try {
      return await _read(client, uri, maxBytes, accept).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<LinkPreviewResponse> _read(
    HttpClient client,
    Uri uri,
    int maxBytes,
    String accept,
  ) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, accept);
    request.headers.set(HttpHeaders.acceptLanguageHeader, 'en');
    final response = await request.close();
    final redirect = response.statusCode >= 300 && response.statusCode < 400;
    final collected = BytesBuilder(copy: false);
    if (!redirect) {
      await for (final chunk in response) {
        collected.add(chunk);
        if (collected.length >= maxBytes) break;
      }
    }
    var bytes = collected.takeBytes();
    if (bytes.length > maxBytes) {
      bytes = Uint8List.sublistView(bytes, 0, maxBytes);
    }
    return LinkPreviewResponse(
      status: response.statusCode,
      body: bytes,
      location: response.headers.value(HttpHeaders.locationHeader),
      contentType: response.headers.contentType?.mimeType.toLowerCase(),
    );
  }
}

/// Turns downloaded image bytes into a small PNG thumbnail, or null.
typedef LinkPreviewThumbnailEncoder = Future<LinkPreviewThumbnail?> Function(
  Uint8List imageBytes,
);

class _Fetched {
  const _Fetched(this.response, this.finalUrl);

  final LinkPreviewResponse response;
  final Uri finalUrl;
}

/// Builds the preview for a message the user is sending (B2). Everything it
/// does is bounded: one page of at most [maxPageBytes], at most
/// [maxRedirects] redirects (each hop must be https and pass the same
/// allow-list rule), one image of at most [maxImageBytes], all within
/// [timeout]. Any failure means no preview; the message is sent without one.
class LinkPreviewService {
  LinkPreviewService({
    LinkPreviewTransport? transport,
    this.thumbnailEncoder,
    this.maxRedirects = 3,
    this.timeout = const Duration(seconds: 8),
    this.maxPageBytes = 256 * 1024,
    this.maxImageBytes = 384 * 1024,
  }) : _transport = transport ?? IoLinkPreviewTransport();

  final LinkPreviewTransport _transport;
  final LinkPreviewThumbnailEncoder? thumbnailEncoder;
  final int maxRedirects;
  final Duration timeout;
  final int maxPageBytes;
  final int maxImageBytes;

  /// The preview for the first link of [text], or null: the mode forbids it,
  /// there is no https link, the site is not allowed, or the fetch failed.
  Future<LinkPreview?> build(String text, LinkPreviewMode mode) async {
    if (mode == LinkPreviewMode.off) return null;
    final link = firstLinkInText(text);
    if (link == null) return null;
    final url = stripTracking(link);
    final uri = parsePreviewUrl(url);
    if (uri == null || !linkPreviewHostAllowed(uri.host, mode)) return null;
    final deadline = DateTime.now().add(timeout);
    try {
      return await _build(url, uri, mode, deadline).timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  Future<LinkPreview?> _build(
    String url,
    Uri uri,
    LinkPreviewMode mode,
    DateTime deadline,
  ) async {
    final page = await _get(
      uri,
      mode,
      deadline,
      maxBytes: maxPageBytes,
      accept: 'text/html,application/xhtml+xml;q=0.9',
    );
    if (page == null || !_isHtml(page.response.contentType)) return null;
    final metadata = extractPageMetadata(
      utf8.decode(page.response.body, allowMalformed: true),
      page.finalUrl,
    );
    final title = cleanPreviewText(metadata.title, linkPreviewMaxTitleUnits);
    final description = cleanPreviewText(
      metadata.description,
      linkPreviewMaxDescriptionUnits,
    );
    final image = metadata.imageUrl;
    final encoder = thumbnailEncoder;
    LinkPreviewThumbnail? thumbnail;
    if (image != null && encoder != null) {
      thumbnail = await _thumbnail(image, mode, deadline, encoder);
    }
    if (title == null && description == null && thumbnail == null) return null;
    return LinkPreview(
      url: url,
      title: title,
      description: description,
      thumbnail: thumbnail,
    );
  }

  bool _isHtml(String? type) =>
      type == 'text/html' || type == 'application/xhtml+xml';

  Future<LinkPreviewThumbnail?> _thumbnail(
    Uri image,
    LinkPreviewMode mode,
    DateTime deadline,
    LinkPreviewThumbnailEncoder encoder,
  ) async {
    try {
      final fetched = await _get(
        image,
        mode,
        deadline,
        maxBytes: maxImageBytes,
        accept: 'image/png,image/jpeg,image/webp,image/gif;q=0.8',
      );
      final type = fetched?.response.contentType ?? '';
      if (fetched == null || !type.startsWith('image/')) return null;
      return await encoder(fetched.response.body);
    } catch (_) {
      return null;
    }
  }

  /// A GET that follows at most [maxRedirects] redirects itself, so every hop
  /// is checked: https, a public-looking host, and the mode's allow-list.
  Future<_Fetched?> _get(
    Uri start,
    LinkPreviewMode mode,
    DateTime deadline, {
    required int maxBytes,
    required String accept,
  }) async {
    var current = start;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (parsePreviewUrl(current.toString()) == null) return null;
      if (!linkPreviewHostAllowed(current.host, mode)) return null;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      final response = await _transport.get(
        current,
        maxBytes: maxBytes,
        accept: accept,
        timeout: remaining,
      );
      if (response.status >= 300 && response.status < 400) {
        final location = response.location;
        if (location == null || location.length > linkPreviewMaxUrlLength) {
          return null;
        }
        final next = Uri.tryParse(location);
        if (next == null) return null;
        current = current.resolveUri(next).removeFragment();
        continue;
      }
      if (response.status != 200) return null;
      return _Fetched(response, current);
    }
    return null;
  }
}
