package httpapi_test

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-webauthn/webauthn/protocol/webauthncbor"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/httpapi"
	"private-messenger/server/internal/mlswire/mlswiretest"
	"private-messenger/server/internal/storage/storagetest"
)

const (
	pkOrigin  = "https://chat.example.com"
	pkRPID    = "chat.example.com"
	pkAndroid = "com.veritra.app:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
)

// testAuthenticator is a software authenticator: ES256 or Ed25519 keys,
// attestation "none".
type testAuthenticator struct {
	ed       bool
	ec       *ecdsa.PrivateKey
	edKey    ed25519.PrivateKey
	credID   []byte
	counter  uint32
	be, bs   bool
	origin   string
	noUV     bool
	rpID     string
	userHdl  []byte
	skipUser bool
}

func newTestAuthenticator(t *testing.T, ed bool) *testAuthenticator {
	t.Helper()
	a := &testAuthenticator{ed: ed, origin: pkOrigin, rpID: pkRPID, credID: make([]byte, 32)}
	_, _ = rand.Read(a.credID)
	if ed {
		_, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		a.edKey = priv
	} else {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		a.ec = key
	}
	return a
}

func (a *testAuthenticator) cose(t *testing.T) []byte {
	t.Helper()
	var key map[int]interface{}
	if a.ed {
		key = map[int]interface{}{1: 1, 3: -8, -1: 6, -2: []byte(a.edKey.Public().(ed25519.PublicKey))}
	} else {
		x, y := make([]byte, 32), make([]byte, 32)
		a.ec.X.FillBytes(x)
		a.ec.Y.FillBytes(y)
		key = map[int]interface{}{1: 2, 3: -7, -1: 1, -2: x, -3: y}
	}
	raw, err := webauthncbor.Marshal(key)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func (a *testAuthenticator) flags(extra byte) byte {
	flags := byte(0x01) | extra
	if !a.noUV {
		flags |= 0x04
	}
	if a.be {
		flags |= 0x08
	}
	if a.bs {
		flags |= 0x10
	}
	return flags
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func (a *testAuthenticator) clientData(kind, challenge string) []byte {
	raw, _ := json.Marshal(map[string]interface{}{"type": kind, "challenge": challenge, "origin": a.origin, "crossOrigin": false})
	return raw
}

// register answers creation options (the public_key object).
func (a *testAuthenticator) register(t *testing.T, options map[string]interface{}) json.RawMessage {
	t.Helper()
	challenge, _ := options["challenge"].(string)
	user, _ := options["user"].(map[string]interface{})
	handle, err := base64.RawURLEncoding.DecodeString(fmt.Sprint(user["id"]))
	if err != nil || len(handle) != 32 {
		t.Fatalf("user handle %v: %v", user["id"], err)
	}
	a.userHdl = handle
	rpHash := sha256.Sum256([]byte(a.rpID))
	authData := append(rpHash[:], a.flags(0x40))
	authData = binary.BigEndian.AppendUint32(authData, a.counter)
	authData = append(authData, make([]byte, 16)...)
	authData = binary.BigEndian.AppendUint16(authData, uint16(len(a.credID)))
	authData = append(authData, a.credID...)
	authData = append(authData, a.cose(t)...)
	attestation, err := webauthncbor.Marshal(map[string]interface{}{"fmt": "none", "attStmt": map[string]interface{}{}, "authData": authData})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(map[string]interface{}{
		"id": b64(a.credID), "rawId": b64(a.credID), "type": "public-key",
		"response": map[string]interface{}{
			"clientDataJSON": b64(a.clientData("webauthn.create", challenge)), "attestationObject": b64(attestation),
			"transports": []string{"internal"},
		},
	})
	return raw
}

// assert answers request options (the public_key object).
func (a *testAuthenticator) assert(t *testing.T, options map[string]interface{}) json.RawMessage {
	t.Helper()
	challenge, _ := options["challenge"].(string)
	rpHash := sha256.Sum256([]byte(a.rpID))
	authData := append(rpHash[:], a.flags(0))
	authData = binary.BigEndian.AppendUint32(authData, a.counter)
	client := a.clientData("webauthn.get", challenge)
	hash := sha256.Sum256(client)
	signed := append(append([]byte{}, authData...), hash[:]...)
	var sig []byte
	if a.ed {
		sig = ed25519.Sign(a.edKey, signed)
	} else {
		digest := sha256.Sum256(signed)
		var err error
		if sig, err = ecdsa.SignASN1(rand.Reader, a.ec, digest[:]); err != nil {
			t.Fatal(err)
		}
	}
	response := map[string]interface{}{"clientDataJSON": b64(client), "authenticatorData": b64(authData), "signature": b64(sig)}
	if !a.skipUser {
		response["userHandle"] = b64(a.userHdl)
	}
	raw, _ := json.Marshal(map[string]interface{}{"id": b64(a.credID), "rawId": b64(a.credID), "type": "public-key", "response": response})
	return raw
}

type pkEnv struct {
	t            *testing.T
	app          *app.App
	handler      http.Handler
	db           *sql.DB
	token        string
	accountID    string
	deviceID     string
	deviceSecret string
	password     string
	source       int
	mu           sync.Mutex
}

func newPasskeyEnv(t *testing.T, passkeys bool) *pkEnv {
	t.Helper()
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "private-messenger.db")
	cfg := config.Config{Addr: ":0", DataDir: dir, DatabasePath: dbPath, StoragePath: filepath.Join(dir, "blobs"), InstanceName: "Test Messenger", SetupToken: "test-setup-token", PublicOrigin: pkOrigin}
	if passkeys {
		parsed, err := config.ParsePasskeys(pkOrigin, pkAndroid, "ABCDE12345.com.veritra.app")
		if err != nil {
			t.Fatal(err)
		}
		cfg.Passkeys = parsed
	}
	storagetest.SeedMigrated(t, dbPath)
	application, err := app.New(context.Background(), cfg, nil)
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() { _ = application.Close() })
	env := &pkEnv{t: t, password: "owner-password-123", app: application, handler: application.Handler(), db: openSessionTestDB(t, dbPath)}
	enrollment := reserveEnrollment(t, env.handler, "/api/v1/setup/owner/enrollment", "")
	body := map[string]interface{}{"instance_name": "Test Messenger", "username": "owner", "password": "owner-password-123", "device_name": "owner phone", "device_key_package": mlswiretest.KeyPackage()}
	addEnrollmentProof(body, enrollment)
	status, response := env.do(http.MethodPost, "/api/v1/setup/owner", "", body)
	if status != http.StatusCreated {
		t.Fatalf("setup owner status=%d body=%s", status, response)
	}
	env.token, env.accountID, env.deviceID, env.deviceSecret = decodeEnrollmentResult(t, response)
	return env
}

