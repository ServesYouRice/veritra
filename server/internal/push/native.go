package push

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
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
	token, err := p.token(ctx)
	if err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]any{"message": map[string]any{
		"token": notification.Endpoint, "data": GenericPayload(),
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
	if response.StatusCode == http.StatusNotFound || response.StatusCode == http.StatusGone || bytes.Contains(responseBody, []byte("UNREGISTERED")) {
		return ErrSubscriptionGone
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("FCM returned status %d", response.StatusCode)
	}
	return nil
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
	key, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse APNs private key: %w", err)
	}
	return &APNsProvider{config: config, key: key, client: nativeHTTPClient()}, nil
}

func (p *APNsProvider) SendEncryptedEventAvailable(ctx context.Context, notification Notification) error {
	if notification.Provider != "apns" || !validAPNsToken(notification.Endpoint) {
		return ErrInvalidTarget
	}
	jwt, err := p.token()
	if err != nil {
		return err
	}
	host := "https://api.push.apple.com"
	if p.config.Sandbox {
		host = "https://api.sandbox.push.apple.com"
	}
	body, _ := json.Marshal(map[string]any{"aps": map[string]any{"content-available": 1},
		"version": "v1", "event": "new_encrypted_event_available"})
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
	if response.StatusCode == http.StatusGone || bytes.Contains(responseBody, []byte("BadDeviceToken")) || bytes.Contains(responseBody, []byte("Unregistered")) {
		return ErrSubscriptionGone
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("APNs returned status %d", response.StatusCode)
	}
	return nil
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
	signature := make([]byte, 64)
	fillInt(signature[:32], r)
	fillInt(signature[32:], s)
	return value + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}
func fillInt(target []byte, value *big.Int) {
	bytes := value.Bytes()
	copy(target[len(target)-len(bytes):], bytes)
}
