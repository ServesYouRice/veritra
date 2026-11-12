package domain

import (
	"encoding/json"
	"time"
)

// SealedMessageEnvelope is an L2-3 sealed-sender envelope (D123,
// docs/crypto.md "Sealed sender with VOPRF tokens"): posted with a token,
// not a session, so it has no sender fields at all. Sealed is always true
// so a reader can tell it from a MessageEnvelope.
type SealedMessageEnvelope struct {
	ID             string          `json:"id"`
	ConversationID string          `json:"conversation_id"`
	IdempotencyKey string          `json:"idempotency_key"`
	Ciphertext     []byte          `json:"ciphertext"`
	CryptoProtocol string          `json:"crypto_protocol"`
	CryptoMetadata json.RawMessage `json:"crypto_metadata"`
	FrankCommit    []byte          `json:"frank_commit,omitempty"`
	Sealed         bool            `json:"sealed"`
	CreatedAt      time.Time       `json:"created_at"`
	ExpiresAt      *time.Time      `json:"expires_at,omitempty"`
}

// SealedToken is a token presented with a sealed post.
type SealedToken struct {
	KeyID  string
	Epoch  uint32
	Nonce  []byte
	Output []byte
}
