package franking

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
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

// TestSharedVector checks testing/vectors/c6-franking-v1.json, which the
// Rust core (report_tests.rs) and the Dart binding check too. A missing or
// unreadable vector fails; it never skips.
func TestSharedVector(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "c6-franking-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var vector struct {
		Commitment struct {
			KeyHex         string `json:"key_hex"`
			ConversationID string `json:"conversation_id"`
			SenderDeviceID string `json:"sender_device_id"`
			ActionID       string `json:"action_id"`
			Payload        string `json:"payload"`
			CommitHex      string `json:"commit_hex"`
		} `json:"commitment"`
	}
	if err := json.Unmarshal(raw, &vector); err != nil {
		t.Fatal(err)
	}
	v := vector.Commitment
	kf, err := hex.DecodeString(v.KeyHex)
	if err != nil {
		t.Fatal(err)
	}
	want, err := hex.DecodeString(v.CommitHex)
	if err != nil {
		t.Fatal(err)
	}
	c := Context{ConversationID: v.ConversationID, SenderDeviceID: v.SenderDeviceID, ActionID: v.ActionID}
	got, err := Commit(kf, c, []byte(v.Payload))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("commit %x, vector %x", got, want)
	}
	if !Verify(want, kf, c, []byte(v.Payload)) {
		t.Fatal("vector commit does not verify")
	}
}
