package mlswire_test

import (
	"bytes"
	"encoding/binary"
	"testing"

	"private-messenger/server/internal/mlswire"
	"private-messenger/server/internal/mlswire/mlswiretest"
)

func TestValidateKeyPackageAcceptsClientAndSyntheticPackages(t *testing.T) {
	if err := mlswire.ValidateKeyPackage(mlswiretest.OpenMLSKeyPackage()); err != nil {
		t.Fatalf("client-made OpenMLS key package rejected: %v", err)
	}
	for i := 0; i < 100; i++ {
		if err := mlswire.ValidateKeyPackage(mlswiretest.KeyPackage()); err != nil {
			t.Fatalf("synthetic key package rejected: %v", err)
		}
	}
	if err := mlswire.ValidateKeyPackage(build(nil)); err != nil {
		t.Fatalf("test builder's default package rejected: %v", err)
	}
}

func TestValidateKeyPackageRejectsNonPackages(t *testing.T) {
	fixture := mlswiretest.OpenMLSKeyPackage()
	cases := map[string][]byte{
		"empty":            nil,
		"64 zero bytes":    make([]byte, 64),
		"4096 zero bytes":  make([]byte, 4096),
		"placeholder text": bytes.Repeat([]byte("owner-key-package"), 8),
		"trailing byte":    append(append([]byte(nil), fixture...), 0),
		"doubled":          append(append([]byte(nil), fixture...), fixture...),
		"over 48 KiB":      append(append([]byte(nil), fixture...), make([]byte, 48<<10)...),
	}
	for name, value := range cases {
		if err := mlswire.ValidateKeyPackage(value); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	for n := 0; n < len(fixture); n++ {
		if err := mlswire.ValidateKeyPackage(fixture[:n]); err == nil {
			t.Fatalf("package truncated to %d of %d bytes accepted", n, len(fixture))
		}
	}
}

func TestValidateKeyPackageRejectsMalformedFields(t *testing.T) {
	fixture := mlswiretest.OpenMLSKeyPackage()
	// fixture[4] is the one-byte length (32) of init_key.
	if fixture[4] != 0x20 {
		t.Fatalf("fixture layout changed: init_key length byte %#x", fixture[4])
	}
	splice := func(length []byte) []byte {
		out := append([]byte(nil), fixture[:4]...)
		out = append(out, length...)
		return append(out, fixture[5:]...)
	}
	cases := map[string][]byte{
		"version 2":                  build(func(k *keyPackage) { k.version = 2 }),
		"cipher suite 3":             build(func(k *keyPackage) { k.suite = 3 }),
		"short init key":             build(func(k *keyPackage) { k.initKey = make([]byte, 31) }),
		"long encryption key":        build(func(k *keyPackage) { k.encryptionKey = make([]byte, 33) }),
		"short signature key":        build(func(k *keyPackage) { k.signatureKey = make([]byte, 31) }),
		"x509 credential":            build(func(k *keyPackage) { k.credentialType = 2 }),
		"empty identity":             build(func(k *keyPackage) { k.identity = nil }),
		"odd capability list":        build(func(k *keyPackage) { k.capabilities[1] = []byte{0, 1, 0} }),
		"update leaf source":         build(func(k *keyPackage) { k.leafSource = 2 }),
		"short leaf signature":       build(func(k *keyPackage) { k.leafSignature = make([]byte, 63) }),
		"long package signature":     build(func(k *keyPackage) { k.signature = make([]byte, 65) }),
		"truncated extension":        build(func(k *keyPackage) { k.extensions = []byte{0x00} }),
		"duplicate extension":        build(func(k *keyPackage) { k.extensions = []byte{0, 10, 0, 0, 10, 0} }),
		"duplicate leaf extension":   build(func(k *keyPackage) { k.leafExtensions = []byte{0, 3, 1, 9, 0, 3, 0} }),
		"two-byte length for 32":     splice([]byte{0x40, 0x20}),
		"four-byte length for 32":    splice([]byte{0x80, 0, 0, 0x20}),
		"length prefix 0b11":         splice([]byte{0xc0, 0, 0, 0, 0, 0, 0, 0x20}),
		"length past end of package": splice([]byte{0x7f, 0xff}),
	}
	for name, value := range cases {
		if err := mlswire.ValidateKeyPackage(value); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	// Unknown and GREASE values in extensions and capabilities still pass.
	grease := build(func(k *keyPackage) {
		k.capabilities[2] = []byte{0x0a, 0x0a, 0xfa, 0xfa}
		k.extensions = []byte{0x0a, 0x0a, 0x00, 0xfa, 0xfa, 0x02, 0x01, 0x02}
		k.leafExtensions = []byte{0x00, 0x0a, 0x01, 0xff}
	})
	if err := mlswire.ValidateKeyPackage(grease); err != nil {
		t.Fatalf("package with unknown extension and capability values rejected: %v", err)
	}
}

// FuzzValidateKeyPackage checks that no input panics the parser and that
// whatever it accepts stops being accepted once a byte is added or removed.
func FuzzValidateKeyPackage(f *testing.F) {
	f.Add(mlswiretest.OpenMLSKeyPackage())
	f.Add(mlswiretest.KeyPackage())
	f.Add(build(nil))
	f.Add(make([]byte, 64))
	f.Fuzz(func(t *testing.T, b []byte) {
		if mlswire.ValidateKeyPackage(b) != nil {
			return
		}
		if mlswire.ValidateKeyPackage(append(append([]byte(nil), b...), 0)) == nil {
			t.Fatal("accepted package still accepted with a trailing byte")
		}
		if mlswire.ValidateKeyPackage(b[:len(b)-1]) == nil {
			t.Fatal("accepted package still accepted with its last byte removed")
		}
	})
}

type keyPackage struct {
	version, suite, credentialType uint16
	initKey, encryptionKey         []byte
	signatureKey, identity         []byte
	capabilities                   [5][]byte
	leafSource                     byte
	leafExtensions, leafSignature  []byte
	extensions, signature          []byte
}

// build encodes a key package field by field; edit changes the defaults,
// which form a valid package. Extension fields hold the already-encoded
// contents of the extensions vector.
func build(edit func(*keyPackage)) []byte {
	k := keyPackage{
		version: 1, suite: 1, credentialType: 1,
		initKey: make([]byte, 32), encryptionKey: make([]byte, 32), signatureKey: make([]byte, 32),
		identity:      []byte("identity"),
		capabilities:  [5][]byte{{0, 1}, {0, 1}, nil, nil, {0, 1}},
		leafSource:    1,
		leafSignature: make([]byte, 64), signature: make([]byte, 64),
	}
	if edit != nil {
		edit(&k)
	}
	var b []byte
	b = binary.BigEndian.AppendUint16(b, k.version)
	b = binary.BigEndian.AppendUint16(b, k.suite)
	b = vector(b, k.initKey)
	b = vector(b, k.encryptionKey)
	b = vector(b, k.signatureKey)
	b = binary.BigEndian.AppendUint16(b, k.credentialType)
	b = vector(b, k.identity)
	for _, list := range k.capabilities {
		b = vector(b, list)
	}
	b = append(b, k.leafSource)
	b = append(b, make([]byte, 16)...)
	b = vector(b, k.leafExtensions)
	b = vector(b, k.leafSignature)
	b = vector(b, k.extensions)
	return vector(b, k.signature)
}

func vector(b, value []byte) []byte {
	if len(value) >= 1<<6 {
		return append(append(b, 0x40|byte(len(value)>>8), byte(len(value))), value...)
	}
	return append(append(b, byte(len(value))), value...)
}
