package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
)

// L2-3 app step (docs/crypto.md, "As built"): an app from before sealed
// sender is never sent message.sealed.created, tokens are issued only while
// every member device reads sealed events, and the retry of a stored post
// answers 200 even after the conversation stopped taking sealed posts.

func syncEventTypes(t *testing.T, handler http.Handler, path, token string) []string {
	t.Helper()
	status, body := doJSON(t, handler, http.MethodGet, path, token, nil)
	if status != http.StatusOK {
		t.Fatalf("sync %s status=%d body=%s", path, status, body)
	}
	var page struct {
		Events []struct {
			Type string `json:"type"`
		} `json:"events"`
	}
	if err := json.Unmarshal(body, &page); err != nil {
		t.Fatal(err)
	}
	types := make([]string, 0, len(page.Events))
	for _, event := range page.Events {
		types = append(types, event.Type)
	}
	return types
}

func countType(types []string, want string) int {
	n := 0
	for _, got := range types {
		if got == want {
			n++
		}
	}
	return n
}

func TestOlderAppsAreNeverSentSealedEvents(t *testing.T) {
	handler, ownerToken, _, _ := sealedHandler(t, func(cfg *config.Config) { cfg.ScopedSync = true })
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealednew")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	sealedReaders(t, handler, ownerToken, memberToken)
	_, info := sealedInfo(t, handler, memberToken, conversationID)
	tokens, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 3)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}
	// A run of sealed posts longer than the page, then one identified post:
	// a device that did not opt in must get past the run to the post.
	for i, token := range tokens {
		key := "sealed-run-00000000000000" + string(rune('a'+i))
		if status, response := postSealed(t, handler, sealedPostBody(conversationID, token, key, []byte{byte(i + 1)}, nil)); status != http.StatusCreated {
			t.Fatalf("sealed post %d status=%d body=%s", i, status, response)
		}
	}
	createMessage(t, handler, ownerToken, conversationID, "after-the-sealed-run", []byte("identified"))

	for _, route := range []string{
		"/api/v1/sync/events?after=0&limit=2",
		"/api/v1/sync/events?after=0&limit=2&scan=bounded",
		"/api/v1/conversations/" + conversationID + "/sync-events?after=0&limit=2&scan=bounded",
	} {
		legacy := syncEventTypes(t, handler, route, memberToken)
		if countType(legacy, "message.sealed.created") != 0 {
			t.Fatalf("%s: an app without the opt-in got a sealed event: %v", route, legacy)
		}
		// Sealed rows are hidden rows: the page still reaches the post
		// after them (no wedge behind a run of sealed events).
		if countType(legacy, "message.envelope.created") != 1 {
			t.Fatalf("%s: the identified post after the run is missing: %v", route, legacy)
		}
		opted := syncEventTypes(t, handler, route+"&sealed=1", memberToken)
		if countType(opted, "message.sealed.created") == 0 {
			t.Fatalf("%s: the opt-in got no sealed event: %v", route, opted)
		}
	}
}

func TestSealedTokensWaitForEveryMemberDevice(t *testing.T) {
	handler, ownerToken, _, _ := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedgate")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)

	// Only the member's device reads sealed events; the owner's app is an
	// older one (it syncs without the opt-in).
	sealedReaders(t, handler, memberToken)
	if status, body := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=1", ownerToken, nil); status != http.StatusOK {
		t.Fatalf("legacy sync status=%d body=%s", status, body)
	}
	status, info := sealedInfo(t, handler, memberToken, conversationID)
	if status != http.StatusOK || info.Eligible {
		t.Fatalf("info with an older member device status=%d %+v", status, info)
	}
	if _, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 1); status != http.StatusConflict || !strings.Contains(body, "sealed_not_eligible") {
		t.Fatalf("issuance with an older member device status=%d body=%s", status, body)
	}

	// Once the owner's device reads sealed events too, tokens are issued.
	sealedReaders(t, handler, ownerToken)
	if _, info = sealedInfo(t, handler, memberToken, conversationID); !info.Eligible {
		t.Fatalf("info after every device opted in %+v", info)
	}
	if _, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 1); status != http.StatusOK {
		t.Fatalf("issuance after every device opted in status=%d body=%s", status, body)
	}
}

func TestSealedReadersAreNotRecordedWhileTheSwitchIsOff(t *testing.T) {
	_, handler, ownerToken, dbPath := newTestAppWithOwnerConfig(t, nil)
	if status, body := doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=1&sealed=1", ownerToken, nil); status != http.StatusOK {
		t.Fatalf("sync status=%d body=%s", status, body)
	}
	var n int
	if err := openSQLite(t, dbPath).QueryRow(`SELECT COUNT(*) FROM sealed_capable_devices`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("recorded %d err=%v", n, err)
	}
	// The setup status says whether the switch is on.
	if status, body := doJSON(t, handler, http.MethodGet, "/api/v1/setup/status", "", nil); status != http.StatusOK || bytes.Contains(body, []byte("sealed_sender")) {
		t.Fatalf("setup status with the switch off status=%d body=%s", status, body)
	}
	sealedOn, _, _, _ := sealedHandler(t, nil)
	if status, body := doJSON(t, sealedOn, http.MethodGet, "/api/v1/setup/status", "", nil); status != http.StatusOK || !bytes.Contains(body, []byte(`"sealed_sender":true`)) {
		t.Fatalf("setup status with the switch on status=%d body=%s", status, body)
	}
}

