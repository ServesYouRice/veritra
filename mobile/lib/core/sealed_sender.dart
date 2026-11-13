import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../crypto/crypto_service.dart'
    show SealedFrankContext, SealedSendingCryptoService, SealedTokenSource;
import '../storage/local_store.dart'
    show LocalStore, PendingEnvelopeRecord, SealedKeyPin;
import 'api_client.dart';
import 'models.dart';

// L2-3 sealed sender, the app side (D123; docs/crypto.md, "Sealed sender
// with VOPRF tokens" and its "App step, as built").
//
// - [SealedSender] keeps the per-conversation token state, fetches tokens on
//   the foreground sync pass (never right before a send), pins the server's
//   POPRF key per origin, and hands a send a token ([SealedTokenSource]).
// - [SealedPostClient] posts a sealed message on its own HTTP client: no
//   session token, no cookies, no connection shared with the session's
//   client.
// - [sealedPostOutcome] classifies a refused post for the outbox. A message
//   chosen to go sealed stays sealed: it is retried under the same
//   idempotency key (with a fresh token where the token was the problem),
//   never posted identified on its own, so a post that may have landed is
//   never stored twice and a server cannot unmask a sender by refusing.
//   After a 409 `sealed_not_eligible` the message waits in the outbox,
//   marked "couldn't send hidden", until the person chooses to send it
//   normally ([reencryptSealedForResend]) or discards it (owner decision
//   2026-11-12, "Ask before re-sending").

/// The sync event of a sealed post. Only an app that reads sealed events
/// (`sealed=1`) is ever served one.
const String sealedMessageEventType = 'message.sealed.created';

/// The failure class the outbox records for a sealed post the server
/// refused with 409 `sealed_not_eligible`.
const String sealedRefusedFailureClass = 'terminal:409:sealed_not_eligible';

/// Whether [record] is a sealed message the server would not take hidden
/// (409 `sealed_not_eligible`), waiting for the person's choice: send it
/// normally, or discard it. Nothing is sent for it until they choose.
bool sealedNeedsResendChoice(PendingEnvelopeRecord record) =>
    record.terminal &&
    record.envelope.sealed &&
    record.failureClass == sealedRefusedFailureClass;

/// What [reencryptSealedForResend] did.
enum SealedResend {
  /// The message was encrypted afresh, identified, under the same key, and
  /// took the sealed entry's place in the outbox; the outbox worker sends
  /// it like any other.
  queued,

  /// An MLS control message is queued for the conversation (I34, D68):
  /// nothing was encrypted; the person can try again once it is delivered.
  held,

  /// It cannot be sent identified (this build cannot seal, its plaintext is
  /// no longer kept, or the entry is gone). Nothing changed.
  unavailable,
}

/// Owner decision 2026-11-12 ("Ask before re-sending"), the one way a
/// message chosen to go sealed is ever sent identified: only after the
/// person tapped "Send normally" on a message the server refused to take
/// hidden ([sealedNeedsResendChoice]). Re-encrypts [sealed] afresh,
/// identified, under the same idempotency key, in its outbox entry's place
/// (a new MLS ciphertext and franking key, no token, no sealed tags). It
/// sends nothing itself: the outbox worker does, once, under the I34 hold.
/// An MLS control message queued for the conversation keeps the fresh
/// encrypt waiting ([SealedResend.held]).
Future<SealedResend> reencryptSealedForResend({
  required Object? crypto,
  required LocalStore localStore,
  required MessageEnvelope sealed,
}) async {
  if (crypto is! SealedSendingCryptoService || !sealed.sealed) {
    return SealedResend.unavailable;
  }
  if ((await localStore.pendingMlsMessages())
      .any((message) => message.conversationId == sealed.conversationId)) {
    return SealedResend.held;
  }
  final identified = await crypto.reencryptSealedAsIdentified(sealed);
  if (identified == null || identified.sealed) return SealedResend.unavailable;
  return SealedResend.queued;
}

/// The UTC day number the server calls a token's epoch. The app takes it
/// from its own clock, never from the server (review M1): a day the server
/// named per account could split accounts into groups by the epoch their
/// tokens carry in the clear at redemption.
int sealedUtcDay(DateTime now) =>
    now.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

/// The batch fetched per conversation and day.
const int sealedTokenBatch = 32;

/// How a refused sealed post is handled.
enum SealedPostOutcome {
  /// The token cannot be redeemed (expired, spent, its key gone): retry the
  /// same message sealed with another token.
  replaceToken,

  /// The server will not take the message sealed and stored nothing (the
  /// conversation is not eligible, or the request is malformed): the
  /// message fails. It is never sent identified instead, unless the person
  /// chooses that for a `sealed_not_eligible` refusal.
  terminal,

