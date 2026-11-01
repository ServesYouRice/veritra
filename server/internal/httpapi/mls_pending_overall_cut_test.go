package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// The pending-changes response carries the overall-cut flag next to the
// list it has always carried (additive; D68 hold release reads it).
func TestMLSPendingChangesReportsOverallCut(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/mls/pending-changes", ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("status=%d body=%s", status, response)
	}
	var body map[string]json.RawMessage
	if err := json.Unmarshal(response, &body); err != nil {
		t.Fatalf("decode: %v %s", err, response)
	}
	if string(body["pending_changes"]) != "[]" {
		t.Fatalf("pending_changes = %s, want []", body["pending_changes"])
	}
	if string(body["list_truncated"]) != "false" {
		t.Fatalf("list_truncated = %q, want false", body["list_truncated"])
	}
}
