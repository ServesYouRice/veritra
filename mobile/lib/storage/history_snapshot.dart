import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../core/models.dart';
import '../crypto/message_format.dart';
import 'encrypted_database.dart';

const historyPayloadLimit = 64 * 1024 * 1024 - 8;
const historyRecordLimit = 100000;

Never _invalid() => throw const FormatException('invalid history snapshot');

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map || value.keys.any((k) => !keys.contains(k))) _invalid();
  return Map<String, dynamic>.from(value);
}

String _id(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 512 ||
      value.contains('\u0000')) _invalid();
  return value;
}

int _time(Object? value) {
  if (value is! int || value < 0 || value > 8640000000000000) _invalid();
  return value;
}

/// Reject duplicate object members before dart:convert can discard them.
/// Also bounds nesting and collection fanout before allocating decoded objects.
Object? strictHistoryJson(List<int> bytes) {
  if (bytes.isEmpty || bytes.length > historyPayloadLimit) _invalid();
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    final stack = <Set<String>?>[];
    var entries = 0;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (c == '{' || c == '[') {
        stack.add(c == '{' ? <String>{} : null);
        if (stack.length > 32) _invalid();
      } else if (c == '}' || c == ']') {
        if (stack.isEmpty) _invalid();
        stack.removeLast();
      } else if (c == ',' || c == ':') {
        if (++entries > historyRecordLimit * 40) _invalid();
      } else if (c == '"') {
        final start = i++;
        while (i < text.length && text[i] != '"') {
          if (text[i] == '\\') i++;
          i++;
        }
        if (i >= text.length) _invalid();
        var next = i + 1;
        while (next < text.length && text[next].trim().isEmpty) next++;
        if (next < text.length && text[next] == ':') {
          if (stack.isEmpty ||
              stack.last == null ||
              !stack.last!
                  .add(jsonDecode(text.substring(start, i + 1)) as String)) {
            _invalid();
          }
        }
      }
    }
    final result = jsonDecode(text);
    var records = 0;
    void count(Object? value) {
      if (value is List) {
        records += value.length;
        if (records > historyRecordLimit) _invalid();
        for (final child in value) {
          count(child);
        }
      } else if (value is Map) {
        for (final child in value.values) {
          count(child);
        }
      }
    }

    count(result);
    return result;
  } catch (_) {
    _invalid();
  }
}

/// Historical metadata only. Never a live Conversation or permission source.
class HistoryConversation {
  const HistoryConversation(this.id, this.kind,
      {this.communityId,
      this.channelId,
      this.title,
      this.historicalChannelIds = const []});
  final String id, kind;
  final String? communityId, channelId, title;
  final List<String> historicalChannelIds;
  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'community_id': communityId,
        'channel_id': channelId,
        'historical_title': title,
        'historical_channel_ids': historicalChannelIds,
      };
  factory HistoryConversation.fromJson(Object? value) {
    final j = _object(value, {
      'id',
      'kind',
      'community_id',
      'channel_id',
      'historical_title',
      'historical_channel_ids'
    });
    final id = _id(j['id']), kind = _id(j['kind']);
    if (!const {'dm', 'group', 'community_channel', 'community_shared'}
        .contains(kind)) _invalid();
    final community = j['community_id'] == null ? null : _id(j['community_id']);
    final channel = j['channel_id'] == null ? null : _id(j['channel_id']);
    if (kind == 'community_channel' && (community == null || channel == null))
      _invalid();
    if (kind == 'community_shared' && (community == null || channel != null))
      _invalid();
    if ((kind == 'dm' || kind == 'group') &&
        (community != null || channel != null)) _invalid();
    final title = j['historical_title'];
    final channels = (j['historical_channel_ids'] as List).map(_id).toList();
    if (channels.length > 10000 ||
        channels.toSet().length != channels.length ||
        (kind != 'community_shared' && channels.isNotEmpty)) _invalid();
    if (title != null && (title is! String || title.length > 1024)) _invalid();
    return HistoryConversation(id, kind,
        communityId: community,
        channelId: channel,
        title: title as String?,
        historicalChannelIds: channels);
  }
  bool sameMapping(HistoryConversation other) =>
      id == other.id &&
      kind == other.kind &&
      communityId == other.communityId &&
      channelId == other.channelId;
}

