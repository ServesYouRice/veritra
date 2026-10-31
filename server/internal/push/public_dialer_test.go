package push

import (
	"net/netip"
	"testing"
)

// The push dialer only connects to globally routable unicast addresses
// (VAL-237). Pure address classification, no network.
func TestForbiddenPushAddress(t *testing.T) {
	forbidden := []string{
		// Shared address space (RFC 6598) and its IPv4-mapped form.
		"100.64.0.1", "100.100.100.100", "100.127.255.254", "::ffff:100.64.0.1", "::ffff:100.127.255.254",
		// Other non-global special-purpose IPv4 ranges.
		"0.0.0.1", "192.0.0.8", "192.0.2.1", "198.18.0.1", "198.19.255.254", "198.51.100.7", "203.0.113.9",
		"240.0.0.1", "255.255.255.254", "255.255.255.255", "::ffff:198.18.0.1", "::ffff:240.0.0.1",
		// IPv6 translation, tunnelling, documentation and discard ranges.
		"64:ff9b::a00:1", "64:ff9b::808:808", "64:ff9b:1::1", "100::1", "2001::1", "2001:db8::1", "2002:a00:1::", "2002:808:808::1",
		// What the earlier predicates already refused.
		"10.1.2.3", "172.16.0.1", "192.168.1.1", "127.0.0.1", "169.254.1.1", "0.0.0.0", "224.0.0.1",
		"::1", "::", "fe80::1", "fc00::1", "fd12::1", "ff02::1", "::ffff:10.0.0.1", "::ffff:127.0.0.1",
	}
	for _, text := range forbidden {
		if !forbiddenPushAddress(netip.MustParseAddr(text)) {
			t.Errorf("%s was allowed", text)
		}
	}
	allowed := []string{
		"8.8.8.8", "1.1.1.1", "9.9.9.9", "100.63.255.255", "100.128.0.1", "198.17.255.255", "198.20.0.1",
		"203.0.114.1",
		"2001:4860:4860::8888", "2606:4700:4700::1111", "::ffff:8.8.8.8", "2a00:1450:4001:81b::200e",
	}
	for _, text := range allowed {
		if forbiddenPushAddress(netip.MustParseAddr(text)) {
			t.Errorf("%s was refused", text)
		}
	}
}
