package httpapi

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/push"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
)

func (a *API) uploadAttachment(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if a.diskLow(w) {
		return
	}
	if r.Header.Get("X-Private-Messenger-Encrypted") != "1" {
		writeError(w, http.StatusBadRequest, "encrypted_upload_header_required")
		return
	}
	conversationID := optionalQuery(r, "conversation_id")
	if conversationID == nil {
		writeError(w, http.StatusBadRequest, "conversation_id_required")
		return
	}
	member, err := a.Store.IsConversationMember(r.Context(), *conversationID, principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	if !member {
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}
	metadata := json.RawMessage(r.Header.Get("X-Crypto-Metadata"))
	if len(metadata) == 0 {
		metadata = json.RawMessage(`{}`)
	}
	if !validAttachmentCryptoMetadata(metadata) {
		writeError(w, http.StatusBadRequest, "invalid_crypto_metadata")
		return
	}
	blob, err := a.Blobs.PutEncryptedBlob(r.Context(), http.MaxBytesReader(w, r.Body, config.MaxAttachmentCiphertext(a.maxAttachmentBytes())))
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "upload_too_large")
			return
		}
		writeError(w, http.StatusInternalServerError, "upload_failed")
		return
	}
	attachment, err := a.Store.CreateAttachmentEnvelope(r.Context(), domain.AttachmentEnvelope{
		OwnerAccountID:   principal.AccountID,
		ConversationID:   conversationID,
		StorageKey:       blob.StorageKey,
		CiphertextSHA256: blob.SHA256,
		SizeBytes:        blob.Size,
		CryptoMetadata:   metadata,
		ChunkDigests:     blob.ChunkDigests,
	})
	if err != nil {
		a.cleanupUncommittedBlob(r.Context(), blob.StorageKey)
		if errors.Is(err, storage.ErrStorageQuota) {
			handleStorageError(w, err)
			return
		}
		writeError(w, http.StatusInternalServerError, "attachment_record_failed")
		return
	}
	writeJSON(w, http.StatusCreated, attachment)
}

func validAttachmentCryptoMetadata(raw json.RawMessage) bool {
	var metadata struct {
		Version   int    `json:"version"`
		Algorithm string `json:"algorithm"`
		ChunkSize int    `json:"chunk_size"`
	}
	if err := json.Unmarshal(raw, &metadata); err != nil {
		return false
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil || len(fields) != 3 {
		return false
	}
	return metadata.Version == 1 && metadata.Algorithm == "AES-256-GCM-chunked" &&
		metadata.ChunkSize == 1024*1024
}

func (a *API) listAttachments(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	attachments, err := a.Store.ListAttachments(r.Context(), principal.AccountID, limit)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"attachments": attachments})
}

