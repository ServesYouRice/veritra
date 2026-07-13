package config

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
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
}

func Load() (Config, error) {
	trustedProxies, err := parseCIDRs(getenv("PRIVATE_MESSENGER_TRUSTED_PROXIES", ""))
	if err != nil {
		return Config{}, err
	}
	cfg := Config{
		Addr:            getenv("PRIVATE_MESSENGER_ADDR", ":8080"),
		DataDir:         getenv("PRIVATE_MESSENGER_DATA_DIR", "./data"),
		InstanceName:    getenv("PRIVATE_MESSENGER_INSTANCE_NAME", "Private Messenger"),
		SetupToken:      os.Getenv("PRIVATE_MESSENGER_SETUP_TOKEN"),
		EnableMetrics:   getenv("PRIVATE_MESSENGER_ENABLE_METRICS", "") == "1",
		ManagementAddr:  getenv("PRIVATE_MESSENGER_MANAGEMENT_ADDR", "127.0.0.1:9090"),
		TrustedProxies:  trustedProxies,
		VAPIDSubscriber: strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_VAPID_SUBSCRIBER")),
		VAPIDPublicKey:  strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_VAPID_PUBLIC_KEY")),
		VAPIDPrivateKey: strings.TrimSpace(os.Getenv("PRIVATE_MESSENGER_VAPID_PRIVATE_KEY")),
	}
	cfg.DatabasePath = getenv("PRIVATE_MESSENGER_DB_PATH", filepath.Join(cfg.DataDir, "private-messenger.db"))
	cfg.StoragePath = getenv("PRIVATE_MESSENGER_STORAGE_PATH", filepath.Join(cfg.DataDir, "blobs"))
	return cfg, nil
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
