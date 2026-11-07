package httpapi_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"private-messenger/server/internal/app"
	"private-messenger/server/internal/auth"
	"private-messenger/server/internal/config"
	"private-messenger/server/internal/devicelist"
	"private-messenger/server/internal/httpapi"
	"private-messenger/server/internal/mlswire/mlswiretest"
	"private-messenger/server/internal/storage"
	"private-messenger/server/internal/storage/storagetest"
)

// L1-2 (D94): the approved-device list routes and the fields that carry a
// version on the existing routes. The statements here are signed by real
// Ed25519 keys through devicelist.Sign.

type dlActor struct {
	token, accountID, deviceID string
	pub                        ed25519.PublicKey
	priv                       ed25519.PrivateKey
}

func (a dlActor) entry() devicelist.Entry {
	return devicelist.Entry{DeviceID: a.deviceID, SigningKey: a.pub}
}

func dlEntries(entries ...devicelist.Entry) []devicelist.Entry {
	out := append([]devicelist.Entry(nil), entries...)
	sort.Slice(out, func(i, j int) bool { return out[i].DeviceID < out[j].DeviceID })
	return out
}

func dlParse(t *testing.T, raw []byte) devicelist.Statement {
	t.Helper()
	statement, err := devicelist.Parse(raw)
	if err != nil {
		t.Fatalf("parse statement: %v", err)
	}
	return statement
}

// dlBodyAfter is the body of the version that follows head (nil for a genesis).
func dlBodyAfter(accountID string, head []byte, t *testing.T, change devicelist.Change, entries []devicelist.Entry, recovery []byte) devicelist.Body {
	body := devicelist.Body{AccountID: accountID, Version: 1, PrevHash: make([]byte, 32), CreatedAtMs: uint64(time.Now().UnixMilli()), Change: change, Entries: dlEntries(entries...), RecoveryKey: recovery}
	if head != nil {
		parsed := dlParse(t, head)
		body.Version = parsed.Body.Version + 1
		body.PrevHash = parsed.Hash()
	}
	return body
}

func dlSign(body devicelist.Body, signer dlActor) []byte {
	return devicelist.Sign(body, devicelist.SignerDevice, signer.deviceID, signer.priv)
}

type dlWorld struct {
	t       *testing.T
	app     *app.App
	handler http.Handler
	dbPath  string
	db      *sql.DB
	owner   dlActor
	chain   [][]byte // the owner's statements, oldest first
	source  int
}

func dlStartApp(t *testing.T) (*app.App, http.Handler, string) {
	t.Helper()
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "private-messenger.db")
	storagetest.SeedMigrated(t, dbPath)
	application, err := app.New(context.Background(), config.Config{
		Addr: ":0", DataDir: dir, DatabasePath: dbPath, StoragePath: filepath.Join(dir, "blobs"),
		InstanceName: "Test Messenger", SetupToken: "test-setup-token", PublicOrigin: recoveryTestOrigin,
	}, nil)
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	t.Cleanup(func() { _ = application.Close() })
	return application, application.Handler(), dbPath
}

// newDLWorld sets up an owner, with a change-1 genesis when genesis is true.
func newDLWorld(t *testing.T, genesis bool) *dlWorld {
	t.Helper()
	application, handler, dbPath := dlStartApp(t)
	w := &dlWorld{t: t, app: application, handler: handler, dbPath: dbPath, db: openSessionTestDB(t, dbPath)}
	enrollment := reserveEnrollment(t, handler, "/api/v1/setup/owner/enrollment", "")
	var statement []byte
	if genesis {
		actor := dlActor{deviceID: enrollment.DeviceID, pub: enrollment.SigningKey, priv: enrollment.PrivateKey}
		statement = dlSign(dlBodyAfter(enrollment.AccountID, nil, t, devicelist.ChangeGenesis, []devicelist.Entry{actor.entry()}, nil), actor)
	}
	status, response := w.setupOwner(enrollment, statement)
	if status != http.StatusCreated {
		t.Fatalf("setup owner status=%d body=%s", status, response)
	}
	var decoded struct {
		Token   string `json:"token"`
		Account struct {
			ID string `json:"id"`
		} `json:"account"`
		Device struct {
			ID string `json:"id"`
		} `json:"device"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatal(err)
	}
	w.owner = dlActor{token: decoded.Token, accountID: decoded.Account.ID, deviceID: decoded.Device.ID, pub: enrollment.SigningKey, priv: enrollment.PrivateKey}
	if genesis {
		w.chain = append(w.chain, statement)
	}
	return w
}

func (w *dlWorld) setupOwner(enrollment testEnrollment, statement []byte) (int, []byte) {
	body := map[string]interface{}{
		"instance_name": "Test Messenger", "username": "owner", "password": "owner-password-123",
		"device_name": "owner phone", "device_key_package": mlswiretest.KeyPackage(),
	}
	addEnrollmentProof(body, enrollment)
	if statement != nil {
		body["device_list"] = statement
	}
	return doJSON(w.t, w.handler, http.MethodPost, "/api/v1/setup/owner", "", body)
}

// do sends a request from a new client address each time, so the per-address
// rate limiter stays out of the way.
func (w *dlWorld) do(method, path, token string, body interface{}) (int, []byte) {
	w.t.Helper()
	var raw []byte
	if body != nil {
		var err error
		if raw, err = json.Marshal(body); err != nil {
			w.t.Fatal(err)
		}
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	w.source++
	req.RemoteAddr = fmt.Sprintf("203.1.%d.%d:5000", w.source/250, w.source%250+1)
	rec := httptest.NewRecorder()
	w.handler.ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

func (w *dlWorld) count(query string, args ...interface{}) int {
	w.t.Helper()
	var n int
	if err := w.db.QueryRow(query, args...).Scan(&n); err != nil {
		w.t.Fatalf("count %q: %v", query, err)
	}
	return n
}

func (w *dlWorld) exec(query string, args ...interface{}) {
	w.t.Helper()
	if _, err := w.db.Exec(query, args...); err != nil {
		w.t.Fatalf("exec %q: %v", query, err)
	}
}

// ownerStatement signs the next owner version.
func (w *dlWorld) ownerStatement(change devicelist.Change, entries []devicelist.Entry, recovery []byte, signer dlActor) []byte {
	var head []byte
	if len(w.chain) > 0 {
		head = w.chain[len(w.chain)-1]
	}
	return dlSign(dlBodyAfter(w.owner.accountID, head, w.t, change, entries, recovery), signer)
}

func (w *dlWorld) registerMember(username string, genesis bool) dlActor {
	w.t.Helper()
	status, response := w.do(http.MethodPost, "/api/v1/invites", w.owner.token, map[string]interface{}{"max_uses": 1})
	if status != http.StatusCreated {
		w.t.Fatalf("create invite status=%d body=%s", status, response)
	}
	var invite struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(response, &invite); err != nil {
		w.t.Fatal(err)
	}
	enrollment := reserveEnrollment(w.t, w.handler, "/api/v1/register/enrollment", invite.Code)
	actor := dlActor{deviceID: enrollment.DeviceID, accountID: enrollment.AccountID, pub: enrollment.SigningKey, priv: enrollment.PrivateKey}
	body := map[string]interface{}{
		"invite_code": invite.Code, "username": username, "password": "member-password-123",
		"device_name": username + " phone", "device_key_package": mlswiretest.KeyPackage(),
	}
	addEnrollmentProof(body, enrollment)
	if genesis {
		body["device_list"] = dlSign(dlBodyAfter(enrollment.AccountID, nil, w.t, devicelist.ChangeGenesis, []devicelist.Entry{actor.entry()}, nil), actor)
	}
	status, response = w.do(http.MethodPost, "/api/v1/register", "", body)
	if status != http.StatusCreated {
		w.t.Fatalf("register %s status=%d body=%s", username, status, response)
	}
	var decoded struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		w.t.Fatal(err)
	}
	actor.token = decoded.Token
	return actor
}

type dlPage struct {
	AccountID   string `json:"account_id"`
	Found       *bool  `json:"found"`
	HeadVersion uint64 `json:"head_version"`
	Statements  []struct {
		Version   uint64    `json:"version"`
		ListHash  []byte    `json:"list_hash"`
		Statement []byte    `json:"statement"`
		CreatedAt time.Time `json:"created_at"`
	} `json:"statements"`
	More bool `json:"more"`
}

func (w *dlWorld) get(token, accountID, query string) (int, []byte, dlPage) {
	w.t.Helper()
	status, body := w.do(http.MethodGet, "/api/v1/accounts/"+accountID+"/device-list"+query, token, nil)
	var page dlPage
	if status == http.StatusOK {
		if err := json.Unmarshal(body, &page); err != nil {
			w.t.Fatalf("decode page %s: %v", body, err)
		}
	}
	return status, body, page
}

func (w *dlWorld) post(token string, statement []byte) (int, []byte) {
	return w.do(http.MethodPost, "/api/v1/account/device-list", token, map[string]interface{}{"device_list": statement})
}

func (w *dlWorld) headVersion(accountID string) int {
	w.t.Helper()
	return w.count(`SELECT COALESCE(MAX(version), 0) FROM device_list_versions WHERE account_id = ?`, accountID)
}

func TestDeviceListGenesisAtSetupAndRegisterIsStoredAndServed(t *testing.T) {
	w := newDLWorld(t, true)
	status, body, page := w.get(w.owner.token, w.owner.accountID, "")
	if status != http.StatusOK || page.HeadVersion != 1 || len(page.Statements) != 1 || page.More {
		t.Fatalf("owner list status=%d body=%s", status, body)
	}
	if !bytes.Equal(page.Statements[0].Statement, w.chain[0]) {
		t.Fatal("the served statement is not the uploaded one")
	}
	if !bytes.Equal(page.Statements[0].ListHash, dlParse(t, w.chain[0]).Hash()) {
		t.Fatal("list_hash differs from the statement's hash")
	}
	if n := w.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'device_list.updated' AND account_id = ?`, w.owner.accountID); n != 1 {
		t.Fatalf("device_list.updated events = %d", n)
	}
	if n := w.count(`SELECT COUNT(*) FROM device_list_devices WHERE account_id = ? AND device_id = ? AND added_version = 1 AND removed_version IS NULL`, w.owner.accountID, w.owner.deviceID); n != 1 {
		t.Fatalf("derived device rows = %d", n)
	}
	member := w.registerMember("alice", true)
	if got := w.headVersion(member.accountID); got != 1 {
		t.Fatalf("member head = %d", got)
	}
	// An account from before L1 (no genesis) has no head and is still served as such.
	legacy := w.registerMember("bob", false)
	status, body, page = w.get(legacy.token, legacy.accountID, "")
	if status != http.StatusOK || page.HeadVersion != 0 || len(page.Statements) != 0 || page.More {
		t.Fatalf("legacy list status=%d body=%s", status, body)
	}
	if w.count(`SELECT COUNT(*) FROM device_list_versions WHERE account_id = ?`, legacy.accountID) != 0 {
		t.Fatal("an account without a genesis gained a list")
	}
}

