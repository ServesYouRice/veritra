package httpapi_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/domain"
	"private-messenger/server/internal/httpapi"
	"private-messenger/server/internal/mlswire/mlswiretest"
)

// K0 recovery enrollment, package R2: HTTP behaviour.

const recoveryTestOrigin = "https://chat.example.com"

type recoveryFixture struct {
	t       *testing.T
	dir     string
	dbPath  string
	app     *app.App
	handler http.Handler
	db      *sql.DB
	source  int

	ownerAccountID    string
	ownerToken        string
	ownerDeviceID     string
	ownerDeviceSecret string
	ownerRK           ed25519.PrivateKey
}

func recoveryTestTime(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000000000Z")
}

func openRecoveryApp(t *testing.T, dir, origin string) *app.App {
	t.Helper()
	application, err := app.New(context.Background(), config.Config{
		Addr:         ":0",
		DataDir:      dir,
		DatabasePath: filepath.Join(dir, "private-messenger.db"),
		StoragePath:  filepath.Join(dir, "blobs"),
		InstanceName: "Test Messenger",
		SetupToken:   "test-setup-token",
		PublicOrigin: origin,
	}, nil)
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	return application
}

// newRecoveryFixture sets up an owner on an app whose public origin is
// origin ("" leaves recovery off).
func newRecoveryFixture(t *testing.T, origin string) *recoveryFixture {
	t.Helper()
	dir := t.TempDir()
	f := &recoveryFixture{t: t, dir: dir, dbPath: filepath.Join(dir, "private-messenger.db")}
	f.app = openRecoveryApp(t, dir, origin)
	t.Cleanup(func() { _ = f.app.Close() })
	f.handler = f.app.Handler()
	enrollment := reserveEnrollment(t, f.handler, "/api/v1/setup/owner/enrollment", "")
	body := map[string]interface{}{
		"instance_name":      "Test Messenger",
		"username":           "owner",
		"password":           "owner-password-123",
		"device_name":        "owner phone",
		"device_key_package": mlswiretest.KeyPackage(),
	}
	addEnrollmentProof(body, enrollment)
	status, response := doJSON(t, f.handler, http.MethodPost, "/api/v1/setup/owner", "", body)
	if status != http.StatusCreated {
		t.Fatalf("setup owner status=%d body=%s", status, response)
	}
	var decoded struct {
		Token        string `json:"token"`
		DeviceSecret string `json:"device_secret"`
		Account      struct {
			ID string `json:"id"`
		} `json:"account"`
		Device struct {
			ID string `json:"id"`
		} `json:"device"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatal(err)
	}
	f.ownerAccountID, f.ownerToken, f.ownerDeviceID, f.ownerDeviceSecret = decoded.Account.ID, decoded.Token, decoded.Device.ID, decoded.DeviceSecret
	f.db = openSessionTestDB(t, f.dbPath)
	return f
}

// do sends a request from a new client address each time, so the
// per-address rate limiter and source backoff stay out of the way.
func (f *recoveryFixture) do(method, path, token string, body interface{}, headers map[string]string) (int, []byte) {
	f.t.Helper()
	var raw []byte
	if body != nil {
		var err error
		if raw, err = json.Marshal(body); err != nil {
			f.t.Fatal(err)
		}
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	f.source++
	req.RemoteAddr = fmt.Sprintf("203.0.%d.%d:5000", f.source/250, f.source%250+1)
	rec := httptest.NewRecorder()
	f.handler.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

func (f *recoveryFixture) exec(query string, args ...interface{}) {
	f.t.Helper()
	if _, err := f.db.Exec(query, args...); err != nil {
		f.t.Fatalf("exec %q: %v", query, err)
	}
}

func (f *recoveryFixture) count(query string, args ...interface{}) int {
	f.t.Helper()
	var n int
	if err := f.db.QueryRow(query, args...).Scan(&n); err != nil {
		f.t.Fatalf("count %q: %v", query, err)
	}
	return n
}

// setRK gives the account of token a new recovery key and returns it.
func (f *recoveryFixture) setRK(token string) ed25519.PrivateKey {
	f.t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		f.t.Fatal(err)
	}
	rkID := make([]byte, 16)
	_, _ = rand.Read(rkID)
	status, body := f.do(http.MethodPut, "/api/v1/account/recovery-key", token, map[string]interface{}{"rk_auth_pub": []byte(public), "rk_id": rkID}, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"configured":true`)) {
		f.t.Fatalf("set recovery key status=%d body=%s", status, body)
	}
	return private
}

