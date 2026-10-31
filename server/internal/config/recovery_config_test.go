package config

import (
	"testing"
	"time"
)

func TestLoadPublicOriginAndRecoveryDurations(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_ENV", "development")
	t.Setenv("PRIVATE_MESSENGER_PUBLIC_ORIGIN", "")
	t.Setenv("PRIVATE_MESSENGER_RECOVERY_ACTIVE_WINDOW_DAYS", "")
	t.Setenv("PRIVATE_MESSENGER_RECOVERY_WAIT_DAYS", "")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PublicOrigin != "" || cfg.RecoveryActiveWindow != 7*24*time.Hour || cfg.RecoveryWait != 7*24*time.Hour {
		t.Fatalf("defaults: origin=%q window=%s wait=%s", cfg.PublicOrigin, cfg.RecoveryActiveWindow, cfg.RecoveryWait)
	}

	t.Setenv("PRIVATE_MESSENGER_PUBLIC_ORIGIN", "https://chat.example.com")
	t.Setenv("PRIVATE_MESSENGER_RECOVERY_ACTIVE_WINDOW_DAYS", "3")
	t.Setenv("PRIVATE_MESSENGER_RECOVERY_WAIT_DAYS", "10")
	cfg, err = Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PublicOrigin != "https://chat.example.com" || cfg.RecoveryActiveWindow != 3*24*time.Hour || cfg.RecoveryWait != 10*24*time.Hour {
		t.Fatalf("set: origin=%q window=%s wait=%s", cfg.PublicOrigin, cfg.RecoveryActiveWindow, cfg.RecoveryWait)
	}

	for _, bad := range []string{"0", "91", "x"} {
		t.Setenv("PRIVATE_MESSENGER_RECOVERY_WAIT_DAYS", bad)
		if _, err := Load(); err == nil {
			t.Fatalf("wait days %q accepted", bad)
		}
	}
	t.Setenv("PRIVATE_MESSENGER_RECOVERY_WAIT_DAYS", "")
	t.Setenv("PRIVATE_MESSENGER_PUBLIC_ORIGIN", "https://Chat.example.com/")
	if _, err := Load(); err == nil {
		t.Fatal("non-canonical public origin accepted")
	}
}

func TestValidPublicOrigin(t *testing.T) {
	for origin, want := range map[string]bool{
		"https://chat.example.com":       true,
		"https://chat.example.com:8443":  true,
		"http://localhost:8080":          true,
		"http://127.0.0.1:8080":          true,
		"http://[::1]:8080":              true,
		"https://chat.example.com/":      false,
		"https://chat.example.com:443":   false,
		"https://Chat.example.com":       false,
		"http://chat.example.com":        false,
		"https://user@chat.example.com":  false,
		"https://chat.example.com?x=1":   false,
		"https://chat.example.com#frag":  false,
		" https://chat.example.com":      false,
		"chat.example.com":               false,
		"ftp://chat.example.com":         false,
		"https://chat.example.com:08443": false,
		"":                               false,
	} {
		if got := ValidPublicOrigin(origin); got != want {
			t.Errorf("ValidPublicOrigin(%q) = %v, want %v", origin, got, want)
		}
	}
}
