package httpapi

import (
	"encoding/json"
	"testing"
)

// C-59172da4f1fb: backup key derivation metadata is read from its exact
// lowercase keys and stored re-encoded, so the counter validated is the
// counter storage reads back with json_extract('$.state_counter').
func TestBackupCryptoMetadataRequiresExactKeys(t *testing.T) {
	for _, raw := range []string{
		`{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"STATE_COUNTER":6}`,
		`{"Version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":6}`,
		`{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":0}`,
		`{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576}`,
		`{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":6,"extra":1}`,
	} {
		if _, ok := canonicalBackupCryptoMetadata(json.RawMessage(raw)); ok {
			t.Fatalf("accepted %s", raw)
		}
	}
	// A repeated key is re-encoded once, with the value that was validated.
	canonical, ok := canonicalBackupCryptoMetadata(json.RawMessage(
		`{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":1,"state_counter":6}`))
	if !ok {
		t.Fatal("refused a valid document")
	}
	const want = `{"version":1,"algorithm":"AES-256-GCM-chunked","chunk_size":1048576,"state_counter":6}`
	if string(canonical) != want {
		t.Fatalf("canonical = %s, want %s", canonical, want)
	}
}
