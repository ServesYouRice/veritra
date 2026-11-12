import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../crypto/crypto_service.dart'
    show SealedSendingCryptoService, SealedTokenSource;
import '../storage/local_store.dart' show LocalStore, SealedKeyPin;
import 'api_client.dart';
import 'models.dart';

// L2-3 sealed sender, the app side (D122; docs/crypto.md, "Sealed sender
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
//   never posted identified, so a post that may have landed is never
//   stored twice.

/// The sync event of a sealed post. Only an app that reads sealed events
/// (`sealed=1`) is ever served one.
const String sealedMessageEventType = 'message.sealed.created';

/// The UTC day number the server calls a token's epoch.
int sealedUtcDay(DateTime now) =>
    now.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

/// The batch fetched per conversation and day.
const int sealedTokenBatch = 32;

/// How a refused sealed post is handled.
enum SealedPostOutcome {
  /// The token cannot be redeemed (expired, spent, its generation or key
  /// gone): retry the same message sealed with another token.
  replaceToken,

  /// The server will not take the message sealed and stored nothing (the
  /// conversation is not eligible, or the request is malformed): the
  /// message fails. It is never sent identified instead.
  terminal,

  /// Try again later, same token (rate limit, server or network trouble).
  retry,
}

SealedPostOutcome sealedPostOutcome(Object error) {
  if (error is! ApiException) return SealedPostOutcome.retry;
  switch (error.serverCode) {
    case 'sealed_generation_changed':
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
/// never sent identified, whatever the answer: once a sealed attempt may
/// have landed, an identified copy would be a second message. A refused
/// token is replaced from [tokens] and the same message (same idempotency
/// key and bytes) posted again, after [rewrite] keeps the new token in its
/// outbox entry; the server answers a post it already stored with 200
/// whatever token comes with it. With no token to replace it, the message
/// waits (a retryable 503 class) for the next token pass. A refusal that
/// stored nothing (not eligible, malformed) is rethrown, and fails the
/// message. Returns normally when the post landed, or when [rewrite] finds
/// the entry gone (its echo arrived: it landed).
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
      switch (sealedPostOutcome(error)) {
        case SealedPostOutcome.retry:
          rethrow;
        case SealedPostOutcome.terminal:
          if (error.serverCode == 'sealed_not_eligible') {
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
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String origin;
  final LocalStore localStore;
  final SealedSendingCryptoService crypto;
  final DateTime Function() _clock;

  /// The server's `sealed_sender` (setup status). Off sends everything
  /// identified and fetches nothing.
  bool enabled = false;

  final Map<String, _ConversationTokens> _conversations =
      <String, _ConversationTokens>{};

  /// The server's day minus this device's, from the last answer (clamped).
  int _dayOffset = 0;
  DateTime? _lastRefresh;
  Future<void>? _running;

  /// The least time between two fetch passes.
  static const refreshInterval = Duration(minutes: 10);

  int get _today => sealedUtcDay(_clock()) + _dayOffset;

  /// Whether messages in [conversationId] currently go sealed (when a token
  /// is held). Server typing and read receipts stay off there: they name
  /// the account seconds around a sealed post.
  bool activeIn(String conversationId) =>
      enabled && (_conversations[conversationId]?.state.eligible ?? false);

  @override
  Future<SealedToken?> takeFor(String conversationId) async {
    if (!enabled) return null;
    final known = _conversations[conversationId];
    if (known == null || !known.state.eligible) return null;
    final pin = await localStore.loadSealedKeyPin(origin);
    if (pin == null ||
        pin.changed ||
        !known.state.key.sameAs(pin.keyId, pin.publicKey)) {
      return null;
    }
    return localStore.takeSealedToken(conversationId,
        keyId: pin.keyId, generation: known.state.generation, epoch: _today);
  }

  @override
  Future<void> putBack(SealedToken token) async {
    await localStore.saveSealedTokens(<SealedToken>[token]);
  }

  /// A post was refused for its token: [conversationId]'s state is stale.
  /// A generation change drops every token of the conversation.
  Future<void> tokenRefused(String conversationId, ApiException error) async {
    if (error.serverCode == 'sealed_generation_changed') {
      _conversations.remove(conversationId);
      await localStore.dropSealedTokens(conversationId: conversationId);
      _lastRefresh = null;
    } else if (error.serverCode == 'sealed_token_invalid') {
      _lastRefresh = null;
    }
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
    final served = await client.sealedKey();
    final pin = await _pinned(served);
    if (pin == null) return;
    final today = sealedUtcDay(_clock());
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
      _dayOffset = (state.epoch - today).clamp(-1, 1).toInt();
      _conversations[id] = _ConversationTokens(state);
      if (!state.eligible) {
        await localStore.dropSealedTokens(conversationId: id);
        continue;
      }
      await localStore.dropSealedTokens(
          conversationId: id, generation: state.generation);
      var remaining = state.remaining;
      for (final epoch in <int>[state.epoch, state.epoch + 1]) {
        if (remaining <= 0) break;
        final held = await localStore.countSealedTokens(id,
            keyId: pin.keyId, generation: state.generation, epoch: epoch);
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
        generation: state.generation,
        count: count);
    try {
      final answer = await client.sealedTokens(sessionToken, conversationId,
          epoch: epoch, generation: state.generation, blinded: blinded.request);
      if (answer.keyId != pin.keyId) return 0;
      final tokens = crypto.sealedTokenFinalize(
          state: blinded.state,
          response: answer.response,
          conversationId: conversationId,
          keyId: pin.keyId,
          epoch: epoch,
          generation: state.generation);
      await localStore.saveSealedTokens(tokens);
      return tokens.length;
    } on ApiException catch (error) {
      if (error.serverCode == 'sealed_generation_changed') {
        _conversations.remove(conversationId);
        await localStore.dropSealedTokens(conversationId: conversationId);
      } else if (error.serverCode == 'sealed_not_eligible') {
        await notEligible(conversationId);
      }
      return 0;
    } finally {
      blinded.state.fillRange(0, blinded.state.length, 0);
    }
  }
}
