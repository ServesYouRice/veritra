package httpapi_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/config"
)

func TestMessageAPIRejectsPlaintextFields(t *testing.T) {
	handler, token, dbPath := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, token)
	sentinel := runtimeSentinel(t)

	body := map[string]interface{}{
		"conversation_id": conversationID,
		"idempotency_key": "send-plaintext",
		"body":            sentinel,
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext")),
		"crypto_protocol": "mls10-openmls-v1",
	}
	status, _ := doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", token, body)
	if status != http.StatusBadRequest {
		t.Fatalf("status=%d want %d", status, http.StatusBadRequest)
	}
	nested := map[string]interface{}{
		"conversation_id": conversationID,
		"idempotency_key": "send-nested-plaintext",
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext")),
		"crypto_protocol": "mls10-openmls-v1",
		"crypto_metadata": map[string]interface{}{"body": sentinel},
	}
	status, _ = doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", token, nested)
	if status != http.StatusBadRequest {
		t.Fatalf("nested status=%d want %d", status, http.StatusBadRequest)
	}
	dbBytes, err := os.ReadFile(dbPath)
	if err != nil {
		t.Fatalf("read db: %v", err)
	}
	if bytes.Contains(dbBytes, []byte(sentinel)) {
		t.Fatal("rejected plaintext sentinel was persisted")
	}
}

func runtimeSentinel(t *testing.T) string {
	t.Helper()
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return "PLAINTEXT_SENTINEL_" + hex.EncodeToString(b[:])
}

func TestMessageAPIAcceptsCiphertextEnvelope(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, token)
	body := map[string]interface{}{
		"conversation_id": conversationID,
		"idempotency_key": "send-ciphertext",
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext")),
		"crypto_protocol": "mls10-openmls-v1",
	}
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", token, body)
	if status != http.StatusCreated {
		t.Fatalf("status=%d body=%s", status, response)
	}
}

func TestJSONDecodeRejectsTrailingDocument(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/conversations", token, []byte(`{"kind":"group"}{"kind":"group"}`), map[string]string{
		"Content-Type": "application/json",
	})
	if status != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte("invalid_json")) {
		t.Fatalf("response missing invalid_json: %s", response)
	}
}

