package push

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"golang.org/x/crypto/hkdf"
	"private-messenger/server/internal/domain"
)

func assertWakePayload(t *testing.T, got map[string]any, mode string) {
	t.Helper()
	want := map[string]any{"version": "v1", "event": "new_encrypted_event_available"}
	if mode == domain.PushNotificationLocalDecrypt {
		want["version"] = "v2"
		want["presentation"] = "none"
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("non-generic or wrong presentation payload: %v", got)
	}
}

func TestNotificationModeFCMAndAPNsContractsRemainSilent(t *testing.T) {
	for _, mode := range []string{domain.PushNotificationLegacy, domain.PushNotificationLocalDecrypt} {
		t.Run(mode, func(t *testing.T) {
			var message map[string]any
			fcm := newTestFCM(t, func(r *http.Request) (*http.Response, error) {
				if r.URL.Host == "oauth2.googleapis.com" {
					return respond(200, `{"access_token":"test","expires_in":3600}`), nil
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Fatal(err)
				}
				message = body["message"].(map[string]any)
				return respond(200, `{}`), nil
			})
			if err := fcm.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "fcm", Endpoint: testFCMToken, NotificationMode: mode}); err != nil {
				t.Fatal(err)
			}
			assertWakePayload(t, message["data"].(map[string]any), mode)
			if _, ok := message["notification"]; ok {
				t.Fatal("FCM requested automatic alert")
			}
			if message["android"].(map[string]any)["priority"] != "normal" {
				t.Fatal("silent wake promoted priority")
			}
			key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			apns, err := NewAPNsProvider(APNsConfig{TeamID: "T", KeyID: "K", BundleID: "org.veritra", PrivateKey: pkcs8PEM(t, key)})
			if err != nil {
				t.Fatal(err)
			}
			var got map[string]any
			apns.client = &http.Client{Transport: roundTrip(func(r *http.Request) (*http.Response, error) {
				if r.Header.Get("apns-push-type") != "background" || r.Header.Get("apns-priority") != "5" {
					t.Fatal("APNs alert/priority changed")
				}
				if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
					t.Fatal(err)
				}
				return respond(200, `{}`), nil
			})}
			if err := apns.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "apns", Endpoint: strings.Repeat("a", 64), NotificationMode: mode}); err != nil {
				t.Fatal(err)
			}
			aps := got["aps"].(map[string]any)
			if len(aps) != 1 || aps["content-available"] != float64(1) {
				t.Fatalf("APNs alert fields: %v", aps)
			}
			delete(got, "aps")
			assertWakePayload(t, got, mode)
		})
	}
	if _, err := GenericPayloadForMode("future_unknown_mode"); err == nil {
		t.Fatal("unknown mode produced legacy alert path")
	}
}

func TestNotificationModeEncryptedWebPushPayloadContract(t *testing.T) {
	receiver, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	vapid, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	auth := []byte("0123456789abcdef")
	provider, err := NewWebPushProvider(WebPushConfig{Subscriber: "mailto:ops@example.test", PublicKey: base64.RawURLEncoding.EncodeToString(vapid.PublicKey().Bytes()), PrivateKey: base64.RawURLEncoding.EncodeToString(vapid.Bytes())})
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{domain.PushNotificationLegacy, domain.PushNotificationLocalDecrypt} {
		var wire []byte
		provider.client.Transport = roundTrip(func(r *http.Request) (*http.Response, error) {
			if r.Header.Get("Content-Encoding") != "aes128gcm" {
				t.Fatal("unencrypted web push")
			}
			var err error
			wire, err = io.ReadAll(r.Body)
			if err != nil {
				t.Fatal(err)
			}
			return respond(201, ""), nil
		})
		if err := provider.SendEncryptedEventAvailable(context.Background(), Notification{Provider: "webpush", Endpoint: "https://push.example.test/opaque", PublicKey: base64.RawURLEncoding.EncodeToString(receiver.PublicKey().Bytes()), AuthSecret: base64.RawURLEncoding.EncodeToString(auth), NotificationMode: mode}); err != nil {
			t.Fatal(err)
		}
		if len(wire) < 21+65+16 || wire[20] != 65 {
			t.Fatal("invalid encrypted record")
		}
		sender, err := ecdh.P256().NewPublicKey(wire[21:86])
		if err != nil {
			t.Fatal(err)
		}
		shared, err := receiver.ECDH(sender)
		if err != nil {
			t.Fatal(err)
		}
		derive := func(secret, salt, info []byte, n int) []byte {
			t.Helper()
			out := make([]byte, n)
			if _, err := io.ReadFull(hkdf.New(sha256.New, secret, salt, info), out); err != nil {
				t.Fatal(err)
			}
			return out
		}
		info := append([]byte("WebPush: info\x00"), receiver.PublicKey().Bytes()...)
		info = append(info, sender.Bytes()...)
		ikm := derive(shared, auth, info, 32)
		key := derive(ikm, wire[:16], []byte("Content-Encoding: aes128gcm\x00"), 16)
		nonce := derive(ikm, wire[:16], []byte("Content-Encoding: nonce\x00"), 12)
		block, err := aes.NewCipher(key)
		if err != nil {
			t.Fatal(err)
		}
		gcm, err := cipher.NewGCM(block)
		if err != nil {
			t.Fatal(err)
		}
		plain, err := gcm.Open(nil, nonce, wire[86:], nil)
		if err != nil {
			t.Fatal(err)
		}
		plain = bytes.TrimRight(plain, "\x00")
		if len(plain) == 0 || plain[len(plain)-1] != 2 {
			t.Fatal("invalid final record padding")
		}
		var got map[string]any
		if err := json.Unmarshal(plain[:len(plain)-1], &got); err != nil {
			t.Fatal(err)
		}
		assertWakePayload(t, got, mode)
	}
}
