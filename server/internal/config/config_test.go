package config

import (
	"bytes"
	"encoding/base64"
	"net"
	"strings"
	"testing"
	"time"
)

func TestLoadOperationalSettings(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_ENV", "production")
	t.Setenv("PRIVATE_MESSENGER_SETUP_TOKEN", "")
	t.Setenv("PRIVATE_MESSENGER_LOG_LEVEL", "warn")
	t.Setenv("PRIVATE_MESSENGER_LOG_FORMAT", "json")
	t.Setenv("PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS", "45")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Environment != "production" || cfg.LogLevel != "warn" || cfg.LogFormat != "json" {
		t.Fatalf("unexpected operational settings: %#v", cfg)
	}
	if cfg.SyncRetention != 45*24*time.Hour {
		t.Fatalf("sync retention = %s", cfg.SyncRetention)
	}
	if cfg.PasswordCost != DefaultPasswordCost {
		t.Fatalf("password cost = %d want %d", cfg.PasswordCost, DefaultPasswordCost)
	}
}

func TestLoadPasswordCostRange(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_BCRYPT_COST", "13")
	cfg, err := Load()
	if err != nil || cfg.PasswordCost != 13 {
		t.Fatalf("configured password cost=%d err=%v", cfg.PasswordCost, err)
	}
	for _, raw := range []string{"9", "16", "not-a-cost"} {
		t.Setenv("PRIVATE_MESSENGER_BCRYPT_COST", raw)
		if _, err := Load(); err == nil {
			t.Fatalf("invalid password cost accepted: %q", raw)
		}
	}
}

func TestValidateSetupTokenUsesDecodedEntropyFloor(t *testing.T) {
	decoded := make([]byte, 32)
	for i := range decoded {
		decoded[i] = byte(i + 1)
	}
	valid := base64.RawURLEncoding.EncodeToString(decoded)
	if err := ValidateSetupToken(valid); err != nil {
		t.Fatalf("valid setup token rejected: %v", err)
	}
	for _, token := range []string{
		"x",
		"test-setup-token",
		base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)),
	} {
		if err := ValidateSetupToken(token); err == nil {
			t.Fatalf("weak setup token accepted: %q", token)
		}
	}
}

func TestLoadRejectsWeakProductionSetupToken(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_ENV", "production")
	t.Setenv("PRIVATE_MESSENGER_SETUP_TOKEN", strings.Repeat("x", 32))
	if _, err := Load(); err == nil {
		t.Fatal("weak production setup token accepted")
	}
}

func TestValidateServeProductionPosture(t *testing.T) {
	cfg := Config{Addr: ":8080", Environment: "production"}
	if err := cfg.ValidateServe(); err == nil {
		t.Fatal("expected public production listener without a proxy to fail")
	}

	_, proxy, err := net.ParseCIDR("10.0.0.0/8")
	if err != nil {
		t.Fatal(err)
	}
	cfg.TrustedProxies = []*net.IPNet{proxy}
	if err := cfg.ValidateServe(); err != nil {
		t.Fatalf("production listener behind declared proxy rejected: %v", err)
	}

	cfg.EnableMetrics = true
	cfg.ManagementAddr = "0.0.0.0:9090"
	if err := cfg.ValidateServe(); err == nil {
		t.Fatal("expected public production metrics listener to fail")
	}
}

func TestLoadRejectsInvalidOperationalSettings(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_LOG_FORMAT", "xml")
	if _, err := Load(); err == nil {
		t.Fatal("expected invalid log format to fail")
	}
}

func TestTrustedProxyRangesRejectUnsafeNetworks(t *testing.T) {
	for _, entry := range []string{
		"0.0.0.0/0",
		"::/0",
		"::ffff:0:0/96",
		"::ffff:0:0/80",
		"0.0.0.0",
		"0.1.2.3/32",
		"224.0.0.1",
		"ff02::1",
		"10.0.0.0/7",
		"8.0.0.0/8",
		"104.16.0.0/11",
		"2001::/16",
		"2400:cb00::/28",
		"fe80::1%eth0",
		"not-a-network",
	} {
		if _, err := parseCIDRs(entry); err == nil {
			t.Errorf("parseCIDRs(%q) accepted an unsafe trusted-proxy range", entry)
		}
	}
}

func TestTrustedProxyRangesAcceptOperatorNetworks(t *testing.T) {
	cases := map[string]string{
		"127.0.0.1":           "127.0.0.1/32",
		"10.0.0.0/8":          "10.0.0.0/8",
		"172.28.250.7/24":     "172.28.250.0/24",
		"100.64.0.0/10":       "100.64.0.0/10",
		"fc00::/7":            "fc00::/7",
		"::1":                 "::1/128",
		"104.16.0.0/13":       "104.16.0.0/13",
		"2400:cb00::/32":      "2400:cb00::/32",
		"2a06:98c0::/29":      "2a06:98c0::/29",
		"::ffff:10.1.2.0/120": "10.1.2.0/24",
		"198.51.100.4":        "198.51.100.4/32",
	}
	for entry, want := range cases {
		networks, err := parseCIDRs(entry)
		if err != nil {
			t.Errorf("parseCIDRs(%q) rejected an operator network: %v", entry, err)
			continue
		}
		if len(networks) != 1 || networks[0].String() != want {
			t.Errorf("parseCIDRs(%q)=%v want %s", entry, networks, want)
		}
	}
	mapped, err := parseCIDRs("::ffff:10.1.2.0/120")
	if err != nil {
		t.Fatal(err)
	}
	if mapped[0].Contains(net.ParseIP("203.0.113.1")) || !mapped[0].Contains(net.ParseIP("10.1.2.3")) {
		t.Fatal("IPv4-mapped trusted range did not narrow to its IPv4 network")
	}
}