func TestMessageLifecycleAndSyncRoutes(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, token)
	messageID := createMessage(t, handler, token, conversationID, "lifecycle-1", []byte("ciphertext-v1"))

	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+messageID+"/edit", token, map[string]interface{}{
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext-v2")),
		"crypto_protocol": "mls10-openmls-v1",
	})
	if status != http.StatusOK {
		t.Fatalf("edit status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte(`"edited_at"`)) {
		t.Fatalf("edit response missing edited marker: %s", response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+messageID+"/reactions", token, map[string]interface{}{
		"reaction_ciphertext": base64.StdEncoding.EncodeToString([]byte("encrypted reaction")),
		"crypto_protocol":     "mls10-openmls-v1",
	})
	if status != http.StatusNoContent {
		t.Fatalf("reaction status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/read-receipts", token, map[string]interface{}{"message_id": messageID})
	if status != http.StatusNoContent {
		t.Fatalf("read receipt status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+messageID+"/delete", token, map[string]interface{}{
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("encrypted delete marker")),
		"crypto_protocol": "mls10-openmls-v1",
	})
	if status != http.StatusOK {
		t.Fatalf("delete status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte(`"deleted_at"`)) {
		t.Fatalf("delete response missing deleted marker: %s", response)
	}

	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0", token, nil)
	if status != http.StatusOK {
		t.Fatalf("sync events status=%d body=%s", status, response)
	}
	for _, eventType := range []string{"message.envelope.created", "message.envelope.edited", "reaction.created", "read_receipt.updated", "message.envelope.deleted"} {
		if !bytes.Contains(response, []byte(eventType)) {
			t.Fatalf("sync response missing %s: %s", eventType, response)
		}
	}
}

func TestConversationScopedWritesRequireMembership(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, ownerToken)
	messageID := createMessage(t, handler, ownerToken, conversationID, "owner-only", []byte("ciphertext"))
	memberToken := registerMember(t, handler, ownerToken, "outsider")
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/devices/me", memberToken, nil)
	if status != http.StatusOK {
		t.Fatalf("member device status=%d body=%s", status, response)
	}
	var memberDevices struct {
		Devices []struct {
			ID string `json:"id"`
		} `json:"devices"`
	}
	if err := json.Unmarshal(response, &memberDevices); err != nil || len(memberDevices.Devices) != 1 {
		t.Fatalf("decode member device: %v", err)
	}

	status, response = doRaw(t, handler, http.MethodPost, "/api/v1/attachments?conversation_id="+conversationID, memberToken, []byte("encrypted attachment"), map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Crypto-Metadata":             `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576}`,
	})
	if status != http.StatusForbidden {
		t.Fatalf("attachment status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/calls", memberToken, map[string]interface{}{
		"conversation_id": conversationID,
		"metadata": map[string]interface{}{
			"version": 1, "ciphertext": base64.StdEncoding.EncodeToString([]byte("encrypted call")),
			"protocol": "mls10-openmls-v1", "sender_device_id": memberDevices.Devices[0].ID, "action_id": "call-action",
		},
	})
	if status != http.StatusForbidden {
		t.Fatalf("call status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+messageID+"/reactions", memberToken, map[string]interface{}{
		"reaction_ciphertext": base64.StdEncoding.EncodeToString([]byte("encrypted reaction")),
		"crypto_protocol":     "mls10-openmls-v1",
	})
	if status != http.StatusForbidden {
		t.Fatalf("reaction status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/read-receipts", memberToken, map[string]interface{}{"message_id": messageID})
	if status != http.StatusForbidden {
		t.Fatalf("read receipt status=%d body=%s", status, response)
	}
}

func TestMetadataSearchBackupExportAndAccountDelete(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, token)
	searchOnlyCiphertext := []byte("SEARCH_ONLY_CIPHERTEXT")
	createMessage(t, handler, token, conversationID, "search-only", searchOnlyCiphertext)

	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/search/metadata?q=owner", token, nil)
	if status != http.StatusOK {
		t.Fatalf("search status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte(`"type":"account"`)) {
		t.Fatalf("search did not include account metadata: %s", response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/search/metadata?q=owner&limit=1&offset=0", token, nil)
	if status != http.StatusOK {
		t.Fatalf("paginated search status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte(`"limit":1`)) || !bytes.Contains(response, []byte(`"offset":0`)) || !bytes.Contains(response, []byte(`"next_offset":1`)) {
		t.Fatalf("paginated search missing pagination metadata: %s", response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/search/metadata?q=SEARCH_ONLY_CIPHERTEXT", token, nil)
	if status != http.StatusOK {
		t.Fatalf("ciphertext search status=%d body=%s", status, response)
	}
	if bytes.Contains(response, []byte("SEARCH_ONLY_CIPHERTEXT")) {
		t.Fatalf("metadata search returned ciphertext content: %s", response)
	}

	status, response = doRaw(t, handler, http.MethodPost, "/api/v1/backups", token, []byte("encrypted backup blob"), map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Key-Derivation-Metadata":     `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`,
		"X-Recovery-Token":              base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32)),
	})
	if status != http.StatusCreated {
		t.Fatalf("backup status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/account/export", token, nil)
	if status != http.StatusOK {
		t.Fatalf("export status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte(`"messages"`)) {
		t.Fatalf("export missing encrypted message envelopes: %s", response)
	}

	status, response = doJSON(t, handler, http.MethodDelete, "/api/v1/account", token, nil)
	if status != http.StatusConflict {
		t.Fatalf("delete account status=%d body=%s", status, response)
	}
	status, _ = doJSON(t, handler, http.MethodGet, "/api/v1/conversations", token, nil)
	if status != http.StatusOK {
		t.Fatalf("last owner token status=%d want %d", status, http.StatusOK)
	}
}

func TestAttachmentInvalidMetadataDoesNotWriteBlob(t *testing.T) {
	handler, token, dbPath := newTestHandlerWithOwner(t)
	blobDir := filepath.Join(filepath.Dir(dbPath), "blobs")
	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/attachments", token, []byte("encrypted attachment"), map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Crypto-Metadata":             "{",
	})
	if status != http.StatusBadRequest {
		t.Fatalf("attachment status=%d body=%s", status, response)
	}
	entries, err := os.ReadDir(blobDir)
	if err != nil {
		t.Fatalf("read blob dir: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("invalid attachment metadata wrote blobs: %#v", entries)
	}
}

func TestAttachmentDownloadRangeAuthorizationAndIntegrity(t *testing.T) {
	handler, ownerToken, dbPath := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, ownerToken)
	payload := []byte("encrypted attachment payload")
	status, response := doRaw(t, handler, http.MethodPost, "/api/v1/attachments?conversation_id="+conversationID, ownerToken, payload, map[string]string{
		"X-Private-Messenger-Encrypted": "1",
		"X-Crypto-Metadata":             `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576}`,
	})
	if status != http.StatusCreated {
		t.Fatalf("upload status=%d body=%s", status, response)
	}
	var attachment struct {
		ID         string `json:"id"`
		StorageKey string `json:"storage_key"`
	}
	if err := json.Unmarshal(response, &attachment); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/attachments/"+attachment.ID, nil)
	req.Header.Set("Authorization", "Bearer "+ownerToken)
	req.Header.Set("Range", "bytes=10-19")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusPartialContent || !bytes.Equal(rec.Body.Bytes(), payload[10:20]) {
		t.Fatalf("range status=%d body=%q", rec.Code, rec.Body.Bytes())
	}
	if got := rec.Header().Get("Content-Range"); got != "bytes 10-19/28" {
		t.Fatalf("Content-Range = %q", got)
	}

	outsiderToken := registerMember(t, handler, ownerToken, "download-outsider")
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/attachments/"+attachment.ID, outsiderToken, nil)
	if status != http.StatusNotFound {
		t.Fatalf("outsider status=%d body=%s", status, response)
	}

	if err := os.Truncate(filepath.Join(filepath.Dir(dbPath), "blobs", attachment.StorageKey), int64(len(payload)-1)); err != nil {
		t.Fatal(err)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/attachments/"+attachment.ID, ownerToken, nil)
	if status != http.StatusInternalServerError || !bytes.Contains(response, []byte("blob_integrity_failed")) {
		t.Fatalf("truncated status=%d body=%s", status, response)
	}
}

func TestPasswordLoginRequiresExplicitDeviceID(t *testing.T) {
	handler, _, _ := newTestHandlerWithOwner(t)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/auth/login", "", map[string]interface{}{
		"username": "owner",
		"password": "owner-password-123",
	})
	if status != http.StatusBadRequest {
		t.Fatalf("login status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte("device_id_required")) {
		t.Fatalf("login response missing device_id_required: %s", response)
	}
}

func TestLogoutAndDeviceRevocationInvalidateSessions(t *testing.T) {
	handler, token, deviceID := newTestHandlerWithOwnerDevice(t)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/auth/logout", token, map[string]interface{}{})
	if status != http.StatusNoContent {
		t.Fatalf("logout status=%d body=%s", status, response)
	}
	status, _ = doJSON(t, handler, http.MethodGet, "/api/v1/conversations", token, nil)
	if status != http.StatusUnauthorized {
		t.Fatalf("logged-out token status=%d want %d", status, http.StatusUnauthorized)
	}

	handler, token, deviceID = newTestHandlerWithOwnerDevice(t)
	status, response = doJSON(t, handler, http.MethodDelete, "/api/v1/devices/"+deviceID, token, nil)
	if status != http.StatusNoContent {
		t.Fatalf("revoke status=%d body=%s", status, response)
	}
	status, _ = doJSON(t, handler, http.MethodGet, "/api/v1/conversations", token, nil)
	if status != http.StatusUnauthorized {
		t.Fatalf("revoked-device token status=%d want %d", status, http.StatusUnauthorized)
	}
}

func TestSetupRejectsNonProductionKeyPackage(t *testing.T) {
	dir := t.TempDir()
	application, err := app.New(context.Background(), config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Test Messenger",
		SetupToken:   "test-setup-token",
	}, nil)
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() { _ = application.Close() })
	status, response := doJSON(t, application.Handler(), http.MethodPost, "/api/v1/setup/owner", "", map[string]interface{}{
		"instance_name":      "Test Messenger",
		"username":           "owner",
		"password":           "owner-password-123",
		"device_name":        "setup browser",
		"device_key_package": base64.StdEncoding.EncodeToString([]byte("setup-non-production-key-package-placeholder")),
	})
	if status != http.StatusBadRequest {
		t.Fatalf("setup status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte("non_production_device_key_package")) {
		t.Fatalf("setup response missing non_production_device_key_package: %s", response)
	}
}

func TestLoginBackoffIsBoundedAndAccountPrivacySafe(t *testing.T) {
	handler, _, deviceID := newTestHandlerWithOwnerDevice(t)
	for _, username := range []string{"owner", "missing-account"} {
		for attempt := 1; attempt <= 3; attempt++ {
			body, err := json.Marshal(map[string]interface{}{
				"username":      username,
				"password":      "wrong-password",
				"device_id":     deviceID,
				"device_secret": "wrong-device-secret",
			})
			if err != nil {
				t.Fatal(err)
			}
			request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", bytes.NewReader(body))
			request.Header.Set("Content-Type", "application/json")
			recorder := httptest.NewRecorder()
			handler.ServeHTTP(recorder, request)
			if attempt < 3 && recorder.Code != http.StatusUnauthorized {
				t.Fatalf("username=%q attempt=%d status=%d body=%s", username, attempt, recorder.Code, recorder.Body.String())
			}
			if attempt == 3 {
				if recorder.Code != http.StatusTooManyRequests || !bytes.Contains(recorder.Body.Bytes(), []byte(`"error":"login_backoff"`)) {
					t.Fatalf("username=%q backoff status=%d body=%s", username, recorder.Code, recorder.Body.String())
				}
				retryAfter, err := strconv.Atoi(recorder.Header().Get("Retry-After"))
				if err != nil || retryAfter < 1 || retryAfter > 60 {
					t.Fatalf("username=%q Retry-After=%q err=%v", username, recorder.Header().Get("Retry-After"), err)
				}
			}
		}
	}
}

func TestSetupRejectsInvalidUsername(t *testing.T) {
	dir := t.TempDir()
	application, err := app.New(context.Background(), config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Test Messenger",
		SetupToken:   "test-setup-token",
	}, nil)
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()
	for _, username := range []string{"ab", "own er", "own.er", "аwner"} {
		status, response := doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", map[string]interface{}{
			"instance_name":      "Test Messenger",
			"username":           username,
			"password":           "owner-password-123",
			"device_name":        "owner phone",
			"device_key_package": base64.StdEncoding.EncodeToString([]byte("owner-key-package")),
		})
		if status != http.StatusBadRequest {
			t.Fatalf("username=%q setup status=%d want %d body=%s", username, status, http.StatusBadRequest, response)
		}
		if !bytes.Contains(response, []byte("invalid_identity")) {
			t.Fatalf("username=%q response missing invalid_identity: %s", username, response)
		}
	}
}