/// All fields are data, not proof. The internal transfer caller must invoke
/// import only after native verification of the matching container/handoff.
class HistoryImportContext {
  const HistoryImportContext(
      {required this.origin,
      required this.accountId,
      required this.sourceDeviceId,
      required this.recipientDeviceId,
      required this.transferId,
      required this.digest,
      required this.snapshotCounter,
      required this.snapshotCreatedAt});
  final int snapshotCounter, snapshotCreatedAt;
  final String origin,
      accountId,
      sourceDeviceId,
      recipientDeviceId,
      transferId,
      digest;
  String get ledgerKey =>
      jsonEncode([origin, accountId, sourceDeviceId, transferId]);
  void checkSession(Session? session) {
    if (session == null ||
        session.baseUrl != origin ||
        session.accountId != accountId ||
        session.deviceId != recipientDeviceId ||
        sourceDeviceId == recipientDeviceId ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) _invalid();
    _id(sourceDeviceId);
    _id(transferId);
  }
}

class DeferredHistoryEffect {
  const DeferredHistoryEffect(
      {required this.accountId,
      required this.conversationId,
      required this.channelId,
      required this.targetKey,
      required this.actorAccountId,
      required this.deleted,
      required this.at,
      required this.order,
      this.body,
      this.formatJson});
  final String accountId, conversationId, targetKey, actorAccountId;
  final String? channelId, body, formatJson;
  final bool deleted;
  final int at, order;
  String get key => jsonEncode(
      [accountId, conversationId, channelId, targetKey, actorAccountId]);
  Map<String, Object?> toJson() => {
        'account': accountId,
        'conversation': conversationId,
        'channel': channelId,
        'target': targetKey,
        'actor': actorAccountId,
        'deleted': deleted,
        'at': at,
        'order': order,
        'body': body,
        'format': formatJson
      };
  factory DeferredHistoryEffect.fromJson(Object? value) {
    final j = _object(value, {
      'account',
      'conversation',
      'channel',
      'target',
      'actor',
      'deleted',
      'at',
      'order',
      'body',
      'format'
    });
    if (j['deleted'] is! bool ||
        (j['body'] != null && j['body'] is! String) ||
        (j['format'] != null && j['format'] is! String)) _invalid();
    final effect = DeferredHistoryEffect(
        accountId: _id(j['account']),
        conversationId: _id(j['conversation']),
        channelId: j['channel'] == null ? null : _id(j['channel']),
        targetKey: _id(j['target']),
        actorAccountId: _id(j['actor']),
        deleted: j['deleted'] as bool,
        at: _time(j['at']),
        order: _time(j['order']),
        body: j['body'] as String?,
        formatJson: j['format'] as String?);
    if (effect.deleted
        ? (effect.body != null || effect.formatJson != null)
        : effect.body == null) _invalid();
    return effect;
  }
}

/// Only callers holding authenticated native effects may populate this journal.
/// It is local materialized state, never an outgoing command or K2 payload.
void deferHistoryEffect(
    HistoryNamespace namespace, MessageEffect effect, String? accountId) {
  if (accountId == null) return;
  String? conversation, channel, body, format;
  late String target, actor;
  late int at;
  final deleted = effect is DeleteMessageEffect;
  switch (effect) {
    case EditMessageEffect():
      conversation = effect.conversationId;
      channel = effect.channelId;
      target = effect.targetKey;
      actor = effect.editorAccountId;
      at = effect.at;
      body = effect.body;
      format = effect.formatJson;
    case DeleteMessageEffect():
      conversation = effect.conversationId;
      channel = effect.channelId;
      target = effect.targetKey;
      actor = effect.deleterAccountId;
      at = effect.at;
    default:
      return;
  }
  if (conversation == null) return;
  final candidate = DeferredHistoryEffect(
      accountId: accountId,
      conversationId: conversation,
      channelId: channel,
      targetKey: target,
      actorAccountId: actor,
      deleted: deleted,
      at: at,
      order: namespace.effectOrder + 1,
      body: body,
      formatJson: format);
  if (namespace.deferred[candidate.key]?.deleted == true) return;
  final previous = namespace.deferred[candidate.key];
  namespace.deferred[candidate.key] = candidate;
  final size = namespace.deferred.values.fold<int>(
      0, (sum, e) => sum + utf8.encode(jsonEncode(e.toJson())).length);
  if (namespace.deferred.length > 4096 || size > 4 * 1024 * 1024) {
    if (previous == null) {
      namespace.deferred.remove(candidate.key);
    } else {
      namespace.deferred[candidate.key] = previous;
    }
    throw StateError('deferred history limit reached');
  }
  namespace.effectOrder = candidate.order;
}