func TestSetupWithABadGenesisCreatesNothing(t *testing.T) {
	application, handler, dbPath := dlStartApp(t)
	w := &dlWorld{t: t, app: application, handler: handler, dbPath: dbPath, db: openSessionTestDB(t, dbPath)}
	enrollment := reserveEnrollment(t, handler, "/api/v1/setup/owner/enrollment", "")
	me := dlActor{deviceID: enrollment.DeviceID, pub: enrollment.SigningKey, priv: enrollment.PrivateKey}
	other := dlActor{deviceID: "dev_" + strings.Repeat("e", 32)}
	other.pub, other.priv, _ = ed25519.GenerateKey(rand.Reader)
	good := func(mutate func(*devicelist.Body)) devicelist.Body {
		body := dlBodyAfter(enrollment.AccountID, nil, t, devicelist.ChangeGenesis, []devicelist.Entry{me.entry()}, nil)
		if mutate != nil {
			mutate(&body)
		}
		return body
	}
	_, wrongKey, _ := ed25519.GenerateKey(rand.Reader)
	cases := map[string][]byte{
		"signed by another key": devicelist.Sign(good(nil), devicelist.SignerDevice, me.deviceID, wrongKey),
		"another account":       dlSign(good(func(b *devicelist.Body) { b.AccountID = "acct_" + strings.Repeat("a", 32) }), me),
		"another device":        dlSign(good(func(b *devicelist.Body) { b.Entries = []devicelist.Entry{other.entry()} }), other),
		"the wrong signing key": dlSign(good(func(b *devicelist.Body) {
			b.Entries = []devicelist.Entry{{DeviceID: me.deviceID, SigningKey: other.pub}}
		}), dlActor{deviceID: me.deviceID, priv: other.priv}),
		"two devices":               dlSign(good(func(b *devicelist.Body) { b.Entries = dlEntries(me.entry(), other.entry()) }), me),
		"a migration genesis":       dlSign(good(func(b *devicelist.Body) { b.Change = devicelist.ChangeMigrationGenesis }), me),
		"a recovery key at genesis": dlSign(good(func(b *devicelist.Body) { b.RecoveryKey = bytes.Repeat([]byte{7}, 32) }), me),
		"not a statement":           []byte("VDL1 garbage"),
	}
	for name, statement := range cases {
		status, body := w.setupOwner(enrollment, statement)
		if status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_device_list") {
			t.Errorf("%s: status=%d body=%s", name, status, body)
		}
		if w.count(`SELECT COUNT(*) FROM accounts`) != 0 || w.count(`SELECT COUNT(*) FROM device_list_versions`) != 0 || w.count(`SELECT COUNT(*) FROM devices`) != 0 {
			t.Fatalf("%s: a refused genesis left rows behind", name)
		}
	}
	// The reservation is still usable: the right statement succeeds.
	if status, body := w.setupOwner(enrollment, dlSign(good(nil), me)); status != http.StatusCreated {
		t.Fatalf("retry with a good genesis status=%d body=%s", status, body)
	}
	if w.headVersion(enrollment.AccountID) != 1 {
		t.Fatal("the genesis was not stored")
	}
}

