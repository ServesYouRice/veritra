package httpapi_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/storage"
)

const v3Base = "/api/v1/device-links/v3"

type v3APIFixture struct {
	application                            *app.App
	handler                                http.Handler
	ownerToken                             string
	db                                     *sql.DB
	link                                   storage.DeviceLinkV3
	claim                                  storage.DeviceLinkV3ClaimInput
	claimToken, deviceSecret, sessionToken string
	claimResponse                          []byte
}

func newV3APIFixture(t *testing.T) *v3APIFixture {
	t.Helper()
	application, handler, token, path := newTestAppWithOwner(t)
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	f := &v3APIFixture{application: application, handler: handler, ownerToken: token, db: db}
	status, response := doJSON(t, handler, http.MethodPost, v3Base, token, map[string]interface{}{"code": strings.Repeat("a", 64), "server_origin": "https://example.test", "protocol_version": storage.DeviceLinkV3Protocol})
	if status != http.StatusCreated {
		t.Fatalf("create v3: %d %s", status, response)
	}
	var created struct {
		Link storage.DeviceLinkV3 `json:"device_link"`
	}
	if err := json.Unmarshal(response, &created); err != nil {
		t.Fatal(err)
	}
	f.link = created.Link
	status, response = doJSON(t, handler, http.MethodPost, v3Base+"/claim-enrollment", "", map[string]interface{}{"code": f.link.Code, "reservation_request_id": strings.Repeat("1", 64), "protocol_version": storage.DeviceLinkV3Protocol})
	if status != http.StatusCreated {
		t.Fatalf("reserve v3: %d %s", status, response)
	}
	var reservation struct {
		ID        string `json:"id"`
		AccountID string `json:"account_id"`
		DeviceID  string `json:"device_id"`
		Challenge []byte `json:"challenge"`
	}
	if err := json.Unmarshal(response, &reservation); err != nil {
		t.Fatal(err)
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	f.claimToken, _, err = auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	f.deviceSecret, _, err = auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	f.sessionToken, _, err = auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	f.claim = storage.DeviceLinkV3ClaimInput{Code: f.link.Code, ProtocolVersion: storage.DeviceLinkV3Protocol, ServerOrigin: f.link.ServerOrigin, ReservationRequestID: strings.Repeat("1", 64), EnrollmentReservationID: reservation.ID, DeviceName: "HTTP linked phone", DeviceKeyPackage: bytes.Repeat([]byte{3}, 64), SigningKey: public, TransferPublicKey: bytes.Repeat([]byte{4}, 32), TranscriptHash: bytes.Repeat([]byte{5}, 32), ClaimTag: bytes.Repeat([]byte{6}, 32), ClaimTokenHash: auth.HashToken(f.claimToken), DeviceSecretHash: auth.HashToken(f.deviceSecret), InitialSessionTokenHash: auth.HashToken(f.sessionToken)}
	// Client-side proof assembly is independent of the server builder.
	requestID, _ := hex.DecodeString(f.claim.ReservationRequestID)
	proof := []byte("veritra-device-link-enrollment-v3")
	for _, field := range [][]byte{[]byte(f.claim.ServerOrigin), []byte(f.claim.Code), requestID, []byte(reservation.ID), []byte(reservation.AccountID), []byte(reservation.DeviceID), []byte(f.claim.DeviceName), reservation.Challenge} {
		var size [2]byte
		binary.BigEndian.PutUint16(size[:], uint16(len(field)))
		proof = append(proof, size[:]...)
		proof = append(proof, field...)
	}
	packageHash := sha256.Sum256(f.claim.DeviceKeyPackage)
	for _, field := range [][]byte{public, packageHash[:], f.claim.TransferPublicKey, f.claim.TranscriptHash, f.claim.ClaimTag} {
		proof = append(proof, field...)
	}
	for _, value := range []string{f.claim.ClaimTokenHash, f.claim.DeviceSecretHash, f.claim.InitialSessionTokenHash} {
		decoded, _ := hex.DecodeString(value)
		proof = append(proof, decoded...)
	}
	f.claim.ChallengeSignature = ed25519.Sign(private, proof)
	status, response = doJSON(t, handler, http.MethodPost, v3Base+"/claim", "", f.claim)
	if status != http.StatusAccepted {
		t.Fatalf("claim v3: %d %s", status, response)
	}
	f.claimResponse = bytes.Clone(response)
	if err := json.Unmarshal(response, &created); err != nil {
		t.Fatal(err)
	}
	f.link = created.Link
	return f
}

func (f *v3APIFixture) approve(t *testing.T) {
	t.Helper()
	status, response := doJSON(t, f.handler, http.MethodPost, v3Base+"/"+f.link.ID+"/approve", f.ownerToken, map[string]interface{}{"protocol_version": storage.DeviceLinkV3Protocol, "claim_request_hash": f.link.ClaimRequestHash, "transcript_hash": f.claim.TranscriptHash, "approval_tag": bytes.Repeat([]byte{9}, 32)})
	if status != http.StatusOK {
		t.Fatalf("approve v3: %d %s", status, response)
	}
}

func (f *v3APIFixture) complete(t *testing.T) (int, []byte) {
	t.Helper()
	body, err := json.Marshal(map[string]interface{}{"protocol_version": storage.DeviceLinkV3Protocol, "claim_request_hash": f.link.ClaimRequestHash, "transcript_hash": f.claim.TranscriptHash, "initial_session_token_hash": f.claim.InitialSessionTokenHash})
	if err != nil {
		t.Fatal(err)
	}
	return doRaw(t, f.handler, http.MethodPost, v3Base+"/"+f.link.ID+"/complete", "", body, map[string]string{"Content-Type": "application/json", "X-Veritra-Claim-Token": f.claimToken})
}

func (f *v3APIFixture) sessions(t *testing.T) int {
	t.Helper()
	var count int
	if err := f.db.QueryRow(`SELECT COUNT(*) FROM sessions`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

func TestDeviceLinkV3HTTPReadOnlyPollAndNoSecretResponses(t *testing.T) {
	f := newV3APIFixture(t)
	before := f.sessions(t)
	headers := map[string]string{"X-Veritra-Claim-Token": f.claimToken}
	for _, path := range []string{v3Base + "/" + f.link.ID + "/claim-status", "/api/v1/device-links/" + f.link.ID + "/claim-status"} {
		status, response := doRaw(t, f.handler, http.MethodGet, path, "", nil, headers)
		if strings.HasPrefix(path, v3Base) {
			if status != http.StatusOK {
				t.Fatalf("poll v3: %d %s", status, response)
			}
		} else if status != http.StatusBadRequest {
			t.Fatalf("legacy consuming GET reached v3: %d", status)
		}
	}
	if f.sessions(t) != before {
		t.Fatal("GET created a session")
	}
	f.approve(t)
	status, response := f.complete(t)
	if status != http.StatusOK {
		t.Fatalf("complete v3: %d %s", status, response)
	}
	first := bytes.Clone(response)
	status, response = f.complete(t)
	if status != http.StatusOK || !bytes.Equal(first, response) || f.sessions(t) != before+1 {
		t.Fatalf("lost completion response not idempotent: %d %s", status, response)
	}
	for _, body := range [][]byte{f.claimResponse, first, response} {
		for _, secret := range []string{f.claimToken, f.deviceSecret, f.sessionToken} {
			if bytes.Contains(body, []byte(secret)) {
				t.Fatal("v3 response disclosed a plaintext credential")
			}
		}
		var object map[string]interface{}
		if err := json.Unmarshal(body, &object); err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"token", "device_secret", "claim_token"} {
			if _, exists := object[key]; exists {
				t.Fatalf("legacy response field %s in v3", key)
			}
		}
	}
	status, response = doJSON(t, f.handler, http.MethodGet, v3Base+"/"+f.link.ID, f.sessionToken, nil)
	if status != http.StatusBadRequest {
		t.Fatalf("recipient read source-only context: %d %s", status, response)
	}
}

func TestDeviceLinkV3HTTPClaimReplayAndApprovedCancellationBoundary(t *testing.T) {
	f := newV3APIFixture(t)
	status, response := doJSON(t, f.handler, http.MethodPost, v3Base+"/claim", "", f.claim)
	if status != http.StatusAccepted || !bytes.Equal(response, f.claimResponse) {
		t.Fatalf("claim replay changed public acknowledgement: %d %s", status, response)
	}
	f.approve(t)
	status, response = doJSON(t, f.handler, http.MethodDelete, v3Base+"/"+f.link.ID, f.ownerToken, nil)
	if status != http.StatusConflict {
		t.Fatalf("approved device reported cancelled: %d %s", status, response)
	}
	status, response = f.complete(t)
	if status != http.StatusOK {
		t.Fatalf("rejected cancellation changed link: %d %s", status, response)
	}
}

func TestDeviceLinkV3HTTPCompletionReplayAfterRotationOrLogoutIsTerminal(t *testing.T) {
	for _, mode := range []string{"rotation", "logout"} {
		t.Run(mode, func(t *testing.T) {
			f := newV3APIFixture(t)
			f.approve(t)
			if status, response := f.complete(t); status != http.StatusOK {
				t.Fatalf("complete: %d %s", status, response)
			}
			ctx := context.Background()
			if mode == "rotation" {
				_, newHash, err := auth.NewToken()
				if err != nil {
					t.Fatal(err)
				}
				if err := f.application.Store.RotateSession(ctx, f.claim.InitialSessionTokenHash, newHash); err != nil {
					t.Fatal(err)
				}
			} else if err := f.application.Store.DeleteSession(ctx, f.claim.InitialSessionTokenHash); err != nil {
				t.Fatal(err)
			}
			before := f.sessions(t)
			status, response := f.complete(t)
			if status != http.StatusGone || !bytes.Contains(response, []byte(`"state":"session_unavailable"`)) || f.sessions(t) != before {
				t.Fatalf("completion resurrected session: %d %s", status, response)
			}
		})
	}
}

func TestDeviceLinkV3HTTPLargeTTLAndMissingProtocolFailClosed(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	for _, body := range []map[string]interface{}{
		{"code": strings.Repeat("a", 64), "server_origin": "https://example.test", "protocol_version": storage.DeviceLinkV3Protocol, "expires_in_seconds": int64(1 << 62)},
		{"code": strings.Repeat("a", 64), "server_origin": "https://example.test", "protocol_version": "veritra-device-link-v2"},
		{"code": strings.Repeat("a", 64), "server_origin": "https://example.test/", "protocol_version": storage.DeviceLinkV3Protocol},
	} {
		status, response := doJSON(t, handler, http.MethodPost, v3Base, token, body)
		if status != http.StatusBadRequest {
			t.Fatalf("invalid v3 create: %d %s", status, response)
		}
	}
}