func TestDeviceLinkingFlowRequiresExistingDeviceApproval(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)

	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/device-links", ownerToken, map[string]interface{}{})
	if status != http.StatusCreated {
		t.Fatalf("create device link status=%d body=%s", status, response)
	}
	var created struct {
		DeviceLink struct {
			ID                 string `json:"id"`
			Code               string `json:"code"`
			State              string `json:"state"`
			ProtocolVersion    string `json:"protocol_version"`
			LinkNonce          []byte `json:"link_nonce"`
			ExistingSigningKey []byte `json:"existing_signing_key"`
		} `json:"device_link"`
	}
	if err := json.Unmarshal(response, &created); err != nil {
		t.Fatalf("decode device link: %v", err)
	}
	if created.DeviceLink.ID == "" || created.DeviceLink.Code == "" || created.DeviceLink.ProtocolVersion == "" || len(created.DeviceLink.LinkNonce) != 32 || len(created.DeviceLink.ExistingSigningKey) != 32 {
		t.Fatalf("created link missing fields: %s", response)
	}

	enrollment := reserveEnrollment(
		t, handler, "/api/v1/device-links/claim-enrollment", created.DeviceLink.Code,
	)
	claimBody := map[string]interface{}{
		"code":               created.DeviceLink.Code,
		"device_name":        "linked tablet",
		"device_key_package": make([]byte, 64),
		"transcript_hash":    bytes.Repeat([]byte{7}, 32),
	}
	addEnrollmentProof(claimBody, enrollment)
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/device-links/claim", "", claimBody)
	if status != http.StatusAccepted {
		t.Fatalf("claim device link status=%d body=%s", status, response)
	}
	var claimed struct {
		ClaimToken string `json:"claim_token"`
		DeviceLink struct {
			State          string `json:"state"`
			TranscriptHash []byte `json:"transcript_hash"`
		} `json:"device_link"`
	}
	if err := json.Unmarshal(response, &claimed); err != nil {
		t.Fatalf("decode claimed device link: %v", err)
	}
	if claimed.ClaimToken == "" || claimed.DeviceLink.State != "claimed" || !bytes.Equal(claimed.DeviceLink.TranscriptHash, bytes.Repeat([]byte{7}, 32)) {
		t.Fatalf("unexpected claimed response: %s", response)
	}

	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/device-links/"+created.DeviceLink.ID, ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("device link status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte(`"claimed_device_name":"linked tablet"`)) {
		t.Fatalf("device link status missing claimed device: %s", response)
	}

	status, response = doRaw(t, handler, http.MethodGet, "/api/v1/device-links/"+created.DeviceLink.ID+"/claim-status", "", nil, map[string]string{
		"X-Veritra-Claim-Token": claimed.ClaimToken,
	})
	if status != http.StatusAccepted {
		t.Fatalf("pre-approval claim status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/device-links/"+created.DeviceLink.ID+"/approve", ownerToken, map[string]interface{}{
		"transcript_hash": bytes.Repeat([]byte{8}, 32),
	})
	if status != http.StatusBadRequest || !bytes.Contains(response, []byte("transcript_mismatch")) {
		t.Fatalf("substituted transcript approval status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/device-links/"+created.DeviceLink.ID+"/approve", ownerToken, map[string]interface{}{
		"transcript_hash": bytes.Repeat([]byte{7}, 32),
	})
	if status != http.StatusOK {
		t.Fatalf("approve device link status=%d body=%s", status, response)
	}
	if !bytes.Contains(response, []byte(`"device"`)) {
		t.Fatalf("approve response missing device: %s", response)
	}

	status, response = doRaw(t, handler, http.MethodGet, "/api/v1/device-links/"+created.DeviceLink.ID+"/claim-status", "", nil, map[string]string{
		"X-Veritra-Claim-Token": claimed.ClaimToken,
	})
	if status != http.StatusOK {
		t.Fatalf("approved claim status=%d body=%s", status, response)
	}
	var completed struct {
		Token          string `json:"token"`
		TranscriptHash []byte `json:"transcript_hash"`
		Device         struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"device"`
	}
	if err := json.Unmarshal(response, &completed); err != nil {
		t.Fatalf("decode completed link: %v", err)
	}
	if completed.Token == "" || completed.Device.ID == "" || completed.Device.Name != "linked tablet" || !bytes.Equal(completed.TranscriptHash, bytes.Repeat([]byte{7}, 32)) {
		t.Fatalf("unexpected completed link: %s", response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/devices/me", completed.Token, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte("linked tablet")) {
		t.Fatalf("linked token devices status=%d body=%s", status, response)
	}
}

func TestListMessagesCursorPagination(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	conversationID := createConversation(t, handler, token)
	var ids []string
	for i := 0; i < 5; i++ {
		ids = append(ids, createMessage(t, handler, token, conversationID, "page-"+strconv.Itoa(i), []byte("ciphertext")))
	}
	type pageT struct {
		Messages []struct {
			ID string `json:"id"`
		} `json:"messages"`
		NextBefore string `json:"next_before"`
	}
	fetch := func(t *testing.T, path string) pageT {
		t.Helper()
		status, response := doJSON(t, handler, http.MethodGet, path, token, nil)
		if status != http.StatusOK {
			t.Fatalf("%s status=%d body=%s", path, status, response)
		}
		var p pageT
		if err := json.Unmarshal(response, &p); err != nil {
			t.Fatalf("decode %s: %v body=%s", path, err, response)
		}
		return p
	}
	// page 1: newest 2 → ids[4], ids[3]; next_before should be ids[3]
	page1 := fetch(t, "/api/v1/conversations/"+conversationID+"/messages?limit=2")
	if len(page1.Messages) != 2 || page1.Messages[0].ID != ids[4] || page1.Messages[1].ID != ids[3] {
		t.Fatalf("page 1 ordering wrong: %#v", page1.Messages)
	}
	if page1.NextBefore != ids[3] {
		t.Fatalf("page 1 next_before=%q want %q", page1.NextBefore, ids[3])
	}
	// page 2 via the cursor: should give ids[2], ids[1]
	page2 := fetch(t, "/api/v1/conversations/"+conversationID+"/messages?limit=2&before="+page1.NextBefore)
	if len(page2.Messages) != 2 || page2.Messages[0].ID != ids[2] || page2.Messages[1].ID != ids[1] {
		t.Fatalf("page 2 ordering wrong: %#v", page2.Messages)
	}
	if page2.NextBefore != ids[1] {
		t.Fatalf("page 2 next_before=%q want %q", page2.NextBefore, ids[1])
	}
	// page 3: last item, no further cursor
	page3 := fetch(t, "/api/v1/conversations/"+conversationID+"/messages?limit=2&before="+page2.NextBefore)
	if len(page3.Messages) != 1 || page3.Messages[0].ID != ids[0] {
		t.Fatalf("page 3 wrong: %#v", page3.Messages)
	}
	if page3.NextBefore != "" {
		t.Fatalf("page 3 should not advertise more, got next_before=%q", page3.NextBefore)
	}
}

func TestConversationKeyPackageClaimsAreAuthorizedAndSingleUse(t *testing.T) {
	handler, ownerToken, ownerDeviceID := newTestHandlerWithOwnerDevice(t)
	_, memberAccountID := registerMemberWithID(t, handler, ownerToken, "claimmember")
	outsiderToken := registerMember(t, handler, ownerToken, "claimoutsider")

	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{
		"kind":               "group",
		"member_account_ids": []string{memberAccountID},
	})
	if status != http.StatusCreated {
		t.Fatalf("create conversation status=%d body=%s", status, response)
	}
	var conversation struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &conversation); err != nil {
		t.Fatalf("decode conversation: %v", err)
	}
	claimPath := "/api/v1/conversations/" + conversation.ID + "/key-packages/claim"

	status, response = doJSON(t, handler, http.MethodPost, claimPath, outsiderToken, nil)
	if status != http.StatusForbidden || !bytes.Contains(response, []byte(`"error":"forbidden"`)) {
		t.Fatalf("non-member claim status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, claimPath, ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("member claim status=%d body=%s", status, response)
	}
	var claimed struct {
		KeyPackages []struct {
			DeviceID string `json:"device_id"`
		} `json:"key_packages"`
	}
	if err := json.Unmarshal(response, &claimed); err != nil {
		t.Fatalf("decode key packages: %v", err)
	}
	if len(claimed.KeyPackages) != 1 || claimed.KeyPackages[0].DeviceID == ownerDeviceID {
		t.Fatalf("claim did not exclude requester device: %s", response)
	}

	status, response = doJSON(t, handler, http.MethodPost, claimPath, ownerToken, nil)
	if status != http.StatusConflict || !bytes.Contains(response, []byte(`"error":"key_package_unavailable"`)) {
		t.Fatalf("repeated claim status=%d body=%s", status, response)
	}
}

func TestDMAndGroupMembershipLifecycleAPI(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "apilifemember")
	outsiderToken, outsiderID := registerMemberWithID(t, handler, ownerToken, "apilifeoutsider")

	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{
		"kind":               "dm",
		"member_account_ids": []string{memberID},
	})
	if status != http.StatusCreated {
		t.Fatalf("create DM status=%d body=%s", status, response)
	}
	var dm struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &dm); err != nil {
		t.Fatalf("decode DM: %v", err)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations", memberToken, map[string]interface{}{
		"kind":               "dm",
		"member_account_ids": []string{ownerID},
	})
	if status != http.StatusCreated {
		t.Fatalf("retry DM status=%d body=%s", status, response)
	}
	var retriedDM struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &retriedDM); err != nil || retriedDM.ID != dm.ID {
		t.Fatalf("retry DM=%#v err=%v want id=%s", retriedDM, err, dm.ID)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+dm.ID+"/members", ownerToken, map[string]interface{}{"account_id": outsiderID})
	if status != http.StatusForbidden {
		t.Fatalf("third DM member status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+dm.ID+"/members", memberToken, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte(ownerID)) || !bytes.Contains(response, []byte(memberID)) {
		t.Fatalf("authorized DM roster status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+dm.ID+"/members", outsiderToken, nil)
	if status != http.StatusForbidden {
		t.Fatalf("outsider DM roster status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{
		"kind":               "group",
		"member_account_ids": []string{memberID},
	})
	if status != http.StatusCreated {
		t.Fatalf("create group status=%d body=%s", status, response)
	}
	var group struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &group); err != nil {
		t.Fatalf("decode group: %v", err)
	}
	status, response = doJSON(t, handler, http.MethodDelete, "/api/v1/conversations/"+group.ID+"/members/me", ownerToken, nil)
	if status != http.StatusConflict || !bytes.Contains(response, []byte(`"error":"last_owner_required"`)) {
		t.Fatalf("last owner leave status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodDelete, "/api/v1/conversations/"+group.ID+"/members/me", memberToken, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte(`"mls_coordination":"pending"`)) {
		t.Fatalf("member leave status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+group.ID+"/members", memberToken, nil)
	if status != http.StatusForbidden {
		t.Fatalf("departed member roster status=%d body=%s", status, response)
	}
}

func TestSingleMessageRepairIsScopedAndIncludesOldDeleteMarkers(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwnerDevice(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "repairmember")
	outsiderToken := registerMember(t, handler, ownerToken, "repairoutsider")
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{
		"kind":               "group",
		"member_account_ids": []string{memberID},
	})
	if status != http.StatusCreated {
		t.Fatalf("create repair conversation status=%d body=%s", status, response)
	}
	var conversation struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &conversation); err != nil {
		t.Fatalf("decode conversation: %v", err)
	}
	oldID := createMessage(t, handler, ownerToken, conversation.ID, "repair-old", []byte("old ciphertext"))
	newestID := createMessage(t, handler, ownerToken, conversation.ID, "repair-new", []byte("new ciphertext"))
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+oldID+"/edit", ownerToken, map[string]interface{}{
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("edited old ciphertext")),
		"crypto_protocol": "mls10-openmls-v1",
	})
	if status != http.StatusOK {
		t.Fatalf("edit old message status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/conversations/"+conversation.ID+"/messages?limit=1", memberToken, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte(newestID)) || bytes.Contains(response, []byte(oldID)) {
		t.Fatalf("newest page status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/messages/"+oldID, memberToken, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte(base64.StdEncoding.EncodeToString([]byte("edited old ciphertext")))) {
		t.Fatalf("authorized old lookup status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/messages/"+oldID, outsiderToken, nil)
	if status != http.StatusNotFound {
		t.Fatalf("outsider old lookup status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/messages/msg_missing", memberToken, nil)
	if status != http.StatusNotFound {
		t.Fatalf("missing lookup status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/messages/"+oldID+"/delete", ownerToken, map[string]interface{}{
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("encrypted delete marker")),
		"crypto_protocol": "mls10-openmls-v1",
	})
	if status != http.StatusOK {
		t.Fatalf("delete old message status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/messages/"+oldID, memberToken, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte(`"deleted_at"`)) || !bytes.Contains(response, []byte(base64.StdEncoding.EncodeToString([]byte("encrypted delete marker")))) {
		t.Fatalf("deleted marker lookup status=%d body=%s", status, response)
	}
}

func newTestHandlerWithOwner(t *testing.T) (http.Handler, string, string) {
	t.Helper()
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "private-messenger.db")
	application, err := app.New(context.Background(), config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: dbPath,
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Test Messenger",
		SetupToken:   "test-setup-token",
	}, nil)
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()
	enrollment := reserveEnrollment(t, handler, "/api/v1/setup/owner/enrollment", "")
	body := map[string]interface{}{
		"instance_name":      "Test Messenger",
		"username":           "owner",
		"password":           "owner-password-123",
		"device_name":        "owner phone",
		"device_key_package": make([]byte, 64),
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
		t.Fatalf("decode setup response: %v", err)
	}
	return handler, decoded.Token, dbPath
}

func newTestHandlerWithOwnerDevice(t *testing.T) (http.Handler, string, string) {
	t.Helper()
	dir := t.TempDir()
	application, err := app.New(context.Background(), config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Test Messenger",
		SetupToken:   "test-setup-token",
	}, nil)
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()
	enrollment := reserveEnrollment(t, handler, "/api/v1/setup/owner/enrollment", "")
	body := map[string]interface{}{
		"instance_name":      "Test Messenger",
		"username":           "owner",
		"password":           "owner-password-123",
		"device_name":        "owner phone",
		"device_key_package": make([]byte, 64),
	}
	addEnrollmentProof(body, enrollment)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/setup/owner", "", body)
	if status != http.StatusCreated {
		t.Fatalf("setup owner status=%d body=%s", status, response)
	}
	var decoded struct {
		Token  string `json:"token"`
		Device struct {
			ID string `json:"id"`
		} `json:"device"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatalf("decode setup response: %v", err)
	}
	if decoded.Token == "" || decoded.Device.ID == "" {
		t.Fatalf("setup response missing token/device: %s", response)
	}
	return handler, decoded.Token, decoded.Device.ID
}

func createConversation(t *testing.T, handler http.Handler, token string) string {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", token, map[string]interface{}{"kind": "group"})
	if status != http.StatusCreated {
		t.Fatalf("create conversation status=%d body=%s", status, response)
	}
	var decoded struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatalf("decode conversation: %v", err)
	}
	return decoded.ID
}

