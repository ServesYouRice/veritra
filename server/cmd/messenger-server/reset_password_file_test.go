package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestPasswordFileModeAllowed(t *testing.T) {
	for _, test := range []struct {
		goos string
		mode os.FileMode
		want bool
	}{
		// Windows reports only the read-only attribute as mode bits.
		{"windows", 0o666, true},
		{"windows", 0o444, true},
		{"linux", 0o600, true},
		{"linux", 0o400, true},
		{"linux", 0o640, false},
		{"linux", 0o604, false},
		{"linux", 0o444, false},
		{"darwin", 0o600, true},
		{"darwin", 0o660, false},
	} {
		if got := passwordFileModeAllowed(test.goos, test.mode); got != test.want {
			t.Errorf("passwordFileModeAllowed(%s, %o) = %v, want %v", test.goos, test.mode, got, test.want)
		}
	}
}

// The size limit must hold before the file is read into memory.
func TestResetOwnerPasswordRefusesALargeFileWithoutReadingIt(t *testing.T) {
	cfg := seedInstance(t, "live")
	path := filepath.Join(t.TempDir(), "password")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	// Sparse: no disk space is used.
	if err := file.Truncate(512 << 20); err != nil {
		t.Fatal(err)
	}
	file.Close()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	err = resetOwnerPassword(context.Background(), cfg, "owner", path, &bytes.Buffer{})
	runtime.ReadMemStats(&after)
	if err == nil || !strings.Contains(err.Error(), "too large") {
		t.Fatalf("err=%v, want too large", err)
	}
	if allocated := after.TotalAlloc - before.TotalAlloc; allocated > 16<<20 {
		t.Fatalf("refusing a 512 MiB password file allocated %d bytes", allocated)
	}
}

func TestResetOwnerPasswordRefusesALargeFile(t *testing.T) {
	cfg := seedInstance(t, "live")
	path := filepath.Join(t.TempDir(), "password")
	if err := os.WriteFile(path, bytes.Repeat([]byte("x"), 2<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	err := resetOwnerPassword(context.Background(), cfg, "owner", path, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "too large") {
		t.Fatalf("err=%v, want too large", err)
	}
}

func TestResetOwnerPasswordRefusesADirectory(t *testing.T) {
	cfg := seedInstance(t, "live")
	dir := filepath.Join(t.TempDir(), "password")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	err := resetOwnerPassword(context.Background(), cfg, "owner", dir, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("err=%v, want a regular-file refusal", err)
	}
}
