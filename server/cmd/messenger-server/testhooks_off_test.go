//go:build !veritra_testhooks

package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

// A default build, which every release build is, holds no test hook: the
// ghost-device command is unknown even in a development environment.
func TestDefaultBuildHasNoTestHooks(t *testing.T) {
	if testHooksCompiled {
		t.Fatal("test hooks compiled into a build without the veritra_testhooks tag")
	}
	t.Setenv("PRIVATE_MESSENGER_ENV", "development")
	dir := t.TempDir()
	var out bytes.Buffer
	err := run([]string{"test-insert-unlisted-device", "--data-dir", dir, "acct", "dev", filepath.Join(dir, "kp")}, &out, &out)
	if err == nil || !strings.Contains(err.Error(), "unknown command") {
		t.Fatalf("the test hook answered in a default build: %v", err)
	}
	out.Reset()
	if err := run([]string{"version"}, &out, &out); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "test hooks") {
		t.Fatalf("default build reports test hooks: %q", out.String())
	}
}
