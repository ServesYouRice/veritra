import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'community_info_payload.dart';
import 'franking.dart';
import 'poll.dart';

const int appPayloadVersion = 2;
const int _headerLength = 8;
const int _paddingBucket = 256;
const int _maxPayloadBytes = 64 * 1024;

/// Longest message text, in UTF-16 code units, a payload body may carry. The
/// composer and edit dialog check it before sending.
const int maxAppTextLength = 16384;
const List<int> _magic = <int>[0x56, 0x41, 0x50, 0x31]; // VAP1

enum AppPayloadType {
  text,
  reply,
  edit,
  delete,
  reaction,
  attachmentManifest,
  pin,
  poll,
  pollVote,
  pollClose,
  callSignal,

  /// C3: a community or private-channel info key, sent only in the group
  /// that owns it.
  infoKey,

  /// C3: asks the group for an info key this device lacks.
  infoKeyRequest,

  /// C3: announces an accepted info record by its SHA-256, so receivers can
  /// tell an allowed editor's record from a server-substituted one.
  infoUpdate,
  profileKey,
  groupProfileKey,

  /// C4 removal proof: the sender's own leave from this record group, bound
  /// to the MLS epoch it is sent in (`docs/crypto.md`, "C4 app wiring").
  memberLeave,

  /// C7: a channel's history record (create, switch, move) in compact form,
  /// proposed in a message of the channel itself.
  historyChange,

  /// C7: the group-level message after a membership commit, one sealed slot
  /// per channel (its body0 carries `for_epoch` and the slot keys).
  historySync,

  /// C7: a newcomer asking for the `history_sync` it did not receive.
  historySyncRequest,
}

/// C7 hidden types (docs/designs/C7-channel-history.md). Never franked
/// (design decision 3, "Franking"): their envelopes carry a random
/// `frank_commit`.
const Set<AppPayloadType> c7PayloadTypes = <AppPayloadType>{
  AppPayloadType.historyChange,
  AppPayloadType.historySync,
  AppPayloadType.historySyncRequest,
};

/// The only types a group-level C7 message (no `channel_id`) may carry.
const Set<AppPayloadType> c7GroupLevelTypes = <AppPayloadType>{
  AppPayloadType.historySync,
  AppPayloadType.historySyncRequest,
};

/// C3 types (docs/designs/C3-private-channels-and-info.md). They change state
/// and never show a bubble.
const Set<AppPayloadType> infoPayloadTypes = <AppPayloadType>{
  AppPayloadType.infoKey,
  AppPayloadType.infoKeyRequest,
  AppPayloadType.infoUpdate,
};

extension AppPayloadTypeWire on AppPayloadType {
  /// The string in the payload's `type`. Existing types keep their Dart enum
  /// name (the wire contract of every device); new multi-word types are
  /// snake_case, as `docs/crypto.md` writes them.
  String get wireName => switch (this) {
        AppPayloadType.pollVote => 'poll_vote',
        AppPayloadType.pollClose => 'poll_close',
        AppPayloadType.infoKey => 'info_key',
        AppPayloadType.infoKeyRequest => 'info_key_request',
        AppPayloadType.infoUpdate => 'info_update',
        AppPayloadType.profileKey => 'profile_key',
        AppPayloadType.groupProfileKey => 'group_profile_key',
        AppPayloadType.memberLeave => 'member_leave',
        AppPayloadType.historyChange => 'history_change',
        AppPayloadType.historySync => 'history_sync',
        AppPayloadType.historySyncRequest => 'history_sync_request',
        _ => name,
      };

  /// Types that change state rather than add a bubble. Senders mark them
  /// `hidden: true` (S2) so an older app stores them without showing them.
  bool get sendsHidden =>
      this == AppPayloadType.pin ||
      this == AppPayloadType.pollVote ||
      this == AppPayloadType.pollClose ||
      infoPayloadTypes.contains(this) ||
      this == AppPayloadType.profileKey ||
      this == AppPayloadType.groupProfileKey ||
      this == AppPayloadType.memberLeave ||
      c7PayloadTypes.contains(this);
}