// makeOwnerIdle puts the owner's device outside the activity window.
func (f *recoveryFixture) makeOwnerIdle() {
	old := recoveryTestTime(time.Now().Add(-8 * 24 * time.Hour))
	f.exec(`UPDATE devices SET last_seen_at = ?, created_at = ? WHERE id = ?`, old, old, f.ownerDeviceID)
}

type recoveryReservation struct {
	ID        string `json:"id"`
	AccountID string `json:"account_id"`
	DeviceID  string `json:"device_id"`
	Challenge []byte `json:"challenge"`
}

func (f *recoveryFixture) reserve(username string) recoveryReservation {
	f.t.Helper()
	status, body := f.do(http.MethodPost, "/api/v1/account-recovery/enrollment", "", map[string]string{"username": username}, nil)
	if status != http.StatusCreated {
		f.t.Fatalf("reserve recovery status=%d body=%s", status, body)
	}
	var reservation recoveryReservation
	if err := json.Unmarshal(body, &reservation); err != nil {
		f.t.Fatal(err)
	}
	return reservation
}

// recoveryProofForTest is the proof layout, written out separately from the
// server's so a change on either side shows.
func recoveryProofForTest(challenge, signingKey, keyPackage []byte, origin string) []byte {
	lp := func(value []byte) []byte {
		var size [2]byte
		binary.BigEndian.PutUint16(size[:], uint16(len(value)))
		return append(size[:], value...)
	}
	keyPackageHash := sha256.Sum256(keyPackage)
	message := []byte("veritra-k0-recovery-proof-v1")
	message = append(message, lp(challenge)...)
	message = append(message, signingKey...)
	message = append(message, keyPackageHash[:]...)
	return append(message, lp([]byte(origin))...)
}

// claimBody builds a claim for reservation: a fresh device key, its
// enrollment proof, and a recovery proof by rk over origin.
func claimBody(t *testing.T, reservation recoveryReservation, password string, rk ed25519.PrivateKey, origin string) map[string]interface{} {
	t.Helper()
	devicePublic, devicePrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	keyPackage := mlswiretest.KeyPackage()
	return map[string]interface{}{
		"enrollment_reservation_id": reservation.ID,
		"password":                  password,
		"device_name":               "new phone",
		"device_key_package":        keyPackage,
		"signing_key":               []byte(devicePublic),
		"challenge_signature":       ed25519.Sign(devicePrivate, enrollmentProofMessageForTest(reservation.Challenge, devicePublic, keyPackage)),
		"recovery_signature":        ed25519.Sign(rk, recoveryProofForTest(reservation.Challenge, devicePublic, keyPackage, origin)),
	}
}

type recoveryClaimResponse struct {
	RequestID    string    `json:"request_id"`
	ClaimToken   string    `json:"claim_token"`
	DeviceSecret string    `json:"device_secret"`
	State        string    `json:"state"`
	ReadyAt      time.Time `json:"ready_at"`
}

func (f *recoveryFixture) claimOK(body map[string]interface{}) recoveryClaimResponse {
	f.t.Helper()
	status, response := f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", body, nil)
	if status != http.StatusAccepted {
		f.t.Fatalf("claim status=%d body=%s", status, response)
	}
	var claimed recoveryClaimResponse
	if err := json.Unmarshal(response, &claimed); err != nil || claimed.ClaimToken == "" || claimed.DeviceSecret == "" {
		f.t.Fatalf("claim response %s: %v", response, err)
	}
	return claimed
}

