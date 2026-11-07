package franking

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestReportAADVector(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "testing", "vectors", "c6-report-aad-v2.json"))
	if err != nil {
		t.Fatal(err)
	}
	var vector struct {
		Cases []struct {
			Name              string `json:"name"`
			InboxKind         string `json:"inbox_kind"`
			InboxID           string `json:"inbox_id"`
			RecipientKeyHex   string `json:"recipient_key_hex"`
			ConversationID    string `json:"conversation_id"`
			ReportID          string `json:"report_id"`
			ReporterAccountID string `json:"reporter_account_id"`
			AADHex            string `json:"aad_hex"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &vector); err != nil || len(vector.Cases) < 2 {
		t.Fatalf("vector: %v (%d cases)", err, len(vector.Cases))
	}
	for _, c := range vector.Cases {
		key, err := hex.DecodeString(c.RecipientKeyHex)
		if err != nil {
			t.Fatal(err)
		}
		got, err := ReportAAD(ReportRoute{InboxKind: c.InboxKind, InboxID: c.InboxID, RecipientKey: key, ConversationID: c.ConversationID, ReportID: c.ReportID, ReporterAccountID: c.ReporterAccountID})
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		if hex.EncodeToString(got) != c.AADHex {
			t.Errorf("%s: aad %x, want %s", c.Name, got, c.AADHex)
		}
		if len(got) > 1024 {
			t.Errorf("%s: aad is %d bytes, over the Rust core's limit", c.Name, len(got))
		}
	}
}

func TestReportAADBindsEveryField(t *testing.T) {
	base := ReportRoute{InboxKind: InboxInstanceOwner, InboxID: "acct_owner", RecipientKey: bytes.Repeat([]byte{1}, 32), ConversationID: "conv", ReportID: "rpt", ReporterAccountID: "acct"}
	want, err := ReportAAD(base)
	if err != nil {
		t.Fatal(err)
	}
	other := bytes.Repeat([]byte{2}, 32)
	changed := map[string]ReportRoute{}
	for name, mutate := range map[string]func(*ReportRoute){
		"kind":     func(r *ReportRoute) { r.InboxKind = InboxCommunity },
		"inbox":    func(r *ReportRoute) { r.InboxID = "other" },
		"key":      func(r *ReportRoute) { r.RecipientKey = other },
		"conv":     func(r *ReportRoute) { r.ConversationID = "conw" },
		"report":   func(r *ReportRoute) { r.ReportID = "rpu" },
		"reporter": func(r *ReportRoute) { r.ReporterAccountID = "acsu" },
		// A boundary shift between neighbouring fields must not collide.
		"shift": func(r *ReportRoute) { r.ConversationID, r.ReportID = "convr", "pt" },
	} {
		route := base
		mutate(&route)
		changed[name] = route
	}
	for name, route := range changed {
		got, err := ReportAAD(route)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if bytes.Equal(got, want) {
			t.Errorf("changing %s leaves the aad unchanged", name)
		}
	}
}

func TestReportAADRefusesBadInput(t *testing.T) {
	good := ReportRoute{InboxKind: InboxCommunity, InboxID: "c", RecipientKey: bytes.Repeat([]byte{1}, 32), ConversationID: "a", ReportID: "b", ReporterAccountID: "d"}
	for name, mutate := range map[string]func(*ReportRoute){
		"kind":      func(r *ReportRoute) { r.InboxKind = "moderators" },
		"short key": func(r *ReportRoute) { r.RecipientKey = r.RecipientKey[:31] },
		"empty id":  func(r *ReportRoute) { r.ReportID = "" },
		"long id":   func(r *ReportRoute) { r.ReporterAccountID = string(bytes.Repeat([]byte{'x'}, MaxIDSize+1)) },
	} {
		route := good
		mutate(&route)
		if _, err := ReportAAD(route); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}