  /// Try again later, same token (rate limit, server or network trouble).
  retry,
}

SealedPostOutcome sealedPostOutcome(Object error) {
  if (error is! ApiException) return SealedPostOutcome.retry;
  switch (error.serverCode) {
    case 'sealed_token_expired':
    case 'sealed_token_spent':
    // A key the server no longer holds (rotated) or an output it does not
    // accept: the token is dead, the message is not.
    case 'sealed_token_invalid':
      return SealedPostOutcome.replaceToken;
  }
  final status = error.statusCode;
  if (status == 408 || status == 429 || status >= 500) {
    return SealedPostOutcome.retry;
  }
  return SealedPostOutcome.terminal;
}

/// Posts [envelope], a message chosen to go sealed, on [poster]. It is
/// never sent identified, whatever the answer: a hostile server could
/// otherwise unmask the sender of any post it chose by refusing it. A 409
/// `sealed_not_eligible` (which the server answers only after finding
/// nothing stored under the key, review M2) drops the conversation's tokens
/// and is rethrown: the outbox keeps the message, terminal, for the person
/// to send normally or discard ([sealedNeedsResendChoice]). A 404 means the
/// server's sealed routes are off: the message waits (a retryable 503
/// class) rather than fail. A refused token is replaced from [tokens] and
/// the same message (same idempotency key and bytes) posted again, after
/// [rewrite] keeps the new token in its outbox entry; the server answers a
/// post it already stored with 200 whatever token comes with it. With no
/// token to replace it, the message waits (a retryable 503 class) for the
/// next token pass. Any other refusal that stored nothing (malformed) is
/// rethrown, and fails the message. Returns normally when the post landed,
/// or when [rewrite] finds the entry gone (its echo arrived: it landed).
Future<void> postSealedMessage({
  required SealedPostClient poster,
  required MessageEnvelope envelope,
  required SealedSender? tokens,
  required Future<bool> Function(MessageEnvelope envelope) rewrite,
  bool Function()? owned,
}) async {
  if (!envelope.sealed) throw StateError('not a sealed envelope');
  var attempt = envelope;
  for (var round = 0; round < 3; round++) {
    try {
      await poster.post(attempt);
      return;
    } on ApiException catch (error) {
      if (owned != null && !owned()) rethrow;
      // Review low (a): the routes answer 404 while the switch is off.
      if (error.statusCode == 404) throw sealedUnavailable();
      switch (sealedPostOutcome(error)) {
        case SealedPostOutcome.retry:
          rethrow;
        case SealedPostOutcome.terminal:
          if (error.statusCode == 409 &&
              error.serverCode == 'sealed_not_eligible') {
            await tokens?.notEligible(envelope.conversationId);
          }
          rethrow;
        case SealedPostOutcome.replaceToken:
          await tokens?.tokenRefused(envelope.conversationId, error);
          final next = await tokens?.takeFor(envelope.conversationId);
          if (next == null) throw sealedTokenNeeded();
          attempt = attempt.withSealedToken(next);
          if (!await rewrite(attempt)) {
            await tokens?.putBack(next);
            return;
          }
      }
    }
  }
  throw sealedTokenNeeded();
}

/// A sealed message with no token to go with: it stays queued and retrying
/// (a 503 class) until a token pass refills.
ApiException sealedTokenNeeded() =>
    ApiException(503, '{"error":"sealed_token_needed"}');

/// The server's sealed routes are off (they answer 404): the message stays
/// queued and retrying (a 503 class) until they are back. It is never sent
/// identified for it.
ApiException sealedUnavailable() =>
    ApiException(503, '{"error":"sealed_unavailable"}');

/// Posts sealed messages. Its [HttpClient] is its own: the session client's
/// pooled TLS connection would tie the post to the session, and nothing
/// here ever sets an `Authorization` header or a cookie.
class SealedPostClient {
  SealedPostClient({required String baseUrl, HttpClient? httpClient})
      : baseUrl = canonicalizeServerOrigin(baseUrl),
        _httpClient = httpClient ?? HttpClient() {
    _httpClient.connectionTimeout = const Duration(seconds: 15);
    // A fresh connection per post: an idle pooled one would link posts.
    _httpClient.idleTimeout = Duration.zero;
  }

  final String baseUrl;
  final HttpClient _httpClient;
  static const _timeout = Duration(seconds: 30);

  void close() => _httpClient.close(force: true);

