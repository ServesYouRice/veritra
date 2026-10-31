//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A regular file swapped for a FIFO between the metadata check and the open
// must be refused from the opened handle, without blocking on the open.
func TestReadPasswordFileRefusesAFIFOSwappedInBeforeTheOpen(t *testing.T) {
	dir := t.TempDir()
	if err := syscall.Mkfifo(filepath.Join(dir, "probe"), 0o600); err != nil {
		t.Skipf("mkfifo unavailable: %v", err)
	}
	path := filepath.Join(dir, "password")
	if err := os.WriteFile(path, []byte("secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	swapped := false
	previous := faultHook
	t.Cleanup(func() { faultHook = previous })
	faultHook = func(step string) error {
		if step == "password-file:open" && !swapped {
			swapped = true
			if err := os.Remove(path); err != nil {
				return err
			}
			if err := syscall.Mkfifo(path, 0o600); err != nil {
				return err
			}
		}
		return nil
	}
	done := make(chan error, 1)
	go func() {
		_, err := readPasswordFile(path)
		done <- err
	}()
	select {
	case err := <-done:
		if !swapped {
			t.Fatal("the swap step did not run")
		}
		if err == nil || !strings.Contains(err.Error(), "regular file") {
			t.Fatalf("err=%v, want a regular-file refusal", err)
		}
	case <-time.After(10 * time.Second):
		// Unblock the reader so the goroutine does not leak.
		if writer, err := os.OpenFile(path, os.O_WRONLY|syscall.O_NONBLOCK, 0); err == nil {
			writer.Close()
		}
		t.Fatal("readPasswordFile blocked opening a FIFO")
	}
}