func (f *recoveryFixture) status(requestID, claimToken string) (int, []byte) {
	f.t.Helper()
	return f.do(http.MethodGet, "/api/v1/account-recovery/"+requestID+"/status", "", nil, map[string]string{"X-Veritra-Claim-Token": claimToken})
}

func (f *recoveryFixture) registerMember(username string) (token, accountID string) {
	f.t.Helper()
	return registerMemberWithID(f.t, f.handler, f.ownerToken, username)
}

func TestAccountRecoveryRoutesAnswer503WhileOriginUnset(t *testing.T) {
	f := newRecoveryFixture(t, "")
	claimToken := strings.Repeat("A", 43)
	for _, route := range []struct {
		method, path, token string
		body                interface{}
	}{
		{http.MethodPost, "/api/v1/account-recovery/enrollment", "", map[string]string{"username": "owner"}},
		{http.MethodPost, "/api/v1/account-recovery/enrollment", "", map[string]string{"username": "nobody"}},
		{http.MethodPost, "/api/v1/account-recovery/claim", "", map[string]string{}},
		{http.MethodGet, "/api/v1/account-recovery/rcv_1/status", "", nil},
		{http.MethodPost, "/api/v1/account-recovery/rcv_1/cancel", "", nil},
		{http.MethodPost, "/api/v1/account-recovery/rcv_1/cancel", f.ownerToken, nil},
		{http.MethodGet, "/api/v1/account-recovery/other", "", nil},
		{http.MethodPut, "/api/v1/account/recovery-key", f.ownerToken, map[string]interface{}{"rk_auth_pub": make([]byte, 32), "rk_id": make([]byte, 16)}},
	} {
		status, body := f.do(route.method, route.path, route.token, route.body, map[string]string{"X-Veritra-Claim-Token": claimToken})
		if status != http.StatusServiceUnavailable || !jsonErrorIs(body, "recovery_not_configured") {
			t.Errorf("%s %s: status=%d body=%s", route.method, route.path, status, body)
		}
	}
	status, body := f.do(http.MethodGet, "/api/v1/account/recovery-key", f.ownerToken, nil, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"available":false`)) || !bytes.Contains(body, []byte(`"configured":false`)) {
		t.Fatalf("recovery key status=%d body=%s", status, body)
	}
}

// With no active device the request is ready at once: the first status
// call completes it (revoking the old device, no recent auth), a repeated
// call answers completed without a token, and login works with the claim's
// device secret.
func TestAccountRecoveryCompletesAtOnceWithoutAnActiveDevice(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	status, body := f.do(http.MethodGet, "/api/v1/account/recovery-key", f.ownerToken, nil, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"available":true`)) || !bytes.Contains(body, []byte(`"rk_id"`)) {
		t.Fatalf("recovery key status=%d body=%s", status, body)
	}
	f.makeOwnerIdle()
	reservation := f.reserve("owner")
	if reservation.AccountID != f.ownerAccountID {
		t.Fatalf("reservation account %q, want %q", reservation.AccountID, f.ownerAccountID)
	}
	claimed := f.claimOK(claimBody(t, reservation, "owner-password-123", f.ownerRK, recoveryTestOrigin))
	if claimed.State != "waiting" || claimed.ReadyAt.After(time.Now().Add(time.Minute)) {
		t.Fatalf("claim = %+v, want ready now", claimed)
	}
	// An unknown id and a wrong token answer alike.
	wrongToken := strings.Repeat("A", 43)
	s1, b1 := f.status(claimed.RequestID, wrongToken)
	s2, b2 := f.status("rcv_00000000000000000000000000000000", claimed.ClaimToken)
	if s1 != http.StatusNotFound || s1 != s2 || !bytes.Equal(b1, b2) {
		t.Fatalf("wrong token %d %s vs unknown id %d %s", s1, b1, s2, b2)
	}
	status, body = f.status(claimed.RequestID, claimed.ClaimToken)
	if status != http.StatusOK {
		t.Fatalf("status=%d body=%s", status, body)
	}
	var completed struct {
		State   string         `json:"state"`
		Token   string         `json:"token"`
		Account domain.Account `json:"account"`
		Device  domain.Device  `json:"device"`
	}
	if err := json.Unmarshal(body, &completed); err != nil || completed.State != "completed" || completed.Token == "" || completed.Account.ID != f.ownerAccountID || completed.Device.ID != reservation.DeviceID {
		t.Fatalf("completion %s: %v", body, err)
	}
	if status, _ := f.do(http.MethodGet, "/api/v1/devices/me", completed.Token, nil, nil); status != http.StatusOK {
		t.Fatalf("recovered session refused: %d", status)
	}
	// Completion never grants recent authentication.
	if status, body := f.do(http.MethodPost, "/api/v1/invites", completed.Token, map[string]int{"max_uses": 1}, nil); status != http.StatusForbidden || !jsonErrorIs(body, "recent_auth_required") {
		t.Fatalf("recent-auth route after recovery: %d %s", status, body)
	}
	if n := f.count(`SELECT COUNT(*) FROM sessions WHERE device_id = ? AND recent_auth_at IS NULL`, reservation.DeviceID); n != 1 {
		t.Fatalf("recovered sessions without recent auth = %d", n)
	}
	if status, _ := f.do(http.MethodGet, "/api/v1/devices/me", f.ownerToken, nil, nil); status != http.StatusUnauthorized {
		t.Fatalf("old device session still works: %d", status)
	}
	if n := f.count(`SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NOT NULL`, f.ownerDeviceID); n != 1 {
		t.Fatal("old device not revoked")
	}
	for _, eventType := range []string{"device.revoked", "account.recovered", "account.recovery.pending"} {
		if n := f.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = ? AND account_id = ?`, eventType, f.ownerAccountID); n != 1 {
			t.Fatalf("%s events = %d", eventType, n)
		}
	}
	// A lost 200: completed again, without a token, then a normal login.
	status, body = f.status(claimed.RequestID, claimed.ClaimToken)
	if status != http.StatusOK || bytes.Contains(body, []byte(`"token"`)) || !bytes.Contains(body, []byte(`"completed"`)) {
		t.Fatalf("repeat status=%d body=%s", status, body)
	}
	status, body = f.do(http.MethodPost, "/api/v1/auth/login", "", map[string]string{
		"username": "owner", "password": "owner-password-123", "device_id": reservation.DeviceID, "device_secret": claimed.DeviceSecret,
	}, nil)
	if status != http.StatusOK {
		t.Fatalf("login after lost 200: %d %s", status, body)
	}
	for _, event := range []string{"account.recovery_requested", "account.recovered", "account.recovery_key_set"} {
		if n := f.count(`SELECT COUNT(*) FROM audit_events WHERE event_type = ?`, event); n != 1 {
			t.Fatalf("audit %s = %d", event, n)
		}
	}
	// Nothing secret reaches the audit log or the sync payloads.
	for _, secret := range []string{claimed.ClaimToken, claimed.DeviceSecret, completed.Token, "owner-password-123"} {
		if n := f.count(`SELECT (SELECT COUNT(*) FROM audit_events WHERE instr(metadata_json, ?) > 0) + (SELECT COUNT(*) FROM sync_events WHERE instr(payload_json, ?) > 0)`, secret, secret); n != 0 {
			t.Fatal("a secret was stored in an audit or sync row")
		}
	}
}

func TestAccountRecoveryWaitsForActiveDevicesAndCancelNeedsRecentAuth(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	reservation := f.reserve("owner")
	claimed := f.claimOK(claimBody(t, reservation, "owner-password-123", f.ownerRK, recoveryTestOrigin))
	if wait := time.Until(claimed.ReadyAt); wait < 7*24*time.Hour-time.Hour {
		t.Fatalf("ready_at %s: an active device must start the 7-day wait", claimed.ReadyAt)
	}
	// The reservation was consumed at claim.
	if status, body := f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", claimBody(t, reservation, "owner-password-123", f.ownerRK, recoveryTestOrigin), nil); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_enrollment") {
		t.Fatalf("reused reservation: %d %s", status, body)
	}
	status, body := f.status(claimed.RequestID, claimed.ClaimToken)
	if status != http.StatusAccepted || !bytes.Contains(body, []byte(`"waiting"`)) {
		t.Fatalf("waiting status=%d body=%s", status, body)
	}
	status, body = f.do(http.MethodGet, "/api/v1/account/recovery-key", f.ownerToken, nil, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(claimed.RequestID)) || !bytes.Contains(body, []byte(`"pending_request"`)) {
		t.Fatalf("recovery key status=%d body=%s", status, body)
	}
	// A thief with the unlocked phone (a session without recent auth)
	// cannot cancel.
	f.exec(`UPDATE sessions SET recent_auth_at = ? WHERE device_id = ?`, recoveryTestTime(time.Now().Add(-time.Hour)), f.ownerDeviceID)
	cancelPath := "/api/v1/account-recovery/" + claimed.RequestID + "/cancel"
	if status, body := f.do(http.MethodPost, cancelPath, f.ownerToken, nil, nil); status != http.StatusForbidden || !jsonErrorIs(body, "recent_auth_required") {
		t.Fatalf("cancel without recent auth: %d %s", status, body)
	}
	if status, body := f.do(http.MethodPost, "/api/v1/auth/reauth", f.ownerToken, map[string]string{"password": "owner-password-123", "device_secret": f.ownerDeviceSecret}, nil); status != http.StatusNoContent {
		t.Fatalf("reauth: %d %s", status, body)
	}
	if status, body := f.do(http.MethodPost, cancelPath, f.ownerToken, nil, nil); status != http.StatusOK {
		t.Fatalf("cancel: %d %s", status, body)
	}
	if status, body := f.status(claimed.RequestID, claimed.ClaimToken); status != http.StatusGone || !jsonErrorIs(body, "recovery_cancelled") {
		t.Fatalf("status after cancel: %d %s", status, body)
	}
	// A password change cancels a waiting request too.
	second := f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
	if status, body := f.do(http.MethodPost, "/api/v1/account/password", f.ownerToken, map[string]string{"new_password": "owner-password-456"}, nil); status != http.StatusNoContent {
		t.Fatalf("change password: %d %s", status, body)
	}
	f.exec(`UPDATE account_recovery_requests SET ready_at = ? WHERE id = ?`, recoveryTestTime(time.Now().Add(-time.Minute)), second.RequestID)
	if status, body := f.status(second.RequestID, second.ClaimToken); status != http.StatusGone {
		t.Fatalf("status after password change: %d %s", status, body)
	}
	// And so does a new recovery key.
	third := f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-456", f.ownerRK, recoveryTestOrigin))
	f.setRK(f.ownerToken)
	if status, body := f.status(third.RequestID, third.ClaimToken); status != http.StatusGone {
		t.Fatalf("status after RK change: %d %s", status, body)
	}
}

// A claim checks the credentials of the reservation's account only: A's
// reservation with B's password and recovery key fails and counts against A.
func TestAccountRecoveryClaimUsesOnlyTheReservationsAccount(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	bobToken, bobID := f.registerMember("bob")
	bobRK := f.setRK(bobToken)
	reservation := f.reserve("owner")
	status, body := f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", claimBody(t, reservation, "member-password-123", bobRK, recoveryTestOrigin), nil)
	if status != http.StatusUnauthorized || !jsonErrorIs(body, "invalid_credentials") {
		t.Fatalf("cross-account claim: %d %s", status, body)
	}
	if n := f.count(`SELECT COUNT(*) FROM recovery_attempts WHERE account_id = ?`, f.ownerAccountID); n != 1 {
		t.Fatalf("owner attempt rows = %d", n)
	}
	if n := f.count(`SELECT COUNT(*) FROM recovery_attempts WHERE account_id = ?`, bobID); n != 0 {
		t.Fatalf("bob attempt rows = %d", n)
	}
	// There is no username field to steer the claim.
	withUsername := claimBody(t, f.reserve("owner"), "member-password-123", bobRK, recoveryTestOrigin)
	withUsername["username"] = "bob"
	if status, body := f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", withUsername, nil); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_json") {
		t.Fatalf("claim with username: %d %s", status, body)
	}
	if n := f.count(`SELECT COUNT(*) FROM account_recovery_requests`); n != 0 {
		t.Fatalf("requests = %d", n)
	}
}

// The proof names the configured origin. A proof made for a look-alike
// origin that relays to this server fails, whatever Host or forwarding
// headers the relay sends.
func TestAccountRecoveryProofIsBoundToTheConfiguredOrigin(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	relayed := map[string]string{"Host": "chat.example.co", "X-Forwarded-Host": "chat.example.co", "X-Forwarded-Proto": "https", "Origin": "https://chat.example.co"}
	for _, origin := range []string{"https://chat.example.co", "https://chat.example.com:8443", "http://chat.example.com", ""} {
		status, body := f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, origin), relayed)
		if status != http.StatusUnauthorized || !jsonErrorIs(body, "invalid_credentials") {
			t.Fatalf("proof for %q: %d %s", origin, status, body)
		}
	}
	f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
}

// Every failing claim does the same work (password hash, recovery
// signature, counter write) and gets the same answer, whatever the reason.
func TestAccountRecoveryFailuresDoEqualWorkAndAnswerAlike(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	noKeyToken, _ := f.registerMember("nokey")
	_ = noKeyToken
	suspendedToken, suspendedID := f.registerMember("suspended")
	f.setRK(suspendedToken)
	deletedToken, deletedID := f.registerMember("deleted")
	f.setRK(deletedToken)
	f.exec(`UPDATE accounts SET status = 'suspended' WHERE id = ?`, suspendedID)
	f.exec(`UPDATE accounts SET status = 'deleted', deleted_at = ? WHERE id = ?`, recoveryTestTime(time.Now()), deletedID)
	wrongRK := func() ed25519.PrivateKey {
		_, private, _ := ed25519.GenerateKey(rand.Reader)
		return private
	}()

	var mu sync.Mutex
	var steps []string
	restore := httpapi.SetRecoveryClaimWorkHookForTest(func(step string) {
		mu.Lock()
		steps = append(steps, step)
		mu.Unlock()
	})
	defer restore()
	var firstBody []byte
	for _, tc := range []struct {
		name, username, password string
		rk                       ed25519.PrivateKey
	}{
		{"unknown account", "ghost", "owner-password-123", f.ownerRK},
		{"suspended account", "suspended", "member-password-123", wrongRK},
		{"deleted account", "deleted", "member-password-123", wrongRK},
		{"no recovery key", "nokey", "member-password-123", wrongRK},
		{"wrong password", "owner", "wrong-password-123", f.ownerRK},
		{"wrong recovery key", "owner", "owner-password-123", wrongRK},
	} {
		reservation := f.reserve(tc.username)
		if !domain.ValidID("acct", reservation.AccountID) {
			t.Fatalf("%s: reservation account id %q", tc.name, reservation.AccountID)
		}
		if tc.username == "suspended" && reservation.AccountID == suspendedID || tc.username == "deleted" && reservation.AccountID == deletedID {
			t.Fatalf("%s: reservation revealed the real account id", tc.name)
		}
		mu.Lock()
		steps = nil
		mu.Unlock()
		status, body := f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", claimBody(t, reservation, tc.password, tc.rk, recoveryTestOrigin), nil)
		if status != http.StatusUnauthorized {
			t.Fatalf("%s: status=%d body=%s", tc.name, status, body)
		}
		if firstBody == nil {
			firstBody = body
		} else if !bytes.Equal(body, firstBody) {
			t.Fatalf("%s: body %s differs from %s", tc.name, body, firstBody)
		}
		mu.Lock()
		got := append([]string(nil), steps...)
		mu.Unlock()
		if want := []string{"password", "recovery_signature", "attempt"}; !reflect.DeepEqual(got, want) {
			t.Fatalf("%s: work = %v, want %v", tc.name, got, want)
		}
	}
	// Decoys are stable, and a decoy id gets its counter row like any other.
	first, second := f.reserve("ghost"), f.reserve("GHOST")
	if first.AccountID != second.AccountID {
		t.Fatalf("decoy changed: %q / %q", first.AccountID, second.AccountID)
	}
	if n := f.count(`SELECT COUNT(*) FROM recovery_attempts WHERE account_id = ?`, first.AccountID); n != 1 {
		t.Fatalf("decoy attempt rows = %d", n)
	}
}

// D79: only right-password-wrong-key claims count; over 50 a day even a
// correct claim gets the same 401; the account is warned once a day; the
// count survives a restart.
func TestAccountRecoveryFailureCap(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	_, wrongRK, _ := ed25519.GenerateKey(rand.Reader)
	claim := func(password string, rk ed25519.PrivateKey) (int, []byte) {
		return f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", claimBody(t, f.reserve("owner"), password, rk, recoveryTestOrigin), nil)
	}
	failures := func() int {
		return f.count(`SELECT COALESCE(SUM(failures), 0) FROM recovery_attempts WHERE account_id = ?`, f.ownerAccountID)
	}
	if status, _ := claim("wrong-password-123", f.ownerRK); status != http.StatusUnauthorized || failures() != 0 {
		t.Fatalf("wrong password, right key: status %d, failures %d", status, failures())
	}
	if status, _ := claim("wrong-password-123", wrongRK); status != http.StatusUnauthorized || failures() != 0 {
		t.Fatalf("both wrong: status %d, failures %d", status, failures())
	}
	if status, _ := claim("owner-password-123", wrongRK); status != http.StatusUnauthorized || failures() != 1 {
		t.Fatalf("right password, wrong key: status %d, failures %d", status, failures())
	}
	f.exec(`UPDATE recovery_attempts SET failures = 50 WHERE account_id = ?`, f.ownerAccountID)
	leaks := func() int {
		return f.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'account.password_leak_suspected' AND account_id = ?`, f.ownerAccountID)
	}
	status, wrongBody := claim("owner-password-123", wrongRK)
	if status != http.StatusUnauthorized || leaks() != 1 {
		t.Fatalf("51st failure: status %d, leak notices %d", status, leaks())
	}
	status, cappedBody := claim("owner-password-123", f.ownerRK)
	if status != http.StatusUnauthorized || !bytes.Equal(cappedBody, wrongBody) {
		t.Fatalf("correct claim over the cap: %d %s", status, cappedBody)
	}
	if status, _ := claim("owner-password-123", wrongRK); status != http.StatusUnauthorized || leaks() != 1 {
		t.Fatalf("second trip the same day: leak notices %d", leaks())
	}
	if n := f.count(`SELECT COUNT(*) FROM account_recovery_requests`); n != 0 {
		t.Fatalf("requests = %d", n)
	}
	// Restart on the same database.
	if err := f.app.Close(); err != nil {
		t.Fatal(err)
	}
	f.app = openRecoveryApp(t, f.dir, recoveryTestOrigin)
	t.Cleanup(func() { _ = f.app.Close() })
	f.handler = f.app.Handler()
	if status, body := claim("owner-password-123", f.ownerRK); status != http.StatusUnauthorized {
		t.Fatalf("correct claim over the cap after restart: %d %s", status, body)
	}
	// The next day the cap is fresh.
	f.exec(`UPDATE recovery_attempts SET day = '2000-01-01'`)
	f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
}

