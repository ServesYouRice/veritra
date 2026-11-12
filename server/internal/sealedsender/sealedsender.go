// Package sealedsender is the server half of L2-3 sealed sender (D123,
// docs/crypto.md "Sealed sender with VOPRF tokens"): an RFC 9497 POPRF
// (mode 0x02, ristretto255-SHA512) that evaluates blinded token nonces with
// a batch DLEQ proof at issuance and recomputes the output of a spent nonce
// at redemption. The two sides cannot be linked: issuance sees only blinded
// elements, redemption only an unblinded (nonce, output) pair.
//
// The client half is crypto/rust/src/l2_sealed.rs; both check
// testing/vectors/l2-sealed-v1.json. The package is pure: no storage and no
// logging. Nonces, outputs and the private key never leave it except as the
// caller's own byte slices.
package sealedsender

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"time"

	"github.com/cloudflare/circl/group"
	"github.com/cloudflare/circl/oprf"
)

const (
	// Suite is the RFC 9497 suite identifier.
	Suite = "ristretto255-SHA512"
	// MaxBatch is the most nonces one issuance request may blind.
	MaxBatch = 32
	// NonceSize is the size of a token nonce (the POPRF input).
	NonceSize = 32
	// OutputSize is the size of a token output (SHA-512).
	OutputSize = 64
	// ElementSize is the size of an encoded ristretto255 element.
	ElementSize = 32
	// PublicKeySize is the size of the encoded public key.
	PublicKeySize = 32
	// PrivateKeySize is the size of the encoded private scalar.
	PrivateKeySize = 32
	// ProofSize is the size of the encoded batch DLEQ proof (c || s).
	ProofSize = 64
	// KeyIDSize is the size of the key id before hex encoding.
	KeyIDSize = 16
	// MaxIDSize bounds the conversation id, as in the Rust core.
	MaxIDSize = 128

	infoLabel  = "veritra-l2-sealed-v1"
	keyIDLabel = "veritra-l2-key-v1"
)

var (
	// ErrInvalidInput reports a malformed argument: a wrong length, a
	// conversation id out of bounds, a batch of the wrong size, or a blinded
	// element that does not decode or is the identity.
	ErrInvalidInput = errors.New("sealedsender: invalid input")
	// ErrInvalidKey reports a private key that does not decode.
	ErrInvalidKey = errors.New("sealedsender: invalid key")
)

var suite = oprf.SuiteRistretto255

// Info returns the POPRF public input of a token:
// "veritra-l2-sealed-v1" || u16 len(conv) || conv || u32 epoch, big-endian.
// Nothing per account or per member list goes in: a number the server
// chose per account would let it tag each account's tokens (review M1).
func Info(conversationID string, epoch uint32) ([]byte, error) {
	if len(conversationID) == 0 || len(conversationID) > MaxIDSize {
		return nil, ErrInvalidInput
	}
	out := make([]byte, 0, len(infoLabel)+2+len(conversationID)+4)
	out = append(out, infoLabel...)
	out = binary.BigEndian.AppendUint16(out, uint16(len(conversationID)))
	out = append(out, conversationID...)
	out = binary.BigEndian.AppendUint32(out, epoch)
	return out, nil
}

// KeyID returns hex(first 16 bytes of SHA-256("veritra-l2-key-v1" || pk)).
func KeyID(publicKey []byte) string {
	h := sha256.New()
	h.Write([]byte(keyIDLabel))
	h.Write(publicKey)
	return hex.EncodeToString(h.Sum(nil)[:KeyIDSize])
}

// Epoch returns the UTC day of t: floor(unix seconds / 86400).
func Epoch(t time.Time) uint32 {
	sec := t.Unix()
	if sec < 0 {
		return 0
	}
	return uint32(sec / 86400)
}

// GenerateKey returns a fresh encoded private key read from rnd
// (crypto/rand when nil).
func GenerateKey(rnd io.Reader) ([]byte, error) {
	if rnd == nil {
		rnd = rand.Reader
	}
	key, err := oprf.GenerateKey(suite, rnd)
	if err != nil {
		return nil, err
	}
	return key.MarshalBinary()
}

