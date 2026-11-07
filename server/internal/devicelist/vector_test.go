package devicelist

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// These tests run the production parse and check over the shared vector of
// L1-1 (crypto core), testing/vectors/l1-device-list-v1.json: both valid chains
// step by step, every single-fault refusal with the class the vector names
// (malformed, chain, rule, signature), and the Ed25519 edge cases (the server
// may be laxer than a client, never stricter).
//
// The vector belongs to L1-1. Until that branch is merged the file is absent
// and these tests skip; once it is present they must pass.

type vectorFile struct {
	Outputs struct {
		Chains []struct {
			Name  string `json:"name"`
			Steps []struct {
				Version          uint64 `json:"version"`
				StatementHex     string `json:"statement_hex"`
				BodyHex          string `json:"body_hex"`
				ListHashHex      string `json:"list_hash_hex"`
				SignedMessageHex string `json:"signed_message_hex"`
			} `json:"steps"`
			ListIDHex string `json:"list_id_hex"`
		} `json:"chains"`
		Refused []struct {
			Name              string  `json:"name"`
			ExpectedAccountID string  `json:"expected_account_id"`
			PrevHex           *string `json:"prev_hex"`
			StatementHex      string  `json:"statement_hex"`
			History           []struct {
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

func loadVector(t *testing.T) vectorFile {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "l1-device-list-v1.json"))
	if errors.Is(err, os.ErrNotExist) {
		t.Skip("testing/vectors/l1-device-list-v1.json is not in this tree yet (it ships with L1-1)")
	}
	if err != nil {
		t.Fatal(err)
	}
	var vector vectorFile
	if err := json.Unmarshal(raw, &vector); err != nil {
		t.Fatalf("parse vector: %v", err)
	}
	return vector
}

func unhex(t *testing.T, name, value string) []byte {
	t.Helper()
	out, err := hex.DecodeString(value)
	if err != nil {
		t.Fatalf("%s is not hex: %v", name, err)
	}
	return out
}

// class names the failure the way the vector does.
func class(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, ErrMalformed):
		return "malformed"
	case errors.Is(err, ErrWrongAccount), errors.Is(err, ErrVersionGap), errors.Is(err, ErrPrevHash), errors.Is(err, ErrNotGenesis):
		return "chain"
	case errors.Is(err, ErrBadSignature):
		return "signature"
	default:
		return "rule"
	}
}

func TestVectorChainsAreAcceptedStepByStep(t *testing.T) {
	vector := loadVector(t)
	if len(vector.Outputs.Chains) == 0 {
		t.Fatal("the vector has no chains")
	}
	for _, chain := range vector.Outputs.Chains {
		devices, keys := map[string]bool{}, map[string]bool{}
		var head *Statement
		var first Statement
		for _, step := range chain.Steps {
			raw := unhex(t, "statement_hex", step.StatementHex)
			statement, err := Parse(raw)
			if err != nil {
				t.Fatalf("%s v%d: parse: %v", chain.Name, step.Version, err)
			}
			history := History{Head: head, SeenDevice: func(id string) bool { return devices[id] }, SeenKey: func(k []byte) bool { return keys[string(k)] }}
			if err := CheckStep(statement.Body.AccountID, history, statement); err != nil {
				t.Fatalf("%s v%d refused: %v", chain.Name, step.Version, err)
			}
			if !bytes.Equal(statement.BodyBytes, unhex(t, "body_hex", step.BodyHex)) {
				t.Fatalf("%s v%d: body differs", chain.Name, step.Version)
			}
			if !bytes.Equal(statement.Hash(), unhex(t, "list_hash_hex", step.ListHashHex)) {
				t.Fatalf("%s v%d: list_hash differs", chain.Name, step.Version)
			}
			if !bytes.Equal(statement.signedMessage(), unhex(t, "signed_message_hex", step.SignedMessageHex)) {
				t.Fatalf("%s v%d: signed message differs", chain.Name, step.Version)
			}
			for _, entry := range statement.Body.Entries {
				devices[entry.DeviceID] = true
				keys[string(entry.SigningKey)] = true
			}
			if head == nil {
				first = statement
			}
			head = &statement
		}
		if !bytes.Equal(first.Hash(), unhex(t, "list_id_hex", chain.ListIDHex)) {
			t.Fatalf("%s: list identity differs", chain.Name)
		}
	}
}

func TestVectorRefusalsAreRefusedInTheirClass(t *testing.T) {
	vector := loadVector(t)
	if len(vector.Outputs.Refused) < 60 {
		t.Fatalf("%d refusals: the vector must keep its coverage", len(vector.Outputs.Refused))
	}
	for _, refused := range vector.Outputs.Refused {
		devices, keys := map[string]bool{}, map[string]bool{}
		for _, pair := range refused.History {
			devices[pair.DeviceID] = true
			keys[string(unhex(t, "history key", pair.SigningKeyHex))] = true
		}
		var head *Statement
		// The account the caller asks about (B2): a valid chain of another
		// account must be refused, so the vector names it and the check
		// never takes it from the statement or its predecessor.
		account := refused.ExpectedAccountID
		if refused.PrevHex != nil {
			prev, err := Parse(unhex(t, "prev_hex", *refused.PrevHex))
			if err != nil {
				t.Fatalf("%s: the previous version does not parse: %v", refused.Name, err)
			}
			head = &prev
			for _, entry := range prev.Body.Entries {
				devices[entry.DeviceID] = true
				keys[string(entry.SigningKey)] = true
			}
		}
		var err error
		statement, parseErr := Parse(unhex(t, "statement_hex", refused.StatementHex))
		if parseErr != nil {
			err = parseErr
		} else {
			history := History{Head: head, SeenDevice: func(id string) bool { return devices[id] }, SeenKey: func(k []byte) bool { return keys[string(k)] }}
			err = CheckStep(account, history, statement)
		}
		if got := class(err); got != refused.Error {
			t.Errorf("%s: refused as %q (%v), the vector says %q", refused.Name, got, err, refused.Error)
		}
	}
}

func TestVectorEdgeCasesTheServerNeverRefusesWhatAClientAccepts(t *testing.T) {
	vector := loadVector(t)
	if len(vector.Outputs.EdgeCases) < 4 {
		t.Fatal("the edge cases are missing")
	}
	for _, edge := range vector.Outputs.EdgeCases {
		accepted := ed25519.Verify(ed25519.PublicKey(unhex(t, "public_key_hex", edge.PublicKeyHex)), unhex(t, "message_hex", edge.MessageHex), unhex(t, "signature_hex", edge.SignatureHex))
		if accepted != edge.ServerAccepts {
			t.Errorf("%s: Go accepts = %v, the vector says %v", edge.Name, accepted, edge.ServerAccepts)
		}
		if edge.ClientAccepts && !accepted {
			t.Errorf("%s: a client accepts what the server refuses", edge.Name)
		}
	}
}
