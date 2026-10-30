package httpapi

import (
	"context"
	"errors"
	"io"
	"net/http"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/uploads"
)

func (a *API) registerHistoryTransferRoutes(mux *http.ServeMux) {
	base := deviceLinkV3Prefix + "/{id}/history"
	mux.HandleFunc("POST "+base, a.withAuth(a.uploadHistoryTransfer))
	mux.HandleFunc("GET "+base, a.withHistoryAccess(a.getHistoryTransfer))
	mux.HandleFunc("GET "+base+"/content", a.withHistoryAccess(a.getHistoryTransferContent))
	mux.HandleFunc("POST "+base+"/ack", a.withHistoryAccess(a.ackHistoryTransfer))
	mux.HandleFunc("DELETE "+base, a.withHistoryAccess(a.cancelHistoryTransfer))
}

type historyHandler func(http.ResponseWriter, *http.Request, storage.HistoryAccess)

func (a *API) withHistoryAccess(next historyHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.Header.Get("Authorization") != "" {
			a.withAuth(func(w http.ResponseWriter, r *http.Request, p domain.Principal) {
				next(w, r, storage.HistoryAccess{AccountID: p.AccountID, DeviceID: p.DeviceID})
			})(w, r)
			return
		}
		hash, ok := deviceLinkV3ClaimTokenHash(w, r)
		if !ok {
			return
		}
		next(w, r, storage.HistoryAccess{ClaimTokenHash: hash})
	}
}

func (a *API) uploadHistoryTransfer(w http.ResponseWriter, r *http.Request, p domain.Principal) {
	w.Header().Set("Cache-Control", "no-store")
	prepared, ok := a.Blobs.(uploads.PreparedStore)
	if !ok {
		writeError(w, http.StatusServiceUnavailable, "upload_failed")
		return
	}
	if a.diskLow(w) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()
	body := r.Body
	stop := context.AfterFunc(ctx, func() { _ = body.Close() })
	defer stop()
	r = r.WithContext(ctx)
	r.Body = http.MaxBytesReader(w, r.Body, storage.MaxHistoryCiphertext+(32<<10))
	reader, err := r.MultipartReader()
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body")
		return
	}
	part, err := reader.NextPart()
	if err != nil || part.FormName() != "metadata" || part.Header.Get("Content-Type") != "application/json" {
		writeError(w, http.StatusBadRequest, "invalid_body")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(part, (12<<10)+1))
	if err != nil || len(raw) > 12<<10 {
		writeError(w, http.StatusBadRequest, "invalid_body")
		return
	}
	var input storage.HistoryTransferInput
	// Use the shared strict decoder, including rejection of trailing JSON.
	if !decodeRawJSON(w, raw, &input) {
		return
	}
	access := storage.HistoryAccess{AccountID: p.AccountID, DeviceID: p.DeviceID}
	existing, err := a.Store.CheckHistoryUpload(ctx, r.PathValue("id"), access, input)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	if existing != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{"transfer": existing})
		return
	}
	part, err = reader.NextPart()
	if err != nil || part.FormName() != "ciphertext" || part.Header.Get("Content-Type") != "application/octet-stream" {
		writeError(w, http.StatusBadRequest, "invalid_body")
		return
	}
	var key string
	writer, err := prepared.PrepareEncryptedBlob(ctx, func(storageKey string) error {
		key = storageKey
		return a.Store.RegisterHistoryUpload(ctx, r.PathValue("id"), access, input, key)
	})
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	defer writer.Close()
	abort := func() {
		cleanupCtx, done := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer done()
		if err := a.Store.AbortHistoryUpload(cleanupCtx, key); err != nil {
			a.warn("blob_cleanup_queue_failed")
		}
	}
	blob, err := writer.Write(ctx, io.LimitReader(part, input.SizeBytes+1))
	if err != nil {
		abort()
		writeError(w, http.StatusBadRequest, "upload_failed")
		return
	}
	if blob.Size != input.SizeBytes || blob.SHA256 != input.CiphertextSHA256 {
		abort()
		writeError(w, http.StatusBadRequest, "invalid_body")
		return
	}
	if _, err = reader.NextPart(); !errors.Is(err, io.EOF) {
		abort()
		writeError(w, http.StatusBadRequest, "invalid_body")
		return
	}
	transfer, err := a.Store.FinalizeHistoryUpload(ctx, r.PathValue("id"), access, input, blob)
	// Deliberately retain the intent/ref after any finalization error. A commit
	// outcome may be ambiguous; cleanup/retry reconciles its durable state.
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]interface{}{"transfer": transfer})
}

func (a *API) getHistoryTransfer(w http.ResponseWriter, r *http.Request, access storage.HistoryAccess) {
	t, err := a.Store.HistoryTransferForAccess(r.Context(), r.PathValue("id"), access, false)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"transfer": t})
}

func (a *API) getHistoryTransferContent(w http.ResponseWriter, r *http.Request, access storage.HistoryAccess) {
	t, err := a.Store.HistoryTransferForAccess(r.Context(), r.PathValue("id"), access, true)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	a.serveEncryptedBlob(w, r, t.Ref)
}

func (a *API) ackHistoryTransfer(w http.ResponseWriter, r *http.Request, access storage.HistoryAccess) {
	var input struct {
		ProtocolVersion  string `json:"protocol_version"`
		TransferID       string `json:"transfer_id"`
		CiphertextSHA256 string `json:"ciphertext_sha256"`
	}
	if !decodeJSON(w, r, &input) {
		return
	}
	if input.ProtocolVersion != storage.DeviceLinkV3Protocol {
		writeError(w, http.StatusBadRequest, "invalid_body")
		return
	}
	t, err := a.Store.AcknowledgeHistoryTransfer(r.Context(), r.PathValue("id"), access, input.TransferID, input.CiphertextSHA256)
	if err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"transfer": t})
}

func (a *API) cancelHistoryTransfer(w http.ResponseWriter, r *http.Request, access storage.HistoryAccess) {
	if err := a.Store.CancelHistoryTransfer(r.Context(), r.PathValue("id"), access); err != nil {
		a.deviceLinkV3Error(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": "cancelled"})
}
