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
  }) : _byKey = <String, LocalMessage>{
          for (final message in messages)
            if (message.conversationId == conversationId) message.key: message,
        } {
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
      : _byKey = const <String, LocalMessage>{};

  final String conversationId;
  final Map<String, LocalMessage> _byKey;
  final Map<String, List<LocalMessageReaction>> _reactions =
      <String, List<LocalMessageReaction>>{};

  static String keyOf(String senderDeviceId, String idempotencyKey) =>
      '$senderDeviceId:$idempotencyKey';

  LocalMessage? forKey(String key) => _byKey[key];

  /// Every local record, in no particular order.
  Iterable<LocalMessage> get messages => _byKey.values;

  LocalMessage? forEnvelope(ReceivedMessageEnvelope envelope) {
    if (envelope.conversationId != conversationId) return null;
    return _byKey[keyOf(envelope.senderDeviceId, envelope.idempotencyKey)];
  }

  /// Edit, delete and reaction envelopes change another message; they are
  /// not drawn as bubbles of their own.
  bool hides(ReceivedMessageEnvelope envelope) =>
      forEnvelope(envelope)?.kind == LocalMessageKind.action;

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
