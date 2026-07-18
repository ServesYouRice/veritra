package httpapi

import (
	"encoding/json"
	"testing"
)

func TestCallMetadataAllowsOnlyEncryptedEnvelope(t *testing.T) {
	valid := json.RawMessage(`{"version":1,"ciphertext":"AQID","protocol":"mls10-openmls-v1"}`)
	if !validCallMetadata(valid) {
		t.Fatal("valid encrypted call envelope was rejected")
	}

	invalid := []json.RawMessage{
		json.RawMessage(`{"version":1,"ciphertext":"AQID","protocol":"mls10-openmls-v1","sdp":"plaintext"}`),
		json.RawMessage(`{"version":1,"ciphertext":"AQID","protocol":"mls10-openmls-v1","ice":{"candidate":"plaintext"}}`),
		json.RawMessage(`{"version":1,"ciphertext":"","protocol":"mls10-openmls-v1"}`),
		json.RawMessage(`{"version":1,"ciphertext":"AQID","protocol":"custom"}`),
		json.RawMessage(`{"version":2,"ciphertext":"AQID","protocol":"mls10-openmls-v1"}`),
	}
	for _, raw := range invalid {
		if validCallMetadata(raw) {
			t.Fatalf("unsafe call metadata accepted: %s", raw)
		}
	}
}
