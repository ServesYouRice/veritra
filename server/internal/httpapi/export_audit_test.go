package httpapi_test

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"testing"
)

// Card I38: an account export records its dedicated audit event, the event
// carries no export content, and a failed audit write withholds the export.
func TestAccountExportIsAuditedAndFailsClosedWithoutTheAudit(t *testing.T) {
	handler, token, dbPath := newTestHandlerWithOwner(t)
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	exportAudits := func() []string {
		t.Helper()
		rows, err := db.Query(`SELECT metadata_json FROM audit_events WHERE event_type = 'account.exported' ORDER BY id`)
		if err != nil {
			t.Fatalf("read audit events: %v", err)
		}
		defer rows.Close()
		var metadata []string
		for rows.Next() {
			var value string
			if err := rows.Scan(&value); err != nil {
				t.Fatalf("scan audit event: %v", err)
			}
			metadata = append(metadata, value)
		}
		return metadata
	}

	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/account/export", token, nil)
	if status != http.StatusOK {
		t.Fatalf("export status=%d body=%s", status, response)
	}
	audits := exportAudits()
	if len(audits) != 1 {
		t.Fatalf("export audit events = %d, want 1", len(audits))
	}
	var metadata map[string]string
	if err := json.Unmarshal([]byte(audits[0]), &metadata); err != nil {
		t.Fatalf("decode audit metadata: %v", err)
	}
	if len(metadata) != 2 || metadata["schema_version"] != "v2" || metadata["scope"] != "account" {
		t.Fatalf("audit metadata = %v, want only schema_version=v2 and scope=account", metadata)
	}

	if _, err := db.Exec(`CREATE TRIGGER inject_export_audit_failure BEFORE INSERT ON audit_events WHEN NEW.event_type = 'account.exported' BEGIN SELECT RAISE(ABORT, 'injected'); END`); err != nil {
		t.Fatalf("install audit failure trigger: %v", err)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/account/export", token, nil)
	if status != http.StatusInternalServerError || !bytes.Contains(response, []byte("export_audit_failed")) {
		t.Fatalf("unaudited export status=%d body=%s", status, response)
	}
	if bytes.Contains(response, []byte(`"messages"`)) || bytes.Contains(response, []byte(`"account"`)) {
		t.Fatalf("export content returned without its audit event: %s", response)
	}
	if got := len(exportAudits()); got != 1 {
		t.Fatalf("export audit events after the failure = %d, want 1", got)
	}
}
