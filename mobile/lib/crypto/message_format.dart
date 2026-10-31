import 'dart:convert';

/// Active pins per chat (per channel in a shared community conversation).
/// Owner decision 2026-10-31: Discord-like 50, replacing W7's original 3.
/// A pin beyond the limit evicts the oldest by `pinned_at`.
const pinLimitPerChat = 50;

/// Who may pin (owner decision 2026-10-31): either member of a DM and any
/// member of a group. Community conversations keep moderator roles until C4
/// adds per-channel permissions; an admin-only group switch also waits for
/// C4, because groups have no encrypted settings record yet. An unknown
/// [kind] (roster not cached) authorizes only a moderator role.
bool pinAllowed({required String? kind, required String? role}) =>
    kind == 'dm' ||
    kind == 'group' ||
    const {'owner', 'admin', 'moderator'}.contains(role);

const formatTypes = {
  'bold',
  'italic',
  'strikethrough',
  'code',
  'code_block',
  'spoiler'
};

bool _validRange(String text, int offset, int length) {
  if (offset < 0 || length < 1 || offset + length > text.length) return false;
  bool split(int at) =>
      at > 0 &&
      at < text.length &&
      text.codeUnitAt(at - 1) >= 0xd800 &&
      text.codeUnitAt(at - 1) <= 0xdbff &&
      text.codeUnitAt(at) >= 0xdc00 &&
      text.codeUnitAt(at) <= 0xdfff;
  return !split(offset) && !split(offset + length);
}

/// Formatting and mentions are optional decoration. Bad entries alone disappear.
Map<String, Object?> messageDecoration(Map<String, Object?> body,
    {Set<String>? members}) {
  final text = body['text'] as String? ?? '';
  final entities = <Map<String, Object?>>[];
  final raw = body['entities'];
  if (raw is List) {
    for (final item in raw.take(256)) {
      if (item is! Map ||
          !formatTypes.contains(item['type']) ||
          item['offset'] is! int ||
          item['length'] is! int) continue;
      final offset = item['offset'] as int, length = item['length'] as int;
      if (!_validRange(text, offset, length)) continue;
      final type = item['type'] as String;
      if (entities.any((e) =>
          offset < (e['offset'] as int) + (e['length'] as int) &&
          (e['offset'] as int) < offset + length &&
          (e['type'] == type ||
              type == 'code' ||
              type == 'code_block' ||
              e['type'] == 'code' ||
              e['type'] == 'code_block'))) continue;
      entities.add({'type': type, 'offset': offset, 'length': length});
    }
  }
  final mentions = <Map<String, Object?>>[];
  final rawMentions = body['mentions'];
  if (rawMentions is List) {
    for (final item in rawMentions.take(50)) {
      if (item is! Map ||
          item['account_id'] is! String ||
          item['offset'] is! int ||
          item['length'] is! int) continue;
      final offset = item['offset'] as int, length = item['length'] as int;
      if (!_validRange(text, offset, length) ||
          text[offset] != '@' ||
          (members != null && !members.contains(item['account_id']))) continue;
      mentions.add({
        'account_id': item['account_id'],
        'offset': offset,
        'length': length
      });
    }
  }
  return {
    if (entities.isNotEmpty) 'entities': entities,
    if (mentions.isNotEmpty) 'mentions': mentions
  };
}

/// Marker parsing happens only on the sender. Received text is never parsed.
Map<String, Object?> composeMessage(String input,
    {Map<String, String> accountsByUsername = const {}}) {
  const markers = {
    '```': 'code_block',
    '||': 'spoiler',
    '*': 'bold',
    '_': 'italic',
    '~': 'strikethrough',
    '`': 'code'
  };
  ({String text, List<Map<String, Object?>> entities}) parse(
      String source, int depth) {
    final out = StringBuffer(), entities = <Map<String, Object?>>[];
    var at = 0;
    while (at < source.length) {
      var matched = false;
      if (depth < 32) {
        for (final entry in markers.entries) {
          if (!source.startsWith(entry.key, at)) continue;
          final end = source.indexOf(entry.key, at + entry.key.length);
          if (end <= at + entry.key.length) continue;
          final content = source.substring(at + entry.key.length, end);
          final nested = entry.value == 'code' || entry.value == 'code_block'
              ? (text: content, entities: <Map<String, Object?>>[])
              : parse(content, depth + 1);
          final offset = out.length;
          entities.add({
            'type': entry.value,
            'offset': offset,
            'length': nested.text.length
          });
          entities.addAll(nested.entities
              .map((e) => {...e, 'offset': offset + (e['offset'] as int)}));
          out.write(nested.text);
          at = end + entry.key.length;
          matched = true;
          break;
        }
      }
      if (!matched) out.write(source[at++]);
    }
    return (text: out.toString(), entities: entities);
  }

  final parsed = parse(input, 0), text = parsed.text;
  final entities = messageDecoration(
      {'text': text, 'entities': parsed.entities})['entities'];
  final mentions = <Map<String, Object?>>[];
  for (final match in RegExp(r'@[A-Za-z0-9_]+').allMatches(text)) {
    final account = accountsByUsername[match.group(0)!.substring(1)];
    if (account != null)
      mentions.add({
        'account_id': account,
        'offset': match.start,
        'length': match.end - match.start
      });
  }
  return {
    'text': text,
    if (entities != null) 'entities': entities,
    if (mentions.isNotEmpty) 'mentions': mentions
  };
}

Map<String, Object?> decodeDecoration(String? value) {
  if (value == null) return const {};
  try {
    return Map<String, Object?>.from(jsonDecode(value) as Map);
  } catch (_) {
    return const {};
  }
}
