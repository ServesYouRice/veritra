package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/sealedsender"
	"private-messenger/server/internal/storage"
)

// L2-3 sealed sender (D123; docs/crypto.md, "Sealed sender with VOPRF
// tokens"). Registered only while config.SealedSender is on; off, every
// route here answers 404.
//
// Nothing here logs a token, a nonce, an output, a blinded element or a
// body.

// registerSealedSender adds the sealed sender routes when the switch is on.
func (a *API) registerSealedSender(mux *http.ServeMux) {
	if !a.SealedSender {
		return
	}
	mux.HandleFunc("GET /api/v1/sealed/key", a.sealedKey)
	mux.HandleFunc("GET /api/v1/sealed/conversations/{id}", a.withAuth(a.sealedConversation))
	mux.HandleFunc("POST /api/v1/sealed/conversations/{id}/tokens", a.withAuth(a.withWriteBudget(a.sealedTokens)))
	mux.HandleFunc("POST /api/v1/sealed/messages", a.sealedMessage)
}

func (a *API) sealedTokenLimit() int {
	if a.SealedTokensPerDay > 0 {
		return a.SealedTokensPerDay
	}
	return 200
}

func (a *API) sealedServerKey(w http.ResponseWriter, r *http.Request) (*sealedsender.Key, bool) {
	key, err := a.Store.SealedSenderKey(r.Context())
	if err != nil {
		a.warn("sealed_key_unavailable", "err", err)
		writeError(w, http.StatusInternalServerError, "storage_error")
		return nil, false
	}
	return key, true
}

// sealedKey publishes the instance's POPRF public key. No session.
func (a *API) sealedKey(w http.ResponseWriter, r *http.Request) {
	key, ok := a.sealedServerKey(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"suite":      sealedsender.Suite,
		"key_id":     key.ID(),
		"public_key": key.PublicKey(),
	})
}

// sealedConversation tells a member what it needs to ask for tokens.
func (a *API) sealedConversation(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	key, ok := a.sealedServerKey(w, r)
	if !ok {
		return
	}
	epoch := sealedsender.Epoch(time.Now().UTC())
	state, err := a.Store.SealedConversationForAccount(r.Context(), r.PathValue("id"), principal.AccountID, epoch)
	if err != nil {
		writeSealedError(w, err)
		return
	}
	remaining := a.sealedTokenLimit() - state.Issued
	if remaining < 0 {
		remaining = 0
	}
	// No epoch and no counter: the app takes the day from its own clock,
	// so the server has no per-account value to bind into a token (review
	// M1). remaining is what the cap still allows for either day an app
	// may ask for, at least (review low c).
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"key_id":     key.ID(),
		"public_key": key.PublicKey(),
		"eligible":   state.Eligible,
		"remaining":  remaining,
	})
}

type sealedTokenRequest struct {
	Epoch   uint32 `json:"epoch"`
	Blinded []byte `json:"blinded"`
}

// sealedTokens evaluates a batch of blinded nonces for a member device,
// within the account's daily cap for the conversation.
func (a *API) sealedTokens(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	raw, ok := readLimitedJSON(w, r)
	if !ok {
		return
	}
	var req sealedTokenRequest
	if !decodeRawJSON(w, raw, &req) {
		return
	}
	count := len(req.Blinded) / sealedsender.ElementSize
	if count == 0 || count > sealedsender.MaxBatch || len(req.Blinded)%sealedsender.ElementSize != 0 {
		writeError(w, http.StatusBadRequest, "invalid_sealed_request")
		return
	}
	today := sealedsender.Epoch(time.Now().UTC())
	if req.Epoch != today && req.Epoch != today+1 {
		writeError(w, http.StatusBadRequest, "invalid_sealed_epoch")
		return
	}
	key, ok := a.sealedServerKey(w, r)
	if !ok {
		return
	}
	conversationID := r.PathValue("id")
	if err := a.Store.ReserveSealedTokens(r.Context(), conversationID, principal.AccountID, req.Epoch, count, a.sealedTokenLimit()); err != nil {
		writeSealedError(w, err)
		return
	}
	response, err := key.Evaluate(conversationID, req.Epoch, req.Blinded)
	if err != nil {
		if errors.Is(err, sealedsender.ErrInvalidInput) {
			writeError(w, http.StatusBadRequest, "invalid_sealed_request")
			return
		}
		a.warn("sealed_evaluate_failed", "err", err)
		writeError(w, http.StatusInternalServerError, "sealed_evaluate_failed")
		return
	}
	n := count * sealedsender.ElementSize
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"key_id":    key.ID(),
		"evaluated": response[:n],
		"proof":     response[n:],
	})
}

type sealedTokenBody struct {
	KeyID  string `json:"key_id"`
	Epoch  uint32 `json:"epoch"`
	Nonce  []byte `json:"nonce"`
	Output []byte `json:"output"`
}

type sealedMessageRequest struct {
	ConversationID string          `json:"conversation_id"`
	Token          sealedTokenBody `json:"token"`
	IdempotencyKey string          `json:"idempotency_key"`
	Ciphertext     []byte          `json:"ciphertext"`
	CryptoProtocol string          `json:"crypto_protocol"`
	CryptoMetadata json.RawMessage `json:"crypto_metadata"`
	FrankCommit    []byte          `json:"frank_commit,omitempty"`
	ExpiresAt      *time.Time      `json:"expires_at,omitempty"`
}

