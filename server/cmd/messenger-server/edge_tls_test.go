package main

import (
	"regexp"
	"testing"
)

// The Kubernetes edge (Traefik's TLSOption with X25519MLKEM768, X25519 and
// P-256) lives in the owner's infra repository with the rest of the cluster
// configuration, whose bootstrap/check-rules.py checks the curve names
// against Traefik's table (docs/operations.md, "Post-quantum TLS").

// Caddy (Compose) needs no setting: from v2.10.0 its default list is
// X25519MLKEM768, X25519, P-256, used whenever the Caddyfile sets no curves.
func TestCaddyKeepsItsPostQuantumDefault(t *testing.T) {
	if regexp.MustCompile(`(?m)^\s*curves\b`).MatchString(readDeployFile(t, "caddy/Caddyfile")) {
		t.Fatal("the Caddyfile overrides curves; keep X25519MLKEM768 first or drop the override")
	}
	image := regexp.MustCompile(`image: caddy:2\.(\d+)\.`).FindStringSubmatch(readDeployFile(t, "docker-compose.yml"))
	if image == nil {
		t.Fatal("docker-compose.yml has no caddy:2.x image")
	}
	if minor := image[1]; len(minor) < 2 || minor < "10" {
		t.Fatalf("caddy 2.%s predates the post-quantum default (2.10.0)", minor)
	}
}
