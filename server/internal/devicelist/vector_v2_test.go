package devicelist

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// These tests run the production parse and check over the format-2 vector of
// L2-3, testing/vectors/l1-device-list-v2.json (made by the crypto core,
// crypto/rust/src/l1_v2_tests.rs): franking keys set by genesis, change 7 and
// recovery and kept by every other change, a format-1 chain moved to format
// 2, every single-fault refusal with its class, and a chain that gives a
// removed device's key to another device (refused through
// History.SeenFrankKeyElsewhere, as the store fills it).

type vectorV2File struct {
	Inputs struct {
		AccountID string `json:"account_id"`
	} `json:"inputs"`
	Outputs struct {
		Chains []struct {
			Name       string   `json:"name"`
			Statements []string `json:"statements"`
			Formats    []int    `json:"formats"`
			Pairs      []struct {
				DeviceID       string  `json:"device_id"`
				RemovedVersion uint64  `json:"removed_version"`
				FrankKey       *string `json:"frank_key"`
			} `json:"pairs"`
		} `json:"chains"`
		Refused []struct {
			Name    string  `json:"name"`
			Prev    *string `json:"prev"`
			Next    string  `json:"next"`
			History []struct {
				DeviceID   string `json:"device_id"`
				SigningKey string `json:"signing_key"`
			} `json:"history"`
			Error string `json:"error"`
		} `json:"refused"`
		RefusedChains []struct {
			Name       string   `json:"name"`
			Statements []string `json:"statements"`
		} `json:"refused_chains"`
	} `json:"outputs"`
}

func loadVectorV2(t *testing.T) vectorV2File {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "l1-device-list-v2.json"))
	if err != nil {
		t.Fatal(err)
	}
	var vector vectorV2File
	if err := json.Unmarshal(raw, &vector); err != nil {
		t.Fatalf("parse vector: %v", err)
	}
	return vector
}

// chainHistory is what the store builds from the versions so far.
type chainHistory struct {
	devices, keys map[string]bool
	frankOwners   map[string]string
}

func newChainHistory() *chainHistory {
	return &chainHistory{devices: map[string]bool{}, keys: map[string]bool{}, frankOwners: map[string]string{}}
}

func (h *chainHistory) add(body Body) {
	for _, entry := range body.Entries {
		h.devices[entry.DeviceID] = true
		h.keys[string(entry.SigningKey)] = true
	}
	for _, frank := range body.FrankKeys {
		h.frankOwners[string(frank.Key)] = frank.DeviceID
	}
}

func (h *chainHistory) history(head *Statement) History {
	return History{
		Head:       head,
		SeenDevice: func(id string) bool { return h.devices[id] },
		SeenKey:    func(k []byte) bool { return h.keys[string(k)] },
		SeenFrankKeyElsewhere: func(k []byte, id string) bool {
			owner, seen := h.frankOwners[string(k)]
			return seen && owner != id
		},
	}
}

// runChain checks every statement in order and returns the first error.
func runChain(t *testing.T, account string, statements []string) (*Statement, error) {
	t.Helper()
	seen := newChainHistory()
	var head *Statement
	for i, value := range statements {
		statement, err := Parse(unhex(t, "statement", value))
		if err != nil {
			return head, err
		}
		if err := CheckStep(account, seen.history(head), statement); err != nil {
			return head, err
		}
		if got := Encode(statement.Body, statement.SignerKind, statement.SignerDeviceID, statement.Signature); !bytes.Equal(got, statement.Raw) {
			t.Fatalf("statement %d does not re-encode to its bytes", i+1)
		}
		seen.add(statement.Body)
		parsed := statement
		head = &parsed
	}
	return head, nil
}

func TestVectorV2ChainsAreAccepted(t *testing.T) {
	vector := loadVectorV2(t)
	if len(vector.Outputs.Chains) < 3 {
		t.Fatal("the vector must keep its chains")
	}
	for _, chain := range vector.Outputs.Chains {
		head, err := runChain(t, vector.Inputs.AccountID, chain.Statements)
		if err != nil {
			t.Fatalf("%s refused: %v", chain.Name, err)
		}
		for i, value := range chain.Statements {
			if format := int(unhex(t, "statement", value)[4]); format != chain.Formats[i] {
				t.Fatalf("%s v%d: format %d, vector says %d", chain.Name, i+1, format, chain.Formats[i])
			}
		}
		// The head lists exactly the keys the vector gives its listed devices.
		for _, pair := range chain.Pairs {
			key, has := head.Body.FrankKeyOf(pair.DeviceID)
			if pair.RemovedVersion != 0 {
				if has {
					t.Fatalf("%s: removed %s still has a key", chain.Name, pair.DeviceID)
				}
				continue
			}
			if has != (pair.FrankKey != nil) || (has && hex.EncodeToString(key) != *pair.FrankKey) {
				t.Fatalf("%s: %s key differs", chain.Name, pair.DeviceID)
			}
		}
	}
}

func TestVectorV2RefusalsKeepTheirClass(t *testing.T) {
	vector := loadVectorV2(t)
	if len(vector.Outputs.Refused) < 30 {
		t.Fatal("the vector must keep its coverage")
	}
	for _, refused := range vector.Outputs.Refused {
		next, err := Parse(unhex(t, "next", refused.Next))
		if err != nil {
			if got := class(err); got != refused.Error {
				t.Fatalf("%s: %s, vector says %s", refused.Name, got, refused.Error)
			}
			continue
		}
		seen := newChainHistory()
		var head *Statement
		for _, pair := range refused.History {
			seen.devices[pair.DeviceID] = true
			seen.keys[string(unhex(t, "key", pair.SigningKey))] = true
		}
		if refused.Prev != nil {
			prev, err := Parse(unhex(t, "prev", *refused.Prev))
			if err != nil {
				t.Fatalf("%s: prev: %v", refused.Name, err)
			}
			seen.add(prev.Body)
			head = &prev
		}
		err = CheckStep(vector.Inputs.AccountID, seen.history(head), next)
		if got := class(err); got != refused.Error {
			t.Fatalf("%s: %q (%v), vector says %s", refused.Name, got, err, refused.Error)
		}
	}
}

func TestVectorV2ReusedFrankKeyIsRefused(t *testing.T) {
	vector := loadVectorV2(t)
	if len(vector.Outputs.RefusedChains) == 0 {
		t.Fatal("the vector has no refused chains")
	}
	for _, chain := range vector.Outputs.RefusedChains {
		_, err := runChain(t, vector.Inputs.AccountID, chain.Statements)
		if err != ErrBadFrankKey {
			t.Fatalf("%s: %v, want ErrBadFrankKey", chain.Name, err)
		}
	}
}

func TestValidFrankKey(t *testing.T) {
	for _, low := range lowOrderFrankKeys {
		if ValidFrankKey(low) {
			t.Fatalf("low-order %x accepted", low)
		}
	}
	p := append([]byte(nil), fieldPrime...)
	if ValidFrankKey(p) {
		t.Fatal("p accepted")
	}
	p[0]++ // p+1, the non-canonical 1
	if ValidFrankKey(p) {
		t.Fatal("p+1 accepted")
	}
	nine := make([]byte, 32)
	nine[0] = 9
	if !ValidFrankKey(nine) || ValidFrankKey(nine[:31]) {
		t.Fatal("base point refused or short key accepted")
	}
	nine[31] |= 0x80
	if ValidFrankKey(nine) {
		t.Fatal("bit 255 accepted")
	}
}
