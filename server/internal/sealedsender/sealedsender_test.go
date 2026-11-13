package sealedsender

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type vector struct {
	ServerSeed string `json:"server_seed"`
	KeyInfo    string `json:"key_info"`
	PublicKey  string `json:"public_key"`
	KeyID      string `json:"key_id"`
	InfoCase   struct {
		ConversationID string `json:"conversation_id"`
		Epoch          uint32 `json:"epoch"`
		Info           string `json:"info"`
	} `json:"info_case"`
	Exchange struct {
		Count    int    `json:"count"`
		Request  string `json:"request"`
		Response string `json:"response"`
		Tokens   string `json:"tokens"`
	} `json:"exchange"`
	RFC struct {
		Seed    string `json:"seed"`
		KeyInfo string `json:"key_info"`
		PK      string `json:"pk"`
		SK      string `json:"sk"`
		Cases   []struct {
			Input             string `json:"input"`
			Info              string `json:"info"`
			BlindedElement    string `json:"blinded_element"`
			EvaluationElement string `json:"evaluation_element"`
			Output            string `json:"output"`
		} `json:"cases"`
	} `json:"rfc9497_poprf_ristretto255"`
}

// loadVector reads testing/vectors/l2-sealed-v1.json, which the Rust core
// generates and Dart checks too.
func loadVector(t *testing.T) vector {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "l2-sealed-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestVectorKeyInfoAndKeyID(t *testing.T) {
	v := loadVector(t)
	key, err := DeriveKey(unhex(t, v.ServerSeed), []byte(v.KeyInfo))
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(key.PublicKey()); got != v.PublicKey {
		t.Fatalf("public key %s, want %s", got, v.PublicKey)
	}
	if key.ID() != v.KeyID || KeyID(unhex(t, v.PublicKey)) != v.KeyID {
		t.Fatalf("key id %s, want %s", key.ID(), v.KeyID)
	}
	info, err := Info(v.InfoCase.ConversationID, v.InfoCase.Epoch)
	if err != nil || hex.EncodeToString(info) != v.InfoCase.Info {
		t.Fatalf("info %x (%v), want %s", info, err, v.InfoCase.Info)
	}
}

// The Rust client's request evaluates to the vector's elements (the proof
// is randomized, so only its size is fixed) and every vector token verifies
// under the same info and fails under any other.
func TestVectorExchange(t *testing.T) {
	v := loadVector(t)
	key, err := DeriveKey(unhex(t, v.ServerSeed), []byte(v.KeyInfo))
	if err != nil {
		t.Fatal(err)
	}
	ic := v.InfoCase
	response, err := key.Evaluate(ic.ConversationID, ic.Epoch, unhex(t, v.Exchange.Request))
	if err != nil {
		t.Fatal(err)
	}
	want := unhex(t, v.Exchange.Response)
	n := v.Exchange.Count * ElementSize
	if len(response) != n+ProofSize || !bytes.Equal(response[:n], want[:n]) {
		t.Fatalf("evaluated elements differ from the vector")
	}
	tokens := unhex(t, v.Exchange.Tokens)
	if len(tokens) != v.Exchange.Count*(NonceSize+OutputSize) {
		t.Fatalf("token bytes %d", len(tokens))
	}
	for i := range v.Exchange.Count {
		tok := tokens[i*(NonceSize+OutputSize) : (i+1)*(NonceSize+OutputSize)]
		nonce, output := tok[:NonceSize], tok[NonceSize:]
		if !key.Verify(ic.ConversationID, ic.Epoch, nonce, output) {
			t.Fatalf("token %d does not verify", i)
		}
		for name, ok := range map[string]bool{
			"other conversation": key.Verify(ic.ConversationID+"x", ic.Epoch, nonce, output),
			"next epoch":         key.Verify(ic.ConversationID, ic.Epoch+1, nonce, output),
			"short output":       key.Verify(ic.ConversationID, ic.Epoch, nonce, output[:63]),
		} {
			if ok {
				t.Fatalf("token %d verified under %s", i, name)
			}
		}
		other, err := DeriveKey(bytes.Repeat([]byte{0x5d}, 32), []byte(v.KeyInfo))
		if err != nil {
			t.Fatal(err)
		}
		if other.Verify(ic.ConversationID, ic.Epoch, nonce, output) {
			t.Fatalf("token %d verified under another key", i)
		}
	}
}

func TestRFC9497POPRFVectors(t *testing.T) {
	v := loadVector(t)
	key, err := DeriveKey(unhex(t, v.RFC.Seed), unhex(t, v.RFC.KeyInfo))
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(key.PublicKey()) != v.RFC.PK {
		t.Fatalf("RFC public key mismatch")
	}
	for i, c := range v.RFC.Cases {
		// The RFC's info is raw bytes, not our layout: evaluate through the
		// server directly.
		info := unhex(t, c.Info)
		out, err := key.server.FullEvaluate(unhex(t, c.Input), info)
		if err != nil || hex.EncodeToString(out) != c.Output {
			t.Fatalf("case %d output mismatch (%v)", i, err)
		}
	}
}

func TestEvaluateRefusesBadRequests(t *testing.T) {
	key, err := DeriveKey(bytes.Repeat([]byte{1}, 32), nil)
	if err != nil {
		t.Fatal(err)
	}
	valid := unhex(t, loadVector(t).Exchange.Request)[:ElementSize]
	for name, blinded := range map[string][]byte{
		"empty":     nil,
		"ragged":    valid[:31],
		"identity":  make([]byte, ElementSize),
		"not point": bytes.Repeat([]byte{0xff}, ElementSize),
		"too many":  bytes.Repeat(valid, MaxBatch+1),
	} {
		if _, err := key.Evaluate("conv", 1, blinded); err == nil {
			t.Fatalf("%s: evaluated", name)
		}
	}
	if _, err := key.Evaluate("", 1, valid); err == nil {
		t.Fatal("empty conversation evaluated")
	}
	if _, err := key.Evaluate(string(bytes.Repeat([]byte{'a'}, MaxIDSize+1)), 1, valid); err == nil {
		t.Fatal("long conversation evaluated")
	}
	if _, err := key.Evaluate("conv", 1, bytes.Repeat(valid, MaxBatch)); err != nil {
		t.Fatalf("full batch refused: %v", err)
	}
}

func TestGenerateAndLoadKey(t *testing.T) {
	priv, err := GenerateKey(nil)
	if err != nil || len(priv) != PrivateKeySize {
		t.Fatalf("generate: %v", err)
	}
	a, err := LoadKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	b, err := LoadKey(priv)
	if err != nil || a.ID() != b.ID() || !bytes.Equal(a.PublicKey(), b.PublicKey()) {
		t.Fatalf("reload changed the key: %v", err)
	}
	if _, err := LoadKey(make([]byte, PrivateKeySize)); err == nil {
		t.Fatal("zero key loaded")
	}
	if _, err := LoadKey(priv[:31]); err == nil {
		t.Fatal("short key loaded")
	}
}

func TestEpoch(t *testing.T) {
	if got := Epoch(time.Unix(20404*86400+86399, 0)); got != 20404 {
		t.Fatalf("epoch %d", got)
	}
	if got := Epoch(time.Unix(20405*86400, 0)); got != 20405 {
		t.Fatalf("epoch %d", got)
	}
}
