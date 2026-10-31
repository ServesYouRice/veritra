package httpapi_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/url"
	"testing"
)

// The account export lists the account's push subscriptions but must never
// carry a subscription's Web Push auth secret. The live Dart contract test
// cannot observe this, because its server offers no push provider, so this
// test seeds a subscription directly and pages through the whole export.
func TestAccountExportOmitsPushSubscriptionAuthSecret(t *testing.T) {
	application, handler, token, dbPath := newTestAppWithOwner(t)
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	var accountID, deviceID string
	if err := db.QueryRow(`SELECT account_id, id FROM devices WHERE revoked_at IS NULL ORDER BY created_at LIMIT 1`).Scan(&accountID, &deviceID); err != nil {
		t.Fatalf("read owner device: %v", err)
	}

	random := make([]byte, 12)
	if _, err := rand.Read(random); err != nil {
		t.Fatal(err)
	}
	sentinel := "EXPORT_SENTINEL_" + hex.EncodeToString(random)
	endpoint := "https://push.example.test/export-" + hex.EncodeToString(random)
	if _, err := application.Store.CreatePushSubscription(context.Background(), accountID, deviceID,
		"webpush", endpoint, "export-public-key", sentinel); err != nil {
		t.Fatalf("seed push subscription: %v", err)
	}

	var bodies [][]byte
	query := "limit=1"
	for page := 0; ; page++ {
		if page > 50 {
			t.Fatal("export did not finish paging")
		}
		status, body := doJSON(t, handler, http.MethodGet, "/api/v1/account/export?"+query, token, nil)
		if status != http.StatusOK {
			t.Fatalf("export status=%d", status)
		}
		bodies = append(bodies, body)
		var decoded struct {
			NextBefore string `json:"next_before"`
		}
		if err := json.Unmarshal(body, &decoded); err != nil {
			t.Fatalf("decode export: %v", err)
		}
		if decoded.NextBefore == "" {
			break
		}
		query = "limit=1&before=" + url.QueryEscape(decoded.NextBefore)
	}
	all := bytes.Join(bodies, []byte("\n"))

	// The subscription is in the export, so the absence below is load-bearing.
	if !bytes.Contains(all, []byte(endpoint)) {
		t.Fatal("export does not list the seeded push subscription")
	}
	forms := []string{
		sentinel,
		base64.StdEncoding.EncodeToString([]byte(sentinel)),
		base64.RawStdEncoding.EncodeToString([]byte(sentinel)),
		base64.URLEncoding.EncodeToString([]byte(sentinel)),
		base64.RawURLEncoding.EncodeToString([]byte(sentinel)),
		hex.EncodeToString([]byte(sentinel)),
		string(bytes.ToUpper([]byte(hex.EncodeToString([]byte(sentinel))))),
		"auth_secret",
	}
	for _, form := range forms {
		if bytes.Contains(all, []byte(form)) {
			t.Fatalf("account export carries the push auth secret (form %q)", form)
		}
	}
}
