package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The C7 body size rule against the step-2 vector's history_sync lengths and
// the channel-body bounds (docs/designs/C7-channel-history.md, "Server").
func TestC7BodySizeRule(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "c7-primitives-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var vector struct {
		Outputs struct {
			SealedBody string `json:"sealed_body_hex"`
			Lengths    []struct {
				Channels        int `json:"channels"`
				HistorySyncBody int `json:"history_sync_body"`
			} `json:"lengths"`
		} `json:"outputs"`
	}
	if err := json.Unmarshal(raw, &vector); err != nil {
		t.Fatal(err)
	}
	if len(vector.Outputs.Lengths) == 0 {
		t.Fatal("vector has no lengths")
	}
	// The crypto library seals up to 508 channels; the server caps N at the
	// C3 channel limit (c7MaxSyncChannels, design: "N from 1 to C3's limit"),
	// so vector entries above it must be refused by both rules.
	sawOverCap := false
	for _, l := range vector.Outputs.Lengths {
		if l.Channels > c7MaxSyncChannels {
			sawOverCap = true
			if C7BodySizeValid(l.HistorySyncBody, true) || c7SyncBodySize(l.HistorySyncBody) {
				t.Fatalf("history_sync body for %d channels (over the %d cap) accepted", l.Channels, c7MaxSyncChannels)
			}
			continue
		}
		if !C7BodySizeValid(l.HistorySyncBody, true) {
			t.Fatalf("history_sync body for %d channels refused at group level", l.Channels)
		}
		if !c7SyncBodySize(l.HistorySyncBody) || c7SyncBodySize(l.HistorySyncBody+1) {
			t.Fatalf("history_sync size rule wrong for %d channels", l.Channels)
		}
	}
	if !sawOverCap {
		t.Fatalf("vector has no entry above the %d-channel cap", c7MaxSyncChannels)
	}
	// The vector seals a short 32-byte plaintext (156 bytes): the framing is
	// 124 bytes, as the rule assumes; real bodies pad VAP1 to 256-byte blocks.
	if body := len(vector.Outputs.SealedBody) / 2; body-c7BodyFraming != 32 {
		t.Fatalf("vector sealed body of %d bytes: framing is not %d", body, c7BodyFraming)
	}
	for _, n := range []int{124 + 256, 124 + 512, 65660} {
		if !C7BodySizeValid(n, false) {
			t.Fatalf("channel body %d refused", n)
		}
	}
	for _, n := range []int{0, 124, 124 + 255, 124 + 257, 65660 + 256} {
		if C7BodySizeValid(n, false) {
			t.Fatalf("channel body %d accepted", n)
		}
	}
	// A private group's history_sync (one channel) is exempt from the posting
	// checks; a channel-sized body never is.
	if !c7SyncOnlyBodySize(1592) || c7SyncOnlyBodySize(124+512) {
		t.Fatal("sync-only size rule")
	}
	// P(500) + 124 + 700*500: the largest history_sync body.
	if !C7BodySizeValid(64512+124+350000, true) || C7BodySizeValid(64512+124+350000, false) {
		t.Fatal("largest history_sync body")
	}
}