func decodeEnrollmentResult(t *testing.T, response []byte) (token, accountID, deviceID, secret string) {
	t.Helper()
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
	if err := json.Unmarshal(response, &decoded); err != nil || decoded.Token == "" {
		t.Fatalf("decode enrollment result: %v %s", err, response)
	}
	return decoded.Token, decoded.Account.ID, decoded.Device.ID, decoded.DeviceSecret
}

// do sends each request from a new client address, so the per-address rate
// limiter and the source backoff stay out of the way.
func (e *pkEnv) do(method, path, token string, body interface{}) (int, []byte) {
	return e.doFrom("", method, path, token, body)
}

func (e *pkEnv) doFrom(addr, method, path, token string, body interface{}) (int, []byte) {
	e.t.Helper()
	var raw []byte
	if body != nil {
		var err error
		if raw, err = json.Marshal(body); err != nil {
			e.t.Fatal(err)
		}
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if path == "/api/v1/setup/owner" {
		req.Header.Set("X-Veritra-Setup-Token", "test-setup-token")
	}
	if addr == "" {
		e.mu.Lock()
		e.source++
		addr = fmt.Sprintf("203.0.%d.%d", e.source/250, e.source%250+1)
		e.mu.Unlock()
	}
	req.RemoteAddr = addr + ":5000"
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

func (e *pkEnv) exec(query string, args ...interface{}) {
	e.t.Helper()
	if _, err := e.db.Exec(query, args...); err != nil {
		e.t.Fatalf("%s: %v", query, err)
	}
}

func (e *pkEnv) count(query string, args ...interface{}) int {
	e.t.Helper()
	var n int
	if err := e.db.QueryRow(query, args...).Scan(&n); err != nil {
		e.t.Fatalf("%s: %v", query, err)
	}
	return n
}

func (e *pkEnv) reauth() {
	e.t.Helper()
	status, response := e.do(http.MethodPost, "/api/v1/auth/reauth", e.token, map[string]string{"password": e.password, "device_secret": e.deviceSecret})
	if status != http.StatusNoContent {
		e.t.Fatalf("reauth status=%d body=%s", status, response)
	}
}

type ceremonyResponse struct {
	CeremonyID string                 `json:"ceremony_id"`
	PublicKey  map[string]interface{} `json:"public_key"`
}

func (e *pkEnv) registerPasskey(a *testAuthenticator, name string) string {
	e.t.Helper()
	e.reauth()
	status, response := e.do(http.MethodPost, "/api/v1/account/passkeys/options", e.token, map[string]string{})
	if status != http.StatusOK {
		e.t.Fatalf("register options status=%d body=%s", status, response)
	}
	var c ceremonyResponse
	if err := json.Unmarshal(response, &c); err != nil {
		e.t.Fatal(err)
	}
	status, response = e.do(http.MethodPost, "/api/v1/account/passkeys", e.token, map[string]interface{}{"ceremony_id": c.CeremonyID, "name": name, "credential": a.register(e.t, c.PublicKey)})
	if status != http.StatusCreated {
		e.t.Fatalf("register status=%d body=%s", status, response)
	}
	var out struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(response, &out)
	return out.ID
}

func (e *pkEnv) loginOptions(deviceID, secret string) (int, ceremonyResponse, []byte) {
	status, response := e.do(http.MethodPost, "/api/v1/auth/passkey/options", "", map[string]string{"device_id": deviceID, "device_secret": secret})
	var c ceremonyResponse
	if status == http.StatusOK {
		_ = json.Unmarshal(response, &c)
	}
	return status, c, response
}

func (e *pkEnv) finish(c ceremonyResponse, deviceID, secret string, credential json.RawMessage) (int, []byte) {
	return e.do(http.MethodPost, "/api/v1/auth/passkey", "", map[string]interface{}{"ceremony_id": c.CeremonyID, "device_id": deviceID, "device_secret": secret, "credential": credential})
}

// signIn runs both steps for the owner's device and returns the status.
func (e *pkEnv) signIn(a *testAuthenticator) (int, []byte) {
	e.t.Helper()
	status, c, response := e.loginOptions(e.deviceID, e.deviceSecret)
	if status != http.StatusOK {
		return status, response
	}
	return e.finish(c, e.deviceID, e.deviceSecret, a.assert(e.t, c.PublicKey))
}

func sessionToken(t *testing.T, response []byte) string {
	t.Helper()
	var out struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(response, &out); err != nil || out.Token == "" {
		t.Fatalf("no token: %v %s", err, response)
	}
	return out.Token
}

func TestPasskeyRegisterAndSignInWithEachAlgorithm(t *testing.T) {
	for name, ed := range map[string]bool{"es256": false, "ed25519": true} {
		t.Run(name, func(t *testing.T) {
			e := newPasskeyEnv(t, true)
			a := newTestAuthenticator(t, ed)
			id := e.registerPasskey(a, "Passkey 1")
			status, response := e.signIn(a)
			if status != http.StatusOK {
				t.Fatalf("sign in status=%d body=%s", status, response)
			}
			var out struct {
				Token, AccountID, DeviceID, Role string
			}
			var raw map[string]string
			_ = json.Unmarshal(response, &raw)
			if raw["token"] == "" || raw["account_id"] != e.accountID || raw["device_id"] != e.deviceID || raw["role"] != "owner" {
				t.Fatalf("login shape: %s %v", response, out)
			}
			status, response = e.do(http.MethodGet, "/api/v1/account/passkeys", raw["token"], nil)
			if status != http.StatusOK || !strings.Contains(string(response), id) || !strings.Contains(string(response), "Passkey 1") || strings.Contains(string(response), b64(a.credID)) {
				t.Fatalf("list status=%d body=%s", status, response)
			}
			// The passkey-sourced audit row names the method and the row ID only.
			if e.count(`SELECT COUNT(*) FROM audit_events WHERE event_type = 'session.login' AND metadata_json LIKE '%"method":"passkey"%'`) != 1 {
				t.Fatal("missing passkey login audit row")
			}
			if e.count(`SELECT COUNT(*) FROM audit_events WHERE event_type = 'passkey.added' AND metadata_json LIKE ?`, "%"+id+"%") != 1 {
				t.Fatal("missing passkey.added audit row")
			}
			// Sync event is an account event carrying the row ID only.
			if e.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'account.passkey_added' AND account_id = ? AND conversation_id IS NULL AND payload_json = ?`, e.accountID, `{"passkey_id":"`+id+`"}`) != 1 {
				t.Fatal("missing account.passkey_added sync event")
			}
		})
	}
}

func TestPasskeySignInGivesNoRecentAuth(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	e.registerPasskey(a, "Passkey 1")
	status, response := e.signIn(a)
	if status != http.StatusOK {
		t.Fatalf("sign in status=%d body=%s", status, response)
	}
	token := sessionToken(t, response)
	if e.count(`SELECT COUNT(*) FROM sessions WHERE recent_auth_at IS NOT NULL AND token_hash != ?`, hashToken(e.token)) != 0 {
		t.Fatal("passkey session carries recent_auth_at")
	}
	for _, route := range []struct{ method, path string }{
		{http.MethodPost, "/api/v1/auth/logout-all"}, {http.MethodPost, "/api/v1/account/password"},
		{http.MethodPost, "/api/v1/invites"}, {http.MethodGet, "/api/v1/account/export"},
		{http.MethodPost, "/api/v1/account/passkeys/options"}, {http.MethodPost, "/api/v1/account/passkeys"},
		{http.MethodDelete, "/api/v1/account/passkeys/pk_x"}, {http.MethodDelete, "/api/v1/account"},
		{http.MethodPost, "/api/v1/device-links"}, {http.MethodDelete, "/api/v1/devices/" + e.deviceID},
	} {
		status, body := e.do(route.method, route.path, token, map[string]interface{}{})
		if status != http.StatusForbidden || !strings.Contains(string(body), "recent_auth_required") {
			t.Fatalf("%s %s with a passkey session: status=%d body=%s", route.method, route.path, status, body)
		}
	}
}

func TestPasskeyRegistrationNeedsRecentAuth(t *testing.T) {
	e := newPasskeyEnv(t, true)
	e.exec(`UPDATE sessions SET recent_auth_at = NULL`)
	status, body := e.do(http.MethodPost, "/api/v1/account/passkeys/options", e.token, map[string]string{})
	if status != http.StatusForbidden {
		t.Fatalf("status=%d body=%s", status, body)
	}
}

func TestPasskeyDeviceChecksAreUniform(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	e.registerPasskey(a, "Passkey 1")
	// Wrong secret, unknown device: the same 401 at step 1.
	for _, tc := range []struct{ device, secret string }{{e.deviceID, "wrong"}, {"dev_unknown", e.deviceSecret}} {
		status, _, body := e.loginOptions(tc.device, tc.secret)
		if status != http.StatusUnauthorized || !strings.Contains(string(body), "invalid_credentials") {
			t.Fatalf("options %+v: status=%d body=%s", tc, status, body)
		}
	}
	// Wrong secret at step 2, after valid options.
	_, c, _ := e.loginOptions(e.deviceID, e.deviceSecret)
	status, body := e.finish(c, e.deviceID, "wrong", a.assert(t, c.PublicKey))
	if status != http.StatusUnauthorized || !strings.Contains(string(body), "invalid_credentials") {
		t.Fatalf("finish with a wrong secret: status=%d body=%s", status, body)
	}
	// Revoked device and suspended account.
	e.exec(`UPDATE devices SET revoked_at = ? WHERE id = ?`, "2026-01-01T00:00:00Z", e.deviceID)
	if status, _, _ := e.loginOptions(e.deviceID, e.deviceSecret); status != http.StatusUnauthorized {
		t.Fatalf("revoked device options status=%d", status)
	}
	if status, _ := e.finish(c, e.deviceID, e.deviceSecret, a.assert(t, c.PublicKey)); status != http.StatusUnauthorized {
		t.Fatalf("revoked device finish status=%d", status)
	}
	e.exec(`UPDATE devices SET revoked_at = NULL WHERE id = ?`, e.deviceID)
	e.exec(`UPDATE accounts SET status = 'suspended' WHERE id = ?`, e.accountID)
	if status, _, _ := e.loginOptions(e.deviceID, e.deviceSecret); status != http.StatusUnauthorized {
		t.Fatalf("suspended account options status=%d", status)
	}
	_, c, _ = e.loginOptions(e.deviceID, e.deviceSecret)
	if status, _ := e.finish(ceremonyResponse{CeremonyID: c.CeremonyID}, e.deviceID, e.deviceSecret, a.assert(t, c.PublicKey)); status != http.StatusUnauthorized {
		t.Fatalf("suspended account finish status=%d", status)
	}
}

func TestPasskeyRefusesAssertionsThatDoNotCheckOut(t *testing.T) {
	cases := map[string]func(e *pkEnv, a *testAuthenticator){
		"wrong user handle":  func(e *pkEnv, a *testAuthenticator) { a.userHdl = bytes.Repeat([]byte{7}, 32) },
		"backup eligibility": func(e *pkEnv, a *testAuthenticator) { a.be = true },
		"origin":             func(e *pkEnv, a *testAuthenticator) { a.origin = "https://evil.example.com" },
		"rp id":              func(e *pkEnv, a *testAuthenticator) { a.rpID = "evil.example.com" },
		"no user verified":   func(e *pkEnv, a *testAuthenticator) { a.noUV = true },
		"sign count regression": func(e *pkEnv, a *testAuthenticator) {
			e.exec(`UPDATE passkey_credentials SET sign_count = 5`)
			a.counter = 5
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			e := newPasskeyEnv(t, true)
			a := newTestAuthenticator(t, false)
			a.counter = 1
			e.registerPasskey(a, "Passkey 1")
			mutate(e, a)
			status, body := e.signIn(a)
			if status != http.StatusUnauthorized || !strings.Contains(string(body), "invalid_credentials") {
				t.Fatalf("status=%d body=%s", status, body)
			}
			if e.count(`SELECT COUNT(*) FROM sessions WHERE recent_auth_at IS NULL`) != 0 {
				t.Fatal("a refused assertion created a session")
			}
		})
	}
}

func TestPasskeySignCountClonedAuthenticatorIsAudited(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	a.counter = 1
	e.registerPasskey(a, "Passkey 1")
	a.counter = 2
	if status, body := e.signIn(a); status != http.StatusOK {
		t.Fatalf("increasing count status=%d body=%s", status, body)
	}
	a.counter = 2
	if status, _ := e.signIn(a); status != http.StatusUnauthorized {
		t.Fatalf("repeated count status=%d", status)
	}
	if e.count(`SELECT COUNT(*) FROM audit_events WHERE event_type = 'passkey.clone_warning'`) != 1 {
		t.Fatal("missing passkey.clone_warning audit row")
	}
	// A synced passkey always reports 0: accepted, and the count stays 0.
	b := newTestAuthenticator(t, true)
	b.be, b.bs = true, true
	e.registerPasskey(b, "Passkey 2")
	for i := 0; i < 2; i++ {
		if status, body := e.signIn(b); status != http.StatusOK {
			t.Fatalf("synced passkey status=%d body=%s", status, body)
		}
	}
}

func TestPasskeyBackupStateChangeIsStored(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	a.be = true
	e.registerPasskey(a, "Passkey 1")
	a.bs = true
	if status, body := e.signIn(a); status != http.StatusOK {
		t.Fatalf("status=%d body=%s", status, body)
	}
	if e.count(`SELECT COUNT(*) FROM passkey_credentials WHERE backup_state = 1`) != 1 {
		t.Fatal("backup state not stored")
	}
}

func TestPasskeyAnotherAccountsCredentialIsRefused(t *testing.T) {
	e := newPasskeyEnv(t, true)
	owner := newTestAuthenticator(t, false)
	e.registerPasskey(owner, "Passkey 1")
	// A second account with its own device and passkey.
	status, response := e.do(http.MethodPost, "/api/v1/invites", e.token, map[string]interface{}{"max_uses": 1})
	if status != http.StatusCreated {
		t.Fatalf("invite status=%d", status)
	}
	var invite struct {
		Code string `json:"code"`
	}
	_ = json.Unmarshal(response, &invite)
	enrollment := reserveEnrollment(t, e.handler, "/api/v1/register/enrollment", invite.Code)
	body := map[string]interface{}{"invite_code": invite.Code, "username": "member", "password": "member-password-123", "device_name": "member phone", "device_key_package": mlswiretest.KeyPackage()}
	addEnrollmentProof(body, enrollment)
	status, response = e.do(http.MethodPost, "/api/v1/register", "", body)
	if status != http.StatusCreated {
		t.Fatalf("register status=%d body=%s", status, response)
	}
	memberToken, _, memberDevice, memberSecret := decodeEnrollmentResult(t, response)
	member := &pkEnv{t: t, password: "member-password-123", handler: e.handler, db: e.db, token: memberToken, deviceID: memberDevice, deviceSecret: memberSecret, source: 100000}
	memberAuth := newTestAuthenticator(t, true)
	member.registerPasskey(memberAuth, "Member passkey")
	// The member's passkey cannot sign in to the owner's device, and neither
	// can the owner's on the member's device.
	_, c, _ := e.loginOptions(e.deviceID, e.deviceSecret)
	status, _ = e.finish(c, e.deviceID, e.deviceSecret, memberAuth.assert(t, c.PublicKey))
	if status != http.StatusUnauthorized {
		t.Fatalf("member passkey on owner device: %d", status)
	}
	_, c, _ = e.loginOptions(memberDevice, memberSecret)
	status, _ = e.finish(c, memberDevice, memberSecret, owner.assert(t, c.PublicKey))
	if status != http.StatusUnauthorized {
		t.Fatalf("owner passkey on member device: %d", status)
	}
	// And each works on its own device.
	if status, body := member.signIn(memberAuth); status != http.StatusOK {
		t.Fatalf("member own sign in: %d %s", status, body)
	}
	// Credential IDs are unique across the instance.
	dup := &testAuthenticator{ed: owner.ed, ec: owner.ec, credID: owner.credID, origin: pkOrigin, rpID: pkRPID}
	member.reauth()
	status, response = member.do(http.MethodPost, "/api/v1/account/passkeys/options", member.token, map[string]string{})
	var opts ceremonyResponse
	_ = json.Unmarshal(response, &opts)
	status, response = member.do(http.MethodPost, "/api/v1/account/passkeys", member.token, map[string]interface{}{"ceremony_id": opts.CeremonyID, "name": "dup", "credential": dup.register(t, opts.PublicKey)})
	if status != http.StatusConflict {
		t.Fatalf("duplicate credential id: status=%d body=%s", status, response)
	}
	// Account deletion removes the passkeys, the handle and open ceremonies.
	member.loginOptions(memberDevice, memberSecret)
	member.reauth()
	if status, body := member.do(http.MethodDelete, "/api/v1/account", member.token, nil); status != http.StatusNoContent && status != http.StatusOK {
		t.Fatalf("delete account status=%d body=%s", status, body)
	}
	for _, table := range []string{"passkey_credentials", "passkey_user_handles", "passkey_ceremonies"} {
		if n := e.count(`SELECT COUNT(*) FROM ` + table + ` WHERE account_id = (SELECT id FROM accounts WHERE username = 'member')`); n != 0 {
			t.Fatalf("%s kept %d rows after account deletion", table, n)
		}
	}
}

func TestPasskeyCeremonyIsSingleUseAndExpires(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	e.registerPasskey(a, "Passkey 1")
	_, c, _ := e.loginOptions(e.deviceID, e.deviceSecret)
	credential := a.assert(t, c.PublicKey)
	if status, body := e.finish(c, e.deviceID, e.deviceSecret, credential); status != http.StatusOK {
		t.Fatalf("first finish status=%d body=%s", status, body)
	}
	if status, _ := e.finish(c, e.deviceID, e.deviceSecret, credential); status != http.StatusUnauthorized {
		t.Fatalf("replayed ceremony status=%d", status)
	}
	_, c, _ = e.loginOptions(e.deviceID, e.deviceSecret)
	e.exec(`UPDATE passkey_ceremonies SET expires_at = ?`, "2020-01-01T00:00:00.000000000Z")
	if status, _ := e.finish(c, e.deviceID, e.deviceSecret, a.assert(t, c.PublicKey)); status != http.StatusUnauthorized {
		t.Fatalf("expired ceremony status=%d", status)
	}
}

func TestPasskeyConcurrentFinishesMakeExactlyOneSession(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	e.registerPasskey(a, "Passkey 1")
	_, c, _ := e.loginOptions(e.deviceID, e.deviceSecret)
	credential := a.assert(t, c.PublicKey)
	var arrived sync.WaitGroup
	arrived.Add(2)
	restore := httpapi.SetPasskeyBeforeSessionHookForTest(func() {
		arrived.Done()
		done := make(chan struct{})
		go func() { arrived.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
		}
	})
	defer restore()
	statuses := make(chan int, 2)
	for i := 0; i < 2; i++ {
		go func() {
			status, _ := e.finish(c, e.deviceID, e.deviceSecret, credential)
			statuses <- status
		}()
	}
	ok := 0
	for i := 0; i < 2; i++ {
		if <-statuses == http.StatusOK {
			ok++
		}
	}
	if ok != 1 {
		t.Fatalf("%d finishes succeeded, want exactly 1", ok)
	}
	if n := e.count(`SELECT COUNT(*) FROM sessions WHERE recent_auth_at IS NULL`); n != 1 {
		t.Fatalf("%d passkey sessions, want 1", n)
	}
}

func TestPasskeyDeletedMidCeremonyFailsTheFence(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	e.registerPasskey(a, "Passkey 1")
	restore := httpapi.SetPasskeyBeforeSessionHookForTest(func() { e.exec(`DELETE FROM passkey_credentials`) })
	defer restore()
	status, _ := e.signIn(a)
	if status != http.StatusUnauthorized {
		t.Fatalf("status=%d", status)
	}
	if e.count(`SELECT COUNT(*) FROM sessions WHERE recent_auth_at IS NULL`) != 0 {
		t.Fatal("session created for a deleted passkey")
	}
}

func TestPasskeyDeviceSecretChangedMidCeremonyFailsTheFence(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	e.registerPasskey(a, "Passkey 1")
	restore := httpapi.SetPasskeyBeforeSessionHookForTest(func() {
		e.exec(`UPDATE devices SET auth_secret_hash = 'changed' WHERE id = ?`, e.deviceID)
	})
	defer restore()
	if status, _ := e.signIn(a); status != http.StatusUnauthorized {
		t.Fatalf("status=%d", status)
	}
}

func TestPasskeyFailuresShareTheDevicesPasswordBackoff(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	e.registerPasskey(a, "Passkey 1")
	bad := newTestAuthenticator(t, false)
	bad.userHdl = a.userHdl
	// Two failed passkey sign-ins from one address, with a valid device secret.
	for i := 0; i < 2; i++ {
		_, c, _ := e.loginOptions(e.deviceID, e.deviceSecret)
		if status, _ := e.finish(c, e.deviceID, e.deviceSecret, bad.assert(t, c.PublicKey)); status != http.StatusUnauthorized {
			t.Fatalf("bad assertion %d status=%d", i, status)
		}
	}
	// A wrong-password login from another address is the third failure on the
	// shared account-device budget.
	status, body := e.doFrom("198.51.100.9", http.MethodPost, "/api/v1/auth/login", "", map[string]string{"username": "owner", "password": "wrong-password", "device_id": e.deviceID, "device_secret": e.deviceSecret})
	if status != http.StatusTooManyRequests {
		t.Fatalf("third failure status=%d body=%s", status, body)
	}
	// Both methods are now blocked for the secret holder.
	if status, _, _ := e.loginOptions(e.deviceID, e.deviceSecret); status != http.StatusTooManyRequests {
		t.Fatalf("passkey options after the shared budget: %d", status)
	}
	// Someone without the secret does not touch that bucket: a stranger's
	// failures never block the owner (no lock-out).
	f := newPasskeyEnv(t, true)
	for i := 0; i < 5; i++ {
		f.loginOptions(f.deviceID, "wrong-secret")
	}
	f.exec(`UPDATE devices SET id = id`)
	g := newTestAuthenticator(t, false)
	f.registerPasskey(g, "Passkey 1")
	if status, body := f.signInFrom("192.0.2.77", g); status != http.StatusOK {
		t.Fatalf("owner blocked by a stranger's failures: %d %s", status, body)
	}
}

func (e *pkEnv) signInFrom(addr string, a *testAuthenticator) (int, []byte) {
	e.t.Helper()
	status, response := e.doFrom(addr, http.MethodPost, "/api/v1/auth/passkey/options", "", map[string]string{"device_id": e.deviceID, "device_secret": e.deviceSecret})
	if status != http.StatusOK {
		return status, response
	}
	var c ceremonyResponse
	_ = json.Unmarshal(response, &c)
	return e.doFrom(addr, http.MethodPost, "/api/v1/auth/passkey", "", map[string]interface{}{"ceremony_id": c.CeremonyID, "device_id": e.deviceID, "device_secret": e.deviceSecret, "credential": a.assert(e.t, c.PublicKey)})
}

func TestPasskeyLimitsAndManagement(t *testing.T) {
	e := newPasskeyEnv(t, true)
	var ids []string
	for i := 0; i < 10; i++ {
		ids = append(ids, e.registerPasskey(newTestAuthenticator(t, i%2 == 0), fmt.Sprintf("Passkey %d", i+1)))
	}
	e.reauth()
	status, body := e.do(http.MethodPost, "/api/v1/account/passkeys/options", e.token, map[string]string{})
	if status != http.StatusConflict || !strings.Contains(string(body), "passkey_limit") {
		t.Fatalf("limit status=%d body=%s", status, body)
	}
	if status, _ := e.do(http.MethodPatch, "/api/v1/account/passkeys/"+ids[0], e.token, map[string]string{"name": strings.Repeat("x", 65)}); status != http.StatusBadRequest {
		t.Fatalf("long name status=%d", status)
	}
	if status, _ := e.do(http.MethodPatch, "/api/v1/account/passkeys/"+ids[0], e.token, map[string]string{"name": "Laptop"}); status != http.StatusNoContent {
		t.Fatalf("rename status=%d", status)
	}
	if status, _ := e.do(http.MethodDelete, "/api/v1/account/passkeys/"+ids[0], e.token, nil); status != http.StatusNoContent {
		t.Fatalf("delete status=%d", status)
	}
	if e.count(`SELECT COUNT(*) FROM audit_events WHERE event_type = 'passkey.removed'`) != 1 || e.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'account.passkey_removed'`) != 1 {
		t.Fatal("removal not audited and synced")
	}
	if status, _ := e.do(http.MethodDelete, "/api/v1/account/passkeys/"+ids[0], e.token, nil); status != http.StatusNotFound {
		t.Fatalf("second delete status=%d", status)
	}
}

func TestPasskeyCeremonyCapPerDevice(t *testing.T) {
	e := newPasskeyEnv(t, true)
	e.registerPasskey(newTestAuthenticator(t, false), "Passkey 1")
	var first ceremonyResponse
	for i := 0; i < 6; i++ {
		_, c, _ := e.loginOptions(e.deviceID, e.deviceSecret)
		if i == 0 {
			first = c
		}
	}
	if n := e.count(`SELECT COUNT(*) FROM passkey_ceremonies WHERE device_id = ?`, e.deviceID); n != 4 {
		t.Fatalf("%d open ceremonies, want 4", n)
	}
	if e.count(`SELECT COUNT(*) FROM passkey_ceremonies WHERE id = ?`, first.CeremonyID) != 0 {
		t.Fatal("the oldest ceremony was not evicted")
	}
}

func TestPasskeyRevokingADeviceDeletesItsCeremonies(t *testing.T) {
	e := newPasskeyEnv(t, true)
	e.registerPasskey(newTestAuthenticator(t, false), "Passkey 1")
	e.exec(`INSERT INTO devices(id, account_id, name, key_package, created_at) SELECT 'dev_second', account_id, 'second', key_package, created_at FROM devices WHERE id = ?`, e.deviceID)
	e.exec(`INSERT INTO passkey_ceremonies(id, kind, account_id, device_id, session_data, created_at, expires_at) VALUES('c1', 'login', ?, 'dev_second', X'7B7D', '2026-01-01T00:00:00Z', '2999-01-01T00:00:00Z')`, e.accountID)
	e.reauth()
	if status, body := e.do(http.MethodDelete, "/api/v1/devices/dev_second", e.token, nil); status != http.StatusNoContent {
		t.Fatalf("revoke status=%d body=%s", status, body)
	}
	if e.count(`SELECT COUNT(*) FROM passkey_ceremonies WHERE device_id = 'dev_second'`) != 0 {
		t.Fatal("a revoked device kept its ceremony")
	}
}

func TestPasskeysOffByDefault(t *testing.T) {
	e := newPasskeyEnv(t, false)
	for _, path := range []string{"/.well-known/assetlinks.json", "/.well-known/apple-app-site-association"} {
		if status, _ := e.do(http.MethodGet, path, "", nil); status != http.StatusNotFound {
			t.Fatalf("%s while off: %d", path, status)
		}
	}
	status, body := e.do(http.MethodPost, "/api/v1/auth/passkey/options", "", map[string]string{"device_id": e.deviceID, "device_secret": e.deviceSecret})
	if status != http.StatusServiceUnavailable || !strings.Contains(string(body), "passkeys_not_configured") {
		t.Fatalf("options while off: %d %s", status, body)
	}
	e.reauth()
	if status, _ := e.do(http.MethodPost, "/api/v1/account/passkeys/options", e.token, map[string]string{}); status != http.StatusServiceUnavailable {
		t.Fatalf("register options while off: %d", status)
	}
	status, body = e.do(http.MethodGet, "/api/v1/setup/status", "", nil)
	if status != http.StatusOK || strings.Contains(string(body), "passkeys") {
		t.Fatalf("setup status while off: %d %s", status, body)
	}
}

func TestPasskeyWellKnownFilesAndSetupStatus(t *testing.T) {
	e := newPasskeyEnv(t, true)
	status, body := e.do(http.MethodGet, "/.well-known/assetlinks.json", "", nil)
	var links []struct {
		Relation []string `json:"relation"`
		Target   struct {
			Namespace    string   `json:"namespace"`
			Package      string   `json:"package_name"`
			Fingerprints []string `json:"sha256_cert_fingerprints"`
		} `json:"target"`
	}
	if err := json.Unmarshal(body, &links); status != http.StatusOK || err != nil || len(links) != 1 || links[0].Relation[0] != "delegate_permission/common.get_login_creds" ||
		links[0].Target.Package != "com.veritra.app" || links[0].Target.Namespace != "android_app" || !strings.HasPrefix(links[0].Target.Fingerprints[0], "AA:BB:CC:DD") {
		t.Fatalf("assetlinks status=%d err=%v body=%s", status, err, body)
	}
	status, body = e.do(http.MethodGet, "/.well-known/apple-app-site-association", "", nil)
	if status != http.StatusOK || !strings.Contains(string(body), `"webcredentials":{"apps":["ABCDE12345.com.veritra.app"]}`) {
		t.Fatalf("aasa status=%d body=%s", status, body)
	}
	status, body = e.do(http.MethodGet, "/api/v1/setup/status", "", nil)
	if status != http.StatusOK || !strings.Contains(string(body), `"passkeys":{"android":true,"apple":true,"rp_id":"chat.example.com"}`) {
		t.Fatalf("setup status=%d body=%s", status, body)
	}
}

func TestPasskeyAndroidOriginRegistersAndSignsIn(t *testing.T) {
	e := newPasskeyEnv(t, true)
	parsed, _ := config.ParsePasskeys(pkOrigin, pkAndroid, "")
	a := newTestAuthenticator(t, false)
	a.origin = parsed.AndroidApps[0].Origin()
	e.registerPasskey(a, "Android passkey")
	if status, body := e.signIn(a); status != http.StatusOK {
		t.Fatalf("android origin sign in: %d %s", status, body)
	}
}

func TestPasskeyAccountExportAndDeleteLeaveNoKeyMaterial(t *testing.T) {
	e := newPasskeyEnv(t, true)
	a := newTestAuthenticator(t, false)
	e.registerPasskey(a, "Passkey 1")
	e.reauth()
	status, body := e.do(http.MethodGet, "/api/v1/account/export", e.token, nil)
	if status != http.StatusOK || !strings.Contains(string(body), `"passkeys"`) || !strings.Contains(string(body), "Passkey 1") || strings.Contains(string(body), b64(a.credID)) || strings.Contains(string(body), "public_key") {
		t.Fatalf("export status=%d body=%.400s", status, body)
	}
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return fmt.Sprintf("%x", sum)
}