LocalMessage applyDeferredHistory(
    HistoryNamespace namespace, LocalMessage message, String accountId,
    {bool targetAuthenticated = false}) {
  var result = message;
  final candidates = namespace.deferred.values
      .where((e) => e.accountId == accountId && e.targetKey == message.key)
      .toList()
    ..sort((a, b) => a.order.compareTo(b.order));
  for (final e in candidates) {
    if (e.conversationId != message.conversationId ||
        e.channelId != message.channelId ||
        e.actorAccountId != message.senderAccountId) {
      // A copied row has no original-sender proof. Its labels cannot erase
      // an authenticated live intent before the actual target arrives.
      if (targetAuthenticated) namespace.deferred.remove(e.key);
      continue;
    }
    if (e.deleted) {
      result = result.copyWith(
          body: const Value(null),
          formatJson: const Value(null),
          replyTo: const Value(null),
          deletedAt: Value(e.at));
      namespace.provenance[message.key]?['live_delete'] = true;
    } else if (result.kind == 'text' &&
        result.deletedAt == null &&
        result.hiddenAt == null &&
        result.senderHidden != true) {
      result = result.copyWith(
          body: Value(e.body),
          formatJson: Value(e.formatJson),
          editedAt: Value(e.at));
      namespace.provenance[message.key]?['live_edit'] = true;
      namespace.deferred.remove(e.key);
    }
  }
  return result;
}

void markLiveHistoryEffect(
    HistoryNamespace namespace, MessageEffect effect, String key) {
  final provenance = namespace.provenance[key];
  if (provenance == null) return;
  if (effect is EditMessageEffect) provenance['live_edit'] = true;
  if (effect is DeleteMessageEffect) provenance['live_delete'] = true;
}

class DirectHistoryMerge {
  DirectHistoryMerge(this.message, this.removed);
  final LocalMessage? message;
  final Set<String> removed;
}

DirectHistoryMerge reconcileDirectHistory(HistoryNamespace namespace,
    List<LocalMessage> existing, LocalMessage incoming, String? accountId) {
  final collisions = existing
      .where((m) =>
          m.key == incoming.key ||
          (incoming.serverMessageId != null &&
              m.serverMessageId == incoming.serverMessageId))
      .toList();
  if (collisions.isEmpty)
    return DirectHistoryMerge(
        accountId == null
            ? incoming
            : applyDeferredHistory(namespace, incoming, accountId,
                targetAuthenticated: true),
        {});
  bool copied(LocalMessage m) =>
      m.state == LocalMessageState.restored ||
      (namespace.provenance.containsKey(m.key) &&
          namespace.provenance[m.key]!['direct_received'] != true);
  final hasDirectCollision = collisions.any((m) => !copied(m));
  final removed = <String>{};
  var result = incoming;
  for (final old in collisions) {
    if (!copied(old)) continue;
    final same = old.key == incoming.key &&
        old.conversationId == incoming.conversationId &&
        old.channelId == incoming.channelId &&
        old.senderAccountId == incoming.senderAccountId &&
        old.senderDeviceId == incoming.senderDeviceId;
    if (same && !hasDirectCollision) {
      final provenance = namespace.provenance.putIfAbsent(
          old.key,
          () => {
                'source_device_id': incoming.senderDeviceId,
                'snapshot_counter': 0,
                'snapshot_created_at': old.createdAt
              });
      final preserve = old.hiddenAt != null ||
          old.deletedAt != null ||
          provenance['live_edit'] == true ||
          provenance['live_delete'] == true;
      if (preserve)
        result = incoming.copyWith(
            body: Value(old.body),
            formatJson: Value(old.formatJson),
            replyTo: Value(old.replyTo),
            hiddenAt: Value(old.hiddenAt),
            deletedAt: Value(old.deletedAt),
            editedAt: Value(old.editedAt));
      provenance['direct_received'] = true;
      provenance['body_provenance'] =
          preserve ? 'retained_snapshot_or_live_effect' : 'direct';
    } else {
      final provenance = namespace.provenance.remove(old.key);
      final identity = jsonEncode([
        accountId,
        old.conversationId,
        old.channelId,
        old.key,
        provenance?['source_device_id'],
        provenance?['transfer_id']
      ]);
      namespace.quarantine[identity] = {
        'message': _messageJson(old),
        'provenance': provenance,
        'reason': 'authenticated_direct_identity_conflict'
      };
      // Quarantine must never stall future authenticated MLS processing.
      while (namespace.quarantine.length > 128 ||
          utf8.encode(jsonEncode(namespace.quarantine)).length >
              4 * 1024 * 1024) {
        namespace.quarantine.remove(namespace.quarantine.keys.first);
      }
      removed.add(old.key);
    }
  }
  if (!hasDirectCollision && accountId != null)
    result = applyDeferredHistory(namespace, result, accountId,
        targetAuthenticated: true);
  return DirectHistoryMerge(hasDirectCollision ? null : result, removed);
}

