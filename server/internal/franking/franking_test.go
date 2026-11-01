package franking

import (
	"bytes"
	"encoding/hex"
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

// Logs a fixed vector for the Rust and Dart implementations to match.
func TestVector(t *testing.T) {
	c, _ := Commit(key(), ctx, []byte("hello"))
	t.Logf("vector: %s", hex.EncodeToString(c))
}
