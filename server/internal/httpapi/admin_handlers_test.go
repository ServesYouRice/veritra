package httpapi_test

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
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

func TestAdminAuditEventsNewestFirstPagesWithBefore(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	_, memberID := registerMemberWithID(t, handler, ownerToken, "bob")
	for _, want := range []string{"suspended", "active", "suspended"} {
		if status, response := doJSON(t, handler, http.MethodPatch, "/api/v1/admin/accounts/"+memberID+"/status", ownerToken, map[string]string{"status": want}); status != http.StatusOK {
			t.Fatalf("set %s status=%d body=%s", want, status, response)
		}
	}
	type page struct {
		Events []struct {
			ID int64 `json:"id"`
		} `json:"events"`
		NextBefore int64 `json:"next_before"`
		NextAfter  int64 `json:"next_after"`
	}
	fetch := func(path string) page {
		t.Helper()
		status, response := doJSON(t, handler, http.MethodGet, path, ownerToken, nil)
		if status != http.StatusOK {
			t.Fatalf("%s status=%d body=%s", path, status, response)
		}
		var decoded page
		if err := json.Unmarshal(response, &decoded); err != nil {
			t.Fatal(err)
		}
		return decoded
	}

	oldest := fetch("/api/v1/admin/audit-events")
	if len(oldest.Events) < 3 {
		t.Fatalf("expected several events, got %d", len(oldest.Events))
	}
	for i := 1; i < len(oldest.Events); i++ {
		if oldest.Events[i].ID <= oldest.Events[i-1].ID {
			t.Fatalf("default order is not oldest first: %+v", oldest.Events)
		}
	}

	first := fetch("/api/v1/admin/audit-events?order=desc&limit=2")
	if len(first.Events) != 2 || first.Events[0].ID <= first.Events[1].ID || first.NextBefore != first.Events[1].ID || first.NextAfter != 0 {
		t.Fatalf("first desc page=%+v", first)
	}
	if first.Events[0].ID != oldest.Events[len(oldest.Events)-1].ID {
		t.Fatalf("desc does not start at the newest event: %+v", first)
	}
	next := fetch("/api/v1/admin/audit-events?order=desc&limit=2&before=" + strconv.FormatInt(first.NextBefore, 10))
	if len(next.Events) == 0 {
		t.Fatal("second desc page is empty")
	}
	for _, event := range next.Events {
		if event.ID >= first.NextBefore {
			t.Fatalf("second desc page repeats or skips: %+v", next)
		}
	}
}

func TestAdminSuspendRankAndRecentAuth(t *testing.T) {
	handler, ownerToken, dbPath := newTestHandlerWithOwner(t)
	adminToken, adminID := registerMemberWithID(t, handler, ownerToken, "adam")
	_, secondOwnerID := registerMemberWithID(t, handler, ownerToken, "olga")
	_, memberID := registerMemberWithID(t, handler, ownerToken, "bob")
	ownerID := accountIDFromExport(t, handler, ownerToken)

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`UPDATE accounts SET role = 'admin' WHERE id = ?`, adminID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE accounts SET role = 'owner' WHERE id = ?`, secondOwnerID); err != nil {
		t.Fatal(err)
	}
	suspend := func(token, target string) (int, []byte) {
		return doJSON(t, handler, http.MethodPatch, "/api/v1/admin/accounts/"+target+"/status", token, map[string]string{"status": "suspended"})
	}

	// An admin cannot suspend an owner, and an owner cannot suspend another owner.
	if status, response := suspend(adminToken, ownerID); status != http.StatusForbidden {
		t.Fatalf("admin suspends owner status=%d body=%s", status, response)
	}
	if status, response := suspend(ownerToken, secondOwnerID); status != http.StatusForbidden {
		t.Fatalf("owner suspends owner status=%d body=%s", status, response)
	}
	// An admin can suspend a member.
	if status, response := suspend(adminToken, memberID); status != http.StatusOK {
		t.Fatalf("admin suspends member status=%d body=%s", status, response)
	}

	// A stale sign-in is refused before anything changes.
	if _, err := db.Exec(`UPDATE sessions SET recent_auth_at = NULL`); err != nil {
		t.Fatal(err)
	}
	status, response := suspend(ownerToken, adminID)
	if status != http.StatusForbidden || !bytes.Contains(response, []byte("recent_auth_required")) {
		t.Fatalf("stale suspend status=%d body=%s", status, response)
	}
}

// The privileged change and its audit row commit together or not at all
// (VAL-214). A trigger makes the audit insert fail.
func TestAdminActionsAreAtomicWithTheirAuditRow(t *testing.T) {
	handler, ownerToken, dbPath := newTestHandlerWithOwner(t)
	_, memberID := registerMemberWithID(t, handler, ownerToken, "bob")
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/invites", ownerToken, map[string]interface{}{"max_uses": 2})
	if status != http.StatusCreated {
		t.Fatalf("create invite status=%d body=%s", status, response)
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &created); err != nil || created.ID == "" {
		t.Fatalf("invite response %s: %v", response, err)
	}

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	auditRows := func(eventType string) int {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM audit_events WHERE event_type = ?`, eventType).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	accountStatus := func() string {
		var s string
		if err := db.QueryRow(`SELECT status FROM accounts WHERE id = ?`, memberID).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	inviteRevoked := func() bool {
		var revoked sql.NullString
		if err := db.QueryRow(`SELECT revoked_at FROM invites WHERE id = ?`, created.ID).Scan(&revoked); err != nil {
			t.Fatal(err)
		}
		return revoked.Valid
	}
	setStatus := func() int {
		code, _ := doJSON(t, handler, http.MethodPatch, "/api/v1/admin/accounts/"+memberID+"/status", ownerToken, map[string]string{"status": "suspended"})
		return code
	}
	revoke := func() int {
		code, _ := doJSON(t, handler, http.MethodDelete, "/api/v1/admin/invites/"+created.ID, ownerToken, nil)
		return code
	}

	if _, err := db.Exec(`CREATE TRIGGER audit_insert_fails BEFORE INSERT ON audit_events BEGIN SELECT RAISE(ABORT, 'audit write refused'); END`); err != nil {
		t.Fatal(err)
	}
	if code := setStatus(); code < 400 {
		t.Fatalf("status change returned %d although its audit row could not be written", code)
	}
	if got := accountStatus(); got != "active" {
		t.Fatalf("account status = %q after a failed audit write, want active", got)
	}
	if code := revoke(); code < 400 {
		t.Fatalf("invite revocation returned %d although its audit row could not be written", code)
	}
	if inviteRevoked() {
		t.Fatal("invite stayed revoked after a failed audit write")
	}

	if _, err := db.Exec(`DROP TRIGGER audit_insert_fails`); err != nil {
		t.Fatal(err)
	}
	if code := setStatus(); code != http.StatusOK {
		t.Fatalf("status change status=%d", code)
	}
	if got := accountStatus(); got != "suspended" || auditRows("account.status.updated") != 1 {
		t.Fatalf("after success: status=%q audit rows=%d", got, auditRows("account.status.updated"))
	}
	if code := revoke(); code != http.StatusNoContent {
		t.Fatalf("revoke status=%d", code)
	}
	if !inviteRevoked() || auditRows("invite.revoked") != 1 {
		t.Fatalf("after success: revoked=%v audit rows=%d", inviteRevoked(), auditRows("invite.revoked"))
	}
}
