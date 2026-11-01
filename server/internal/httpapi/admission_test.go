package httpapi_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/mlswire/mlswiretest"
)

func newLimitedHandler(t *testing.T, limits config.Limits) (http.Handler, string) {
	t.Helper()
	dir := t.TempDir()
	application, err := app.New(context.Background(), config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath: filepath.Join(dir, "blobs"), InstanceName: "Test Messenger", SetupToken: "test-setup-token",
		Limits: limits,
	}, nil)
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()
	enrollment := reserveEnrollment(t, handler, "/api/v1/setup/owner/enrollment", "")
	body := map[string]interface{}{
		"instance_name": "Test Messenger", "username": "owner", "password": "owner-password-123",
		"device_name": "owner phone", "device_key_package": mlswiretest.KeyPackage(),
	}
	addEnrollmentProof(body, enrollment)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", body)
	if status != http.StatusCreated {
		t.Fatalf("setup owner status=%d body=%s", status, response)
	}
	var decoded struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatal(err)
	}
	return handler, decoded.Token
}

// A burst of sends exhausts the account's delivery budget: the reservation
// covers a full conversation, the settlement only what was used, and the
// refusal is a 429 with Retry-After. Another account keeps its own budget.
func TestWriteBudgetRefusesBurstsPerAccount(t *testing.T) {
	handler, ownerToken := newLimitedHandler(t, config.Limits{ConversationMembers: 9, DeliveriesPerMinute: 60})
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "member")
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken,
		map[string]interface{}{"kind": "group", "member_account_ids": []string{memberID}})
	if status != http.StatusCreated {
		t.Fatalf("create group status=%d body=%s", status, response)
	}
	var conversation struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(response, &conversation)
	send := func(token string, i int) (int, http.Header) {
		raw, _ := json.Marshal(map[string]interface{}{
			"conversation_id": conversation.ID, "idempotency_key": fmt.Sprintf("burst-%s-%d", token[:6], i),
			"ciphertext": []byte("ciphertext"), "crypto_protocol": "mls10-openmls-v1",
		})
		recorder := doRawRecorder(t, handler, http.MethodPost, "/api/v1/messages/envelopes", token, raw)
		return recorder.Code, recorder.Header()
	}
	// 60 deliveries a minute; the group create cost 1 and each message 3
	// (the write and the two member accounts it is published to), with 10
	// reserved up front.
	admitted := 0
	var refusedHeader http.Header
	for i := 0; i < 40; i++ {
		code, header := send(ownerToken, i)
		if code == http.StatusCreated {
			admitted++
			continue
		}
		if code != http.StatusTooManyRequests {
			t.Fatalf("send %d status=%d", i, code)
		}
		refusedHeader = header
		break
	}
	if admitted < 15 || admitted > 30 || refusedHeader == nil {
		t.Fatalf("admitted %d sends before a refusal, want 15-30 and then a 429", admitted)
	}
	if wait, err := strconv.Atoi(refusedHeader.Get("Retry-After")); err != nil || wait < 1 || wait > 60 {
		t.Fatalf("Retry-After=%q", refusedHeader.Get("Retry-After"))
	}
	if code, _ := send(memberToken, 0); code != http.StatusCreated {
		t.Fatalf("other account refused with %d", code)
	}
}

func doRawRecorder(t *testing.T, handler http.Handler, method, path, token string, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

func containsBytes(body []byte, want string) bool { return bytes.Contains(body, []byte(want)) }

// Limit refusals name only the caller's own state.
func TestAdmissionLimitErrorsAreSpecificForTheCaller(t *testing.T) {
	handler, ownerToken := newLimitedHandler(t, config.Limits{ConversationMembers: 2, ConversationsPerAccount: 10})
	_, aliceID := registerMemberWithID(t, handler, ownerToken, "alice")
	_, bobID := registerMemberWithID(t, handler, ownerToken, "bob")
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken,
		map[string]interface{}{"kind": "group", "member_account_ids": []string{aliceID, bobID}})
	if status != http.StatusConflict || !json.Valid(response) || string(response) == "" {
		t.Fatalf("oversized group status=%d body=%s", status, response)
	}
	if want := `"conversation_member_limit_reached"`; !containsBytes(response, want) {
		t.Fatalf("oversized group body=%s", response)
	}
	for i := 0; i < 11; i++ {
		status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{"kind": "group"})
	}
	if status != http.StatusConflict || !containsBytes(response, `"conversation_limit_reached"`) {
		t.Fatalf("eleventh conversation status=%d body=%s", status, response)
	}
}
