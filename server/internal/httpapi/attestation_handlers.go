package httpapi

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"

	"private-messenger/server/internal/attest"
)

// ClaimedBuild is the server's own statement about what it runs. It is not
// evidence: only the platform report is.
type ClaimedBuild struct {
	Version     string `json:"version"`
	Commit      string `json:"commit"`
	ImageDigest string `json:"image_digest,omitempty"`
}

// attestation serves the L3 proof hook (registered only while it is on). It
// logs nothing about the nonce or the report; the request log carries the
// route pattern only. Clients never use it to change a trust decision.
func (a *API) attestation(w http.ResponseWriter, r *http.Request) {
	raw, err := hex.DecodeString(r.URL.Query().Get("nonce"))
	if err != nil || len(raw) != 32 {
		writeError(w, http.StatusBadRequest, "invalid_nonce")
		return
	}
	var nonce [32]byte
	copy(nonce[:], raw)
	ev, err := a.Attest.Report(r.Context(), attest.UserData(nonce, a.TLSKeyHash))
	if err != nil {
		if errors.Is(err, attest.ErrNotConfigured) {
			writeError(w, http.StatusNotFound, "not_found")
			return
		}
		writeError(w, http.StatusServiceUnavailable, "attestation_unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"format":        attest.UserDataLabel,
		"kind":          ev.Kind,
		"report":        base64.StdEncoding.EncodeToString(ev.Report),
		"claimed_build": a.ClaimedBuild,
	})
}
