package realtime

import (
	"errors"
	"fmt"
	"sync"
	"testing"
)

// checkHubIndexes recomputes every count by brute force and compares it with
// the indexes Register relies on.
func checkHubIndexes(t *testing.T, h *Hub) {
	t.Helper()
	h.mu.RLock()
	defer h.mu.RUnlock()
	total := 0
	perIP := map[string]int{}
	for accountID, clients := range h.subscribers {
		if len(clients) == 0 {
			t.Fatalf("empty account set left in index")
		}
		for client := range clients {
			if client.accountID != accountID {
				t.Fatalf("client indexed under wrong account")
			}
			perIP[client.ipKey]++
			total++
		}
	}
	if total != h.total {
		t.Fatalf("total=%d, counted %d", h.total, total)
	}
	if len(perIP) != len(h.perIP) {
		t.Fatalf("perIP has %d addresses, counted %d", len(h.perIP), len(perIP))
	}
	for ip, n := range perIP {
		if h.perIP[ip] != n {
			t.Fatalf("perIP count %d, counted %d", h.perIP[ip], n)
		}
	}
}

func TestHubPerAccountLimit(t *testing.T) {
	hub := NewHub()
	var clients []*Client
	for i := 0; i < maxConnectionsPerAccount; i++ {
		c, err := hub.Register("acct", fmt.Sprintf("dev%d", i), fmt.Sprintf("192.0.2.%d", i))
		if err != nil {
			t.Fatalf("register %d: %v", i, err)
		}
		clients = append(clients, c)
	}
	if _, err := hub.Register("acct", "devX", "198.51.100.1"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("expected account limit, got %v", err)
	}
	if _, err := hub.Register("other", "devX", "198.51.100.1"); err != nil {
		t.Fatalf("other account must be unaffected: %v", err)
	}
	hub.Unregister(clients[0])
	if _, err := hub.Register("acct", "devX", "198.51.100.1"); err != nil {
		t.Fatalf("slot must free after unregister: %v", err)
	}
	checkHubIndexes(t, hub)
}

func TestHubPerDeviceLimit(t *testing.T) {
	hub := NewHub()
	for i := 0; i < maxConnectionsPerDevice; i++ {
		if _, err := hub.Register("acct", "dev", fmt.Sprintf("192.0.2.%d", i)); err != nil {
			t.Fatalf("register %d: %v", i, err)
		}
	}
	if _, err := hub.Register("acct", "dev", "198.51.100.1"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("expected device limit, got %v", err)
	}
	// The same device id under another account is a different device.
	if _, err := hub.Register("other", "dev", "198.51.100.1"); err != nil {
		t.Fatalf("device limit must be per account: %v", err)
	}
	if _, err := hub.Register("acct", "dev2", "198.51.100.1"); err != nil {
		t.Fatalf("other device on same account: %v", err)
	}
	hub.DisconnectDevice("acct", "dev")
	if _, err := hub.Register("acct", "dev", "198.51.100.1"); err != nil {
		t.Fatalf("device slot must free after disconnect: %v", err)
	}
	checkHubIndexes(t, hub)
}

func TestHubPerIPLimit(t *testing.T) {
	hub := NewHub()
	var clients []*Client
	for i := 0; i < maxConnectionsPerIP; i++ {
		c, err := hub.Register(fmt.Sprintf("acct%d", i), "dev", "203.0.113.1")
		if err != nil {
			t.Fatalf("register %d: %v", i, err)
		}
		clients = append(clients, c)
	}
	if _, err := hub.Register("acctX", "dev", "203.0.113.1"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("expected IP limit, got %v", err)
	}
	if _, err := hub.Register("acctX", "dev", "203.0.113.2"); err != nil {
		t.Fatalf("other IP must be unaffected: %v", err)
	}
	hub.Unregister(clients[3])
	hub.Unregister(clients[3]) // double unregister must not free a second slot
	if _, err := hub.Register("acctY", "dev", "203.0.113.1"); err != nil {
		t.Fatalf("IP slot must free after unregister: %v", err)
	}
	if _, err := hub.Register("acctZ", "dev", "203.0.113.1"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("double unregister freed an extra slot: %v", err)
	}
	checkHubIndexes(t, hub)
}

// An IPv6 client controls at least a /64, so the per-address cap counts the
// prefix, not the single address (VAL-238). IPv4 and IPv4-mapped forms of one
// address share a bucket.
func TestHubPerIPLimitAggregatesIPv6Slash64(t *testing.T) {
	hub := NewHub()
	for i := 0; i < maxConnectionsPerIP; i++ {
		if _, err := hub.Register(fmt.Sprintf("acct%d", i), "dev", fmt.Sprintf("2001:db8:1::%x", i+1)); err != nil {
			t.Fatalf("register %d: %v", i, err)
		}
	}
	if _, err := hub.Register("rotator", "dev", "2001:db8:1::ffff"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("a fresh address in the same /64 escaped the cap: %v", err)
	}
	if _, err := hub.Register("rotator", "dev", "2001:db8:1:0:abcd::1"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("another interface identifier in the same /64 escaped the cap: %v", err)
	}
	if _, err := hub.Register("neighbour", "dev", "2001:db8:2::1"); err != nil {
		t.Fatalf("a different /64 must be unaffected: %v", err)
	}
	checkHubIndexes(t, hub)

	mapped := NewHub()
	for i := 0; i < maxConnectionsPerIP; i++ {
		ip := "192.0.2.1"
		if i%2 == 1 {
			ip = "::ffff:192.0.2.1"
		}
		if _, err := mapped.Register(fmt.Sprintf("acct%d", i), "dev", ip); err != nil {
			t.Fatalf("register %d: %v", i, err)
		}
	}
	if _, err := mapped.Register("extra", "dev", "::ffff:192.0.2.1"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("mapped and plain IPv4 forms did not share a bucket: %v", err)
	}
	if _, err := mapped.Register("extra", "dev", "192.0.2.2"); err != nil {
		t.Fatalf("another IPv4 address must be unaffected: %v", err)
	}
	checkHubIndexes(t, mapped)
}

