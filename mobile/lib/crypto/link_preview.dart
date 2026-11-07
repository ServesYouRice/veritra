import 'dart:convert';
import 'dart:typed_data';

/// Link previews (B2, `docs/crypto.md` "5.8 Link previews").
///
/// The sender's app fetches a page and writes the result into the encrypted
/// payload body as `link_preview`. Receivers and the server never fetch
/// anything. This file holds only the pure parts: the wire form, its limits,
/// the receiver's validation and the URL helpers both sides share.

const int linkPreviewMaxUrlLength = 2048;
const int linkPreviewMaxTitleUnits = 200;
const int linkPreviewMaxDescriptionUnits = 400;

/// The inline thumbnail is a PNG the sender re-encoded: at most this many
/// bytes and this many pixels on a side.
const int linkPreviewMaxThumbnailBytes = 16 * 1024;
const int linkPreviewMaxThumbnailSide = 160;

/// The whole body (text and preview) must stay under this many UTF-8 bytes,
/// so the framed payload stays inside the 64 KiB limit with its envelope.
const int linkPreviewBodyBudgetBytes = 48 * 1024;

const int _maxThumbnailBase64 = (linkPreviewMaxThumbnailBytes ~/ 3 + 1) * 4;

/// Query parameters that only identify a click or a campaign. They are
/// removed from the URL that is fetched and sent.
const Set<String> _trackingParameters = <String>{
  'fbclid',
  'gclid',
  'dclid',
  'gbraid',
  'wbraid',
  'msclkid',
  'twclid',
  'yclid',
  'igshid',
  'mc_eid',
  'mc_cid',
  'mkt_tok',
  'vero_id',
  'oly_anon_id',
  'oly_enc_id',
  '_ga',
  '_gl',
  'ref_src',
  'ref_url',
  's_cid',
  'spm',
};

bool _isTrackingParameter(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('utm_') || _trackingParameters.contains(lower);
}

/// Drops the fragment and every tracking query parameter. Pure string work,
/// so the rest of the URL is left exactly as written.
String stripTracking(String url) {
  final hash = url.indexOf('#');
  final withoutFragment = hash >= 0 ? url.substring(0, hash) : url;
  final question = withoutFragment.indexOf('?');
  if (question < 0) return withoutFragment;
  final kept = <String>[];
  for (final pair in withoutFragment.substring(question + 1).split('&')) {
    if (pair.isEmpty) continue;
    final equals = pair.indexOf('=');
    final name = equals < 0 ? pair : pair.substring(0, equals);
    if (!_isTrackingParameter(name)) kept.add(pair);
  }
  final base = withoutFragment.substring(0, question);
  return kept.isEmpty ? base : '$base?${kept.join('&')}';
}

final RegExp _linkPattern = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

const Map<String, String> _closers = <String, String>{
  ')': '(',
  ']': '[',
  '}': '{',
};

int _count(String text, String character) => character.allMatches(text).length;

/// Removes trailing sentence punctuation, and a closing bracket only when it
/// has no opening partner inside the link.
String _trimLinkEnd(String link) {
  var end = link.length;
  while (end > 0) {
    final last = link[end - 1];
    final current = link.substring(0, end);
    final opener = _closers[last];
    if ('.,;:!?\''.contains(last)) {
      end--;
    } else if (opener != null &&
        _count(current, last) > _count(current, opener)) {
      end--;
    } else {
      break;
    }
  }
  return link.substring(0, end);
}

/// The links in [text], in order, with trailing punctuation removed.
List<String> linksInText(String text) {
  return <String>[
    for (final match in _linkPattern.allMatches(text))
      _trimLinkEnd(match.group(0)!),
  ];
}

String? firstLinkInText(String text) {
  final links = linksInText(text);
  return links.isEmpty ? null : links.first;
}

final RegExp _hostPattern = RegExp(
  r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
);
final RegExp _numeric = RegExp(r'^[0-9]+$');

const List<String> _localSuffixes = <String>[
  '.local',
  '.localhost',
  '.internal',
  '.lan',
  '.home',
  '.corp',
  '.intranet',
  '.arpa',
];

/// An ASCII DNS name with at least two labels that is not a local name. IP
/// literals fail: an all-numeric last label is an IPv4 literal.
bool isPublicLookingHost(String host) {
  final lower = host.toLowerCase();
  if (lower.length > 253 || !_hostPattern.hasMatch(lower)) return false;
  if (_numeric.hasMatch(lower.split('.').last)) return false;
  return !_localSuffixes.any(lower.endsWith);
}

/// Parses [raw] as a URL a preview may describe or fetch: https, the default
/// port, no credentials, a public-looking DNS name, no whitespace, control or
/// non-ASCII characters. Null otherwise.
Uri? parsePreviewUrl(String raw) {
  if (raw.isEmpty || raw.length > linkPreviewMaxUrlLength) return null;
  for (final unit in raw.codeUnits) {
    if (unit <= 0x20 || unit > 0x7e) return null;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.isScheme('https') || !uri.hasAuthority) return null;
  if (uri.userInfo.isNotEmpty) return null;
  if (uri.hasPort && uri.port != 443) return null;
  if (!isPublicLookingHost(uri.host)) return null;
  return uri;
}

bool _blockedRune(int rune) {
  if (rune < 0x20) return rune != 0x09 && rune != 0x0a && rune != 0x0d;
  if (rune >= 0x7f && rune <= 0x9f) return true;
  if (rune >= 0x200b && rune <= 0x200f) return true;
  if (rune >= 0x202a && rune <= 0x202e) return true;
  if (rune >= 0x2066 && rune <= 0x2069) return true;
  return rune == 0xfeff || rune == 0xfffd;
}