func (a *API) attachmentSubroute(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/attachments/"), "/")
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	attachment, err := a.Store.AttachmentForAccount(r.Context(), id, principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	switch r.Method {
	case http.MethodGet:
		a.serveEncryptedBlob(w, r, uploads.BlobRef{
			StorageKey: attachment.StorageKey, SHA256: attachment.CiphertextSHA256,
			Size: attachment.SizeBytes, ChunkDigests: attachment.ChunkDigests,
		})
	case http.MethodDelete:
		if attachment.OwnerAccountID != principal.AccountID {
			writeError(w, http.StatusForbidden, "forbidden")
			return
		}
		deleted, err := a.Store.DeleteAttachment(r.Context(), id, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		a.completeQueuedBlobDeletion(r.Context(), deleted.StorageKey)
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusNotFound, "not_found")
	}
}

func (a *API) uploadBackup(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if a.diskLow(w) {
		return
	}
	if r.Header.Get("X-Private-Messenger-Encrypted") != "1" {
		writeError(w, http.StatusBadRequest, "encrypted_upload_header_required")
		return
	}
	metadata := json.RawMessage(r.Header.Get("X-Key-Derivation-Metadata"))
	if len(metadata) == 0 {
		writeError(w, http.StatusBadRequest, "key_derivation_metadata_required")
		return
	}
	metadata, ok := canonicalBackupCryptoMetadata(metadata)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_key_derivation_metadata")
		return
	}
	recoveryToken, err := base64.RawURLEncoding.DecodeString(r.Header.Get("X-Recovery-Token"))
	if err != nil || len(recoveryToken) != 32 {
		writeError(w, http.StatusBadRequest, "recovery_token_required")
		return
	}
	recoveryTokenHash := sha256.Sum256(recoveryToken)
	blob, err := a.Blobs.PutEncryptedBlob(r.Context(), http.MaxBytesReader(w, r.Body, 100<<20))
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "upload_too_large")
			return
		}
		writeError(w, http.StatusInternalServerError, "backup_upload_failed")
		return
	}
	if err := a.Store.CreateBackupBlobWithChunkDigests(r.Context(), principal.AccountID, principal.DeviceID, blob.StorageKey, blob.SHA256, blob.Size, blob.ChunkDigests, metadata, recoveryTokenHash[:]); err != nil {
		a.cleanupUncommittedBlob(r.Context(), blob.StorageKey)
		if errors.Is(err, storage.ErrStorageQuota) {
			handleStorageError(w, err)
			return
		}
		writeError(w, http.StatusInternalServerError, "backup_record_failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]interface{}{"storage_key": blob.StorageKey, "ciphertext_sha256": blob.SHA256, "size_bytes": blob.Size})
}

// backupCryptoMetadata is the key derivation metadata of an encrypted backup.
type backupCryptoMetadata struct {
	Version      int    `json:"version"`
	Algorithm    string `json:"algorithm"`
	ChunkSize    int    `json:"chunk_size"`
	StateCounter int64  `json:"state_counter"`
}

// canonicalBackupCryptoMetadata validates backup key derivation metadata and
// returns it re-encoded. Each field is read from its exact lowercase key:
// encoding/json matches struct fields case-insensitively, and storage reads
// the counter back with json_extract('$.state_counter'), so a document with
// "STATE_COUNTER" (or a repeated key) could pass validation with one counter
// and be stored with another. The re-encoded document is what is stored.
func canonicalBackupCryptoMetadata(raw json.RawMessage) (json.RawMessage, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || len(fields) != 4 {
		return nil, false
	}
	var metadata backupCryptoMetadata
	for key, target := range map[string]interface{}{
		"version": &metadata.Version, "algorithm": &metadata.Algorithm,
		"chunk_size": &metadata.ChunkSize, "state_counter": &metadata.StateCounter,
	} {
		value, ok := fields[key]
		if !ok || json.Unmarshal(value, target) != nil {
			return nil, false
		}
	}
	if metadata.Version != 1 || metadata.Algorithm != "AES-256-GCM-chunked" ||
		metadata.ChunkSize != 1024*1024 || metadata.StateCounter <= 0 {
		return nil, false
	}
	canonical, err := json.Marshal(metadata)
	if err != nil {
		return nil, false
	}
	return canonical, true
}

func (a *API) recoverBackup(w http.ResponseWriter, r *http.Request) {
	token, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(r.Header.Get("X-Recovery-Token")))
	if err != nil || len(token) != 32 {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	hash := sha256.Sum256(token)
	start, err := recoveryRangeStart(r)
	if err != nil {
		writeError(w, http.StatusRequestedRangeNotSatisfiable, "invalid_recovery_range")
		return
	}
	transfer, err := a.Store.BeginRecoveryTransfer(r.Context(), hash[:], start)
	if err != nil {
		if errors.Is(err, storage.ErrRecoveryBusy) {
			writeError(w, http.StatusConflict, "recovery_transfer_in_progress")
			return
		}
		if errors.Is(err, storage.ErrRecoveryRange) {
			writeError(w, http.StatusRequestedRangeNotSatisfiable, "invalid_recovery_range")
			return
		}
		handleStorageError(w, err)
		return
	}
	start, end, err := recoveryRange(r, transfer.Backup.SizeBytes)
	if err != nil {
		_ = finalizeRecoveryTransfer(r, a.Store, transfer, 0, 0)
		writeError(w, http.StatusRequestedRangeNotSatisfiable, "invalid_recovery_range")
		return
	}
	a.serveRecoveryBlob(w, r, transfer, end-start+1)
}

func recoveryRange(r *http.Request, size int64) (int64, int64, error) {
	if size < 0 {
		return 0, 0, errors.New("invalid recovery size")
	}
	start, err := recoveryRangeStart(r)
	if err != nil {
		return 0, 0, err
	}
	if strings.TrimSpace(r.Header.Get("Range")) == "" {
		if size == 0 {
			return 0, -1, nil
		}
		return 0, size - 1, nil
	}
	header := strings.TrimSpace(r.Header.Get("Range"))
	spec := strings.TrimSpace(strings.TrimPrefix(header, "bytes="))
	if strings.Contains(spec, ",") {
		return 0, 0, errors.New("multiple recovery ranges are not supported")
	}
	parts := strings.Split(spec, "-")
	if len(parts) != 2 || parts[0] == "" {
		return 0, 0, errors.New("invalid recovery range")
	}
	if start >= size {
		return 0, 0, errors.New("invalid recovery range")
	}
	end := size - 1
	if strings.TrimSpace(parts[1]) != "" {
		end, err = strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64)
		if err != nil || end < start || end >= size {
			return 0, 0, errors.New("invalid recovery range")
		}
	}
	return start, end, nil
}

