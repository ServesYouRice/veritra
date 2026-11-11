package httpapi_test

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
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

// reportBody is one stored copy as the API returns it. It deliberately has no
// envelope, sender or commitment field: since D95 the server records none.
type reportBody struct {
	ID                 string `json:"id"`
	ReportID           string `json:"report_id"`
	InboxKind          string `json:"inbox_kind"`
	InboxID            string `json:"inbox_id"`
	KeyRev             int64  `json:"key_rev"`
	RecipientPublicKey []byte `json:"recipient_public_key"`
	ConversationID     string `json:"conversation_id"`
	ReporterAccountID  string `json:"reporter_account_id"`
	Sealed             []byte `json:"sealed"`
}

func listReportsAs(t *testing.T, handler http.Handler, token, query string) (int, []reportBody, string) {
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
	return status, decoded.Reports, string(response)
}

type reportCopy struct {
	InboxID string
	Rev     int64
	Key     []byte
	Sealed  []byte
}

func copyBody(c reportCopy) map[string]interface{} {
	return map[string]interface{}{
		"inbox_id":             c.InboxID,
		"key_rev":              c.Rev,
		"recipient_public_key": base64.StdEncoding.EncodeToString(c.Key),
		"sealed":               base64.StdEncoding.EncodeToString(c.Sealed),
	}
}

func fileReport(t *testing.T, handler http.Handler, token, conversationID, reportID string, copies ...reportCopy) (int, string) {
	t.Helper()
	list := []map[string]interface{}{}
	for _, c := range copies {
		list = append(list, copyBody(c))
	}
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/reports", token, map[string]interface{}{
		"conversation_id": conversationID,
		"report_id":       reportID,
		"copies":          list,
	})
	return status, string(response)
}

func sealedWith(b byte) []byte {
	return append([]byte("VRP1"), bytes.Repeat([]byte{b}, 64)...)
}

const reportIDOne = "rpt-0000000000000001"

func putReportKey(t *testing.T, handler http.Handler, token string, key []byte) (int, string) {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodPut, "/api/v1/reports/inbox-keys/instance", token, map[string]interface{}{"public_key": base64.StdEncoding.EncodeToString(key)})
	return status, string(response)
}

