package push

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

var (
	ErrNoProvider       = errors.New("push provider is not configured")
	ErrInvalidTarget    = errors.New("invalid web push target")
	ErrSubscriptionGone = errors.New("push subscription is no longer valid")
)

type Notification struct {
	Endpoint   string
	PublicKey  string
	AuthSecret string
}

type Provider interface {
	SendEncryptedEventAvailable(ctx context.Context, notification Notification) error
}

type DisabledProvider struct{}

func (DisabledProvider) SendEncryptedEventAvailable(context.Context, Notification) error {
	return ErrNoProvider
}

type WebPushConfig struct {
	Subscriber string
	PublicKey  string
	PrivateKey string
}

type WebPushProvider struct {
	config WebPushConfig
	client *http.Client
	slots  chan struct{}
}

func NewWebPushProvider(config WebPushConfig) (*WebPushProvider, error) {
	if strings.TrimSpace(config.Subscriber) == "" || strings.TrimSpace(config.PublicKey) == "" || strings.TrimSpace(config.PrivateKey) == "" {
		return nil, ErrNoProvider
	}
	if parsed, err := url.Parse(config.Subscriber); err != nil || (parsed.Scheme != "mailto" && parsed.Scheme != "https") {
		return nil, errors.New("VAPID subscriber must be a mailto or HTTPS URI")
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
	return &WebPushProvider{
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

func (p *WebPushProvider) SendEncryptedEventAvailable(ctx context.Context, notification Notification) error {
	if err := ValidateWebPushTarget(notification); err != nil {
		return err
	}
	select {
	case p.slots <- struct{}{}:
		defer func() { <-p.slots }()
	case <-ctx.Done():
		return ctx.Err()
	}
	payload, err := json.Marshal(GenericPayload())
	if err != nil {
		return err
	}
	response, err := webpush.SendNotificationWithContext(ctx, payload, &webpush.Subscription{
		Endpoint: notification.Endpoint,
		Keys: webpush.Keys{
			P256dh: notification.PublicKey,
			Auth:   notification.AuthSecret,
		},
	}, &webpush.Options{
		HTTPClient:      p.client,
		Subscriber:      p.config.Subscriber,
		VAPIDPublicKey:  p.config.PublicKey,
		VAPIDPrivateKey: p.config.PrivateKey,
		TTL:             60,
		Topic:           "veritra-sync",
		Urgency:         webpush.UrgencyNormal,
	})
	if err != nil {
		return err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	if response.StatusCode == http.StatusGone || response.StatusCode == http.StatusNotFound {
		return ErrSubscriptionGone
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("web push endpoint returned status %d", response.StatusCode)
	}
	return nil
}

func ValidateWebPushTarget(notification Notification) error {
	endpoint, err := url.Parse(strings.TrimSpace(notification.Endpoint))
	if err != nil || endpoint.Scheme != "https" || endpoint.Host == "" || endpoint.User != nil || endpoint.Fragment != "" || len(endpoint.String()) > 1000 {
		return ErrInvalidTarget
	}
	publicKey, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(notification.PublicKey, "="))
	if err != nil || len(publicKey) != 65 || publicKey[0] != 4 {
		return ErrInvalidTarget
	}
	authSecret, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(notification.AuthSecret, "="))
	if err != nil || len(authSecret) != 16 {
		return ErrInvalidTarget
	}
	return nil
}

func publicOnlyDialer(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	addresses, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil {
		return nil, err
	}
	dialer := net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}
	for _, candidate := range addresses {
		ip := candidate.IP
		if ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() || ip.IsMulticast() {
			continue
		}
		connection, err := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
		if err == nil {
			return connection, nil
		}
	}
	return nil, errors.New("push endpoint resolved only to forbidden addresses")
}

func GenericPayload() map[string]string {
	return map[string]string{"version": "v1", "event": "new_encrypted_event_available"}
}
