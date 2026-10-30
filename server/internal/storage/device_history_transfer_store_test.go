package storage

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/uploads"
	"private-messenger/server/migrations"
)

type historyFixture struct {
	*v3Fixture
	blobs                    *uploads.LocalStore
	root                     string
	source, recipient, claim HistoryAccess
	input                    HistoryTransferInput
	data                     []byte
}

func newHistoryFixture(t *testing.T) *historyFixture {
	t.Helper()
	f := newV3Fixture(t)
	link := f.approve(t)
	root := t.TempDir()
	blobs, err := uploads.NewLocalStore(root)
	if err != nil {
		t.Fatal(err)
	}
	data := []byte("opaque history ciphertext")
	d := sha256.Sum256(data)
	return &historyFixture{v3Fixture: f, blobs: blobs, root: root, source: HistoryAccess{AccountID: link.AccountID, DeviceID: link.SourceDeviceID}, recipient: HistoryAccess{AccountID: link.AccountID, DeviceID: link.RecipientDeviceID}, claim: HistoryAccess{ClaimTokenHash: auth.HashToken(f.claimToken)}, data: data, input: HistoryTransferInput{ProtocolVersion: DeviceLinkV3Protocol, TransferID: strings.Repeat("b", 64), ClaimRequestHash: link.ClaimRequestHash, TranscriptHash: link.TranscriptHash, CiphertextSHA256: hex.EncodeToString(d[:]), SizeBytes: int64(len(data)), Handoff: []byte("opaque handoff")}}
}

func (f *historyFixture) prepare(t *testing.T) uploads.PreparedWrite {
	t.Helper()
	w, err := f.blobs.PrepareEncryptedBlob(context.Background(), func(key string) error {
		return f.store.RegisterHistoryUpload(context.Background(), f.link.ID, f.source, f.input, key)
	})
	if err != nil {
		t.Fatal(err)
	}
	return w
}

func (f *historyFixture) upload(t *testing.T) HistoryTransfer {
	t.Helper()
	w := f.prepare(t)
	defer w.Close()
	ref, err := w.Write(context.Background(), bytes.NewReader(f.data))
	if err != nil {
		t.Fatal(err)
	}
	result, err := f.store.FinalizeHistoryUpload(context.Background(), f.link.ID, f.source, f.input, ref)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestHistoryTransferImmutableRetryAuthorizationAndAck(t *testing.T) {
	f := newHistoryFixture(t)
	ctx := context.Background()
	tfr := f.upload(t)
	existing, err := f.store.CheckHistoryUpload(ctx, f.link.ID, f.source, f.input)
	if err != nil || existing == nil || existing.TransferID != tfr.TransferID {
		t.Fatalf("lost upload response: %v %v", existing, err)
	}
	changed := f.input
	changed.Handoff = []byte("replacement")
	if _, err := f.store.CheckHistoryUpload(ctx, f.link.ID, f.source, changed); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatal(err)
	}
	for _, access := range []HistoryAccess{f.recipient, f.claim, {AccountID: f.source.AccountID, DeviceID: "wrong"}, {ClaimTokenHash: strings.Repeat("c", 64)}} {
		if _, err := f.store.CheckHistoryUpload(ctx, f.link.ID, access, f.input); err == nil {
			t.Fatal("non-source upload allowed")
		}
	}
	source, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, f.source, false)
	if err != nil || len(source.Handoff) != 0 {
		t.Fatalf("source handoff: %v %v", source, err)
	}
	if _, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, f.source, true); !errors.Is(err, ErrForbidden) {
		t.Fatal(err)
	}
	for _, access := range []HistoryAccess{f.recipient, f.claim} {
		got, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, access, true)
		if err != nil || !bytes.Equal(got.Handoff, f.input.Handoff) {
			t.Fatalf("recipient access %v %v", got, err)
		}
	}
	var used int64
	if err := f.store.db.QueryRowContext(ctx, `SELECT size_bytes FROM blob_usage_accounts WHERE account_id=?`, f.source.AccountID).Scan(&used); err != nil || used != f.input.SizeBytes {
		t.Fatalf("quota double counted %d %v", used, err)
	}
	if _, err := f.store.AcknowledgeHistoryTransfer(ctx, f.link.ID, f.source, tfr.TransferID, tfr.CiphertextSHA256); !errors.Is(err, ErrForbidden) {
		t.Fatal(err)
	}
	if _, err := f.store.db.ExecContext(ctx, `CREATE TRIGGER fail_history_queue BEFORE INSERT ON blob_deletion_queue BEGIN SELECT RAISE(ABORT,'queue failure'); END`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.AcknowledgeHistoryTransfer(ctx, f.link.ID, f.claim, tfr.TransferID, tfr.CiphertextSHA256); err == nil {
		t.Fatal("queue failure ignored")
	}
	got, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, f.claim, true)
	if err != nil || len(got.Handoff) == 0 {
		t.Fatal("failed ACK consumed transfer")
	}
	if _, err := f.store.db.ExecContext(ctx, `DROP TRIGGER fail_history_queue`); err != nil {
		t.Fatal(err)
	}
	ack, err := f.store.AcknowledgeHistoryTransfer(ctx, f.link.ID, f.claim, tfr.TransferID, tfr.CiphertextSHA256)
	if err != nil || ack.State != "acknowledged" || len(ack.Handoff) != 0 || ack.Ref.StorageKey != "" {
		t.Fatalf("ack %v %v", ack, err)
	}
	retry, err := f.store.AcknowledgeHistoryTransfer(ctx, f.link.ID, f.recipient, tfr.TransferID, tfr.CiphertextSHA256)
	if err != nil || !retry.TerminalAt.Equal(*ack.TerminalAt) {
		t.Fatalf("ACK retry %v %v", retry, err)
	}
	if _, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, f.claim, true); err == nil {
		t.Fatal("ACK retained download")
	}
	keys, err := f.store.PendingBlobDeletions(ctx, 10)
	if err != nil || len(keys) != 1 || keys[0] != got.Ref.StorageKey {
		t.Fatalf("queue %v %v", keys, err)
	}
	if err := f.store.db.QueryRowContext(ctx, `SELECT size_bytes FROM blob_usage_accounts WHERE account_id=?`, f.source.AccountID).Scan(&used); err != nil || used != 0 {
		t.Fatalf("quota retained %d %v", used, err)
	}
}

