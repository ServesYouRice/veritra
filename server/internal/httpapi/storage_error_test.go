package httpapi

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"private-messenger/server/internal/admission"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

func TestHandleStorageErrorReportsQuotaExhaustion(t *testing.T) {
	recorder := httptest.NewRecorder()

	handleStorageError(recorder, storage.ErrStorageQuota)

	if recorder.Code != http.StatusInsufficientStorage {
		t.Fatalf("status=%d want %d", recorder.Code, http.StatusInsufficientStorage)
	}
	if !bytes.Contains(recorder.Body.Bytes(), []byte(`"error":"storage_quota_exceeded"`)) {
		t.Fatalf("body=%s", recorder.Body.String())
	}
}

func TestHandleStorageErrorReportsAdmissionLimits(t *testing.T) {
	for err, code := range map[error]string{
		storage.ErrDeviceLimit:             "device_limit_reached",
		storage.ErrDeviceLinkLimit:         "device_link_limit_reached",
		storage.ErrConversationLimit:       "conversation_limit_reached",
		storage.ErrConversationMemberLimit: "conversation_member_limit_reached",
	} {
		recorder := httptest.NewRecorder()
		handleStorageError(recorder, err)
		if recorder.Code != http.StatusConflict || !bytes.Contains(recorder.Body.Bytes(), []byte(`"error":"`+code+`"`)) {
			t.Fatalf("%v: status=%d body=%s", err, recorder.Code, recorder.Body.String())
		}
	}
}

func TestDiskGuardRefusesWritesButNotReads(t *testing.T) {
	counters := &admission.Counters{}
	api := &API{LowDisk: func() bool { return true }, Admission: counters}
	reached := false
	handler := api.withWriteBudget(func(w http.ResponseWriter, _ *http.Request, _ domain.Principal) {
		reached = true
		w.WriteHeader(http.StatusNoContent)
	})
	recorder := httptest.NewRecorder()
	handler(recorder, httptest.NewRequest(http.MethodPost, "/api/v1/messages/envelopes", nil), domain.Principal{AccountID: "acct_a"})
	if recorder.Code != http.StatusInsufficientStorage || reached || !bytes.Contains(recorder.Body.Bytes(), []byte(`"server_storage_low"`)) {
		t.Fatalf("write on a full disk: status=%d reached=%v body=%s", recorder.Code, reached, recorder.Body.String())
	}
	recorder = httptest.NewRecorder()
	handler(recorder, httptest.NewRequest(http.MethodGet, "/api/v1/messages/msg_x", nil), domain.Principal{AccountID: "acct_a"})
	if recorder.Code != http.StatusNoContent || !reached {
		t.Fatalf("read on a full disk: status=%d", recorder.Code)
	}
	uploads := httptest.NewRecorder()
	api.uploadAttachment(uploads, httptest.NewRequest(http.MethodPost, "/api/v1/attachments", nil), domain.Principal{AccountID: "acct_a"})
	if uploads.Code != http.StatusInsufficientStorage {
		t.Fatalf("upload on a full disk: status=%d", uploads.Code)
	}
	var refused int64
	counters.Each(func(limit string, n int64) {
		if limit == admission.Disk {
			refused = n
		}
	})
	if refused != 2 {
		t.Fatalf("disk refusals = %d, want 2", refused)
	}
}

func newLimitStoreForBudget(t *testing.T) *storage.Store {
	t.Helper()
	dir := t.TempDir()
	store, err := storage.Open(context.Background(), config.Config{DatabasePath: filepath.Join(dir, "db"), Limits: config.Limits{ConversationMembers: 4}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

// The settlement charges what the request published, not the reservation.
func TestWriteBudgetSettlesPublishedRecipients(t *testing.T) {
	budget := admission.NewBudget(100, 1<<20, nil)
	store := newLimitStoreForBudget(t)
	api := &API{Budget: budget, Store: store}
	handler := api.withWriteBudget(func(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
		countRecipients(r.Context(), 4)
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusNoContent)
	})
	for i := 0; i < 20; i++ {
		recorder := httptest.NewRecorder()
		handler(recorder, httptest.NewRequest(http.MethodPost, "/x", strings.NewReader("body")), domain.Principal{AccountID: "acct_a"})
		if recorder.Code != http.StatusNoContent {
			t.Fatalf("request %d refused after %d deliveries", i, 5*i)
		}
	}
	// 20 requests x (1 + 4) = 100: the budget is spent.
	recorder := httptest.NewRecorder()
	handler(recorder, httptest.NewRequest(http.MethodPost, "/x", strings.NewReader("body")), domain.Principal{AccountID: "acct_a"})
	if recorder.Code != http.StatusTooManyRequests || recorder.Header().Get("Retry-After") == "" {
		t.Fatalf("21st request status=%d", recorder.Code)
	}
}

func TestPublishCommittedEventRejectsZeroEventID(t *testing.T) {
	hub := realtime.NewHub()
	client, err := hub.Register("acct_test", "dev_test", "127.0.0.1")
	if err != nil {
		t.Fatalf("register realtime client: %v", err)
	}
	defer hub.Unregister(client)
	api := &API{Hub: hub}

	api.publishCommittedEvent(context.Background(), []string{"acct_test"}, realtime.Event{Type: "message.envelope.edited", ID: 0, CreatedAt: time.Now().UTC()})
	select {
	case payload := <-client.Send():
		t.Fatalf("zero-id event was published: %s", payload)
	default:
	}

	api.publishCommittedEvent(context.Background(), []string{"acct_test"}, realtime.Event{Type: "message.envelope.edited", ID: 1, CreatedAt: time.Now().UTC()})
	select {
	case <-client.Send():
	case <-time.After(time.Second):
		t.Fatal("committed event was not published")
	}
}
