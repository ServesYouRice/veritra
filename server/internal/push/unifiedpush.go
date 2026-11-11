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
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
	"golang.org/x/crypto/hkdf"
)

type UnifiedPushConfig struct {
	VAPID WebPushConfig
}

type UnifiedPushProvider struct {
	config UnifiedPushConfig
	client *http.Client
	slots  chan struct{}
}

func NewUnifiedPushProvider(config UnifiedPushConfig) (*UnifiedPushProvider, error) {
	if config.VAPID.Subscriber != "" {
		if parsed, err := url.Parse(config.VAPID.Subscriber); err != nil || (parsed.Scheme != "mailto" && parsed.Scheme != "https") {
			return nil, errors.New("VAPID subscriber must be a mailto or HTTPS URI")
		}
		config.VAPID.Subscriber = librarySubscriber(config.VAPID.Subscriber)
	}
	transport := &http.Transport{
		Proxy:                 nil,
		DialContext:           publicOnlyDialer,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          32,
		MaxIdleConnsPerHost:   2,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: 5 * time.Second,
	}
	return &UnifiedPushProvider{
		config: config,
		client: &http.Client{
			Transport: transport,
			Timeout:   10 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return errors.New("push endpoint redirects are forbidden")
			},
		},
		slots: make(chan struct{}, 32),
	}, nil
}

func ValidateUnifiedPushTarget(notification Notification) error {
	endpoint, err := url.Parse(strings.TrimSpace(notification.Endpoint))
	if err != nil || endpoint.Scheme != "https" || endpoint.Host == "" || endpoint.User != nil || endpoint.Fragment != "" || len(endpoint.String()) > 1000 {
		return ErrInvalidTarget
	}
	// Unencrypted POST endpoint: both keys must be empty.
	if notification.PublicKey == "" && notification.AuthSecret == "" {
		return nil
	}
	// Encrypted RFC 8291 endpoint: both keys must be present and valid.
	publicKey, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(notification.PublicKey, "="))
	if err != nil || len(publicKey) != 65 || publicKey[0] != 4 {
		return ErrInvalidTarget
	}
	if x, _ := elliptic.Unmarshal(elliptic.P256(), publicKey); x == nil {
		return ErrInvalidTarget
	}
	authSecret, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(notification.AuthSecret, "="))
	if err != nil || len(authSecret) != 16 {
		return ErrInvalidTarget
	}
	return nil
}

func (p *UnifiedPushProvider) SendEncryptedEventAvailable(ctx context.Context, notification Notification) error {
	if notification.Provider != "unifiedpush" {
		return ErrNoProvider
	}
	if err := ValidateUnifiedPushTarget(notification); err != nil {
		return err
	}
	data, err := GenericPayloadForMode(notification.NotificationMode)
	if err != nil {
		return err
	}
	select {
	case p.slots <- struct{}{}:
		defer func() { <-p.slots }()
	case <-ctx.Done():
		return ctx.Err()
	}
	payload, err := json.Marshal(data)
	if err != nil {
		return err
	}

	hasKeys := notification.PublicKey != "" && notification.AuthSecret != ""
	hasVAPID := strings.TrimSpace(p.config.VAPID.Subscriber) != "" &&
		strings.TrimSpace(p.config.VAPID.PublicKey) != "" &&
		strings.TrimSpace(p.config.VAPID.PrivateKey) != ""

	if hasKeys && hasVAPID {
		response, err := webpush.SendNotificationWithContext(ctx, payload, &webpush.Subscription{
			Endpoint: notification.Endpoint,
			Keys: webpush.Keys{
				P256dh: notification.PublicKey,
				Auth:   notification.AuthSecret,
			},
		}, &webpush.Options{
			HTTPClient:      p.client,
			Subscriber:      p.config.VAPID.Subscriber,
			VAPIDPublicKey:  p.config.VAPID.PublicKey,
			VAPIDPrivateKey: p.config.VAPID.PrivateKey,
			TTL:             60,
			Topic:           "veritra-sync",
			Urgency:         webpush.UrgencyNormal,
		})
		if err != nil {
			return sanitizeSendError(err)
		}
		defer response.Body.Close()
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		if response.StatusCode == http.StatusGone || response.StatusCode == http.StatusNotFound {
			return ErrSubscriptionGone
		}
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			return fmt.Errorf("unifiedpush endpoint returned status %d", response.StatusCode)
		}
		return nil
	}

	var req *http.Request
	if hasKeys {
		encryptedBody, err := encryptRFC8291(payload, notification.PublicKey, notification.AuthSecret)
		if err != nil {
			return err
		}
		req, err = http.NewRequestWithContext(ctx, http.MethodPost, notification.Endpoint, bytes.NewReader(encryptedBody))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Encoding", "aes128gcm")
		req.Header.Set("Content-Type", "application/octet-stream")
	} else {
		req, err = http.NewRequestWithContext(ctx, http.MethodPost, notification.Endpoint, bytes.NewReader(payload))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")
	}

	req.Header.Set("TTL", "60")
	req.Header.Set("Topic", "veritra-sync")
	req.Header.Set("Urgency", "normal")

	response, err := p.client.Do(req)
	if err != nil {
		return sanitizeSendError(err)
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	if response.StatusCode == http.StatusGone || response.StatusCode == http.StatusNotFound {
		return ErrSubscriptionGone
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("unifiedpush endpoint returned status %d", response.StatusCode)
	}
	return nil
}