type interruptedHistoryReader struct {
	entered chan struct{}
	resume  chan struct{}
	data    []byte
	used    bool
}

func (r *interruptedHistoryReader) Read(p []byte) (int, error) {
	if r.used {
		return 0, io.EOF
	}
	close(r.entered)
	<-r.resume
	r.used = true
	return copy(p, r.data), nil
}

func TestHistoryTransferInvalidationDuringWriteNeverAcknowledgesEarlyDeletion(t *testing.T) {
	for _, mode := range []string{"intent expiry", "source revoke", "recipient revoke", "copy cancel"} {
		t.Run(mode, func(t *testing.T) {
			f := newHistoryFixture(t)
			ctx := context.Background()
			w := f.prepare(t)
			r := &interruptedHistoryReader{entered: make(chan struct{}), resume: make(chan struct{}), data: f.data}
			type writeResult struct {
				ref uploads.BlobRef
				err error
			}
			done := make(chan writeResult, 1)
			go func() { ref, err := w.Write(ctx, r); done <- writeResult{ref, err} }()
			<-r.entered
			var key string
			if err := f.store.db.QueryRowContext(ctx, `SELECT storage_key FROM device_history_upload_intents WHERE link_id=?`, f.link.ID).Scan(&key); err != nil {
				t.Fatal(err)
			}
			switch mode {
			case "intent expiry":
				if _, err := f.store.db.ExecContext(ctx, `UPDATE device_history_upload_intents SET expires_at=? WHERE link_id=?`, formatTime(time.Now().Add(-time.Second)), f.link.ID); err != nil {
					t.Fatal(err)
				}
				if _, err := f.store.PruneOperationalRows(ctx, time.Now()); err != nil {
					t.Fatal(err)
				}
			case "source revoke":
				if err := f.store.RevokeDevice(ctx, f.source.AccountID, f.source.DeviceID); err != nil {
					t.Fatal(err)
				}
			case "recipient revoke":
				if err := f.store.RevokeDevice(ctx, f.source.AccountID, f.recipient.DeviceID); err != nil {
					t.Fatal(err)
				}
			case "copy cancel":
				if err := f.store.CancelHistoryTransfer(ctx, f.link.ID, f.claim); err != nil {
					t.Fatal(err)
				}
			}
			keys, err := f.store.PendingBlobDeletions(ctx, 10)
			if err != nil || len(keys) != 1 || keys[0] != key {
				t.Fatalf("invalidation queue %v %v", keys, err)
			}
			if err := f.blobs.Delete(ctx, key); !errors.Is(err, uploads.ErrBlobBusy) {
				t.Fatalf("early delete acknowledged: %v", err)
			}
			close(r.resume)
			result := <-done
			if result.err != nil {
				t.Fatal(result.err)
			}
			if _, err := f.store.FinalizeHistoryUpload(ctx, f.link.ID, f.source, f.input, result.ref); err == nil {
				t.Fatal("invalidated writer finalized")
			}
			_ = w.Close()
			if err := f.blobs.Delete(ctx, key); err != nil {
				t.Fatal(err)
			}
			if err := f.store.CompleteBlobDeletion(ctx, key); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestHistoryTransferCrashAfterRenameRetainsDurableIntentForCleanup(t *testing.T) {
	f := newHistoryFixture(t)
	ctx := context.Background()
	w := f.prepare(t)
	ref, err := w.Write(ctx, bytes.NewReader(f.data))
	if err != nil {
		t.Fatal(err)
	}
	// Simulate process loss after durable rename, before metadata finalization:
	// no abort/finalize runs, and a replacement store starts without old guards.
	_ = w.Close()
	replacement, err := uploads.NewLocalStore(f.root)
	if err != nil {
		t.Fatal(err)
	}
	blob, err := replacement.Open(ctx, ref)
	if err != nil {
		t.Fatal(err)
	}
	_ = blob.Close()
	if _, err := f.store.db.ExecContext(ctx, `UPDATE device_history_upload_intents SET expires_at=? WHERE storage_key=?`, formatTime(time.Now().Add(-time.Second)), ref.StorageKey); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.PruneOperationalRows(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	keys, err := f.store.PendingBlobDeletions(ctx, 10)
	if err != nil || len(keys) != 1 || keys[0] != ref.StorageKey {
		t.Fatalf("lost intent: %v %v", keys, err)
	}
	if err := replacement.Delete(ctx, ref.StorageKey); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.CheckHistoryUpload(ctx, f.link.ID, f.source, f.input); err != nil {
		t.Fatal(err)
	}
	f.upload(t)
}

func TestHistoryTransferIntentQuotasExpiryAndCancellation(t *testing.T) {
	f := newHistoryFixture(t)
	ctx := context.Background()
	f.store.limits.AccountStorageBytes = f.input.SizeBytes - 1
	if _, err := f.blobs.PrepareEncryptedBlob(ctx, func(key string) error { return f.store.RegisterHistoryUpload(ctx, f.link.ID, f.source, f.input, key) }); !errors.Is(err, ErrStorageQuota) {
		t.Fatal(err)
	}
	f.store.limits.AccountStorageBytes = 1 << 20
	w := f.prepare(t)
	defer w.Close()
	if _, err := f.blobs.PrepareEncryptedBlob(ctx, func(key string) error { return f.store.RegisterHistoryUpload(ctx, f.link.ID, f.source, f.input, key) }); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatal(err)
	}
	if err := f.store.CancelHistoryTransfer(ctx, f.link.ID, f.recipient); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.CheckHistoryUpload(ctx, f.link.ID, f.source, f.input); err == nil {
		t.Fatal("cancelled copy recreated")
	}
	var active bool
	if err := f.store.db.QueryRowContext(ctx, `SELECT revoked_at IS NULL FROM devices WHERE id=?`, f.recipient.DeviceID).Scan(&active); err != nil || !active {
		t.Fatal("copy cancellation unlinked device")
	}
}

func TestHistoryTransferFinalizeRollbackAndBackupReferences(t *testing.T) {
	f := newHistoryFixture(t)
	ctx := context.Background()
	w := f.prepare(t)
	defer w.Close()
	ref, err := w.Write(ctx, bytes.NewReader(f.data))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.db.ExecContext(ctx, `CREATE TRIGGER fail_transfer_commit BEFORE INSERT ON device_history_transfers BEGIN SELECT RAISE(ABORT,'injected SQL failure'); END`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.FinalizeHistoryUpload(ctx, f.link.ID, f.source, f.input, ref); err == nil {
		t.Fatal("injected failure ignored")
	}
	n, err := countRows(ctx, f.store.db, `SELECT COUNT(*) FROM device_history_upload_intents WHERE storage_key=?`, ref.StorageKey)
	if err != nil || n != 1 {
		t.Fatal("rollback lost durable intent")
	}
	var usage int64
	if err := f.store.db.QueryRowContext(ctx, `SELECT size_bytes FROM blob_usage_accounts WHERE account_id=?`, f.source.AccountID).Scan(&usage); err != nil || usage != f.input.SizeBytes {
		t.Fatalf("rollback quota %d %v", usage, err)
	}
	keys, err := f.store.PendingBlobDeletions(ctx, 10)
	if err != nil || len(keys) != 0 {
		t.Fatal("uncertain finalization queued live blob")
	}
	if _, err := f.store.db.ExecContext(ctx, `DROP TRIGGER fail_transfer_commit`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.FinalizeHistoryUpload(ctx, f.link.ID, f.source, f.input, ref); err != nil {
		t.Fatal(err)
	}
	var path string
	if err := f.store.db.QueryRowContext(ctx, `SELECT file FROM pragma_database_list WHERE name='main'`).Scan(&path); err != nil {
		t.Fatal(err)
	}
	refs, _, err := ListDatabaseBlobReferences(ctx, path)
	if err != nil || len(refs) != 1 || refs[0].StorageKey != ref.StorageKey {
		t.Fatalf("backup omitted active history: %v %v", refs, err)
	}
	if err := f.store.RecordBlobChunkDigests(ctx, ref.StorageKey, ref.SHA256, ref.Size, ref.ChunkDigests); err != nil {
		t.Fatal(err)
	}
}

func TestHistoryTransferCommittedLifecycleQueuesCiphertextAndReleasesQuota(t *testing.T) {
	for _, mode := range []string{"expiry", "source revoke", "recipient revoke", "account deletion", "copy cancel"} {
		t.Run(mode, func(t *testing.T) {
			f := newHistoryFixture(t)
			ctx := context.Background()
			f.upload(t)
			active, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, f.claim, true)
			if err != nil {
				t.Fatal(err)
			}
			switch mode {
			case "expiry":
				past := formatTime(time.Now().UTC().Add(-time.Second))
				if _, err := f.store.db.ExecContext(ctx, `UPDATE device_history_transfers SET expires_at=? WHERE link_id=?`, past, f.link.ID); err != nil {
					t.Fatal(err)
				}
				if _, err := f.store.db.ExecContext(ctx, `UPDATE device_links_v3 SET transfer_expires_at=? WHERE id=?`, past, f.link.ID); err != nil {
					t.Fatal(err)
				}
				if _, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, f.claim, true); err == nil {
					t.Fatal("expired auth allowed")
				}
				if _, err := f.store.PruneOperationalRows(ctx, time.Now()); err != nil {
					t.Fatal(err)
				}
			case "source revoke":
				if err := f.store.RevokeDevice(ctx, f.source.AccountID, f.source.DeviceID); err != nil {
					t.Fatal(err)
				}
			case "recipient revoke":
				if err := f.store.RevokeDevice(ctx, f.source.AccountID, f.recipient.DeviceID); err != nil {
					t.Fatal(err)
				}
			case "account deletion":
				if _, err := f.store.db.ExecContext(ctx, `UPDATE accounts SET role='member' WHERE id=?`, f.source.AccountID); err != nil {
					t.Fatal(err)
				}
				if err := f.store.DeleteAccount(ctx, f.source.AccountID); err != nil {
					t.Fatal(err)
				}
			case "copy cancel":
				if err := f.store.CancelHistoryTransfer(ctx, f.link.ID, f.source); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := f.store.HistoryTransferForAccess(ctx, f.link.ID, f.claim, true); err == nil {
				t.Fatal("retired claim downloaded")
			}
			keys, err := f.store.PendingBlobDeletions(ctx, 10)
			if err != nil || len(keys) != 1 || keys[0] != active.Ref.StorageKey {
				t.Fatalf("retirement lost blob queue %v %v", keys, err)
			}
			var usage int64
			if err := f.store.db.QueryRowContext(ctx, `SELECT COALESCE((SELECT size_bytes FROM blob_usage_accounts WHERE account_id=?),0)`, f.source.AccountID).Scan(&usage); err != nil || usage != 0 {
				t.Fatalf("retirement quota %d %v", usage, err)
			}
		})
	}
}

type historyCrashInput struct {
	DatabasePath, Root, LinkID string
	Access                     HistoryAccess
	Input                      HistoryTransferInput
	Data                       []byte
}

func TestHistoryTransferCrashProcessHelper(t *testing.T) {
	path := os.Getenv("VERITRA_HISTORY_CRASH_FIXTURE")
	if path == "" {
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f historyCrashInput
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	store, err := Open(ctx, config.Config{DatabasePath: f.DatabasePath})
	if err != nil {
		t.Fatal(err)
	}
	blobs, err := uploads.NewLocalStore(f.Root)
	if err != nil {
		t.Fatal(err)
	}
	w, err := blobs.PrepareEncryptedBlob(ctx, func(key string) error { return store.RegisterHistoryUpload(ctx, f.LinkID, f.Access, f.Input, key) })
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(ctx, bytes.NewReader(f.Data)); err != nil {
		t.Fatal(err)
	}
	// Terminate without deferred closes, abort, or final SQL commit.
	os.Exit(73)
}

func TestHistoryTransferActualProcessExitAfterRenameBeforeSQL(t *testing.T) {
	f := newHistoryFixture(t)
	ctx := context.Background()
	var dbPath string
	if err := f.store.db.QueryRowContext(ctx, `SELECT file FROM pragma_database_list WHERE name='main'`).Scan(&dbPath); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(historyCrashInput{DatabasePath: dbPath, Root: f.root, LinkID: f.link.ID, Access: f.source, Input: f.input, Data: f.data})
	if err != nil {
		t.Fatal(err)
	}
	fixture := filepath.Join(t.TempDir(), "crash.json")
	if err := os.WriteFile(fixture, raw, 0600); err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command(exe, "-test.run=^TestHistoryTransferCrashProcessHelper$")
	command.Env = append(os.Environ(), "VERITRA_HISTORY_CRASH_FIXTURE="+fixture)
	output, err := command.CombinedOutput()
	var exited *exec.ExitError
	if !errors.As(err, &exited) || exited.ExitCode() != 73 {
		t.Fatalf("crash helper failed: %v %s", err, output)
	}
	var key string
	if err := f.store.db.QueryRowContext(ctx, `SELECT storage_key FROM device_history_upload_intents WHERE link_id=?`, f.link.ID).Scan(&key); err != nil {
		t.Fatal(err)
	}
	ref := uploads.BlobRef{StorageKey: key, SHA256: f.input.CiphertextSHA256, Size: f.input.SizeBytes}
	blob, err := f.blobs.Open(ctx, ref)
	if err != nil {
		t.Fatalf("crashed rename missing: %v", err)
	}
	_ = blob.Close()
	if _, err := f.store.db.ExecContext(ctx, `UPDATE device_history_upload_intents SET expires_at=? WHERE storage_key=?`, formatTime(time.Now().Add(-time.Second)), key); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.PruneOperationalRows(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	keys, err := f.store.PendingBlobDeletions(ctx, 10)
	if err != nil || len(keys) != 1 || keys[0] != key {
		t.Fatalf("crash orphan not queued: %v %v", keys, err)
	}
	if err := f.blobs.Delete(ctx, key); err != nil {
		t.Fatal(err)
	}
	f.upload(t)
}

func TestHistoryTransferMigrationFailureRollsBackAndPreservesExistingData(t *testing.T) {
	ctx := context.Background()
	store := openBareStore(t)
	old, _ := migrationsUpTo(t, "0038")
	if err := store.Migrate(ctx, old); err != nil {
		t.Fatal(err)
	}
	owner := createTestOwner(t, ctx, store)
	broken := fstest.MapFS{}
	for name, file := range old.(fstest.MapFS) {
		broken[name] = file
	}
	sql, err := migrations.FS.ReadFile("0039_device_history_transfers.sql")
	if err != nil {
		t.Fatal(err)
	}
	broken["0039_device_history_transfers.sql"] = &fstest.MapFile{Data: append(sql, []byte("\nINSERT INTO missing_history_test_table VALUES(1);")...)}
	if err := store.Migrate(ctx, broken); err == nil {
		t.Fatal("injected migration failure ignored")
	}
	for _, query := range []string{`SELECT COUNT(*) FROM sqlite_master WHERE name IN ('device_history_transfers','device_history_upload_intents','history_usage_insert')`, `SELECT COUNT(*) FROM pragma_table_info('device_links_v3') WHERE name='history_cancelled_at'`, `SELECT COUNT(*) FROM schema_migrations WHERE version='0039_device_history_transfers.sql'`} {
		n, err := countRows(ctx, store.db, query)
		if err != nil || n != 0 {
			t.Fatalf("partial migration survived %d %v", n, err)
		}
	}
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		t.Fatal(err)
	}
	n, err := countRows(ctx, store.db, `SELECT COUNT(*) FROM accounts WHERE id=? AND status='active'`, owner.Account.ID)
	if err != nil || n != 1 {
		t.Fatalf("upgrade lost existing account %d %v", n, err)
	}
}
