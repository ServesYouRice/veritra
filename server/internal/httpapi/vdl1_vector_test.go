package httpapi

import (
	"bytes"
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

// This file checks testing/vectors/l1-device-list-v1.json, the shared vector
// for the approved-device list (docs/designs/L1-approved-device-list.md,
// step L1-1). The Rust core (crypto/rust/src/l1_tests.rs) and Dart
// (mobile/test/l1_device_list_native_test.dart) check it too.
//
// The checker below is an independent reimplementation written from the
// design, not from the Rust code, and test-only: the production Go parse and
// check belong to L1-2 (the server step). It uses Go's crypto/ed25519, which
// is laxer than the clients' strict verifier, so the edge-case test pins
// which side accepts what.

const (
	vdl1VecSigLabel  = "veritra-l1-device-list-sig-v1"
	vdl1VecHashLabel = "veritra-l1-device-list-hash-v1"
)

type vdl1VecPair struct {
	id  string
	key []byte
}

type vdl1VecStatement struct {
	account    string
	version    uint64
	prevHash   []byte
	created    uint64
	change     byte
	entries    []vdl1VecPair
	recovery   []byte
	signerKind byte
	signerID   string
	signature  []byte
	body       []byte
}

func (s *vdl1VecStatement) listHash() []byte {
	digest := sha256.Sum256(append([]byte(vdl1VecHashLabel), s.body...))
	return digest[:]
}

func vdl1VecSignedMessage(body []byte, kind byte, signerID string) []byte {
	digest := sha256.Sum256(body)
	message := append([]byte(vdl1VecSigLabel), digest[:]...)
	message = append(message, kind)
	message = binary.BigEndian.AppendUint16(message, uint16(len(signerID)))
	return append(message, signerID...)
}

type vdl1VecReader struct {
	data   []byte
	offset int
	bad    bool
}

func (r *vdl1VecReader) take(count int) []byte {
	if r.bad || count < 0 || r.offset+count > len(r.data) {
		r.bad = true
		return nil
	}
	value := r.data[r.offset : r.offset+count]
	r.offset += count
	return value
}

func (r *vdl1VecReader) byteValue() byte {
	if value := r.take(1); value != nil {
		return value[0]
	}
	return 0
}

func (r *vdl1VecReader) u64() uint64 {
	if value := r.take(8); value != nil {
		return binary.BigEndian.Uint64(value)
	}
	return 0
}

// lp reads a u16 length and that many bytes, which must number min..max.
func (r *vdl1VecReader) lp(min, max int) []byte {
	length := r.take(2)
	if length == nil {
		return nil
	}
	n := int(binary.BigEndian.Uint16(length))
	if n < min || n > max {
		r.bad = true
		return nil
	}
	if n == 0 {
		return []byte{}
	}
	return r.take(n)
}

func vdl1VecParse(raw []byte) (*vdl1VecStatement, string) {
	if len(raw) > 4096 {
		return nil, "malformed"
	}
	r := &vdl1VecReader{data: raw}
	if !bytes.Equal(r.take(4), []byte("VDL1")) || r.byteValue() != 1 {
		return nil, "malformed"
	}
	s := &vdl1VecStatement{}
	s.account = string(r.lp(1, 128))
	s.version = r.u64()
	s.prevHash = r.take(32)
	s.created = r.u64()
	s.change = r.byteValue()
	count := int(r.byteValue())
	if r.bad || s.version == 0 || s.change < 1 || s.change > 6 || count < 1 || count > 16 {
		return nil, "malformed"
	}
	for i := 0; i < count; i++ {
		id := r.lp(1, 128)
		key := r.take(32)
		if r.bad || !validRecoveryAuthKey(key) {
			return nil, "malformed"
		}
		if i > 0 && s.entries[i-1].id >= string(id) {
			return nil, "malformed"
		}
		for _, other := range s.entries {
			if bytes.Equal(other.key, key) {
				return nil, "malformed"
			}
		}
		s.entries = append(s.entries, vdl1VecPair{string(id), key})
	}
	switch r.byteValue() {
	case 0:
	case 1:
		s.recovery = r.take(32)
		if r.bad || !validRecoveryAuthKey(s.recovery) {
			return nil, "malformed"
		}
	default:
		return nil, "malformed"
	}
	if r.bad {
		return nil, "malformed"
	}
	genesis := s.change == 1 || s.change == 6
	if genesis != (s.version == 1) || (genesis && !bytes.Equal(s.prevHash, make([]byte, 32))) {
		return nil, "malformed"
	}
	s.body = raw[:r.offset]
	s.signerKind = r.byteValue()
	switch s.signerKind {
	case 1:
		s.signerID = string(r.lp(1, 128))
	case 2:
		r.lp(0, 0)
	default:
		return nil, "malformed"
	}
	s.signature = r.take(64)
	if r.bad || r.offset != len(raw) {
		return nil, "malformed"
	}
	return s, ""
}

func vdl1VecFind(entries []vdl1VecPair, id string) []byte {
	for _, entry := range entries {
		if entry.id == id {
			return entry.key
		}
	}
	return nil
}

func vdl1VecHas(entries []vdl1VecPair, pair vdl1VecPair) bool {
	for _, entry := range entries {
		if entry.id == pair.id && bytes.Equal(entry.key, pair.key) {
			return true
		}
	}
	return false
}

func vdl1VecSeen(history []vdl1VecPair, pair vdl1VecPair) bool {
	for _, seen := range history {
		if seen.id == pair.id || bytes.Equal(seen.key, pair.key) {
			return true
		}
	}
	return false
}

func vdl1VecEqual(a, b []vdl1VecPair) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].id != b[i].id || !bytes.Equal(a[i].key, b[i].key) {
			return false
		}
	}
	return true
}