// The account backoff is drained only by callers whose recovery proof
// verified; failures without the key count only against their source.
func TestAccountRecoveryAccountBackoffCountsOnlyProofHolders(t *testing.T) {
	frozen := time.Now()
	restore := httpapi.SetLoginBackoffClockForTest(func() time.Time { return frozen })
	defer restore()
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	_, wrongRK, _ := ed25519.GenerateKey(rand.Reader)
	claim := func(password string, rk ed25519.PrivateKey) (int, []byte) {
		return f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", claimBody(t, f.reserve("owner"), password, rk, recoveryTestOrigin), nil)
	}
	for i := 0; i < 5; i++ {
		if status, body := claim("wrong-password-123", wrongRK); status != http.StatusUnauthorized {
			t.Fatalf("keyless failure %d: %d %s", i, status, body)
		}
	}
	// Without the key nobody locked the owner out.
	if status, _ := claim("owner-password-123", f.ownerRK); status != http.StatusAccepted {
		t.Fatalf("owner claim after keyless failures: %d", status)
	}
	var last int
	for i := 0; i < 3; i++ {
		last, _ = claim("wrong-password-123", f.ownerRK)
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("third key-holder failure from new sources: %d, want 429", last)
	}
	if status, body := claim("owner-password-123", f.ownerRK); status != http.StatusTooManyRequests || !jsonErrorIs(body, "recovery_backoff") {
		t.Fatalf("account backoff: %d %s", status, body)
	}
}

