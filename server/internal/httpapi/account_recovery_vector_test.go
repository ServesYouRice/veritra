package httpapi

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base32"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// k0RecoveryVector is testing/vectors/k0-recovery-v1.json, the known-answer
// vector the Rust core (crypto/rust/src/recovery_tests.rs) also checks.
type k0RecoveryVector struct {
	Description string `json:"description"`
	RecoveryKey struct {
		EntropyHex   string `json:"entropy_hex"`
		Display      string `json:"display"`
		RKPubHex     string `json:"rk_pub_hex"`
		RKIDHex      string `json:"rk_id_hex"`
		RKAuthPubHex string `json:"rk_auth_pub_hex"`
	} `json:"recovery_key"`
	Proof struct {
		ChallengeHex  string `json:"challenge_hex"`
		SigningKeyHex string `json:"signing_key_hex"`
		KeyPackageHex string `json:"key_package_hex"`
		Origin        string `json:"origin"`
		MessageHex    string `json:"message_hex"`
		SignatureHex  string `json:"signature_hex"`
	} `json:"proof"`
}

func loadK0RecoveryVector(t *testing.T) k0RecoveryVector {
	t.Helper()
	// A missing file fails the test: the cross-implementation check must
	// never silently disappear.
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "k0-recovery-v1.json"))
	if err != nil {
		t.Fatalf("read K0 recovery vector: %v", err)
	}
	var vector k0RecoveryVector
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&vector); err != nil {
		t.Fatalf("parse K0 recovery vector: %v", err)
	}
	return vector
}

func vectorHex(t *testing.T, name, value string) []byte {
	t.Helper()
	decoded, err := hex.DecodeString(value)
	if err != nil || len(decoded) == 0 {
		t.Fatalf("vector field %s is not non-empty hex", name)
	}
	return decoded
}