// sealedMetadataKeys are the only crypto_metadata members a sealed post may
// carry; anything else (a channel, a leave notice) needs a sender.
var sealedMetadataKeys = map[string]bool{
	"protocol_version": true,
	"group_id":         true,
	"content_type":     true,
	"payload_version":  true,
	"mls_epoch":        true,
}

// sealedMessage stores a post paid for with a token. It must carry no
// session: a request with an Authorization header or a cookie is refused,
// so a client bug fails closed instead of tying the post to an account.
func (a *API) sealedMessage(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
		writeError(w, http.StatusBadRequest, "sealed_request_authenticated")
		return
	}
	if a.diskLow(w) {
		return
	}
	raw, ok := readLimitedJSON(w, r)
	if !ok {
		return
	}
	if containsPlaintextMessageKey(raw) {
		writeError(w, http.StatusBadRequest, "plaintext_message_fields_forbidden")
		return
	}
	var req sealedMessageRequest
	if !decodeRawJSON(w, raw, &req) {
		return
	}
	now := time.Now().UTC()
	switch {
	case req.ConversationID == "" || len(req.ConversationID) > sealedsender.MaxIDSize,
		len(req.IdempotencyKey) < 22 || len(req.IdempotencyKey) > 128,
		len(req.Ciphertext) == 0,
		req.CryptoProtocol != productionMessageCryptoProtocol:
		writeError(w, http.StatusBadRequest, "invalid_encrypted_envelope")
		return
	case len(req.FrankCommit) != 0 && len(req.FrankCommit) != sealedsender.CommitSize:
		writeError(w, http.StatusBadRequest, "invalid_frank_commit")
		return
	case req.ExpiresAt != nil && !req.ExpiresAt.After(now):
		writeError(w, http.StatusBadRequest, "invalid_expires_at")
		return
	case len(req.Token.Nonce) != sealedsender.NonceSize || len(req.Token.Output) != sealedsender.OutputSize || req.Token.KeyID == "":
		writeError(w, http.StatusBadRequest, "invalid_sealed_token")
		return
	}
	if !validSealedMetadata(req.CryptoMetadata, req.ConversationID) {
		writeError(w, http.StatusBadRequest, "invalid_crypto_metadata")
		return
	}
	key, ok := a.sealedServerKey(w, r)
	if !ok {
		return
	}
	if req.Token.KeyID != key.ID() {
		writeError(w, http.StatusForbidden, "sealed_token_invalid")
		return
	}
	today := sealedsender.Epoch(now)
	if req.Token.Epoch != today && req.Token.Epoch+1 != today {
		writeError(w, http.StatusConflict, "sealed_token_expired")
		return
	}
	// The token proves, before any lookup, that its holder was issued it
	// for this conversation and day: an unknown conversation and a forged
	// token answer alike.
	if !key.Verify(req.ConversationID, req.Token.Epoch, req.Token.Nonce, req.Token.Output) {
		writeError(w, http.StatusForbidden, "sealed_token_invalid")
		return
	}
	stored, duplicate, eventID, recipients, err := a.Store.SaveSealedEnvelope(r.Context(), domain.SealedMessageEnvelope{
		ConversationID: req.ConversationID,
		IdempotencyKey: req.IdempotencyKey,
		Ciphertext:     req.Ciphertext,
		CryptoProtocol: req.CryptoProtocol,
		CryptoMetadata: req.CryptoMetadata,
		FrankCommit:    req.FrankCommit,
		ExpiresAt:      req.ExpiresAt,
	}, domain.SealedToken{
		KeyID:  req.Token.KeyID,
		Epoch:  req.Token.Epoch,
		Nonce:  req.Token.Nonce,
		Output: req.Token.Output,
	})
	if err != nil {
		writeSealedError(w, err)
		return
	}
	if duplicate {
		writeJSON(w, http.StatusOK, stored)
		return
	}
	// The bare frame every message event gets (C7): no event id,
	// conversation id or envelope. A device reads the sealed event from sync,
	// which applies the join filter and the `sealed=1` opt-in.
	a.publishSyncAvailable(r.Context(), recipients, eventID)
	writeJSON(w, http.StatusCreated, stored)
}

// validSealedMetadata accepts an object with only sealedMetadataKeys, a
// group_id equal to the conversation, content_type "application" and an
// integer mls_epoch (the join filter reads it). Repeated keys are refused by
// the store (checkMetadataEpoch).
func validSealedMetadata(raw json.RawMessage, conversationID string) bool {
	var fields map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &fields) != nil || fields == nil {
		return false
	}
	for name := range fields {
		if !sealedMetadataKeys[name] {
			return false
		}
	}
	var groupID, contentType string
	if json.Unmarshal(fields["group_id"], &groupID) != nil || groupID != conversationID {
		return false
	}
	if json.Unmarshal(fields["content_type"], &contentType) != nil || contentType != "application" {
		return false
	}
	epoch, ok := fields["mls_epoch"]
	if !ok {
		return false
	}
	if _, err := strconv.ParseUint(string(epoch), 10, 63); err != nil {
		return false
	}
	return true
}

func writeSealedError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, storage.ErrSealedNotEligible):
		writeError(w, http.StatusConflict, "sealed_not_eligible")
	case errors.Is(err, storage.ErrSealedTokenLimit):
		writeError(w, http.StatusTooManyRequests, "sealed_token_limit")
	case errors.Is(err, storage.ErrSealedTokenSpent):
		writeError(w, http.StatusConflict, "sealed_token_spent")
	case errors.Is(err, storage.ErrSealedTokenInvalid):
		writeError(w, http.StatusForbidden, "sealed_token_invalid")
	default:
		handleStorageError(w, err)
	}
}
