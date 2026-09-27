package httpapi

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
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
		xffLines   []string
		realIP     string
		want       string
	}{
		{name: "untrusted peer cannot spoof forwarding", remoteAddr: "198.51.100.10:443", xff: "127.0.0.1", want: "198.51.100.10"},
		{name: "trusted proxy preserves distinct client", remoteAddr: "172.28.250.2:8080", xff: "203.0.113.8", want: "203.0.113.8"},
		{name: "rightmost untrusted hop defeats forged left entry", remoteAddr: "172.28.250.2:8080", xff: "127.0.0.1, 203.0.113.9, 172.28.250.3", want: "203.0.113.9"},
		{name: "trusted proxy real ip fallback", remoteAddr: "172.28.250.2:8080", realIP: "203.0.113.10", want: "203.0.113.10"},
		{name: "malformed real ip falls back to peer", remoteAddr: "172.28.250.2:8080", realIP: "not-an-ip", want: "172.28.250.2"},
		{name: "malformed hop fails closed instead of skipping to forged entry", remoteAddr: "172.28.250.2:8080", xff: "203.0.113.66, garbage, 172.28.250.3", want: "172.28.250.2"},
		{name: "zoned hop fails closed", remoteAddr: "172.28.250.2:8080", xff: "203.0.113.66, fe80::1%eth0", want: "172.28.250.2"},
		{name: "forged trusted and loopback entries left of the client are ignored", remoteAddr: "172.28.250.2:8080", xff: "172.28.250.9, 127.0.0.1, 203.0.113.11", want: "203.0.113.11"},
		{name: "all-trusted chain resolves to peer, not a forged real ip", remoteAddr: "172.28.250.2:8080", xff: "172.28.250.4, 172.28.250.3", realIP: "203.0.113.12", want: "172.28.250.2"},
		{name: "real ip ignored when forwarded chain exists", remoteAddr: "172.28.250.2:8080", xff: "203.0.113.13", realIP: "198.51.100.99", want: "203.0.113.13"},
		{name: "ip and port entries are accepted", remoteAddr: "172.28.250.2:8080", xff: "203.0.113.14:50123, [2001:db8::7]:443", want: "2001:db8::7"},
		{name: "ipv4-mapped hop is canonical", remoteAddr: "172.28.250.2:8080", xff: "::ffff:203.0.113.15", want: "203.0.113.15"},
		{name: "chain beyond the hop bound fails closed", remoteAddr: "172.28.250.2:8080", xff: "203.0.113.16" + strings.Repeat(", 172.28.250.3", maxForwardedHops), want: "172.28.250.2"},
		{name: "client within the hop bound is found", remoteAddr: "172.28.250.2:8080", xff: "203.0.113.17" + strings.Repeat(", 172.28.250.3", maxForwardedHops-1), want: "203.0.113.17"},
		{name: "split header lines are read in order", remoteAddr: "172.28.250.2:8080", xffLines: []string{"198.51.100.1, 203.0.113.18", "172.28.250.3"}, want: "203.0.113.18"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest("GET", "https://messenger.example.test/api/v1/health", nil)
			request.RemoteAddr = test.remoteAddr
			request.Header.Set("X-Forwarded-For", test.xff)
			if test.xffLines != nil {
				request.Header.Del("X-Forwarded-For")
				for _, line := range test.xffLines {
					request.Header.Add("X-Forwarded-For", line)
				}
			}
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
