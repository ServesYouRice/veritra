package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

// A history upload cut off mid-body (a dropped connection, a killed app)
// commits nothing, gives its quota back, queues its partial blob for deletion
// and leaves no intent behind, so the source's retry of the same copy is
// accepted as a first upload (K2).
func TestHistoryTransferHTTPPartialUploadLeavesNothingAndRetrySucceeds(t *testing.T) {
	for _, cut := range []string{"inside metadata", "inside ciphertext", "before closing boundary"} {
		t.Run(cut, func(t *testing.T) {
			f := newV3APIFixture(t)
			f.approve(t)
			data := bytes.Repeat([]byte("encrypted-history"), 4000)
			input := historyHTTPInput(f, data)
			body, ctype := historyMultipart(t, input, data, false)
			start := bytes.Index(body, data)
			if start < 0 {
				t.Fatal("ciphertext not found in body")
			}
			var at int
			switch cut {
			case "inside metadata":
				at = bytes.Index(body, []byte(`"transfer_id"`)) + 4
			case "inside ciphertext":
				at = start + len(data)/2
			case "before closing boundary":
				at = start + len(data)
			}
			var accountID string
			if err := f.db.QueryRow(`SELECT account_id FROM device_links_v3 WHERE id=?`, f.link.ID).Scan(&accountID); err != nil {
				t.Fatal(err)
			}
			usage := func() int64 {
				var n int64
				if err := f.db.QueryRow(`SELECT COALESCE((SELECT size_bytes FROM blob_usage_accounts WHERE account_id=?),0)`, accountID).Scan(&n); err != nil {
					t.Fatal(err)
				}
				return n
			}
			count := func(query string) int {
				var n int
				if err := f.db.QueryRow(query, f.link.ID).Scan(&n); err != nil {
					t.Fatal(err)
				}
				return n
			}
			queued := func() int {
				var n int
				if err := f.db.QueryRow(`SELECT COUNT(*) FROM blob_deletion_queue`).Scan(&n); err != nil {
					t.Fatal(err)
				}
				return n
			}
			before, queuedBefore := usage(), queued()
			base := v3Base + "/" + f.link.ID + "/history"

			w := historyRequest(t, f, http.MethodPost, base, f.ownerToken, body[:at], map[string]string{"Content-Type": ctype})
			if w.Code < 400 {
				t.Fatalf("partial upload accepted %d %s", w.Code, w.Body.String())
			}
			if n := count(`SELECT COUNT(*) FROM device_history_transfers WHERE link_id=?`); n != 0 {
				t.Fatalf("partial upload committed %d transfers", n)
			}
			if n := count(`SELECT COUNT(*) FROM device_history_upload_intents WHERE link_id=?`); n != 0 {
				t.Fatalf("partial upload left %d intents (a retry would be refused)", n)
			}
			if got := usage(); got != before {
				t.Fatalf("partial upload kept quota: %d, was %d", got, before)
			}
			wantQueued := queuedBefore + 1
			if cut == "inside metadata" {
				// Refused before any blob was prepared.
				wantQueued = queuedBefore
			}
			if got := queued(); got != wantQueued {
				t.Fatalf("deletion queue %d, want %d", got, wantQueued)
			}
			// The recipient finds nothing to download.
			headers := map[string]string{"X-Veritra-Claim-Token": f.claimToken}
			if w := historyRequest(t, f, http.MethodGet, base+"/content", "", nil, headers); w.Code == http.StatusOK {
				t.Fatal("content served after a partial upload")
			}

			// The same copy again, whole: a first upload, not a conflict.
			w = historyRequest(t, f, http.MethodPost, base, f.ownerToken, body, map[string]string{"Content-Type": ctype})
			if w.Code != http.StatusCreated {
				t.Fatalf("retry after partial upload %d %s", w.Code, w.Body.String())
			}
			var created struct {
				Transfer struct {
					CiphertextSHA256 string `json:"ciphertext_sha256"`
					SizeBytes        int64  `json:"size_bytes"`
				} `json:"transfer"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
				t.Fatal(err)
			}
			if created.Transfer.CiphertextSHA256 != input.CiphertextSHA256 || created.Transfer.SizeBytes != input.SizeBytes {
				t.Fatalf("retry receipt %+v", created.Transfer)
			}
			if got := usage(); got != before+input.SizeBytes {
				t.Fatalf("quota after retry %d, want %d", got, before+input.SizeBytes)
			}
			var key string
			if err := f.db.QueryRow(`SELECT storage_key FROM device_history_transfers WHERE link_id=?`, f.link.ID).Scan(&key); err != nil {
				t.Fatal(err)
			}
			var stale int
			if err := f.db.QueryRow(`SELECT COUNT(*) FROM blob_deletion_queue WHERE storage_key=?`, key).Scan(&stale); err != nil || stale != 0 {
				t.Fatalf("the committed copy is queued for deletion %d %v", stale, err)
			}
			w = historyRequest(t, f, http.MethodGet, base+"/content", "", nil, headers)
			if w.Code != http.StatusOK || !bytes.Equal(w.Body.Bytes(), data) {
				t.Fatalf("content after retry %d len %d", w.Code, w.Body.Len())
			}
		})
	}
}