func TestDeviceListReadersAndUniform404(t *testing.T) {
	w := newDLWorld(t, true)
	alice := w.registerMember("alice", true)
	stranger := w.registerMember("carol", true)
	status, response := w.do(http.MethodPost, "/api/v1/conversations", w.owner.token, map[string]interface{}{"kind": "group"})
	if status != http.StatusCreated {
		t.Fatalf("create conversation status=%d body=%s", status, response)
	}
	var conversation struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(response, &conversation); err != nil {
		t.Fatal(err)
	}
	if status, response = w.do(http.MethodPost, "/api/v1/conversations/"+conversation.ID+"/members", w.owner.token, map[string]interface{}{"account_id": alice.accountID}); status != http.StatusCreated && status != http.StatusOK {
		t.Fatalf("add member status=%d body=%s", status, response)
	}

	if status, _, page := w.get(w.owner.token, w.owner.accountID, ""); status != http.StatusOK || page.HeadVersion != 1 {
		t.Fatalf("the account reads its own list: %d", status)
	}
	if status, _, page := w.get(alice.token, w.owner.accountID, ""); status != http.StatusOK || page.HeadVersion != 1 {
		t.Fatalf("a conversation peer reads the list: %d", status)
	}
	if status, _, page := w.get(w.owner.token, alice.accountID, ""); status != http.StatusOK || page.HeadVersion != 1 {
		t.Fatalf("the peer relation is symmetric: %d", status)
	}
	// A stranger and an unknown account get the same 404, byte for byte.
	strangerStatus, strangerBody, _ := w.get(stranger.token, w.owner.accountID, "")
	unknownStatus, unknownBody, _ := w.get(stranger.token, "acct_"+strings.Repeat("0", 32), "")
	if strangerStatus != http.StatusNotFound || unknownStatus != http.StatusNotFound || !bytes.Equal(strangerBody, unknownBody) {
		t.Fatalf("stranger %d %s, unknown %d %s", strangerStatus, strangerBody, unknownStatus, unknownBody)
	}
	if status, _, _ := w.get("", w.owner.accountID, ""); status != http.StatusUnauthorized {
		t.Fatalf("unauthenticated read status=%d", status)
	}
	if status, body, _ := w.get(w.owner.token, w.owner.accountID, "?after=-1"); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_after") {
		t.Fatalf("after=-1 status=%d body=%s", status, body)
	}
	if status, _, page := w.get(w.owner.token, w.owner.accountID, "?after=1"); status != http.StatusOK || len(page.Statements) != 0 || page.HeadVersion != 1 || page.More {
		t.Fatalf("after=1: %d %+v", status, page)
	}

	// The batch read answers the same for unreadable and unknown accounts.
	query := func(token string, items ...map[string]interface{}) (int, []byte, []dlPage) {
		status, body := w.do(http.MethodPost, "/api/v1/device-lists/query", token, map[string]interface{}{"items": items})
		var decoded struct {
			Items []dlPage `json:"items"`
		}
		if status == http.StatusOK {
			if err := json.Unmarshal(body, &decoded); err != nil {
				t.Fatalf("decode batch %s: %v", body, err)
			}
		}
		return status, body, decoded.Items
	}
	status, body, items := query(alice.token,
		map[string]interface{}{"account_id": w.owner.accountID, "after": 0},
		map[string]interface{}{"account_id": stranger.accountID, "after": 0},
		map[string]interface{}{"account_id": "acct_" + strings.Repeat("0", 32), "after": 0},
		map[string]interface{}{"account_id": alice.accountID, "after": 1})
	if status != http.StatusOK || len(items) != 4 {
		t.Fatalf("batch status=%d body=%s", status, body)
	}
	if items[0].Found == nil || !*items[0].Found || len(items[0].Statements) != 1 || items[0].AccountID != w.owner.accountID {
		t.Fatalf("readable item: %+v", items[0])
	}
	for _, index := range []int{1, 2} {
		if items[index].Found == nil || *items[index].Found || len(items[index].Statements) != 0 || items[index].HeadVersion != 0 || items[index].More {
			t.Fatalf("unreadable item %d: %+v", index, items[index])
		}
	}
	if items[3].Found == nil || !*items[3].Found || len(items[3].Statements) != 0 || items[3].HeadVersion != 1 {
		t.Fatalf("own item after the head: %+v", items[3])
	}
	// Bounds: no items, too many, a negative cursor, a missing id.
	if status, _, _ := query(alice.token); status != http.StatusBadRequest {
		t.Fatalf("empty batch status=%d", status)
	}
	many := make([]map[string]interface{}, 101)
	for i := range many {
		many[i] = map[string]interface{}{"account_id": alice.accountID, "after": 0}
	}
	if status, _, _ := query(alice.token, many...); status != http.StatusBadRequest {
		t.Fatalf("101 items status=%d", status)
	}
	if status, _, _ := query(alice.token, many[:100]...); status != http.StatusOK {
		t.Fatalf("100 items status=%d", status)
	}
	if status, _, _ := query(alice.token, map[string]interface{}{"account_id": alice.accountID, "after": -1}); status != http.StatusBadRequest {
		t.Fatalf("negative cursor status=%d", status)
	}
	if status, _, _ := query(alice.token, map[string]interface{}{"account_id": "", "after": 0}); status != http.StatusBadRequest {
		t.Fatalf("empty id status=%d", status)
	}
}

func TestDeviceListPagingAndBatchBudget(t *testing.T) {
	w := newDLWorld(t, true)
	// Versions 2..70 as opaque rows: the read routes serve what is stored and
	// never parse it.
	for version := 2; version <= 70; version++ {
		w.exec(`INSERT INTO device_list_versions(account_id, version, list_hash, statement, change, signer_device_id, created_at) VALUES(?, ?, ?, ?, 2, ?, ?)`,
			w.owner.accountID, version, bytes.Repeat([]byte{byte(version)}, 32), []byte(fmt.Sprintf("row-%d", version)), w.owner.deviceID, "2026-11-07T00:00:00Z")
	}
	status, _, page := w.get(w.owner.token, w.owner.accountID, "")
	if status != http.StatusOK || len(page.Statements) != 64 || !page.More || page.HeadVersion != 70 || page.Statements[0].Version != 1 || page.Statements[63].Version != 64 {
		t.Fatalf("first page: %d %d statements more=%v head=%d", status, len(page.Statements), page.More, page.HeadVersion)
	}
	status, _, page = w.get(w.owner.token, w.owner.accountID, "?after=64")
	if status != http.StatusOK || len(page.Statements) != 6 || page.More || page.Statements[0].Version != 65 || page.Statements[5].Version != 70 {
		t.Fatalf("last page: %d %d statements more=%v", status, len(page.Statements), page.More)
	}
	// Five items of the same account: the budget of 256 statements covers four
	// full pages; the fifth gets none and is told there is more.
	items := make([]map[string]interface{}, 5)
	for i := range items {
		items[i] = map[string]interface{}{"account_id": w.owner.accountID, "after": 0}
	}
	status, body := w.do(http.MethodPost, "/api/v1/device-lists/query", w.owner.token, map[string]interface{}{"items": items})
	var decoded struct {
		Items []dlPage `json:"items"`
	}
	if status != http.StatusOK || json.Unmarshal(body, &decoded) != nil || len(decoded.Items) != 5 {
		t.Fatalf("batch status=%d", status)
	}
	total := 0
	for index, item := range decoded.Items {
		total += len(item.Statements)
		wantStatements := 64
		if index == 4 {
			wantStatements = 0
		}
		if len(item.Statements) != wantStatements || !item.More {
			t.Fatalf("item %d has %d statements, more=%v", index, len(item.Statements), item.More)
		}
	}
	if total != 256 {
		t.Fatalf("batch returned %d statements", total)
	}
}

// linkV3 links a second device through the v3 route with a change-2 version
// signed by the owner, and returns the new device.
func (w *dlWorld) linkV3(t *testing.T) (*v3APIFixture, dlActor) {
	t.Helper()
	f := newV3APIFixtureOn(t, w.app, w.handler, w.owner.token, w.dbPath)
	device := dlActor{deviceID: f.recipientDeviceID, pub: f.claim.SigningKey}
	statement := w.ownerStatement(devicelist.ChangeAdd, []devicelist.Entry{w.owner.entry(), device.entry()}, nil, w.owner)
	status, response := doJSON(t, w.handler, http.MethodPost, v3Base+"/"+f.link.ID+"/approve", w.owner.token, f.approveBody(statement))
	if status != http.StatusOK {
		t.Fatalf("approve v3 with a list status=%d body=%s", status, response)
	}
	w.chain = append(w.chain, statement)
	return f, device
}