func createMessage(t *testing.T, handler http.Handler, token, conversationID, idempotencyKey string, ciphertext []byte) string {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", token, map[string]interface{}{
		"conversation_id": conversationID,
		"idempotency_key": idempotencyKey,
		"ciphertext":      base64.StdEncoding.EncodeToString(ciphertext),
		"crypto_protocol": "mls10-openmls-v1",
	})
	if status != http.StatusCreated {
		t.Fatalf("create message status=%d body=%s", status, response)
	}
	var decoded struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatalf("decode message: %v", err)
	}
	return decoded.ID
}

func registerMember(t *testing.T, handler http.Handler, ownerToken, username string) string {
	t.Helper()
	token, _ := registerMemberWithID(t, handler, ownerToken, username)
	return token
}

func registerMemberWithID(t *testing.T, handler http.Handler, ownerToken, username string) (string, string) {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/invites", ownerToken, map[string]interface{}{"max_uses": 1})
	if status != http.StatusCreated {
		t.Fatalf("create invite status=%d body=%s", status, response)
	}
	var invite struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(response, &invite); err != nil {
		t.Fatalf("decode invite: %v", err)
	}
	enrollment := reserveEnrollment(t, handler, "/api/v1/register/enrollment", invite.Code)
	body := map[string]interface{}{
		"invite_code":        invite.Code,
		"username":           username,
		"password":           "member-password-123",
		"device_name":        username + " phone",
		"device_key_package": make([]byte, 64),
	}
	addEnrollmentProof(body, enrollment)
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/register", "", body)
	if status != http.StatusCreated {
		t.Fatalf("register member status=%d body=%s", status, response)
	}
	var decoded struct {
		Token   string `json:"token"`
		Account struct {
			ID string `json:"id"`
		} `json:"account"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatalf("decode register response: %v", err)
	}
	return decoded.Token, decoded.Account.ID
}

func accountIDFromExport(t *testing.T, handler http.Handler, token string) string {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/account/export", token, nil)
	if status != http.StatusOK {
		t.Fatalf("export account status=%d body=%s", status, response)
	}
	var decoded struct {
		Account struct {
			ID string `json:"id"`
		} `json:"account"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatalf("decode account export: %v", err)
	}
	return decoded.Account.ID
}

