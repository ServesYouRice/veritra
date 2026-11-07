package httpapi_test

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// C6 (docs/designs/C6-reports-franking.md): franking commitments on envelopes
// and the sealed report routes. The server must carry the commitment write
// once, route reports by conversation kind, record the sender and commitment
// itself, and never see or log report content.

func frankedMessage(t *testing.T, handler http.Handler, token, conversationID, key string, commit []byte) (string, string) {
	t.Helper()
	body := map[string]interface{}{
		"conversation_id": conversationID,
		"idempotency_key": key,
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext-" + key)),
		"crypto_protocol": "mls10-openmls-v1",
	}
	if commit != nil {
		body["frank_commit"] = base64.StdEncoding.EncodeToString(commit)
	}
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", token, body)
	if status != http.StatusCreated {
		t.Fatalf("create franked message status=%d body=%s", status, response)
	}
	var decoded struct {
		ID          string `json:"id"`
		FrankCommit []byte `json:"frank_commit"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatal(err)
	}
	if commit != nil && !bytes.Equal(decoded.FrankCommit, commit) {
		t.Fatalf("response commit %x, want %x", decoded.FrankCommit, commit)
	}
	if commit == nil && strings.Contains(string(response), "frank_commit") {
		t.Fatalf("unfranked response mentions frank_commit: %s", response)
	}
	return decoded.ID, string(response)
}

func sealedBytes() []byte {
	return append([]byte("VRP1"), bytes.Repeat([]byte{9}, 64)...)
}

func commitOf(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }

func TestFrankCommitIsStoredOnceInItsOwnColumn(t *testing.T) {
	handler, ownerToken, dbPath := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sender")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)

	commit := commitOf(0xab)
	messageID, _ := frankedMessage(t, handler, memberToken, conversationID, "franked-1", commit)

	// Wrong sizes are refused, and nothing is stored for them.
	for _, size := range []int{1, 31, 33, 64} {
		status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", memberToken, map[string]interface{}{
			"conversation_id": conversationID,
			"idempotency_key": "bad-size",
			"ciphertext":      base64.StdEncoding.EncodeToString([]byte("x")),
			"crypto_protocol": "mls10-openmls-v1",
			"frank_commit":    base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, size)),
		})
		if status != http.StatusBadRequest || !strings.Contains(string(response), "invalid_frank_commit") {
			t.Fatalf("size %d: status=%d body=%s", size, status, response)
		}
	}

	// Every read path returns the commitment: a single fetch, the list, sync.
	for _, path := range []string{"/api/v1/messages/" + messageID, "/api/v1/conversations/" + conversationID + "/messages", "/api/v1/sync/events?after=0&limit=100"} {
		status, response := doJSON(t, handler, http.MethodGet, path, ownerToken, nil)
		if status != http.StatusOK || !strings.Contains(string(response), base64.StdEncoding.EncodeToString(commit)) {
			t.Fatalf("%s lacks the commitment: status=%d body=%s", path, status, response)
		}
	}

	// It never rides inside crypto_metadata: the stored metadata is untouched.
	db := openSQLite(t, dbPath)
	var metadata string
	if err := db.QueryRow(`SELECT crypto_metadata_json FROM message_envelopes WHERE id = ?`, messageID).Scan(&metadata); err != nil || strings.Contains(metadata, "frank") {
		t.Fatalf("crypto_metadata_json=%q err=%v", metadata, err)
	}

	// Write-once at the database: no statement changes or clears it.
	for _, statement := range []string{
		`UPDATE message_envelopes SET frank_commit = X'00' WHERE id = ?`,
		`UPDATE message_envelopes SET frank_commit = NULL WHERE id = ?`,
		`UPDATE message_envelopes SET frank_commit = zeroblob(32) WHERE id = ?`,
	} {
		if _, err := db.Exec(statement, messageID); err == nil {
			t.Fatalf("%s succeeded", statement)
		}
	}
	if _, err := db.Exec(`UPDATE message_envelopes SET edited_at = edited_at WHERE id = ?`, messageID); err != nil {
		t.Fatalf("unrelated update refused: %v", err)
	}

	// An in-place edit would leave the commitment stale, so it is refused.
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+messageID+"/edit", memberToken, map[string]interface{}{
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("new")),
		"crypto_protocol": "mls10-openmls-v1",
	})
	if status != http.StatusForbidden {
		t.Fatalf("edit of franked message status=%d body=%s", status, response)
	}

	// An idempotent retry must repeat the commitment; a different one is a
	// different message.
	status, _ = doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", memberToken, map[string]interface{}{
		"conversation_id": conversationID,
		"idempotency_key": "franked-1",
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext-franked-1")),
		"crypto_protocol": "mls10-openmls-v1",
		"frank_commit":    base64.StdEncoding.EncodeToString(commit),
	})
	if status != http.StatusOK {
		t.Fatalf("idempotent retry status=%d", status)
	}
	status, _ = doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", memberToken, map[string]interface{}{
		"conversation_id": conversationID,
		"idempotency_key": "franked-1",
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext-franked-1")),
		"crypto_protocol": "mls10-openmls-v1",
		"frank_commit":    base64.StdEncoding.EncodeToString(commitOf(0xcd)),
	})
	if status != http.StatusConflict {
		t.Fatalf("retry with another commitment status=%d, want 409", status)
	}
}

func openSQLite(t *testing.T, path string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(10000)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

type reportBody struct {
	ID                 string `json:"id"`
	InboxKind          string `json:"inbox_kind"`
	InboxID            string `json:"inbox_id"`
	KeyRev             int64  `json:"key_rev"`
	RecipientPublicKey []byte `json:"recipient_public_key"`
	ConversationID     string `json:"conversation_id"`
	EnvelopeID         string `json:"envelope_id"`
	ReporterAccountID  string `json:"reporter_account_id"`
	SenderAccountID    string `json:"sender_account_id"`
	SenderDeviceID     string `json:"sender_device_id"`
	ActionID           string `json:"action_id"`
	FrankCommit        []byte `json:"frank_commit"`
	Sealed             []byte `json:"sealed"`
}

func listReportsAs(t *testing.T, handler http.Handler, token, query string) (int, []reportBody) {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/reports?"+query, token, nil)
	var decoded struct {
		Reports []reportBody `json:"reports"`
	}
	if status == http.StatusOK {
		if err := json.Unmarshal(response, &decoded); err != nil {
			t.Fatal(err)
		}
	}
	return status, decoded.Reports
}

func fileReport(t *testing.T, handler http.Handler, token, conversationID, envelopeID string, rev int64, key, sealed []byte) (int, string) {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/reports", token, map[string]interface{}{
		"conversation_id":      conversationID,
		"envelope_id":          envelopeID,
		"key_rev":              rev,
		"recipient_public_key": base64.StdEncoding.EncodeToString(key),
		"sealed":               base64.StdEncoding.EncodeToString(sealed),
	})
	return status, string(response)
}

func TestReportToInstanceOwnerFromGroup(t *testing.T) {
	handler, ownerToken, dbPath := newTestHandlerWithOwner(t)
	senderToken, senderID := registerMemberWithID(t, handler, ownerToken, "sender")
	reporterToken, reporterID := registerMemberWithID(t, handler, ownerToken, "reporter")
	outsiderToken := registerMember(t, handler, ownerToken, "outsider")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, senderID)
	addMember(t, handler, ownerToken, conversationID, reporterID)

	commit := commitOf(0x5a)
	franked, _ := frankedMessage(t, handler, senderToken, conversationID, "msg-a", commit)
	unfranked, _ := frankedMessage(t, handler, senderToken, conversationID, "msg-b", nil)
	own, _ := frankedMessage(t, handler, reporterToken, conversationID, "msg-own", commitOf(0x11))

	// Without a published key there is nowhere to send a report.
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/reports/inbox?conversation_id="+conversationID, reporterToken, nil)
	if status != http.StatusConflict || !strings.Contains(string(response), "report_inbox_unavailable") {
		t.Fatalf("inbox before publish status=%d body=%s", status, response)
	}

	// Only an owner publishes the key; it must be 32 bytes.
	key := bytes.Repeat([]byte{7}, 32)
	put := func(token string, key []byte) (int, []byte) {
		return doJSON(t, handler, http.MethodPut, "/api/v1/reports/inbox-keys/instance", token, map[string]interface{}{"public_key": base64.StdEncoding.EncodeToString(key)})
	}
	if status, _ := put(reporterToken, key); status != http.StatusForbidden {
		t.Fatalf("member published the owner key: %d", status)
	}
	if status, _ := put(ownerToken, key[:31]); status != http.StatusBadRequest {
		t.Fatalf("short key status=%d", status)
	}
	if status, response := put(ownerToken, key); status != http.StatusOK || !strings.Contains(string(response), `"key_rev":1`) {
		t.Fatalf("publish status=%d body=%s", status, response)
	}
	// The same key again does not raise the revision.
	if status, response := put(ownerToken, key); status != http.StatusOK || !strings.Contains(string(response), `"key_rev":1`) {
		t.Fatalf("republish status=%d body=%s", status, response)
	}

	// Members see the inbox and its key; outsiders do not.
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/reports/inbox?conversation_id="+conversationID, reporterToken, nil)
	if status != http.StatusOK || !strings.Contains(string(response), `"inbox_kind":"instance_owner"`) || !strings.Contains(string(response), base64.StdEncoding.EncodeToString(key)) {
		t.Fatalf("inbox status=%d body=%s", status, response)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, "/api/v1/reports/inbox?conversation_id="+conversationID, outsiderToken, nil); status != http.StatusForbidden {
		t.Fatalf("outsider inbox status=%d", status)
	}

	// Refusals: unfranked message, own message, stale revision, bad sealed
	// bytes, non-member, unknown message.
	if status, body := fileReport(t, handler, reporterToken, conversationID, unfranked, 1, key, sealedBytes()); status != http.StatusConflict || !strings.Contains(body, "message_not_reportable") {
		t.Fatalf("unfranked report status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, own, 1, key, sealedBytes()); status != http.StatusConflict || !strings.Contains(body, "message_not_reportable") {
		t.Fatalf("own message report status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, franked, 2, key, sealedBytes()); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("stale revision status=%d body=%s", status, body)
	}
	for name, sealed := range map[string][]byte{
		"no magic":  append([]byte("XXXX"), bytes.Repeat([]byte{9}, 64)...),
		"too short": []byte("VRP1"),
		"too long":  append([]byte("VRP1"), bytes.Repeat([]byte{9}, 262196)...),
	} {
		if status, body := fileReport(t, handler, reporterToken, conversationID, franked, 1, key, sealed); status != http.StatusBadRequest {
			t.Fatalf("%s: status=%d body=%s", name, status, body)
		}
	}
	if status, _ := fileReport(t, handler, outsiderToken, conversationID, franked, 1, key, sealedBytes()); status != http.StatusForbidden {
		t.Fatalf("outsider report status=%d", status)
	}
	if status, _ := fileReport(t, handler, reporterToken, conversationID, "msg_00000000000000000000000000000000", 1, key, sealedBytes()); status != http.StatusNotFound {
		t.Fatalf("unknown message report status=%d", status)
	}

	// A good report. The response does not echo the sealed bytes.
	sealed := sealedBytes()
	status, body := fileReport(t, handler, reporterToken, conversationID, franked, 1, key, sealed)
	if status != http.StatusCreated || strings.Contains(body, `"sealed"`) {
		t.Fatalf("report status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, franked, 1, key, sealed); status != http.StatusConflict || !strings.Contains(body, "already_reported") {
		t.Fatalf("duplicate report status=%d body=%s", status, body)
	}

	// The owner reads it, with routing fields and the server's own record of
	// the sender and the commitment.
	status, reports := listReportsAs(t, handler, ownerToken, "inbox=instance_owner")
	if status != http.StatusOK || len(reports) != 1 {
		t.Fatalf("owner list status=%d reports=%d", status, len(reports))
	}
	got := reports[0]
	if got.InboxKind != "instance_owner" || got.InboxID != "instance" || got.KeyRev != 1 || !bytes.Equal(got.RecipientPublicKey, key) ||
		got.ConversationID != conversationID || got.EnvelopeID != franked || got.ReporterAccountID != reporterID ||
		got.SenderAccountID != senderID || got.SenderDeviceID == "" || got.ActionID != "msg-a" ||
		!bytes.Equal(got.FrankCommit, commit) || !bytes.Equal(got.Sealed, sealed) {
		t.Fatalf("unexpected report: %+v", got)
	}

	// Nobody else reads it: not the reporter, not the sender, not a bad inbox.
	for name, token := range map[string]string{"reporter": reporterToken, "sender": senderToken, "outsider": outsiderToken} {
		if status, _ := listReportsAs(t, handler, token, "inbox=instance_owner"); status != http.StatusForbidden {
			t.Fatalf("%s listed the owner inbox: %d", name, status)
		}
	}
	if status, _ := listReportsAs(t, handler, ownerToken, "inbox=moderators"); status != http.StatusBadRequest {
		t.Fatalf("bad inbox status=%d", status)
	}
	if status, _ := listReportsAs(t, handler, ownerToken, "inbox=community"); status != http.StatusBadRequest {
		t.Fatalf("community without id status=%d", status)
	}

	// The report outlives its envelope: the row snapshot is what verifies.
	db := openSQLite(t, dbPath)
	if _, err := db.Exec(`DELETE FROM message_envelopes WHERE id = ?`, franked); err != nil {
		t.Fatal(err)
	}
	if status, reports := listReportsAs(t, handler, ownerToken, "inbox=instance_owner"); status != http.StatusOK || len(reports) != 1 || !bytes.Equal(reports[0].FrankCommit, commit) {
		t.Fatalf("report did not survive its envelope: status=%d %+v", status, reports)
	}

	// Rotating the key makes older revisions refuse.
	rotated := bytes.Repeat([]byte{8}, 32)
	if status, response := put(ownerToken, rotated); status != http.StatusOK || !strings.Contains(string(response), `"key_rev":2`) {
		t.Fatalf("rotate status=%d body=%s", status, response)
	}
	second, _ := frankedMessage(t, handler, senderToken, conversationID, "msg-c", commitOf(0x66))
	if status, body := fileReport(t, handler, reporterToken, conversationID, second, 1, key, sealed); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("report to the old key status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, second, 2, rotated, sealed); status != http.StatusCreated {
		t.Fatalf("report to the new key status=%d body=%s", status, body)
	}

	// Dismissal is for people who can read the inbox, and looks like a
	// missing report to everyone else.
	if status, _ := doJSON(t, handler, http.MethodDelete, "/api/v1/reports/"+got.ID, reporterToken, nil); status != http.StatusNotFound {
		t.Fatalf("reporter dismissal status=%d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodDelete, "/api/v1/reports/"+got.ID, ownerToken, nil); status != http.StatusNoContent {
		t.Fatalf("owner dismissal status=%d", status)
	}
	if status, reports := listReportsAs(t, handler, ownerToken, "inbox=instance_owner"); status != http.StatusOK || len(reports) != 1 {
		t.Fatalf("after dismissal status=%d reports=%d", status, len(reports))
	}

	// The audit log records that reports were filed, never what they held.
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/admin/audit-events", ownerToken, nil)
	if status != http.StatusOK || !strings.Contains(string(response), "report.filed") {
		t.Fatalf("audit status=%d body=%s", status, response)
	}
	for _, secret := range []string{base64.StdEncoding.EncodeToString(sealed), base64.StdEncoding.EncodeToString(commit), franked} {
		if strings.Contains(string(response), secret) {
			t.Fatalf("audit log holds report content %q", secret)
		}
	}
}

func TestReportsAreCappedPerReporter(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	senderToken, senderID := registerMemberWithID(t, handler, ownerToken, "sender")
	reporterToken, reporterID := registerMemberWithID(t, handler, ownerToken, "reporter")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, senderID)
	addMember(t, handler, ownerToken, conversationID, reporterID)
	capKey := bytes.Repeat([]byte{7}, 32)
	if status, _ := doJSON(t, handler, http.MethodPut, "/api/v1/reports/inbox-keys/instance", ownerToken, map[string]interface{}{"public_key": base64.StdEncoding.EncodeToString(capKey)}); status != http.StatusOK {
		t.Fatalf("publish status=%d", status)
	}
	var lastStatus int
	var lastBody string
	for i := 0; i < 21; i++ {
		id, _ := frankedMessage(t, handler, senderToken, conversationID, "m"+string(rune('a'+i)), commitOf(byte(i+1)))
		lastStatus, lastBody = fileReport(t, handler, reporterToken, conversationID, id, 1, capKey, sealedBytes())
		if i < 20 && lastStatus != http.StatusCreated {
			t.Fatalf("report %d status=%d body=%s", i, lastStatus, lastBody)
		}
	}
	if lastStatus != http.StatusTooManyRequests || !strings.Contains(lastBody, "report_limit_reached") {
		t.Fatalf("21st report status=%d body=%s", lastStatus, lastBody)
	}
}

func TestCommunityReportsRouteToModerators(t *testing.T) {
	handler, ownerToken, dbPath := newTestHandlerWithOwner(t)
	senderToken, senderID := registerMemberWithID(t, handler, ownerToken, "sender")
	reporterToken, reporterID := registerMemberWithID(t, handler, ownerToken, "reporter")
	modToken, modID := registerMemberWithID(t, handler, ownerToken, "moderator")

	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{"name": "Reports"})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, response)
	}
	var community struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &community); err != nil {
		t.Fatal(err)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]interface{}{"name": "general"})
	if status != http.StatusCreated {
		t.Fatalf("create channel status=%d body=%s", status, response)
	}
	var created struct {
		Conversation struct {
			ID string `json:"id"`
		} `json:"conversation"`
	}
	if err := json.Unmarshal(response, &created); err != nil {
		t.Fatal(err)
	}
	conversationID := created.Conversation.ID
	for id, role := range map[string]string{senderID: "member", reporterID: "member", modID: "moderator"} {
		if status, response := doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/members", ownerToken, map[string]interface{}{"account_id": id, "role": role}); status != http.StatusOK {
			t.Fatalf("add community member status=%d body=%s", status, response)
		}
		addMember(t, handler, ownerToken, conversationID, id)
	}
	franked, _ := frankedMessage(t, handler, senderToken, conversationID, "c-1", commitOf(0x42))

	// No route publishes a community inbox key yet (C4 distributes it), so
	// reporting is unavailable until one exists.
	communityKey := bytes.Repeat([]byte{3}, 32)
	if status, body := fileReport(t, handler, reporterToken, conversationID, franked, 1, communityKey, sealedBytes()); status != http.StatusConflict || !strings.Contains(body, "report_inbox_unavailable") {
		t.Fatalf("report without community key status=%d body=%s", status, body)
	}

	db := openSQLite(t, dbPath)
	if _, err := db.Exec(`INSERT INTO report_inbox_keys(inbox_kind, inbox_id, public_key, key_rev, updated_at) VALUES('community', ?, ?, 1, '2026-11-07T00:00:00Z')`, community.ID, communityKey); err != nil {
		t.Fatal(err)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/reports/inbox?conversation_id="+conversationID, reporterToken, nil)
	if status != http.StatusOK || !strings.Contains(string(response), `"inbox_kind":"community"`) || !strings.Contains(string(response), community.ID) {
		t.Fatalf("community inbox status=%d body=%s", status, response)
	}
	// A report sealed to another key is refused even at the current revision.
	if status, body := fileReport(t, handler, reporterToken, conversationID, franked, 1, bytes.Repeat([]byte{4}, 32), sealedBytes()); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("report to another key status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, franked, 1, communityKey, sealedBytes()); status != http.StatusCreated {
		t.Fatalf("community report status=%d body=%s", status, body)
	}

	query := "inbox=community&community_id=" + community.ID
	for name, token := range map[string]string{"community owner": ownerToken, "moderator": modToken} {
		if status, reports := listReportsAs(t, handler, token, query); status != http.StatusOK || len(reports) != 1 || reports[0].InboxKind != "community" || reports[0].InboxID != community.ID || !bytes.Equal(reports[0].RecipientPublicKey, communityKey) {
			t.Fatalf("%s list status=%d reports=%+v", name, status, reports)
		}
	}
	for name, token := range map[string]string{"reporter": reporterToken, "sender": senderToken} {
		if status, _ := listReportsAs(t, handler, token, query); status != http.StatusForbidden {
			t.Fatalf("%s listed the moderator inbox: %d", name, status)
		}
	}
	// The instance owners' inbox does not show community reports.
	if status, reports := listReportsAs(t, handler, ownerToken, "inbox=instance_owner"); status != http.StatusOK || len(reports) != 0 {
		t.Fatalf("instance inbox status=%d reports=%d", status, len(reports))
	}
}
