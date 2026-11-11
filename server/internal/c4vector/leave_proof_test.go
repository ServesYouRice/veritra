package c4vector

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type leaveProofVector struct {
	Name             string   `json:"name"`
	Label            string   `json:"label"`
	GroupID          string   `json:"group_id_hex"`
	LeafIndex        uint32   `json:"leaf_index"`
	EncryptionKeyTLS string   `json:"encryption_key_tls_hex"`
	SigningSeed      string   `json:"signing_seed_hex"`
	SigningPublic    string   `json:"signing_public_hex"`
	LeaveTBS         string   `json:"leave_tbs_hex"`
	SignContent      string   `json:"sign_content_hex"`
	Signature        string   `json:"signature_hex"`
	Statement        string   `json:"statement_hex"`
	SecondStatement  string   `json:"second_statement_hex"`
	AAD              string   `json:"aad_hex"`
	MalformedAADList []string `json:"malformed_aad_hex"`
}

func load(t *testing.T) leaveProofVector {
	t.Helper()
	name := "c4-leave-proof-v1.json"
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", name))
	if err != nil {
		t.Fatalf("%s: %v (a missing vector fails; it never skips)", name, err)
	}
	var v leaveProofVector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if v.Name != "c4-leave-proof-v1" {
		t.Fatalf("vector name %q", v.Name)
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

// varint is the RFC 9420 variable-length integer prefix (section 2.1.2).
func varint(n int) []byte {
	switch {
	case n < 1<<6:
		return []byte{byte(n)}
	case n < 1<<14:
		return []byte{0x40 | byte(n>>8), byte(n)}
	default:
		return []byte{0x80 | byte(n>>24), byte(n >> 16), byte(n >> 8), byte(n)}
	}
}

// vl is an RFC 9420 opaque<V>: a varint length, then the bytes.
func vl(b []byte) []byte { return append(varint(len(b)), b...) }

func u32(v uint32) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, v)
	return b
}

const (
	statementBytes = 70
	maxStatements  = 16
)

type statement struct {
	leaf      uint32
	signature []byte
}

var errMalformed = errors.New("malformed VCL1 list")

// parseAAD is the strict VCL1 reading: magic, a count of 1..16, exactly that
// many 70-byte statements with u16 64 signature lengths, distinct leaves,
// nothing after.
func parseAAD(aad []byte) ([]statement, error) {
	if len(aad) < 5 || !bytes.Equal(aad[:4], []byte("VCL1")) {
		return nil, errMalformed
	}
	count := int(aad[4])
	if count < 1 || count > maxStatements || len(aad) != 5+count*statementBytes {
		return nil, errMalformed
	}
	seen := map[uint32]bool{}
	out := make([]statement, 0, count)
	for i := range count {
		s := aad[5+i*statementBytes : 5+(i+1)*statementBytes]
		if binary.BigEndian.Uint16(s[4:6]) != 64 {
			return nil, errMalformed
		}
		leaf := binary.BigEndian.Uint32(s[:4])
		if seen[leaf] {
			return nil, errMalformed
		}
		seen[leaf] = true
		out = append(out, statement{leaf: leaf, signature: s[6:]})
	}
	return out, nil
}

func TestLeaveProofVector(t *testing.T) {
	v := load(t)
	group := unhex(t, v.GroupID)
	// The leaf's HPKE key as the leaf node carries it (TLS opaque<V>).
	keyTLS := unhex(t, v.EncryptionKeyTLS)
	if len(keyTLS) != 33 || !bytes.Equal(keyTLS, vl(keyTLS[1:])) {
		t.Fatalf("encryption_key_tls is not a VL 32-byte key: %x", keyTLS)
	}

	// LeaveTBS = VL(group_id) || u32 leaf_index || EncryptionKey (opaque<V>).
	tbs := bytes.Join([][]byte{vl(group), u32(v.LeafIndex), keyTLS}, nil)
	if got := hex.EncodeToString(tbs); got != v.LeaveTBS {
		t.Fatalf("leave_tbs %s, vector %s", got, v.LeaveTBS)
	}
	// SignContent = VL("MLS 1.0 " || label) || VL(LeaveTBS) (RFC 9420 5.1.2).
	content := append(vl([]byte("MLS 1.0 "+v.Label)), vl(tbs)...)
	if got := hex.EncodeToString(content); got != v.SignContent {
		t.Fatalf("sign_content %s, vector %s", got, v.SignContent)
	}

	priv := ed25519.NewKeyFromSeed(unhex(t, v.SigningSeed))
	pub := priv.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(pub); got != v.SigningPublic {
		t.Fatalf("signing_public %s, vector %s", got, v.SigningPublic)
	}
	sig := unhex(t, v.Signature)
	// Ed25519 is deterministic: Go signs the same bytes Rust did.
	if got := ed25519.Sign(priv, content); !bytes.Equal(got, sig) {
		t.Fatalf("signature %x, vector %x", got, sig)
	}
	if !ed25519.Verify(pub, content, sig) {
		t.Fatal("vector signature does not verify")
	}
	// The signature covers the labelled content, never the bare TBS.
	if ed25519.Verify(pub, tbs, sig) {
		t.Fatal("signature verifies over the unlabelled TBS")
	}

	stmt := bytes.Join([][]byte{u32(v.LeafIndex), {0, 64}, sig}, nil)
	if got := hex.EncodeToString(stmt); got != v.Statement {
		t.Fatalf("statement %s, vector %s", got, v.Statement)
	}
	second := unhex(t, v.SecondStatement)
	aad := bytes.Join([][]byte{[]byte("VCL1"), {2}, stmt, second}, nil)
	if got := hex.EncodeToString(aad); got != v.AAD {
		t.Fatalf("aad %s, vector %s", got, v.AAD)
	}
	parsed, err := parseAAD(aad)
	if err != nil || len(parsed) != 2 || parsed[0].leaf != v.LeafIndex ||
		!bytes.Equal(parsed[0].signature, sig) {
		t.Fatalf("parse aad: %v %+v", err, parsed)
	}
}

func TestLeaveProofVectorMalformedListsProveNothing(t *testing.T) {
	v := load(t)
	if len(v.MalformedAADList) == 0 {
		t.Fatal("vector lists no malformed AAD")
	}
	for i, raw := range v.MalformedAADList {
		if _, err := parseAAD(unhex(t, raw)); err == nil {
			t.Errorf("malformed_aad_hex[%d] parsed", i)
		}
	}
}
