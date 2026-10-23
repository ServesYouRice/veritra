package app

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/storage"
)

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// Card I29 (and the AGENTS.md logging boundary): request bodies, keys,
// tokens and ciphertext bodies never reach the application log, on success
// or on any rejection path, even at debug level.
func TestApplicationLogNeverContainsBodiesTokensOrCiphertext(t *testing.T) {
	ctx := context.Background()
	logs := &lockedBuffer{}
	application, err := New(ctx, deploymentConfig(t), slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()

	reservation, err := application.Store.ReserveOwnerEnrollment(ctx)
	if err != nil {
		t.Fatal(err)
	}
	passwordHash, err := auth.HashPassword("owner-password-123")
	if err != nil {
		t.Fatal(err)
	}
	owner, err := application.Store.CreateOwner(ctx, storage.CreateOwnerInput{
		EnrollmentReservationID: reservation.ID,
		InstanceName:            "Log Privacy",
		Username:                "owner",
		PasswordHash:            passwordHash,
		DeviceName:              "owner device",
		KeyPackage:              []byte("synthetic-key-package"),
	})
	if err != nil {
		t.Fatal(err)
	}
	const sessionToken = "SENTINELsessiontoken0123456789abcdef"
	if err := application.Store.CreateSession(ctx, auth.HashToken(sessionToken), owner.Account.ID, owner.Device.ID, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	conversation, err := application.Store.CreateConversation(ctx, storage.CreateConversationInput{Kind: "group", CreatedBy: owner.Account.ID})
	if err != nil {
		t.Fatal(err)
	}

	secrets := []string{
		sessionToken,
		"SENTINELbearerforged",
		"SENTINELpassword",
		"SENTINELplaintextbody",
		"SENTINELciphertextbody",
		"SENTINELrecoverytoken",
		"SENTINELsetuptoken",
		"SENTINELclaimtoken",
		"SENTINELbackupbody",
		"SENTINELmalformed",
	}
	ciphertext := base64.StdEncoding.EncodeToString([]byte("SENTINELciphertextbody"))
	recovery := base64.RawURLEncoding.EncodeToString([]byte("SENTINELrecoverytoken-pad-32byte"))
	requests := []struct {
		method, path, token, body string
		headers                   map[string]string
	}{
		{"POST", "/api/v1/messages/envelopes", sessionToken, `{"conversation_id":"` + conversation.ID + `","idempotency_key":"log-ok","ciphertext":"` + ciphertext + `","crypto_protocol":"mls10-openmls-v1"}`, nil},
		{"POST", "/api/v1/messages/envelopes", sessionToken, `{"conversation_id":"` + conversation.ID + `","idempotency_key":"log-plain","body":"SENTINELplaintextbody","ciphertext":"` + ciphertext + `","crypto_protocol":"mls10-openmls-v1"}`, nil},
		{"POST", "/api/v1/messages/envelopes", sessionToken, `{"conversation_id":"conv_missing","idempotency_key":"log-missing","ciphertext":"` + ciphertext + `","crypto_protocol":"mls10-openmls-v1"}`, nil},
		{"POST", "/api/v1/messages/envelopes", "SENTINELbearerforged", `{"ciphertext":"` + ciphertext + `"}`, nil},
		{"POST", "/api/v1/messages/envelopes", sessionToken, `{"SENTINELmalformed`, nil},
		{"POST", "/api/v1/auth/login", "", `{"username":"owner","password":"SENTINELpassword","device_id":"` + owner.Device.ID + `","device_secret":"SENTINELpassword"}`, nil},
		{"POST", "/api/v1/setup/owner", "", `{"password":"SENTINELpassword"}`, map[string]string{"X-Veritra-Setup-Token": "SENTINELsetuptoken"}},
		{"POST", "/api/v1/device-links/claim", "", `{"code":"SENTINELclaimtoken"}`, map[string]string{"X-Veritra-Claim-Token": "SENTINELclaimtoken"}},
		{"POST", "/api/v1/backups", sessionToken, "SENTINELbackupbody", map[string]string{
			"X-Private-Messenger-Encrypted": "1",
			"X-Key-Derivation-Metadata":     `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1}`,
			"X-Recovery-Token":              recovery,
		}},
		{"GET", "/api/v1/recovery", "", "", map[string]string{"X-Recovery-Token": recovery}},
		{"GET", "/api/v1/recovery", "", "", map[string]string{"X-Recovery-Token": "SENTINELrecoverytoken"}},
		{"GET", "/api/v1/recovery/SENTINELrecoverytoken", "", "", nil},
	}
	statuses := make([]int, 0, len(requests))
	for _, item := range requests {
		request := httptest.NewRequest(item.method, item.path, strings.NewReader(item.body))
		request.RemoteAddr = "127.0.0.1:40000"
		if item.body != "" && item.headers == nil {
			request.Header.Set("Content-Type", "application/json")
		}
		if item.token != "" {
			request.Header.Set("Authorization", "Bearer "+item.token)
		}
		for key, value := range item.headers {
			request.Header.Set(key, value)
		}
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		statuses = append(statuses, recorder.Code)
	}
	// The flow must reach both the success and the rejection paths.
	if statuses[0] != http.StatusCreated || statuses[1] != http.StatusBadRequest || statuses[3] != http.StatusUnauthorized || statuses[8] != http.StatusCreated || statuses[9] != http.StatusOK {
		t.Fatalf("unexpected statuses %v", statuses)
	}
	output := logs.String()
	if !strings.Contains(output, "http_request") {
		t.Fatalf("request log missing: %s", output)
	}
	forms := []string{recovery, ciphertext}
	for _, secret := range secrets {
		forms = append(forms, secret, base64.StdEncoding.EncodeToString([]byte(secret)), base64.RawURLEncoding.EncodeToString([]byte(secret)), hex.EncodeToString([]byte(secret)))
	}
	for _, form := range forms {
		if strings.Contains(output, form) {
			t.Fatalf("application log contains a body, token or ciphertext form %q:\n%s", form, output)
		}
	}
	if strings.Contains(output, "SENTINEL") {
		t.Fatalf("application log contains a sentinel:\n%s", output)
	}
}
