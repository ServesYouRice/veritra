package httpapi_test

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
)

const (
	testSFUKey    = "sfu-key"
	testSFUSecret = "0123456789abcdef0123456789abcdef-secret"
)

func withSFU(c *config.Config) {
	c.SFUURL = "wss://sfu.example.test"
	c.SFUAPIKey = testSFUKey
	c.SFUAPISecret = testSFUSecret
}

type roomJoinReply struct {
	CallID       string `json:"call_id"`
	Epoch        int64  `json:"epoch"`
	Created      bool   `json:"created"`
	SFUToken     string `json:"sfu_token"`
	SFUURL       string `json:"sfu_url"`
	Nonce        string `json:"nonce"`
	Participants []struct {
		DeviceID  string `json:"device_id"`
		AccountID string `json:"account_id"`
	} `json:"participants"`
}

func roomDM(t *testing.T, handler http.Handler, ownerToken, memberID string) string {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/conversations", ownerToken, map[string]interface{}{"kind": "dm", "member_account_ids": []string{memberID}})
	if status != http.StatusCreated {
		t.Fatalf("create DM status=%d body=%s", status, response)
	}
	var dm struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(response, &dm)
	return dm.ID
}

func joinRoom(t *testing.T, handler http.Handler, token, conversationID string) roomJoinReply {
	t.Helper()
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/join", token, map[string]string{"conversation_id": conversationID})
	if status != http.StatusOK {
		t.Fatalf("join status=%d body=%s", status, response)
	}
	var reply roomJoinReply
	if err := json.Unmarshal(response, &reply); err != nil {
		t.Fatal(err)
	}
	return reply
}

func jwtPayload(t *testing.T, token string) map[string]any {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token %q", token)
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(raw, &claims); err != nil {
		t.Fatal(err)
	}
	return claims
}

func TestRoomsAreUnavailableWithoutSFU(t *testing.T) {
	handler, token, _ := newTestHandlerWithOwner(t)
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/join", token, map[string]string{"conversation_id": "conv_x"})
	if status != http.StatusServiceUnavailable || !bytes.Contains(response, []byte("rooms_unavailable")) {
		t.Fatalf("status=%d body=%s", status, response)
	}
}

func TestRoomJoinLeaveAndTokenPrivacy(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, withSFU)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "roommember")
	outsiderToken := registerMember(t, handler, ownerToken, "roomoutsider")
	conversationID := roomDM(t, handler, ownerToken, memberID)

	first := joinRoom(t, handler, ownerToken, conversationID)
	if !first.Created || first.Epoch != 0 || len(first.Participants) != 1 || first.SFUURL == "" || first.Nonce == "" {
		t.Fatalf("first join=%+v", first)
	}
	claims := jwtPayload(t, first.SFUToken)
	rawClaims, _ := json.Marshal(claims)
	for _, secret := range []string{conversationID, ownerID, memberID, first.CallID} {
		if bytes.Contains(rawClaims, []byte(secret)) {
			t.Fatalf("token names %q: %s", secret, rawClaims)
		}
	}
	if claims["iss"] != testSFUKey {
		t.Fatalf("iss=%v", claims["iss"])
	}
	second := joinRoom(t, handler, memberToken, conversationID)
	if second.Created || second.CallID != first.CallID || len(second.Participants) != 2 {
		t.Fatalf("second join=%+v", second)
	}
	if status, _ := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/join", outsiderToken, map[string]string{"conversation_id": conversationID}); status != http.StatusForbidden {
		t.Fatalf("outsider join status=%d", status)
	}
	// A device that is not in the room cannot read or change it.
	if status, _ := doJSON(t, handler, http.MethodGet, "/api/v1/rooms/"+first.CallID, outsiderToken, nil); status != http.StatusForbidden {
		t.Fatalf("outsider state status=%d", status)
	}

	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/"+first.CallID+"/leave", ownerToken, struct{}{})
	if status != http.StatusOK || !bytes.Contains(response, []byte(`"ended":false`)) {
		t.Fatalf("leave status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodPost, "/api/v1/rooms/"+first.CallID+"/leave", memberToken, struct{}{})
	if status != http.StatusOK || !bytes.Contains(response, []byte(`"ended":true`)) {
		t.Fatalf("last leave status=%d body=%s", status, response)
	}
	if again := joinRoom(t, handler, ownerToken, conversationID); !again.Created || again.CallID == first.CallID {
		t.Fatalf("rejoin after end=%+v", again)
	}
}

// postOffer posts a join offer for the seat joined with reply, expiring in
// expiresIn, and returns the status.
func postOffer(t *testing.T, handler http.Handler, token, callID string, reply roomJoinReply, expiresIn time.Duration) int {
	t.Helper()
	code, _ := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/"+callID+"/offer", token, map[string]any{
		"nonce": reply.Nonce, "key_package": bytes.Repeat([]byte{7}, 80), "signature": bytes.Repeat([]byte{8}, 64),
		"expires_at": time.Now().Add(expiresIn).Unix(),
	})
	return code
}

