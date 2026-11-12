package sealedsender

// An independent check of testing/vectors/l2-frank-dv-v1.json, the
// designated-verifier franking of a sealed message (docs/crypto.md,
// "Franking a sealed message"). Nothing here comes from the Rust core: X25519
// is golang.org/x/crypto/curve25519, HKDF, HMAC and SHA-256 are the standard
// library, and every value is recomputed from the vector's secrets. The
// server never checks tags; this only shows two implementations agree.

import (
	"bytes"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"golang.org/x/crypto/curve25519"
)

type dvVector struct {
	Label          string `json:"label"`
	KidLabel       string `json:"kid_label"`
	KeyLabel       string `json:"key_label"`
	ConversationID string `json:"conversation_id"`
	Commit         string `json:"commit"`
	Sender         struct {
		AccountID   string `json:"account_id"`
		DeviceID    string `json:"device_id"`
		FrankSecret string `json:"frank_secret"`
		FrankPublic string `json:"frank_public"`
	} `json:"sender"`
	Owners []struct {
		ReportSeed   string `json:"report_seed"`
		X25519Secret string `json:"x25519_secret"`
		ReportPublic string `json:"report_public"`
		Kid          string `json:"kid"`
		Z            string `json:"z"`
		K            string `json:"k"`
		TagInput     string `json:"tag_input"`
		Tag          string `json:"tag"`
	} `json:"owners"`
	Designations []struct {
		Name            string   `json:"name"`
		OwnerPublicKeys []string `json:"owner_public_keys"`
		D               string   `json:"d"`
	} `json:"designations"`
	VerifyCases []struct {
		Name              string `json:"name"`
		ReportSeed        string `json:"report_seed"`
		SenderFrankPublic string `json:"sender_frank_public"`
		ConversationID    string `json:"conversation_id"`
		AccountID         string `json:"account_id"`
		DeviceID          string `json:"device_id"`
		Commit            string `json:"commit"`
		D                 string `json:"d"`
		Result            int    `json:"result"`
	} `json:"verify_cases"`
	Refused []struct {
		Kind string `json:"kind"`
		Key  string `json:"key"`
	} `json:"refused_public_keys"`
}