func vdl1VecVerify(key []byte, s *vdl1VecStatement) string {
	if !ed25519.Verify(ed25519.PublicKey(key), vdl1VecSignedMessage(s.body, s.signerKind, s.signerID), s.signature) {
		return "signature"
	}
	return ""
}

// vdl1VecCheck is the design's "Who may sign what" table, in the order the
// vector's refusals assume: chain, rule, signature.
func vdl1VecCheck(prev, next *vdl1VecStatement, history []vdl1VecPair) string {
	if next.change == 1 || next.change == 6 {
		if prev != nil {
			return "chain"
		}
		if next.recovery != nil || next.signerKind != 1 {
			return "rule"
		}
		key := vdl1VecFind(next.entries, next.signerID)
		if key == nil || (next.change == 1 && len(next.entries) != 1) {
			return "rule"
		}
		return vdl1VecVerify(key, next)
	}
	if prev == nil {
		return "chain"
	}
	if next.account != prev.account || next.version != prev.version+1 || !bytes.Equal(next.prevHash, prev.listHash()) {
		return "chain"
	}
	ever := append(append([]vdl1VecPair{}, history...), prev.entries...)
	sameRecovery := bytes.Equal(next.recovery, prev.recovery)
	var key []byte
	switch {
	case next.change == 2 && next.signerKind == 1:
		key = vdl1VecFind(prev.entries, next.signerID)
		if key == nil || !bytes.Equal(vdl1VecFind(next.entries, next.signerID), key) || !sameRecovery {
			return "rule"
		}
		added := 0
		var extra vdl1VecPair
		for _, pair := range next.entries {
			if !vdl1VecHas(prev.entries, pair) {
				added++
				extra = pair
			}
		}
		for _, pair := range prev.entries {
			if !vdl1VecHas(next.entries, pair) {
				return "rule"
			}
		}
		if len(next.entries) != len(prev.entries)+1 || added != 1 || vdl1VecSeen(ever, extra) {
			return "rule"
		}
	case next.change == 3 && next.signerKind == 1:
		key = vdl1VecFind(prev.entries, next.signerID)
		if key == nil || len(next.entries) >= len(prev.entries) || !sameRecovery {
			return "rule"
		}
		for _, pair := range next.entries {
			if !vdl1VecHas(prev.entries, pair) {
				return "rule"
			}
		}
	case next.change == 4 && next.signerKind == 2:
		key = prev.recovery
		if key == nil || len(next.entries) != 1 || !sameRecovery || vdl1VecSeen(ever, next.entries[0]) {
			return "rule"
		}
	case next.change == 5 && next.signerKind == 1:
		key = vdl1VecFind(prev.entries, next.signerID)
		if key == nil || !vdl1VecEqual(next.entries, prev.entries) || sameRecovery {
			return "rule"
		}
	default:
		return "rule"
	}
	return vdl1VecVerify(key, next)
}