// A login that rehashes a legacy password during the wait must not turn
// into a false 410 at completion.
func TestAccountRecoveryCompletesAfterALoginRehash(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	legacy, err := bcrypt.GenerateFromPassword([]byte("owner-password-123"), bcrypt.MinCost+6)
	if err != nil {
		t.Fatal(err)
	}
	f.exec(`UPDATE accounts SET password_hash = ? WHERE id = ?`, string(legacy), f.ownerAccountID)
	claimed := f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
	// The claim does not rehash.
	if n := f.count(`SELECT COUNT(*) FROM accounts WHERE id = ? AND password_hash = ?`, f.ownerAccountID, string(legacy)); n != 1 {
		t.Fatal("the claim rehashed the password")
	}
	status, body := f.do(http.MethodPost, "/api/v1/auth/login", "", map[string]string{
		"username": "owner", "password": "owner-password-123", "device_id": f.ownerDeviceID, "device_secret": f.ownerDeviceSecret,
	}, nil)
	if status != http.StatusOK {
		t.Fatalf("login: %d %s", status, body)
	}
	if n := f.count(`SELECT COUNT(*) FROM accounts WHERE id = ? AND password_hash = ?`, f.ownerAccountID, string(legacy)); n != 0 {
		t.Fatal("the login did not rehash the legacy password")
	}
	f.exec(`UPDATE account_recovery_requests SET ready_at = ? WHERE id = ?`, recoveryTestTime(time.Now().Add(-time.Minute)), claimed.RequestID)
	if status, body := f.status(claimed.RequestID, claimed.ClaimToken); status != http.StatusOK || !bytes.Contains(body, []byte(`"token"`)) {
		t.Fatalf("completion after rehash: %d %s", status, body)
	}
}

