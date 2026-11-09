package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/realtime"
	"private-messenger/server/internal/storage"
)

// W11 encrypted profile routes (docs/designs/W11-profiles.md). The body is an
// opaque blob: VPE1 + 8-byte nonce prefix + AEAD ciphertext. The server checks
// its magic, its size bucket and the key id's shape, never its content, and
// never logs the body or the key id.

const (
	profileOverhead   = 4 + 8 + 16 // magic, nonce prefix, GCM tag
	profileSmallBytes = 4*1024 + profileOverhead
	profileLargeBytes = 256*1024 + profileOverhead
	profileMagic      = "VPE1"
)

func (a *API) registerProfileRoutes(mux *http.ServeMux) {
	mux.HandleFunc("PUT /api/v1/profiles/account/me", a.withAuth(a.withWriteBudget(a.putAccountProfile)))
	mux.HandleFunc("GET /api/v1/profiles/account/{account_id}", a.withAuth(a.getAccountProfile))
	mux.HandleFunc("PUT /api/v1/conversations/{id}/profile", a.withAuth(a.withWriteBudget(a.putConversationProfile)))
	mux.HandleFunc("GET /api/v1/conversations/{id}/profile", a.withAuth(a.getConversationProfile))
	mux.HandleFunc("DELETE /api/v1/conversations/{id}/title", a.withAuth(a.withWriteBudget(a.clearConversationTitle)))
	mux.HandleFunc("POST /api/v1/profiles/versions", a.withAuth(a.profileVersions))
	// C3 community info (docs/designs/C3-private-channels-and-info.md).
	mux.HandleFunc("PUT /api/v1/communities/{id}/info", a.withAuth(a.withWriteBudget(a.putCommunityInfo)))
	mux.HandleFunc("GET /api/v1/communities/{id}/info", a.withAuth(a.getCommunityInfo))
	mux.HandleFunc("PUT /api/v1/communities/{id}/categories/{cid}", a.withAuth(a.withWriteBudget(a.putCategoryInfo)))
	mux.HandleFunc("GET /api/v1/communities/{id}/categories/{cid}", a.withAuth(a.getCategoryInfo))
	mux.HandleFunc("PUT /api/v1/channels/{id}/info", a.withAuth(a.withWriteBudget(a.putChannelInfo)))
	mux.HandleFunc("GET /api/v1/channels/{id}/info", a.withAuth(a.getChannelInfo))
}

