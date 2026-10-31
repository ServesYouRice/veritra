package storage

import "encoding/base64"

// encodeBase64ForTest is how a []byte field appears inside a JSON payload.
func encodeBase64ForTest(text string) string {
	return base64.StdEncoding.EncodeToString([]byte(text))
}