func TestSealedRetryOfAStoredPostOutlivesEligibility(t *testing.T) {
	handler, ownerToken, dbPath, _ := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedretry")
	leaverToken, leaverID := registerMemberWithID(t, handler, ownerToken, "sealedretryleave")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	addMember(t, handler, ownerToken, conversationID, leaverID)
	sealedReaders(t, handler, ownerToken, memberToken, leaverToken)
	_, info := sealedInfo(t, handler, memberToken, conversationID)
	tokens, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 2)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}
	post := sealedPostBody(conversationID, tokens[0], sealedKey1, []byte("stored once"), commitOf(0x11))
	status, first := postSealed(t, handler, post)
	if status != http.StatusCreated {
		t.Fatalf("post status=%d body=%s", status, first)
	}
	var stored struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(first, &stored); err != nil {
		t.Fatal(err)
	}
	db := openSQLite(t, dbPath)

	// A member leaves, then posting turns
	// admins-only: the answer was lost, and the app retries the same post.
	if _, err := db.Exec(`DELETE FROM memberships WHERE conversation_id = ? AND account_id = ?`, conversationID, leaverID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE conversations SET posting_policy = 'admins' WHERE id = ?`, conversationID); err != nil {
		t.Fatal(err)
	}
	status, retry := postSealed(t, handler, post)
	if status != http.StatusOK || !bytes.Contains(retry, []byte(stored.ID)) {
		t.Fatalf("retry status=%d body=%s", status, retry)
	}
	// A new post is still refused, and spends nothing.
	fresh := sealedPostBody(conversationID, tokens[1], "sealed-key-000000000000009", []byte("new"), nil)
	if status, response := postSealed(t, handler, fresh); status != http.StatusConflict || !strings.Contains(string(response), "sealed_not_eligible") {
		t.Fatalf("new post status=%d body=%s", status, response)
	}
	var spent int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sealed_spent_tokens`).Scan(&spent); err != nil || spent != 1 {
		t.Fatalf("spent %d err=%v", spent, err)
	}
	// The retry with other bytes under the stored key is still a conflict.
	changed := sealedPostBody(conversationID, tokens[1], sealedKey1, []byte("other bytes"), commitOf(0x11))
	if status, response := postSealed(t, handler, changed); status != http.StatusConflict || !strings.Contains(string(response), "idempotency_conflict") {
		t.Fatalf("changed retry status=%d body=%s", status, response)
	}
}

// Review M2: redemption checks the issuance gate too. A device that cannot
// read sealed events (linked, or an older app, after the tokens were
// issued) closes it: a new sealed post is refused with sealed_not_eligible
// and stores, spends and syncs nothing, so the app may send that message
// identified; a post stored before still answers its retry with 200.
func TestSealedRedemptionWaitsForEveryMemberDevice(t *testing.T) {
	handler, ownerToken, dbPath, _ := sealedHandler(t, nil)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "sealedgate2")
	conversationID := createConversation(t, handler, ownerToken)
	addMember(t, handler, ownerToken, conversationID, memberID)
	sealedReaders(t, handler, ownerToken, memberToken)
	_, info := sealedInfo(t, handler, memberToken, conversationID)
	tokens, status, body := requestSealedTokens(t, handler, memberToken, conversationID, info.Epoch, 2)
	if status != http.StatusOK {
		t.Fatalf("tokens status=%d body=%s", status, body)
	}
	stored := sealedPostBody(conversationID, tokens[0], sealedKey1, []byte("before the gate"), nil)
	if status, response := postSealed(t, handler, stored); status != http.StatusCreated {
		t.Fatalf("post status=%d body=%s", status, response)
	}
	// The owner's device stops counting as one that reads sealed events.
	db := openSQLite(t, dbPath)
	if _, err := db.Exec(`DELETE FROM sealed_capable_devices WHERE device_id IN (SELECT d.id FROM devices d JOIN memberships m ON m.account_id = d.account_id WHERE m.conversation_id = ? AND m.role = 'owner')`, conversationID); err != nil {
		t.Fatal(err)
	}
	if status, retry := postSealed(t, handler, stored); status != http.StatusOK {
		t.Fatalf("retry of a stored post status=%d body=%s", status, retry)
	}
	var eventsBefore int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'message.sealed.created'`).Scan(&eventsBefore); err != nil {
		t.Fatal(err)
	}
	fresh := sealedPostBody(conversationID, tokens[1], "sealed-key-000000000000077", []byte("after the gate"), nil)
	if status, response := postSealed(t, handler, fresh); status != http.StatusConflict || !strings.Contains(string(response), "sealed_not_eligible") {
		t.Fatalf("post with the gate closed status=%d body=%s", status, response)
	}
	var envelopes, spent, events int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sealed_message_envelopes WHERE idempotency_key = 'sealed-key-000000000000077'`).Scan(&envelopes); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM sealed_spent_tokens`).Scan(&spent); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'message.sealed.created'`).Scan(&events); err != nil {
		t.Fatal(err)
	}
	if envelopes != 0 || spent != 1 || events != eventsBefore {
		t.Fatalf("refused post left envelopes=%d spent=%d events=%d (was %d)", envelopes, spent, events, eventsBefore)
	}
	// The same message may now go identified under the same key.
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", memberToken, map[string]interface{}{
		"conversation_id": conversationID,
		"idempotency_key": "sealed-key-000000000000077",
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("identified now")),
		"crypto_protocol": "mls10-openmls-v1",
	})
	if status != http.StatusCreated {
		t.Fatalf("identified fallback status=%d body=%s", status, response)
	}
	// And a delayed sealed copy of it can no longer land.
	sealedReaders(t, handler, ownerToken)
	if status, response := postSealed(t, handler, fresh); status != http.StatusConflict || !strings.Contains(string(response), "idempotency_conflict") {
		t.Fatalf("late sealed copy status=%d body=%s", status, response)
	}
}
