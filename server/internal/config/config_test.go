package config

import (
	"bytes"
	"encoding/base64"
	"net"
	"os"
	"path/filepath"
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

func TestLoadSecretsFromFiles(t *testing.T) {
	dir := t.TempDir()
	write := func(name, value string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	decoded := make([]byte, 32)
	for i := range decoded {
		decoded[i] = byte(i + 1)
	}
	token := base64.RawURLEncoding.EncodeToString(decoded)
	t.Setenv("PRIVATE_MESSENGER_ENV", "production")
	t.Setenv("PRIVATE_MESSENGER_SETUP_TOKEN", "")
	t.Setenv("PRIVATE_MESSENGER_SETUP_TOKEN_FILE", write("setup", token+"\n"))
	t.Setenv("PRIVATE_MESSENGER_VAPID_PRIVATE_KEY_FILE", write("vapid", "vapid-secret\n"))
	t.Setenv("PRIVATE_MESSENGER_FCM_PRIVATE_KEY_FILE", write("fcm", "-----BEGIN PRIVATE KEY-----\nfcm\n-----END PRIVATE KEY-----\n"))
	t.Setenv("PRIVATE_MESSENGER_APNS_PRIVATE_KEY_FILE", write("apns", "apns-secret"))
	t.Setenv("PRIVATE_MESSENGER_TURN_URLS", "turns://turn.example.com:5349")
	t.Setenv("PRIVATE_MESSENGER_TURN_SHARED_SECRET_FILE", write("turn", "turn-secret\r\n"))

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SetupToken != token || cfg.VAPIDPrivateKey != "vapid-secret" || cfg.APNsPrivateKey != "apns-secret" || cfg.TURNSharedSecret != "turn-secret" {
		t.Fatalf("file secrets were not loaded and trimmed")
	}
	if cfg.FCMPrivateKey != "-----BEGIN PRIVATE KEY-----\nfcm\n-----END PRIVATE KEY-----" {
		t.Fatalf("multi-line FCM key was not preserved")
	}
}

func TestLoadSecretFileErrorsNeverEchoValues(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "turn")
	if err := os.WriteFile(path, []byte("sentinel-file-secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(dir, "empty")
	if err := os.WriteFile(empty, []byte(" \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	large := filepath.Join(dir, "large")
	if err := os.WriteFile(large, bytes.Repeat([]byte("a"), maxSecretFileBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, direct, file string
	}{
		{"both set", "sentinel-inline-secret", path},
		{"missing file", "", filepath.Join(dir, "missing")},
		{"directory", "", dir},
		{"empty file", "", empty},
		{"oversized file", "", large},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("PRIVATE_MESSENGER_TURN_URLS", "turns://turn.example.com:5349")
			t.Setenv("PRIVATE_MESSENGER_TURN_SHARED_SECRET", tc.direct)
			t.Setenv("PRIVATE_MESSENGER_TURN_SHARED_SECRET_FILE", tc.file)
			_, err := Load()
			if err == nil {
				t.Fatal("invalid secret file configuration accepted")
			}
			if strings.Contains(err.Error(), "sentinel") {
				t.Fatalf("error leaked a secret value: %v", err)
			}
		})
	}
}

func TestLoadShutdownTimeout(t *testing.T) {
	cfg, err := Load()
	if err != nil || cfg.ShutdownTimeout != DefaultShutdownTimeout {
		t.Fatalf("default shutdown timeout=%s err=%v", cfg.ShutdownTimeout, err)
	}
	t.Setenv("PRIVATE_MESSENGER_SHUTDOWN_TIMEOUT", "2m")
	if cfg, err = Load(); err != nil || cfg.ShutdownTimeout != 2*time.Minute {
		t.Fatalf("configured shutdown timeout=%s err=%v", cfg.ShutdownTimeout, err)
	}
	for _, raw := range []string{"1s", "16m", "soon"} {
		t.Setenv("PRIVATE_MESSENGER_SHUTDOWN_TIMEOUT", raw)
		if _, err := Load(); err == nil {
			t.Fatalf("invalid shutdown timeout accepted: %q", raw)
		}
	}
}