func TestIPBucket(t *testing.T) {
	for in, want := range map[string]string{
		"192.0.2.1":                "192.0.2.1",
		"::ffff:192.0.2.1":         "192.0.2.1",
		"2001:db8:1:2:3:4:5:6":     "2001:db8:1:2::/64",
		"2001:db8:1:2:ffff::1":     "2001:db8:1:2::/64",
		"2001:db8:1:3::1":          "2001:db8:1:3::/64",
		"not an address":           "not an address",
		"":                         "",
		"fe80::1%eth0":             "fe80::/64",
		"2001:db8:1::1/64 garbage": "2001:db8:1::1/64 garbage",
	} {
		if got := ipBucket(in); got != want {
			t.Errorf("ipBucket(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHubTotalLimit(t *testing.T) {
	hub := NewHub()
	for i := 0; i < maxConnections; i++ {
		if _, err := hub.Register(fmt.Sprintf("acct%d", i), "dev", fmt.Sprintf("10.%d.%d.%d", i/65536, (i/256)%256, i%256)); err != nil {
			t.Fatalf("register %d: %v", i, err)
		}
	}
	if _, err := hub.Register("new", "dev", "192.0.2.1"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("expected total limit, got %v", err)
	}
	if hub.ConnectionCount() != maxConnections {
		t.Fatalf("count=%d", hub.ConnectionCount())
	}
}

func TestHubDisconnectPathsCleanIndexes(t *testing.T) {
	hub := NewHub()
	register := func(account, device, ip string) *Client {
		t.Helper()
		c, err := hub.Register(account, device, ip)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	keep := register("a", "keep", "192.0.2.1")
	register("a", "drop", "192.0.2.1")
	register("a", "drop2", "192.0.2.2")
	register("b", "dev", "192.0.2.1")
	register("c", "dev", "192.0.2.3")

	hub.DisconnectAccountExceptDevice("a", "keep")
	checkHubIndexes(t, hub)
	if hub.ConnectionCount() != 3 {
		t.Fatalf("count=%d", hub.ConnectionCount())
	}
	hub.DisconnectDevice("a", "keep")
	checkHubIndexes(t, hub)
	if _, open := <-keep.Send(); open {
		t.Fatal("disconnected client must be closed")
	}
	hub.Unregister(keep) // already removed: no double decrement
	hub.DisconnectAccount("b")
	checkHubIndexes(t, hub)
	if hub.ConnectionCount() != 1 {
		t.Fatalf("count=%d", hub.ConnectionCount())
	}
	hub.Drain()
	checkHubIndexes(t, hub)
	if len(hub.perIP) != 0 || hub.ConnectionCount() != 0 {
		t.Fatal("drain must clear every index")
	}
	if _, err := hub.Register("d", "dev", "192.0.2.9"); !errors.Is(err, ErrHubDraining) {
		t.Fatalf("expected draining, got %v", err)
	}
}

func TestHubConcurrentRegisterKeepsLimits(t *testing.T) {
	hub := NewHub()
	var wg sync.WaitGroup
	var mu sync.Mutex
	accepted := map[string]int{}
	for g := 0; g < 16; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				account := fmt.Sprintf("acct%d", i%4)
				device := fmt.Sprintf("dev%d", i%2)
				c, err := hub.Register(account, device, "198.51.100.7")
				if err != nil {
					continue
				}
				mu.Lock()
				accepted[account]++
				mu.Unlock()
				switch i % 3 {
				case 0:
					hub.Unregister(c)
				case 1:
					hub.DisconnectDevice(account, device)
				}
			}
		}(g)
	}
	wg.Wait()
	checkHubIndexes(t, hub)
	hub.mu.RLock()
	defer hub.mu.RUnlock()
	if hub.perIP["198.51.100.7"] > maxConnectionsPerIP {
		t.Fatalf("IP cap exceeded: %d", hub.perIP["198.51.100.7"])
	}
	for _, clients := range hub.subscribers {
		if len(clients) > maxConnectionsPerAccount {
			t.Fatalf("account cap exceeded: %d", len(clients))
		}
		perDevice := map[string]int{}
		for c := range clients {
			perDevice[c.deviceID]++
			if perDevice[c.deviceID] > maxConnectionsPerDevice {
				t.Fatalf("device cap exceeded")
			}
		}
	}
}