type vdl1VecVector struct {
	Labels struct {
		Signature string `json:"signature"`
		Hash      string `json:"hash"`
	} `json:"labels"`
	Inputs struct {
		AccountID string `json:"account_id"`
		Devices   []struct {
			DeviceID       string `json:"device_id"`
			SigningSeedHex string `json:"signing_seed_hex"`
			SigningKeyHex  string `json:"signing_key_hex"`
		} `json:"devices"`
		Recovery []struct {
			EntropyHex   string `json:"entropy_hex"`
			RKListPubHex string `json:"rk_list_pub_hex"`
			ListSeedHex  string `json:"list_seed_hex"`
		} `json:"recovery"`
	} `json:"inputs"`
	Outputs struct {
		Chains []struct {
			Name  string `json:"name"`
			Steps []struct {
				Version          uint64 `json:"version"`
				Change           byte   `json:"change"`
				StatementHex     string `json:"statement_hex"`
				BodyHex          string `json:"body_hex"`
				ListHashHex      string `json:"list_hash_hex"`
				SignerKind       byte   `json:"signer_kind"`
				SignerDeviceID   string `json:"signer_device_id"`
				SignedMessageHex string `json:"signed_message_hex"`
				SignatureHex     string `json:"signature_hex"`
			} `json:"steps"`
			ChainHex    string `json:"chain_hex"`
			ListIDHex   string `json:"list_id_hex"`
			HeadVersion uint64 `json:"head_version"`
		} `json:"chains"`
		Refused []struct {
			Name         string  `json:"name"`
			PrevHex      *string `json:"prev_hex"`
			StatementHex string  `json:"statement_hex"`
			History      []struct {
				DeviceID      string `json:"device_id"`
				SigningKeyHex string `json:"signing_key_hex"`
			} `json:"history"`
			Error string `json:"error"`
		} `json:"refused"`
		EdgeCases []struct {
			Name          string `json:"name"`
			PublicKeyHex  string `json:"public_key_hex"`
			MessageHex    string `json:"message_hex"`
			SignatureHex  string `json:"signature_hex"`
			ClientAccepts bool   `json:"client_accepts"`
			ServerAccepts bool   `json:"server_accepts"`
		} `json:"edge_cases"`
	} `json:"outputs"`
}

func loadVDL1Vector(t *testing.T) vdl1VecVector {
	t.Helper()
	// A missing file fails the test: the cross-implementation check must
	// never silently disappear.
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "l1-device-list-v1.json"))
	if err != nil {
		t.Fatalf("read L1 device-list vector: %v", err)
	}
	var vector vdl1VecVector
	// The vector carries fields this check does not read: decode loosely.
	if err := json.Unmarshal(raw, &vector); err != nil {
		t.Fatalf("parse L1 device-list vector: %v", err)
	}
	return vector
}

func vdl1VecHex(t *testing.T, name, value string) []byte {
	t.Helper()
	decoded, err := hex.DecodeString(value)
	if err != nil {
		t.Fatalf("vector field %s is not hex: %v", name, err)
	}
	return decoded
}

