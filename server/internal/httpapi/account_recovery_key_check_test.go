package httpapi

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"testing"
)

// The hard-coded list is proved, not trusted: a forged signature R || 0,
// with R from the list, verifies under every listed key for some message,
// which only happens for points of small order, and the R values that
// verify are exactly the list, so it is complete and canonical.
func TestRecoverySmallOrderKeysAreExactlyTheTorsionPoints(t *testing.T) {
	if len(recoverySmallOrderKeys) != 8 {
		t.Fatalf("small-order keys = %d, want 8", len(recoverySmallOrderKeys))
	}
	seen := map[string]bool{}
	for _, key := range recoverySmallOrderKeys {
		forged := false
		for i := 0; i < 64; i++ {
			message := []byte(fmt.Sprintf("forged-%d", i))
			for _, r := range recoverySmallOrderKeys {
				signature := append(bytes.Clone(r), make([]byte, 32)...)
				if ed25519.Verify(ed25519.PublicKey(key), message, signature) {
					forged = true
					seen[hex.EncodeToString(r)] = true
				}
			}
		}
		if !forged {
			t.Errorf("no forged signature verifies under %x", key)
		}
		if validRecoveryAuthKey(key) {
			t.Errorf("small-order key %x accepted", key)
		}
	}
	for _, r := range recoverySmallOrderKeys {
		if !seen[hex.EncodeToString(r)] {
			t.Errorf("%x never appeared as a forged R", r)
		}
	}
}

func TestValidRecoveryAuthKeyAcceptsRealKeysAndRejectsBadEncodings(t *testing.T) {
	for i := 0; i < 300; i++ {
		public, _, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		if !validRecoveryAuthKey(public) {
			t.Fatalf("generated key %x rejected", public)
		}
	}
	nonCanonical := func(low byte, sign byte) []byte {
		key := bytes.Repeat([]byte{0xff}, 32)
		key[0] = low
		key[31] = 0x7f | sign
		return key
	}
	rejected := map[string][]byte{
		"short":                  make([]byte, 31),
		"long":                   make([]byte, 33),
		"y = p":                  nonCanonical(0xed, 0),
		"y = p + 1":              nonCanonical(0xee, 0),
		"y = 2^255 - 1":          nonCanonical(0xff, 0x80),
		"identity with x sign":   append([]byte{1}, append(make([]byte, 30), 0x80)...),
		"order two with x sign":  nonCanonical(0xec, 0x80),
		"identity":               append([]byte{1}, make([]byte, 31)...),
		"all zero (order four)":  make([]byte, 32),
		"low order eight point":  recoverySmallOrderKeys[4],
		"high order eight point": recoverySmallOrderKeys[7],
	}
	for name, key := range rejected {
		if validRecoveryAuthKey(key) {
			t.Errorf("%s: %x accepted", name, key)
		}
	}
	// About half of all y values are not on the curve; the check must find
	// some among small ones.
	offCurve := 0
	for y := byte(2); y < 40; y++ {
		key := make([]byte, 32)
		key[0] = y
		if !validRecoveryAuthKey(key) {
			offCurve++
		}
	}
	if offCurve == 0 {
		t.Fatal("no off-curve y among 2..39 was rejected")
	}
}
