package attest

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNoneNeverReturnsEvidence(t *testing.T) {
	p, err := New("")
	if err != nil || p.Kind() != "none" {
		t.Fatalf("New(\"\") = %v, %v", p, err)
	}
	ev, err := p.Report(context.Background(), [64]byte{})
	if !errors.Is(err, ErrNotConfigured) || len(ev.Report) != 0 {
		t.Fatalf("none returned %+v, %v", ev, err)
	}
	if _, err := New("sev-snp-please"); err == nil {
		t.Fatal("unknown mode accepted")
	}
}

func TestUserDataBindsNonceAndKey(t *testing.T) {
	var nonce, key [32]byte
	nonce[0], key[0] = 1, 2
	want := sha512.Sum512(append(append([]byte(UserDataLabel), nonce[:]...), key[:]...))
	if got := UserData(nonce, key); got != want {
		t.Fatal("user data does not follow the documented hash")
	}
	other := key
	other[1] = 9
	if UserData(nonce, other) == UserData(nonce, key) {
		t.Fatal("user data ignores the TLS key")
	}
}

func TestConfigfsMissingRootIsNotConfigured(t *testing.T) {
	_, err := ConfigfsTSM{Root: filepath.Join(t.TempDir(), "absent")}.Report(context.Background(), [64]byte{})
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("err = %v", err)
	}
}

func TestTLSKeyHashFromCertFile(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "t"}, NotBefore: time.Now(), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "cert.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	got, err := TLSKeyHashFromCertFile(path)
	if err != nil || got != sha256.Sum256(cert.RawSubjectPublicKeyInfo) {
		t.Fatalf("hash = %x, err = %v", got, err)
	}
	bad := filepath.Join(t.TempDir(), "bad.pem")
	_ = os.WriteFile(bad, []byte("nope"), 0o600)
	if _, err := TLSKeyHashFromCertFile(bad); err == nil {
		t.Fatal("garbage accepted")
	}
}