func recoveryRangeStart(r *http.Request) (int64, error) {
	header := strings.TrimSpace(r.Header.Get("Range"))
	if header == "" {
		return 0, nil
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, errors.New("invalid recovery range")
	}
	spec := strings.TrimSpace(strings.TrimPrefix(header, "bytes="))
	if strings.Contains(spec, ",") {
		return 0, errors.New("multiple recovery ranges are not supported")
	}
	parts := strings.Split(spec, "-")
	if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" {
		return 0, errors.New("invalid recovery range")
	}
	start, err := strconv.ParseInt(strings.TrimSpace(parts[0]), 10, 64)
	if err != nil || start < 0 {
		return 0, errors.New("invalid recovery range")
	}
	return start, nil
}

// blobResponseWriter carries a verified blob through http.ServeContent.
// Before a 200 or 206 status line is sent it verifies the chunk holding the
// first byte to serve, so a bad chunk there becomes a clean
// 500 blob_integrity_failed. A chunk that fails later stops the copy; the
// caller then aborts the response (panic(http.ErrAbortHandler)), so the
// client sees a broken transfer, never an unverified byte. It also records
// the status and the body bytes handed to the connection.
type blobResponseWriter struct {
	http.ResponseWriter
	blob            uploads.Blob
	status          int
	written         int64
	integrityFailed bool

	// confirmFlush makes the writer flush every recoveryFlushInterval bytes
	// and at the end (flushAll). flushed is the body byte count the last
	// successful flush covered: bytes still in the server's buffers are not
	// progress, because a dropped connection never delivers them.
	confirmFlush bool
	flushed      int64
	// flushUnsupported records that the response chain cannot flush, so
	// nothing can be confirmed and written is used as before.
	flushUnsupported bool
	flushErr         error
	// cutOff is set from another goroutine to stop a stream whose recovery
	// lease was lost. It is never set for ordinary downloads.
	cutOff atomic.Bool
}

// recoveryFlushInterval is how many body bytes a recovery download writes
// between confirming flushes.
const recoveryFlushInterval = 1 << 20