func vectorHKDF(t *testing.T, prk []byte, info string) []byte {
	t.Helper()
	out, err := hkdf.Expand(sha256.New, prk, info, 32)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// TestK0RecoveryVectorDerivation re-derives every public recovery value
// from the entropy with Go's own primitives, independent of the Rust code,
// so a swapped HKDF argument or a mistyped label cannot freeze into the
// vector.
func TestK0RecoveryVectorDerivation(t *testing.T) {
	vector := loadK0RecoveryVector(t)
	entropy := vectorHex(t, "entropy_hex", vector.RecoveryKey.EntropyHex)
	if len(entropy) != 30 {
		t.Fatalf("entropy has %d bytes, want 30", len(entropy))
	}

	// Display: Crockford base32 of entropy || SHA-256(label || entropy)[0:2].
	check := sha256.Sum256(append([]byte("veritra-k0-rk-check-v1"), entropy...))
	crockford := base32.NewEncoding("0123456789ABCDEFGHJKMNPQRSTVWXYZ").WithPadding(base32.NoPadding)
	if display := crockford.EncodeToString(append(bytes.Clone(entropy), check[:2]...)); display != vector.RecoveryKey.Display {
		t.Fatalf("display = %s, vector has %s", display, vector.RecoveryKey.Display)
	}

	prk, err := hkdf.Extract(sha256.New, entropy, []byte("veritra-k0-v1"))
	if err != nil {
		t.Fatal(err)
	}

	// rk_auth_pub: Ed25519 key from the "veritra-k0 recovery-auth" seed.
	authPrivate := ed25519.NewKeyFromSeed(vectorHKDF(t, prk, "veritra-k0 recovery-auth"))
	authPublic := authPrivate.Public().(ed25519.PublicKey)
	if want := vectorHex(t, "rk_auth_pub_hex", vector.RecoveryKey.RKAuthPubHex); !bytes.Equal(authPublic, want) {
		t.Fatalf("rk_auth_pub = %x, vector has %x", authPublic, want)
	}
	if !validRecoveryAuthKey(authPublic) {
		t.Fatal("the vector's rk_auth_pub is refused by validRecoveryAuthKey")
	}

	// rk_pub: RFC 9180 DeriveKeyPair for DHKEM(X25519, HKDF-SHA256).
	ikm := vectorHKDF(t, prk, "veritra-k0 recovery-hpke")
	suiteID := []byte{'K', 'E', 'M', 0x00, 0x20}
	labeledIKM := append(append(append([]byte("HPKE-v1"), suiteID...), "dkp_prk"...), ikm...)
	dkpPRK, err := hkdf.Extract(sha256.New, labeledIKM, nil)
	if err != nil {
		t.Fatal(err)
	}
	labeledInfo := append(append([]byte{0x00, 0x20}, "HPKE-v1"...), suiteID...)
	labeledInfo = append(labeledInfo, "sk"...)
	secret, err := hkdf.Expand(sha256.New, dkpPRK, string(labeledInfo), 32)
	if err != nil {
		t.Fatal(err)
	}
	hpkePrivate, err := ecdh.X25519().NewPrivateKey(secret)
	if err != nil {
		t.Fatal(err)
	}
	rkPub := hpkePrivate.PublicKey().Bytes()
	if want := vectorHex(t, "rk_pub_hex", vector.RecoveryKey.RKPubHex); !bytes.Equal(rkPub, want) {
		t.Fatalf("rk_pub = %x, vector has %x", rkPub, want)
	}

	// rk_id: SHA-256("veritra-k0-rk-id-v1" || rk_pub)[0:16], what the PUT takes.
	rkIDDigest := sha256.Sum256(append([]byte("veritra-k0-rk-id-v1"), rkPub...))
	want := vectorHex(t, "rk_id_hex", vector.RecoveryKey.RKIDHex)
	if len(want) != 16 || !bytes.Equal(rkIDDigest[:16], want) {
		t.Fatalf("rk_id = %x, vector has %x", rkIDDigest[:16], want)
	}
}

// TestK0RecoveryVectorProof checks the Rust-made proof against the
// production recoveryProofMessage and ed25519.Verify, as the claim handler
// does, and that Go's own signature over that message is byte-identical
// (Ed25519 is deterministic).
func TestK0RecoveryVectorProof(t *testing.T) {
	vector := loadK0RecoveryVector(t)
	challenge := vectorHex(t, "challenge_hex", vector.Proof.ChallengeHex)
	signingKey := vectorHex(t, "signing_key_hex", vector.Proof.SigningKeyHex)
	keyPackage := vectorHex(t, "key_package_hex", vector.Proof.KeyPackageHex)
	wantMessage := vectorHex(t, "message_hex", vector.Proof.MessageHex)
	signature := vectorHex(t, "signature_hex", vector.Proof.SignatureHex)
	authPublic := ed25519.PublicKey(vectorHex(t, "rk_auth_pub_hex", vector.RecoveryKey.RKAuthPubHex))
	origin := vector.Proof.Origin
	if len(signingKey) != ed25519.PublicKeySize || len(signature) != ed25519.SignatureSize {
		t.Fatal("vector signing key or signature has the wrong size")
	}

	message := recoveryProofMessage(challenge, signingKey, keyPackage, origin)
	if !bytes.Equal(message, wantMessage) {
		t.Fatalf("recoveryProofMessage = %x\nvector message      = %x", message, wantMessage)
	}

	// The layout, spelled out once more against the design text.
	var layout []byte
	layout = append(layout, recoveryProofLabel...)
	layout = binary.BigEndian.AppendUint16(layout, uint16(len(challenge)))
	layout = append(layout, challenge...)
	layout = append(layout, signingKey...)
	keyPackageHash := sha256.Sum256(keyPackage)
	layout = append(layout, keyPackageHash[:]...)
	layout = binary.BigEndian.AppendUint16(layout, uint16(len(origin)))
	layout = append(layout, origin...)
	if !bytes.Equal(layout, message) {
		t.Fatal("recoveryProofMessage differs from the documented layout")
	}

	if !ed25519.Verify(authPublic, message, signature) {
		t.Fatal("the Rust recovery proof does not verify")
	}

	entropy := vectorHex(t, "entropy_hex", vector.RecoveryKey.EntropyHex)
	prk, err := hkdf.Extract(sha256.New, entropy, []byte("veritra-k0-v1"))
	if err != nil {
		t.Fatal(err)
	}
	authPrivate := ed25519.NewKeyFromSeed(vectorHKDF(t, prk, "veritra-k0 recovery-auth"))
	if goSignature := ed25519.Sign(authPrivate, message); !bytes.Equal(goSignature, signature) {
		t.Fatalf("Go signature %x differs from the vector's %x", goSignature, signature)
	}

	// Every bound field changes the message, so the proof fails.
	for name, mutated := range map[string][]byte{
		"origin":      recoveryProofMessage(challenge, signingKey, keyPackage, "https://chat.example.com.evil"),
		"challenge":   recoveryProofMessage(append(bytes.Clone(challenge), 0), signingKey, keyPackage, origin),
		"key package": recoveryProofMessage(challenge, signingKey, append(bytes.Clone(keyPackage), 0), origin),
		"signing key": recoveryProofMessage(challenge, append([]byte{signingKey[0] ^ 1}, signingKey[1:]...), keyPackage, origin),
	} {
		if ed25519.Verify(authPublic, mutated, signature) {
			t.Fatalf("the proof verified with a different %s", name)
		}
	}
}
