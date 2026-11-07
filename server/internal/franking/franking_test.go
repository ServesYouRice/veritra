package franking

import (
	"bytes"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/hpke"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func key() []byte { return bytes.Repeat([]byte{7}, KeySize) }

var ctx = Context{ConversationID: "C", SenderDeviceID: "D", ActionID: "A"}

func TestCommitVerifyRoundTrip(t *testing.T) {
	p := []byte(`{"v":2,"type":"text","body":{"text":"hi"}}`)
	c, err := Commit(key(), ctx, p)
	if err != nil || len(c) != CommitSize {
		t.Fatalf("commit: %v len %d", err, len(c))
	}
	if !Verify(c, key(), ctx, p) {
		t.Fatal("valid commit rejected")
	}
}

func TestVerifyRejectsAnyChange(t *testing.T) {
	p := []byte("payload")
	c, _ := Commit(key(), ctx, p)
	other := bytes.Repeat([]byte{8}, KeySize)
	cases := map[string]bool{
		"payload": Verify(c, key(), ctx, []byte("payloae")),
		"key":     Verify(c, other, ctx, p),
		"conv":    Verify(c, key(), Context{"X", "D", "A"}, p),
		"device":  Verify(c, key(), Context{"C", "X", "A"}, p),
		"action":  Verify(c, key(), Context{"C", "D", "X"}, p),
		"short":   Verify(c[:31], key(), ctx, p),
		"badkey":  Verify(c, key()[:5], ctx, p),
	}
	for name, ok := range cases {
		if ok {
			t.Errorf("%s change accepted", name)
		}
	}
}

func TestLengthPrefixPreventsFieldShifting(t *testing.T) {
	a, _ := Commit(key(), Context{"ab", "c", "A"}, []byte("p"))
	b, _ := Commit(key(), Context{"a", "bc", "A"}, []byte("p"))
	if bytes.Equal(a, b) {
		t.Fatal("field boundary shift collides")
	}
}

func TestCommitRejectsBadKey(t *testing.T) {
	if _, err := Commit(nil, ctx, nil); err != ErrKeySize {
		t.Fatalf("got %v", err)
	}
}

func TestCommitRejectsOutOfBoundsInput(t *testing.T) {
	long := strings.Repeat("x", MaxIDSize+1)
	big := bytes.Repeat([]byte("x"), MaxPayloadSize+1)
	cases := map[string]Context{
		"empty conversation": {"", "D", "A"},
		"empty device":       {"C", "", "A"},
		"empty action":       {"C", "D", ""},
		"long conversation":  {long, "D", "A"},
		"long device":        {"C", long, "A"},
		"long action":        {"C", "D", long},
	}
	for name, c := range cases {
		if _, err := Commit(key(), c, []byte("p")); err != ErrInvalidInput {
			t.Errorf("%s: got %v", name, err)
		}
		if Verify(make([]byte, CommitSize), key(), c, []byte("p")) {
			t.Errorf("%s: verified", name)
		}
	}
	for name, p := range map[string][]byte{"empty": nil, "too big": big} {
		if _, err := Commit(key(), ctx, p); err != ErrInvalidInput {
			t.Errorf("payload %s: got %v", name, err)
		}
	}
	edge := Context{strings.Repeat("c", MaxIDSize), "D", "A"}
	if _, err := Commit(key(), edge, bytes.Repeat([]byte("x"), MaxPayloadSize)); err != nil {
		t.Fatalf("maximum sizes refused: %v", err)
	}
}

type sharedVector struct {
	Commitment      commitCase   `json:"commitment"`
	CommitmentCases []commitCase `json:"commitment_cases"`
	MalformedFrank  []string     `json:"malformed_frank"`
	UnfrankedBody   []string     `json:"unfranked_frank_in_body"`
	Report          sealCase     `json:"report_hpke"`
	GoSealed        sealCase     `json:"report_hpke_go_sealed"`
}

type commitCase struct {
	Name           string `json:"name"`
	KeyHex         string `json:"key_hex"`
	ConversationID string `json:"conversation_id"`
	SenderDeviceID string `json:"sender_device_id"`
	ActionID       string `json:"action_id"`
	Payload        string `json:"payload"`
	WireJSON       string `json:"wire_json"`
	CommitHex      string `json:"commit_hex"`
}

type sealCase struct {
	SeedHex   string `json:"seed_hex"`
	PublicHex string `json:"public_hex"`
	AAD       string `json:"aad"`
	Plaintext string `json:"plaintext"`
	SealedHex string `json:"sealed_hex"`
}

// loadVector reads testing/vectors/c6-franking-v1.json, which the Rust core
// (report_tests.rs) and the Dart binding check too. A missing or unreadable
// vector fails; it never skips.
func loadVector(t *testing.T) sharedVector {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "c6-franking-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v sharedVector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func mustHex(t *testing.T, value string) []byte {
	t.Helper()
	out, err := hex.DecodeString(value)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func checkCommitCase(t *testing.T, v commitCase) {
	t.Helper()
	kf, want := mustHex(t, v.KeyHex), mustHex(t, v.CommitHex)
	c := Context{ConversationID: v.ConversationID, SenderDeviceID: v.SenderDeviceID, ActionID: v.ActionID}
	got, err := Commit(kf, c, []byte(v.Payload))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("%s: commit %x, vector %x", v.Name, got, want)
	}
	if !Verify(want, kf, c, []byte(v.Payload)) {
		t.Fatalf("%s: vector commit does not verify", v.Name)
	}
	payload, key, ok := splitFrank(v.WireJSON)
	if !ok || payload != v.Payload || !bytes.Equal(key, kf) {
		t.Fatalf("%s: wire_json does not split into payload and key", v.Name)
	}
}

func TestSharedVector(t *testing.T) {
	v := loadVector(t)
	checkCommitCase(t, v.Commitment)
	if len(v.CommitmentCases) < 2 {
		t.Fatal("vector lost its extra commitment cases")
	}
	for _, c := range v.CommitmentCases {
		checkCommitCase(t, c)
	}
}

// splitFrank is a strict test-side reference for the franking v1 wire rule
// (docs/crypto.md, "Franking v1"): the member is the last one, spelled
// exactly `,"frank":{"k":"<44 chars standard padded base64>"}}`, the key is
// 32 bytes in canonical form, and what remains must be a JSON object
// without a top-level "frank". Dart's splitFrank is the shipped parser; this
// keeps the vector's malformed cases honest on a second implementation.
func splitFrank(wire string) (payload string, key []byte, ok bool) {
	const prefix, tail = `,"frank":{"k":"`, `"}}`
	if len(wire) <= len(prefix)+44+len(tail) || !strings.HasSuffix(wire, tail) {
		return "", nil, false
	}
	start := len(wire) - len(prefix) - 44 - len(tail)
	if wire[start:start+len(prefix)] != prefix {
		return "", nil, false
	}
	text := wire[start+len(prefix) : len(wire)-len(tail)]
	key, err := base64.StdEncoding.DecodeString(text)
	if err != nil || len(key) != KeySize || base64.StdEncoding.EncodeToString(key) != text {
		return "", nil, false
	}
	payload = wire[:start] + "}"
	var object map[string]json.RawMessage
	if json.Unmarshal([]byte(payload), &object) != nil {
		return "", nil, false
	}
	if _, has := object["frank"]; has {
		return "", nil, false
	}
	return payload, key, true
}

func TestSharedVectorMalformedFrank(t *testing.T) {
	v := loadVector(t)
	if len(v.MalformedFrank) < 11 || len(v.UnfrankedBody) < 1 {
		t.Fatal("vector lost its malformed frank cases")
	}
	for _, c := range v.MalformedFrank {
		if _, _, ok := splitFrank(c); ok {
			t.Errorf("malformed frank accepted: %s", c)
		}
	}
	// `frank` nested in the body is not the reserved member: the strict
	// reader finds no frank suffix there (Dart calls it Unfranked).
	for _, c := range v.UnfrankedBody {
		if _, _, ok := splitFrank(c); ok {
			t.Errorf("nested frank read as the reserved member: %s", c)
		}
	}
}

// TestSharedReportSealVector checks the vector's report keys and sealed
// reports with Go's own HKDF and RFC 9180 HPKE (crypto/hpke), independently
// of the Rust core (pm_crypto_report_key_public and pm_crypto_report_seal,
// ABI 12). report_hpke was sealed by Rust and opened here; report_hpke_go_sealed
// was sealed here (generated with crypto/hpke) and Rust and Dart open it. The
// server never opens reports; this is interoperability evidence only.
func TestSharedReportSealVector(t *testing.T) {
	v := loadVector(t)
	for name, r := range map[string]sealCase{"rust sealed": v.Report, "go sealed": v.GoSealed} {
		seed, public, sealed := mustHex(t, r.SeedHex), mustHex(t, r.PublicHex), mustHex(t, r.SealedHex)
		prk, err := hkdf.Extract(sha256.New, seed, []byte("veritra-c6-report-key-v1"))
		if err != nil {
			t.Fatal(err)
		}
		ikm, err := hkdf.Expand(sha256.New, prk, "veritra-c6 report-hpke", 32)
		if err != nil {
			t.Fatal(err)
		}
		private, err := hpke.DHKEM(ecdh.X25519()).DeriveKeyPair(ikm)
		if err != nil {
			t.Fatal(err)
		}
		if got := private.PublicKey().Bytes(); !bytes.Equal(got, public) {
			t.Fatalf("%s: public %x, vector %x", name, got, public)
		}
		if len(sealed) < 4+32 || string(sealed[:4]) != "VRP1" {
			t.Fatalf("%s: sealed vector lacks the VRP1 header", name)
		}
		recipient, err := hpke.NewRecipient(sealed[4:36], private, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte("veritra-c6-report-v1"))
		if err != nil {
			t.Fatal(err)
		}
		opened, err := recipient.Open([]byte(r.AAD), sealed[36:])
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if string(opened) != r.Plaintext {
			t.Fatalf("%s: opened %q, vector %q", name, opened, r.Plaintext)
		}
	}
}