// flushAll flushes the response and records how far that confirmed.
func (w *blobResponseWriter) flushAll() {
	if !w.confirmFlush || w.flushErr != nil || w.flushUnsupported {
		return
	}
	err := http.NewResponseController(w.ResponseWriter).Flush()
	switch {
	case err == nil:
		w.flushed = w.written
	case errors.Is(err, http.ErrNotSupported):
		w.flushUnsupported = true
	default:
		w.flushErr = err
	}
}

// confirmed is the number of body bytes progress may count.
func (w *blobResponseWriter) confirmed() int64 {
	if !w.confirmFlush || w.flushUnsupported {
		return w.written
	}
	return w.flushed
}

// errTransferCutOff ends a stream that no longer holds its recovery lease.
var errTransferCutOff = errors.New("recovery transfer lease lost")

func (w *blobResponseWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	// A multipart/byteranges body is produced by a ServeContent goroutine
	// that positions the blob itself; its chunks are still verified on read.
	if (status == http.StatusOK || status == http.StatusPartialContent) &&
		!strings.HasPrefix(w.Header().Get("Content-Type"), "multipart/") {
		if err := w.blob.VerifyCurrent(); err != nil {
			w.integrityFailed = true
			w.status = http.StatusInternalServerError
			for _, key := range []string{"Accept-Ranges", "Content-Disposition", "Content-Length", "Content-Range", "Etag"} {
				w.Header().Del(key)
			}
			writeError(w.ResponseWriter, http.StatusInternalServerError, "blob_integrity_failed")
			return
		}
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *blobResponseWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.WriteHeader(http.StatusOK)
	}
	if w.integrityFailed {
		return 0, uploads.ErrBlobIntegrity
	}
	if w.cutOff.Load() {
		return 0, errTransferCutOff
	}
	n, err := w.ResponseWriter.Write(p)
	w.written += int64(n)
	if err == nil && w.confirmFlush && w.written-w.flushed >= recoveryFlushInterval {
		if w.flushAll(); w.flushErr != nil {
			return n, w.flushErr
		}
	}
	return n, err
}

// openBlob opens ref for a download and writes the error response itself
// when it cannot.
func (a *API) openBlob(w http.ResponseWriter, r *http.Request, ref uploads.BlobRef) (uploads.Blob, bool) {
	blob, err := a.Blobs.Open(r.Context(), ref)
	if err == nil {
		return blob, true
	}
	if errors.Is(err, uploads.ErrBlobIntegrity) {
		a.warn("blob_integrity_failed")
		writeError(w, http.StatusInternalServerError, "blob_integrity_failed")
	} else {
		writeError(w, http.StatusNotFound, "blob_not_found")
	}
	return nil, false
}

// finishBlobResponse runs after ServeContent. It stores the record Open
// rebuilt for a blob stored before chunk records existed, and reports
// whether a chunk failed after the status line was sent, in which case the
// caller must abort the response.
func (a *API) finishBlobResponse(r *http.Request, ref uploads.BlobRef, blob uploads.Blob, writer *blobResponseWriter) bool {
	if record := blob.RecomputedChunkDigests(); record != nil {
		if ref.ChunkDigests != nil {
			a.warn("blob_digest_record_invalid")
		}
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
		err := a.Store.RecordBlobChunkDigests(ctx, ref.StorageKey, ref.SHA256, ref.Size, record)
		cancel()
		if err != nil {
			a.warn("blob_digest_backfill_failed")
		}
	}
	if writer.integrityFailed {
		a.warn("blob_integrity_failed")
		return false
	}
	if blob.Err() != nil {
		a.warn("blob_integrity_failed")
		return true
	}
	return false
}