class DecryptedAppPayload {
  const DecryptedAppPayload({
    required this.type,
    required this.actionId,
    required this.body,
    this.channelId,
    this.expiresAtMs,
  });

  final AppPayloadType type;
  final String actionId;
  final Map<String, Object?> body;
  final String? channelId;

  /// The sender's own expiry for this message, in epoch milliseconds, from
  /// the signed (end-to-end encrypted) payload. Null when the sender put none
  /// there (an older app, or no disappearing timer): the receiver then falls
  /// back to the server-stamped time, see [effectiveExpiryMillis].
  final int? expiresAtMs;
}

/// The latest expiry a sender may name, in epoch milliseconds (year 9999): a
/// value past it, or not a positive integer, is read as absent.
const int _maxExpiryMs = 253402300799000;

/// The expiry to store for a message (TASK-106, owner decision 2026-11-07).
/// [senderMs] is the sender's authenticated value from the payload and
/// [serverMs] the server-stamped envelope time, either may be null.
///
/// - Both: the shorter one. A longer server time is ignored; a shorter one
///   still applies, because it cannot make the message outlive what the
///   sender chose.
/// - Only the sender's: that.
/// - Only the server's (the payload has none, for example from an older
///   app): the server's, as before. That is the compatibility fallback; it
///   is exactly as trustworthy as it always was.
int? effectiveExpiryMillis({int? senderMs, int? serverMs}) {
  if (senderMs == null) return serverMs;
  if (serverMs == null) return senderMs;
  return senderMs < serverMs ? senderMs : serverMs;
}

int? _readExpiryMs(Object? raw) =>
    raw is int && raw > 0 && raw <= _maxExpiryMs ? raw : null;

/// What a decrypted application payload turned out to be (W8 step 0, P1).
/// Classification is total: [AppPayloadCodec.classify] never throws.
sealed class AppPayloadOutcome {
  const AppPayloadOutcome();
}

/// A payload this app understands, fully validated.
final class DecodedAppPayload extends AppPayloadOutcome {
  const DecodedAppPayload(this.payload);

  final DecryptedAppPayload payload;
}

/// Authentic (its context matched) but newer than, or unknown to, this app.
/// [rawJson] is the inner JSON exactly as decrypted, kept for a later app
/// version; [hidden] is the sender's `hidden: true` flag.
final class UnsupportedAppPayload extends AppPayloadOutcome {
  const UnsupportedAppPayload({required this.rawJson, required this.hidden});

  final String rawJson;
  final bool hidden;
}

/// Broken framing, JSON or context, or a known type with a bad body.
final class InvalidAppPayload extends AppPayloadOutcome {
  const InvalidAppPayload();
}

/// What a receiver does with a payload that has no `frank` member (D95,
/// condition G5). Accepting is the owner's decision for now, so every
/// sender running an older app keeps working; [acceptUnfranked] is the
/// switch that turns it into a refusal once every sender runs the franking
/// build, with no other change.
///
/// Refusing makes an unfranked payload `invalid`, with exemptions decided
/// after decoding: a hidden payload this app does not understand
/// ([UnsupportedAppPayload.hidden]), and a payload whose type is in
/// [unfrankedPayloadTypes]. The C7 hidden types (`history_change`,
/// `history_sync`, `history_sync_request`) are never franked, because a
/// `frank` member would push them out of the 512-byte bucket (C6 design,
/// open item 9). Today they decode as unsupported hidden payloads; when C7
/// makes them known types, [unfrankedPayloadTypes] keeps them exempt only if
/// it holds their `AppPayloadType.name`, so the C7 merge must keep the two in
/// step. Every other message type this app sends, pins included, is franked
/// and is never exempt.
class FrankingPolicy {
  const FrankingPolicy({this.acceptUnfranked = true});

