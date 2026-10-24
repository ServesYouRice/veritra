package config

import (
	"strings"
	"testing"
)

func TestRateLimitsDefaultWhenUnset(t *testing.T) {
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.RateLimits != (RateLimits{}) {
		t.Fatalf("unset rate limits = %+v, want zero (defaults applied later)", cfg.RateLimits)
	}
	want := RateLimits{AddressPerMinute: 240, AccountPerMinute: 240, SignedInAddressPerMinute: 1200}
	if got := cfg.RateLimits.WithDefaults(); got != want {
		t.Fatalf("defaults = %+v, want %+v", got, want)
	}
}

func TestRateLimitsParseAndBound(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_RATE_LIMIT_ADDRESS_PER_MINUTE", "120")
	t.Setenv("PRIVATE_MESSENGER_RATE_LIMIT_ACCOUNT_PER_MINUTE", "300")
	t.Setenv("PRIVATE_MESSENGER_RATE_LIMIT_SIGNED_IN_ADDRESS_PER_MINUTE", "3000")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if want := (RateLimits{AddressPerMinute: 120, AccountPerMinute: 300, SignedInAddressPerMinute: 3000}); cfg.RateLimits != want {
		t.Fatalf("rate limits = %+v, want %+v", cfg.RateLimits, want)
	}
	for key, value := range map[string]string{
		"PRIVATE_MESSENGER_RATE_LIMIT_ADDRESS_PER_MINUTE":           "59",
		"PRIVATE_MESSENGER_RATE_LIMIT_ACCOUNT_PER_MINUTE":           "100001",
		"PRIVATE_MESSENGER_RATE_LIMIT_SIGNED_IN_ADDRESS_PER_MINUTE": "lots",
	} {
		t.Run(key, func(t *testing.T) {
			t.Setenv(key, value)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), key) {
				t.Fatalf("%s=%s accepted: %v", key, value, err)
			}
		})
	}
}

// One account must be able to use its whole budget at an address, so the
// address ceiling may not be below it, including against the default.
func TestRateLimitsRelations(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_RATE_LIMIT_SIGNED_IN_ADDRESS_PER_MINUTE", "200")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "SIGNED_IN_ADDRESS_PER_MINUTE") {
		t.Fatalf("ceiling 200 below the default account budget 240 accepted: %v", err)
	}
	t.Setenv("PRIVATE_MESSENGER_RATE_LIMIT_ACCOUNT_PER_MINUTE", "200")
	if _, err := Load(); err != nil {
		t.Fatalf("ceiling equal to the account budget refused: %v", err)
	}
}
