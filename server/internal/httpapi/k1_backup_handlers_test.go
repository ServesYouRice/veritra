package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// postK1 uploads body as a K1 copy with the given metadata document.
func (f *recoveryFixture) postK1(token, metadata string, body []byte, extra map[string]string) (int, []byte) {
	f.t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/backups", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("X-Private-Messenger-Encrypted", "1")
	req.Header.Set("X-Key-Derivation-Metadata", metadata)
	for key, value := range extra {
		req.Header.Set(key, value)
	}
	f.source++
	req.RemoteAddr = fmt.Sprintf("198.51.%d.%d:5000", f.source/250, f.source%250+1)
	rec := httptest.NewRecorder()
	f.handler.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

func k1Metadata(rkID []byte, counter int64) string {
	return fmt.Sprintf(`{"kind":1,"rk_id":%q,"counter":%d}`, base64.StdEncoding.EncodeToString(rkID), counter)
}

func (f *recoveryFixture) accountRKID() []byte {
	f.t.Helper()
	var rkID []byte
	if err := f.db.QueryRow(`SELECT rk_id FROM account_recovery_keys WHERE account_id = ?`, f.ownerAccountID).Scan(&rkID); err != nil {
		f.t.Fatal(err)
	}
	return rkID
}

func TestK1UploadNeedsThePublicOrigin(t *testing.T) {
	f := newRecoveryFixture(t, "")
	status, body := f.postK1(f.ownerToken, k1Metadata(make([]byte, 16), 1), []byte("sealed"), nil)
	if status != http.StatusServiceUnavailable || !bytes.Contains(body, []byte("recovery_not_configured")) {
		t.Fatalf("K1 upload without an origin: %d %s", status, body)
	}
	if n := f.count(`SELECT COUNT(*) FROM backup_blobs`); n != 0 {
		t.Fatalf("rows = %d", n)
	}
}

func TestK1UploadRoutesAndRefusals(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.setRK(f.ownerToken)
	rkID := f.accountRKID()
	other := bytes.Repeat([]byte{0xEE}, 16)

	for name, tc := range map[string]struct {
		metadata string
		extra    map[string]string
		status   int
		code     string
	}{
		"recovery token":  {k1Metadata(rkID, 1), map[string]string{"X-Recovery-Token": base64.RawURLEncoding.EncodeToString(make([]byte, 32))}, http.StatusBadRequest, "recovery_token_not_allowed"},
		"extra key":       {`{"kind":1,"rk_id":"` + base64.StdEncoding.EncodeToString(rkID) + `","counter":1,"x":1}`, nil, http.StatusBadRequest, "invalid_key_derivation_metadata"},
		"wrong kind":      {`{"kind":2,"rk_id":"` + base64.StdEncoding.EncodeToString(rkID) + `","counter":1}`, nil, http.StatusBadRequest, "invalid_key_derivation_metadata"},
		"short rk_id":     {k1Metadata(rkID[:8], 1), nil, http.StatusBadRequest, "invalid_key_derivation_metadata"},
		"zero counter":    {k1Metadata(rkID, 0), nil, http.StatusBadRequest, "invalid_key_derivation_metadata"},
		"other rk_id":     {k1Metadata(other, 1), nil, http.StatusConflict, "recovery_key_changed"},
		"case variant":    {`{"KIND":1,"kind":1,"rk_id":"` + base64.StdEncoding.EncodeToString(rkID) + `","counter":1}`, nil, http.StatusBadRequest, "invalid_key_derivation_metadata"},
		"string counter":  {`{"kind":1,"rk_id":"` + base64.StdEncoding.EncodeToString(rkID) + `","counter":"1"}`, nil, http.StatusBadRequest, "invalid_key_derivation_metadata"},
		"unpadded base64": {`{"kind":1,"rk_id":"` + base64.RawStdEncoding.EncodeToString(rkID) + `","counter":1}`, nil, http.StatusBadRequest, "invalid_key_derivation_metadata"},
	} {
		status, body := f.postK1(f.ownerToken, tc.metadata, []byte("sealed"), tc.extra)
		if status != tc.status || !bytes.Contains(body, []byte(tc.code)) {
			t.Fatalf("%s: %d %s, want %d %s", name, status, body, tc.status, tc.code)
		}
	}
	if n := f.count(`SELECT COUNT(*) FROM backup_blobs`); n != 0 {
		t.Fatalf("refused uploads left %d rows", n)
	}
	status, body := f.postK1(f.ownerToken, k1Metadata(rkID, 3), []byte("sealed copy one"), nil)
	if status != http.StatusCreated {
		t.Fatalf("first copy: %d %s", status, body)
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(body, &created); err != nil || created.ID == "" {
		t.Fatalf("created = %s", body)
	}
	status, body = f.postK1(f.ownerToken, k1Metadata(rkID, 3), []byte("replay"), nil)
	if status != http.StatusConflict || !bytes.Contains(body, []byte("backup_counter_stale")) {
		t.Fatalf("stale counter: %d %s", status, body)
	}
	// Every refused body is removed from the blob store (only one blob is
	// stored, and nothing waits in the deletion queue).
	if n := f.count(`SELECT COUNT(*) FROM blob_deletion_queue`); n != 0 {
		t.Fatalf("deletion queue = %d", n)
	}
	if status, body = f.postK1(f.ownerToken, k1Metadata(rkID, 4), []byte("sealed copy two"), nil); status != http.StatusCreated {
		t.Fatalf("second copy: %d %s", status, body)
	}
	// The list carries the K1 fields; the replaced copy is still served.
	status, body = f.do(http.MethodGet, "/api/v1/backups", f.ownerToken, nil, nil)
	var list struct {
		Backups []struct {
			ID         string `json:"id"`
			Kind       int    `json:"kind"`
			RKID       []byte `json:"rk_id"`
			Counter    int64  `json:"counter"`
			Superseded bool   `json:"superseded"`
			DeviceName string `json:"device_name"`
		} `json:"backups"`
	}
	if status != http.StatusOK || json.Unmarshal(body, &list) != nil || len(list.Backups) != 2 {
		t.Fatalf("list: %d %s", status, body)
	}
	newest, older := list.Backups[0], list.Backups[1]
	if newest.Kind != 1 || newest.Counter != 4 || newest.Superseded || !bytes.Equal(newest.RKID, rkID) || newest.DeviceName != "owner phone" ||
		older.ID != created.ID || !older.Superseded {
		t.Fatalf("list = %+v", list.Backups)
	}
	status, body = f.do(http.MethodGet, "/api/v1/backups/"+created.ID, f.ownerToken, nil, nil)
	if status != http.StatusOK || string(body) != "sealed copy one" {
		t.Fatalf("superseded download: %d %q", status, body)
	}
}

func TestK1DeleteOfAnotherDevicesCopyNeedsRecentAuth(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.setRK(f.ownerToken)
	rkID := f.accountRKID()
	if status, body := f.postK1(f.ownerToken, k1Metadata(rkID, 1), []byte("own"), nil); status != http.StatusCreated {
		t.Fatalf("own copy: %d %s", status, body)
	}
	// A copy of another device of the account.
	now := recoveryTestTime(time.Now())
	f.exec(`INSERT INTO devices(id, account_id, name, key_package, auth_secret_hash, created_at) VALUES('dev_k1_tablet', ?, 'tablet', X'01', 'hash', ?)`, f.ownerAccountID, now)
	f.exec(`INSERT INTO backup_blobs(id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at, kind, rk_id, counter)
		VALUES('backup_k1_tablet', ?, 'dev_k1_tablet', 'blob_k1_tablet', '', 3, '{}', ?, 1, ?, 1)`, f.ownerAccountID, now, rkID)
	var own string
	if err := f.db.QueryRow(`SELECT id FROM backup_blobs WHERE device_id = ?`, f.ownerDeviceID).Scan(&own); err != nil {
		t.Fatal(err)
	}
	f.exec(`UPDATE sessions SET recent_auth_at = ? WHERE device_id = ?`, recoveryTestTime(time.Now().Add(-time.Hour)), f.ownerDeviceID)
	if status, body := f.do(http.MethodDelete, "/api/v1/backups/backup_k1_tablet", f.ownerToken, nil, nil); status != http.StatusForbidden || !bytes.Contains(body, []byte("recent_auth_required")) {
		t.Fatalf("other device's copy without recent auth: %d %s", status, body)
	}
	if status, body := f.do(http.MethodDelete, "/api/v1/backups/"+own, f.ownerToken, nil, nil); status != http.StatusNoContent {
		t.Fatalf("own copy without recent auth: %d %s", status, body)
	}
	f.reauth()
	if status, body := f.do(http.MethodDelete, "/api/v1/backups/backup_k1_tablet", f.ownerToken, nil, nil); status != http.StatusNoContent {
		t.Fatalf("other device's copy after reauth: %d %s", status, body)
	}
}

func TestK1KeySwapRouteDeletesOldKeyCopies(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.setRK(f.ownerToken)
	if status, body := f.postK1(f.ownerToken, k1Metadata(f.accountRKID(), 1), []byte("old key"), nil); status != http.StatusCreated {
		t.Fatalf("copy: %d %s", status, body)
	}
	f.setRK(f.ownerToken)
	if n := f.count(`SELECT COUNT(*) FROM backup_blobs WHERE kind = 1`); n != 0 {
		t.Fatalf("old-key copies after the swap = %d", n)
	}
	if n := f.count(`SELECT COUNT(*) FROM blob_deletion_queue`); n != 1 {
		t.Fatalf("queued blob deletions = %d, want 1", n)
	}
	// The next upload under the old key is refused; under the new one it
	// goes on with a higher counter.
	if status, body := f.postK1(f.ownerToken, k1Metadata(bytes.Repeat([]byte{1}, 16), 2), []byte("x"), nil); status != http.StatusConflict {
		t.Fatalf("old key upload: %d %s", status, body)
	}
	if status, body := f.postK1(f.ownerToken, k1Metadata(f.accountRKID(), 2), []byte("new key"), nil); status != http.StatusCreated {
		t.Fatalf("new key upload: %d %s", status, body)
	}
}

// blobFiles counts the stored blob files (temporary uploads excluded).
func (f *recoveryFixture) blobFiles() int {
	f.t.Helper()
	entries, err := os.ReadDir(filepath.Join(f.dir, "blobs"))
	if err != nil {
		f.t.Fatal(err)
	}
	n := 0
	for _, entry := range entries {
		if !entry.IsDir() && !strings.HasSuffix(entry.Name(), ".tmp") {
			n++
		}
	}
	return n
}

// Refused uploads leave no file, and replaced copies leave the disk at
// once: a loop of uploads keeps two files (review blocker).
func TestK1UploadLoopKeepsTwoFilesAndRefusalsNone(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.setRK(f.ownerToken)
	rkID := f.accountRKID()
	before := f.blobFiles()
	if status, body := f.postK1(f.ownerToken, k1Metadata(bytes.Repeat([]byte{3}, 16), 1), []byte("x"), nil); status != http.StatusConflict {
		t.Fatalf("other key: %d %s", status, body)
	}
	if n := f.blobFiles(); n != before {
		t.Fatalf("a refused upload left %d files", n-before)
	}
	for counter := int64(1); counter <= 5; counter++ {
		if status, body := f.postK1(f.ownerToken, k1Metadata(rkID, counter), []byte(fmt.Sprintf("copy %d", counter)), nil); status != http.StatusCreated {
			t.Fatalf("copy %d: %d %s", counter, status, body)
		}
	}
	if n := f.blobFiles(); n != before+2 {
		t.Fatalf("files after five uploads = %d, want %d", n, before+2)
	}
	if n := f.count(`SELECT COUNT(*) FROM blob_deletion_queue`); n != 0 {
		t.Fatalf("deletion queue = %d", n)
	}
}

// Above the allowance the upload answers the storage-quota error and its
// file is removed.
func TestK1UploadOverTheAllowanceIsRefusedAndCleanedUp(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.setRK(f.ownerToken)
	rkID := f.accountRKID()
	now := recoveryTestTime(time.Now())
	// Another device of the account already holds the whole allowance.
	f.exec(`INSERT INTO devices(id, account_id, name, key_package, auth_secret_hash, created_at) VALUES('dev_k1_full', ?, 'desktop', X'01', 'hash', ?)`, f.ownerAccountID, now)
	f.exec(`INSERT INTO backup_blobs(id, account_id, device_id, storage_key, ciphertext_sha256, size_bytes, key_derivation_metadata_json, created_at, kind, rk_id, counter)
		VALUES('backup_k1_full', ?, 'dev_k1_full', 'blob_k1_full', '', ?, '{}', ?, 1, ?, 1)`, f.ownerAccountID, 2*(64<<20+64*20+416), now, rkID)
	before := f.blobFiles()
	status, body := f.postK1(f.ownerToken, k1Metadata(rkID, 1), []byte("one byte too many"), nil)
	if status != http.StatusInsufficientStorage || !bytes.Contains(body, []byte("storage_quota_exceeded")) {
		t.Fatalf("over the allowance: %d %s", status, body)
	}
	if n := f.blobFiles(); n != before {
		t.Fatalf("the refused upload left %d files", n-before)
	}
}
