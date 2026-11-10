package push

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"golang.org/x/crypto/hkdf"
)

func decryptRFC8291(t *testing.T, encrypted []byte, privKey []byte, receiverPubKeyB64, authSecretB64 string) []byte {
	t.Helper()
	if len(encrypted) < 16+4+1+65+16 {
		t.Fatalf("encrypted payload too short: %d bytes", len(encrypted))
	}
	salt := encrypted[:16]
	recordSize := binary.BigEndian.Uint32(encrypted[16:20])
	if recordSize != 4096 {
		t.Fatalf("unexpected record size: %d", recordSize)
	}
	idlen := int(encrypted[20])
	if idlen != 65 {
		t.Fatalf("unexpected idlen: %d", idlen)
	}
	localPubKey := encrypted[21 : 21+65]
	ciphertext := encrypted[21+65:]

	curve := elliptic.P256()
	ephemeralX, ephemeralY := elliptic.Unmarshal(curve, localPubKey)
	if ephemeralX == nil {
		t.Fatal("invalid ephemeral public key")
	}
	sx, _ := curve.ScalarMult(ephemeralX, ephemeralY, privKey)
	sharedSecret := make([]byte, (curve.Params().BitSize+7)/8)
	sx.FillBytes(sharedSecret)

	receiverPubKey, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(receiverPubKeyB64, "="))
	if err != nil {
		t.Fatal(err)
	}
	authSecret, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(authSecretB64, "="))
	if err != nil {
		t.Fatal(err)
	}

	prkInfo := bytes.NewBuffer([]byte("WebPush: info\x00"))
	prkInfo.Write(receiverPubKey)
	prkInfo.Write(localPubKey)

	prkReader := hkdf.New(sha256.New, sharedSecret, authSecret, prkInfo.Bytes())
	ikm := make([]byte, 32)
	if _, err := io.ReadFull(prkReader, ikm); err != nil {
		t.Fatal(err)
	}

	cekReader := hkdf.New(sha256.New, ikm, salt, []byte("Content-Encoding: aes128gcm\x00"))
	cek := make([]byte, 16)
	if _, err := io.ReadFull(cekReader, cek); err != nil {
		t.Fatal(err)
	}

	nonceReader := hkdf.New(sha256.New, ikm, salt, []byte("Content-Encoding: nonce\x00"))
	nonce := make([]byte, 12)
	if _, err := io.ReadFull(nonceReader, nonce); err != nil {
		t.Fatal(err)
	}

	block, err := aes.NewCipher(cek)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}

	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		t.Fatalf("gcm open failed: %v", err)
	}
	// Strip padding (0x00) and trailing delimiter (0x02)
	plaintext = bytes.TrimRight(plaintext, "\x00")
	if len(plaintext) > 0 && plaintext[len(plaintext)-1] == 0x02 {
		plaintext = plaintext[:len(plaintext)-1]
	}
	return plaintext
}