func TestRoomAcceptsOneCommitPerEpoch(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, withSFU)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "commitmember")
	conversationID := roomDM(t, handler, ownerToken, memberID)
	room := joinRoom(t, handler, ownerToken, conversationID)
	member := joinRoom(t, handler, memberToken, conversationID)
	if code := postOffer(t, handler, memberToken, room.CallID, member, 30*time.Second); code != http.StatusNoContent {
		t.Fatalf("offer status=%d", code)
	}
	var memberDevice string
	for _, p := range member.Participants {
		if p.AccountID == memberID {
			memberDevice = p.DeviceID
		}
	}
	// The creator adds the member, which may then commit too.
	if status, response := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/"+room.CallID+"/commit", ownerToken, map[string]any{
		"expected_epoch": 0, "commit": []byte{1}, "welcome": []byte{9}, "added_device_ids": []string{memberDevice},
	}); status != http.StatusOK {
		t.Fatalf("add commit status=%d body=%s", status, response)
	}

	var wg sync.WaitGroup
	codes := make([]int, 2)
	for i, token := range []string{ownerToken, memberToken} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes[i], _ = doJSON(t, handler, http.MethodPost, "/api/v1/rooms/"+room.CallID+"/commit", token, map[string]any{
				"expected_epoch": 1, "commit": []byte{1, byte(i)},
			})
		}()
	}
	wg.Wait()
	if !(codes[0] == 200 && codes[1] == 409) && !(codes[0] == 409 && codes[1] == 200) {
		t.Fatalf("codes=%v want one 200 and one 409", codes)
	}
	status, response := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/"+room.CallID+"/commit", ownerToken, map[string]any{"expected_epoch": 2, "commit": []byte{2}})
	if status != http.StatusOK {
		t.Fatalf("epoch 2 commit status=%d body=%s", status, response)
	}
	status, response = doJSON(t, handler, http.MethodGet, "/api/v1/rooms/"+room.CallID+"/commits?after=0", memberToken, nil)
	var listed struct {
		Commits []struct {
			Epoch int64 `json:"epoch"`
		} `json:"commits"`
	}
	if status != http.StatusOK || json.Unmarshal(response, &listed) != nil || len(listed.Commits) != 3 || listed.Commits[2].Epoch != 3 {
		t.Fatalf("commits status=%d body=%s", status, response)
	}
	// An empty commit is refused.
	if status, _ := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/"+room.CallID+"/commit", ownerToken, map[string]any{"expected_epoch": 3, "commit": []byte{}}); status != http.StatusBadRequest {
		t.Fatalf("empty commit status=%d", status)
	}
}

func TestRoomCommitNeedsASeatInTheGroup(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, withSFU)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "waitingmember")
	conversationID := roomDM(t, handler, ownerToken, memberID)
	room := joinRoom(t, handler, ownerToken, conversationID)
	member := joinRoom(t, handler, memberToken, conversationID)
	commit := func(token string, epoch int64, added []string) int {
		code, _ := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/"+room.CallID+"/commit", token, map[string]any{
			"expected_epoch": epoch, "commit": []byte{1}, "added_device_ids": added,
		})
		return code
	}
	// A seat still waiting for its Welcome cannot take an epoch.
	if code := commit(memberToken, 0, nil); code != http.StatusForbidden {
		t.Fatalf("waiting seat commit status=%d want 403", code)
	}
	var memberDevice string
	for _, p := range member.Participants {
		if p.AccountID == memberID {
			memberDevice = p.DeviceID
		}
	}
	// Naming a seat that posted no offer does not put it in the group.
	if code := commit(ownerToken, 0, []string{memberDevice}); code != http.StatusOK {
		t.Fatalf("owner commit status=%d", code)
	}
	if code := commit(memberToken, 1, nil); code != http.StatusForbidden {
		t.Fatalf("seat without an offer marked in group: status=%d want 403", code)
	}
}

func TestRoomOfferExpiresWithinTheWindow(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, withSFU)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "lateoffer")
	conversationID := roomDM(t, handler, ownerToken, memberID)
	room := joinRoom(t, handler, ownerToken, conversationID)
	member := joinRoom(t, handler, memberToken, conversationID)
	if code := postOffer(t, handler, memberToken, room.CallID, member, 90*time.Second); code != http.StatusBadRequest {
		t.Fatalf("90 s offer status=%d want 400", code)
	}
	if code := postOffer(t, handler, memberToken, room.CallID, member, 50*time.Second); code != http.StatusNoContent {
		t.Fatalf("50 s offer status=%d", code)
	}
}

func signedWebhook(t *testing.T, handler http.Handler, secret string, body []byte, bodyHash string) int {
	t.Helper()
	b := func(v []byte) string { return base64.RawURLEncoding.EncodeToString(v) }
	if bodyHash == "" {
		sum := sha256.Sum256(body)
		bodyHash = base64.StdEncoding.EncodeToString(sum[:])
	}
	header, _ := json.Marshal(map[string]string{"alg": "HS256", "typ": "JWT"})
	claims, _ := json.Marshal(map[string]any{"iss": testSFUKey, "exp": time.Now().Add(time.Minute).Unix(), "sha256": bodyHash})
	signing := b(header) + "." + b(claims)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(signing))
	req := httptest.NewRequest(http.MethodPost, "/api/v1/rooms/webhook", bytes.NewReader(body))
	req.Header.Set("Authorization", signing+"."+b(mac.Sum(nil)))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec.Code
}

