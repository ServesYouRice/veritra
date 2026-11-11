// Package attest is the L3 proof hook. It is switched off: the only provider
// built in by default is None. A provider asks the platform for a signed
// report that binds a caller nonce and the server's TLS key. Nothing here
// makes a trust decision, and nothing here claims the operator cannot see
// metadata: an attested server is still run by its operator.
package attest

import (
	"context"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ErrNotConfigured is returned while attestation is off or the platform has
// no report interface.
var ErrNotConfigured = errors.New("attestation not configured")

// UserDataLabel prefixes the hashed report user data.
const UserDataLabel = "veritra-attest-v1"

// Evidence is what a provider returns. Report is the platform's raw bytes.
type Evidence struct {
	Kind   string
	Report []byte
}

// Provider produces platform evidence for a nonce.
type Provider interface {
	Kind() string
	Report(ctx context.Context, userData [64]byte) (Evidence, error)
}

// UserData is SHA-512("veritra-attest-v1" || nonce || tlsKeyHash). A report
// relayed from another machine fails because the verifier recomputes this
// from the key of the certificate it actually connected to.
func UserData(nonce [32]byte, tlsKeyHash [32]byte) [64]byte {
	h := sha512.New()
	h.Write([]byte(UserDataLabel))
	h.Write(nonce[:])
	h.Write(tlsKeyHash[:])
	var out [64]byte
	copy(out[:], h.Sum(nil))
	return out
}

// None is the default provider. It never returns evidence.
type None struct{}

func (None) Kind() string { return "none" }
func (None) Report(context.Context, [64]byte) (Evidence, error) {
	return Evidence{}, ErrNotConfigured
}

// TLSKeyHashFromCertFile returns SHA-256 of the DER SubjectPublicKeyInfo of
// the first certificate in a PEM file.
func TLSKeyHashFromCertFile(path string) ([32]byte, error) {
	var zero [32]byte
	data, err := os.ReadFile(path)
	if err != nil {
		return zero, err
	}
	for {
		var block *pem.Block
		block, data = pem.Decode(data)
		if block == nil {
			return zero, errors.New("attest: no certificate found in PEM file")
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return zero, fmt.Errorf("attest: parse certificate: %w", err)
		}
		return sha256.Sum256(cert.RawSubjectPublicKeyInfo), nil
	}
}

// DefaultConfigfsRoot is the kernel's TSM report directory (Linux 6.7+).
const DefaultConfigfsRoot = "/sys/kernel/config/tsm/report"

// ConfigfsTSM reads reports through the kernel's configfs-tsm interface, so
// SEV-SNP and TDX share one code path and no vendor SDK is needed.
type ConfigfsTSM struct {
	// Root is the report directory; empty means DefaultConfigfsRoot.
	Root string
}

func (ConfigfsTSM) Kind() string { return "configfs-tsm" }

func (c ConfigfsTSM) Report(ctx context.Context, userData [64]byte) (Evidence, error) {
	root := c.Root
	if root == "" {
		root = DefaultConfigfsRoot
	}
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		return Evidence{}, ErrNotConfigured
	}
	if err := ctx.Err(); err != nil {
		return Evidence{}, err
	}
	// One entry per request; the kernel serialises reads of a report entry.
	dir, err := os.MkdirTemp(root, "veritra-")
	if err != nil {
		// configfs makes entries with mkdir, which MkdirTemp does too.
		return Evidence{}, fmt.Errorf("attest: create report entry: %w", err)
	}
	defer os.Remove(dir)
	if err := os.WriteFile(filepath.Join(dir, "inblob"), userData[:], 0o200); err != nil {
		return Evidence{}, fmt.Errorf("attest: write inblob: %w", err)
	}
	report, err := os.ReadFile(filepath.Join(dir, "outblob"))
	if err != nil {
		return Evidence{}, fmt.Errorf("attest: read outblob: %w", err)
	}
	provider, _ := os.ReadFile(filepath.Join(dir, "provider"))
	kind := strings.TrimSpace(string(provider))
	if kind == "" {
		kind = c.Kind()
	}
	return Evidence{Kind: kind, Report: report}, nil
}

// New returns the provider for a switch value: "" or "none", or
// "configfs-tsm". Anything else is an error so a typo cannot look like on.
func New(mode string) (Provider, error) {
	switch strings.TrimSpace(mode) {
	case "", "none":
		return None{}, nil
	case "configfs-tsm":
		return ConfigfsTSM{}, nil
	}
	return nil, fmt.Errorf("attest: unknown mode %q (use none or configfs-tsm)", mode)
}