  /// Posts [envelope] (which must be sealed). Returns on 2xx, the retry of
  /// a stored post included; throws [ApiException] otherwise.
  Future<void> post(MessageEnvelope envelope) async {
    final body = utf8.encode(jsonEncode(envelope.toSealedPostJson()));
    final uri = Uri.parse(baseUrl).resolve('/api/v1/sealed/messages');
    final request = await _httpClient.openUrl('POST', uri).timeout(_timeout);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.headers.contentType = ContentType.json;
    request.headers.removeAll(HttpHeaders.authorizationHeader);
    request.headers.removeAll(HttpHeaders.cookieHeader);
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close().timeout(_timeout);
    final bytes = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      if (bytes.length + chunk.length > ApiException.maxErrorBodyBytes) {
        bytes.addAll(chunk.take(ApiException.maxErrorBodyBytes - bytes.length));
        break;
      }
      bytes.addAll(chunk);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        utf8.decode(bytes, allowMalformed: true),
        ApiException.parseRetryAfter(
            response.headers.value(HttpHeaders.retryAfterHeader)),
      );
    }
  }
}

/// What the app last learned about one conversation.
class _ConversationTokens {
  _ConversationTokens(this.state);
  final SealedConversationState state;
}

/// Token state and fetching for one session's origin.
class SealedSender implements SealedTokenSource {
  SealedSender({
    required this.origin,
    required this.localStore,
    required this.crypto,
    this.loadFrankContext,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String origin;
  final LocalStore localStore;
  final SealedSendingCryptoService crypto;
  final DateTime Function() _clock;

  /// L2-3: reads what a sealed message is designated with (this device's
  /// listed franking key and the pinned owner keys), on the token pass
  /// only. Null, or a null answer, sends everything identified.
  final Future<SealedFrankContext?> Function()? loadFrankContext;

  SealedFrankContext? _frank;

  @override
  SealedFrankContext? get frankContext => _frank;

  /// The server's `sealed_sender` (setup status). Off sends everything
  /// identified and fetches nothing.
  bool enabled = false;

  final Map<String, _ConversationTokens> _conversations =
      <String, _ConversationTokens>{};

  DateTime? _lastRefresh;
  Future<void>? _running;

  /// The least time between two fetch passes.
  static const refreshInterval = Duration(minutes: 10);

  /// This device's UTC day. Never adjusted by anything the server says.
  int get _today => sealedUtcDay(_clock());

  /// Whether messages in [conversationId] currently go sealed (when a token
  /// is held). Server typing and read receipts stay off there: they name
  /// the account seconds around a sealed post.
  bool activeIn(String conversationId) =>
      enabled && (_conversations[conversationId]?.state.eligible ?? false);

  @override
  Future<SealedToken?> takeFor(String conversationId) async {
    // Fail safe (docs/crypto.md, "Franking a sealed message"): without this
    // device's own franking key on its verified list, nothing goes sealed.
    if (!enabled || _frank == null) return null;
    final known = _conversations[conversationId];
    if (known == null || !known.state.eligible) return null;
    final pin = await localStore.loadSealedKeyPin(origin);
    if (pin == null ||
        pin.changed ||
        !known.state.key.sameAs(pin.keyId, pin.publicKey)) {
      return null;
    }
    return localStore.takeSealedToken(conversationId,
        keyId: pin.keyId, epoch: _today);
  }

  @override
  Future<void> putBack(SealedToken token) async {
    await localStore.saveSealedTokens(<SealedToken>[token]);
  }

  /// What the designation is made with changed (an owner key accepted in
  /// Settings): the next foreground pass loads it again.
  void contextChanged() {
    _lastRefresh = null;
  }

  /// A post was refused for its token: an invalid one (a key the server no
  /// longer holds) asks for a fresh pass.
  Future<void> tokenRefused(String conversationId, ApiException error) async {
    if (error.serverCode == 'sealed_token_invalid') _lastRefresh = null;
  }

  /// The server refused [conversationId] for sealed posts: send identified
  /// from now on (the next message), and keep no tokens for it.
  Future<void> notEligible(String conversationId) async {
    _conversations.remove(conversationId);
    await localStore.dropSealedTokens(conversationId: conversationId);
  }

  /// Accepts the key the server now serves in place of the pinned one (the
  /// Settings action). Tokens under the old key are dropped.
  Future<void> acceptChangedKey() async {
    final pin = await localStore.loadSealedKeyPin(origin);
    final seenKeyId = pin?.seenKeyId;
    final seenPublicKey = pin?.seenPublicKey;
    if (pin == null || seenKeyId == null || seenPublicKey == null) return;
    await localStore.saveSealedKeyPin(SealedKeyPin(
      origin: origin,
      keyId: seenKeyId,
      publicKey: seenPublicKey,
      pinnedAt: _clock().toUtc().millisecondsSinceEpoch,
    ));
    await localStore.dropSealedTokens(keyId: seenKeyId);
    _conversations.clear();
    _lastRefresh = null;
  }

  /// One fetch pass, on the foreground sync pass (at most every
  /// [refreshInterval], one at a time). Errors end the pass quietly: the
  /// next pass tries again, and sends go identified meanwhile.
  Future<void> refresh(
      ApiClient client, String sessionToken, List<Conversation> conversations) {
    if (!enabled) return Future<void>.value();
    final last = _lastRefresh;
    final now = _clock();
    if (last != null && now.difference(last) < refreshInterval) {
      return Future<void>.value();
    }
    return _running ??= () async {
      try {
        _lastRefresh = now;
        await _refresh(client, sessionToken, conversations);
      } catch (_) {
        // Quiet: no token, ciphertext or key is ever logged.
      } finally {
        _running = null;
      }
    }();
  }

  Future<void> _refresh(ApiClient client, String sessionToken,
      List<Conversation> conversations) async {
    // L2-3: the designation context, read here and nowhere on a send.
    try {
      _frank = await loadFrankContext?.call();
    } catch (_) {
      _frank = null;
    }
    final served = await client.sealedKey();
    final pin = await _pinned(served);
    if (pin == null) return;
    final today = _today;
    // Tokens of a day that can no longer be redeemed.
    await localStore.dropSealedTokens(minEpoch: today - 1);
    for (final conversation in conversations) {
      if (!enabled) return;
      if (!(conversation.kind == 'dm' || conversation.kind == 'group') ||
          conversation.communityId != null ||
          conversation.channelId != null) {
        continue;
      }
      final id = conversation.id;
      final SealedConversationState state;
      try {
        state = await client.sealedConversation(sessionToken, id);
      } on ApiException {
        continue;
      }
      if (!state.key.sameAs(pin.keyId, pin.publicKey)) {
        // A key other than the pinned one, per conversation: stop and keep
        // it for a person to look at, as for the published key.
        await _pinned(state.key);
        return;
      }
      _conversations[id] = _ConversationTokens(state);
      if (!state.eligible) {
        await localStore.dropSealedTokens(conversationId: id);
        continue;
      }
      var remaining = state.remaining;
      // Today and tomorrow by this device's clock, the same two days for
      // every member whose clock is right: the server chooses none of it.
      for (final epoch in <int>[today, today + 1]) {
        if (remaining <= 0) break;
        final held = await localStore.countSealedTokens(id,
            keyId: pin.keyId, epoch: epoch);
        if (held > 0) continue;
        final count =
            remaining < sealedTokenBatch ? remaining : sealedTokenBatch;
        final fetched = await _fetch(client, sessionToken, pin, state,
            conversationId: id, epoch: epoch, count: count);
        if (fetched == 0) break;
        remaining -= fetched;
      }
    }
  }

  /// The pin after seeing [served]: pinned on first use; a different key is
  /// recorded as seen and stops sealed sending (null) until accepted.
  Future<SealedKeyPin?> _pinned(SealedServerKey served) async {
    final pin = await localStore.loadSealedKeyPin(origin);
    final now = _clock().toUtc().millisecondsSinceEpoch;
    if (pin == null) {
      final fresh = SealedKeyPin(
          origin: origin,
          keyId: served.keyId,
          publicKey: served.publicKey,
          pinnedAt: now);
      await localStore.saveSealedKeyPin(fresh);
      return fresh;
    }
    if (served.sameAs(pin.keyId, pin.publicKey)) {
      if (pin.seenKeyId != null) {
        await localStore.saveSealedKeyPin(pin.withSeen(null, null));
        return pin.withSeen(null, null);
      }
      return pin;
    }
    final seen = pin.seenKeyId == served.keyId &&
        pin.seenPublicKey != null &&
        served.sameAs(pin.seenKeyId!, pin.seenPublicKey!);
    if (!seen) {
      await localStore
          .saveSealedKeyPin(pin.withSeen(served.keyId, served.publicKey));
    }
    _conversations.clear();
    return null;
  }

  Future<int> _fetch(ApiClient client, String sessionToken, SealedKeyPin pin,
      SealedConversationState state,
      {required String conversationId,
      required int epoch,
      required int count}) async {
    final blinded = crypto.sealedTokenRequest(
        publicKey: pin.publicKey,
        conversationId: conversationId,
        epoch: epoch,
        count: count);
    try {
      final answer = await client.sealedTokens(sessionToken, conversationId,
          epoch: epoch, blinded: blinded.request);
      if (answer.keyId != pin.keyId) return 0;
      final tokens = crypto.sealedTokenFinalize(
          state: blinded.state,
          response: answer.response,
          conversationId: conversationId,
          keyId: pin.keyId,
          epoch: epoch);
      await localStore.saveSealedTokens(tokens);
      return tokens.length;
    } on ApiException catch (error) {
      if (error.serverCode == 'sealed_not_eligible') {
        await notEligible(conversationId);
      }
      return 0;
    } finally {
      blinded.state.fillRange(0, blinded.state.length, 0);
    }
  }
}
