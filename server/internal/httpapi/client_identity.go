package httpapi

import (
	"net"
	"net/http"
	"strings"
)

// ClientIdentityResolver derives one spoof-resistant network identity for
// HTTP throttles, setup authorization, and realtime connection limits.
// Forwarding headers are trusted only when the direct peer is in an explicitly
// configured proxy network.
type ClientIdentityResolver struct {
	trustedProxies []*net.IPNet
}

func NewClientIdentityResolver(trustedProxies []*net.IPNet) *ClientIdentityResolver {
	return &ClientIdentityResolver{trustedProxies: append([]*net.IPNet(nil), trustedProxies...)}
}

func (resolver *ClientIdentityResolver) ClientIP(r *http.Request) string {
	direct := remoteHost(r.RemoteAddr)
	directIP := net.ParseIP(direct)
	if resolver == nil || directIP == nil || !ipInNetworks(directIP, resolver.trustedProxies) {
		return canonicalIP(direct)
	}
	forwarded := strings.Split(r.Header.Get("X-Forwarded-For"), ",")
	for index := len(forwarded) - 1; index >= 0; index-- {
		candidate := canonicalIP(strings.TrimSpace(forwarded[index]))
		ip := net.ParseIP(candidate)
		if ip == nil {
			continue
		}
		if !ipInNetworks(ip, resolver.trustedProxies) {
			return candidate
		}
	}
	if realIP := canonicalIP(strings.TrimSpace(r.Header.Get("X-Real-IP"))); net.ParseIP(realIP) != nil {
		return realIP
	}
	return canonicalIP(direct)
}

func remoteHost(remoteAddr string) string {
	host, _, err := net.SplitHostPort(strings.TrimSpace(remoteAddr))
	if err == nil {
		return host
	}
	return strings.Trim(strings.TrimSpace(remoteAddr), "[]")
}

func canonicalIP(value string) string {
	if ip := net.ParseIP(strings.Trim(value, "[]")); ip != nil {
		return ip.String()
	}
	return strings.Trim(value, "[]")
}

func ipInNetworks(ip net.IP, networks []*net.IPNet) bool {
	for _, network := range networks {
		if network != nil && network.Contains(ip) {
			return true
		}
	}
	return false
}
