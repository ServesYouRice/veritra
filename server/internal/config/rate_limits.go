package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// RateLimits are the per-minute request budgets of the HTTP rate limiter;
// see docs/operations.md, "Credential abuse controls". A zero field means
// "use the default". The credential (10 a minute) and enrollment (5 a
// minute) budgets per address are fixed: they bound password and
// capability guessing and are not meant to be raised.
type RateLimits struct {
	// AddressPerMinute bounds requests from one client address that carry
	// no session token or one that does not resolve to a session.
	AddressPerMinute int
	// AccountPerMinute bounds requests with a valid session, per account at
	// one client address.
	AccountPerMinute int
	// SignedInAddressPerMinute bounds all requests that carry a session
	// token from one client address, every account behind it together.
	SignedInAddressPerMinute int
}

const (
	DefaultAddressRequestsPerMinute         = 240
	DefaultAccountRequestsPerMinute         = 240
	DefaultSignedInAddressRequestsPerMinute = 1200
)

type rateLimitSetting struct {
	key      string
	min, max int
	set      func(*RateLimits, int)
}

var rateLimitSettings = []rateLimitSetting{
	{"PRIVATE_MESSENGER_RATE_LIMIT_ADDRESS_PER_MINUTE", 60, 100_000, func(l *RateLimits, v int) { l.AddressPerMinute = v }},
	{"PRIVATE_MESSENGER_RATE_LIMIT_ACCOUNT_PER_MINUTE", 60, 100_000, func(l *RateLimits, v int) { l.AccountPerMinute = v }},
	{"PRIVATE_MESSENGER_RATE_LIMIT_SIGNED_IN_ADDRESS_PER_MINUTE", 60, 1_000_000, func(l *RateLimits, v int) { l.SignedInAddressPerMinute = v }},
}

func loadRateLimits() (RateLimits, error) {
	var limits RateLimits
	for _, setting := range rateLimitSettings {
		raw := strings.TrimSpace(os.Getenv(setting.key))
		if raw == "" {
			continue
		}
		value, err := strconv.Atoi(raw)
		if err != nil || value < setting.min || value > setting.max {
			return RateLimits{}, fmt.Errorf("%s must be a whole number between %d and %d", setting.key, setting.min, setting.max)
		}
		setting.set(&limits, value)
	}
	if err := limits.WithDefaults().Validate(); err != nil {
		return RateLimits{}, err
	}
	return limits, nil
}

// WithDefaults fills every zero field.
func (l RateLimits) WithDefaults() RateLimits {
	if l.AddressPerMinute == 0 {
		l.AddressPerMinute = DefaultAddressRequestsPerMinute
	}
	if l.AccountPerMinute == 0 {
		l.AccountPerMinute = DefaultAccountRequestsPerMinute
	}
	if l.SignedInAddressPerMinute == 0 {
		l.SignedInAddressPerMinute = DefaultSignedInAddressRequestsPerMinute
	}
	return l
}

// Validate checks that one account can use its whole budget at an address.
func (l RateLimits) Validate() error {
	if l.SignedInAddressPerMinute < l.AccountPerMinute {
		return fmt.Errorf("PRIVATE_MESSENGER_RATE_LIMIT_SIGNED_IN_ADDRESS_PER_MINUTE must be at least PRIVATE_MESSENGER_RATE_LIMIT_ACCOUNT_PER_MINUTE (%d)", l.AccountPerMinute)
	}
	return nil
}
