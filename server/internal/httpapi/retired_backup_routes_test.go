package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"net/http"
	"testing"
)

// K1-6 (D91): the VBK2 upload and the 15-minute recovery-token route are
// retired. Old clients get a typed 410 they can show; nothing is stored, no
// token is read and no body is consumed into the blob store.
func TestRetiredBackupRoutesAnswerATypedError(t *testing.T) {
	for name, origin := range map[string]string{"origin set": recoveryTestOrigin, "no origin": ""} {
		t.Run(name, func(t *testing.T) {
			f := newRecoveryFixture(t, origin)
			token := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
			legacyMetadata := `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`
			for _, extra := range []map[string]string{{"X-Recovery-Token": token}, nil} {
				status, body := f.postK1(f.ownerToken, legacyMetadata, []byte("encrypted backup blob"), extra)
				if status != http.StatusGone || !bytes.Contains(body, []byte("backup_format_retired")) {
					t.Fatalf("legacy upload: %d %s", status, body)
				}
			}
			// Garbage metadata is a client error as before; it never reaches K1 or legacy storage.
			if status, _ := f.postK1(f.ownerToken, `not json`, []byte("x"), nil); status != http.StatusGone {
				t.Fatalf("garbage metadata status = %d", status)
			}
			if n := f.count(`SELECT COUNT(*) FROM backup_blobs`); n != 0 {
				t.Fatalf("rows = %d", n)
			}
			for _, headers := range []map[string]string{{"X-Recovery-Token": token}, {"X-Recovery-Token": "bad"}, nil} {
				status, body := doRaw(t, f.handler, http.MethodGet, "/api/v1/recovery", "", nil, headers)
				if status != http.StatusGone || !bytes.Contains(body, []byte("recovery_route_retired")) {
					t.Fatalf("recovery route: %d %s", status, body)
				}
			}
			if status, _ := doRaw(t, f.handler, http.MethodGet, "/api/v1/recovery/"+token, "", nil, nil); status != http.StatusNotFound {
				t.Fatalf("token in the path: %d", status)
			}
		})
	}
}