class HistoryNamespace {
  HistoryNamespace(
      {this.counter = 0,
      this.effectOrder = 0,
      Map<String, DeferredHistoryEffect>? deferred,
      Map<String, Map<String, Object?>>? quarantine,
      Map<String, HistoryConversation>? conversations,
      Map<String, Map<String, Object?>>? provenance,
      Map<String, Map<String, Object?>>? imports})
      : quarantine = quarantine ?? {},
        deferred = deferred ?? {},
        conversations = conversations ?? {},
        provenance = provenance ?? {},
        imports = imports ?? {};
  int counter;
  int effectOrder;
  final Map<String, DeferredHistoryEffect> deferred;
  final Map<String, Map<String, Object?>> quarantine;
  final Map<String, HistoryConversation> conversations;
  final Map<String, Map<String, Object?>> provenance, imports;
  Map<String, Object?> toJson() => {
        'counter': counter,
        'effect_order': effectOrder,
        'deferred': deferred.map((key, value) => MapEntry(key, value.toJson())),
        'quarantine': quarantine,
        'conversations': conversations.values.map((c) => c.toJson()).toList(),
        'provenance': provenance,
        'imports': imports
      };
  factory HistoryNamespace.fromJson(Object? value) {
    final j = _object(value, {
      'counter',
      'effect_order',
      'deferred',
      'quarantine',
      'conversations',
      'provenance',
      'imports'
    });
    return HistoryNamespace(
        counter: _time(j['counter']),
        effectOrder: _time(j['effect_order']),
        deferred: {
          for (final e in (j['deferred'] as Map).entries)
            e.key as String: DeferredHistoryEffect.fromJson(e.value)
        },
        quarantine: {
          for (final e in (j['quarantine'] as Map).entries)
            e.key as String: Map<String, Object?>.from(e.value as Map)
        },
        conversations: {
          for (final c in j['conversations'] as List)
            HistoryConversation.fromJson(c).id: HistoryConversation.fromJson(c)
        },
        provenance: {
          for (final e in (j['provenance'] as Map).entries)
            _id(e.key): Map<String, Object?>.from(e.value as Map)
        },
        imports: {
          for (final e in (j['imports'] as Map).entries)
            e.key as String: Map<String, Object?>.from(e.value as Map)
        });
  }
  HistoryNamespace copy() => HistoryNamespace.fromJson(toJson());
}

class HistorySnapshot {
  HistorySnapshot(
      {required this.accountId,
      required this.sourceDeviceId,
      required this.counter,
      required this.createdAt,
      required this.conversations,
      required this.messages,
      required this.reactions,
      required this.pins,
      required this.starred,
      required this.preferences,
      this.origins = const {}});
  final String accountId, sourceDeviceId;
  final int counter, createdAt;
  final List<HistoryConversation> conversations;
  final List<LocalMessage> messages;
  final List<LocalMessageReaction> reactions;
  final List<LocalPin> pins;
  final Map<String, int> starred;
  final List<LocalConversationPref> preferences;

  /// Earlier own-device snapshots remain snapshots after another export.
  final Map<String, Map<String, Object?>> origins;

  List<int> encode() {
    final bytes = utf8.encode(jsonEncode({
      'version': 1,
      'account_id': accountId,
      'source_device_id': sourceDeviceId,
      'snapshot_counter': counter,
      'snapshot_created_at': createdAt,
      'conversations': conversations.map((c) => c.toJson()).toList(),
      'messages': messages.map(_messageJson).toList(),
      'reactions': reactions.map((r) => r.toJson()).toList(),
      'pins': pins.map((p) => p.toJson()).toList(),
      'starred': starred,
      'conversation_prefs': preferences.map((p) => p.toJson()).toList(),
      'origins': origins
    }));
    // Identical structural validation on both directions; explicit overflow.
    HistorySnapshot.decode(bytes);
    return bytes;
  }