func (f *v3APIFixture) approveBody(statement []byte) map[string]interface{} {
	body := map[string]interface{}{"protocol_version": storage.DeviceLinkV3Protocol, "claim_request_hash": f.link.ClaimRequestHash, "transcript_hash": f.claim.TranscriptHash, "approval_tag": bytes.Repeat([]byte{9}, 32)}
	if statement != nil {
		body["device_list"] = statement
	}
	return body
}

func TestLinkV3ApproveRequiresAndStoresTheDeviceListVersion(t *testing.T) {
	w := newDLWorld(t, true)
	f := newV3APIFixtureOn(t, w.app, w.handler, w.owner.token, w.dbPath)
	device := dlActor{deviceID: f.recipientDeviceID, pub: f.claim.SigningKey}
	approve := func(statement []byte) (int, []byte) {
		return w.do(http.MethodPost, v3Base+"/"+f.link.ID+"/approve", w.owner.token, f.approveBody(statement))
	}
	devicesBefore := w.count(`SELECT COUNT(*) FROM devices WHERE account_id = ?`, w.owner.accountID)
	assertNothingChanged := func(name string) {
		t.Helper()
		if w.count(`SELECT COUNT(*) FROM devices WHERE account_id = ?`, w.owner.accountID) != devicesBefore || w.headVersion(w.owner.accountID) != 1 {
			t.Fatalf("%s: a refused approval changed the account", name)
		}
		if w.count(`SELECT COUNT(*) FROM device_links_v3 WHERE id = ? AND state = 'claimed'`, f.link.ID) != 1 {
			t.Fatalf("%s: the link left the claimed state", name)
		}
	}
	// With a head, an approval must carry the version.
	if status, body := approve(nil); status != http.StatusBadRequest || !jsonErrorIs(body, "device_list_required") {
		t.Fatalf("no version: status=%d body=%s", status, body)
	}
	assertNothingChanged("no version")

	otherPub, otherPriv, _ := ed25519.GenerateKey(rand.Reader)
	stranger := dlActor{deviceID: "dev_" + strings.Repeat("9", 32), pub: otherPub, priv: otherPriv}
	entries := []devicelist.Entry{w.owner.entry(), device.entry()}
	bad := map[string][]byte{
		"a different key for the new device": w.ownerStatement(devicelist.ChangeAdd, []devicelist.Entry{w.owner.entry(), {DeviceID: device.deviceID, SigningKey: otherPub}}, nil, w.owner),
		"a different device":                 w.ownerStatement(devicelist.ChangeAdd, []devicelist.Entry{w.owner.entry(), stranger.entry()}, nil, w.owner),
		"signed by a device not on the list": dlSign(dlBodyAfter(w.owner.accountID, w.chain[0], t, devicelist.ChangeAdd, entries, nil), stranger),
		"a removal in place of an add":       w.ownerStatement(devicelist.ChangeRemove, []devicelist.Entry{w.owner.entry()}, nil, w.owner),
		"an unparseable statement":           []byte("not a statement"),
	}
	for name, statement := range bad {
		if status, body := approve(statement); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_device_list") {
			t.Errorf("%s: status=%d body=%s", name, status, body)
		}
		assertNothingChanged(name)
	}
	// A version that does not chain from the head: 409 with the head version.
	stale := dlBodyAfter(w.owner.accountID, w.chain[0], t, devicelist.ChangeAdd, entries, nil)
	stale.PrevHash = bytes.Repeat([]byte{3}, 32)
	status, body := approve(dlSign(stale, w.owner))
	var conflict struct {
		Error       string `json:"error"`
		HeadVersion uint64 `json:"head_version"`
	}
	if status != http.StatusConflict || json.Unmarshal(body, &conflict) != nil || conflict.Error != "device_list_conflict" || conflict.HeadVersion != 1 {
		t.Fatalf("stale prev_hash: status=%d body=%s", status, body)
	}
	skipped := dlBodyAfter(w.owner.accountID, w.chain[0], t, devicelist.ChangeAdd, entries, nil)
	skipped.Version = 3
	if status, body := approve(dlSign(skipped, w.owner)); status != http.StatusConflict || !strings.Contains(string(body), "device_list_conflict") {
		t.Fatalf("version gap: status=%d body=%s", status, body)
	}
	assertNothingChanged("conflicts")

	good := w.ownerStatement(devicelist.ChangeAdd, entries, nil, w.owner)
	if status, body := approve(good); status != http.StatusOK {
		t.Fatalf("good approval status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, good)
	if w.headVersion(w.owner.accountID) != 2 || w.count(`SELECT COUNT(*) FROM devices WHERE account_id = ? AND id = ?`, w.owner.accountID, device.deviceID) != 1 {
		t.Fatal("the device and its version did not land together")
	}
	if w.count(`SELECT COUNT(*) FROM device_list_devices WHERE account_id = ? AND device_id = ? AND added_version = 2 AND removed_version IS NULL`, w.owner.accountID, device.deviceID) != 1 {
		t.Fatal("derived row missing")
	}
	if n := w.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'device_list.updated' AND account_id = ?`, w.owner.accountID); n != 2 {
		t.Fatalf("device_list.updated events = %d", n)
	}
	// A retry of the same approval is answered without a second version.
	if status, body := approve(good); status != http.StatusOK {
		t.Fatalf("approval retry status=%d body=%s", status, body)
	}
	if w.headVersion(w.owner.accountID) != 2 {
		t.Fatal("a retried approval added a version")
	}
}

// claimV2Link creates a v2 device link as the owner and claims it, ready for
// approval.
func (w *dlWorld) claimV2Link() (string, testEnrollment) {
	t := w.t
	t.Helper()
	status, response := w.do(http.MethodPost, "/api/v1/device-links", w.owner.token, map[string]interface{}{"code": strings.Repeat("c", 64)})
	if status != http.StatusCreated {
		t.Fatalf("create device link status=%d body=%s", status, response)
	}
	var created struct {
		DeviceLink struct {
			ID   string `json:"id"`
			Code string `json:"code"`
		} `json:"device_link"`
	}
	if err := json.Unmarshal(response, &created); err != nil {
		t.Fatal(err)
	}
	enrollment := reserveEnrollment(t, w.handler, "/api/v1/device-links/claim-enrollment", created.DeviceLink.Code)
	claim := map[string]interface{}{
		"code": created.DeviceLink.Code, "device_name": "linked tablet", "device_key_package": mlswiretest.KeyPackage(),
		"transcript_hash": bytes.Repeat([]byte{7}, 32), "claim_tag": bytes.Repeat([]byte{8}, 32),
	}
	addEnrollmentProof(claim, enrollment)
	if status, response = w.do(http.MethodPost, "/api/v1/device-links/claim", "", claim); status != http.StatusAccepted {
		t.Fatalf("claim status=%d body=%s", status, response)
	}
	return created.DeviceLink.ID, enrollment
}

func TestLinkV2ApproveRequiresAndStoresTheDeviceListVersion(t *testing.T) {
	w := newDLWorld(t, true)
	linkID, enrollment := w.claimV2Link()
	device := dlActor{deviceID: enrollment.DeviceID, pub: enrollment.SigningKey}
	approve := func(statement []byte) (int, []byte) {
		body := map[string]interface{}{"transcript_hash": bytes.Repeat([]byte{7}, 32), "approval_tag": bytes.Repeat([]byte{9}, 32)}
		if statement != nil {
			body["device_list"] = statement
		}
		return w.do(http.MethodPost, "/api/v1/device-links/"+linkID+"/approve", w.owner.token, body)
	}
	if status, body := approve(nil); status != http.StatusBadRequest || !jsonErrorIs(body, "device_list_required") {
		t.Fatalf("no version: status=%d body=%s", status, body)
	}
	if w.count(`SELECT COUNT(*) FROM devices WHERE id = ?`, device.deviceID) != 0 {
		t.Fatal("a refused approval created the device")
	}
	wrong := w.ownerStatement(devicelist.ChangeAdd, []devicelist.Entry{w.owner.entry(), {DeviceID: device.deviceID, SigningKey: bytes.Repeat([]byte{5}, 32)}}, nil, w.owner)
	if status, body := approve(wrong); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_device_list") {
		t.Fatalf("wrong key: status=%d body=%s", status, body)
	}
	good := w.ownerStatement(devicelist.ChangeAdd, []devicelist.Entry{w.owner.entry(), device.entry()}, nil, w.owner)
	if status, body := approve(good); status != http.StatusOK {
		t.Fatalf("good approval status=%d body=%s", status, body)
	}
	if w.headVersion(w.owner.accountID) != 2 || w.count(`SELECT COUNT(*) FROM devices WHERE id = ?`, device.deviceID) != 1 {
		t.Fatal("the device and its version did not land together")
	}
}

func TestRevokeStoresTheChange3VersionAndRepairRemovesRevokedSiblings(t *testing.T) {
	w := newDLWorld(t, true)
	_, linked := w.linkV3(t) // chain: v1 owner, v2 owner+linked

	// A removal that does not match the revoked device is refused and the
	// device stays live.
	wrong := w.ownerStatement(devicelist.ChangeRemove, []devicelist.Entry{linked.entry()}, nil, w.owner) // removes the owner
	if status, body := w.do(http.MethodDelete, "/api/v1/devices/"+linked.deviceID, w.owner.token, map[string]interface{}{"device_list": wrong}); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_device_list") {
		t.Fatalf("mismatched removal status=%d body=%s", status, body)
	}
	if w.count(`SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NULL`, linked.deviceID) != 1 || w.headVersion(w.owner.accountID) != 2 {
		t.Fatal("a refused revocation changed state")
	}
	good := w.ownerStatement(devicelist.ChangeRemove, []devicelist.Entry{w.owner.entry()}, nil, w.owner)
	if status, body := w.do(http.MethodDelete, "/api/v1/devices/"+linked.deviceID, w.owner.token, map[string]interface{}{"device_list": good}); status != http.StatusNoContent {
		t.Fatalf("revoke with a version status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, good)
	if w.headVersion(w.owner.accountID) != 3 || w.count(`SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NOT NULL`, linked.deviceID) != 1 {
		t.Fatal("the revocation and its version did not land together")
	}
	if w.count(`SELECT COUNT(*) FROM device_list_devices WHERE account_id = ? AND device_id = ? AND removed_version = 3`, w.owner.accountID, linked.deviceID) != 1 {
		t.Fatal("derived row not marked removed")
	}

	// The removed device never returns, even if the server still had it.
	again := w.ownerStatement(devicelist.ChangeAdd, []devicelist.Entry{w.owner.entry(), linked.entry()}, nil, w.owner)
	if status, body := w.post(w.owner.token, again); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_device_list") {
		t.Fatalf("re-adding a removed device status=%d body=%s", status, body)
	}

	// Repair: a revocation without a version leaves the device listed; a listed
	// device then signs the removal, with no recent auth, but only for devices
	// the server already revoked.
	f2, second := w.linkV3(t) // v4 add
	_ = f2
	if status, body := w.do(http.MethodDelete, "/api/v1/devices/"+second.deviceID, w.owner.token, nil); status != http.StatusNoContent {
		t.Fatalf("revoke without a version status=%d body=%s", status, body)
	}
	if w.headVersion(w.owner.accountID) != 4 || w.count(`SELECT COUNT(*) FROM device_list_devices WHERE account_id = ? AND device_id = ? AND removed_version IS NULL`, w.owner.accountID, second.deviceID) != 1 {
		t.Fatal("a revocation with no version changed the list")
	}
	w.exec(`UPDATE sessions SET recent_auth_at = '2020-01-01T00:00:00Z' WHERE account_id = ?`, w.owner.accountID)
	repair := w.ownerStatement(devicelist.ChangeRemove, []devicelist.Entry{w.owner.entry()}, nil, w.owner)
	if status, body := w.post(w.owner.token, repair); status != http.StatusOK {
		t.Fatalf("repair status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, repair)
	if w.headVersion(w.owner.accountID) != 5 {
		t.Fatal("repair version missing")
	}
	// Removing a device the server has not revoked is refused on this route.
	third := dlActor{deviceID: "dev_" + strings.Repeat("7", 32)}
	third.pub, third.priv, _ = ed25519.GenerateKey(rand.Reader)
	w.exec(`INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES(?, ?, 'x', X'01', ?, 'h', '2026-11-07T00:00:00Z')`, third.deviceID, w.owner.accountID, []byte(third.pub))
	// (listed through a proper add first, then removed while still live)
	add := w.ownerStatement(devicelist.ChangeAdd, []devicelist.Entry{w.owner.entry(), third.entry()}, nil, w.owner)
	_ = add // an add has no route of its own here; seed the derived state instead
	w.exec(`INSERT INTO device_list_versions(account_id, version, list_hash, statement, change, signer_device_id, created_at) VALUES(?, 6, ?, ?, 2, ?, '2026-11-07T00:00:00Z')`, w.owner.accountID, dlParse(t, add).Hash(), add, w.owner.deviceID)
	w.exec(`INSERT INTO device_list_devices(account_id, device_id, signing_key, added_version) VALUES(?, ?, ?, 6)`, w.owner.accountID, third.deviceID, []byte(third.pub))
	w.chain = append(w.chain, add)
	liveRemoval := w.ownerStatement(devicelist.ChangeRemove, []devicelist.Entry{w.owner.entry()}, nil, w.owner)
	if status, body := w.post(w.owner.token, liveRemoval); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_device_list") {
		t.Fatalf("removing a live device through the repair route status=%d body=%s", status, body)
	}
	// An add or a recovery-key change has no business on this route.
	if status, body := w.post(w.owner.token, w.ownerStatement(devicelist.ChangeRecoveryKey, []devicelist.Entry{w.owner.entry(), third.entry()}, bytes.Repeat([]byte{4}, 32), w.owner)); status != http.StatusBadRequest {
		t.Fatalf("change 5 on the repair route status=%d body=%s", status, body)
	}
}

func TestMigrationGenesisNeedsRecentAuthAndLiveMatchingDevices(t *testing.T) {
	w := newDLWorld(t, false)
	if w.headVersion(w.owner.accountID) != 0 {
		t.Fatal("an owner set up without a genesis has a list")
	}
	genesis := func(entries []devicelist.Entry, signer dlActor) []byte {
		return dlSign(dlBodyAfter(w.owner.accountID, nil, t, devicelist.ChangeMigrationGenesis, entries, nil), signer)
	}
	// An account's other device, alive, and one that is revoked.
	live := dlActor{deviceID: "dev_" + strings.Repeat("a", 32)}
	live.pub, live.priv, _ = ed25519.GenerateKey(rand.Reader)
	dead := dlActor{deviceID: "dev_" + strings.Repeat("b", 32)}
	dead.pub, dead.priv, _ = ed25519.GenerateKey(rand.Reader)
	w.exec(`INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at) VALUES(?, ?, 'live', X'01', ?, 'h', '2026-11-07T00:00:00Z')`, live.deviceID, w.owner.accountID, []byte(live.pub))
	w.exec(`INSERT INTO devices(id, account_id, name, key_package, signing_key, auth_secret_hash, created_at, revoked_at) VALUES(?, ?, 'dead', X'01', ?, 'h', '2026-11-07T00:00:00Z', '2026-11-07T01:00:00Z')`, dead.deviceID, w.owner.accountID, []byte(dead.pub))

	// Without recent auth.
	w.exec(`UPDATE sessions SET recent_auth_at = '2020-01-01T00:00:00Z' WHERE account_id = ?`, w.owner.accountID)
	if status, body := w.post(w.owner.token, genesis([]devicelist.Entry{w.owner.entry()}, w.owner)); status != http.StatusForbidden || !jsonErrorIs(body, "recent_auth_required") {
		t.Fatalf("stale auth status=%d body=%s", status, body)
	}
	w.exec(`UPDATE sessions SET recent_auth_at = ? WHERE account_id = ?`, time.Now().UTC().Format("2006-01-02T15:04:05.000000000Z"), w.owner.accountID)
	refused := map[string][]byte{
		"a revoked device":                genesis([]devicelist.Entry{w.owner.entry(), dead.entry()}, w.owner),
		"a key that is not the device's":  genesis([]devicelist.Entry{w.owner.entry(), {DeviceID: live.deviceID, SigningKey: dead.pub}}, w.owner),
		"a device the account lacks":      genesis([]devicelist.Entry{w.owner.entry(), {DeviceID: "dev_" + strings.Repeat("c", 32), SigningKey: bytes.Repeat([]byte{6}, 32)}}, w.owner),
		"signed by a device not on it":    genesis([]devicelist.Entry{w.owner.entry()}, live),
		"not including the signer":        genesis([]devicelist.Entry{live.entry()}, w.owner),
		"a plain genesis (change 1) here": dlSign(dlBodyAfter(w.owner.accountID, nil, t, devicelist.ChangeGenesis, []devicelist.Entry{w.owner.entry()}, nil), w.owner),
	}
	for name, statement := range refused {
		if status, body := w.post(w.owner.token, statement); status != http.StatusBadRequest {
			t.Errorf("%s: status=%d body=%s", name, status, body)
		}
	}
	if w.headVersion(w.owner.accountID) != 0 {
		t.Fatal("a refused migration genesis stored a version")
	}
	good := genesis([]devicelist.Entry{w.owner.entry(), live.entry()}, w.owner)
	if status, body := w.post(w.owner.token, good); status != http.StatusOK {
		t.Fatalf("migration genesis status=%d body=%s", status, body)
	}
	if status, body := w.post(w.owner.token, good); status != http.StatusConflict || !strings.Contains(string(body), "device_list_conflict") {
		t.Fatalf("a second genesis status=%d body=%s", status, body)
	}
	if status, body := w.post("", good); status != http.StatusUnauthorized {
		t.Fatalf("unauthenticated publish status=%d body=%s", status, body)
	}
	if status, body := w.do(http.MethodPost, "/api/v1/account/device-list", w.owner.token, map[string]interface{}{}); status != http.StatusBadRequest || !jsonErrorIs(body, "device_list_required") {
		t.Fatalf("empty publish status=%d body=%s", status, body)
	}
}

func TestRecoveryKeyPutCarriesTheChange5VersionAndRecoveryAddsChange4(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	w := &dlWorld{t: t, app: f.app, handler: f.handler, dbPath: f.dbPath, db: f.db,
		owner: dlActor{token: f.ownerToken, accountID: f.ownerAccountID, deviceID: f.ownerDeviceID, pub: f.ownerKey.Public().(ed25519.PublicKey), priv: f.ownerKey}}
	// The owner publishes the migration genesis; recovery must be set after it.
	genesis := w.ownerStatement(devicelist.ChangeMigrationGenesis, []devicelist.Entry{w.owner.entry()}, nil, w.owner)
	if status, body := w.post(w.owner.token, genesis); status != http.StatusOK {
		t.Fatalf("genesis status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, genesis)

	authPub, authPriv, _ := ed25519.GenerateKey(rand.Reader)
	rkID := bytes.Repeat([]byte{0x42}, 16)
	listPub, listPriv, _ := ed25519.GenerateKey(rand.Reader)
	put := func(statement []byte) (int, []byte) {
		body := map[string]interface{}{"rk_auth_pub": []byte(authPub), "rk_id": rkID}
		if statement != nil {
			body["device_list"] = statement
		}
		return w.do(http.MethodPut, "/api/v1/account/recovery-key", w.owner.token, body)
	}
	// With a head, the recovery key cannot be set without its version.
	if status, body := put(nil); status != http.StatusBadRequest || !jsonErrorIs(body, "device_list_required") {
		t.Fatalf("no version: status=%d body=%s", status, body)
	}
	if f.count(`SELECT COUNT(*) FROM account_recovery_keys`) != 0 {
		t.Fatal("a refused recovery key was stored")
	}
	// The version must set a key, and chain from the head.
	if status, body := put(w.ownerStatement(devicelist.ChangeRecoveryKey, []devicelist.Entry{w.owner.entry()}, nil, w.owner)); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_device_list") {
		t.Fatalf("a change 5 without a key: status=%d body=%s", status, body)
	}
	smallOrder := bytes.Repeat([]byte{0}, 32)
	smallOrder[0] = 1
	if status, body := put(w.ownerStatement(devicelist.ChangeRecoveryKey, []devicelist.Entry{w.owner.entry()}, smallOrder, w.owner)); status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_device_list") {
		t.Fatalf("a small-order recovery key: status=%d body=%s", status, body)
	}
	if status, body := put(w.ownerStatement(devicelist.ChangeAdd, []devicelist.Entry{w.owner.entry()}, listPub, w.owner)); status != http.StatusBadRequest {
		t.Fatalf("another change kind: status=%d body=%s", status, body)
	}
	if f.count(`SELECT COUNT(*) FROM account_recovery_keys`) != 0 || w.headVersion(w.owner.accountID) != 1 {
		t.Fatal("a refused recovery key changed state")
	}
	setKey := w.ownerStatement(devicelist.ChangeRecoveryKey, []devicelist.Entry{w.owner.entry()}, listPub, w.owner)
	if status, body := put(setKey); status != http.StatusOK {
		t.Fatalf("recovery key with its version status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, setKey)
	if f.count(`SELECT COUNT(*) FROM account_recovery_keys`) != 1 || w.headVersion(w.owner.accountID) != 2 {
		t.Fatal("the recovery key and its version did not land together")
	}

	// Recovery: the owner is idle, the claim completes at once and revokes the
	// owner's device. The new device then posts change 4, signed by the key the
	// list names.
	f.makeOwnerIdle()
	body := claimBody(t, f.reserve("owner"), "owner-password-123", authPriv, recoveryTestOrigin)
	newKey := ed25519.PublicKey(body["signing_key"].([]byte))
	claimed := f.claimOK(body)
	status, response := f.status(claimed.RequestID, claimed.ClaimToken)
	var completed struct {
		State  string `json:"state"`
		Token  string `json:"token"`
		Device struct {
			ID string `json:"id"`
		} `json:"device"`
	}
	if status != http.StatusOK || json.Unmarshal(response, &completed) != nil || completed.State != "completed" || completed.Token == "" {
		t.Fatalf("recovery completion status=%d body=%s", status, response)
	}
	recovered := dlActor{token: completed.Token, accountID: w.owner.accountID, deviceID: completed.Device.ID, pub: newKey}
	listed := []devicelist.Entry{recovered.entry()}
	recoverySign := func(entries []devicelist.Entry, key ed25519.PrivateKey) []byte {
		return devicelist.Sign(dlBodyAfter(w.owner.accountID, w.chain[len(w.chain)-1], t, devicelist.ChangeRecovery, entries, listPub), devicelist.SignerRecoveryKey, "", key)
	}
	_, wrongKey, _ := ed25519.GenerateKey(rand.Reader)
	refused := map[string][]byte{
		"signed by another key":        recoverySign(listed, wrongKey),
		"signed by a device":           dlSign(dlBodyAfter(w.owner.accountID, w.chain[len(w.chain)-1], t, devicelist.ChangeRecovery, listed, listPub), dlActor{deviceID: recovered.deviceID, priv: wrongKey}),
		"listing two devices":          recoverySign(dlEntries(recovered.entry(), w.owner.entry()), listPriv),
		"listing the revoked device":   recoverySign([]devicelist.Entry{w.owner.entry()}, listPriv),
		"a changed recovery key":       devicelist.Sign(dlBodyAfter(w.owner.accountID, w.chain[len(w.chain)-1], t, devicelist.ChangeRecovery, listed, authPub), devicelist.SignerRecoveryKey, "", listPriv),
		"a device that does not exist": recoverySign([]devicelist.Entry{{DeviceID: "dev_" + strings.Repeat("d", 32), SigningKey: bytes.Repeat([]byte{8}, 32)}}, listPriv),
	}
	for name, statement := range refused {
		if status, body := w.post(recovered.token, statement); status != http.StatusBadRequest {
			t.Errorf("%s: status=%d body=%s", name, status, body)
		}
	}
	if w.headVersion(w.owner.accountID) != 2 {
		t.Fatal("a refused recovery version was stored")
	}
	// The revoked owner device cannot post at all.
	if status, _ := w.post(w.owner.token, recoverySign(listed, listPriv)); status != http.StatusUnauthorized {
		t.Fatalf("the revoked device's session still works: %d", status)
	}
	good := recoverySign(listed, listPriv)
	if status, body := w.post(recovered.token, good); status != http.StatusOK {
		t.Fatalf("recovery version status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, good)
	if w.headVersion(w.owner.accountID) != 3 {
		t.Fatal("recovery version missing")
	}
	if f.count(`SELECT COUNT(*) FROM device_list_devices WHERE account_id = ? AND device_id = ? AND removed_version = 3`, w.owner.accountID, w.owner.deviceID) != 1 {
		t.Fatal("the lost device was not marked removed")
	}
	// Posting it again, or a second recovery, is a conflict or refused.
	if status, body := w.post(recovered.token, good); status != http.StatusConflict {
		t.Fatalf("replayed recovery version status=%d body=%s", status, body)
	}
}

func TestChange4IsRefusedForADeviceRecoveryDidNotEnroll(t *testing.T) {
	w := newDLWorld(t, true)
	rkPub, rkPriv, _ := ed25519.GenerateKey(rand.Reader)
	setKey := w.ownerStatement(devicelist.ChangeRecoveryKey, []devicelist.Entry{w.owner.entry()}, rkPub, w.owner)
	authPub, _, _ := ed25519.GenerateKey(rand.Reader)
	status, body := w.do(http.MethodPut, "/api/v1/account/recovery-key", w.owner.token, map[string]interface{}{"rk_auth_pub": []byte(authPub), "rk_id": bytes.Repeat([]byte{1}, 16), "device_list": setKey})
	if status != http.StatusOK {
		t.Fatalf("set recovery key status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, setKey)
	// The one active device holds the recovery key's list key, but it was not
	// enrolled by recovery completion: its change 4 is refused.
	statement := devicelist.Sign(dlBodyAfter(w.owner.accountID, w.chain[1], t, devicelist.ChangeRecovery, []devicelist.Entry{{DeviceID: w.owner.deviceID, SigningKey: w.owner.pub}}, rkPub), devicelist.SignerRecoveryKey, "", rkPriv)
	if status, body := w.post(w.owner.token, statement); status != http.StatusBadRequest {
		t.Fatalf("change 4 from a non-recovered device status=%d body=%s", status, body)
	}
}

// A head with no recovery key (a recovery key set before L1, not yet confirmed
// on a device) refuses a recovery claim with the same 401 as no key at all, does
// the same work, and does not count the user's own correct key toward D79. A
// wrong key still counts.
func TestRecoveryClaimOnAHeadWithoutARecoveryKeyIsRefusedWithoutCountingTowardD79(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken) // the pre-L1 key: set while the account has no list
	w := &dlWorld{t: t, app: f.app, handler: f.handler, dbPath: f.dbPath, db: f.db,
		owner: dlActor{token: f.ownerToken, accountID: f.ownerAccountID, deviceID: f.ownerDeviceID, pub: f.ownerKey.Public().(ed25519.PublicKey), priv: f.ownerKey}}
	var mu sync.Mutex
	var steps []string
	restore := httpapi.SetRecoveryClaimWorkHookForTest(func(step string) {
		mu.Lock()
		steps = append(steps, step)
		mu.Unlock()
	})
	defer restore()
	f.makeOwnerIdle()
	failures := func() int {
		return f.count(`SELECT COALESCE(SUM(failures), 0) FROM recovery_attempts WHERE account_id = ?`, f.ownerAccountID)
	}
	claim := func(password string, rk ed25519.PrivateKey) (int, []byte, []string) {
		mu.Lock()
		steps = nil
		mu.Unlock()
		status, body := f.do(http.MethodPost, "/api/v1/account-recovery/claim", "", claimBody(t, f.reserve("owner"), password, rk, recoveryTestOrigin), nil)
		mu.Lock()
		defer mu.Unlock()
		return status, body, append([]string(nil), steps...)
	}
	// Before any list the key works.
	status, claimResponse, _ := claim("owner-password-123", f.ownerRK)
	if status != http.StatusAccepted {
		t.Fatalf("claim before the list status=%d", status)
	}
	var early recoveryClaimResponse
	if err := json.Unmarshal(claimResponse, &early); err != nil || early.RequestID == "" {
		t.Fatalf("claim response %s: %v", claimResponse, err)
	}
	// Publish the migration genesis: a list with no recovery key.
	genesis := w.ownerStatement(devicelist.ChangeMigrationGenesis, []devicelist.Entry{w.owner.entry()}, nil, w.owner)
	if status, body := w.post(w.owner.token, genesis); status != http.StatusOK {
		t.Fatalf("genesis status=%d body=%s", status, body)
	}
	// A claim filed before the list must not complete onto it: completion
	// would revoke every listed device and nothing could sign the version
	// that lists the new one.
	if status, body := f.status(early.RequestID, early.ClaimToken); status != http.StatusGone || !jsonErrorIs(body, "recovery_cancelled") {
		t.Fatalf("completion onto a keyless head status=%d body=%s", status, body)
	}
	if f.count(`SELECT COUNT(*) FROM devices WHERE account_id = ? AND revoked_at IS NULL`, f.ownerAccountID) != 1 ||
		f.count(`SELECT COUNT(*) FROM devices WHERE account_id = ?`, f.ownerAccountID) != 1 {
		t.Fatal("a refused completion revoked a device or enrolled one")
	}
	base := failures()
	status, body, correct := claim("owner-password-123", f.ownerRK)
	if status != http.StatusUnauthorized || !jsonErrorIs(body, "invalid_credentials") {
		t.Fatalf("correct key on a keyless head status=%d body=%s", status, body)
	}
	if got := failures(); got != base {
		t.Fatalf("the correct key was counted: failures %d -> %d", base, got)
	}
	_, wrongRK, _ := ed25519.GenerateKey(rand.Reader)
	status, wrongBody, wrong := claim("owner-password-123", wrongRK)
	if status != http.StatusUnauthorized || !bytes.Equal(wrongBody, body) {
		t.Fatalf("wrong key status=%d body=%s", status, wrongBody)
	}
	if got := failures(); got != base+1 {
		t.Fatalf("a wrong key must count: failures %d -> %d", base, got)
	}
	want := []string{"password", "recovery_signature", "attempt"}
	if !reflect.DeepEqual(correct, want) || !reflect.DeepEqual(wrong, want) {
		t.Fatalf("work differs: correct=%v wrong=%v want=%v", correct, wrong, want)
	}
	// No leak warning and no account backoff from the user's own correct key:
	// repeating it keeps answering 401 without a retry delay.
	for i := 0; i < 12; i++ {
		if status, body, _ := claim("owner-password-123", f.ownerRK); status != http.StatusUnauthorized || !jsonErrorIs(body, "invalid_credentials") {
			t.Fatalf("repeat %d: status=%d body=%s", i, status, body)
		}
	}
	if got := failures(); got != base+1 {
		t.Fatalf("repeated correct keys were counted: %d", got)
	}
	if n := f.count(`SELECT COUNT(*) FROM sync_events WHERE event_type = 'account.password_leak_suspected' AND account_id = ?`, f.ownerAccountID); n != 0 {
		t.Fatalf("leak warnings = %d", n)
	}
	// Confirming the key on a device (change 5) makes recovery work again.
	rkListPub, _, _ := ed25519.GenerateKey(rand.Reader)
	w.chain = append(w.chain, genesis)
	set := w.ownerStatement(devicelist.ChangeRecoveryKey, []devicelist.Entry{w.owner.entry()}, rkListPub, w.owner)
	authPub := f.ownerRK.Public().(ed25519.PublicKey)
	if status, body := w.do(http.MethodPut, "/api/v1/account/recovery-key", w.owner.token, map[string]interface{}{"rk_auth_pub": []byte(authPub), "rk_id": bytes.Repeat([]byte{3}, 16), "device_list": set}); status != http.StatusOK {
		t.Fatalf("confirm status=%d body=%s", status, body)
	}
	if status, body, _ := claim("owner-password-123", f.ownerRK); status != http.StatusAccepted {
		t.Fatalf("claim after confirming the key status=%d body=%s", status, body)
	}
}

// Deleting an account deletes its list, and the list is no longer readable.
func TestDeletingAnAccountDeletesItsDeviceList(t *testing.T) {
	w := newDLWorld(t, true)
	alice := w.registerMember("alice", true)
	if w.headVersion(alice.accountID) != 1 {
		t.Fatal("no list to delete")
	}
	if status, body := w.do(http.MethodDelete, "/api/v1/account", alice.token, nil); status != http.StatusNoContent {
		t.Fatalf("delete account status=%d body=%s", status, body)
	}
	if w.count(`SELECT COUNT(*) FROM device_list_versions WHERE account_id = ?`, alice.accountID) != 0 ||
		w.count(`SELECT COUNT(*) FROM device_list_devices WHERE account_id = ?`, alice.accountID) != 0 {
		t.Fatal("the deleted account's list is still stored")
	}
	if status, _, _ := w.get(w.owner.token, alice.accountID, ""); status != http.StatusNotFound {
		t.Fatalf("a deleted account's list reads as %d", status)
	}
}

// Nothing in the logs or audit trail carries a statement.
func TestDeviceListAuditCarriesOnlyAccountVersionAndChange(t *testing.T) {
	w := newDLWorld(t, true)
	w.linkV3(t)
	rows, err := w.db.Query(`SELECT event_type, metadata_json FROM audit_events WHERE event_type = 'account.device_list_updated'`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	seen := 0
	for rows.Next() {
		var eventType, metadata string
		if err := rows.Scan(&eventType, &metadata); err != nil {
			t.Fatal(err)
		}
		var decoded map[string]interface{}
		if err := json.Unmarshal([]byte(metadata), &decoded); err != nil || len(decoded) != 2 || decoded["version"] == nil || decoded["change"] == nil {
			t.Fatalf("audit metadata %s: %v", metadata, err)
		}
		seen++
	}
	if seen == 0 {
		t.Fatal("no audit event for the added version")
	}
}

// A session with no device cannot sign the version a list needs: the v2
// approval refuses it with device_session_required (D94, fail closed), changes
// nothing, and the recovery-key and revoke routes refuse it too (recent
// authentication already needs a device).
func TestDevicelessSessionCannotApproveALinkOrChangeRecoveryOrRevokeOnAList(t *testing.T) {
	w := newDLWorld(t, true)
	linkID, enrollment := w.claimV2Link()
	token := "deviceless-session-token-for-d94"
	now := time.Now().UTC().Format("2006-01-02T15:04:05.000000000Z")
	later := time.Now().UTC().Add(time.Hour).Format("2006-01-02T15:04:05.000000000Z")
	w.exec(`INSERT INTO sessions(token_hash, account_id, device_id, expires_at, created_at, recent_auth_at, last_used_at, absolute_expires_at) VALUES(?, ?, NULL, ?, ?, ?, ?, ?)`,
		auth.HashToken(token), w.owner.accountID, later, now, now, now, later)

	approve := map[string]interface{}{"transcript_hash": bytes.Repeat([]byte{7}, 32), "approval_tag": bytes.Repeat([]byte{9}, 32)}
	if status, body := w.do(http.MethodPost, "/api/v1/device-links/"+linkID+"/approve", token, approve); status != http.StatusBadRequest || !jsonErrorIs(body, "device_session_required") {
		t.Fatalf("approve: status=%d body=%s", status, body)
	}
	listed := w.ownerStatement(devicelist.ChangeAdd, []devicelist.Entry{w.owner.entry(), {DeviceID: enrollment.DeviceID, SigningKey: enrollment.SigningKey}}, nil, w.owner)
	approve["device_list"] = listed
	if status, body := w.do(http.MethodPost, "/api/v1/device-links/"+linkID+"/approve", token, approve); status != http.StatusBadRequest || !jsonErrorIs(body, "device_session_required") {
		t.Fatalf("approve with a version: status=%d body=%s", status, body)
	}
	if w.count(`SELECT COUNT(*) FROM devices WHERE id = ?`, enrollment.DeviceID) != 0 || w.headVersion(w.owner.accountID) != 1 {
		t.Fatal("a refused approval changed state")
	}

	authPub, _, _ := ed25519.GenerateKey(rand.Reader)
	put := map[string]interface{}{"rk_auth_pub": []byte(authPub), "rk_id": bytes.Repeat([]byte{0x42}, 16)}
	if status, body := w.do(http.MethodPut, "/api/v1/account/recovery-key", token, put); status != http.StatusForbidden || !jsonErrorIs(body, "recent_auth_required") {
		t.Fatalf("recovery key: status=%d body=%s", status, body)
	}
	if w.count(`SELECT COUNT(*) FROM account_recovery_keys`) != 0 || w.headVersion(w.owner.accountID) != 1 {
		t.Fatal("a refused recovery key changed state")
	}
	status, body := w.do(http.MethodDelete, "/api/v1/devices/"+w.owner.deviceID, token, map[string]interface{}{"device_list": listed})
	if status != http.StatusForbidden || !jsonErrorIs(body, "recent_auth_required") {
		t.Fatalf("revoke: status=%d body=%s", status, body)
	}
	if w.count(`SELECT COUNT(*) FROM devices WHERE id = ? AND revoked_at IS NULL`, w.owner.deviceID) != 1 {
		t.Fatal("a refused revoke revoked the device")
	}
}