  /// Payload types that are never franked (C6 design, open item 9), by
  /// `AppPayloadType.name`.
  static const Set<String> unfrankedPayloadTypes = {
    'history_change',
    'history_sync',
    'history_sync_request',
    // C3: an info key must never be reportable, since a report hands the
    // payload to its reader. Receivers keep no reveal for these types even
    // when one is franked.
    'infoKey',
    'infoKeyRequest',
    'infoUpdate',
    // C4: a leave proof says nothing anyone would report.
    'memberLeave',
  };

  /// Whether a payload without `frank` is accepted (as unreportable).
  final bool acceptUnfranked;

  /// Whether [outcome], a payload that classified but carries no `frank`,
  /// is accepted.
  bool acceptsUnfranked(AppPayloadOutcome outcome) =>
      acceptUnfranked ||
      switch (outcome) {
        UnsupportedAppPayload(:final hidden) => hidden,
        DecodedAppPayload(:final payload) =>
          unfrankedPayloadTypes.contains(payload.type.name),
        InvalidAppPayload() => false,
      };
}

/// Encodes only client-visible content. The complete padded value is protected
/// by MLS; duplicated routing fields are checked after decryption so ciphertext
/// cannot be replayed into a different conversation, device, or action row.
class AppPayloadCodec {
  AppPayloadCodec({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  Uint8List encode({
    required AppPayloadType type,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Map<String, Object?> body,
    String? channelId,
    bool hidden = false,
  }) {
    validateContext(conversationId, senderDeviceId, actionId);
    final version = type == AppPayloadType.pin ||
            type == AppPayloadType.poll ||
            type == AppPayloadType.pollVote ||
            type == AppPayloadType.pollClose ||
            infoPayloadTypes.contains(type) ||
            type == AppPayloadType.profileKey ||
            type == AppPayloadType.groupProfileKey ||
            type == AppPayloadType.memberLeave ||
            c7PayloadTypes.contains(type) ||
            channelId != null ||
            hidden ||
            body.keys.any(const {
              'entities',
              'mentions',
              'link_preview',
              'forwarded',
              'profile_key',
              'group_profile_key'
            }.contains)
        ? 2
        : 1;
    _validateBody(type, body, version: version);
    return _frame(_innerJson(version, type, conversationId, senderDeviceId,
        actionId, body, channelId, hidden, null));
  }

  /// Encodes a franked payload (C6, `docs/crypto.md` "Franking v1"). Always
  /// `v: 2`, because a v1 receiver refuses any seventh top-level key.
  /// [canonical] is the inner JSON exactly as [encode] would write it at v2,
  /// which the franking commitment covers; the wire JSON is [canonical] with
  /// the `frank` member appended last ([frankWireJson]). Every message the
  /// app sends is written this way (the message send path).
  ({Uint8List padded, Uint8List canonical}) encodeFranked({
    required AppPayloadType type,
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    required Map<String, Object?> body,
    required Uint8List frankKey,
    String? channelId,
    bool hidden = false,
    int? expiresAtMs,
  }) {
    validateContext(conversationId, senderDeviceId, actionId);
    _validateBody(type, body, version: 2);
    final canonical = _innerJson(2, type, conversationId, senderDeviceId,
        actionId, body, channelId, hidden, expiresAtMs);
    return (
      padded: _frame(frankWireJson(canonical, frankKey)),
      canonical: canonical
    );
  }

  static Uint8List _innerJson(
          int version,
          AppPayloadType type,
          String conversationId,
          String senderDeviceId,
          String actionId,
          Map<String, Object?> body,
          String? channelId,
          bool hidden,
          int? expiresAtMs) =>
      utf8.encode(jsonEncode(<String, Object?>{
        'v': version,
        'type': type.wireName,
        'conversation_id': conversationId,
        'sender_device_id': senderDeviceId,
        'action_id': actionId,
        if (channelId != null) 'channel_id': channelId,
        if (hidden) 'hidden': true,
        // The sender's expiry (v2 only: a v1 receiver refuses extra keys,
        // and every v2 receiver ignores keys it does not know).
        if (expiresAtMs != null) 'expires_at': expiresAtMs,
        'body': body,
      }));

  /// The length of the `VAP1` value for an inner JSON of [innerBytes]: the
  /// 8-byte header, then the next 256-byte bucket. C7 budgets its record
  /// message against this (`docs/designs/C7-channel-history.md` decision 3).
  static int framedLength(int innerBytes) {
    if (innerBytes > _maxPayloadBytes - _headerLength) {
      throw const FormatException('application payload is too large');
    }
    final unpadded = _headerLength + innerBytes;
    return ((unpadded + _paddingBucket - 1) ~/ _paddingBucket) * _paddingBucket;
  }

  Uint8List _frame(Uint8List encoded) {
    final paddedLength = framedLength(encoded.length);
    final unpadded = _headerLength + encoded.length;
    final result = Uint8List(paddedLength);
    result.setRange(0, _magic.length, _magic);
    ByteData.sublistView(result).setUint32(4, encoded.length, Endian.big);
    result.setRange(_headerLength, unpadded, encoded);
    for (var index = unpadded; index < result.length; index++) {
      result[index] = _random.nextInt(256);
    }
    return result;
  }

  DecryptedAppPayload decode(
    List<int> padded, {
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
  }) {
    validateContext(conversationId, senderDeviceId, actionId);
    if (padded.length < _paddingBucket ||
        padded.length > _maxPayloadBytes ||
        padded.length % _paddingBucket != 0 ||
        !_constantTimePrefix(padded, _magic)) {
      throw const FormatException('invalid application payload framing');
    }
    final length = ByteData.sublistView(Uint8List.fromList(padded))
        .getUint32(4, Endian.big);
    if (length <= 0 || length > padded.length - _headerLength) {
      throw const FormatException('invalid application payload length');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(
        padded.sublist(_headerLength, _headerLength + length),
        allowMalformed: false,
      ));
    } catch (_) {
      throw const FormatException('invalid application payload encoding');
    }
    if (decoded is! Map) {
      throw const FormatException('invalid application payload');
    }
    final map = Map<String, Object?>.from(decoded);
    final version = map['v'];
    if (version is! int || version < 1 || version > appPayloadVersion) {
      throw const FormatException('unsupported application payload version');
    }
    final typeName = map['type'];
    final type = AppPayloadType.values
        .where((candidate) => candidate.wireName == typeName)
        .firstOrNull;
    if (type == null ||
        map['conversation_id'] != conversationId ||
        map['sender_device_id'] != senderDeviceId ||
        map['action_id'] != actionId ||
        map['body'] is! Map) {
      throw const FormatException('application payload context mismatch');
    }
    final body = Map<String, Object?>.from(map['body'] as Map);
    if (map.containsKey('channel_id') ||
        (version == 1 &&
            (map.length != _v1Keys.length ||
                !map.keys.every(_v1Keys.contains))))
      throw const FormatException('invalid application payload context');
    _validateBody(type, body, version: version);
    return DecryptedAppPayload(type: type, actionId: actionId, body: body);
  }

  /// What a framed payload says about franking (C6): the inner JSON is cut
  /// out of the `VAP1` framing and read for its top-level `frank` member
  /// ([splitFrank]). Never throws; broken framing reads as [MalformedFrank].
  static FrankOutcome frankOf(List<int> padded) {
    try {
      if (padded.length < _headerLength + 2 ||
          padded.length > _maxPayloadBytes ||
          !_constantTimePrefix(padded, _magic)) {
        return const MalformedFrank();
      }
      final bytes = padded is Uint8List ? padded : Uint8List.fromList(padded);
      final length = ByteData.sublistView(bytes).getUint32(4, Endian.big);
      if (length <= 0 || length > bytes.length - _headerLength) {
        return const MalformedFrank();
      }
      return splitFrank(
          Uint8List.sublistView(bytes, _headerLength, _headerLength + length));
    } catch (_) {
      return const MalformedFrank();
    }
  }

  /// Checks the envelope fields the server supplied (P2). The decrypted
  /// context is compared against these afterwards.
  static void validateContext(
      String conversationId, String deviceId, String actionId) {
    if (conversationId.isEmpty ||
        deviceId.isEmpty ||
        actionId.isEmpty ||
        conversationId.length > 128 ||
        deviceId.length > 128 ||
        actionId.length > 128) {
      throw const FormatException('invalid application payload context');
    }
  }

  /// Decodes like [decode] but never throws (P1). Run it only on a context
  /// already checked with [validateContext].
  ///
  /// v1 stays strict; v2 validates required fields and ignores additive keys.
  /// Newer versions and reserved types are retained as unsupported rows.
  AppPayloadOutcome classify(
    List<int> padded, {
    required String conversationId,
    required String senderDeviceId,
    required String actionId,
    String? channelId,
    bool communityShared = false,
  }) {
    try {
      if (padded.length < _paddingBucket ||
          padded.length > _maxPayloadBytes ||
          padded.length % _paddingBucket != 0 ||
          !_constantTimePrefix(padded, _magic)) {
        return const InvalidAppPayload();
      }
      final length = ByteData.sublistView(Uint8List.fromList(padded))
          .getUint32(4, Endian.big);
      if (length <= 0 || length > padded.length - _headerLength) {
        return const InvalidAppPayload();
      }
      final rawJson = utf8.decode(
        padded.sublist(_headerLength, _headerLength + length),
        allowMalformed: false,
      );
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return const InvalidAppPayload();
      final map = Map<String, Object?>.from(decoded);
      final version = map['v'];
      if (version is! int ||
          version < 1 ||
          map['conversation_id'] != conversationId ||
          map['sender_device_id'] != senderDeviceId ||
          map['action_id'] != actionId ||
          map['type'] is! String ||
          map['body'] is! Map ||
          // Channel context is mandatory only for a shared community group.
          (communityShared
              ? channelId == null || map['channel_id'] != channelId
              : map.containsKey('channel_id'))) {
        return const InvalidAppPayload();
      }
      if (version > appPayloadVersion) {
        return UnsupportedAppPayload(
            rawJson: rawJson, hidden: map['hidden'] == true);
      }
      if (version == 1 &&
          (map.length != _v1Keys.length || !map.keys.every(_v1Keys.contains))) {
        return const InvalidAppPayload();
      }
      final type = AppPayloadType.values
          .where((candidate) => candidate.wireName == map['type'])
          .firstOrNull;
      if (type == null) {
        return UnsupportedAppPayload(
            rawJson: rawJson, hidden: map['hidden'] == true);
      }
      final body = Map<String, Object?>.from(map['body'] as Map);
      _validateBody(type, body, version: version);
      return DecodedAppPayload(DecryptedAppPayload(
          type: type,
          actionId: actionId,
          body: body,
          channelId: map['channel_id'] as String?,
          expiresAtMs: version >= 2 ? _readExpiryMs(map['expires_at']) : null));
    } catch (_) {
      return const InvalidAppPayload();
    }
  }

  void _validateBody(AppPayloadType type, Map<String, Object?> body,
      {int version = 1}) {
    bool stringField(String name, {int max = maxAppTextLength}) =>
        body[name] is String && (body[name] as String).length <= max;
    final valid = switch (type) {
      AppPayloadType.text =>
        stringField('text') && (version >= 2 || body.length == 1),
      AppPayloadType.reply => stringField('text') &&
          stringField('reply_to_id', max: 128) &&
          (version >= 2 || body.length == 2),
      AppPayloadType.edit => stringField('message_id', max: 128) &&
          stringField('text') &&
          (version >= 2 || body.length == 2),
      AppPayloadType.delete => stringField('message_id', max: 128) &&
          (version >= 2 || body.length == 1),
      AppPayloadType.reaction => stringField('message_id', max: 128) &&
          stringField('reaction', max: 32) &&
          (version >= 2 || body.length == 2),
      AppPayloadType.attachmentManifest => body['attachments'] is List &&
          (body['attachments'] as List).length <= 32,
      AppPayloadType.pin => version >= 2 &&
          stringField('message_id', max: 128) &&
          body['pinned'] is bool &&
          (body['pinned'] == false ||
              const [86400, 604800, 2592000]
                  .contains(body['duration_seconds'])),
      AppPayloadType.poll => version >= 2 && isValidPollBody(body),
      AppPayloadType.pollVote => version >= 2 && isValidPollVoteBody(body),
      AppPayloadType.pollClose => version >= 2 && isValidPollCloseBody(body),
      AppPayloadType.infoKey => version >= 2 && isValidInfoKeyBody(body),
      AppPayloadType.infoKeyRequest =>
        version >= 2 && isValidInfoKeyRequestBody(body),
      AppPayloadType.infoUpdate => version >= 2 && isValidInfoUpdateBody(body),
      // The key fields are checked where the key is used, so a malformed key
      // is dropped alone and its message still counts as an action.
      AppPayloadType.profileKey ||
      AppPayloadType.groupProfileKey =>
        version >= 2,
      AppPayloadType.memberLeave => version >= 2 &&
          body.length == 1 &&
          body['epoch'] is int &&
          (body['epoch'] as int) >= 0,
      AppPayloadType.historyChange => version >= 2 && isValidC7ChangeBody(body),
      AppPayloadType.historySync => version >= 2 && isValidC7SyncBody(body),
      AppPayloadType.historySyncRequest =>
        version >= 2 && isValidC7SyncRequestBody(body),
      AppPayloadType.callSignal => body['signal'] is Map &&
          (version >= 2 || body.length == 1) &&
          jsonEncode(body['signal']).length <= 48 * 1024,
    };
    if (!valid) throw const FormatException('invalid application payload body');
  }
}

const Set<String> _v1Keys = <String>{
  'v',
  'type',
  'conversation_id',
  'sender_device_id',
  'action_id',
  'body',
};

bool _constantTimePrefix(List<int> value, List<int> expected) {
  if (value.length < expected.length) return false;
  var difference = 0;
  for (var index = 0; index < expected.length; index++) {
    difference |= value[index] ^ expected[index];
  }
  return difference == 0;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

/// `{"r": base64}`: a compact record, 143 bytes, or a move's 143 plus
/// `lp(close_group_id)` (at most 64 bytes) and the 128-byte wrap.
bool isValidC7ChangeBody(Map<String, Object?> body) {
  final r = body['r'];
  if (body.length != 1 || r is! String) return false;
  try {
    final n = base64Decode(r).length;
    return n == 143 || (n >= 143 + 2 + 1 + 128 && n <= 143 + 2 + 64 + 128);
  } on FormatException {
    return false;
  }
}

/// `{"for_epoch": u64, "channels": [[channel_id, base64(key_c)], ...]}`:
/// 1 to 508 channels, ids at most 64 bytes, sorted bytewise and distinct,
/// each key 32 bytes.
bool isValidC7SyncBody(Map<String, Object?> body) {
  final epoch = body['for_epoch'];
  final channels = body['channels'];
  if (body.length != 2 || epoch is! int || epoch < 0 || channels is! List) {
    return false;
  }
  if (channels.isEmpty || channels.length > 508) return false;
  List<int>? previous;
  for (final entry in channels) {
    if (entry is! List || entry.length != 2) return false;
    final id = entry[0], key = entry[1];
    if (id is! String || key is! String || id.isEmpty) return false;
    final idBytes = utf8.encode(id);
    if (idBytes.length > 64) return false;
    try {
      if (base64Decode(key).length != 32) return false;
    } on FormatException {
      return false;
    }
    if (previous != null && _compareBytes(previous, idBytes) >= 0) {
      return false;
    }
    previous = idBytes;
  }
  return true;
}

/// `{"for_epoch": u64}`: the membership commit whose `history_sync` the
/// sender is missing.
bool isValidC7SyncRequestBody(Map<String, Object?> body) {
  final epoch = body['for_epoch'];
  return body.length == 1 && epoch is int && epoch >= 0;
}

int _compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
