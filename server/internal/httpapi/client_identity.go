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

// maxForwardedHops bounds how many X-Forwarded-For entries are examined,
// counting from the entry the nearest proxy appended.
const maxForwardedHops = 16

// ClientIP walks X-Forwarded-For from the right, skipping trusted proxies, and
// returns the first untrusted hop. Anything it cannot vouch for — a malformed
// or zoned entry, a chain longer than maxForwardedHops, or a chain made only
// of trusted proxies — resolves to the direct peer. That fails closed: every
// such client shares the proxy's identity rather than choosing its own.
// X-Real-IP is used only when X-Forwarded-For is absent, so the proxy must
// overwrite it. The RFC 7239 Forwarded header is deliberately ignored.
func (resolver *ClientIdentityResolver) ClientIP(r *http.Request) string {
	direct := canonicalIP(remoteHost(r.RemoteAddr))
	directIP := net.ParseIP(direct)
	if resolver == nil || directIP == nil || !ipInNetworks(directIP, resolver.trustedProxies) {
		return direct
	}
	joined := strings.Join(r.Header.Values("X-Forwarded-For"), ",")
	if strings.Trim(joined, ", \t") == "" {
		if realIP, ok := forwardedIP(r.Header.Get("X-Real-IP")); ok {
			return realIP.String()
		}
		return direct
	}
	forwarded := strings.Split(joined, ",")
	for hops := 0; hops < maxForwardedHops && hops < len(forwarded); hops++ {
		ip, ok := forwardedIP(forwarded[len(forwarded)-1-hops])
		if !ok {
			return direct
		}
		if !ipInNetworks(ip, resolver.trustedProxies) {
			return ip.String()
		}
	}
	return direct
}

// forwardedIP parses one forwarding-header entry. Some load balancers append
// "ip:port", so a port is accepted; zoned addresses are not.
func forwardedIP(value string) (net.IP, bool) {
	value = strings.TrimSpace(value)
	if host, _, err := net.SplitHostPort(value); err == nil {
		value = host
	}
	value = strings.Trim(value, "[]")
	if strings.Contains(value, "%") {
		return nil, false
	}
	ip := net.ParseIP(value)
	return ip, ip != nil
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
