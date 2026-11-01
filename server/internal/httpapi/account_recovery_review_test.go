package httpapi_test

import (
	"bytes"
	"encoding/hex"
	"net/http"
	"testing"
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
