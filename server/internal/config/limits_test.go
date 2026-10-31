package config

import (
	"strings"
	"testing"
)

func TestLimitsDefaultWhenUnset(t *testing.T) {
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Limits != (Limits{}) {
		t.Fatalf("unset limits = %+v, want zero (defaults applied later)", cfg.Limits)
	}
	got := cfg.Limits.WithDefaults()
	want := Limits{AccountStorageBytes: 512 << 20, AccountBlobs: 10000, DevicesPerAccount: 10, ConversationMembers: 100,
		ConversationsPerAccount: 1000, KeyPackageClaimsPerTarget: 25, MLSSelfUpdateMinutes: 60, DeliveriesPerMinute: 1000, WriteBytesPerHour: 64 << 20, AttachmentBytes: 48 << 20, SocketsPerIPv6Prefix: 200}
	if got != want {
		t.Fatalf("defaults = %+v, want %+v", got, want)
	}
}

func TestLimitsParseAndBound(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_LIMIT_ACCOUNT_STORAGE_MIB", "256")
	t.Setenv("PRIVATE_MESSENGER_LIMIT_INSTANCE_STORAGE_MIB", "4096")
	t.Setenv("PRIVATE_MESSENGER_LIMIT_DEVICES_PER_ACCOUNT", "4")
	t.Setenv("PRIVATE_MESSENGER_LIMIT_CONVERSATION_MEMBERS", "50")
	t.Setenv("PRIVATE_MESSENGER_LIMIT_DELIVERIES_PER_MINUTE", "500")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	l := cfg.Limits
	if l.KeyPackageClaimsPerTarget != 0 {
		t.Fatalf("key package claim limit set without its variable: %+v", l)
	}
	if l.AccountStorageBytes != 256<<20 || l.InstanceStorageBytes != 4096<<20 || l.DevicesPerAccount != 4 || l.ConversationMembers != 50 || l.DeliveriesPerMinute != 500 {
		t.Fatalf("limits = %+v", l)
	}
	for key, value := range map[string]string{
		"PRIVATE_MESSENGER_LIMIT_DEVICES_PER_ACCOUNT":           "11",
		"PRIVATE_MESSENGER_LIMIT_CONVERSATION_MEMBERS":          "1",
		"PRIVATE_MESSENGER_LIMIT_ACCOUNT_STORAGE_MIB":           "8",
		"PRIVATE_MESSENGER_LIMIT_CONVERSATIONS_PER_ACCOUNT":     "many",
		"PRIVATE_MESSENGER_LIMIT_WRITE_MIB_PER_HOUR":            "-1",
		"PRIVATE_MESSENGER_LIMIT_ATTACHMENT_MIB":                "49",
		"PRIVATE_MESSENGER_LIMIT_KEY_PACKAGE_CLAIMS_PER_TARGET": "51",
		"PRIVATE_MESSENGER_LIMIT_MLS_SELF_UPDATE_MINUTES":       "10081",
	} {
		t.Run(key, func(t *testing.T) {
			t.Setenv(key, value)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), key) {
				t.Fatalf("%s=%s accepted: %v", key, value, err)
			}
		})
	}
}

func TestLimitsRelations(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_LIMIT_CONVERSATION_MEMBERS", "1000")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "DELIVERIES_PER_MINUTE") {
		t.Fatalf("1000 members with 1000 deliveries/min accepted: %v", err)
	}
	t.Setenv("PRIVATE_MESSENGER_LIMIT_DELIVERIES_PER_MINUTE", "2002")
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PRIVATE_MESSENGER_LIMIT_ACCOUNT_STORAGE_MIB", "2048")
	t.Setenv("PRIVATE_MESSENGER_LIMIT_INSTANCE_STORAGE_MIB", "1024")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "must not exceed") {
		t.Fatalf("account above instance accepted: %v", err)
	}
}

func TestDeriveInstanceStorage(t *testing.T) {
	for _, tc := range []struct {
		volume int64
		keep   int
		want   int64
	}{
		{40 << 30, 7, 3686 << 20},   // the shipped 40 GiB PVC, keep 7
		{100 << 30, 7, 9216 << 20},  // tier M volume
		{500 << 30, 7, 10240 << 20}, // capped at the former 10 GiB
		{40 << 30, 1, 9216 << 20},
		{100 << 20, 7, 64 << 20}, // floor
	} {
		if got := DeriveInstanceStorage(tc.volume, tc.keep); got != tc.want {
			t.Fatalf("DeriveInstanceStorage(%d, %d) = %d MiB, want %d MiB", tc.volume>>20, tc.keep, got>>20, tc.want>>20)
		}
	}
}

func TestSocketsPerIPv6PrefixLimit(t *testing.T) {
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Limits.WithDefaults().SocketsPerIPv6Prefix; got != DefaultSocketsPerIPv6Prefix {
		t.Fatalf("default = %d, want %d", got, DefaultSocketsPerIPv6Prefix)
	}
	t.Setenv("PRIVATE_MESSENGER_LIMIT_SOCKETS_PER_IPV6_PREFIX", "50")
	if cfg, err = Load(); err != nil || cfg.Limits.SocketsPerIPv6Prefix != 50 {
		t.Fatalf("configured limit: %+v err=%v", cfg.Limits, err)
	}
	for _, value := range []string{"19", "10001", "many"} {
		t.Setenv("PRIVATE_MESSENGER_LIMIT_SOCKETS_PER_IPV6_PREFIX", value)
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "SOCKETS_PER_IPV6_PREFIX") {
			t.Fatalf("%q accepted: %v", value, err)
		}
	}
}

func TestAttachmentLimit(t *testing.T) {
	t.Setenv("PRIVATE_MESSENGER_LIMIT_ATTACHMENT_MIB", "10")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Limits.AttachmentBytes != 10<<20 {
		t.Fatalf("attachment limit = %d", cfg.Limits.AttachmentBytes)
	}
	if got, want := MaxAttachmentCiphertext(10<<20), int64(10<<20+10*20); got != want {
		t.Fatalf("ciphertext bound = %d, want %d", got, want)
	}
}