func loadDVVector(t *testing.T) dvVector {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "l2-frank-dv-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v dvVector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// p = 2^255 - 19, little-endian.
var fieldP = func() []byte {
	p := bytes.Repeat([]byte{0xff}, 32)
	p[0], p[31] = 0xed, 0x7f
	return p
}()

// canonical reports whether u (little-endian) has bit 255 clear and u < p.
func canonical(u []byte) bool {
	if len(u) != 32 || u[31]&0x80 != 0 {
		return false
	}
	for i := 31; i >= 0; i-- {
		if u[i] != fieldP[i] {
			return u[i] < fieldP[i]
		}
	}
	return false
}

// reportX25519Secret derives the C6 report key pair's X25519 secret from
// the seed exactly as report.rs does: HKDF-SHA256 to 32 bytes, then RFC 9180
// DeriveKeyPair for DHKEM(X25519, HKDF-SHA256).
func reportX25519Secret(t *testing.T, seed []byte) []byte {
	t.Helper()
	prk, err := hkdf.Extract(sha256.New, seed, []byte("veritra-c6-report-key-v1"))
	if err != nil {
		t.Fatal(err)
	}
	ikm, err := hkdf.Expand(sha256.New, prk, "veritra-c6 report-hpke", 32)
	if err != nil {
		t.Fatal(err)
	}
	// RFC 9180 §7.1.3: suite_id = "KEM" || I2OSP(0x0020, 2).
	suite := []byte{'K', 'E', 'M', 0x00, 0x20}
	labeledExtract := func(salt []byte, label string, ikm []byte) []byte {
		in := append(append(append([]byte("HPKE-v1"), suite...), label...), ikm...)
		out, err := hkdf.Extract(sha256.New, in, salt)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	labeledExpand := func(prk []byte, label string, info []byte, length int) []byte {
		in := binary.BigEndian.AppendUint16(nil, uint16(length))
		in = append(append(append(append(in, "HPKE-v1"...), suite...), label...), info...)
		out, err := hkdf.Expand(sha256.New, prk, string(in), length)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	dkp := labeledExtract(nil, "dkp_prk", ikm)
	return labeledExpand(dkp, "sk", nil, 32)
}

func appendLP16(out []byte, s string) []byte {
	out = binary.BigEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
}

func dvKid(v dvVector, pub []byte) []byte {
	sum := sha256.Sum256(append([]byte(v.KidLabel), pub...))
	return sum[:16]
}

func dvTag(t *testing.T, v dvVector, z, sender, verifier []byte, conv, account, device string, kid, commit []byte) (key, input, tag []byte) {
	t.Helper()
	prk, err := hkdf.Extract(sha256.New, z, []byte(v.Label))
	if err != nil {
		t.Fatal(err)
	}
	info := append(append([]byte(v.KeyLabel), sender...), verifier...)
	key, err = hkdf.Expand(sha256.New, prk, string(info), 32)
	if err != nil {
		t.Fatal(err)
	}
	input = []byte(v.Label)
	for _, id := range []string{conv, account, device} {
		input = appendLP16(input, id)
	}
	input = append(append(input, kid...), commit...)
	mac := hmac.New(sha256.New, key)
	mac.Write(input)
	return key, input, mac.Sum(nil)
}

func TestDVVectorIndependentX25519(t *testing.T) {
	v := loadDVVector(t)
	if v.Label != "veritra-frank-dv-v1" || v.KidLabel != "veritra-frank-dv-kid-v1" || v.KeyLabel != "veritra-frank-dv-v1 key" {
		t.Fatal("labels")
	}
	commit := mustHex(t, v.Commit)
	fSecret := mustHex(t, v.Sender.FrankSecret)
	fPublic, err := curve25519.X25519(fSecret, curve25519.Basepoint)
	if err != nil || hex.EncodeToString(fPublic) != v.Sender.FrankPublic {
		t.Fatalf("sender public %x (%v)", fPublic, err)
	}
	for i, owner := range v.Owners {
		sk := reportX25519Secret(t, mustHex(t, owner.ReportSeed))
		if hex.EncodeToString(sk) != owner.X25519Secret {
			t.Fatalf("owner %d: report secret %x", i, sk)
		}
		pk, err := curve25519.X25519(sk, curve25519.Basepoint)
		if err != nil || hex.EncodeToString(pk) != owner.ReportPublic {
			t.Fatalf("owner %d: report public %x (%v)", i, pk, err)
		}
		kid := dvKid(v, pk)
		if hex.EncodeToString(kid) != owner.Kid {
			t.Fatalf("owner %d: kid", i)
		}
		// Z both ways.
		z1, err1 := curve25519.X25519(fSecret, pk)
		z2, err2 := curve25519.X25519(sk, fPublic)
		if err1 != nil || err2 != nil || !bytes.Equal(z1, z2) || hex.EncodeToString(z1) != owner.Z {
			t.Fatalf("owner %d: Z %x %x", i, z1, z2)
		}
		key, input, tag := dvTag(t, v, z1, fPublic, pk, v.ConversationID, v.Sender.AccountID, v.Sender.DeviceID, kid, commit)
		if hex.EncodeToString(key) != owner.K || hex.EncodeToString(input) != owner.TagInput || hex.EncodeToString(tag) != owner.Tag {
			t.Fatalf("owner %d: K, input or tag differ", i)
		}
	}
}

// designate is an independent Go designation: skip keys that are not
// canonical or give an all-zero Z, one entry per kid, sorted by kid.
func designate(t *testing.T, v dvVector, fSecret, fPublic []byte, keys [][]byte, conv, account, device string, commit []byte) []byte {
	type entry struct{ kid, tag []byte }
	var entries []entry
	seen := map[string]bool{}
	for _, pk := range keys {
		if !canonical(pk) {
			continue
		}
		z, err := curve25519.X25519(fSecret, pk)
		if err != nil {
			continue // x/crypto refuses an all-zero result (low order)
		}
		kid := dvKid(v, pk)
		if seen[string(kid)] {
			continue
		}
		seen[string(kid)] = true
		_, _, tag := dvTag(t, v, z, fPublic, pk, conv, account, device, kid, commit)
		entries = append(entries, entry{kid, tag})
	}
	sort.Slice(entries, func(i, j int) bool { return bytes.Compare(entries[i].kid, entries[j].kid) < 0 })
	var out []byte
	for _, e := range entries {
		out = append(append(out, e.kid...), e.tag...)
	}
	return out
}

func TestDVVectorDesignationsAndVerdicts(t *testing.T) {
	v := loadDVVector(t)
	fSecret := mustHex(t, v.Sender.FrankSecret)
	fPublic := mustHex(t, v.Sender.FrankPublic)
	commit := mustHex(t, v.Commit)
	for _, c := range v.Designations {
		var keys [][]byte
		for _, k := range c.OwnerPublicKeys {
			keys = append(keys, mustHex(t, k))
		}
		d := designate(t, v, fSecret, fPublic, keys, v.ConversationID, v.Sender.AccountID, v.Sender.DeviceID, commit)
		if hex.EncodeToString(d) != c.D {
			t.Fatalf("%s: d differs", c.Name)
		}
	}
	for _, c := range v.VerifyCases {
		sk := reportX25519Secret(t, mustHex(t, c.ReportSeed))
		pk, _ := curve25519.X25519(sk, curve25519.Basepoint)
		d := mustHex(t, c.D)
		got := 2
		for off := 0; off+48 <= len(d); off += 48 {
			if !bytes.Equal(d[off:off+16], dvKid(v, pk)) {
				continue
			}
			got = 0
			sender := mustHex(t, c.SenderFrankPublic)
			if !canonical(sender) {
				break
			}
			z, err := curve25519.X25519(sk, sender)
			if err != nil {
				break
			}
			_, _, tag := dvTag(t, v, z, sender, pk, c.ConversationID, c.AccountID, c.DeviceID, dvKid(v, pk), mustHex(t, c.Commit))
			if hmac.Equal(tag, d[off+16:off+48]) {
				got = 1
			}
		}
		if got != c.Result {
			t.Fatalf("%s: verdict %d, vector %d", c.Name, got, c.Result)
		}
	}
}

// The refused keys: every low-order point (and its high-bit spelling) makes
// x/crypto's X25519 fail with an all-zero result, and every non-canonical
// spelling of an ordinary point gives exactly the canonical point's Z, so
// refusing it is a rule above X25519 (one key, one encoding), as the Rust
// core and the vector record.
func TestDVVectorRefusedKeys(t *testing.T) {
	v := loadDVVector(t)
	fSecret := mustHex(t, v.Sender.FrankSecret)
	lowOrder, nonCanonical := 0, 0
	for _, r := range v.Refused {
		key := mustHex(t, r.Key)
		switch r.Kind {
		case "low_order":
			lowOrder++
			if _, err := curve25519.X25519(fSecret, key); err == nil {
				t.Fatalf("low-order %x accepted by x/crypto", key)
			}
		case "non_canonical":
			nonCanonical++
			if canonical(key) {
				t.Fatalf("%x is canonical", key)
			}
			reduced := reduce(key)
			if !canonical(reduced) {
				t.Fatalf("%x does not reduce", key)
			}
			z1, err1 := curve25519.X25519(fSecret, key)
			z2, err2 := curve25519.X25519(fSecret, reduced)
			if err1 != nil || err2 != nil || !bytes.Equal(z1, z2) {
				t.Fatalf("%x: X25519 differs from its canonical point", key)
			}
		default:
			t.Fatalf("kind %q", r.Kind)
		}
	}
	if lowOrder != 14 || nonCanonical < 2 {
		t.Fatalf("refused list: %d low-order, %d non-canonical", lowOrder, nonCanonical)
	}
}

// reduce clears bit 255 and subtracts p once if the value is still ≥ p.
func reduce(u []byte) []byte {
	out := append([]byte(nil), u...)
	out[31] &= 0x7f
	if canonical(out) {
		return out
	}
	var borrow int
	for i := 0; i < 32; i++ {
		d := int(out[i]) - int(fieldP[i]) - borrow
		borrow = 0
		if d < 0 {
			d += 256
			borrow = 1
		}
		out[i] = byte(d)
	}
	return out
}
