package httpapi

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

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

func TestPublishCommittedEventRejectsZeroEventID(t *testing.T) {
	hub := realtime.NewHub()
	client, err := hub.Register("acct_test", "dev_test", "127.0.0.1")
	if err != nil {
		t.Fatalf("register realtime client: %v", err)
	}
	defer hub.Unregister(client)
	api := &API{Hub: hub}

	api.publishCommittedEvent([]string{"acct_test"}, realtime.Event{Type: "message.envelope.edited", ID: 0, CreatedAt: time.Now().UTC()})
	select {
	case payload := <-client.Send():
		t.Fatalf("zero-id event was published: %s", payload)
	default:
	}

	api.publishCommittedEvent([]string{"acct_test"}, realtime.Event{Type: "message.envelope.edited", ID: 1, CreatedAt: time.Now().UTC()})
	select {
	case <-client.Send():
	case <-time.After(time.Second):
		t.Fatal("committed event was not published")
	}
}