func TestReportToEveryInstanceOwnerFromGroup(t *testing.T) {
	handler, ownerToken, dbPath := newTestHandlerWithOwner(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	secondToken, secondID := registerMemberWithID(t, handler, ownerToken, "olga")
	senderToken, senderID := registerMemberWithID(t, handler, ownerToken, "sender")
	reporterToken, reporterID := registerMemberWithID(t, handler, ownerToken, "reporter")
	outsiderToken := registerMember(t, handler, ownerToken, "outsider")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, senderID)
	addMember(t, handler, ownerToken, conversationID, reporterID)
	db := openSQLite(t, dbPath)
	if _, err := db.Exec(`UPDATE accounts SET role = 'owner' WHERE id = ?`, secondID); err != nil {
		t.Fatal(err)
	}

	// Without a published key there is nowhere to send a report.
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/reports/inbox?conversation_id="+conversationID, reporterToken, nil)
	if status != http.StatusConflict || !strings.Contains(string(response), "report_inbox_unavailable") {
		t.Fatalf("inbox before publish status=%d body=%s", status, response)
	}

	// Only an owner publishes a key, their own; it must be 32 bytes.
	key1, key2 := bytes.Repeat([]byte{7}, 32), bytes.Repeat([]byte{8}, 32)
	if status, _ := putReportKey(t, handler, reporterToken, key1); status != http.StatusForbidden {
		t.Fatalf("member published an owner key: %d", status)
	}
	if status, _ := putReportKey(t, handler, ownerToken, key1[:31]); status != http.StatusBadRequest {
		t.Fatalf("short key status=%d", status)
	}
	if status, body := putReportKey(t, handler, ownerToken, key1); status != http.StatusOK || !strings.Contains(body, `"key_rev":1`) || !strings.Contains(body, ownerID) {
		t.Fatalf("publish status=%d body=%s", status, body)
	}
	// The same key again does not raise the revision.
	if status, body := putReportKey(t, handler, ownerToken, key1); status != http.StatusOK || !strings.Contains(body, `"key_rev":1`) {
		t.Fatalf("republish status=%d body=%s", status, body)
	}

	// Members see the recipients and their keys; outsiders do not. An owner
	// who has not published a key is not a recipient yet.
	inboxPath := "/api/v1/reports/inbox?conversation_id=" + conversationID
	status, response = doJSON(t, handler, http.MethodGet, inboxPath, reporterToken, nil)
	if status != http.StatusOK || !strings.Contains(string(response), `"inbox_kind":"instance_owner"`) || !strings.Contains(string(response), base64.StdEncoding.EncodeToString(key1)) || strings.Contains(string(response), secondID) {
		t.Fatalf("inbox status=%d body=%s", status, response)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, inboxPath, outsiderToken, nil); status != http.StatusForbidden {
		t.Fatalf("outsider inbox status=%d", status)
	}
	if status, body := putReportKey(t, handler, secondToken, key2); status != http.StatusOK {
		t.Fatalf("second owner publish status=%d body=%s", status, body)
	}
	status, response = doJSON(t, handler, http.MethodGet, inboxPath, reporterToken, nil)
	if status != http.StatusOK || !strings.Contains(string(response), ownerID) || !strings.Contains(string(response), secondID) {
		t.Fatalf("inbox with two owners status=%d body=%s", status, response)
	}

	first := reportCopy{InboxID: ownerID, Rev: 1, Key: key1, Sealed: sealedWith(1)}
	second := reportCopy{InboxID: secondID, Rev: 1, Key: key2, Sealed: sealedWith(2)}

	// Refusals: a missing owner copy, a duplicate, a stale revision, a wrong
	// key, an unknown inbox, bad sealed bytes, a short report id, a
	// non-member, no copies.
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, first); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("one owner missing status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, first, first); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("duplicate copy status=%d body=%s", status, body)
	}
	stale := second
	stale.Rev = 2
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, first, stale); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("stale revision status=%d body=%s", status, body)
	}
	wrongKey := second
	wrongKey.Key = bytes.Repeat([]byte{9}, 32)
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, first, wrongKey); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("wrong key status=%d body=%s", status, body)
	}
	stranger := second
	stranger.InboxID = senderID
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, first, stranger); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("non-owner inbox status=%d body=%s", status, body)
	}
	for name, sealed := range map[string][]byte{
		"no magic":  append([]byte("XXXX"), bytes.Repeat([]byte{9}, 64)...),
		"too short": []byte("VRP1"),
		"too long":  append([]byte("VRP1"), bytes.Repeat([]byte{9}, 262196)...),
	} {
		bad := second
		bad.Sealed = sealed
		if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, first, bad); status != http.StatusBadRequest {
			t.Fatalf("%s: status=%d body=%s", name, status, body)
		}
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, "short", first, second); status != http.StatusBadRequest {
		t.Fatalf("short report id status=%d body=%s", status, body)
	}
	if status, _ := fileReport(t, handler, reporterToken, conversationID, reportIDOne); status != http.StatusBadRequest {
		t.Fatalf("no copies status=%d", status)
	}
	if status, _ := fileReport(t, handler, outsiderToken, conversationID, reportIDOne, first, second); status != http.StatusForbidden {
		t.Fatalf("outsider report status=%d", status)
	}

	// A good report: one stored copy per owner. The response echoes neither
	// the sealed bytes nor anything about a message.
	status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, first, second)
	if status != http.StatusCreated || strings.Contains(body, `"sealed"`) || !strings.Contains(body, `"copies":2`) {
		t.Fatalf("report status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, first, second); status != http.StatusConflict || !strings.Contains(body, "already_reported") {
		t.Fatalf("duplicate report status=%d body=%s", status, body)
	}

	// Each owner reads only their own copy, with its own sealed bytes. The
	// server holds no envelope id, sender or commitment for it.
	status, reports, raw := listReportsAs(t, handler, ownerToken, "inbox=instance_owner")
	if status != http.StatusOK || len(reports) != 1 {
		t.Fatalf("first owner list status=%d reports=%d", status, len(reports))
	}
	got := reports[0]
	if got.InboxKind != "instance_owner" || got.InboxID != ownerID || got.ReportID != reportIDOne || got.KeyRev != 1 || !bytes.Equal(got.RecipientPublicKey, key1) ||
		got.ConversationID != conversationID || got.ReporterAccountID != reporterID || !bytes.Equal(got.Sealed, first.Sealed) {
		t.Fatalf("unexpected report: %+v", got)
	}
	for _, field := range []string{"envelope_id", "frank_commit", "sender_account_id", "sender_device_id", "action_id"} {
		if strings.Contains(raw, field) {
			t.Fatalf("report names %s: %s", field, raw)
		}
	}
	status, secondReports, _ := listReportsAs(t, handler, secondToken, "inbox=instance_owner")
	if status != http.StatusOK || len(secondReports) != 1 || secondReports[0].InboxID != secondID || !bytes.Equal(secondReports[0].Sealed, second.Sealed) {
		t.Fatalf("second owner list status=%d reports=%+v", status, secondReports)
	}
	// No column of the table could hold the message's identity.
	rows, err := db.Query(`SELECT name FROM pragma_table_info('reports')`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(name, "envelope") || strings.Contains(name, "frank") || strings.Contains(name, "sender") || strings.Contains(name, "action") {
			t.Fatalf("reports has column %q", name)
		}
	}

	// Nobody else reads them: not the reporter, not the sender, not a bad inbox.
	for name, token := range map[string]string{"reporter": reporterToken, "sender": senderToken, "outsider": outsiderToken} {
		if status, _, _ := listReportsAs(t, handler, token, "inbox=instance_owner"); status != http.StatusForbidden {
			t.Fatalf("%s listed the owner inbox: %d", name, status)
		}
	}
	if status, _, _ := listReportsAs(t, handler, ownerToken, "inbox=moderators"); status != http.StatusBadRequest {
		t.Fatalf("bad inbox status=%d", status)
	}
	if status, _, _ := listReportsAs(t, handler, ownerToken, "inbox=community"); status != http.StatusBadRequest {
		t.Fatalf("community without id status=%d", status)
	}

	// Rotating one owner's key makes the old revision refuse.
	rotated := bytes.Repeat([]byte{6}, 32)
	if status, body := putReportKey(t, handler, ownerToken, rotated); status != http.StatusOK || !strings.Contains(body, `"key_rev":2`) {
		t.Fatalf("rotate status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, "rpt-0000000000000002", first, second); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("report to the old key status=%d body=%s", status, body)
	}
	first = reportCopy{InboxID: ownerID, Rev: 2, Key: rotated, Sealed: sealedWith(3)}
	if status, body := fileReport(t, handler, reporterToken, conversationID, "rpt-0000000000000002", first, second); status != http.StatusCreated {
		t.Fatalf("report to the new key status=%d body=%s", status, body)
	}

	// Dismissal is per copy and for people who can read that inbox; anyone
	// else sees a missing report.
	if status, _ := doJSON(t, handler, http.MethodDelete, "/api/v1/reports/"+got.ID, reporterToken, nil); status != http.StatusNotFound {
		t.Fatalf("reporter dismissal status=%d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodDelete, "/api/v1/reports/"+secondReports[0].ID, ownerToken, nil); status != http.StatusNotFound {
		t.Fatalf("one owner dismissed another's copy: %d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodDelete, "/api/v1/reports/"+got.ID, ownerToken, nil); status != http.StatusNoContent {
		t.Fatalf("owner dismissal status=%d", status)
	}
	if status, reports, _ := listReportsAs(t, handler, ownerToken, "inbox=instance_owner"); status != http.StatusOK || len(reports) != 1 {
		t.Fatalf("after dismissal status=%d reports=%d", status, len(reports))
	}
	if status, reports, _ := listReportsAs(t, handler, secondToken, "inbox=instance_owner"); status != http.StatusOK || len(reports) != 2 {
		t.Fatalf("the other owner lost a copy: status=%d reports=%d", status, len(reports))
	}

	// A copy older than 90 days is no longer listed (the sweeper removes it).
	if _, err := db.Exec(`UPDATE reports SET created_at = ? WHERE id = ?`, time.Now().UTC().Add(-91*24*time.Hour).Format("2006-01-02T15:04:05.000000000Z"), secondReports[0].ID); err != nil {
		t.Fatal(err)
	}
	if status, reports, _ := listReportsAs(t, handler, secondToken, "inbox=instance_owner"); status != http.StatusOK || len(reports) != 1 {
		t.Fatalf("expired copy still listed: status=%d reports=%d", status, len(reports))
	}

	// The audit log records that reports were filed, never what they held.
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/admin/audit-events", ownerToken, nil)
	if status != http.StatusOK || !strings.Contains(string(response), "report.filed") {
		t.Fatalf("audit status=%d body=%s", status, response)
	}
	for _, secret := range []string{base64.StdEncoding.EncodeToString(sealedWith(1)), reportIDOne} {
		if strings.Contains(string(response), secret) {
			t.Fatalf("audit log holds report content %q", secret)
		}
	}
}

func TestReportsAreCappedPerReporter(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	reporterToken, reporterID := registerMemberWithID(t, handler, ownerToken, "reporter")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, reporterID)
	capKey := bytes.Repeat([]byte{7}, 32)
	if status, _ := putReportKey(t, handler, ownerToken, capKey); status != http.StatusOK {
		t.Fatalf("publish status=%d", status)
	}
	var lastStatus int
	var lastBody string
	for i := 0; i < 21; i++ {
		lastStatus, lastBody = fileReport(t, handler, reporterToken, conversationID, "rpt-cap-"+strings.Repeat("x", 8)+string(rune('a'+i)), reportCopy{InboxID: ownerID, Rev: 1, Key: capKey, Sealed: sealedWith(byte(i))})
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

	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, response)
	}
	var community struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &community); err != nil {
		t.Fatal(err)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]interface{}{})
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

	// No route publishes a community inbox key yet (C4 distributes it), so
	// reporting is unavailable until one exists.
	communityKey := bytes.Repeat([]byte{3}, 32)
	community1 := reportCopy{InboxID: community.ID, Rev: 1, Key: communityKey, Sealed: sealedWith(5)}
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, community1); status != http.StatusConflict || !strings.Contains(body, "report_inbox_unavailable") {
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
	other := community1
	other.Key = bytes.Repeat([]byte{4}, 32)
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, other); status != http.StatusConflict || !strings.Contains(body, "report_inbox_changed") {
		t.Fatalf("report to another key status=%d body=%s", status, body)
	}
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, community1); status != http.StatusCreated {
		t.Fatalf("community report status=%d body=%s", status, body)
	}

	query := "inbox=community&community_id=" + community.ID
	for name, token := range map[string]string{"community owner": ownerToken, "moderator": modToken} {
		if status, reports, _ := listReportsAs(t, handler, token, query); status != http.StatusOK || len(reports) != 1 || reports[0].InboxKind != "community" || reports[0].InboxID != community.ID || !bytes.Equal(reports[0].RecipientPublicKey, communityKey) {
			t.Fatalf("%s list status=%d reports=%+v", name, status, reports)
		}
	}
	for name, token := range map[string]string{"reporter": reporterToken, "sender": senderToken} {
		if status, _, _ := listReportsAs(t, handler, token, query); status != http.StatusForbidden {
			t.Fatalf("%s listed the moderator inbox: %d", name, status)
		}
	}
	// The instance owners' inbox does not show community reports.
	if status, reports, _ := listReportsAs(t, handler, ownerToken, "inbox=instance_owner"); status != http.StatusOK || len(reports) != 0 {
		t.Fatalf("instance inbox status=%d reports=%d", status, len(reports))
	}
}