  factory HistorySnapshot.decode(List<int> bytes) {
    try {
      final j = _object(strictHistoryJson(bytes), {
        'version',
        'account_id',
        'source_device_id',
        'snapshot_counter',
        'snapshot_created_at',
        'conversations',
        'messages',
        'reactions',
        'pins',
        'starred',
        'conversation_prefs',
        'origins'
      });
      if (j['version'] != 1) _invalid();
      final conversations = (j['conversations'] as List)
          .map(HistoryConversation.fromJson)
          .toList();
      if (conversations.length > 10000) _invalid();
      final byId = <String, HistoryConversation>{};
      for (final c in conversations) {
        if (byId.containsKey(c.id)) _invalid();
        byId[c.id] = c;
      }
      final keys = <String>{}, serverIds = <String>{};
      final messages = (j['messages'] as List).map((raw) {
        final m = _readMessage(raw);
        final c = byId[m.conversationId];
        if (c == null ||
            (c.kind == 'community_shared'
                ? m.channelId == null ||
                    !c.historicalChannelIds.contains(m.channelId)
                : m.channelId != null) ||
            !keys.add(m.key) ||
            (m.serverMessageId != null && !serverIds.add(m.serverMessageId!)))
          _invalid();
        return m;
      }).toList();
      final live = {
        for (final m in messages)
          if (_eligible(m)) m.key: m
      };
      final reactionKeys = <String>{};
      final reactions = (j['reactions'] as List).map((raw) {
        final r = LocalMessageReaction.fromJson(_object(
            raw, {'targetKey', 'reactorAccountId', 'reaction', 'updatedAt'}));
        if (!live.containsKey(r.targetKey) ||
            !reactionKeys.add(jsonEncode([r.targetKey, r.reactorAccountId])) ||
            r.reaction.isEmpty ||
            r.reaction.length > 64) _invalid();
        _id(r.reactorAccountId);
        _time(r.updatedAt);
        return r;
      }).toList();
      final pinKeys = <String>{};
      final pins = (j['pins'] as List).map((raw) {
        final p = LocalPin.fromJson(_object(raw, {
          'conversationId',
          'channelId',
          'targetKey',
          'pinnedByAccountId',
          'pinnedAt',
          'appliedOrder',
          'expiresAt'
        }));
        final m = live[p.targetKey];
        if (m == null ||
            m.conversationId != p.conversationId ||
            m.channelId != p.channelId ||
            !pinKeys.add(p.targetKey) ||
            p.expiresAt <= p.pinnedAt) _invalid();
        _id(p.pinnedByAccountId);
        _time(p.pinnedAt);
        _time(p.expiresAt);
        _time(p.appliedOrder);
        return p;
      }).toList();
      final starred = <String, int>{};
      for (final e in (j['starred'] as Map).entries) {
        if (!live.containsKey(e.key)) _invalid();
        starred[e.key as String] = _time(e.value);
      }
      final prefKeys = <String>{};
      final prefs = (j['conversation_prefs'] as List).map((raw) {
        final p = LocalConversationPref.fromJson(
            _object(raw, {'conversationId', 'archivedAt', 'pinnedAt'}));
        if (!byId.containsKey(p.conversationId) ||
            !prefKeys.add(p.conversationId)) _invalid();
        if (p.archivedAt != null) _time(p.archivedAt);
        if (p.pinnedAt != null) _time(p.pinnedAt);
        return p;
      }).toList();
      final origins = <String, Map<String, Object?>>{};
      for (final e in (j['origins'] as Map).entries) {
        if (!keys.contains(e.key)) _invalid();
        final o = _object(e.value,
            {'source_device_id', 'snapshot_counter', 'snapshot_created_at'});
        _id(o['source_device_id']);
        _time(o['snapshot_counter']);
        _time(o['snapshot_created_at']);
        origins[e.key as String] = o;
      }
      final counter = _time(j['snapshot_counter']);
      if (counter == 0) _invalid();
      return HistorySnapshot(
          accountId: _id(j['account_id']),
          sourceDeviceId: _id(j['source_device_id']),
          counter: counter,
          createdAt: _time(j['snapshot_created_at']),
          conversations: conversations,
          messages: messages,
          reactions: reactions,
          pins: pins,
          starred: starred,
          preferences: prefs,
          origins: origins);
    } catch (_) {
      _invalid();
    }
  }
}

const _messageFields = {
  'key',
  'serverMessageId',
  'conversationId',
  'senderAccountId',
  'senderDeviceId',
  'kind',
  'body',
  'replyTo',
  'createdAt',
  'editedAt',
  'deletedAt',
  'expiresAt',
  'hiddenAt',
  'formatJson',
  'forwardHops',
  'channelId',
  'senderHidden'
};
Map<String, Object?> _messageJson(LocalMessage m) => {
      for (final e in m.toJson().entries)
        if (_messageFields.contains(e.key)) e.key: e.value
    };

