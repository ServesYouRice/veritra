// Package b6vector checks testing/vectors/b6-media-v1.json (B6 media keys
// and the join signature) with Go's standard library, independently of the
// Rust core.
package b6vector

import (
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type vector struct {
	Inputs  map[string]any `json:"inputs"`
	Outputs struct {
		Context string `json:"exporter_context_hex"`
		Keys    []struct {
			Leaf   uint32 `json:"leaf"`
			Stream uint8  `json:"stream"`
			Key    string `json:"key_hex"`
		} `json:"keys"`
		Public    string `json:"join_public_key_hex"`
		Message   string `json:"join_message_hex"`
		Signature string `json:"join_signature_hex"`
	} `json:"outputs"`
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func lp(b []byte) []byte {
	return append(binary.BigEndian.AppendUint16(nil, uint16(len(b))), b...)
}

func TestB6VectorReDerived(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "b6-media-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	in := v.Inputs
	str := func(k string) string { return in[k].(string) }

	ctx := append(lp([]byte(str("call_id"))), binary.BigEndian.AppendUint64(nil, uint64(in["epoch"].(float64)))...)
	if hex.EncodeToString(ctx) != v.Outputs.Context {
		t.Fatal("exporter context")
	}
	if str("exporter_label") != "veritra-b6-media-v1" || str("sender_salt") != "veritra-b6-sender-v1" {
		t.Fatal("labels")
	}
	e := unhex(t, str("exporter_secret_hex"))
	if len(v.Outputs.Keys) == 0 {
		t.Fatal("no keys")
	}
	for _, k := range v.Outputs.Keys {
		info := append(binary.BigEndian.AppendUint32(nil, k.Leaf), k.Stream)
		got, err := hkdf.Key(sha256.New, e, []byte(str("sender_salt")), string(info), 32)
		if err != nil {
			t.Fatal(err)
		}
		if hex.EncodeToString(got) != k.Key {
			t.Fatalf("key leaf %d stream %d", k.Leaf, k.Stream)
		}
	}

	kp := unhex(t, str("join_key_package_hex"))
	sum := sha256.Sum256(kp)
	msg := append(lp(unhex(t, str("join_group_id_hex"))), lp(unhex(t, str("join_nonce_hex")))...)
	msg = binary.BigEndian.AppendUint64(msg, uint64(in["join_expires_at"].(float64)))
	msg = append(msg, sum[:]...)
	if hex.EncodeToString(msg) != v.Outputs.Message {
		t.Fatal("join message")
	}
	pub := ed25519.PublicKey(unhex(t, v.Outputs.Public))
	if got := ed25519.NewKeyFromSeed(unhex(t, str("join_seed_hex"))).Public().(ed25519.PublicKey); !pub.Equal(got) {
		t.Fatal("public key")
	}
	signed := append([]byte(str("join_domain")), msg...)
	sig := unhex(t, v.Outputs.Signature)
	if !ed25519.Verify(pub, signed, sig) {
		t.Fatal("join signature")
	}
	if ed25519.Verify(pub, append([]byte("veritra-c7-post-sig-v1"), msg...), sig) {
		t.Fatal("signature verifies under another domain")
	}
}
