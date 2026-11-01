// Package mlswire checks the structure of RFC 9420 (MLS 1.0) objects that the
// server stores for clients. It only parses: it verifies no signature, no
// credential binding and no lifetime against the clock.
package mlswire

import "errors"

// Key-package size bounds, the transport limits the server and the crypto
// core share (crypto/rust/src/lib.rs MIN_KEY_PACKAGE_BYTES and
// MAX_KEY_PACKAGE_BYTES).
const (
	MinKeyPackageBytes = 64
	MaxKeyPackageBytes = 48 << 10
)

const (
	protocolVersionMLS10 = 0x0001
	// cipherSuiteX25519AES128Ed25519 is
	// MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519, the only suite clients
	// use (crypto/rust/src/mls.rs CIPHERSUITE) and the only one the server
	// accepts for published key packages.
	cipherSuiteX25519AES128Ed25519 = 0x0001
	credentialTypeBasic            = 0x0001
	leafNodeSourceKeyPackage       = 1
	// For the suite above: X25519 HPKE keys, Ed25519 keys and signatures.
	hpkePublicKeyBytes    = 32
	signaturePublicBytes  = 32
	signatureBytes        = 64
	lifetimeBytes         = 16 // not_before and not_after, uint64 each
	capabilityListsInLeaf = 5  // versions, cipher_suites, extensions, proposals, credentials
)

// ErrInvalidKeyPackage reports bytes that are not one well-formed KeyPackage.
var ErrInvalidKeyPackage = errors.New("invalid MLS key package")

// ValidateKeyPackage accepts exactly one RFC 9420 section 10 KeyPackage in
// the encoding clients upload: the bare TLS serialization that
// MlsDevice::create_key_package (crypto/rust/src/mls.rs) returns from
// KeyPackage::tls_serialize_detached, with no MLSMessage wrapper.
//
// It checks the protocol version (mls10), the cipher suite (0x0001), the
// key and signature sizes of that suite, a basic credential with a
// non-empty identity, a leaf node whose source is key_package with its
// lifetime, well-formed extension lists without duplicate types, minimal
// variable-length vector encodings (section 2.1.2), and that nothing
// follows the signature. Extension and capability values are not
// allowlisted, so GREASE and unknown values pass. Signatures and the
// credential-to-signing-key binding are not verified (plan question
// section-255217d2d387fd53976689b2/Q-1).
func ValidateKeyPackage(b []byte) error {
	if len(b) < MinKeyPackageBytes || len(b) > MaxKeyPackageBytes {
		return ErrInvalidKeyPackage
	}
	r := reader{data: b, ok: true}
	if r.uint16() != protocolVersionMLS10 || r.uint16() != cipherSuiteX25519AES128Ed25519 {
		return ErrInvalidKeyPackage
	}
	if initKey := r.vector(); !r.ok || len(initKey) != hpkePublicKeyBytes {
		return ErrInvalidKeyPackage
	}
	if !readLeafNode(&r) {
		return ErrInvalidKeyPackage
	}
	if extensions := r.vector(); !r.ok || !validExtensions(extensions) {
		return ErrInvalidKeyPackage
	}
	if signature := r.vector(); !r.ok || len(signature) != signatureBytes || len(r.data) != 0 {
		return ErrInvalidKeyPackage
	}
	return nil
}

// readLeafNode reads one RFC 9420 section 7.2 LeafNode whose source is
// key_package.
func readLeafNode(r *reader) bool {
	if key := r.vector(); !r.ok || len(key) != hpkePublicKeyBytes {
		return false
	}
	if key := r.vector(); !r.ok || len(key) != signaturePublicBytes {
		return false
	}
	if r.uint16() != credentialTypeBasic {
		return false
	}
	if identity := r.vector(); !r.ok || len(identity) == 0 {
		return false
	}
	for i := 0; i < capabilityListsInLeaf; i++ {
		// Each list holds uint16 values.
		if list := r.vector(); !r.ok || len(list)%2 != 0 {
			return false
		}
	}
	if r.uint8() != leafNodeSourceKeyPackage {
		return false
	}
	r.take(lifetimeBytes)
	if extensions := r.vector(); !r.ok || !validExtensions(extensions) {
		return false
	}
	signature := r.vector()
	return r.ok && len(signature) == signatureBytes
}

// validExtensions reports whether b is a sequence of Extension structs
// (uint16 type, opaque data<V>) with no type repeated.
func validExtensions(b []byte) bool {
	r := reader{data: b, ok: true}
	seen := make(map[uint16]struct{})
	for r.ok && len(r.data) > 0 {
		extensionType := r.uint16()
		r.vector()
		if _, repeated := seen[extensionType]; repeated {
			return false
		}
		seen[extensionType] = struct{}{}
	}
	return r.ok
}

// reader reads TLS presentation-language values. Once a read runs past the
// end or meets a malformed length, ok is false and every later read yields
// zero values.
type reader struct {
	data []byte
	ok   bool
}

func (r *reader) take(n int) []byte {
	if !r.ok || n < 0 || n > len(r.data) {
		r.ok = false
		return nil
	}
	out := r.data[:n]
	r.data = r.data[n:]
	return out
}

func (r *reader) uint8() uint8 {
	b := r.take(1)
	if !r.ok {
		return 0
	}
	return b[0]
}

func (r *reader) uint16() uint16 {
	b := r.take(2)
	if !r.ok {
		return 0
	}
	return uint16(b[0])<<8 | uint16(b[1])
}

// vector reads an RFC 9420 section 2.1.2 variable-length vector: a length
// in 1, 2 or 4 bytes whose top two bits give the size (prefix 0b11 is
// invalid), then that many bytes. A length encoded in more bytes than it
// needs is malformed.
func (r *reader) vector() []byte {
	first := r.uint8()
	if !r.ok {
		return nil
	}
	length := int(first & 0x3f)
	switch first >> 6 {
	case 0:
	case 1:
		rest := r.take(1)
		if !r.ok {
			return nil
		}
		length = length<<8 | int(rest[0])
		if length < 1<<6 {
			r.ok = false
			return nil
		}
	case 2:
		rest := r.take(3)
		if !r.ok {
			return nil
		}
		length = length<<24 | int(rest[0])<<16 | int(rest[1])<<8 | int(rest[2])
		if length < 1<<14 {
			r.ok = false
			return nil
		}
	default:
		r.ok = false
		return nil
	}
	return r.take(length)
}
