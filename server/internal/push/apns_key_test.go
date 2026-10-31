package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"strings"
	"testing"
)

// APNs signs with ES256, which is P-256 only. Another curve is refused when
// the provider is built, in both key encodings, and signing never slices
// with a negative index (VAL-235).
func TestAPNsRejectsKeysThatAreNotP256(t *testing.T) {
	for name, curve := range map[string]elliptic.Curve{
		"P-224": elliptic.P224(), "P-384": elliptic.P384(), "P-521": elliptic.P521(),
	} {
		key, err := ecdsa.GenerateKey(curve, rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		der, err := x509.MarshalECPrivateKey(key)
		if err != nil {
			t.Fatal(err)
		}
		sec1 := string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}))
		for encoding, pemKey := range map[string]string{"PKCS #8": pkcs8PEM(t, key), "SEC 1": sec1} {
			config := APNsConfig{TeamID: "TEAM", KeyID: "KEY1", BundleID: "org.veritra.app", PrivateKey: pemKey}
			if _, err := NewAPNsProvider(config); err == nil || !strings.Contains(err.Error(), "P-256") {
				t.Errorf("%s %s key: err=%v, want a P-256 error", name, encoding, err)
			}
		}
	}
	for _, curve := range []elliptic.Curve{elliptic.P384(), elliptic.P521()} {
		key, err := ecdsa.GenerateKey(curve, rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		// A direct sign must report the oversized signature, not panic.
		var signErr error
		func() {
			defer func() {
				if recovered := recover(); recovered != nil {
					t.Errorf("signing with a %s key panicked: %v", curve.Params().Name, recovered)
				}
			}()
			_, signErr = signECDSAJWT(key, map[string]any{"alg": "ES256"}, map[string]any{"iss": "TEAM"})
		}()
		if signErr == nil {
			t.Errorf("signing with a %s key returned no error", curve.Params().Name)
		}
	}
}