LocalMessage _readMessage(Object? raw) {
  final j = _object(raw, _messageFields);
  final key = _id(j['key']), device = _id(j['senderDeviceId']);
  if (!key.startsWith('$device:') || key.length <= device.length + 1)
    _invalid();
  _id(j['senderAccountId']);
  _id(j['conversationId']);
  _time(j['createdAt']);
  for (final f in ['editedAt', 'deletedAt', 'hiddenAt', 'expiresAt']) {
    if (j[f] != null) _time(j[f]);
  }
  for (final f in ['serverMessageId', 'replyTo', 'channelId']) {
    if (j[f] != null) _id(j[f]);
  }
  if (!const {
        'text',
        'attachment',
        'unsupported',
        'action',
        'invalid',
        'unverifiable'
      }.contains(j['kind']) ||
      (j['senderHidden'] != null && j['senderHidden'] is! bool) ||
      (j['forwardHops'] != null &&
          (j['forwardHops'] is! int ||
              (j['forwardHops'] as int) < 0 ||
              (j['forwardHops'] as int) > 5))) _invalid();
  j['state'] = 'restored';
  j['searchId'] = null;
  final m = LocalMessage.fromJson(j);
  if (m.body != null && utf8.encode(m.body!).length > 65536) _invalid();
  if (!_eligible(m) &&
      (m.body != null || m.formatJson != null || m.replyTo != null)) _invalid();
  if (m.kind == 'unsupported' && m.body != null) {
    final opaque = strictHistoryJson(utf8.encode(m.body!));
    if (opaque is! Map || opaque['hidden'] == true) _invalid();
  }
  if (m.formatJson != null) {
    if (m.kind != 'text' || m.body == null) _invalid();
    final d = _object(strictHistoryJson(utf8.encode(m.formatJson!)),
        {'entities', 'mentions'});
    if ((d['entities'] is List && (d['entities'] as List).length > 256) ||
        (d['mentions'] is List && (d['mentions'] as List).length > 50))
      _invalid();
    j['formatJson'] = jsonEncode(messageDecoration({...d, 'text': m.body}));
  }
  if (m.kind == 'attachment' && m.body != null) _validateAttachments(m);
  return LocalMessage.fromJson(j);
}

void _validateAttachments(LocalMessage m) {
  final list = strictHistoryJson(utf8.encode(m.body!));
  if (list is! List || list.length > 32) _invalid();
  for (final item in list) {
    if (item is! Map) _invalid();
    final crypto = _object(item, {
      'version',
      'algorithm',
      'key',
      'nonce_prefix',
      'chunk_size',
      'chunk_count',
      'plaintext_size',
      'conversation_id',
      'action_id',
      'file_name',
      'media_type',
      'id',
      'ciphertext_size'
    });
    if (crypto['id'] is! String ||
        crypto['file_name'] is! String ||
        crypto['media_type'] is! String ||
        crypto['version'] != 1 ||
        crypto['algorithm'] != 'AES-256-GCM-chunked' ||
        crypto['conversation_id'] != m.conversationId ||
        crypto['action_id'] != m.key.substring(m.senderDeviceId.length + 1) ||
        base64Decode(crypto['key'] as String).length != 32 ||
        base64Decode(crypto['nonce_prefix'] as String).length != 8 ||
        crypto['chunk_size'] != 1048576 ||
        crypto['plaintext_size'] is! int ||
        (crypto['plaintext_size'] as int) <= 0 ||
        (crypto['plaintext_size'] as int) > 48 * 1024 * 1024 ||
        crypto['chunk_count'] !=
            ((crypto['plaintext_size'] as int) + 1048575) ~/ 1048576 ||
        crypto['ciphertext_size'] !=
            (crypto['plaintext_size'] as int) +
                (crypto['chunk_count'] as int) * 20) _invalid();
  }
}

bool _eligible(LocalMessage m) =>
    m.hiddenAt == null &&
    m.deletedAt == null &&
    m.senderHidden != true &&
    const {'text', 'attachment', 'unsupported'}.contains(m.kind);

LocalMessage historyMessageFromInsert(InsertMessageEffect effect) =>
    LocalMessage(
        key: effect.key,
        serverMessageId: effect.serverMessageId,
        conversationId: effect.conversationId,
        senderAccountId: effect.senderAccountId,
        senderDeviceId: effect.senderDeviceId,
        kind: effect.kind,
        body: effect.body,
        replyTo: effect.replyTo,
        createdAt: effect.createdAt,
        state: effect.state,
        expiresAt: effect.expiresAt,
        formatJson: effect.formatJson,
        forwardHops: effect.forwardHops,
        channelId: effect.channelId,
        senderHidden: effect.senderHidden);

