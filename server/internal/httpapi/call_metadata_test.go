package httpapi

import (
	"encoding/json"
	"testing"
)

func TestCallMetadataAllowsOnlyEncryptedEnvelope(t *testing.T) {
	valid := json.RawMessage(`{"version":1,"ciphertext":"AQID","protocol":"mls10-openmls-v1","sender_device_id":"dev_test","action_id":"action_test"}`)
	if !validCallMetadata(valid) {
		t.Fatal("valid encrypted call envelope was rejected")
	}

	invalid := []json.RawMessage{
		json.RawMessage(`{"version":1,"ciphertext":"AQID","protocol":"mls10-openmls-v1","sender_device_id":"dev_test","action_id":"action_test","sdp":"plaintext"}`),
		json.RawMessage(`{"version":1,"ciphertext":"AQID","protocol":"mls10-openmls-v1","sender_device_id":"dev_test","action_id":"action_test","ice":{"candidate":"plaintext"}}`),
		json.RawMessage(`{"version":1,"ciphertext":"","protocol":"mls10-openmls-v1","sender_device_id":"dev_test","action_id":"action_test"}`),
		json.RawMessage(`{"version":1,"ciphertext":"AQID","protocol":"custom","sender_device_id":"dev_test","action_id":"action_test"}`),
		json.RawMessage(`{"version":2,"ciphertext":"AQID","protocol":"mls10-openmls-v1","sender_device_id":"dev_test","action_id":"action_test"}`),
	}
	for _, raw := range invalid {
		if validCallMetadata(raw) {
			t.Fatalf("unsafe call metadata accepted: %s", raw)
		}
	}
}
