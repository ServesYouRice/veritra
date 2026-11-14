import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/attachments.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../storage/encrypted_database.dart'
    show LocalMessage, LocalMessageKind;
import '../../ui/format.dart';

/// Most characters of a message a chat row quotes; the row ellipsises the rest.
const int _previewLength = 100;

/// Bidirectional overrides and isolates. A sender could use them to make a
/// preview read in another order than the chat shows it.
final RegExp _bidiControls =
    RegExp(r'[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]');

/// "sender: first words" for a chat row (U12), or null when the row falls back
/// to its kind line. [row] comes from the local store only (`chatPreviewFor`).
///
/// - Text is its first words; a spoiler is the usual hidden-spoiler line.
/// - An attachment, a voice note and a poll are a placeholder, never the file
///   name, a question or an option.
/// - Nothing quotes a message of a conversation that is still a request, one
///   this device could not verify or understand (D25), a deleted one, or one
///   from an account this device blocked.
/// - Your own message starts with "You"; in a group or channel another
///   person's starts with their name. In a chat of two the title already says
///   who is speaking, so their messages start with no name.
String? chatPreviewLine(
  AppLocalizations l10n,
  AppState state,
  Conversation conversation,
  LocalMessage? row,
) {
  // Nothing of a request is quoted before it is accepted (B8).
  if (state.requestBucket(conversation) != RequestBucket.chat) return null;
  if (row == null || row.deletedAt != null) return null;
  if (state.isBlocked(row.senderAccountId)) return null;
  final String? body;
  switch (row.kind) {
    case LocalMessageKind.text:
      if (row.body == null) return null;
      body = row.formatJson?.contains('spoiler') == true
          ? l10n.w8HiddenSpoiler
          : _firstWords(row.body!);
    case LocalMessageKind.attachment:
      final entries = AttachmentEntry.listFromBody(row.body,
          conversationId: row.conversationId);
      body = entries.isEmpty
          ? l10n.chatAttachment
          : entries.first.isVoiceNote
              ? l10n.chatPreviewVoiceNote
              : entries.first.isImage
                  ? l10n.chatPreviewPhoto
                  : l10n.chatAttachment;
    case LocalMessageKind.poll:
      body = l10n.chatPreviewPoll;
    default:
      return null;
  }
  if (body.isEmpty) return null;
  if (row.senderAccountId == state.session?.accountId) {
    return l10n.chatPreviewYou(body);
  }
  if (conversation.isDm) return body;
  return l10n.chatPreviewFrom(_senderName(state, conversation, row), body);
}

String _firstWords(String text) {
  final collapsed = text
      .replaceAll(_bidiControls, '')
      .replaceAll(RegExp(r'[\p{Cc}\p{Zl}\p{Zp}\s]+', unicode: true), ' ')
      .trim();
  final characters = collapsed.characters;
  return characters.length <= _previewLength
      ? collapsed
      : characters.take(_previewLength).toString();
}

/// A person's name as shared with this device, else the username of the member
/// record, else the short account ID. Only the local row names the sender.
String _senderName(
    AppState state, Conversation conversation, LocalMessage row) {
  final shared = state.profileNameOf(row.senderAccountId);
  if (shared != null && shared.isNotEmpty) return shared;
  final username = state
      .membersFor(conversation.id)
      .where((member) => member.accountId == row.senderAccountId)
      .map((member) => member.username)
      .firstOrNull;
  return accountLabel(row.senderAccountId, username);
}
