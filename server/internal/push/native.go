package push

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type FCMConfig struct {
	ProjectID, ClientEmail, PrivateKey string
}

type FCMProvider struct {
	config      FCMConfig
	key         *rsa.PrivateKey
	client      *http.Client
	mu          sync.Mutex
	accessToken string
	expiresAt   time.Time
}

func NewFCMProvider(config FCMConfig) (*FCMProvider, error) {
	if strings.TrimSpace(config.ProjectID) == "" || strings.TrimSpace(config.ClientEmail) == "" || strings.TrimSpace(config.PrivateKey) == "" {
		return nil, ErrNoProvider
	}
	block, _ := pem.Decode([]byte(strings.ReplaceAll(config.PrivateKey, `\n`, "\n")))
	if block == nil {
		return nil, errors.New("invalid FCM private key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse FCM private key: %w", err)
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("FCM private key is not RSA")
	}
	return &FCMProvider{config: config, key: key, client: nativeHTTPClient()}, nil
}

func (p *FCMProvider) SendEncryptedEventAvailable(ctx context.Context, notification Notification) error {
	if notification.Provider != "fcm" || !validFCMToken(notification.Endpoint) {
		return ErrInvalidTarget
	}
	payload, err := GenericPayloadForMode(notification.NotificationMode)
	if err != nil {
		return err
	}
	token, err := p.token(ctx)
	if err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]any{"message": map[string]any{
		"token": notification.Endpoint, "data": payload,
		"android": map[string]any{"priority": "normal", "ttl": "60s"},
	}})
	endpoint := "https://fcm.googleapis.com/v1/projects/" + url.PathEscape(p.config.ProjectID) + "/messages:send"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	response, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 16<<10))
	// The device token is retired only when FCM says so: HTTP 410, or an
	// UNREGISTERED errorCode in error.details. A bare 404 can come from the
	// project or the request rather than the token, so it stays an ordinary
	// error; so does a body that is truncated or not JSON (retry, don't delete).
	if response.StatusCode == http.StatusGone || (response.StatusCode >= 400 && fcmUnregistered(responseBody)) {
		return ErrSubscriptionGone
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("FCM returned status %d", response.StatusCode)
	}
	return nil
}

// fcmUnregistered reports whether an FCM v1 error body carries the
// UNREGISTERED errorCode in error.details.
func fcmUnregistered(body []byte) bool {
	var parsed struct {
		Error struct {
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &parsed) != nil {
		return false
	}
	for _, detail := range parsed.Error.Details {
		if detail.ErrorCode == "UNREGISTERED" {
			return true
		}
	}
	return false
}

func (p *FCMProvider) token(ctx context.Context) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.accessToken != "" && time.Until(p.expiresAt) > 2*time.Minute {
		return p.accessToken, nil
	}
	now := time.Now().UTC()
	claims := map[string]any{"iss": p.config.ClientEmail,
		"scope": "https://www.googleapis.com/auth/firebase.messaging",
		"aud":   "https://oauth2.googleapis.com/token", "iat": now.Unix(), "exp": now.Add(time.Hour).Unix()}
	assertion, err := signRSAJWT(p.key, map[string]any{"alg": "RS256", "typ": "JWT"}, claims)
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://oauth2.googleapis.com/token", strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := p.client.Do(req)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	limited := io.LimitReader(response.Body, 16<<10)
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, limited)
		return "", fmt.Errorf("FCM OAuth returned status %d", response.StatusCode)
	}
	var value struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if json.NewDecoder(limited).Decode(&value) != nil || value.AccessToken == "" || value.ExpiresIn <= 0 {
		return "", errors.New("invalid FCM OAuth response")
	}
	p.accessToken, p.expiresAt = value.AccessToken, now.Add(time.Duration(value.ExpiresIn)*time.Second)
	return p.accessToken, nil
}

type APNsConfig struct {
	TeamID, KeyID, BundleID, PrivateKey string
	Sandbox                             bool
}
type APNsProvider struct {
	config APNsConfig
	key    *ecdsa.PrivateKey
	client *http.Client
	mu     sync.Mutex
	jwt    string
	jwtAt  time.Time
}

func NewAPNsProvider(config APNsConfig) (*APNsProvider, error) {
	if strings.TrimSpace(config.TeamID) == "" || strings.TrimSpace(config.KeyID) == "" || strings.TrimSpace(config.BundleID) == "" || strings.TrimSpace(config.PrivateKey) == "" {
		return nil, ErrNoProvider
	}
	block, _ := pem.Decode([]byte(strings.ReplaceAll(config.PrivateKey, `\n`, "\n")))
	if block == nil {
		return nil, errors.New("invalid APNs private key")
	}
	// Apple issues .p8 keys in PKCS #8; SEC 1 EC keys are accepted too.
	var key *ecdsa.PrivateKey
	if parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		ecKey, ok := parsed.(*ecdsa.PrivateKey)
		if !ok {
			return nil, errors.New("APNs private key is not an EC key")
		}
		key = ecKey
	} else if ecKey, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
		key = ecKey
	} else {
		return nil, fmt.Errorf("parse APNs private key: %w", err)
	}
	// The JWT is signed with ES256, which Apple defines on P-256 only.
	if key.Curve != elliptic.P256() {
		return nil, errors.New("APNs private key must use the P-256 curve")
	}
	return &APNsProvider{config: config, key: key, client: nativeHTTPClient()}, nil
}