func TestVDL1VectorLabelsAndRecoveryKey(t *testing.T) {
	vector := loadVDL1Vector(t)
	if vector.Labels.Signature != vdl1VecSigLabel || vector.Labels.Hash != vdl1VecHashLabel {
		t.Fatalf("labels = %q, %q", vector.Labels.Signature, vector.Labels.Hash)
	}
	// The device-list recovery key: HKDF-Expand(PRK, "veritra-k0 device-list")
	// is an Ed25519 seed; PRK is the K0 extract of the entropy.
	for _, entry := range vector.Inputs.Recovery {
		entropy := vdl1VecHex(t, "entropy_hex", entry.EntropyHex)
		prk, err := hkdf.Extract(sha256.New, entropy, []byte("veritra-k0-v1"))
		if err != nil {
			t.Fatal(err)
		}
		seed, err := hkdf.Expand(sha256.New, prk, "veritra-k0 device-list", 32)
		if err != nil {
			t.Fatal(err)
		}
		if want := vdl1VecHex(t, "list_seed_hex", entry.ListSeedHex); !bytes.Equal(seed, want) {
			t.Fatalf("list seed = %x, vector has %x", seed, want)
		}
		public := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
		if want := vdl1VecHex(t, "rk_list_pub_hex", entry.RKListPubHex); !bytes.Equal(public, want) {
			t.Fatalf("rk_list_pub = %x, vector has %x", public, want)
		}
		if !validRecoveryAuthKey(public) {
			t.Fatal("the list recovery key is refused by the point check")
		}
	}
}

func TestVDL1VectorChains(t *testing.T) {
	vector := loadVDL1Vector(t)
	seeds := map[string][]byte{}
	for _, device := range vector.Inputs.Devices {
		seed := vdl1VecHex(t, "signing_seed_hex", device.SigningSeedHex)
		private := ed25519.NewKeyFromSeed(seed)
		if want := vdl1VecHex(t, "signing_key_hex", device.SigningKeyHex); !bytes.Equal(private.Public().(ed25519.PublicKey), want) {
			t.Fatalf("device %s key does not match its seed", device.DeviceID)
		}
		seeds[device.DeviceID] = seed
	}
	var recoverySeeds [][]byte
	for _, entry := range vector.Inputs.Recovery {
		recoverySeeds = append(recoverySeeds, vdl1VecHex(t, "list_seed_hex", entry.ListSeedHex))
	}
	if len(vector.Outputs.Chains) != 2 {
		t.Fatalf("%d chains, want 2", len(vector.Outputs.Chains))
	}
	for _, chain := range vector.Outputs.Chains {
		var previous *vdl1VecStatement
		var history []vdl1VecPair
		var first *vdl1VecStatement
		changes := map[byte]bool{}
		for _, step := range chain.Steps {
			raw := vdl1VecHex(t, "statement_hex", step.StatementHex)
			statement, problem := vdl1VecParse(raw)
			if problem != "" {
				t.Fatalf("%s v%d: parse: %s", chain.Name, step.Version, problem)
			}
			if problem := vdl1VecCheck(previous, statement, history); problem != "" {
				t.Fatalf("%s v%d refused: %s", chain.Name, step.Version, problem)
			}
			if statement.version != step.Version || statement.change != step.Change || statement.signerKind != step.SignerKind || statement.signerID != step.SignerDeviceID {
				t.Fatalf("%s v%d: header differs from the vector", chain.Name, step.Version)
			}
			if !bytes.Equal(statement.body, vdl1VecHex(t, "body_hex", step.BodyHex)) {
				t.Fatalf("%s v%d: body differs", chain.Name, step.Version)
			}
			if !bytes.Equal(statement.listHash(), vdl1VecHex(t, "list_hash_hex", step.ListHashHex)) {
				t.Fatalf("%s v%d: list hash differs", chain.Name, step.Version)
			}
			message := vdl1VecSignedMessage(statement.body, statement.signerKind, statement.signerID)
			if !bytes.Equal(message, vdl1VecHex(t, "signed_message_hex", step.SignedMessageHex)) {
				t.Fatalf("%s v%d: signed message differs", chain.Name, step.Version)
			}
			// Ed25519 is deterministic, so Go's own signature must be the
			// vector's byte for byte.
			var seed []byte
			if statement.signerKind == 1 {
				seed = seeds[statement.signerID]
			} else {
				for _, candidate := range recoverySeeds {
					if bytes.Equal(ed25519.NewKeyFromSeed(candidate).Public().(ed25519.PublicKey), previous.recovery) {
						seed = candidate
					}
				}
			}
			if seed == nil {
				t.Fatalf("%s v%d: no seed for the signer", chain.Name, step.Version)
			}
			signature := ed25519.Sign(ed25519.NewKeyFromSeed(seed), message)
			if !bytes.Equal(signature, vdl1VecHex(t, "signature_hex", step.SignatureHex)) {
				t.Fatalf("%s v%d: Go's signature differs from the vector's", chain.Name, step.Version)
			}
			for _, pair := range statement.entries {
				if !vdl1VecSeen(history, pair) {
					history = append(history, pair)
				}
			}
			changes[statement.change] = true
			if first == nil {
				first = statement
			}
			previous = statement
		}
		if previous.version != chain.HeadVersion {
			t.Fatalf("%s head = %d, vector has %d", chain.Name, previous.version, chain.HeadVersion)
		}
		if !bytes.Equal(first.listHash(), vdl1VecHex(t, "list_id_hex", chain.ListIDHex)) {
			t.Fatalf("%s: list identity differs", chain.Name)
		}
		// chain_hex is u16 count | count x (u16 len | statement).
		packed := vdl1VecHex(t, "chain_hex", chain.ChainHex)
		want := binary.BigEndian.AppendUint16(nil, uint16(len(chain.Steps)))
		for _, step := range chain.Steps {
			raw := vdl1VecHex(t, "statement_hex", step.StatementHex)
			want = binary.BigEndian.AppendUint16(want, uint16(len(raw)))
			want = append(want, raw...)
		}
		if !bytes.Equal(packed, want) {
			t.Fatalf("%s: chain_hex is not the packed statements", chain.Name)
		}
		if chain.Name[0] == 'A' {
			for _, change := range []byte{1, 2, 3, 4, 5} {
				if !changes[change] {
					t.Fatalf("chain A never uses change %d", change)
				}
			}
		} else if !changes[6] {
			t.Fatal("chain B never uses the migration genesis")
		}
	}
}

