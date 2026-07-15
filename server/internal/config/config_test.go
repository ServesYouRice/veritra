package config

import (
	"net"
	"testing"
	"time"
)

func TestLoadOperationalSettings(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_ENV", "production")
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
