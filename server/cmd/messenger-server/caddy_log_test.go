package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Card I29: no credential reaches a configured proxy log field, URL or error.
// Caddy's access log and its error log (which records the failed request,
// headers included) must both drop the request URI and every credential
// header the server accepts. Authorization is redacted by Caddy itself.
// Checked against Caddy 2.11.4 on 2026-10-23
// (testing/evidence/verification-2026-10-23.md).
func TestCaddyLogsDropURIsAndCredentialHeaders(t *testing.T) {
	caddyfile := readDeployFile(t, "caddy/Caddyfile")
	blocks := map[string]string{
		"error log (log default)": caddyBlock(t, caddyfile, "log default {"),
		"access log (site log)":   caddyBlock(t, caddyfile, "\tlog {"),
	}
	headers := credentialHeaders(t)
	for _, required := range []string{"X-Recovery-Token", "X-Veritra-Setup-Token", "X-Veritra-Claim-Token"} {
		if !headers[required] {
			t.Fatalf("server no longer reads %s; update this test", required)
		}
	}
	for name, block := range blocks {
		if !strings.Contains(block, "format filter") || !strings.Contains(block, "request>uri delete") {
			t.Fatalf("%s does not delete the request URI:\n%s", name, block)
		}
		for header := range headers {
			if !strings.Contains(block, "request>headers>"+header+" delete") {
				t.Fatalf("%s keeps credential header %s", name, header)
			}
		}
	}
}

// caddyBlock returns the brace-balanced block that starts at opener.
func caddyBlock(t *testing.T, text, opener string) string {
	t.Helper()
	start := strings.Index(text, opener)
	if start < 0 {
		t.Fatalf("Caddyfile has no %q block", strings.TrimSpace(opener))
	}
	depth := 0
	for i := start; i < len(text); i++ {
		switch text[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return text[start : i+1]
			}
		}
	}
	t.Fatalf("unterminated %q block", strings.TrimSpace(opener))
	return ""
}

// credentialHeaders lists every X-...-Token request header the server reads.
func credentialHeaders(t *testing.T) map[string]bool {
	t.Helper()
	pattern := regexp.MustCompile(`Header\.Get\("(X-[A-Za-z-]+-Token)"\)`)
	headers := map[string]bool{}
	root := filepath.Join("..", "..", "internal")
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return err
		}
		source, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, match := range pattern.FindAllSubmatch(source, -1) {
			headers[string(match[1])] = true
		}
		return nil
	})
	if err != nil {
		t.Fatalf("scan server sources: %v", err)
	}
	return headers
}
