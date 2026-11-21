package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// goBuildTags matches a Go -tags flag (not git's --tags or --no-tags).
var goBuildTags = regexp.MustCompile(`(^|[\s"'])-tags[\s=]`)

// The test hooks (testhooks.go) exist only in a binary built with the
// veritra_testhooks tag. No release, image or deployment build may pass it,
// and none may pass build tags at all, so a production binary can never
// hold them. Only the live end-to-end script builds a test-hook binary.
func TestReleaseBuildsNeverSetTestHooksTag(t *testing.T) {
	root := filepath.Join("..", "..", "..")
	files := []string{
		"server/Dockerfile",
		".github/workflows/release.yml",
		".github/workflows/repro.yml",
		"scripts/release-image.sh",
		"scripts/verify-server-build.sh",
		"scripts/demo.sh",
		"scripts/demo.ps1",
		"scripts/dev.sh",
		"scripts/dev.ps1",
		"scripts/smoke-deploy.sh",
		"scripts/capacity.sh",
		"Makefile",
	}
	deploy, err := filepath.Glob(filepath.Join(root, "deploy", "*"))
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range deploy {
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() {
			rel, _ := filepath.Rel(root, path)
			files = append(files, rel)
		}
	}
	for _, rel := range files {
		raw, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
		text := string(raw)
		if strings.Contains(text, "veritra_testhooks") || goBuildTags.MatchString(text) || strings.Contains(text, "GOFLAGS") {
			t.Errorf("%s sets build tags; release and deployment builds must not (test hooks)", rel)
		}
	}
	// The one place that builds a test-hook binary.
	raw, err := os.ReadFile(filepath.Join(root, "scripts", "test-live-e2e.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "-tags veritra_testhooks") {
		t.Fatal("scripts/test-live-e2e.sh no longer builds the test-hook binary; update this guard")
	}
}