final RegExp _whitespace = RegExp(r'\s+');

/// Display text for a title or description: control and bidirectional
/// override characters removed, whitespace collapsed, cut to [maxUnits]
/// UTF-16 units without splitting a surrogate pair. Null when nothing is left.
String? cleanPreviewText(Object? value, int maxUnits) {
  if (value is! String) return null;
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (!_blockedRune(rune)) buffer.writeCharCode(rune);
  }
  var text = buffer.toString().replaceAll(_whitespace, ' ').trim();
  if (text.length > maxUnits) {
    var cut = maxUnits;
    final unit = text.codeUnitAt(cut - 1);
    if (unit >= 0xd800 && unit <= 0xdbff) cut--;
    text = text.substring(0, cut).trimRight();
  }
  return text.isEmpty ? null : text;
}

const List<int> _pngSignature = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
];

const List<int> _ihdr = <int>[0x49, 0x48, 0x44, 0x52];

bool _pngMatches(Uint8List png, int width, int height) {
  if (png.length < 33) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (png[i] != _pngSignature[i]) return false;
  }
  // The first chunk must be IHDR: length 13, the name, then width and height.
  for (var i = 0; i < _ihdr.length; i++) {
    if (png[12 + i] != _ihdr[i]) return false;
  }
  final header = ByteData.sublistView(png);
  return header.getUint32(8) == 13 &&
      header.getUint32(16) == width &&
      header.getUint32(20) == height;
}

/// A re-encoded PNG thumbnail carried inline in the preview.
class LinkPreviewThumbnail {
  const LinkPreviewThumbnail({
    required this.png,
    required this.width,
    required this.height,
  });

  final Uint8List png;
  final int width;
  final int height;

  Map<String, Object?> toWire() => <String, Object?>{
        'mime': 'image/png',
        'width': width,
        'height': height,
        'data': base64.encode(png),
      };

  /// Null unless [raw] is a small, well-formed PNG whose header agrees with
  /// the declared size. A bad thumbnail never invalidates the preview.
  static LinkPreviewThumbnail? fromWire(Object? raw) {
    try {
      if (raw is! Map) return null;
      final width = raw['width'];
      final height = raw['height'];
      final encoded = raw['data'];
      if (raw['mime'] != 'image/png') return null;
      if (width is! int || height is! int || encoded is! String) return null;
      if (width < 1 || height < 1) return null;
      if (width > linkPreviewMaxThumbnailSide) return null;
      if (height > linkPreviewMaxThumbnailSide) return null;
      if (encoded.length > _maxThumbnailBase64) return null;
      final png = base64.decode(encoded);
      if (png.length > linkPreviewMaxThumbnailBytes) return null;
      if (!_pngMatches(png, width, height)) return null;
      return LinkPreviewThumbnail(png: png, width: width, height: height);
    } catch (_) {
      return null;
    }
  }
}

/// What a link preview shows. [url] is the https link the sender's text
/// contains, with tracking removed; the card always shows its real host.
class LinkPreview {
  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.thumbnail,
  });

  final String url;
  final String? title;
  final String? description;
  final LinkPreviewThumbnail? thumbnail;

  String get host => Uri.tryParse(url)?.host ?? '';

  Map<String, Object?> toWire() => <String, Object?>{
        'url': url,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (thumbnail != null) 'thumb': thumbnail!.toWire(),
      };

  /// The receiver's check. Lenient like formatting: a preview that breaks a
  /// rule is dropped alone and the message stays valid. A preview is kept only
  /// when its URL is https, carries no tracking, is public-looking, and equals
  /// (after the same tracking strip) a link in [text], so a card can never
  /// describe a different site than the one the message names. Nothing is
  /// fetched here.
  static LinkPreview? fromWire(Object? raw, {required String text}) {
    try {
      if (raw is! Map) return null;
      final url = raw['url'];
      if (url is! String) return null;
      if (parsePreviewUrl(url) == null || stripTracking(url) != url) {
        return null;
      }
      if (!linksInText(text).any((link) => stripTracking(link) == url)) {
        return null;
      }
      final title = cleanPreviewText(raw['title'], linkPreviewMaxTitleUnits);
      final description = cleanPreviewText(
        raw['description'],
        linkPreviewMaxDescriptionUnits,
      );
      final thumbnail = LinkPreviewThumbnail.fromWire(raw['thumb']);
      if (title == null && description == null && thumbnail == null) {
        return null;
      }
      return LinkPreview(
        url: url,
        title: title,
        description: description,
        thumbnail: thumbnail,
      );
    } catch (_) {
      return null;
    }
  }
}

/// [body] with [preview] added as `link_preview`, within the size budget:
/// the thumbnail goes first when the body is too large, then the whole
/// preview. Sending never fails because of a preview.
Map<String, Object?> bodyWithLinkPreview(
  Map<String, Object?> body,
  LinkPreview preview,
) {
  int size(Map<String, Object?> candidate) =>
      utf8.encode(jsonEncode(candidate)).length;
  final full = <String, Object?>{...body, 'link_preview': preview.toWire()};
  if (size(full) <= linkPreviewBodyBudgetBytes) return full;
  if (preview.thumbnail == null) return body;
  final plain = LinkPreview(
    url: preview.url,
    title: preview.title,
    description: preview.description,
  );
  final withoutThumbnail = <String, Object?>{
    ...body,
    'link_preview': plain.toWire(),
  };
  if (size(withoutThumbnail) <= linkPreviewBodyBudgetBytes) {
    return withoutThumbnail;
  }
  return body;
}