func TestReportEnvelopeRecordGoesToTheCopyHolderOnly(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	senderToken, senderID := registerMemberWithID(t, handler, ownerToken, "sender")
	reporterToken, reporterID := registerMemberWithID(t, handler, ownerToken, "reporter")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, senderID)
	addMember(t, handler, ownerToken, conversationID, reporterID)
	otherConversation := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, otherConversation, senderID)

	key := bytes.Repeat([]byte{7}, 32)
	if status, body := putReportKey(t, handler, ownerToken, key); status != http.StatusOK {
		t.Fatalf("publish status=%d body=%s", status, body)
	}
	commit := commitOf(0xcd)
	messageID, _ := frankedMessage(t, handler, senderToken, conversationID, "franked-r1", commit)
	otherID, _ := frankedMessage(t, handler, senderToken, otherConversation, "franked-r2", commitOf(0xee))
	if status, body := fileReport(t, handler, reporterToken, conversationID, reportIDOne, reportCopy{InboxID: ownerID, Rev: 1, Key: key, Sealed: sealedWith(1)}); status != http.StatusCreated {
		t.Fatalf("report status=%d body=%s", status, body)
	}
	status, reports, body := listReportsAs(t, handler, ownerToken, "inbox=instance_owner")
	if status != http.StatusOK || len(reports) != 1 {
		t.Fatalf("list status=%d body=%s", status, body)
	}
	path := "/api/v1/reports/" + reports[0].ID + "/envelope?envelope_id="

	status, response := doJSON(t, handler, http.MethodGet, path+messageID, ownerToken, nil)
	var record struct {
		EnvelopeID      string `json:"envelope_id"`
		SenderAccountID string `json:"sender_account_id"`
		SenderDeviceID  string `json:"sender_device_id"`
		FrankCommit     []byte `json:"frank_commit"`
	}
	if status != http.StatusOK || json.Unmarshal(response, &record) != nil || record.EnvelopeID != messageID || record.SenderAccountID != senderID || record.SenderDeviceID == "" || !bytes.Equal(record.FrankCommit, commit) {
		t.Fatalf("record status=%d body=%s", status, response)
	}
	// A message of another conversation, a missing id, the reporter and the
	// sender all learn nothing.
	if status, _ := doJSON(t, handler, http.MethodGet, path+otherID, ownerToken, nil); status != http.StatusNotFound {
		t.Fatalf("other conversation status=%d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, path+"no-such-envelope", ownerToken, nil); status != http.StatusNotFound {
		t.Fatalf("missing envelope status=%d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, path, ownerToken, nil); status != http.StatusBadRequest {
		t.Fatalf("empty envelope id status=%d", status)
	}
	for name, token := range map[string]string{"reporter": reporterToken, "sender": senderToken} {
		if status, _ := doJSON(t, handler, http.MethodGet, path+messageID, token, nil); status != http.StatusNotFound {
			t.Fatalf("%s status=%d", name, status)
		}
	}
}

func TestOwnerReadsOnlyTheirOwnCurrentReportKey(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	memberToken := registerMember(t, handler, ownerToken, "member")
	path := "/api/v1/reports/inbox-keys/instance"

	if status, _ := doJSON(t, handler, http.MethodGet, path, ownerToken, nil); status != http.StatusNotFound {
		t.Fatalf("before publish status=%d", status)
	}
	key1, key2 := bytes.Repeat([]byte{7}, 32), bytes.Repeat([]byte{8}, 32)
	if status, body := putReportKey(t, handler, ownerToken, key1); status != http.StatusOK {
		t.Fatalf("publish status=%d body=%s", status, body)
	}
	status, response := doJSON(t, handler, http.MethodGet, path, ownerToken, nil)
	if status != http.StatusOK || !strings.Contains(string(response), base64.StdEncoding.EncodeToString(key1)) || !strings.Contains(string(response), ownerID) || !strings.Contains(string(response), `"key_rev":1`) {
		t.Fatalf("own key status=%d body=%s", status, response)
	}
	// A replaced key is what is returned next, at its new revision.
	if status, body := putReportKey(t, handler, ownerToken, key2); status != http.StatusOK {
		t.Fatalf("replace status=%d body=%s", status, body)
	}
	status, response = doJSON(t, handler, http.MethodGet, path, ownerToken, nil)
	if status != http.StatusOK || !strings.Contains(string(response), base64.StdEncoding.EncodeToString(key2)) || !strings.Contains(string(response), `"key_rev":2`) {
		t.Fatalf("replaced key status=%d body=%s", status, response)
	}
	// Members get nothing, and no token gets nothing.
	if status, _ := doJSON(t, handler, http.MethodGet, path, memberToken, nil); status != http.StatusForbidden {
		t.Fatalf("member status=%d", status)
	}
	if status, _ := doJSON(t, handler, http.MethodGet, path, "", nil); status != http.StatusUnauthorized {
		t.Fatalf("anonymous status=%d", status)
	}
}
