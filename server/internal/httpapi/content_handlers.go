package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
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
	if !json.Valid(metadata) {
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
		_ = a.Blobs.Delete(r.Context(), storageKey)
		writeError(w, http.StatusInternalServerError, "attachment_record_failed")
		return
	}
	writeJSON(w, http.StatusCreated, attachment)
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
		if err := a.Blobs.Delete(r.Context(), deleted.StorageKey); err != nil {
			a.warn("attachment_blob_cleanup_failed", "attachment_id", deleted.ID, "err", err)
		}
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
	if !json.Valid(metadata) {
		writeError(w, http.StatusBadRequest, "invalid_key_derivation_metadata")
		return
	}
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
	if err := a.Store.CreateBackupBlob(r.Context(), principal.AccountID, principal.DeviceID, storageKey, sha, size, metadata); err != nil {
		_ = a.Blobs.Delete(r.Context(), storageKey)
		writeError(w, http.StatusInternalServerError, "backup_record_failed")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]interface{}{"storage_key": storageKey, "ciphertext_sha256": sha, "size_bytes": size})
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
		if err := a.Blobs.Delete(r.Context(), deleted.StorageKey); err != nil {
			a.warn("backup_blob_cleanup_failed", "backup_id", deleted.ID, "err", err)
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		writeError(w, http.StatusNotFound, "not_found")
	}
}

func serveEncryptedBlob(w http.ResponseWriter, r *http.Request, blobs uploads.Store, storageKey, sha string, size int64) {
	file, err := blobs.Open(storageKey)
	if err != nil {
		writeError(w, http.StatusNotFound, "blob_not_found")
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	if sha != "" {
		w.Header().Set("ETag", `"sha256-`+sha+`"`)
	}
	_, _ = io.Copy(w, file)
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
	if req.Provider != "webpush" || push.ValidateWebPushTarget(push.Notification{Endpoint: req.Endpoint, PublicKey: req.PublicKey, AuthSecret: req.AuthSecret}) != nil {
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
		"enabled":          a.VAPIDPublicKey != "",
		"vapid_public_key": a.VAPIDPublicKey,
	})
}

func (a *API) notifyPush(ctx context.Context, conversationID, senderAccountID string) {
	if a.Push == nil {
		return
	}
	targets, err := a.Store.PushTargetsForConversation(ctx, conversationID, senderAccountID)
	if err != nil || len(targets) == 0 {
		return
	}
	go a.deliverPush(targets)
}

func (a *API) deliverPush(targets []storage.PushTarget) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	failures := 0
	for _, target := range targets {
		err := a.Push.SendEncryptedEventAvailable(ctx, push.Notification{
			Endpoint:   target.Endpoint,
			PublicKey:  target.PublicKey,
			AuthSecret: target.AuthSecret,
		})
		switch {
		case err == nil, errors.Is(err, push.ErrNoProvider):
		case errors.Is(err, push.ErrSubscriptionGone):
			_ = a.Store.DisablePushTarget(ctx, target.ID)
		default:
			failures++
		}
		if ctx.Err() != nil {
			break
		}
	}
	if failures > 0 {
		a.warn("push_delivery_incomplete", "failed_count", failures)
	}
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