func TestClassifyAccountRecoveryRoutes(t *testing.T) {
	for target, want := range map[string]httpapi.RouteClass{
		"/api/v1/account-recovery/enrollment":         httpapi.EnrollmentRoute,
		"/api/v1/account-recovery/claim":              httpapi.CredentialRoute,
		"/api/v1/account-recovery/claim/":             httpapi.CredentialRoute,
		"/api/v1/account-recovery/rcv_1/status":       httpapi.CredentialRoute,
		"/api/v1/account-recovery/rcv_1%2Fstatus":     httpapi.CredentialRoute,
		"/api/v1/account-recovery/rcv_1/status/":      httpapi.CredentialRoute,
		"/api/v1/account-recovery/rcv_1/cancel":       httpapi.CredentialRoute,
		"/api/v1/account-recovery//claim":             httpapi.CredentialRoute,
		"/api/v1/account-recovery/x/enrollment":       httpapi.CredentialRoute,
		"/api/v1/account-recovery/enrollment/":        httpapi.CredentialRoute,
		"/api/v1/account-recovery":                    httpapi.CredentialRoute,
		"/api/v1/account-recovery-other":              httpapi.OrdinaryRoute,
		"/api/v1/account/recovery-key":                httpapi.OrdinaryRoute,
		"/api/v1/recovery":                            httpapi.CredentialRoute,
		"/api/v1/account-recovery/%2E%2E/auth/logout": httpapi.CredentialRoute,
	} {
		path := httptest.NewRequest("GET", target, nil).URL.Path
		if got := httpapi.ClassifyRoute(path); got != want {
			t.Errorf("ClassifyRoute(%q) = %d, want %d", target, got, want)
		}
	}
}
