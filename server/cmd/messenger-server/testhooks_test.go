//go:build veritra_testhooks

package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

// A test-hook binary refuses to serve, and its hooks refuse to run, outside
// a development environment; an unset environment counts as production.
func TestTestHookBinaryRefusesProduction(t *testing.T) {
	if !testHooksCompiled {
		t.Fatal("built with veritra_testhooks but testHooksCompiled is false")
	}
	for _, env := range []string{"production", ""} {
		t.Run("env="+env, func(t *testing.T) {
			t.Setenv("PRIVATE_MESSENGER_ENV", env)
			t.Setenv("PRIVATE_MESSENGER_SETUP_TOKEN", "")
			dir := t.TempDir()
			var out bytes.Buffer
			err := run([]string{"serve", "--addr", "127.0.0.1:0", "--data-dir", dir}, &out, &out)
			if err == nil || !strings.Contains(err.Error(), "veritra_testhooks") {
				t.Fatalf("serve in %q: %v", env, err)
			}
			err = run([]string{testHookUnlistedDevice, "--data-dir", dir, "acct", "dev", filepath.Join(dir, "kp")}, &out, &out)
			if err == nil || !strings.Contains(err.Error(), "veritra_testhooks") {
				t.Fatalf("hook in %q: %v", env, err)
			}
		})
	}
	t.Setenv("PRIVATE_MESSENGER_ENV", "production")
	var out bytes.Buffer
	if err := run([]string{"version"}, &out, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "test hooks, not for production") {
		t.Fatalf("version hides the test hooks: %q", out.String())
	}
}