func TestUnifiedPushValidation(t *testing.T) {
	curve := elliptic.P256()
	_, px, py, err := elliptic.GenerateKey(curve, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	validPubKey := base64.RawURLEncoding.EncodeToString(elliptic.Marshal(curve, px, py))
	validAuth := base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef"))

	// Valid with keys
	if err := ValidateUnifiedPushTarget(Notification{
		Provider:   "unifiedpush",
		Endpoint:   "https://push.example.org/up/v1/test",
		PublicKey:  validPubKey,
		AuthSecret: validAuth,
	}); err != nil {
		t.Fatalf("valid target rejected: %v", err)
	}

	// Valid without keys
	if err := ValidateUnifiedPushTarget(Notification{
		Provider: "unifiedpush",
		Endpoint: "https://push.example.org/up/v1/test",
	}); err != nil {
		t.Fatalf("valid keyless target rejected: %v", err)
	}

	// Plain HTTP rejected
	if err := ValidateUnifiedPushTarget(Notification{
		Provider: "unifiedpush",
		Endpoint: "http://push.example.org/up/v1/test",
	}); !errors.Is(err, ErrInvalidTarget) {
		t.Fatalf("plain HTTP accepted: %v", err)
	}

	// Endpoint too long
	if err := ValidateUnifiedPushTarget(Notification{
		Provider: "unifiedpush",
		Endpoint: "https://push.example.org/" + strings.Repeat("a", 1000),
	}); !errors.Is(err, ErrInvalidTarget) {
		t.Fatalf("oversized endpoint accepted: %v", err)
	}

	// Partial keys: pub key only
	if err := ValidateUnifiedPushTarget(Notification{
		Provider:  "unifiedpush",
		Endpoint:  "https://push.example.org/test",
		PublicKey: validPubKey,
	}); !errors.Is(err, ErrInvalidTarget) {
		t.Fatalf("partial key accepted: %v", err)
	}

	// Partial keys: auth secret only
	if err := ValidateUnifiedPushTarget(Notification{
		Provider:   "unifiedpush",
		Endpoint:   "https://push.example.org/test",
		AuthSecret: validAuth,
	}); !errors.Is(err, ErrInvalidTarget) {
		t.Fatalf("partial key accepted: %v", err)
	}

	// Malformed pub key (wrong length)
	if err := ValidateUnifiedPushTarget(Notification{
		Provider:   "unifiedpush",
		Endpoint:   "https://push.example.org/test",
		PublicKey:  base64.RawURLEncoding.EncodeToString([]byte("short")),
		AuthSecret: validAuth,
	}); !errors.Is(err, ErrInvalidTarget) {
		t.Fatalf("malformed pub key accepted: %v", err)
	}

	// Malformed auth secret (wrong length)
	if err := ValidateUnifiedPushTarget(Notification{
		Provider:   "unifiedpush",
		Endpoint:   "https://push.example.org/test",
		PublicKey:  validPubKey,
		AuthSecret: base64.RawURLEncoding.EncodeToString([]byte("short")),
	}); !errors.Is(err, ErrInvalidTarget) {
		t.Fatalf("malformed auth secret accepted: %v", err)
	}
}

func TestUnifiedPushDeliveryRFC8291WithoutVAPID(t *testing.T) {
	provider, err := NewUnifiedPushProvider(UnifiedPushConfig{})
	if err != nil {
		t.Fatal(err)
	}

	curve := elliptic.P256()
	privKey, px, py, err := elliptic.GenerateKey(curve, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pubKeyB64 := base64.RawURLEncoding.EncodeToString(elliptic.Marshal(curve, px, py))
	authB64 := base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef"))

	var recordedReq *http.Request
	var recordedBody []byte
	provider.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		recordedReq = r
		var readErr error
		recordedBody, readErr = io.ReadAll(r.Body)
		if readErr != nil {
			return nil, readErr
		}
		return respond(http.StatusCreated, ""), nil
	})

	target := Notification{
		Provider:   "unifiedpush",
		Endpoint:   "https://push.example.org/endpoint-123",
		PublicKey:  pubKeyB64,
		AuthSecret: authB64,
	}

	if err := provider.SendEncryptedEventAvailable(context.Background(), target); err != nil {
		t.Fatalf("send failed: %v", err)
	}

	if recordedReq.Header.Get("Content-Encoding") != "aes128gcm" {
		t.Fatalf("unexpected Content-Encoding: %s", recordedReq.Header.Get("Content-Encoding"))
	}
	if recordedReq.Header.Get("Content-Type") != "application/octet-stream" {
		t.Fatalf("unexpected Content-Type: %s", recordedReq.Header.Get("Content-Type"))
	}
	if recordedReq.Header.Get("TTL") != "60" {
		t.Fatalf("unexpected TTL: %s", recordedReq.Header.Get("TTL"))
	}
	if recordedReq.Header.Get("Authorization") != "" {
		t.Fatalf("unexpected Authorization header: %s", recordedReq.Header.Get("Authorization"))
	}

	// Decrypt and verify payload
	decrypted := decryptRFC8291(t, recordedBody, privKey, pubKeyB64, authB64)
	var payload map[string]any
	if err := json.Unmarshal(decrypted, &payload); err != nil {
		t.Fatalf("invalid decrypted json: %v (%s)", err, string(decrypted))
	}
	if payload["version"] != "v1" || payload["event"] != "new_encrypted_event_available" {
		t.Fatalf("unexpected payload: %v", payload)
	}
	// Boundary check: no message text or sender name
	for _, forbidden := range []string{"text", "body", "sender", "account", "conversation", "sender_name"} {
		if _, ok := payload[forbidden]; ok {
			t.Fatalf("payload leaked forbidden field: %s", forbidden)
		}
	}
}

