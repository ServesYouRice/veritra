//go:build !windows

package config

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Opening a FIFO read-only blocks until a writer appears, so the regular-file
// check must come before any blocking open (VAL-213).
func TestReadSecretFileRejectsFIFOWithoutBlocking(t *testing.T) {
	fifo := filepath.Join(t.TempDir(), "secret")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Skipf("named pipes unavailable: %v", err)
	}
	// If the read blocks, a late writer lets the goroutine finish so the
	// failure is reported instead of leaking a stuck open.
	t.Cleanup(func() {
		if writer, err := os.OpenFile(fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0); err == nil {
			writer.Close()
		}
	})
	type result struct {
		value string
		err   error
	}
	done := make(chan result, 1)
	go func() {
		value, err := readSecretFile(fifo)
		done <- result{value, err}
	}()
	select {
	case got := <-done:
		if got.err == nil || !strings.Contains(got.err.Error(), "not a regular file") {
			t.Fatalf("FIFO secret: value=%q err=%v, want a not-a-regular-file error", got.value, got.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("readSecretFile blocked on a FIFO with no writer")
	}
}

func TestReadSecretFileStillReadsRegularFilesAndSymlinks(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	if err := os.WriteFile(target, []byte("s3cret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	for _, path := range []string{target, link} {
		if value, err := readSecretFile(path); err != nil || value != "s3cret" {
			t.Fatalf("%s: value=%q err=%v", path, value, err)
		}
	}
}
