package config

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Addr            string
	DataDir         string
	DatabasePath    string
	StoragePath     string
	InstanceName    string
	SetupToken      string
	EnableMetrics   bool
	ManagementAddr  string
	TrustedProxies  []*net.IPNet
	VAPIDSubscriber string
	VAPIDPublicKey  string
	VAPIDPrivateKey string
	Environment     string
	LogLevel        string
	LogFormat       string
	SyncRetention   time.Duration
}

func Load() (Config, error) {
	trustedProxies, err := parseCIDRs(getenv("PRIVATE_MESSENGER_TRUSTED_PROXIES", ""))
	if err != nil {
		return Config{}, err
	}
	cfg := Config{
		Addr:            getenv("PRIVATE_MESSENGER_ADDR", ":8080"),
		DataDir:         getenv("PRIVATE_MESSENGER_DATA_DIR", "./data"),
		InstanceName:    getenv("PRIVATE_MESSENGER_INSTANCE_NAME", "Veritra"),
		SetupToken:      os.Getenv("PRIVATE_MESSENGER_SETUP_TOKEN"),
		EnableMetrics:   getenv("PRIVATE_MESSENGER_ENABLE_METRICS", "") == "1",
		ManagementAddr:  getenv("PRIVATE_MESSENGER_MANAGEMENT_ADDR", "127.0.0.1:9090"),
		TrustedProxies:  trustedProxies,
		VAPIDSubscriber: strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_VAPID_SUBSCRIBER")),
		VAPIDPublicKey:  strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_VAPID_PUBLIC_KEY")),
		VAPIDPrivateKey: strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_VAPID_PRIVATE_KEY")),
		Environment:     strings.ToLower(strings.TrimSpace(getenv("PRIVATE_MESSENGER_ENV", "development"))),
		LogLevel:        strings.ToLower(strings.TrimSpace(getenv("PRIVATE_MESSENGER_LOG_LEVEL", "info"))),
		LogFormat:       strings.ToLower(strings.TrimSpace(getenv("PRIVATE_MESSENGER_LOG_FORMAT", "text"))),
		SyncRetention:   30 * 24 * time.Hour,
	}
	if cfg.Environment != "development" && cfg.Environment != "production" {
		return Config{}, fmt.Errorf("PRIVATE_MESSENGER_ENV must be development or production")
	}
	if cfg.LogLevel != "debug" && cfg.LogLevel != "info" && cfg.LogLevel != "warn" && cfg.LogLevel != "error" {
		return Config{}, fmt.Errorf("PRIVATE_MESSENGER_LOG_LEVEL must be debug, info, warn, or error")
	}
	if cfg.LogFormat != "text" && cfg.LogFormat != "json" {
		return Config{}, fmt.Errorf("PRIVATE_MESSENGER_LOG_FORMAT must be text or json")
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

// ValidateServe rejects unsafe production listener configurations. TLS is
// expected at a reverse proxy; a non-loopback application listener therefore
// requires at least one explicitly trusted proxy network.
func (c Config) ValidateServe() error {
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