func TestRoomWebhookChecksSignatureAndEndsSeats(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, withSFU)
	_, memberID := registerMemberWithID(t, handler, ownerToken, "webhookmember")
	conversationID := roomDM(t, handler, ownerToken, memberID)
	room := joinRoom(t, handler, ownerToken, conversationID)
	claims := jwtPayload(t, room.SFUToken)
	identity := claims["sub"].(string)
	sfuRoom := claims["video"].(map[string]any)["room"].(string)
	body, _ := json.Marshal(map[string]any{"event": "participant_left", "room": map[string]string{"name": sfuRoom}, "participant": map[string]string{"identity": identity}})

	if code := signedWebhook(t, handler, "wrong-secret-wrong-secret-wrong-secret", body, ""); code != http.StatusUnauthorized {
		t.Fatalf("forged status=%d", code)
	}
	if code := signedWebhook(t, handler, testSFUSecret, body, "AAAA"); code != http.StatusUnauthorized {
		t.Fatalf("wrong body hash status=%d", code)
	}
	if code := signedWebhook(t, handler, testSFUSecret, body, ""); code != http.StatusNoContent {
		t.Fatalf("valid status=%d", code)
	}
	// The only seat is gone, so the room has ended and a new join creates one.
	if again := joinRoom(t, handler, ownerToken, conversationID); !again.Created {
		t.Fatalf("rejoin=%+v", again)
	}
}

func TestRoomOfferNeedsTheIssuedNonceAndIsListedForMembers(t *testing.T) {
	_, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, withSFU)
	memberToken, memberID := registerMemberWithID(t, handler, ownerToken, "offermember")
	conversationID := roomDM(t, handler, ownerToken, memberID)
	owner := joinRoom(t, handler, ownerToken, conversationID)
	member := joinRoom(t, handler, memberToken, conversationID)
	path := "/api/v1/rooms/" + owner.CallID + "/offer"
	offer := func(nonce string) int {
		code, _ := doJSON(t, handler, http.MethodPost, path, memberToken, map[string]any{
			"nonce": nonce, "key_package": bytes.Repeat([]byte{7}, 80), "signature": bytes.Repeat([]byte{8}, 64),
			"expires_at": time.Now().Add(30 * time.Second).Unix(),
		})
		return code
	}
	if code := offer("n_wrong"); code != http.StatusBadRequest {
		t.Fatalf("wrong nonce status=%d", code)
	}
	if code := offer(member.Nonce); code != http.StatusNoContent {
		t.Fatalf("offer status=%d", code)
	}
	if code := offer(member.Nonce); code != http.StatusBadRequest {
		t.Fatalf("nonce reuse status=%d", code)
	}
	status, response := doJSON(t, handler, http.MethodGet, "/api/v1/rooms/"+owner.CallID, ownerToken, nil)
	if status != http.StatusOK || !bytes.Contains(response, []byte("offer_key_package")) || !bytes.Contains(response, []byte("group_id")) {
		t.Fatalf("state status=%d body=%s", status, response)
	}
	// The creator is in the group from the start; the joiner waits until a commit adds it.
	status, _ = doJSON(t, handler, http.MethodPost, "/api/v1/rooms/"+owner.CallID+"/commit", ownerToken, map[string]any{
		"expected_epoch": 0, "commit": []byte{1}, "welcome": []byte{2}, "added_device_ids": []string{"any"},
	})
	if status != http.StatusOK {
		t.Fatalf("commit status=%d", status)
	}
}

// A session without a device holds no MLS device, so it cannot take a seat.
func TestRoomJoinNeedsADeviceSession(t *testing.T) {
	application, handler, ownerToken, _ := newTestAppWithOwnerConfig(t, withSFU)
	ownerID := accountIDFromExport(t, handler, ownerToken)
	_, memberID := registerMemberWithID(t, handler, ownerToken, "devicelessroom")
	conversationID := roomDM(t, handler, ownerToken, memberID)
	db := openSessionTestDB(t, filepath.Join(application.Config.DataDir, "private-messenger.db"))
	token := "deviceless-session-token-for-rooms"
	now := time.Now().UTC().Format("2006-01-02T15:04:05.000000000Z")
	later := time.Now().UTC().Add(time.Hour).Format("2006-01-02T15:04:05.000000000Z")
	if _, err := db.Exec(`INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at) VALUES(?, ?, NULL, ?, ?, ?, ?, ?)`,
		auth.HashToken(token), ownerID, later, now, now, now, later); err != nil {
		t.Fatal(err)
	}
	status, body := doJSON(t, handler, http.MethodPost, "/api/v1/rooms/join", token, map[string]string{"conversation_id": conversationID})
	if status != http.StatusForbidden || !jsonErrorIs(body, "device_required") {
		t.Fatalf("deviceless join status=%d body=%s", status, body)
	}
}
