//go:build veritra_testhooks

package main

// Test hooks for the live end-to-end runs (scripts/test-live-e2e.sh). This
// file is compiled only with the veritra_testhooks build tag. Release and
// image builds never pass it (server/Dockerfile, scripts/release-image.sh);
// TestReleaseBuildsNeverSetTestHooksTag fails if one does. A binary built
// with the tag also refuses to serve, and the hooks refuse to run, outside
// PRIVATE_MESSENGER_ENV=development (an unset environment is production).

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"private-messenger/server/internal/config"
	"private-messenger/server/internal/storage"
	"private-messenger/server/migrations"
)

// testHooksCompiled reports whether this binary holds the test hooks.
const testHooksCompiled = true

// testHookUnlistedDevice is the L1-5 "ghost device" command.
const testHookUnlistedDevice = "test-insert-unlisted-device"

// maxTestKeyPackageBytes bounds the key package file the hook reads; the
// server's own transport bound for one key package is 48 KiB.
const maxTestKeyPackageBytes = 48 * 1024

// requireTestHookEnvironment refuses a test hook, or serving with one
// compiled in, anywhere but a development environment.
func requireTestHookEnvironment(cfg config.Config) error {
	if cfg.Environment != "development" {
		return errors.New("this binary was built with test hooks (veritra_testhooks) and runs only with PRIVATE_MESSENGER_ENV=development")
	}
	return nil
}

// runTestHook runs command when it names a test hook. handled is false for
// any other command.
func runTestHook(ctx context.Context, cfg config.Config, command string, args []string, stdout io.Writer) (handled bool, err error) {
	if command != testHookUnlistedDevice {
		return false, nil
	}
	if err := requireTestHookEnvironment(cfg); err != nil {
		return true, err
	}
	if len(args) != 3 {
		return true, fmt.Errorf("usage: %s --data-dir DIR ACCOUNT_ID DEVICE_ID KEY_PACKAGE_FILE", testHookUnlistedDevice)
	}
	return true, insertUnlistedDevice(ctx, cfg, args[0], args[1], args[2], stdout)
}

// insertUnlistedDevice writes a device no signed list names into a stopped
// server's database, under the same exclusions as reset-owner-password.
func insertUnlistedDevice(ctx context.Context, cfg config.Config, accountID, deviceID, keyPackageFile string, stdout io.Writer) error {
	keyPackage, err := readTestKeyPackage(keyPackageFile)
	if err != nil {
		return err
	}
	if cfg, err = cfg.ResolvePaths(); err != nil {
		return err
	}
	if _, err := os.Stat(cfg.DatabasePath); err != nil {
		return fmt.Errorf("no database at %s: %w", cfg.DatabasePath, err)
	}
	server, err := acquireServerExclusion(cfg)
	if err != nil {
		return fmt.Errorf("a server appears to be running; stop it first: %w", err)
	}
	defer server.Release()
	probeCtx, cancel := context.WithTimeout(ctx, time.Second)
	err = storage.ProbeDatabaseExclusive(probeCtx, cfg.DatabasePath)
	cancel()
	if err != nil {
		return fmt.Errorf("database appears in use; stop the server first: %w", err)
	}
	store, err := storage.Open(ctx, cfg)
	if err != nil {
		return err
	}
	defer store.Close()
	if err := store.Migrate(ctx, migrations.FS); err != nil {
		return err
	}
	if err := store.InsertUnlistedDeviceForTest(ctx, accountID, deviceID, keyPackage); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "unlisted test device inserted")
	return nil
}

func readTestKeyPackage(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maxTestKeyPackageBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || len(raw) > maxTestKeyPackageBytes {
		return nil, errors.New("key package file is empty or too large")
	}
	return raw, nil
}
