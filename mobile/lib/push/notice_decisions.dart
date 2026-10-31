import '../core/models.dart';
import '../storage/encrypted_database.dart' show LocalMessage;
import '../storage/local_store.dart';
import 'message_notice_policy.dart';

/// What the processor knows about one reference right now.
enum NoticeEligibility { eligible, ineligible, unknown }

/// The current policy inputs, read fresh for every pass. A `null` answer
/// means "not known": the reference stays pending, never treated as allowed.
class NoticePolicy {
  const NoticePolicy({
    required this.blocked,
    required this.conversationAccepted,
    required this.muted,
    required this.mentionsInMutedChats,
  });

  /// Whether [accountId] is blocked, or null when the block list is unknown.
  final Future<bool?> Function(String accountId) blocked;

  /// D48 acceptance of the conversation, or null when it is unknown.
  final bool? Function(String conversationId) conversationAccepted;

  /// A fresh mute read, or null when it could not be read.
  final Future<bool?> Function(String conversationId) muted;
  final bool mentionsInMutedChats;
}

/// Result of one pass. [durable] is true only when every reference seen was
/// either decided terminally or proven ineligible; a native wake may then be
/// acknowledged. [shown] counts generic notices native reported as shown.
class NoticePassResult {
  const NoticePassResult({required this.durable, required this.shown});
  final bool durable;
  final int shown;
}

/// Turns the private notice outbox (D52) into at most a few generic notices.
///
/// Every decision is made on this device from rows already committed by
/// authenticated decryption. No text, sender name or conversation ID leaves
/// this class: native receives only the opaque decision ID. Missing policy
/// data leaves the reference pending; it never alerts.
class LocalNoticeProcessor {
  LocalNoticeProcessor({
    required this.store,
    required this.session,
    required this.policy,
    required this.present,
    this.check,
    DateTime Function()? now,
    this.maxBatches = 3,
  }) : _now = now ?? DateTime.now;

  final LocalStore store;
  final Session session;
  final NoticePolicy policy;

  /// Native generic notice for one durable decision ID.
  final Future<LocalNoticeOutcome> Function(String decisionId) present;

  /// The permit/owner fence, checked before every durable mutation.
  final void Function()? check;
  final DateTime Function() _now;
  final int maxBatches;

  LocalNoticeOwner? get owner {
    final account = session.accountId, device = session.deviceId;
    if (account == null || device == null) return null;
    return LocalNoticeOwner(
        origin: session.baseUrl, accountId: account, deviceId: device);
  }

  Future<NoticePassResult> run() async {
    final scope = owner;
    if (scope == null) {
      return const NoticePassResult(durable: false, shown: 0);
    }
    var shown = 0;
    final rows = <String, Map<String, LocalMessage>>{};
    final mutes = <String, bool?>{};

    // A decision frozen by an earlier pass whose answer was lost keeps its ID,
    // so native recognizes a retry instead of alerting twice.
    final frozen = await store.pendingNoticeDecision(scope,
        now: _ms(), checkCanCommit: check);
    if (frozen != null) {
      final outcome = await _decide(scope, frozen, rows, mutes);
      if (outcome == null)
        return const NoticePassResult(durable: false, shown: 0);
      if (outcome == LocalNoticeOutcome.unavailable) {
        return NoticePassResult(durable: false, shown: shown);
      }
      if (outcome == LocalNoticeOutcome.shown) shown++;
    }

    for (var batch = 0; batch < maxBatches; batch++) {
      final pending = await store.pendingNoticeReferences(scope,
          now: _ms(), checkCanCommit: check);
      if (pending.isEmpty) return NoticePassResult(durable: true, shown: shown);
      final eligible = <String>[], ineligible = <String>[];
      var unknown = 0;
      for (final reference in pending) {
        switch (await _evaluate(reference, rows, mutes)) {
          case NoticeEligibility.eligible:
            eligible.add(reference.id);
          case NoticeEligibility.ineligible:
            ineligible.add(reference.id);
          case NoticeEligibility.unknown:
            unknown++;
        }
      }
      if (ineligible.isNotEmpty) {
        await store.suppressNoticeReferences(scope, ineligible,
            now: _ms(), checkCanCommit: check);
      }
      if (eligible.isNotEmpty) {
        final decision = await store.freezeNoticeDecision(scope, eligible,
            now: _ms(), checkCanCommit: check);
        if (decision == null)
          return NoticePassResult(durable: false, shown: shown);
        final outcome = await _decide(scope, decision, rows, mutes);
        if (outcome == null || outcome == LocalNoticeOutcome.unavailable) {
          return NoticePassResult(durable: false, shown: shown);
        }
        if (outcome == LocalNoticeOutcome.shown) shown++;
      }
      if (unknown > 0) {
        // Left pending for the next opportunity; another batch would read
        // the same undecidable references again.
        return NoticePassResult(durable: false, shown: shown);
      }
    }
    final rest = await store.pendingNoticeReferences(scope,
        limit: 1, now: _ms(), checkCanCommit: check);
    return NoticePassResult(durable: rest.isEmpty, shown: shown);
  }