func (a *API) serveRecoveryBlob(w http.ResponseWriter, r *http.Request, transfer storage.RecoveryTransfer, expected int64) {
	ref := backupBlobRef(transfer.Backup)
	blob, ok := a.openBlob(w, r, ref)
	if !ok {
		_ = finalizeRecoveryTransfer(r, a.Store, transfer, 0, 0)
		return
	}
	defer blob.Close()
	w.Header().Set("Cache-Control", "no-store, private")
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if transfer.Backup.CiphertextSHA256 != "" {
		w.Header().Set("ETag", `"sha256-`+transfer.Backup.CiphertextSHA256+`"`)
	}
	tracked := &blobResponseWriter{ResponseWriter: w, blob: blob, confirmFlush: true}
	request := r.Clone(r.Context())
	request.Header.Del("If-Match")
	request.Header.Del("If-None-Match")
	request.Header.Del("If-Modified-Since")
	request.Header.Del("If-Unmodified-Since")
	request.Header.Del("If-Range")
	// The lease is renewed until the final flush is done: a client that stalls
	// there must not let it lapse, or the completion below is refused and the
	// capability stays usable.
	stopRenewing := a.renewRecoveryLease(r.Context(), tracked, transfer)
	defer stopRenewing()
	http.ServeContent(tracked, request, "encrypted.bin", time.Time{}, blob)
	validResponse := !tracked.integrityFailed && (tracked.status == http.StatusOK || tracked.status == http.StatusPartialContent)
	if r.Header.Get("Range") != "" {
		validResponse = validResponse && tracked.status == http.StatusPartialContent &&
			w.Header().Get("Content-Range") == "bytes "+strconv.FormatInt(transfer.StartOffset, 10)+"-"+
				strconv.FormatInt(transfer.StartOffset+expected-1, 10)+"/"+strconv.FormatInt(transfer.Backup.SizeBytes, 10)
	} else {
		validResponse = validResponse && tracked.status == http.StatusOK
	}
	if contentLength, err := strconv.ParseInt(w.Header().Get("Content-Length"), 10, 64); err != nil || contentLength != expected {
		validResponse = false
	}
	// Only verified bytes that a flush pushed to the connection count: Write
	// succeeds long before a client has the data, and a drop during the
	// final flush must not consume the capability. A flush only reaches the
	// kernel, so delivery is still not proven (see the recovery
	// acknowledgement question); a mid-stream failure records progress up to
	// the last confirmed flush.
	if validResponse {
		tracked.flushAll()
	}
	written := tracked.confirmed()
	stopRenewing()
	if !validResponse || written > expected {
		written = 0
	}
	abort := a.finishBlobResponse(r, ref, blob, tracked)
	if err := finalizeRecoveryTransfer(r, a.Store, transfer, written, expected); err != nil {
		// No lease id, token or range goes into the log.
		a.warn("recovery_transfer_completion_failed", "lease_lost", errors.Is(err, storage.ErrRecoveryBusy))
	}
	if abort {
		panic(http.ErrAbortHandler)
	}
}

// recoveryLeaseRenewInterval is well below storage.RecoveryLeaseLifetime, so
// two renewals can fail before a lease lapses.
var recoveryLeaseRenewInterval = storage.RecoveryLeaseLifetime / 3

// renewRecoveryLease keeps transfer's lease alive while its body streams, so a
// slow download is not taken over by a second caller and can still record its
// progress. The stream ends with the request, whose deadline bounds the whole
// transfer. If the lease cannot be renewed (it lapsed or was taken over) the
// writer is cut off: the capability may already be in other hands. A failed
// renewal for any other reason is retried at the next tick. The returned
// function stops the renewal and waits for it.
func (a *API) renewRecoveryLease(ctx context.Context, w *blobResponseWriter, transfer storage.RecoveryTransfer) (stop func()) {
	done := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		ticker := time.NewTicker(recoveryLeaseRenewInterval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			renewCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			err := a.Store.RenewRecoveryTransfer(renewCtx, transfer.LeaseID)
			cancel()
			switch {
			case err == nil:
			case errors.Is(err, storage.ErrRecoveryBusy):
				a.warn("recovery_transfer_lease_lost")
				w.cutOff.Store(true)
				return
			default:
				a.warn("recovery_transfer_lease_renew_failed")
			}
		}
	}()
	var once sync.Once
	return func() {
		once.Do(func() { close(done) })
		<-finished
	}
}

