package httpapi_test

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"reflect"
	"testing"
	"time"
)

// K0 R2 review follow-ups: HTTP behaviour.

// A small-order or invalid recovery auth key is refused like any other
// malformed key, and nothing is stored.
func TestPutRecoveryKeyRejectsSmallOrderAndInvalidKeys(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	for _, encoded := range []string{
		"0100000000000000000000000000000000000000000000000000000000000000",
		"0000000000000000000000000000000000000000000000000000000000000080",
		"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
		"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	} {
		key, err := hex.DecodeString(encoded)
		if err != nil {
			t.Fatal(err)
		}
		status, body := f.do(http.MethodPut, "/api/v1/account/recovery-key", f.ownerToken, map[string]interface{}{"rk_auth_pub": key, "rk_id": make([]byte, 16)}, nil)
		if status != http.StatusBadRequest || !jsonErrorIs(body, "invalid_recovery_key") {
			t.Errorf("key %s: status=%d body=%s", encoded, status, body)
		}
	}
	if n := f.count(`SELECT COUNT(*) FROM account_recovery_keys`); n != 0 {
		t.Fatalf("stored %d recovery keys", n)
	}
	status, body := f.do(http.MethodGet, "/api/v1/account/recovery-key", f.ownerToken, nil, nil)
	if status != http.StatusOK || !bytes.Contains(body, []byte(`"configured":false`)) {
		t.Fatalf("recovery key status=%d body=%s", status, body)
	}
}

// Completion deletes the account's device-less sessions, so their sockets
// are closed too; another account's stay open.
func TestRecoveryCompletionClosesDeviceLessSockets(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	f.makeOwnerIdle()
	claimed := f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
	restore, err := f.app.Hub.Register(f.ownerAccountID, "", "198.51.100.8")
	if err != nil {
		t.Fatal(err)
	}
	defer f.app.Hub.Unregister(restore)
	other, err := f.app.Hub.Register("acct_other", "", "198.51.100.9")
	if err != nil {
		t.Fatal(err)
	}
	defer f.app.Hub.Unregister(other)
	if status, body := f.status(claimed.RequestID, claimed.ClaimToken); status != http.StatusOK {
		t.Fatalf("status=%d body=%s", status, body)
	}
	deadline := time.After(5 * time.Second)
	for closed := false; !closed; {
		select {
		case _, open := <-restore.Send():
			closed = !open
		case <-deadline:
			t.Fatal("the device-less socket stayed open")
		}
	}
	select {
	case _, open := <-other.Send():
		if !open {
			t.Fatal("another account's device-less socket was closed")
		}
	default:
	}
}

// A new recovery key cancels the waiting request; the live event names the
// request, as the stored sync event does.
func TestPutRecoveryKeyCancelEventNamesTheRequest(t *testing.T) {
	f := newRecoveryFixture(t, recoveryTestOrigin)
	f.ownerRK = f.setRK(f.ownerToken)
	claimed := f.claimOK(claimBody(t, f.reserve("owner"), "owner-password-123", f.ownerRK, recoveryTestOrigin))
	client, err := f.app.Hub.Register(f.ownerAccountID, f.ownerDeviceID, "198.51.100.7")
	if err != nil {
		t.Fatal(err)
	}
	defer f.app.Hub.Unregister(client)
	f.setRK(f.ownerToken)
	var stored map[string]string
	var payload string
	if err := f.db.QueryRow(`SELECT payload_json FROM sync_events WHERE event_type = 'account.recovery.cancelled' AND account_id = ?`, f.ownerAccountID).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(payload), &stored); err != nil || stored["request_id"] != claimed.RequestID {
		t.Fatalf("stored payload %s: %v", payload, err)
	}
	for {
		select {
		case raw := <-client.Send():
			var event struct {
				Type    string            `json:"type"`
				Payload map[string]string `json:"payload"`
			}
			if err := json.Unmarshal(raw, &event); err != nil {
				t.Fatal(err)
			}
			if event.Type != "account.recovery.cancelled" {
				continue
			}
			if !reflect.DeepEqual(event.Payload, stored) {
				t.Fatalf("live payload %v, stored %v", event.Payload, stored)
			}
			return
		case <-time.After(5 * time.Second):
			t.Fatal("no live account.recovery.cancelled event")
		}
	}
}
