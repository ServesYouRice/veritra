package httpapi_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"testing"

	"private-messenger/server/internal/devicelist"
)

// memberLinkedInSync counts the device.member_linked events the token's sync
// lists from the start.
func memberLinkedInSync(t *testing.T, w *dlWorld, token string) int {
	t.Helper()
	status, response := w.do(http.MethodGet, "/api/v1/sync/events?after=0", token, nil)
	if status != http.StatusOK {
		t.Fatalf("sync status=%d body=%s", status, response)
	}
	return bytes.Count(response, []byte(`"device.member_linked"`))
}

// D96 for K0-R: the change-4 version a recovered device posts tells the
// coordinator account of each MLS group the recovered account is in, live and
// in sync, with the same notice a link approval writes. Recovery completion
// itself writes none (the device is not on the list head yet, so no
// coordinator could add it), nor do the change-6 genesis, the change-5
// recovery key, a refused change 4 or a replayed one.
//
// Bob's device founds the group alone (the owner is a member with no leaf),
// so bob's device coordinates whatever the generated ids: a notice written
// by the wrong version would reach bob and show here.
func TestRecoveryVersionNotifiesGroupCoordinatorOnce(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	w := &dlWorld{t: t, app: f.app, handler: f.handler, dbPath: f.dbPath, db: f.db,
		owner: dlActor{token: f.ownerToken, accountID: f.ownerAccountID, deviceID: f.ownerDeviceID, pub: f.ownerKey.Public().(ed25519.PublicKey), priv: f.ownerKey}}
	bob := w.registerMember("bob", false)
	conversationID := createConversation(t, f.handler, f.ownerToken)
	addMember(t, f.handler, f.ownerToken, conversationID, bob.accountID)
	if status, body := w.do(http.MethodPost, "/api/v1/conversations/"+conversationID+"/mls/commits", bob.token,
		map[string]interface{}{"epoch": 0, "idempotency_key": "genesis"}); status != http.StatusCreated {
		t.Fatalf("bob's genesis status=%d body=%s", status, body)
	}
	bobLive, err := f.app.Hub.Register(bob.accountID, bob.deviceID, "10.0.0.2")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(bobLive.Close)

	genesis := w.ownerStatement(devicelist.ChangeMigrationGenesis, []devicelist.Entry{w.owner.entry()}, nil, w.owner)
	if status, body := w.post(w.owner.token, genesis); status != http.StatusOK {
		t.Fatalf("genesis status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, genesis)
	authPub, authPriv, _ := ed25519.GenerateKey(rand.Reader)
	listPub, listPriv, _ := ed25519.GenerateKey(rand.Reader)
	setKey := w.ownerStatement(devicelist.ChangeRecoveryKey, []devicelist.Entry{w.owner.entry()}, listPub, w.owner)
	if status, body := w.do(http.MethodPut, "/api/v1/account/recovery-key", w.owner.token,
		map[string]interface{}{"rk_auth_pub": []byte(authPub), "rk_id": bytes.Repeat([]byte{0x42}, 16), "device_list": setKey}); status != http.StatusOK {
		t.Fatalf("recovery key status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, setKey)

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
	recoveredLive, err := f.app.Hub.Register(recovered.accountID, recovered.deviceID, "10.0.0.3")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(recoveredLive.Close)
	if count, _ := drainMemberLinked(t, bobLive); count != 0 {
		t.Fatalf("bob was told before the recovery version: %d live notices", count)
	}
	if got := memberLinkedInSync(t, w, bob.token); got != 0 {
		t.Fatalf("bob's sync lists %d notices before the recovery version", got)
	}

	recoverySign := func(key ed25519.PrivateKey) []byte {
		return devicelist.Sign(dlBodyAfter(w.owner.accountID, w.chain[len(w.chain)-1], t, devicelist.ChangeRecovery, []devicelist.Entry{recovered.entry()}, listPub), devicelist.SignerRecoveryKey, "", key)
	}
	_, wrongKey, _ := ed25519.GenerateKey(rand.Reader)
	if status, body := w.post(recovered.token, recoverySign(wrongKey)); status != http.StatusBadRequest {
		t.Fatalf("a wrongly signed recovery version status=%d body=%s", status, body)
	}
	if count, _ := drainMemberLinked(t, bobLive); count != 0 || memberLinkedInSync(t, w, bob.token) != 0 {
		t.Fatal("a refused recovery version told bob")
	}

	good := recoverySign(listPriv)
	if status, body := w.post(recovered.token, good); status != http.StatusOK {
		t.Fatalf("recovery version status=%d body=%s", status, body)
	}
	count, payload := drainMemberLinked(t, bobLive)
	if count != 1 {
		t.Fatalf("bob got %d live notices, want one", count)
	}
	if len(payload) != 2 || payload["account_id"] != recovered.accountID || payload["device_id"] != recovered.deviceID {
		t.Fatalf("payload = %v, want the recovered account and device only", payload)
	}
	if own, _ := drainMemberLinked(t, recoveredLive); own != 0 {
		t.Fatalf("the recovered account was told about its own device: %d", own)
	}
	if got := memberLinkedInSync(t, w, bob.token); got != 1 {
		t.Fatalf("bob's sync lists %d notices, want one", got)
	}
	if got := memberLinkedInSync(t, w, recovered.token); got != 0 {
		t.Fatalf("the recovered account's sync lists %d notices, want none", got)
	}
	// What the notice is for: bob's device now coordinates adding it.
	status, response = w.do(http.MethodGet, "/api/v1/mls/pending-changes", bob.token, nil)
	var pending struct {
		PendingChanges []struct {
			ConversationID string `json:"conversation_id"`
			Add            []struct {
				DeviceID string `json:"device_id"`
			} `json:"add"`
			CoordinatorDeviceID string `json:"coordinator_device_id"`
		} `json:"pending_changes"`
	}
	if status != http.StatusOK || json.Unmarshal(response, &pending) != nil || len(pending.PendingChanges) != 1 {
		t.Fatalf("pending changes status=%d body=%s", status, response)
	}
	change := pending.PendingChanges[0]
	if change.ConversationID != conversationID || change.CoordinatorDeviceID != bob.deviceID || len(change.Add) != 1 || change.Add[0].DeviceID != recovered.deviceID {
		t.Fatalf("pending change = %+v, want bob's device to add the recovered one", change)
	}

	// A replay is a conflict and tells nobody again.
	if status, body := w.post(recovered.token, good); status != http.StatusConflict {
		t.Fatalf("replayed recovery version status=%d body=%s", status, body)
	}
	if count, _ := drainMemberLinked(t, bobLive); count != 0 || memberLinkedInSync(t, w, bob.token) != 1 {
		t.Fatal("a replayed recovery version told bob again")
	}
}
