package httpapi_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"net/http"
	"strings"
	"testing"

	"private-messenger/server/internal/devicelist"
)

// L2-3: change 7 on POST /account/device-list. A listed device sets its own
// franking key, once; nothing else may change, no other device may set it,
// and no later version may change or drop it.
func TestChange7SetsOnlyTheCallersOwnFrankingKeyOnce(t *testing.T) {
	w := newDLWorld(t, true)
	other := dlActor{deviceID: "dev_" + strings.Repeat("9", 32)}
	other.pub, other.priv, _ = ed25519.GenerateKey(rand.Reader)
	key := func(b byte) []byte { k := bytes.Repeat([]byte{b}, 32); k[31] = 0x11; return k }
	sign := func(entries []devicelist.FrankKey, signer dlActor, change devicelist.Change) []byte {
		head := w.chain[len(w.chain)-1]
		body := dlBodyAfter(w.owner.accountID, head, t, change, []devicelist.Entry{w.owner.entry()}, nil)
		body.FrankKeys = entries
		return dlSign(body, signer)
	}
	own := devicelist.FrankKey{DeviceID: w.owner.deviceID, Key: key(0x21)}

	// Signed by a device that is not on the list.
	if status, body := w.post(w.owner.token, sign([]devicelist.FrankKey{own}, other, devicelist.ChangeFrankKey)); status != http.StatusBadRequest {
		t.Fatalf("change 7 by an unlisted device status=%d body=%s", status, body)
	}
	// A change 7 that sets no key.
	if status, body := w.post(w.owner.token, sign(nil, w.owner, devicelist.ChangeFrankKey)); status != http.StatusBadRequest {
		t.Fatalf("change 7 without a key status=%d body=%s", status, body)
	}
	good := sign([]devicelist.FrankKey{own}, w.owner, devicelist.ChangeFrankKey)
	if status, body := w.post(w.owner.token, good); status != http.StatusOK {
		t.Fatalf("change 7 status=%d body=%s", status, body)
	}
	w.chain = append(w.chain, good)
	if w.headVersion(w.owner.accountID) != 2 {
		t.Fatal("change 7 was not stored as version 2")
	}
	// Set once: a second change 7 that replaces it is refused.
	if status, body := w.post(w.owner.token, sign([]devicelist.FrankKey{{DeviceID: w.owner.deviceID, Key: key(0x22)}}, w.owner, devicelist.ChangeFrankKey)); status != http.StatusBadRequest {
		t.Fatalf("a replacing change 7 status=%d body=%s", status, body)
	}
	// The key stays: a later version that drops it is refused (checked by
	// CheckStep directly; change 5 has its own route).
	head := dlParse(t, w.chain[len(w.chain)-1])
	recoveryPub, _, _ := ed25519.GenerateKey(rand.Reader)
	dropped := dlBodyAfter(w.owner.accountID, w.chain[len(w.chain)-1], t, devicelist.ChangeRecoveryKey, []devicelist.Entry{w.owner.entry()}, recoveryPub)
	next := dlParse(t, dlSign(dropped, w.owner))
	if err := devicelist.CheckStep(w.owner.accountID, devicelist.History{Head: &head, SeenDevice: func(string) bool { return false }, SeenKey: func([]byte) bool { return false }}, next); err != devicelist.ErrBadFrankKey {
		t.Fatalf("dropping the key: %v", err)
	}
}
