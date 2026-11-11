package mlswire_test

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"private-messenger/server/internal/mlswire"
)

// l2Vector is testing/vectors/l2-padding-v1.json (L2-1, crypto ABI 23).
type l2Vector struct {
	PadExtensionType int `json:"pad_extension_type"`
	Block            int `json:"block"`
	LinearLimit      int `json:"linear_limit"`
	MaxPadded        int `json:"max_padded"`
	Buckets          []struct {
		Length int  `json:"length"`
		Padded *int `json:"padded"`
	} `json:"buckets"`
	KeyPackageHex string `json:"key_package_hex"`
}

func readL2Vector(t *testing.T) l2Vector {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "l2-padding-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v l2Vector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// l2Bucket re-states the rule from docs/crypto.md ("L2 padding"),
// independently of the Rust core.
func l2Bucket(v l2Vector, n int) (int, bool) {
	if n <= v.LinearLimit {
		blocks := (n + v.Block - 1) / v.Block
		if blocks < 1 {
			blocks = 1
		}
		return blocks * v.Block, true
	}
	p := 1
	for p < n {
		p *= 2
	}
	return p, p <= v.MaxPadded
}

func TestL2PaddingVectorBuckets(t *testing.T) {
	v := readL2Vector(t)
	if v.PadExtensionType != 0xF0A2 || len(v.Buckets) < 10 {
		t.Fatalf("unexpected vector header: %+v", v)
	}
	for _, c := range v.Buckets {
		got, ok := l2Bucket(v, c.Length)
		if c.Padded == nil {
			if ok {
				t.Fatalf("length %d: want no bucket, got %d", c.Length, got)
			}
			continue
		}
		if !ok || got != *c.Padded {
			t.Fatalf("length %d: want %d, got %d (%v)", c.Length, *c.Padded, got, ok)
		}
	}
}

// The server's structural check accepts a padded ABI 23 key package (the
// pad is an ordinary extension and its type is in the leaf capabilities),
// reads its leaf key, and refuses it once a byte is cut from the pad.
func TestValidateKeyPackageAcceptsAnL2PaddedPackage(t *testing.T) {
	v := readL2Vector(t)
	kp, err := hex.DecodeString(v.KeyPackageHex)
	if err != nil {
		t.Fatal(err)
	}
	if size, _ := l2Bucket(v, len(kp)); size != len(kp) {
		t.Fatalf("vector key package is %d bytes, not a bucket", len(kp))
	}
	if !bytes.Contains(kp, []byte{0xF0, 0xA2}) {
		t.Fatal("vector key package carries no pad extension")
	}
	if err := mlswire.ValidateKeyPackage(kp); err != nil {
		t.Fatalf("padded key package rejected: %v", err)
	}
	if key, err := mlswire.LeafSignatureKey(kp); err != nil || len(key) != 32 {
		t.Fatalf("leaf key of padded package: %x, %v", key, err)
	}
	// Drop one zero byte from the pad without fixing its length prefix.
	marker := bytes.LastIndex(kp, []byte{0xF0, 0xA2})
	cut := append(append([]byte{}, kp[:marker+5]...), kp[marker+6:]...)
	if err := mlswire.ValidateKeyPackage(cut); err == nil {
		t.Fatal("truncated pad accepted")
	}
}
