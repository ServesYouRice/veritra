package config

import (
	"encoding/base64"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Addr             string
	DataDir          string
	DatabasePath     string
	StoragePath      string
	InstanceName     string
	SetupToken       string
	EnableMetrics    bool
	ManagementAddr   string
	TrustedProxies   []*net.IPNet
	VAPIDSubscriber  string
	VAPIDPublicKey   string
	VAPIDPrivateKey  string
	FCMProjectID     string
	FCMClientEmail   string
	FCMPrivateKey    string
	APNsTeamID       string
	APNsKeyID        string
	APNsBundleID     string
	APNsPrivateKey   string
	TURNURLs         []string
	TURNSharedSecret string
	Environment      string
	LogLevel         string
	LogFormat        string
	PasswordCost     int
	SyncRetention    time.Duration
}

const (
	DefaultPasswordCost = 10
	MinPasswordCost     = 10
	MaxPasswordCost     = 15
)

func Load() (Config, error) {
	trustedProxies, err := parseCIDRs(getenv("PRIVATE_MESSENGER_TRUSTED_PROXIES", ""))
	if err != nil {
		return Config{}, err
	}
	passwordCost, err := parsePasswordCost(os.Getenv("PRIVATE_MESSENGER_BCRYPT_COST"))
	if err != nil {
		return Config{}, err
	}
	cfg := Config{
		Addr:             getenv("PRIVATE_MESSENGER_ADDR", ":8080"),
		DataDir:          getenv("PRIVATE_MESSENGER_DATA_DIR", "./data"),
		InstanceName:     getenv("PRIVATE_MESSENGER_INSTANCE_NAME", "Veritra"),
		SetupToken:       strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_SETUP_TOKEN")),
		EnableMetrics:    getenv("PRIVATE_MESSENGER_ENABLE_METRICS", "") == "1",
		ManagementAddr:   getenv("PRIVATE_MESSENGER_MANAGEMENT_ADDR", "127.0.0.1:9090"),
		TrustedProxies:   trustedProxies,
		VAPIDSubscriber:  strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_VAPID_SUBSCRIBER")),
		VAPIDPublicKey:   strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_VAPID_PUBLIC_KEY")),
		VAPIDPrivateKey:  strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_VAPID_PRIVATE_KEY")),
		FCMProjectID:     strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_FCM_PROJECT_ID")),
		FCMClientEmail:   strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_FCM_CLIENT_EMAIL")),
		FCMPrivateKey:    strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_FCM_PRIVATE_KEY")),
		APNsTeamID:       strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_APNS_TEAM_ID")),
		APNsKeyID:        strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_APNS_KEY_ID")),
		APNsBundleID:     strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_APNS_BUNDLE_ID")),
		APNsPrivateKey:   strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_APNS_PRIVATE_KEY")),
		TURNURLs:         splitNonEmpty(os.Getenv("PRIVATE_MESSENGER_TURN_URLS")),
		TURNSharedSecret: strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_TURN_SHARED_SECRET")),
		Environment:      strings.ToLower(strings.TrimSpace(getenv("PRIVATE_MESSENGER_ENV", "development"))),
		LogLevel:         strings.ToLower(strings.TrimSpace(getenv("PRIVATE_MESSENGER_LOG_LEVEL", "info"))),
		LogFormat:        strings.ToLower(strings.TrimSpace(getenv("PRIVATE_MESSENGER_LOG_FORMAT", "text"))),
		PasswordCost:     passwordCost,
		SyncRetention:    30 * 24 * time.Hour,
	}
	if cfg.Environment != "development" && cfg.Environment != "production" {
		return Config{}, fmt.Errorf("PRIVATE_MESSENGER_ENV must be development or production")
	}
	if cfg.Environment == "production" && cfg.SetupToken != "" {
		if err := ValidateSetupToken(cfg.SetupToken); err != nil {
			return Config{}, err
		}
	}
	if cfg.LogLevel != "debug" && cfg.LogLevel != "info" && cfg.LogLevel != "warn" && cfg.LogLevel != "error" {
		return Config{}, fmt.Errorf("PRIVATE_MESSENGER_LOG_LEVEL must be debug, info, warn, or error")
	}
	if cfg.LogFormat != "text" && cfg.LogFormat != "json" {
		return Config{}, fmt.Errorf("PRIVATE_MESSENGER_LOG_FORMAT must be text or json")
	}
	if (len(cfg.TURNURLs) == 0) != (cfg.TURNSharedSecret == "") {
		return Config{}, fmt.Errorf("TURN URLs and shared secret must be configured together")
	}
	for _, raw := range cfg.TURNURLs {
		value, err := url.Parse(raw)
		if err != nil || (value.Scheme != "turn" && value.Scheme != "turns") || value.Host == "" || value.User != nil {
			return Config{}, fmt.Errorf("invalid PRIVATE_MESSENGER_TURN_URLS entry")
		}
	}
	if raw := strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS")); raw != "" {
		days, err := strconv.Atoi(raw)
		if err != nil || days <= 0 || days > 3650 {
			return Config{}, fmt.Errorf("PRIVATE_MESSENGER_SYNC_EVENT_RETENTION_DAYS must be between 1 and 3650")
		}
		cfg.SyncRetention = time.Duration(days) * 24 * time.Hour
	}
	cfg.DatabasePath = getenv("PRIVATE_MESSENGER_DB_PATH", filepath.Join(cfg.DataDir, "private-messenger.db"))
	cfg.StoragePath = getenv("PRIVATE_MESSENGER_STORAGE_PATH", filepath.Join(cfg.DataDir, "blobs"))
	return cfg, nil
}

