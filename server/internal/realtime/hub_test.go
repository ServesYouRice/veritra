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
	perPrefix := map[string]int{}
	for accountID, clients := range h.subscribers {
		if len(clients) == 0 {
			t.Fatalf("empty account set left in index")
		}
		for client := range clients {
			if client.accountID != accountID {
				t.Fatalf("client indexed under wrong account")
			}
			perIP[client.ipKey]++
			if client.prefixKey != "" {
				perPrefix[client.prefixKey]++
			}
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
	if len(perPrefix) != len(h.perPrefix) {
		t.Fatalf("perPrefix has %d prefixes, counted %d", len(h.perPrefix), len(perPrefix))
	}
	for prefix, n := range perPrefix {
		if h.perPrefix[prefix] != n {
			t.Fatalf("perPrefix count %d, counted %d", h.perPrefix[prefix], n)
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

// An IPv6 client controls at least a /64, so rotating addresses inside it
// must not escape every cap: one address still gets maxConnectionsPerIP
// sockets, and the whole /64 gets its own, higher cap (VAL-238). IPv4 and
// IPv4-mapped forms of one address share a bucket.
func TestHubIPv6AddressAndPrefixLimits(t *testing.T) {
	hub := NewHub()
	account := 0
	register := func(ip string) error {
		account++
		_, err := hub.Register(fmt.Sprintf("acct%d", account), "dev", ip)
		return err
	}
	// 20 sockets from one address, and the 21st is refused.
	for i := 0; i < maxConnectionsPerIP; i++ {
		if err := register("2001:db8:1::1"); err != nil {
			t.Fatalf("register %d from one address: %v", i, err)
		}
	}
	if err := register("2001:db8:1::1"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("a 21st socket from one address was admitted: %v", err)
	}
	// An office /64 holds many addresses: up to the prefix cap in all.
	for address := 2; hub.perPrefix["2001:db8:1::/64"] < defaultMaxConnectionsPerIPv6Prefix; address++ {
		if err := register(fmt.Sprintf("2001:db8:1::%x", address)); err != nil {
			t.Fatalf("register from address %d with %d in the /64: %v", address, hub.perPrefix["2001:db8:1::/64"], err)
		}
	}
	if err := register("2001:db8:1:0:abcd::1"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("a fresh address in a full /64 escaped the prefix cap: %v", err)
	}
	if err := register("2001:db8:2::1"); err != nil {
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
	if len(mapped.perPrefix) != 0 {
		t.Fatalf("IPv4 sockets were counted under a prefix: %v", mapped.perPrefix)
	}
	checkHubIndexes(t, mapped)
}

func TestHubPrefixLimitIsConfigurableAndFreesOnRemoval(t *testing.T) {
	hub := NewHubWithLimits(HubLimits{PerIPv6Prefix: 30})
	var clients []*Client
	for i := 0; i < 30; i++ {
		c, err := hub.Register(fmt.Sprintf("acct%d", i), "dev", fmt.Sprintf("2001:db8:9::%x", i+1))
		if err != nil {
			t.Fatalf("register %d: %v", i, err)
		}
		clients = append(clients, c)
	}
	if _, err := hub.Register("over", "dev", "2001:db8:9::ffff"); !errors.Is(err, ErrConnectionLimit) {
		t.Fatalf("the configured prefix cap of 30 did not hold: %v", err)
	}
	hub.Unregister(clients[0])
	if _, err := hub.Register("again", "dev", "2001:db8:9::ffff"); err != nil {
		t.Fatalf("removal did not free a prefix slot: %v", err)
	}
	hub.DisconnectAccount("again")
	hub.Drain()
	checkHubIndexes(t, hub)
	if len(hub.perIP) != 0 || len(hub.perPrefix) != 0 {
		t.Fatalf("indexes not empty after drain: %v %v", hub.perIP, hub.perPrefix)
	}
}

func TestAddressKeys(t *testing.T) {
	for in, want := range map[string][2]string{
		"192.0.2.1":            {"192.0.2.1", ""},
		"::ffff:192.0.2.1":     {"192.0.2.1", ""},
		"2001:db8:1:2:3:4:5:6": {"2001:db8:1:2:3:4:5:6", "2001:db8:1:2::/64"},
		"2001:db8:1:2:ffff::1": {"2001:db8:1:2:ffff::1", "2001:db8:1:2::/64"},
		"fe80::1%eth0":         {"fe80::1", "fe80::/64"},
		"not an address":       {"not an address", ""},
		"":                     {"", ""},
	} {
		address, prefix := addressKeys(in)
		if address != want[0] || prefix != want[1] {
			t.Errorf("addressKeys(%q) = %q, %q; want %q, %q", in, address, prefix, want[0], want[1])
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