func encryptRFC8291(payload []byte, peerPublicKeyB64, authSecretB64 string) ([]byte, error) {
	dh, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(peerPublicKeyB64, "="))
	if err != nil {
		return nil, err
	}
	authSecret, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(authSecretB64, "="))
	if err != nil {
		return nil, err
	}

	curve := elliptic.P256()
	localPrivateKey, x, y, err := elliptic.GenerateKey(curve, rand.Reader)
	if err != nil {
		return nil, err
	}
	localPublicKey := elliptic.Marshal(curve, x, y)

	sharedX, sharedY := elliptic.Unmarshal(curve, dh)
	if sharedX == nil {
		return nil, errors.New("invalid peer public key point")
	}
	sx, _ := curve.ScalarMult(sharedX, sharedY, localPrivateKey)
	sharedSecret := make([]byte, (curve.Params().BitSize+7)/8)
	sx.FillBytes(sharedSecret)

	prkInfo := bytes.NewBuffer([]byte("WebPush: info\x00"))
	prkInfo.Write(dh)
	prkInfo.Write(localPublicKey)

	prkReader := hkdf.New(sha256.New, sharedSecret, authSecret, prkInfo.Bytes())
	ikm := make([]byte, 32)
	if _, err := io.ReadFull(prkReader, ikm); err != nil {
		return nil, err
	}

	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}

	cekReader := hkdf.New(sha256.New, ikm, salt, []byte("Content-Encoding: aes128gcm\x00"))
	cek := make([]byte, 16)
	if _, err := io.ReadFull(cekReader, cek); err != nil {
		return nil, err
	}

	nonceReader := hkdf.New(sha256.New, ikm, salt, []byte("Content-Encoding: nonce\x00"))
	nonce := make([]byte, 12)
	if _, err := io.ReadFull(nonceReader, nonce); err != nil {
		return nil, err
	}

	block, err := aes.NewCipher(cek)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	// Delimiter 0x02 for the last record
	record := append(append(make([]byte, 0, len(payload)+1), payload...), 0x02)
	ciphertext := gcm.Seal(nil, nonce, record, nil)

	const recordSize uint32 = 4096
	recordBuf := bytes.NewBuffer(salt)
	rs := make([]byte, 4)
	binary.BigEndian.PutUint32(rs, recordSize)
	recordBuf.Write(rs)
	recordBuf.WriteByte(byte(len(localPublicKey)))
	recordBuf.Write(localPublicKey)
	recordBuf.Write(ciphertext)

	return recordBuf.Bytes(), nil
}

// sanitizeSendError drops the request URL that net/http embeds in its errors:
// the endpoint path is a bearer secret and must not reach logs.
func sanitizeSendError(err error) error {
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return fmt.Errorf("unifiedpush request failed: %w", urlErr.Err)
	}
	return err
}