HistorySnapshot captureHistory(
    {required Session session,
    required HistoryNamespace namespace,
    required List<Conversation> conversations,
    required List<LocalMessage> messages,
    required List<LocalMessageReaction> reactions,
    required List<LocalPin> pins,
    required Map<String, int> starred,
    required List<LocalConversationPref> preferences,
    required int now}) {
  final descriptors =
      Map<String, HistoryConversation>.of(namespace.conversations);
  for (final c in conversations) {
    final d = HistoryConversation(c.id, c.kind,
        communityId: c.communityId, channelId: c.channelId, title: c.title);
    if (descriptors[c.id] != null && !descriptors[c.id]!.sameMapping(d))
      _invalid();
    descriptors[c.id] = d;
  }
  for (final d in descriptors.values.toList()) {
    if (d.kind != 'community_shared') continue;
    final channels = <String>{
      ...d.historicalChannelIds,
      for (final m in messages)
        if (m.conversationId == d.id && m.channelId != null) m.channelId!
    };
    descriptors[d.id] = HistoryConversation(d.id, d.kind,
        communityId: d.communityId,
        title: d.title,
        historicalChannelIds: channels.toList()..sort());
  }
  final rows = <LocalMessage>[];
  for (final m in messages) {
    if (m.kind == 'invalid' || m.kind == 'unverifiable') continue;
    if (m.state == 'pending' || (m.expiresAt != null && m.expiresAt! <= now))
      continue;
    if (!descriptors.containsKey(m.conversationId)) _invalid();
    // Unsupported hidden controls from pre-W8 databases also remain hidden.
    var hidden = m.senderHidden == true;
    if (m.kind == 'unsupported' && m.body != null) {
      final raw = strictHistoryJson(utf8.encode(m.body!));
      hidden |= raw is Map && raw['hidden'] == true;
    }
    final clean = m.copyWith(senderHidden: Value(hidden));
    rows.add(_eligible(clean)
        ? clean
        : clean.copyWith(
            body: const Value(null),
            formatJson: const Value(null),
            replyTo: const Value(null)));
  }
  final live = {
    for (final m in rows)
      if (_eligible(m)) m.key
  };
  final result = HistorySnapshot(
      accountId: _id(session.accountId),
      sourceDeviceId: _id(session.deviceId),
      counter: namespace.counter + 1,
      createdAt: now,
      conversations: descriptors.values.toList(),
      messages: rows,
      reactions: reactions.where((r) => live.contains(r.targetKey)).toList(),
      pins: pins
          .where((p) => live.contains(p.targetKey) && p.expiresAt > now)
          .toList(),
      starred: {
        for (final e in starred.entries)
          if (live.contains(e.key)) e.key: e.value
      },
      preferences: preferences,
      origins: {
        for (final m in rows)
          if (namespace.provenance.containsKey(m.key) || m.state == 'restored')
            m.key: {
              for (final f in [
                'source_device_id',
                'snapshot_counter',
                'snapshot_created_at'
              ])
                f: namespace.provenance[m.key]?[f] ??
                    (f == 'source_device_id'
                        ? session.deviceId
                        : f == 'snapshot_counter'
                            ? 0
                            : now)
            }
      });
  return HistorySnapshot.decode(result.encode());
}

class HistoryMerge {
  HistoryMerge(this.namespace, this.messages, this.reactions, this.pins,
      this.starred, this.preferences);
  final HistoryNamespace namespace;
  final List<LocalMessage> messages;
  final List<LocalMessageReaction> reactions;
  final List<LocalPin> pins;
  final Map<String, int> starred;
  final List<LocalConversationPref> preferences;
}