func parsePasswordCost(raw string) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return DefaultPasswordCost, nil
	}
	cost, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || cost < MinPasswordCost || cost > MaxPasswordCost {
		return 0, fmt.Errorf("PRIVATE_MESSENGER_BCRYPT_COST must be between %d and %d", MinPasswordCost, MaxPasswordCost)
	}
	return cost, nil
}

// ValidateSetupToken accepts the one supported operator encoding: unpadded
// URL-safe base64 containing at least 32 decoded bytes. The decoded-size check
// enforces the entropy floor; string length alone is not sufficient.
func ValidateSetupToken(token string) error {
	token = strings.TrimSpace(token)
	if token == "" {
		return fmt.Errorf("PRIVATE_MESSENGER_SETUP_TOKEN must not be empty")
	}
	switch strings.ToLower(token) {
	case "ci-smoke-setup-token", "contract-setup-token", "test-setup-token", "change-me", "replace-me":
		return fmt.Errorf("PRIVATE_MESSENGER_SETUP_TOKEN is a reserved placeholder")
	}
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(decoded) < 32 {
		return fmt.Errorf("PRIVATE_MESSENGER_SETUP_TOKEN must be unpadded base64url encoding of at least 32 random bytes; generate one with `messenger-server generate-setup-token`")
	}
	unique := make(map[byte]struct{}, len(decoded))
	for _, value := range decoded {
		unique[value] = struct{}{}
	}
	if len(unique) < 4 {
		return fmt.Errorf("PRIVATE_MESSENGER_SETUP_TOKEN has insufficient byte diversity")
	}
	return nil
}

func splitNonEmpty(raw string) []string {
	result := make([]string, 0)
	for _, item := range strings.Split(raw, ",") {
		if value := strings.TrimSpace(item); value != "" {
			result = append(result, value)
		}
	}
	return result
}

// ValidateServe rejects unsafe production listener configurations. TLS is
// expected at a reverse proxy; a non-loopback application listener therefore
// requires at least one explicitly trusted proxy network.
func (c Config) ValidateServe() error {
	if c.Environment == "production" && c.SetupToken != "" {
		if err := ValidateSetupToken(c.SetupToken); err != nil {
			return err
		}
	}
	host, _, err := net.SplitHostPort(c.Addr)
	if err != nil {
		return fmt.Errorf("invalid PRIVATE_MESSENGER_ADDR %q: %w", c.Addr, err)
	}
	if c.Environment == "production" && !loopbackHost(host) && len(c.TrustedProxies) == 0 {
		return fmt.Errorf("production non-loopback listener requires PRIVATE_MESSENGER_TRUSTED_PROXIES for the TLS reverse proxy")
	}
	if c.Environment == "production" && c.EnableMetrics {
		managementHost, _, err := net.SplitHostPort(c.ManagementAddr)
		if err != nil {
			return fmt.Errorf("invalid PRIVATE_MESSENGER_MANAGEMENT_ADDR %q: %w", c.ManagementAddr, err)
		}
		ip := net.ParseIP(managementHost)
		if !loopbackHost(managementHost) && (ip == nil || !ip.IsPrivate()) {
			return fmt.Errorf("production metrics listener must use a loopback or private IP address")
		}
	}
	return nil
}

func loopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func getenv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func parseCIDRs(raw string) ([]*net.IPNet, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	var result []*net.IPNet
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if !strings.Contains(part, "/") {
			if strings.Contains(part, ":") {
				part += "/128"
			} else {
				part += "/32"
			}
		}
		_, cidr, err := net.ParseCIDR(part)
		if err != nil {
			return nil, fmt.Errorf("invalid PRIVATE_MESSENGER_TRUSTED_PROXIES CIDR %q: %w", part, err)
		}
		result = append(result, cidr)
	}
	return result, nil
}
