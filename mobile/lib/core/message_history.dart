import 'dart:convert';

import '../storage/encrypted_database.dart'
    show LocalMessage, LocalMessageKind, LocalMessageReaction;
import 'models.dart';

/// Decrypted history for one conversation, read from the encrypted local
/// database (D23). The server's envelope list still supplies order and
/// paging; this supplies what each envelope says.
///
/// Envelopes are matched by `<sender_device_id>:<idempotency_key>`, the same
/// key the MLS payload authenticated (D22). The sender shown for a message
/// comes from the local record, never from the server's envelope.
class ConversationHistory {
  ConversationHistory({
    required this.conversationId,
    required List<LocalMessage> messages,
    required List<LocalMessageReaction> reactions,
  })  : _byKey = <String, LocalMessage>{
          for (final message in messages)
            if (message.conversationId == conversationId) message.key: message,
        },
        _byServerId = <String, LocalMessage>{
          for (final message in messages)
            if (message.conversationId == conversationId &&
                message.serverMessageId != null)
              message.serverMessageId!: message,
        } {
    for (final message in _byKey.values) {
      if (message.kind == LocalMessageKind.unsupported &&
          _isHiddenPayload(message.body)) {
        _hiddenKeys.add(message.key);
      }
    }
    for (final reaction in reactions) {
      if (!_byKey.containsKey(reaction.targetKey)) continue;
      (_reactions[reaction.targetKey] ??= <LocalMessageReaction>[])
          .add(reaction);
    }
    for (final list in _reactions.values) {
      list.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    }
  }

  ConversationHistory.empty(this.conversationId)
      : _byKey = const <String, LocalMessage>{},
        _byServerId = const <String, LocalMessage>{};

  final String conversationId;
  final Map<String, LocalMessage> _byKey;

  /// Rows by the server envelope that produced them. Placeholder rows are
  /// keyed by sync event, not by the envelope's claimed idempotency key
  /// (P3), so this is how their envelope finds them.
  final Map<String, LocalMessage> _byServerId;
  final Set<String> _hiddenKeys = <String>{};
  final Map<String, List<LocalMessageReaction>> _reactions =
      <String, List<LocalMessageReaction>>{};

  static String keyOf(String senderDeviceId, String idempotencyKey) =>
      '$senderDeviceId:$idempotencyKey';

  LocalMessage? forKey(String key) => _byKey[key];

  /// Every local record, in no particular order.
  Iterable<LocalMessage> get messages => _byKey.values;

  LocalMessage? forEnvelope(ReceivedMessageEnvelope envelope) {
    if (envelope.conversationId != conversationId) return null;
    return _byServerId[envelope.id] ??
        _byKey[keyOf(envelope.senderDeviceId, envelope.idempotencyKey)];
  }

  /// Edit, delete and reaction envelopes change another message; they are
  /// not drawn as bubbles of their own.
  /// An unsupported control message the sender marked `hidden` is stored but
  /// never drawn (S2).
  bool hides(ReceivedMessageEnvelope envelope) {
    final local = forEnvelope(envelope);
    return local != null &&
        (local.kind == LocalMessageKind.action ||
            _hiddenKeys.contains(local.key));
  }

  static bool _isHiddenPayload(String? rawJson) {
    if (rawJson == null) return false;
    try {
      final decoded = jsonDecode(rawJson);
      return decoded is Map && decoded['hidden'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Reactions on [key], grouped by emoji with a count, oldest first.
  List<({String reaction, int count, bool mine})> reactionsFor(
    String key, {
    String? ownAccountId,
  }) {
    final groups = <String, ({String reaction, int count, bool mine})>{};
    for (final item in _reactions[key] ?? const <LocalMessageReaction>[]) {
      final previous = groups[item.reaction];
      final mine = item.reactorAccountId == ownAccountId;
      groups[item.reaction] = (
        reaction: item.reaction,
        count: (previous?.count ?? 0) + 1,
        mine: (previous?.mine ?? false) || mine,
      );
    }
    return groups.values.toList(growable: false);
  }
}
