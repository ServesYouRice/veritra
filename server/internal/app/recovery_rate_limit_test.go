package app

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Card I29: the recovery route sits under the strict credential budget of
// the production handler (10 per minute per client), so guessing
// capabilities is bounded however the guesses vary, and reauthentication
// shares the same budget (I37).
func TestRecoveryGuessesHitTheCredentialRateLimit(t *testing.T) {
	application, err := New(context.Background(), deploymentConfig(t), slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = application.Close() })
	handler := application.Handler()
	send := func(remote, method, path string, headers map[string]string) int {
		request := httptest.NewRequest(method, path, strings.NewReader("{}"))
		request.RemoteAddr = remote
		for key, value := range headers {
			request.Header.Set(key, value)
		}
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		return recorder.Code
	}
	guess := func(i int) map[string]string {
		token := base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf("guessed-capability-%013d", i)))
		return map[string]string{"X-Recovery-Token": token}
	}

	const attacker = "198.51.100.7:40000"
	for i := 0; i < 10; i++ {
		if status := send(attacker, http.MethodGet, "/api/v1/recovery", guess(i)); status == http.StatusTooManyRequests {
			t.Fatalf("guess %d was limited before the budget was spent", i+1)
		}
	}
	if status := send(attacker, http.MethodGet, "/api/v1/recovery", guess(10)); status != http.StatusTooManyRequests {
		t.Fatalf("11th recovery guess status=%d, want 429", status)
	}
	if status := send(attacker, http.MethodPost, "/api/v1/auth/reauth", map[string]string{"Authorization": "Bearer guessed"}); status != http.StatusTooManyRequests {
		t.Fatalf("reauth after the spent credential budget status=%d, want 429", status)
	}
	if status := send("198.51.100.8:40000", http.MethodGet, "/api/v1/recovery", guess(11)); status == http.StatusTooManyRequests {
		t.Fatal("another client inherited the spent budget")
	}
}
