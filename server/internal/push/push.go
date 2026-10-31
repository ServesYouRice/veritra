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
	"net/netip"
	"net/url"
	"strings"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
	"private-messenger/server/internal/domain"
)

var (
	ErrNoProvider       = errors.New("push provider is not configured")
	ErrInvalidTarget    = errors.New("invalid web push target")
	ErrSubscriptionGone = errors.New("push subscription is no longer valid")
)

type Notification struct {
	NotificationMode string
	Provider         string
	Endpoint         string
	PublicKey        string
	AuthSecret       string
}

type Router struct{ providers map[string]Provider }

func NewRouter(providers map[string]Provider) Provider {
	copy := make(map[string]Provider, len(providers))
	for name, provider := range providers {
		if provider != nil {
			copy[name] = provider
		}
	}
	if len(copy) == 0 {
		return DisabledProvider{}
	}
	return &Router{providers: copy}
}

func (r *Router) SendEncryptedEventAvailable(ctx context.Context, notification Notification) error {
	provider := r.providers[notification.Provider]
	if provider == nil {
		return ErrNoProvider
	}
	return provider.SendEncryptedEventAvailable(ctx, notification)
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
	config.Subscriber = librarySubscriber(config.Subscriber)
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

// librarySubscriber adapts the configured VAPID contact URI to webpush-go,
// which prefixes "mailto:" to anything not starting with "https:". Without
// this the JWT "sub" claim would read "mailto:mailto:...".
func librarySubscriber(configured string) string {
	configured = strings.TrimSpace(configured)
	scheme, rest, _ := strings.Cut(configured, ":")
	switch strings.ToLower(scheme) {
	case "mailto":
		return rest
	case "https":
		return "https:" + rest
	}
	return configured
}

func (p *WebPushProvider) SendEncryptedEventAvailable(ctx context.Context, notification Notification) error {
	if notification.Provider != "webpush" {
		return ErrNoProvider
	}
	if err := ValidateWebPushTarget(notification); err != nil {
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

// nonGlobalPushPrefixes are IANA special-purpose ranges that Go's IsPrivate,
// IsLoopback and link-local predicates do not cover but that are not
// globally reachable: this-network, shared address space (RFC 6598, used by
// carrier NAT and overlay networks), IETF protocol assignments,
// documentation, benchmarking, reserved and broadcast space, and the IPv6
// translation and tunnelling ranges. NAT64 (64:ff9b::/96) and 6to4
// (2002::/16) are blocked outright rather than decoded for the IPv4 address
// they embed, which is simpler and cannot be fooled by the decoding.
var nonGlobalPushPrefixes = func() []netip.Prefix {
	var prefixes []netip.Prefix
	for _, cidr := range []string{
		"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24",
		"198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4",
		"255.255.255.255/32",
		"64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "2001::/32",
		"2001:db8::/32", "2002::/16",
	} {
		prefixes = append(prefixes, netip.MustParsePrefix(cidr))
	}
	return prefixes
}()

// forbiddenPushAddress reports whether a push endpoint must not be dialed at
// addr: anything private, loopback, link-local, unspecified, multicast or in a
// non-global special-purpose range. IPv4-mapped IPv6 forms are judged as the
// IPv4 address they carry.
func forbiddenPushAddress(addr netip.Addr) bool {
	addr = addr.Unmap().WithZone("")
	if addr.IsPrivate() || addr.IsLoopback() || addr.IsLinkLocalUnicast() || addr.IsLinkLocalMulticast() || addr.IsUnspecified() || addr.IsMulticast() {
		return true
	}
	for _, prefix := range nonGlobalPushPrefixes {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
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
		addr, ok := netip.AddrFromSlice(ip)
		if !ok || forbiddenPushAddress(addr) {
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

// An omitted in-memory mode is legacy for existing provider callers. Unknown
// nonempty modes fail closed rather than accidentally presenting a notice.
func GenericPayloadForMode(mode string) (map[string]string, error) {
	if mode == "" || mode == domain.PushNotificationLegacy {
		return GenericPayload(), nil
	}
	if mode == domain.PushNotificationLocalDecrypt {
		return map[string]string{"version": "v2", "event": "new_encrypted_event_available", "presentation": "none"}, nil
	}
	return nil, ErrInvalidTarget
}