func doJSON(t *testing.T, handler http.Handler, method, path, token string, body interface{}) (int, []byte) {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if path == "/api/v1/setup/owner" || path == "/api/v1/setup/owner/enrollment" {
		req.Header.Set("X-Veritra-Setup-Token", "test-setup-token")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

type testEnrollment struct {
	ID                 string `json:"id"`
	AccountID          string `json:"account_id"`
	DeviceID           string `json:"device_id"`
	Challenge          []byte `json:"challenge"`
	SigningKey         []byte
	PrivateKey         ed25519.PrivateKey
	ProtocolVersion    string `json:"protocol_version"`
	LinkNonce          []byte `json:"link_nonce"`
	ExistingDeviceID   string `json:"existing_device_id"`
	ExistingSigningKey []byte `json:"existing_signing_key"`
}

func reserveEnrollment(t *testing.T, handler http.Handler, path, inviteCode string) testEnrollment {
	t.Helper()
	body := interface{}(map[string]interface{}{})
	if inviteCode != "" {
		field := "invite_code"
		if path == "/api/v1/device-links/claim-enrollment" {
			field = "code"
		}
		body = map[string]interface{}{field: inviteCode}
	}
	status, response := doJSON(t, handler, http.MethodPost, path, "", body)
	if status != http.StatusCreated {
		t.Fatalf("reserve enrollment status=%d body=%s", status, response)
	}
	var enrollment testEnrollment
	if err := json.Unmarshal(response, &enrollment); err != nil {
		t.Fatalf("decode enrollment: %v", err)
	}
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate enrollment key: %v", err)
	}
	enrollment.SigningKey = publicKey
	enrollment.PrivateKey = privateKey
	return enrollment
}

func addEnrollmentProof(body map[string]interface{}, enrollment testEnrollment) {
	var keyPackage []byte
	switch value := body["device_key_package"].(type) {
	case string:
		keyPackage, _ = base64.StdEncoding.DecodeString(value)
	case []byte:
		keyPackage = value
	case []int:
		keyPackage = make([]byte, len(value))
		for index, item := range value {
			keyPackage[index] = byte(item)
		}
	}
	body["enrollment_reservation_id"] = enrollment.ID
	body["signing_key"] = enrollment.SigningKey
	body["challenge_signature"] = ed25519.Sign(
		enrollment.PrivateKey,
		enrollmentProofMessageForTest(
			enrollment.Challenge,
			enrollment.SigningKey,
			keyPackage,
		),
	)
}

func enrollmentProofMessageForTest(challenge, signingKey, keyPackage []byte) []byte {
	keyPackageHash := sha256.Sum256(keyPackage)
	proof := []byte("veritra-enrollment-proof-v1")
	var challengeLength [2]byte
	binary.BigEndian.PutUint16(challengeLength[:], uint16(len(challenge)))
	proof = append(proof, challengeLength[:]...)
	proof = append(proof, challenge...)
	proof = append(proof, signingKey...)
	return append(proof, keyPackageHash[:]...)
}

func doRaw(t *testing.T, handler http.Handler, method, path, token string, body []byte, headers map[string]string) (int, []byte) {
	t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

func TestListInvitesReturnsOwnInvitesOnly(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/invites", ownerToken, map[string]interface{}{
		"max_uses": 5,
	})
	if status != http.StatusCreated {
		t.Fatalf("create invite status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/invites", ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("list invites status=%d body=%s", status, response)
	}
	var listed struct {
		Invites []struct {
			ID      string `json:"id"`
			Code    string `json:"code"`
			MaxUses int    `json:"max_uses"`
		} `json:"invites"`
	}
	if err := json.Unmarshal(response, &listed); err != nil {
		t.Fatalf("decode invites: %v", err)
	}
	if len(listed.Invites) != 1 || listed.Invites[0].MaxUses != 5 ||
		listed.Invites[0].Code == "" {
		t.Fatalf("unexpected invites: %#v", listed.Invites)
	}
	status, response = doJSON(t, handler, http.MethodDelete, "/api/v1/invites/"+listed.Invites[0].ID, ownerToken, nil)
	if status != http.StatusNoContent {
		t.Fatalf("revoke invite status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/register", "", map[string]interface{}{
		"invite_code": listed.Invites[0].Code, "username": "revokedinvite",
		"password": "member-password-123", "device_name": "phone",
		"device_key_package": base64.StdEncoding.EncodeToString([]byte("revoked-key-package")),
	})
	if status != http.StatusBadRequest {
		t.Fatalf("revoked invite registration status=%d body=%s", status, response)
	}

	memberToken := registerMember(t, handler, ownerToken, "listmember")
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/invites", memberToken, nil)
	if status != http.StatusForbidden {
		t.Fatalf("member list invites status=%d body=%s", status, response)
	}
}

func TestListCommunitiesAndChannelsScopedToMembership(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{
		"name": "Neighborhood",
	})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, response)
	}
	var community struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &community); err != nil {
		t.Fatalf("decode community: %v", err)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]interface{}{
		"name": "general",
	})
	if status != http.StatusCreated {
		t.Fatalf("create channel status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/communities", ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("list communities status=%d body=%s", status, response)
	}
	var communities struct {
		Communities []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"communities"`
	}
	if err := json.Unmarshal(response, &communities); err != nil {
		t.Fatalf("decode communities: %v", err)
	}
	if len(communities.Communities) != 1 || communities.Communities[0].Name != "Neighborhood" {
		t.Fatalf("unexpected communities: %#v", communities.Communities)
	}

	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/communities/"+community.ID+"/channels", ownerToken, nil)
	if status != http.StatusOK {
		t.Fatalf("list channels status=%d body=%s", status, response)
	}
	var channels struct {
		Channels []struct {
			Name string `json:"name"`
		} `json:"channels"`
	}
	if err := json.Unmarshal(response, &channels); err != nil {
		t.Fatalf("decode channels: %v", err)
	}
	if len(channels.Channels) != 1 || channels.Channels[0].Name != "general" {
		t.Fatalf("unexpected channels: %#v", channels.Channels)
	}

	memberToken := registerMember(t, handler, ownerToken, "outsider")
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/communities", memberToken, nil)
	if status != http.StatusOK {
		t.Fatalf("outsider list communities status=%d body=%s", status, response)
	}
	if err := json.Unmarshal(response, &communities); err != nil {
		t.Fatalf("decode outsider communities: %v", err)
	}
	if len(communities.Communities) != 0 {
		t.Fatalf("outsider should see no communities: %#v", communities.Communities)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/communities/"+community.ID+"/channels", memberToken, nil)
	if status != http.StatusForbidden {
		t.Fatalf("outsider list channels status=%d body=%s", status, response)
	}
}

func TestConversationAndChannelAuthorizationBoundaries(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "boundarymember")
	ownerID := accountIDFromExport(t, handler, ownerToken)

	conversationID := createConversation(t, handler, ownerToken)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/typing", memberToken, nil)
	if status != http.StatusForbidden {
		t.Fatalf("outsider typing status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", ownerToken, map[string]interface{}{
		"account_id": memberID,
		"role":       "moderator",
	})
	if status != http.StatusOK {
		t.Fatalf("promote member status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/sync/events?after=0&limit=100", memberToken, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte(`"membership.updated"`)) || !bytes.Contains(response, []byte(conversationID)) {
		t.Fatalf("member sync missing membership update status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/conversations/"+conversationID+"/members", memberToken, map[string]interface{}{
		"account_id": ownerID,
		"role":       "member",
	})
	if status != http.StatusForbidden {
		t.Fatalf("moderator demote owner status=%d body=%s", status, response)
	}

	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/communities", ownerToken, map[string]interface{}{"name": "Kinds"})
	if status != http.StatusCreated {
		t.Fatalf("create community status=%d body=%s", status, response)
	}
	var community struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &community); err != nil {
		t.Fatalf("decode community: %v", err)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/communities/"+community.ID+"/channels", ownerToken, map[string]interface{}{
		"name": "bad-kind",
		"kind": "text",
	})
	if status != http.StatusBadRequest {
		t.Fatalf("invalid channel kind status=%d body=%s", status, response)
	}
}

func TestMessageReferencesStayWithinConversation(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	firstConversation := createConversation(t, handler, token)
	secondConversation := createConversation(t, handler, token)
	messageID := createMessage(t, handler, token, firstConversation, "reference-source", []byte("ciphertext"))
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/messages/envelopes", token, map[string]interface{}{
		"conversation_id": secondConversation,
		"idempotency_key": "cross-conversation-reference",
		"ciphertext":      base64.StdEncoding.EncodeToString([]byte("ciphertext")),
		"crypto_protocol": "mls10-openmls-v1",
		"reply_to_id":     messageID,
	})
	if status != http.StatusBadRequest {
		t.Fatalf("cross-conversation reply status=%d body=%s", status, response)
	}
}

func TestAuthenticatedAPIResponsesAreNotCacheable(t *testing.T) {
	handler, ownerToken, _ := newTestHandlerWithOwner(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/devices/me", nil)
	req.Header.Set("Authorization", "Bearer "+ownerToken)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if got := rec.Header().Get("Cache-Control"); got != "no-store, private" {
		t.Fatalf("Cache-Control=%q", got)
	}
}
