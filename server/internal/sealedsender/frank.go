package sealedsender

import (
	"crypto/ed25519"
	"encoding/binary"
)

const (
	// CommitSize is the size of a C6 franking commitment.
	CommitSize = 32
	// SignatureSize is the size of a sealed message's franking signature.
	SignatureSize = ed25519.SignatureSize

	frankSigLabel = "veritra-frank-sig-v1"
)

// FrankSignatureInput returns the bytes a sealed sender signs over its
// franking commitment with its device's MLS signing key:
// "veritra-frank-sig-v1" || u16 len(conv) || conv || u16 len(account) ||
// account || u16 len(device) || device || commit.
//
// The server never sees the signature: it travels inside the MLS
// ciphertext. This is the reference for the vectors and for report
// tooling; the apps verify through pm_crypto_l2_frank_verify.
func FrankSignatureInput(conversationID, accountID, deviceID string, commit []byte) ([]byte, error) {
	if len(commit) != CommitSize {
		return nil, ErrInvalidInput
	}
	out := []byte(frankSigLabel)
	for _, id := range []string{conversationID, accountID, deviceID} {
		if len(id) == 0 || len(id) > MaxIDSize {
			return nil, ErrInvalidInput
		}
		out = binary.BigEndian.AppendUint16(out, uint16(len(id)))
		out = append(out, id...)
	}
	return append(out, commit...), nil
}

// VerifyFrankSignature reports whether signature is signingKey's Ed25519
// signature over FrankSignatureInput. The Rust core uses ed25519-dalek's
// verify_strict, which also refuses small-order keys and R points; Go's
// crypto/ed25519 accepts those, so the two can differ only on a key no
// honest device holds.
func VerifyFrankSignature(signingKey []byte, conversationID, accountID, deviceID string, commit, signature []byte) bool {
	if len(signingKey) != ed25519.PublicKeySize || len(signature) != SignatureSize {
		return false
	}
	input, err := FrankSignatureInput(conversationID, accountID, deviceID, commit)
	if err != nil {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(signingKey), input, signature)
}
