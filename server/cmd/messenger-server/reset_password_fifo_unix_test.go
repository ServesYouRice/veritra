//go:build !windows

package main

import (
	"bytes"
	"context"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Opening a FIFO for reading blocks until a writer appears, so the command
// must refuse it from its metadata alone.
func TestResetOwnerPasswordRefusesAFIFOWithoutBlocking(t *testing.T) {
	cfg := seedInstance(t, "live")
	path := filepath.Join(t.TempDir(), "password")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Skipf("mkfifo unavailable: %v", err)
	}
	done := make(chan error, 1)
	go func() { done <- resetOwnerPassword(context.Background(), cfg, "owner", path, &bytes.Buffer{}) }()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "regular file") {
			t.Fatalf("err=%v, want a regular-file refusal", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("reset-owner-password blocked opening a FIFO")
	}
}
