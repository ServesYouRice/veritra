package httpapi

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"

	"private-messenger/server/internal/realtime"
)

func TestClientIdentityResolverProxyTopologies(t *testing.T) {
	_, proxyNetwork, err := net.ParseCIDR("172.28.250.0/24")
	if err != nil {
		t.Fatalf("parse proxy network: %v", err)
	}
	resolver := NewClientIdentityResolver([]*net.IPNet{proxyNetwork})
	tests := []struct {
		name       string
		remoteAddr string
		xff        string
		realIP     string
		want       string
	}{
		{name: "untrusted peer cannot spoof forwarding", remoteAddr: "198.51.100.10:443", xff: "127.0.0.1", want: "198.51.100.10"},
		{name: "trusted proxy preserves distinct client", remoteAddr: "172.28.250.2:8080", xff: "203.0.113.8", want: "203.0.113.8"},
		{name: "rightmost untrusted hop defeats forged left entry", remoteAddr: "172.28.250.2:8080", xff: "127.0.0.1, 203.0.113.9, 172.28.250.3", want: "203.0.113.9"},
		{name: "trusted proxy real ip fallback", remoteAddr: "172.28.250.2:8080", realIP: "203.0.113.10", want: "203.0.113.10"},
		{name: "malformed real ip falls back to peer", remoteAddr: "172.28.250.2:8080", realIP: "not-an-ip", want: "172.28.250.2"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest("GET", "https://messenger.example.test/api/v1/health", nil)
			request.RemoteAddr = test.remoteAddr
			request.Header.Set("X-Forwarded-For", test.xff)
			request.Header.Set("X-Real-IP", test.realIP)
			if got := resolver.ClientIP(request); got != test.want {
				t.Fatalf("ClientIP()=%q want %q", got, test.want)
			}
		})
	}
}

func TestRealtimeConnectionLimitUsesTrustedProxyIdentity(t *testing.T) {
	_, proxyNetwork, err := net.ParseCIDR("172.28.250.0/24")
	if err != nil {
		t.Fatal(err)
	}
	resolver := NewClientIdentityResolver([]*net.IPNet{proxyNetwork})
	hub := realtime.NewHub()
	register := func(clientIP string, index int) error {
		request := httptest.NewRequest(http.MethodGet, "/api/v1/sync/ws", nil)
		request.RemoteAddr = "172.28.250.2:8080"
		request.Header.Set("X-Forwarded-For", clientIP)
		_, err := hub.Register(fmt.Sprintf("account-%s-%d", clientIP, index), fmt.Sprintf("device-%d", index), resolver.ClientIP(request))
		return err
	}
	for index := 0; index < 20; index++ {
		if err := register("203.0.113.8", index); err != nil {
			t.Fatalf("connection %d rejected early: %v", index, err)
		}
	}
	if err := register("203.0.113.8", 20); !errors.Is(err, realtime.ErrConnectionLimit) {
		t.Fatalf("same proxied client exceeded limit with error=%v", err)
	}
	if err := register("203.0.113.9", 21); err != nil {
		t.Fatalf("distinct proxied client shared another client's limit: %v", err)
	}
}

func TestSetupAuthorizationUsesResolvedIdentityAndToken(t *testing.T) {
	_, proxyNetwork, err := net.ParseCIDR("172.28.250.0/24")
	if err != nil {
		t.Fatalf("parse proxy network: %v", err)
	}
	api := &API{ClientIdentities: NewClientIdentityResolver([]*net.IPNet{proxyNetwork})}

	spoofed := httptest.NewRequest(http.MethodPost, "/api/v1/setup/owner", nil)
	spoofed.RemoteAddr = "198.51.100.20:443"
	spoofed.Header.Set("X-Forwarded-For", "127.0.0.1")
	if api.setupAuthorized(spoofed) {
		t.Fatal("untrusted peer spoofed loopback setup authorization")
	}

	proxied := httptest.NewRequest(http.MethodPost, "/api/v1/setup/owner", nil)
	proxied.RemoteAddr = "172.28.250.2:8080"
	proxied.Header.Set("X-Forwarded-For", "127.0.0.1, 203.0.113.20")
	if api.setupAuthorized(proxied) {
		t.Fatal("forged leftmost loopback bypassed trusted proxy topology")
	}

	api.SetupToken = "required-token"
	loopback := httptest.NewRequest(http.MethodPost, "/api/v1/setup/owner", nil)
	loopback.RemoteAddr = "127.0.0.1:8080"
	if api.setupAuthorized(loopback) {
		t.Fatal("production-style setup token was bypassed from loopback")
	}
	loopback.Header.Set("X-Veritra-Setup-Token", "required-token")
	if !api.setupAuthorized(loopback) {
		t.Fatal("valid setup token was rejected")
	}
	loopback.Header.Set("X-Veritra-Setup-Token", "short")
	if api.setupAuthorized(loopback) {
		t.Fatal("short setup token was accepted")
	}
}