func TestUnifiedPushDeliveryWithVAPID(t *testing.T) {
	curve := elliptic.P256()
	vapidPriv, vx, vy, err := elliptic.GenerateKey(curve, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	provider, err := NewUnifiedPushProvider(UnifiedPushConfig{
		VAPID: WebPushConfig{
			Subscriber: "mailto:ops@example.org",
			PublicKey:  base64.RawURLEncoding.EncodeToString(elliptic.Marshal(curve, vx, vy)),
			PrivateKey: base64.RawURLEncoding.EncodeToString(vapidPriv),
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	receiverPriv, rx, ry, err := elliptic.GenerateKey(curve, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	receiverPubB64 := base64.RawURLEncoding.EncodeToString(elliptic.Marshal(curve, rx, ry))
	authB64 := base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef"))

	var authHeader string
	var recordedBody []byte
	provider.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		authHeader = r.Header.Get("Authorization")
		recordedBody, _ = io.ReadAll(r.Body)
		return respond(http.StatusCreated, ""), nil
	})

	target := Notification{
		Provider:   "unifiedpush",
		Endpoint:   "https://push.example.org/endpoint-vapid",
		PublicKey:  receiverPubB64,
		AuthSecret: authB64,
	}

	if err := provider.SendEncryptedEventAvailable(context.Background(), target); err != nil {
		t.Fatalf("send failed: %v", err)
	}

	if !strings.HasPrefix(authHeader, "vapid t=") {
		t.Fatalf("expected VAPID authorization header, got: %s", authHeader)
	}

	decrypted := decryptRFC8291(t, recordedBody, receiverPriv, receiverPubB64, authB64)
	var payload map[string]any
	if err := json.Unmarshal(decrypted, &payload); err != nil {
		t.Fatalf("invalid decrypted json: %v", err)
	}
	if payload["version"] != "v1" || payload["event"] != "new_encrypted_event_available" {
		t.Fatalf("unexpected payload: %v", payload)
	}
}

func TestUnifiedPushDeliveryPlainJSON(t *testing.T) {
	provider, err := NewUnifiedPushProvider(UnifiedPushConfig{})
	if err != nil {
		t.Fatal(err)
	}

	var recordedReq *http.Request
	var recordedBody []byte
	provider.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
		recordedReq = r
		recordedBody, _ = io.ReadAll(r.Body)
		return respond(http.StatusOK, `{"status":"ok"}`), nil
	})

	target := Notification{
		Provider: "unifiedpush",
		Endpoint: "https://push.example.org/endpoint-keyless",
	}

	if err := provider.SendEncryptedEventAvailable(context.Background(), target); err != nil {
		t.Fatalf("send failed: %v", err)
	}

	if recordedReq.Header.Get("Content-Type") != "application/json" {
		t.Fatalf("unexpected Content-Type: %s", recordedReq.Header.Get("Content-Type"))
	}

	var payload map[string]any
	if err := json.Unmarshal(recordedBody, &payload); err != nil {
		t.Fatalf("invalid json body: %v", err)
	}
	if payload["version"] != "v1" || payload["event"] != "new_encrypted_event_available" {
		t.Fatalf("unexpected payload: %v", payload)
	}
}

func TestUnifiedPushSubscriptionGone(t *testing.T) {
	provider, err := NewUnifiedPushProvider(UnifiedPushConfig{})
	if err != nil {
		t.Fatal(err)
	}

	for _, code := range []int{http.StatusGone, http.StatusNotFound} {
		provider.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
			return respond(code, ""), nil
		})
		target := Notification{
			Provider: "unifiedpush",
			Endpoint: "https://push.example.org/endpoint-dead",
		}
		err := provider.SendEncryptedEventAvailable(context.Background(), target)
		if !errors.Is(err, ErrSubscriptionGone) {
			t.Fatalf("expected ErrSubscriptionGone for code %d, got: %v", code, err)
		}
	}
}

func TestUnifiedPushSSRFProtection(t *testing.T) {
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	provider, err := NewUnifiedPushProvider(UnifiedPushConfig{})
	if err != nil {
		t.Fatal(err)
	}

	target := Notification{
		Provider: "unifiedpush",
		Endpoint: server.URL + "/push",
	}
	if err := provider.SendEncryptedEventAvailable(context.Background(), target); err == nil {
		t.Fatal("a loopback push endpoint was contacted")
	}
	if hits.Load() != 0 {
		t.Fatal("the request reached a private address")
	}
}
