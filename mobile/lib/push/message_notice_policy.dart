import '../core/models.dart';
import '../crypto/message_format.dart';
import '../storage/encrypted_database.dart'
    show LocalMessage, LocalMessageKind, LocalMessageState;

/// Content eligibility shared by desktop notices and future bounded mobile
/// wake work. Call only with a row already committed by authenticated decrypt.
/// Permission, foreground state, deduplication and fresh mute lookup stay with
/// the caller. Missing policy data must never be interpreted as unmuted.
class MessageNoticeCandidate {
  const MessageNoticeCandidate({
    required this.text,
    required this.mentionsAccount,
    required this.concealsSpoiler,
  });

  final String text;
  final bool mentionsAccount;
  final bool concealsSpoiler;

  bool allowedWhenMuted({required bool mentionsInMutedChats}) =>
      mentionsInMutedChats && mentionsAccount;
}

/// Metadata accompanying a committed authenticated local row. This is not
/// cryptographic proof by itself, and contains no ciphertext or manifest.
class NoticeMessageContext {
  const NoticeMessageContext(
      {required this.serverMessageId,
      required this.conversationId,
      required this.senderAccountId,
      required this.senderDeviceId,
      required this.messageKey,
      required this.createdAt,
      this.expiresAt,
      this.editedAt,
      this.deletedAt});
  factory NoticeMessageContext.fromEnvelope(ReceivedMessageEnvelope envelope) =>
      NoticeMessageContext(
          serverMessageId: envelope.id,
          conversationId: envelope.conversationId,
          senderAccountId: envelope.senderAccountId,
          senderDeviceId: envelope.senderDeviceId,
          messageKey: '${envelope.senderDeviceId}:${envelope.idempotencyKey}',
          createdAt: envelope.createdAt,
          expiresAt: envelope.expiresAt,
          editedAt: envelope.editedAt,
          deletedAt: envelope.deletedAt);
  final String serverMessageId,
      conversationId,
      senderAccountId,
      senderDeviceId,
      messageKey;
  final DateTime createdAt;
  final DateTime? expiresAt, editedAt, deletedAt;
}

MessageNoticeCandidate? messageNoticeCandidate({
  required Session session,
  required ReceivedMessageEnvelope envelope,
  required LocalMessage? message,
  required DateTime now,
  required bool blocked,
  required bool conversationAccepted,
  Duration freshness = const Duration(minutes: 10),
  bool includeGenericAttachments = false,
}) =>
    messageNoticeCandidateForContext(
        session: session,
        envelope: NoticeMessageContext.fromEnvelope(envelope),
        message: message,
        now: now,
        blocked: blocked,
        conversationAccepted: conversationAccepted,
        freshness: freshness,
        includeGenericAttachments: includeGenericAttachments);

MessageNoticeCandidate? messageNoticeCandidateForContext({
  required Session session,
  required NoticeMessageContext envelope,
  required LocalMessage? message,
  required DateTime now,
  required bool blocked,
  required bool conversationAccepted,
  Duration freshness = const Duration(minutes: 10),
  bool includeGenericAttachments = false,
}) {
  final account = session.accountId;
  final device = session.deviceId;
  if (account == null ||
      device == null ||
      blocked ||
      !conversationAccepted ||
      envelope.senderAccountId == account ||
      envelope.senderDeviceId == device ||
      envelope.editedAt != null ||
      envelope.deletedAt != null ||
      envelope.createdAt.isAfter(now.add(const Duration(minutes: 2))) ||
      now.difference(envelope.createdAt) > freshness ||
      (envelope.expiresAt != null && !now.isBefore(envelope.expiresAt!))) {
    return null;
  }
  if (message == null ||
      (message.kind != LocalMessageKind.text &&
          !(includeGenericAttachments &&
              message.kind == LocalMessageKind.attachment)) ||
      message.state == LocalMessageState.restored ||
      message.body == null ||
      message.deletedAt != null ||
      message.editedAt != null ||
      message.hiddenAt != null ||
      message.senderHidden == true ||
      message.conversationId != envelope.conversationId ||
      message.senderAccountId != envelope.senderAccountId ||
      message.senderDeviceId != envelope.senderDeviceId ||
      message.createdAt != envelope.createdAt.millisecondsSinceEpoch ||
      message.key != envelope.messageKey ||
      (message.expiresAt != null &&
          message.expiresAt! <= now.millisecondsSinceEpoch)) {
    return null;
  }
  if (message.kind == LocalMessageKind.attachment) {
    // The phone path may show the fixed generic notice for a fresh committed
    // attachment. Its manifest is never rendered as a notification preview.
    return const MessageNoticeCandidate(
        text: '', mentionsAccount: false, concealsSpoiler: false);
  }
  // Revalidate ranges as well as account IDs. Raw @name text and malformed
  // backup decoration cannot turn a muted message into a mention notice.
  final decoration = messageDecoration({
    ...decodeDecoration(message.formatJson),
    'text': message.body!,
  });
  final mentions = decoration['mentions'] as List? ?? const [];
  final entities = decoration['entities'] as List? ?? const [];
  return MessageNoticeCandidate(
    text: message.body!,
    mentionsAccount: mentions.any((m) => m['account_id'] == account),
    concealsSpoiler: entities.any((e) => e['type'] == 'spoiler'),
  );
}
