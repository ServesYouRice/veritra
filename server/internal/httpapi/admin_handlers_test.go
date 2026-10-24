package httpapi_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestAdminAccountsSuspendReactivateAndAuditLog(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "bob")

	// Members cannot use the admin API.
	if status, _ := doJSON(t, handler, http.MethodGet, "/api/v1/admin/accounts", memberToken, nil); status != http.StatusForbidden {
		t.Fatalf("member list status=%d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, "/api/v1/admin/audit-events", memberToken, nil); status != http.StatusForbidden {
		t.Fatalf("member audit status=%d", status)
	}

	// Paging: one account per page, the cursor continues.
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/admin/accounts?limit=1", ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("list status=%d body=%s", status, response)
	}
	var page struct {
		Accounts  []struct{ ID string } `json:"accounts"`
		NextAfter string                `json:"next_after"`
	}
	if err := json.Unmarshal(response, &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Accounts) != 1 || page.NextAfter == "" {
		t.Fatalf("first page=%s", response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/admin/accounts?limit=1&after="+page.NextAfter, ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("second page status=%d body=%s", status, response)
	}

	// Suspend, then reactivate.
	for _, want := range []string{"suspended", "active"} {
		status, response = doJSON(t, handler, http.MethodPatch, "/api/v1/admin/accounts/"+memberID+"/status", ownerToken, map[string]string{"status": want})
		if status != http.StatusOK {
			t.Fatalf("set %s status=%d body=%s", want, status, response)
		}
	}
	// An owner cannot suspend themselves.
	ownerID := accountIDFromExport(t, handler, ownerToken)
	if status, _ = doJSON(t, handler, http.MethodPatch, "/api/v1/admin/accounts/"+ownerID+"/status", ownerToken, map[string]string{"status": "suspended"}); status != http.StatusForbidden {
		t.Fatalf("self suspend status=%d", status)
	}

	// Both changes are in the audit log, which carries ids and statuses only.
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/admin/audit-events", ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("audit status=%d body=%s", status, response)
	}
	var events struct {
		Events []struct {
			EventType string                 `json:"event_type"`
			Metadata  map[string]interface{} `json:"metadata"`
		} `json:"events"`
	}
	if err := json.Unmarshal(response, &events); err != nil {
		t.Fatal(err)
	}
	updates := 0
	for _, event := range events.Events {
		if event.EventType == "account.status.updated" && event.Metadata["target_account_id"] == memberID {
			updates++
		}
	}
	if updates != 2 {
		t.Fatalf("status audit events=%d body=%s", updates, response)
	}
}
