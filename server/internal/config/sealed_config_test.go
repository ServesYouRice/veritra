package config

import "testing"

func TestSealedSenderSwitchAndCap(t *testing.T) {
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SealedSender || cfg.SealedTokensPerDay != DefaultSealedTokensPerDay {
		t.Fatalf("default sealed=%v cap=%d", cfg.SealedSender, cfg.SealedTokensPerDay)
	}
	t.Setenv("PRIVATE_MESSENGER_SEALED_SENDER", "1")
	t.Setenv("PRIVATE_MESSENGER_SEALED_TOKENS_PER_DAY", "64")
	cfg, err = Load()
	if err != nil || !cfg.SealedSender || cfg.SealedTokensPerDay != 64 {
		t.Fatalf("sealed=%v cap=%d err=%v", cfg.SealedSender, cfg.SealedTokensPerDay, err)
	}
	for _, bad := range []string{"0", "10001", "many"} {
		t.Setenv("PRIVATE_MESSENGER_SEALED_TOKENS_PER_DAY", bad)
		if _, err := Load(); err == nil {
			t.Fatalf("cap %q accepted", bad)
		}
	}
}
