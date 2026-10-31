package httpapi

import (
	"bytes"
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage"
	"private-messenger/server/migrations"
)

// stallingFlushWriter takes the body into memory and blocks in Flush until
// released, like a connection whose client has stopped reading at the end.
type stallingFlushWriter struct {
	header  http.Header
	body    bytes.Buffer
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (w *stallingFlushWriter) Header() http.Header         { return w.header }
func (w *stallingFlushWriter) WriteHeader(int)             {}
func (w *stallingFlushWriter) Write(p []byte) (int, error) { return w.body.Write(p) }
func (w *stallingFlushWriter) Flush() {
	w.once.Do(func() { close(w.entered) })
	<-w.release
}

// The lease is renewed until the final flush has finished. A client that
// stalls on the last flush must not let the lease lapse, or the completion
// is refused and the one-time capability stays usable.
func TestRecoveryLeaseSurvivesAStalledFinalFlush(t *testing.T) {
	previous := recoveryLeaseRenewInterval
	recoveryLeaseRenewInterval = 10 * time.Millisecond
	defer func() { recoveryLeaseRenewInterval = previous }()

	ctx := context.Background()
	dir := t.TempDir()
	cfg := config.Config{DataDir: dir, DatabasePath: filepath.Join(dir, "private-messenger.db"), StoragePath: filepath.Join(dir, "blobs")}
	store, err := storage.Open(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	reservation, err := store.ReserveOwnerEnrollment(ctx)
	if err != nil {
		t.Fatal(err)
	}
	owner, err := store.CreateOwner(ctx, storage.CreateOwnerInput{
		EnrollmentReservationID: reservation.ID, InstanceName: "flush", Username: "owner",
		PasswordHash: "x", DeviceName: "phone", KeyPackage: []byte("kp"), SigningKey: bytes.Repeat([]byte{1}, 32),
	})
	if err != nil {
		t.Fatal(err)
	}
	payload := bytes.Repeat([]byte("x"), 4096)
	token := bytes.Repeat([]byte{0x7a}, 32)
	if err := store.CreateBackupBlob(ctx, owner.Account.ID, owner.Device.ID, "blob_flush", "00000000000000000000000000000000000000000000000000000000000000ab", int64(len(payload)), []byte(`{"state_counter":1}`), token); err != nil {
		t.Fatal(err)
	}
	transfer, err := store.BeginRecoveryTransfer(ctx, token, 0)
	if err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", "file:"+cfg.DatabasePath+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	api := &API{Store: store, Blobs: &downloadTestStore{reader: &countingReadSeekCloser{Reader: bytes.NewReader(payload)}}}
	w := &stallingFlushWriter{header: make(http.Header), entered: make(chan struct{}), release: make(chan struct{})}
	done := make(chan struct{})
	go func() {
		defer close(done)
		api.serveRecoveryBlob(w, httptest.NewRequest(http.MethodGet, "/api/v1/recovery", nil), transfer, int64(len(payload)))
	}()
	select {
	case <-w.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the final flush never started")
	}
	// While the flush is stuck, the lease would run out within a moment if
	// nothing renewed it.
	if _, err := db.Exec(`UPDATE backup_blobs SET recovery_lease_expires_at = ?`, time.Now().UTC().Add(150*time.Millisecond).Format("2006-01-02T15:04:05.000000000Z")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(500 * time.Millisecond)
	close(w.release)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("serveRecoveryBlob did not finish")
	}
	var tokenHash []byte
	var next int64
	if err := db.QueryRow(`SELECT recovery_token_hash, recovery_next_offset FROM backup_blobs`).Scan(&tokenHash, &next); err != nil {
		t.Fatal(err)
	}
	if tokenHash != nil || next != int64(len(payload)) {
		t.Fatalf("after a complete transfer: token hash = %x, offset = %d, want a consumed capability at %d", tokenHash, next, len(payload))
	}
}