HistoryMerge mergeHistory(
    {required HistorySnapshot snapshot,
    required HistoryImportContext context,
    required HistoryNamespace namespace,
    required List<Conversation> liveConversations,
    required List<LocalMessage> existing,
    required List<LocalPin> existingPins,
    required List<LocalConversationPref> existingPreferences,
    required int now}) {
  if (snapshot.accountId != context.accountId ||
      snapshot.sourceDeviceId != context.sourceDeviceId ||
      snapshot.counter != context.snapshotCounter ||
      snapshot.createdAt != context.snapshotCreatedAt) _invalid();
  final ledger = namespace.imports[context.ledgerKey];
  if (ledger != null) {
    if (ledger['digest'] != context.digest) _invalid();
    return HistoryMerge(namespace, [], [], [], {}, []);
  }
  final next = namespace.copy();
  final known = {
    ...namespace.conversations,
    for (final c in liveConversations)
      c.id: HistoryConversation(c.id, c.kind,
          communityId: c.communityId, channelId: c.channelId)
  };
  for (final d in snapshot.conversations) {
    if ((known[d.id] != null && !known[d.id]!.sameMapping(d)) ||
        (namespace.conversations[d.id] != null &&
            !namespace.conversations[d.id]!.sameMapping(d))) _invalid();
    next.conversations.putIfAbsent(d.id, () => d);
    if (d.kind == 'community_shared') {
      final previous = next.conversations[d.id]!;
      next.conversations[d.id] = HistoryConversation(d.id, d.kind,
          communityId: d.communityId,
          title: previous.title,
          historicalChannelIds: {
            ...previous.historicalChannelIds,
            ...d.historicalChannelIds
          }.toList()
            ..sort());
    }
  }
  final byKey = {for (final m in existing) m.key: m};
  final byServer = {
    for (final m in existing)
      if (m.serverMessageId != null) m.serverMessageId!: m.key
  };
  final added = <LocalMessage>[];
  for (final m in snapshot.messages) {
    final old = byKey[m.key];
    if (old != null &&
        (old.conversationId != m.conversationId ||
            old.channelId != m.channelId ||
            old.senderAccountId != m.senderAccountId ||
            old.senderDeviceId != m.senderDeviceId ||
            (old.serverMessageId != null &&
                m.serverMessageId != null &&
                old.serverMessageId != m.serverMessageId))) _invalid();
    if (m.serverMessageId != null &&
        byServer[m.serverMessageId] != null &&
        byServer[m.serverMessageId] != m.key) _invalid();
    if (old != null || (m.expiresAt != null && m.expiresAt! <= now)) continue;
    next.provenance[m.key] = {
      'source_device_id': snapshot.origins[m.key]?['source_device_id'] ??
          context.sourceDeviceId,
      'snapshot_counter':
          snapshot.origins[m.key]?['snapshot_counter'] ?? snapshot.counter,
      'snapshot_created_at':
          snapshot.origins[m.key]?['snapshot_created_at'] ?? snapshot.createdAt,
      'received_from_device_id': context.sourceDeviceId,
      'transfer_id': context.transferId,
      'origin': context.origin
    };
    added.add(applyDeferredHistory(next, m, context.accountId));
  }
  final keys = added.where(_eligible).map((m) => m.key).toSet();
  final pins = <LocalPin>[];
  var order = existingPins.fold<int>(
      0, (max, p) => p.appliedOrder > max ? p.appliedOrder : max);
  final sorted = List<LocalPin>.of(snapshot.pins)
    ..sort((a, b) {
      final t = a.pinnedAt.compareTo(b.pinnedAt);
      return t != 0 ? t : a.appliedOrder.compareTo(b.appliedOrder);
    });
  for (final p in sorted) {
    if (known.containsKey(p.conversationId) ||
        !keys.contains(p.targetKey) ||
        p.expiresAt <= now) continue;
    final m = added.firstWhere((m) => m.key == p.targetKey);
    final expiry = m.expiresAt != null && m.expiresAt! < p.expiresAt
        ? m.expiresAt!
        : p.expiresAt;
    pins.add(p.copyWith(appliedOrder: ++order, expiresAt: expiry));
    final same = pins
        .where((x) =>
            x.conversationId == p.conversationId && x.channelId == p.channelId)
        .toList();
    if (same.length > pinLimitPerChat) pins.remove(same.first);
  }
  var pinnedCount = existingPreferences.where((p) => p.pinnedAt != null).length;
  final prefs = <LocalConversationPref>[];
  for (final p in snapshot.preferences) {
    if (known.containsKey(p.conversationId) ||
        existingPreferences.any((e) => e.conversationId == p.conversationId))
      continue;
    final pin = p.pinnedAt != null && pinnedCount < 5 ? p.pinnedAt : null;
    if (pin != null) pinnedCount++;
    prefs.add(p.copyWith(pinnedAt: Value(pin)));
  }
  next.imports[context.ledgerKey] = {
    'digest': context.digest,
    'snapshot_counter': snapshot.counter,
    'snapshot_created_at': snapshot.createdAt,
    'imported_at': now
  };
  return HistoryMerge(
      next,
      added,
      snapshot.reactions.where((r) => keys.contains(r.targetKey)).toList(),
      pins,
      {
        for (final e in snapshot.starred.entries)
          if (keys.contains(e.key)) e.key: e.value
      },
      prefs);
}
