import 'package:html/parser.dart' as html_parser;

/// What the sender's app reads from a fetched page (B2). The values are raw:
/// `cleanPreviewText` bounds and cleans them before they enter a payload.
class PageMetadata {
  const PageMetadata({this.title, this.description, this.imageUrl});

  final String? title;
  final String? description;

  /// The preview image, resolved against the page URL. Not yet checked
  /// against the fetch policy.
  final Uri? imageUrl;
}

/// Reads the Open Graph and Twitter card tags, falling back to `<title>` and
/// `<meta name="description">`. Run only on a page this device fetched for a
/// message it is sending, never on received content.
PageMetadata extractPageMetadata(String source, Uri pageUrl) {
  final document = html_parser.parse(source);
  final meta = <String, String>{};
  for (final element in document.querySelectorAll('meta')) {
    final content = element.attributes['content'];
    if (content == null) continue;
    for (final attribute in const <String>['property', 'name']) {
      final key = element.attributes[attribute]?.trim().toLowerCase();
      if (key != null && key.isNotEmpty) meta.putIfAbsent(key, () => content);
    }
  }
  String? first(List<String> keys) {
    for (final key in keys) {
      final value = meta[key];
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  final title = first(<String>['og:title', 'twitter:title']) ??
      document.querySelector('title')?.text;
  final description = first(
    <String>['og:description', 'twitter:description', 'description'],
  );
  Uri? imageUrl;
  final rawImage = first(<String>[
    'og:image:secure_url',
    'og:image',
    'og:image:url',
    'twitter:image',
    'twitter:image:src',
  ]);
  if (rawImage != null) {
    final parsed = Uri.tryParse(rawImage.trim());
    if (parsed != null) imageUrl = pageUrl.resolveUri(parsed);
  }
  return PageMetadata(
    title: title,
    description: description,
    imageUrl: imageUrl,
  );
}