  /// Re-reads every frozen reference before presenting: an edit, deletion,
  /// block or new mute since freezing suppresses the decision durably.
  /// Returns null when the policy could not be read (decision stays frozen).
  Future<LocalNoticeOutcome?> _decide(
      LocalNoticeOwner scope,
      LocalNoticeDecision decision,
      Map<String, Map<String, LocalMessage>> rows,
      Map<String, bool?> mutes) async {
    // Fresh rows and mute state, read once for this decision.
    rows.clear();
    mutes.clear();
    var anyEligible = false;
    for (final reference in decision.references) {
      final verdict = await _evaluate(reference, rows, mutes);
      if (verdict == NoticeEligibility.unknown) return null;
      if (verdict == NoticeEligibility.eligible) anyEligible = true;
    }
    if (!anyEligible) {
      await store.finishNoticeDecision(
          scope, decision.id, LocalNoticeOutcome.suppressed,
          now: _ms(), checkCanCommit: check);
      return LocalNoticeOutcome.suppressed;
    }
    check?.call();
    final outcome = await present(decision.id);
    await store.finishNoticeDecision(scope, decision.id, outcome,
        now: _ms(), checkCanCommit: check);
    return outcome;
  }

  Future<NoticeEligibility> _evaluate(
      LocalNoticeReference reference,
      Map<String, Map<String, LocalMessage>> rows,
      Map<String, bool?> mutes) async {
    if (!reference.owner.matchesSession(session)) {
      return NoticeEligibility.ineligible;
    }
    final conversation = reference.conversationId;
    final byKey = rows[conversation] ??= {
      for (final row in await store.loadMessages(conversation)) row.key: row
    };
    final now = _now();
    final candidate = messageNoticeCandidateForContext(
        session: session,
        envelope: NoticeMessageContext(
            serverMessageId: reference.serverMessageId,
            conversationId: conversation,
            senderAccountId: reference.senderAccountId,
            senderDeviceId: reference.senderDeviceId,
            messageKey: reference.messageKey,
            createdAt: DateTime.fromMillisecondsSinceEpoch(reference.createdAt,
                isUtc: true),
            expiresAt: reference.expiresAt == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(reference.expiresAt!,
                    isUtc: true)),
        message: byKey[reference.messageKey],
        now: now,
        // Block and acceptance are applied below, where "unknown" differs
        // from "no".
        blocked: false,
        conversationAccepted: true,
        includeGenericAttachments: true);
    if (candidate == null) return NoticeEligibility.ineligible;
    final blocked = await policy.blocked(reference.senderAccountId);
    if (blocked == null) return NoticeEligibility.unknown;
    if (blocked) return NoticeEligibility.ineligible;
    final accepted = policy.conversationAccepted(conversation);
    if (accepted == null) return NoticeEligibility.unknown;
    if (!accepted) return NoticeEligibility.ineligible;
    final muted = mutes.containsKey(conversation)
        ? mutes[conversation]
        : (mutes[conversation] = await policy.muted(conversation));
    if (muted == null) return NoticeEligibility.unknown;
    if (!muted) return NoticeEligibility.eligible;
    return candidate.allowedWhenMuted(
            mentionsInMutedChats: policy.mentionsInMutedChats)
        ? NoticeEligibility.eligible
        : NoticeEligibility.ineligible;
  }

  int _ms() => _now().millisecondsSinceEpoch;
}
