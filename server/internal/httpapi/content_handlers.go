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
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/push"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
)

func (a *API) uploadAttachment(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
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
	storageKey, sha, size, err := a.Blobs.PutEncryptedBlob(r.Context(), http.MaxBytesReader(w, r.Body, 50<<20))
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
		StorageKey:       storageKey,
		CiphertextSHA256: sha,
		SizeBytes:        size,
		CryptoMetadata:   metadata,
	})
	if err != nil {
		a.cleanupUncommittedBlob(r.Context(), storageKey)
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
		serveEncryptedBlob(w, r, a.Blobs, attachment.StorageKey, attachment.CiphertextSHA256, attachment.SizeBytes)
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
	if r.Header.Get("X-Private-Messenger-Encrypted") != "1" {
		writeError(w, http.StatusBadRequest, "encrypted_upload_header_required")
		return
	}
	metadata := json.RawMessage(r.Header.Get("X-Key-Derivation-Metadata"))
	if len(metadata) == 0 {
		writeError(w, http.StatusBadRequest, "key_derivation_metadata_required")
		return
	}
	if !validBackupCryptoMetadata(metadata) {
		writeError(w, http.StatusBadRequest, "invalid_key_derivation_metadata")
		return
	}
	recoveryToken, err := base64.RawURLEncoding.DecodeString(r.Header.Get("X-Recovery-Token"))
	if err != nil || len(recoveryToken) != 32 {
		writeError(w, http.StatusBadRequest, "recovery_token_required")
		return
	}
	recoveryTokenHash := sha256.Sum256(recoveryToken)
	storageKey, sha, size, err := a.Blobs.PutEncryptedBlob(r.Context(), http.MaxBytesReader(w, r.Body, 100<<20))
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "upload_too_large")
			return
		}
		writeError(w, http.StatusInternalServerError, "backup_upload_failed")
		return
	}
	if err := a.Store.CreateBackupBlob(r.Context(), principal.AccountID, principal.DeviceID, storageKey, sha, size, metadata, recoveryTokenHash[:]); err != nil {
		a.cleanupUncommittedBlob(r.Context(), storageKey)
		if errors.Is(err, storage.ErrStorageQuota) {
			handleStorageError(w, err)
			return
		}
		writeError(w, http.StatusInternalServerError, "backup_record_failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]interface{}{"storage_key": storageKey, "ciphertext_sha256": sha, "size_bytes": size})
}

func validBackupCryptoMetadata(raw json.RawMessage) bool {
	var metadata struct {
		Version      int    `json:"version"`
		Algorithm    string `json:"algorithm"`
		ChunkSize    int    `json:"chunk_size"`
		StateCounter int64  `json:"state_counter"`
	}
	var fields map[string]json.RawMessage
	return json.Unmarshal(raw, &metadata) == nil && json.Unmarshal(raw, &fields) == nil &&
		len(fields) == 4 && metadata.Version == 1 && metadata.Algorithm == "AES-256-GCM-chunked" &&
		metadata.ChunkSize == 1024*1024 && metadata.StateCounter > 0
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
	start, end, err = recoveryRange(r, transfer.Backup.SizeBytes)
	if err != nil {
		_ = finalizeRecoveryTransfer(r, a.Store, transfer, 0, 0)
		writeError(w, http.StatusRequestedRangeNotSatisfiable, "invalid_recovery_range")
		return
	}
	serveRecoveryBlob(w, r, a.Store, a.Blobs, transfer, end-start+1)
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

type recoveryResponseWriter struct {
	http.ResponseWriter
	written int64
	status  int
	err     error
}

func (w *recoveryResponseWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(p)
	w.written += int64(n)
	if err != nil {
		w.err = err
	}
	return n, err
}

func (w *recoveryResponseWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func serveRecoveryBlob(w http.ResponseWriter, r *http.Request, store *storage.Store, blobs uploads.Store, transfer storage.RecoveryTransfer, expected int64) {
	file, err := blobs.Open(r.Context(), transfer.Backup.StorageKey, transfer.Backup.CiphertextSHA256, transfer.Backup.SizeBytes)
	if err != nil {
		_ = finalizeRecoveryTransfer(r, store, transfer, 0, 0)
		if errors.Is(err, uploads.ErrBlobIntegrity) {
			writeError(w, http.StatusInternalServerError, "blob_integrity_failed")
			return
		}
		writeError(w, http.StatusNotFound, "blob_not_found")
		return
	}
	defer file.Close()
	w.Header().Set("Cache-Control", "no-store, private")
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if transfer.Backup.CiphertextSHA256 != "" {
		w.Header().Set("ETag", `"sha256-`+transfer.Backup.CiphertextSHA256+`"`)
	}
	tracked := &recoveryResponseWriter{ResponseWriter: w}
	request := r.Clone(r.Context())
	request.Header.Del("If-Match")
	request.Header.Del("If-None-Match")
	request.Header.Del("If-Modified-Since")
	request.Header.Del("If-Unmodified-Since")
	request.Header.Del("If-Range")
	http.ServeContent(tracked, request, "encrypted.bin", time.Time{}, file)
	validResponse := tracked.status == http.StatusOK || tracked.status == http.StatusPartialContent
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
	if !validResponse || tracked.written > expected {
		tracked.written = 0
	}
	if err := finalizeRecoveryTransfer(r, store, transfer, tracked.written, expected); err != nil {
		return
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
		serveEncryptedBlob(w, r, a.Blobs, backup.StorageKey, backup.CiphertextSHA256, backup.SizeBytes)
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

func serveEncryptedBlob(w http.ResponseWriter, r *http.Request, blobs uploads.Store, storageKey, sha string, size int64) {
	file, err := blobs.Open(r.Context(), storageKey, sha, size)
	if err != nil {
		if errors.Is(err, uploads.ErrBlobIntegrity) {
			writeError(w, http.StatusInternalServerError, "blob_integrity_failed")
			return
		}
		writeError(w, http.StatusNotFound, "blob_not_found")
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if sha != "" {
		w.Header().Set("ETag", `"sha256-`+sha+`"`)
	}
	http.ServeContent(w, r, "encrypted.bin", time.Time{}, file)
}

func (a *API) cleanupUncommittedBlob(ctx context.Context, storageKey string) {
	cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if err := a.Blobs.Delete(cleanupCtx, storageKey); err == nil {
		return
	}
	if err := a.Store.QueueBlobDeletion(cleanupCtx, storageKey); err != nil {
		a.warn("blob_cleanup_queue_failed")
	}
}

func (a *API) completeQueuedBlobDeletion(ctx context.Context, storageKey string) {
	cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if err := a.Blobs.Delete(cleanupCtx, storageKey); err != nil {
		_ = a.Store.RecordBlobDeletionFailure(cleanupCtx, storageKey)
		a.warn("blob_cleanup_deferred")
		return
	}
	if err := a.Store.CompleteBlobDeletion(cleanupCtx, storageKey); err != nil {
		a.warn("blob_cleanup_completion_failed")
	}
}

func (a *API) createPushSubscription(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		Provider   string `json:"provider"`
		Endpoint   string `json:"endpoint"`
		PublicKey  string `json:"public_key"`
		AuthSecret string `json:"auth_secret"`
	}
	if !decodeJSON(w, r, &req) {
		return
	}
	valid := (req.Provider == "webpush" && push.ValidateWebPushTarget(push.Notification{Provider: "webpush", Endpoint: req.Endpoint, PublicKey: req.PublicKey, AuthSecret: req.AuthSecret}) == nil) ||
		((req.Provider == "fcm" || req.Provider == "apns") && push.ValidateNativeTarget(req.Provider, req.Endpoint) == nil && req.PublicKey == "" && req.AuthSecret == "")
	if !valid {
		writeError(w, http.StatusBadRequest, "invalid_push_subscription")
		return
	}
	subscriptionID, err := a.Store.CreatePushSubscription(r.Context(), principal.AccountID, principal.DeviceID, req.Provider, req.Endpoint, req.PublicKey, req.AuthSecret)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "push_subscription_failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"status": "ok", "subscription_id": subscriptionID, "payload_policy": "generic_encrypted_event_only"})
}

func (a *API) pushConfig(w http.ResponseWriter, _ *http.Request, _ domain.Principal) {
	writeJSON(w, http.StatusOK, map[string]any{
		"enabled":          len(a.PushProviders) > 0,
		"providers":        a.PushProviders,
		"vapid_public_key": a.VAPIDPublicKey,
	})
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