func TestVDL1VectorRefusals(t *testing.T) {
	vector := loadVDL1Vector(t)
	if len(vector.Outputs.Refused) < 60 {
		t.Fatalf("%d refusals: the vector must keep its coverage", len(vector.Outputs.Refused))
	}
	for _, refused := range vector.Outputs.Refused {
		var history []vdl1VecPair
		for _, pair := range refused.History {
			history = append(history, vdl1VecPair{pair.DeviceID, vdl1VecHex(t, "history key", pair.SigningKeyHex)})
		}
		var previous *vdl1VecStatement
		if refused.PrevHex != nil {
			var problem string
			previous, problem = vdl1VecParse(vdl1VecHex(t, "prev_hex", *refused.PrevHex))
			if problem != "" {
				t.Fatalf("%s: the previous version does not parse: %s", refused.Name, problem)
			}
		}
		got := ""
		statement, problem := vdl1VecParse(vdl1VecHex(t, "statement_hex", refused.StatementHex))
		if problem != "" {
			got = problem
		} else {
			got = vdl1VecCheck(previous, statement, history)
		}
		if got != refused.Error {
			t.Errorf("%s: refused as %q, the vector says %q", refused.Name, got, refused.Error)
		}
	}
}

// TestVDL1VectorEdgeCases pins the difference between the clients' strict
// verifier and Go's crypto/ed25519 (the server's defence in depth): the
// server must never refuse what an honest client signs, and the two columns
// say where Go is the laxer one.
func TestVDL1VectorEdgeCases(t *testing.T) {
	vector := loadVDL1Vector(t)
	if len(vector.Outputs.EdgeCases) < 4 {
		t.Fatal("the edge cases are missing")
	}
	for _, edge := range vector.Outputs.EdgeCases {
		accepted := ed25519.Verify(
			ed25519.PublicKey(vdl1VecHex(t, "public_key_hex", edge.PublicKeyHex)),
			vdl1VecHex(t, "message_hex", edge.MessageHex),
			vdl1VecHex(t, "signature_hex", edge.SignatureHex),
		)
		if accepted != edge.ServerAccepts {
			t.Errorf("%s: Go accepts = %v, the vector says %v", edge.Name, accepted, edge.ServerAccepts)
		}
		if edge.ClientAccepts && !edge.ServerAccepts {
			t.Errorf("%s: a client accepts what the server would refuse", edge.Name)
		}
	}
}