func validProfileKeyID(v string) bool {
	if len(v) != 32 {
		return false
	}
	for _, c := range v {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// parseProfilePrecondition reads If-Match: "<version>" or If-None-Match: *.
// It returns the expected stored version: 0 for the first write.
func parseProfilePrecondition(r *http.Request) (int64, bool) {
	if r.Header.Get("If-None-Match") == "*" && r.Header.Get("If-Match") == "" {
		return 0, true
	}
	raw := strings.Trim(r.Header.Get("If-Match"), `"`)
	if raw == "" || r.Header.Get("If-None-Match") != "" {
		return 0, false
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || v < 1 {
		return 0, false
	}
	return v, true
}

func (a *API) putAccountProfile(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.putProfile(w, r, principal, storage.ProfileKindAccount, principal.AccountID, "")
}

func (a *API) putConversationProfile(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.putProfile(w, r, principal, storage.ProfileKindConversation, r.PathValue("id"), "")
}

func (a *API) putCommunityInfo(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.putProfile(w, r, principal, storage.ProfileKindCommunity, r.PathValue("id"), "")
}

func (a *API) putCategoryInfo(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.putProfile(w, r, principal, storage.ProfileKindCategory, r.PathValue("cid"), r.PathValue("id"))
}

func (a *API) putChannelInfo(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.putProfile(w, r, principal, storage.ProfileKindChannel, r.PathValue("id"), "")
}

func (a *API) getCommunityInfo(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.getProfile(w, r, principal, storage.ProfileKindCommunity, r.PathValue("id"))
}

func (a *API) getCategoryInfo(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	p, err := a.Store.GetCategoryInfo(r.Context(), principal.AccountID, r.PathValue("id"), r.PathValue("cid"))
	a.writeProfile(w, r, p, err)
}

func (a *API) getChannelInfo(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.getProfile(w, r, principal, storage.ProfileKindChannel, r.PathValue("id"))
}

func (a *API) putProfile(w http.ResponseWriter, r *http.Request, principal domain.Principal, kind, subjectID, communityID string) {
	if r.Header.Get("X-Private-Messenger-Encrypted") != "1" {
		writeError(w, http.StatusBadRequest, "encrypted_upload_header_required")
		return
	}
	keyID := r.Header.Get("X-Profile-Key-Id")
	expected, ok := parseProfilePrecondition(r)
	if !validProfileKeyID(keyID) || !ok {
		writeError(w, http.StatusBadRequest, "invalid_profile")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, profileLargeBytes))
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "profile_too_large")
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_profile")
		return
	}
	if (len(body) != profileSmallBytes && len(body) != profileLargeBytes) || string(body[:min(len(body), 4)]) != profileMagic {
		writeError(w, http.StatusBadRequest, "invalid_profile")
		return
	}
	version, notices, err := a.Store.PutProfile(r.Context(), storage.ProfileWrite{
		Kind: kind, SubjectID: subjectID, WriterAccountID: principal.AccountID,
		KeyID: keyID, Ciphertext: body, ExpectedVersion: expected, CommunityID: communityID,
	})
	switch {
	case errors.Is(err, storage.ErrProfileVersionConflict):
		writeError(w, http.StatusPreconditionFailed, "version_conflict")
		return
	case errors.Is(err, storage.ErrCategoryLimit):
		writeError(w, http.StatusConflict, "category_limit_reached")
		return
	case err != nil:
		handleStorageError(w, err)
		return
	}
	for _, n := range notices {
		a.publishCommittedEvent(r.Context(), []string{n.AccountID}, realtime.Event{
			Version: "v1", Type: n.EventType, ID: n.EventID, Payload: n.Payload, CreatedAt: time.Now().UTC(),
		})
	}
	writeJSON(w, http.StatusOK, map[string]int64{"version": version})
}

func (a *API) getAccountProfile(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.getProfile(w, r, principal, storage.ProfileKindAccount, r.PathValue("account_id"))
}

func (a *API) getConversationProfile(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	a.getProfile(w, r, principal, storage.ProfileKindConversation, r.PathValue("id"))
}

func (a *API) getProfile(w http.ResponseWriter, r *http.Request, principal domain.Principal, kind, subjectID string) {
	p, err := a.Store.GetProfile(r.Context(), principal.AccountID, kind, subjectID)
	a.writeProfile(w, r, p, err)
}

func (a *API) writeProfile(w http.ResponseWriter, r *http.Request, p storage.EncryptedProfile, err error) {
	if err != nil {
		// Strangers, ex-members, blocked accounts and missing records all
		// answer 404, so the route is not an existence oracle.
		if errors.Is(err, storage.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found")
			return
		}
		handleStorageError(w, err)
		return
	}
	etag := `"` + strconv.FormatInt(p.Version, 10) + `"`
	w.Header().Set("ETag", etag)
	w.Header().Set("X-Profile-Key-Id", p.KeyID)
	w.Header().Set("Cache-Control", "no-store")
	if r.Header.Get("If-None-Match") != "*" && strings.Trim(r.Header.Get("If-None-Match"), `"`) == strconv.FormatInt(p.Version, 10) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(p.Ciphertext)
}

func (a *API) clearConversationTitle(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if err := a.Store.ClearLegacyConversationTitle(r.Context(), r.PathValue("id"), principal.AccountID); err != nil {
		handleStorageError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) profileVersions(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req struct {
		AccountIDs      []string `json:"account_ids"`
		ConversationIDs []string `json:"conversation_ids"`
		CommunityIDs    []string `json:"community_ids"`
		CategoryIDs     []string `json:"category_ids"`
		ChannelIDs      []string `json:"channel_ids"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_input")
		return
	}
	versions, err := a.Store.SubjectVersions(r.Context(), principal.AccountID, storage.ProfileVersionQuery{
		AccountIDs: req.AccountIDs, ConversationIDs: req.ConversationIDs,
		CommunityIDs: req.CommunityIDs, CategoryIDs: req.CategoryIDs, ChannelIDs: req.ChannelIDs,
	})
	if err != nil {
		handleStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"versions": versions})
}
