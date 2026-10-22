package main

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"private-messenger/server/internal/config"
)

// Two data directories that share one overridden database or blob directory
// must not both get a server process (card I46).
func TestResourceLocksRejectSharedOverriddenStorage(t *testing.T) {
	shared := t.TempDir()
	first := commandConfig(t.TempDir())
	first.DatabasePath = filepath.Join(shared, "db", "private-messenger.db")
	first.StoragePath = filepath.Join(shared, "blobs")
	first, err := first.ResolvePaths()
	if err != nil {
		t.Fatal(err)
	}
	held, err := acquireResourceLocks(first)
	if err != nil {
		t.Fatal(err)
	}

	sameDatabase := commandConfig(t.TempDir())
	sameDatabase.DatabasePath = filepath.Join(shared, "db", "..", "db", "private-messenger.db")
	sameDatabase, err = sameDatabase.ResolvePaths()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := acquireResourceLocks(sameDatabase); err == nil || !strings.Contains(err.Error(), "multiple writers") {
		t.Fatalf("shared database lock error=%v", err)
	}
	sameBlobs := commandConfig(t.TempDir())
	sameBlobs.StoragePath = first.StoragePath
	if _, err := acquireResourceLocks(sameBlobs); err == nil || !strings.Contains(err.Error(), "blob storage") {
		t.Fatalf("shared blob lock error=%v", err)
	}

	if err := held.Release(); err != nil {
		t.Fatal(err)
	}
	again, err := acquireResourceLocks(sameDatabase)
	if err != nil {
		t.Fatalf("released locks could not be reacquired: %v", err)
	}
	if err := again.Release(); err != nil {
		t.Fatal(err)
	}
}

func TestStorageCommandsRejectOverlappingPaths(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PRIVATE_MESSENGER_STORAGE_PATH", dir)
	var output bytes.Buffer
	err := run([]string{"migrate", "-data-dir", dir}, &output, &output)
	if err == nil || !strings.Contains(err.Error(), "blob storage path") {
		t.Fatalf("overlapping layout error=%v", err)
	}
}

func readDeployFile(t *testing.T, name string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "deploy", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func TestSupportedComposeUsesDigestImageAndHardening(t *testing.T) {
	compose := readDeployFile(t, "docker-compose.yml")
	if regexp.MustCompile(`(?m)^\s*build:`).MatchString(compose) {
		t.Fatal("supported compose builds from a source checkout")
	}
	if !strings.Contains(compose, `image: "${VERITRA_IMAGE:?`) {
		t.Fatal("supported compose does not require the released image reference")
	}
	for _, want := range []string{"read_only: true", "- ALL", "no-new-privileges:true", `user: "65532:65532"`, "messenger-data:/data", "stop_grace_period: 30s", ":/run/secrets:ro"} {
		if !strings.Contains(compose, want) {
			t.Fatalf("compose lacks %q", want)
		}
	}
	// Secret values must not be interpolated into the service environment,
	// where `docker compose config` and `docker inspect` would show them.
	// The one-time setup token is the documented exception.
	for _, key := range config.SecretEnvKeys {
		if key == "PRIVATE_MESSENGER_SETUP_TOKEN" {
			continue
		}
		if strings.Contains(compose, key+":") {
			t.Fatalf("compose passes %s by value; use %s_FILE", key, key)
		}
	}
}

func TestSystemdUnitsAreHardened(t *testing.T) {
	for _, name := range []string{"systemd/private-messenger.service", "systemd/private-messenger-backup.service"} {
		unit := readDeployFile(t, name)
		for _, want := range []string{
			"NoNewPrivileges=true", "CapabilityBoundingSet=\n", "ProtectSystem=strict",
			"ReadWritePaths=%S/private-messenger", "StateDirectory=private-messenger",
			"ProtectHome=true", "PrivateTmp=true", "PrivateDevices=true",
			"RestrictNamespaces=true", "SystemCallFilter=@system-service", "UMask=0077",
		} {
			if !strings.Contains(unit, want) {
				t.Fatalf("%s lacks %q", name, strings.TrimSpace(want))
			}
		}
	}
	if unit := readDeployFile(t, "systemd/private-messenger.service"); !strings.Contains(unit, "TimeoutStopSec=30") {
		t.Fatal("server unit stop timeout no longer covers the shutdown budget")
	}
}
