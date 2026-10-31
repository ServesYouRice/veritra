package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

// traefikCurveIDs is Traefik's table of curvePreferences names, copied from
// traefik/traefik v3.7.13 pkg/tls/certificate.go (CurveIDs), the version
// k3s v1.34.12 bundles. Traefik refuses every TLS connection to a route
// whose TLSOption names a curve outside this table, so an unknown name here
// is a broken edge, not a fallback. The MLKEM names exist from v3.5.0.
var traefikCurveIDs = map[string]tls.CurveID{
	"secp256r1":          tls.CurveP256,
	"CurveP256":          tls.CurveP256,
	"secp384r1":          tls.CurveP384,
	"CurveP384":          tls.CurveP384,
	"secp521r1":          tls.CurveP521,
	"CurveP521":          tls.CurveP521,
	"x25519":             tls.X25519,
	"X25519":             tls.X25519,
	"x25519mlkem768":     tls.X25519MLKEM768,
	"X25519MLKEM768":     tls.X25519MLKEM768,
	"secp256r1mlkem768":  tls.SecP256r1MLKEM768,
	"SecP256r1MLKEM768":  tls.SecP256r1MLKEM768,
	"secp384r1mlkem1024": tls.SecP384r1MLKEM1024,
	"SecP384r1MLKEM1024": tls.SecP384r1MLKEM1024,
}

// edgeCurves reads curvePreferences from the k3s TLSOption and maps each
// name through Traefik's table.
func edgeCurves(t *testing.T) []tls.CurveID {
	t.Helper()
	option := readDeployFile(t, "kubernetes/base/tlsoption.yaml")
	for _, want := range []string{"kind: TLSOption", "  name: veritra\n", "  minVersion: VersionTLS12\n"} {
		if !strings.Contains(option, want) {
			t.Fatalf("tlsoption.yaml lacks %q", want)
		}
	}
	block := regexp.MustCompile(`(?m)^  curvePreferences:\n((?:    - \S+\n)+)`).FindStringSubmatch(option)
	if block == nil {
		t.Fatal("tlsoption.yaml has no curvePreferences list")
	}
	var curves []tls.CurveID
	for _, line := range strings.Split(strings.TrimSpace(block[1]), "\n") {
		name := strings.TrimPrefix(strings.TrimSpace(line), "- ")
		id, ok := traefikCurveIDs[name]
		if !ok {
			t.Fatalf("curve %q is not in Traefik's table; Traefik would refuse TLS on the route", name)
		}
		curves = append(curves, id)
	}
	return curves
}

func TestK3sEdgePrefersPostQuantumWithClassicalFallback(t *testing.T) {
	curves := edgeCurves(t)
	want := []tls.CurveID{tls.X25519MLKEM768, tls.X25519, tls.CurveP256}
	if !slices.Equal(curves, want) {
		t.Fatalf("curvePreferences = %v, want %v", curves, want)
	}
	route := readDeployFile(t, "kubernetes/base/ingressroute.yaml")
	if !strings.Contains(route, "    options:\n      name: veritra\n") {
		t.Fatal("the IngressRoute does not use the veritra TLSOption")
	}
	if !strings.Contains(readDeployFile(t, "kubernetes/base/kustomization.yaml"), "  - tlsoption.yaml\n") {
		t.Fatal("kustomization.yaml does not include tlsoption.yaml")
	}

	// Traefik hands the list to Go's crypto/tls; check what it negotiates.
	server := &tls.Config{
		Certificates:     []tls.Certificate{selfSignedCertificate(t)},
		MinVersion:       tls.VersionTLS12,
		CurvePreferences: curves,
	}
	cases := []struct {
		name   string
		client *tls.Config
		want   tls.CurveID
	}{
		{"current client", &tls.Config{}, tls.X25519MLKEM768},
		{"classical X25519 only", &tls.Config{CurvePreferences: []tls.CurveID{tls.X25519}}, tls.X25519},
		{"P-256 only", &tls.Config{CurvePreferences: []tls.CurveID{tls.CurveP256}}, tls.CurveP256},
		{"X25519 preferred, hybrid offered", &tls.Config{CurvePreferences: []tls.CurveID{tls.X25519, tls.X25519MLKEM768}}, tls.X25519MLKEM768},
		{"TLS 1.2", &tls.Config{MaxVersion: tls.VersionTLS12}, tls.X25519},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tc.client.InsecureSkipVerify = true // the test's own self-signed certificate
			if got := handshakeCurve(t, server, tc.client); got != tc.want {
				t.Fatalf("negotiated %v, want %v", got, tc.want)
			}
		})
	}
}

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

func handshakeCurve(t *testing.T, server, client *tls.Config) tls.CurveID {
	t.Helper()
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()
	deadline := time.Now().Add(10 * time.Second)
	_ = serverConn.SetDeadline(deadline)
	_ = clientConn.SetDeadline(deadline)
	serverSide := tls.Server(serverConn, server)
	done := make(chan error, 1)
	go func() { done <- serverSide.Handshake() }()
	clientSide := tls.Client(clientConn, client)
	if err := clientSide.Handshake(); err != nil {
		t.Fatalf("client handshake: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("server handshake: %v", err)
	}
	return clientSide.ConnectionState().CurveID
}

func selfSignedCertificate(t *testing.T) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "veritra.example.com"},
		DNSNames:     []string{"veritra.example.com"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}