func finalizeRecoveryTransfer(r *http.Request, store *storage.Store, transfer storage.RecoveryTransfer, written, expected int64) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
	defer cancel()
	return store.CompleteRecoveryTransfer(ctx, transfer.LeaseID, transfer.StartOffset, written, expected)
}

func (a *API) listBackups(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	backups, err := a.Store.ListBackups(r.Context(), principal.AccountID, limit)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"backups": backups})
}

func (a *API) backupSubroute(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/backups/"), "/")
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	backup, err := a.Store.BackupForAccount(r.Context(), id, principal.AccountID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	switch r.Method {
	case http.MethodGet:
		a.serveEncryptedBlob(w, r, backupBlobRef(backup))
	case http.MethodDelete:
		deleted, err := a.Store.DeleteBackup(r.Context(), id, principal.AccountID)
		if err != nil {
			handleStorageError(w, err)
			return
		}
		a.completeQueuedBlobDeletion(r.Context(), deleted.StorageKey)
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusNotFound, "not_found")
	}
}

func backupBlobRef(backup domain.BackupBlob) uploads.BlobRef {
	return uploads.BlobRef{
		StorageKey: backup.StorageKey, SHA256: backup.CiphertextSHA256,
		Size: backup.SizeBytes, ChunkDigests: backup.ChunkDigests,
	}
}

// serveEncryptedBlob streams a blob, verifying each chunk before it is sent
// (see blobResponseWriter for what a client sees on a failure).
func (a *API) serveEncryptedBlob(w http.ResponseWriter, r *http.Request, ref uploads.BlobRef) {
	// Callers have authorized the request by now. Each range of a multipart
	// response costs a seek plus a chunk read and hash, and a Range header
	// can name thousands of them, so only one range is served (RFC 9110
	// §14.2 lets a server refuse such a request). The recovery route already
	// does the same; clients here send a single range or none.
	if strings.Contains(r.Header.Get("Range"), ",") {
		w.Header().Set("Content-Range", "bytes */"+strconv.FormatInt(ref.Size, 10))
		writeError(w, http.StatusRequestedRangeNotSatisfiable, "multiple_ranges_not_supported")
		return
	}
	blob, ok := a.openBlob(w, r, ref)
	if !ok {
		return
	}
	defer blob.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if ref.SHA256 != "" {
		w.Header().Set("ETag", `"sha256-`+ref.SHA256+`"`)
	}
	writer := &blobResponseWriter{ResponseWriter: w, blob: blob}
	http.ServeContent(writer, r, "encrypted.bin", time.Time{}, blob)
	if a.finishBlobResponse(r, ref, blob, writer) {
		panic(http.ErrAbortHandler)
	}
}

// blobCleanupTimeout bounds each step of an inline blob cleanup: the delete,
// and separately the durable record that keeps a failed delete from being
// forgotten. Tests shorten it.
var blobCleanupTimeout = 5 * time.Second

// blobCleanupContext is a fresh cleanup deadline detached from the request.
// Each step takes its own, so a delete that used up its time cannot leave
// the fallback record that follows it with an expired context.
func blobCleanupContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), blobCleanupTimeout)
}

func (a *API) cleanupUncommittedBlob(ctx context.Context, storageKey string) {
	deleteCtx, cancelDelete := blobCleanupContext(ctx)
	err := a.Blobs.Delete(deleteCtx, storageKey)
	cancelDelete()
	if err == nil {
		return
	}
	queueCtx, cancelQueue := blobCleanupContext(ctx)
	defer cancelQueue()
	if err := a.Store.QueueBlobDeletion(queueCtx, storageKey); err != nil {
		a.warn("blob_cleanup_queue_failed")
	}
}