// Key is a loaded server key.
type Key struct {
	server    oprf.PartialObliviousServer
	publicKey []byte
	id        string
}

// LoadKey decodes an encoded private key.
func LoadKey(private []byte) (*Key, error) {
	if len(private) != PrivateKeySize {
		return nil, ErrInvalidKey
	}
	var key oprf.PrivateKey
	if err := key.UnmarshalBinary(suite, private); err != nil {
		return nil, ErrInvalidKey
	}
	return newKey(&key)
}

// DeriveKey derives a key from a 32-byte seed as RFC 9497 §3.2.1 does
// (DeriveKeyPair, POPRF mode). The vectors use it; production keys come from
// GenerateKey.
func DeriveKey(seed, info []byte) (*Key, error) {
	key, err := oprf.DeriveKey(suite, oprf.PartialObliviousMode, seed, info)
	if err != nil {
		return nil, ErrInvalidKey
	}
	return newKey(key)
}

func newKey(key *oprf.PrivateKey) (*Key, error) {
	pub, err := key.Public().MarshalBinary()
	if err != nil || len(pub) != PublicKeySize {
		return nil, ErrInvalidKey
	}
	return &Key{
		server:    oprf.NewPartialObliviousServer(suite, key),
		publicKey: pub,
		id:        KeyID(pub),
	}, nil
}

// PublicKey returns a copy of the encoded public key.
func (k *Key) PublicKey() []byte { return append([]byte(nil), k.publicKey...) }

// ID returns the key id (hex).
func (k *Key) ID() string { return k.id }

// Evaluate evaluates count = len(blinded)/32 blinded elements (1 to
// MaxBatch) under info(conversation, epoch) and returns the
// evaluated elements followed by the 64-byte batch proof, the response the
// Rust client finalizes.
func (k *Key) Evaluate(conversationID string, epoch uint32, blinded []byte) ([]byte, error) {
	if len(blinded) == 0 || len(blinded)%ElementSize != 0 || len(blinded)/ElementSize > MaxBatch {
		return nil, ErrInvalidInput
	}
	info, err := Info(conversationID, epoch)
	if err != nil {
		return nil, err
	}
	count := len(blinded) / ElementSize
	elements := make([]oprf.Blinded, count)
	for i := range count {
		e := group.Ristretto255.NewElement()
		if err := e.UnmarshalBinary(blinded[i*ElementSize : (i+1)*ElementSize]); err != nil || e.IsIdentity() {
			return nil, ErrInvalidInput
		}
		elements[i] = e
	}
	eval, err := k.server.Evaluate(&oprf.EvaluationRequest{Elements: elements}, info)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, count*ElementSize+ProofSize)
	for _, e := range eval.Elements {
		enc, err := e.MarshalBinaryCompress()
		if err != nil || len(enc) != ElementSize {
			return nil, ErrInvalidInput
		}
		out = append(out, enc...)
	}
	proof, err := eval.Proof.MarshalBinary()
	if err != nil || len(proof) != ProofSize {
		return nil, ErrInvalidInput
	}
	return append(out, proof...), nil
}

// Output recomputes the POPRF output of nonce under info(conversation,
// epoch).
func (k *Key) Output(conversationID string, epoch uint32, nonce []byte) ([]byte, error) {
	if len(nonce) != NonceSize {
		return nil, ErrInvalidInput
	}
	info, err := Info(conversationID, epoch)
	if err != nil {
		return nil, err
	}
	return k.server.FullEvaluate(nonce, info)
}

// Verify reports, in constant time over the output, whether output is the
// POPRF output of nonce under info(conversation, epoch).
func (k *Key) Verify(conversationID string, epoch uint32, nonce, output []byte) bool {
	if len(output) != OutputSize {
		return false
	}
	want, err := k.Output(conversationID, epoch, nonce)
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare(want, output) == 1
}