func (p *APNsProvider) SendEncryptedEventAvailable(ctx context.Context, notification Notification) error {
	if notification.Provider != "apns" || !validAPNsToken(notification.Endpoint) {
		return ErrInvalidTarget
	}
	payload, err := GenericPayloadForMode(notification.NotificationMode)
	if err != nil {
		return err
	}
	jwt, err := p.token()
	if err != nil {
		return err
	}
	host := "https://api.push.apple.com"
	if p.config.Sandbox {
		host = "https://api.sandbox.push.apple.com"
	}
	bodyFields := map[string]any{"aps": map[string]any{"content-available": 1}}
	for key, value := range payload {
		bodyFields[key] = value
	}
	body, _ := json.Marshal(bodyFields)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+notification.Endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", p.config.BundleID)
	req.Header.Set("apns-push-type", "background")
	req.Header.Set("apns-priority", "5")
	req.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(time.Minute).Unix()))
	req.Header.Set("apns-collapse-id", "veritra-sync")
	response, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
	// Apple's answer is {"reason": "..."}; only the exact field counts.
	// HTTP 410 and reason Unregistered mean the token is no longer active.
	// BadDeviceToken is deliberately not gone: Apple also answers it for a
	// valid token sent to the wrong (sandbox or production) environment, and
	// the process uses one environment for every subscription.
	var answer struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(responseBody, &answer)
	if response.StatusCode == http.StatusGone || answer.Reason == "Unregistered" {
		return ErrSubscriptionGone
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		if apnsReasonToken(answer.Reason) {
			return fmt.Errorf("APNs returned status %d (%s)", response.StatusCode, answer.Reason)
		}
		return fmt.Errorf("APNs returned status %d", response.StatusCode)
	}
	return nil
}

// apnsReasonToken reports whether reason looks like one of Apple's fixed
// reason codes (short, letters only), so it is safe to put in an error.
func apnsReasonToken(reason string) bool {
	if reason == "" || len(reason) > 64 {
		return false
	}
	for _, char := range reason {
		if (char < 'a' || char > 'z') && (char < 'A' || char > 'Z') {
			return false
		}
	}
	return true
}

func (p *APNsProvider) token() (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.jwt != "" && time.Since(p.jwtAt) < 45*time.Minute {
		return p.jwt, nil
	}
	now := time.Now().UTC()
	value, err := signECDSAJWT(p.key, map[string]any{"alg": "ES256", "kid": p.config.KeyID}, map[string]any{"iss": p.config.TeamID, "iat": now.Unix()})
	if err == nil {
		p.jwt, p.jwtAt = value, now
	}
	return value, err
}

func nativeHTTPClient() *http.Client {
	return &http.Client{Transport: &http.Transport{Proxy: nil, ForceAttemptHTTP2: true, TLSHandshakeTimeout: 5 * time.Second, ResponseHeaderTimeout: 5 * time.Second}, Timeout: 10 * time.Second}
}
func validFCMToken(value string) bool {
	value = strings.TrimSpace(value)
	return len(value) >= 32 && len(value) <= 4096 && !strings.ContainsAny(value, " \r\n\t")
}
func validAPNsToken(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, char := range value {
		if !strings.ContainsRune("0123456789abcdefABCDEF", char) {
			return false
		}
	}
	return true
}
func ValidateNativeTarget(provider, token string) error {
	if (provider == "fcm" && validFCMToken(token)) || (provider == "apns" && validAPNsToken(token)) {
		return nil
	}
	return ErrInvalidTarget
}

func jwtParts(header, claims map[string]any) (string, error) {
	h, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	c, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(c), nil
}
func signRSAJWT(key *rsa.PrivateKey, header, claims map[string]any) (string, error) {
	value, err := jwtParts(header, claims)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256([]byte(value))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, hash[:])
	if err != nil {
		return "", err
	}
	return value + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}
func signECDSAJWT(key *ecdsa.PrivateKey, header, claims map[string]any) (string, error) {
	value, err := jwtParts(header, claims)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256([]byte(value))
	r, s, err := ecdsa.Sign(rand.Reader, key, hash[:])
	if err != nil {
		return "", err
	}
	// ES256 is a fixed 64-byte signature: r and s as 32-byte big-endian
	// halves. A key on a larger curve cannot produce one.
	signature := make([]byte, 64)
	if err := fillInt(signature[:32], r); err != nil {
		return "", err
	}
	if err := fillInt(signature[32:], s); err != nil {
		return "", err
	}
	return value + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

// fillInt writes value big-endian, left-padded, into target. It reports an
// error instead of slicing out of range when value does not fit.
func fillInt(target []byte, value *big.Int) error {
	bytes := value.Bytes()
	if len(bytes) > len(target) {
		return errors.New("ECDSA signature component does not fit an ES256 signature; the key must use P-256")
	}
	copy(target[len(target)-len(bytes):], bytes)
	return nil
}