func (a *API) completeQueuedBlobDeletion(ctx context.Context, storageKey string) {
	deleteCtx, cancelDelete := blobCleanupContext(ctx)
	err := a.Blobs.Delete(deleteCtx, storageKey)
	cancelDelete()
	recordCtx, cancelRecord := blobCleanupContext(ctx)
	defer cancelRecord()
	if err != nil {
		_ = a.Store.RecordBlobDeletionFailure(recordCtx, storageKey)
		a.warn("blob_cleanup_deferred")
		return
	}
	if err := a.Store.CompleteBlobDeletion(recordCtx, storageKey); err != nil {
		a.warn("blob_cleanup_completion_failed")
	}
}

func (a *API) createPushSubscription(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		NotificationMode json.RawMessage `json:"notification_mode"`
		Provider         string          `json:"provider"`
		Endpoint         string          `json:"endpoint"`
		PublicKey        string          `json:"public_key"`
		AuthSecret       string          `json:"auth_secret"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	mode := domain.PushNotificationLegacy
	if len(req.NotificationMode) > 0 {
		mode = ""
		if err := json.Unmarshal(req.NotificationMode, &mode); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_push_subscription")
			return
		}
	}
	if !domain.ValidPushNotificationMode(mode) {
		writeError(w, http.StatusBadRequest, "invalid_push_subscription")
		return
	}
	if mode == domain.PushNotificationLocalDecrypt && principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	valid := (req.Provider == "webpush" && push.ValidateWebPushTarget(push.Notification{Provider: "webpush", Endpoint: req.Endpoint, PublicKey: req.PublicKey, AuthSecret: req.AuthSecret}) == nil) ||
		((req.Provider == "fcm" || req.Provider == "apns") && push.ValidateNativeTarget(req.Provider, req.Endpoint) == nil && req.PublicKey == "" && req.AuthSecret == "")
	if !valid {
		writeError(w, http.StatusBadRequest, "invalid_push_subscription")
		return
	}
	// Only providers this server can deliver through (card I41).
	if !a.pushProviderOffered(req.Provider) {
		writeError(w, http.StatusBadRequest, "push_provider_unavailable")
		return
	}
	subscriptionID, err := a.Store.CreatePushSubscriptionWithMode(r.Context(), principal.AccountID, principal.DeviceID, req.Provider, req.Endpoint, req.PublicKey, req.AuthSecret, mode)
	if err != nil {
		if errors.Is(err, storage.ErrUnauthorized) || errors.Is(err, storage.ErrInvalidInput) {
			handleStorageError(w, err)
			return
		}
		writeError(w, http.StatusInternalServerError, "push_subscription_failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"status": "ok", "subscription_id": subscriptionID, "payload_policy": "generic_encrypted_event_only", "notification_mode": mode})
}

// pushConfig tells the client which providers this server delivers
// through. The VAPID key is sent only with Web Push: FCM and APNs never need
// it (card I41).
func (a *API) pushConfig(w http.ResponseWriter, _ *http.Request, _ domain.Principal) {
	response := map[string]any{
		"enabled":        len(a.PushProviders) > 0,
		"providers":      a.PushProviders,
		"payload_policy": "generic_encrypted_event_only",
	}
	if a.pushProviderOffered("webpush") {
		response["vapid_public_key"] = a.VAPIDPublicKey
	}
	writeJSON(w, http.StatusOK, response)
}

func (a *API) pushProviderOffered(provider string) bool {
	for _, offered := range a.PushProviders {
		if offered == provider {
			return true
		}
	}
	return false
}

// listDevicePushSubscriptions is the privacy-safe diagnostics view: which
// provider this device is registered with and since when. No endpoint,
// token or key is returned.
func (a *API) listDevicePushSubscriptions(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	subscriptions, err := a.Store.ListDevicePushSubscriptions(r.Context(), principal.AccountID, principal.DeviceID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"subscriptions": subscriptions})
}

const pushTestInterval = time.Minute

// sendTestPush sends the ordinary generic wake to this device's own
// registrations, so the user can check notifications end to end. The wake
// carries nothing but the generic event; results are coarse classes.
func (a *API) sendTestPush(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if principal.DeviceID == "" {
		writeError(w, http.StatusBadRequest, "device_session_required")
		return
	}
	if !a.allowPushTest(principal.DeviceID, time.Now()) {
		writeError(w, http.StatusTooManyRequests, "push_test_rate_limited")
		return
	}
	subscriptions, err := a.Store.ListDevicePushSubscriptions(r.Context(), principal.AccountID, principal.DeviceID)
	if err != nil {
		handleStorageError(w, err)
		return
	}
	if len(subscriptions) == 0 {
		writeError(w, http.StatusNotFound, "no_push_subscription")
		return
	}
	type outcome struct {
		NotificationMode string `json:"notification_mode,omitempty"`
		Presentation     string `json:"presentation,omitempty"`
		ID               string `json:"id"`
		Provider         string `json:"provider"`
		Result           string `json:"result"`
	}
	results := make([]outcome, 0, len(subscriptions))
	for _, subscription := range subscriptions {
		// Resolve the mode/target again immediately before the provider call.
		fresh, refreshErr := a.Store.DevicePushSubscriptionForDevice(r.Context(), subscription.ID, principal.AccountID, principal.DeviceID)
		if refreshErr != nil {
			result := "failed"
			if errors.Is(refreshErr, storage.ErrNotFound) {
				result = "gone"
			}
			results = append(results, outcome{ID: subscription.ID, Provider: subscription.Provider, Result: result})
			continue
		}
		target := fresh.Target()
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		err := a.Push.SendEncryptedEventAvailable(ctx, push.Notification{
			NotificationMode: target.NotificationMode,
			Provider:         target.Provider, Endpoint: target.Endpoint,
			PublicKey: target.PublicKey, AuthSecret: target.AuthSecret,
		})
		cancel()
		result := "delivered"
		switch {
		case err == nil:
		case errors.Is(err, push.ErrSubscriptionGone):
			result = "gone"
			_ = a.Store.DisablePushTarget(r.Context(), target)
		case errors.Is(err, push.ErrNoProvider):
			result = "provider_unavailable"
		default:
			result = "failed"
		}
		presentation := ""
		if target.NotificationMode == domain.PushNotificationLocalDecrypt {
			presentation = "none"
		}
		results = append(results, outcome{ID: subscription.ID, Provider: subscription.Provider, Result: result, NotificationMode: target.NotificationMode, Presentation: presentation})
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

func (a *API) allowPushTest(deviceID string, now time.Time) bool {
	a.pushTestMu.Lock()
	defer a.pushTestMu.Unlock()
	if a.pushTestLast == nil {
		a.pushTestLast = map[string]time.Time{}
	}
	if last, ok := a.pushTestLast[deviceID]; ok && now.Sub(last) < pushTestInterval {
		return false
	}
	if len(a.pushTestLast) > 10000 {
		for id, last := range a.pushTestLast {
			if now.Sub(last) >= pushTestInterval {
				delete(a.pushTestLast, id)
			}
		}
	}
	a.pushTestLast[deviceID] = now
	return true
}

func (a *API) deletePushSubscription(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	id := r.PathValue("id")
	if strings.TrimSpace(id) == "" {
		writeError(w, http.StatusBadRequest, "invalid_subscription_id")
		return
	}
	if err := a.Store.DisablePushSubscription(r.Context(), id, principal.AccountID); err != nil {
		handleStorageError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// maxAttachmentBytes is the operator's per-file cap, or the default.
func (a *API) maxAttachmentBytes() int64 {
	if a.MaxAttachmentBytes > 0 {
		return a.MaxAttachmentBytes
	}
	return config.DefaultAttachmentMiB << 20
}
