// Package mlswiretest provides MLS key packages for tests and the load tool:
// a real one made by the client crypto core, and a builder for structurally
// valid, unsigned ones. Nothing here may be used to accept a key package.
package mlswiretest

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
)

// openMLSKeyPackageHex is one KeyPackage exactly as clients upload it.
//
// Provenance: printed by a scratch binary that called
// MlsDevice::new(b"acct_fixture", b"dev_fixture") and then
// MlsDevice::create_key_package (crypto/rust/src/mls.rs, which returns
// KeyPackage::tls_serialize_detached) from crypto/rust at commit 1a21ee2
// (OpenMLS 0.9.2, suite MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519), on
// 2026-11-01. Its lifetime runs to about 2027-01-30; the server does not
// check lifetimes, so the fixture does not expire for these tests.
const openMLSKeyPackageHex = "" +
	"0001000120decc25b15e79a8ac8bb53836e567b8c45df3dd2422d425546ae57f94ad437813" +
	"20cf6685159813328ee65e5f90143b29e109a93ee7f9de4f1115aa4b33afe1d210" +
	"20c03f695be2a74eb7495649e583a9e0fae097fc1b713fc6f0aee7fc1f95bb6db4" +
	"00011c01000c616363745f66697874757265000b6465765f66697874757265" +
	"02000106000100020003000002000101000000006ae70a64000000006b55d674" +
	"00" +
	"40404a4919181459589ae8a5a78df3f2934332255c296e06a623c488ea4e8cb0a5" +
	"5106432cbe8d09dadfa0caf620bede7fcbc8fa494150c271b2c42accf51a67b20f" +
	"00" +
	"4040c6257fe38abed39740e5a3a6325cd413142ca2026366701e0efb00fa153ac3" +
	"b361342e7fd6802cf9e349512239f41d847f3ddeb959a5ec0ac222a71c055cc80f"

// OpenMLSKeyPackage returns a copy of the client-made key package above.
func OpenMLSKeyPackage() []byte {
	b, err := hex.DecodeString(openMLSKeyPackageHex)
	if err != nil {
		panic(err)
	}
	return b
}

// KeyPackage returns a new KeyPackage with random keys and random bytes in
// place of both signatures. It has the client's layout (mls10, suite
// 0x0001, a basic credential in the client's identity encoding, the
// client's capabilities) and parses as a key package, but no MLS client
// would accept it: nothing in it is signed.
func KeyPackage() []byte {
	identity := []byte{0x01}
	for _, part := range [][]byte{randomBytes(16), randomBytes(16)} {
		identity = binary.BigEndian.AppendUint16(identity, uint16(len(part)))
		identity = append(identity, part...)
	}
	var b []byte
	b = binary.BigEndian.AppendUint16(b, 0x0001) // version mls10
	b = binary.BigEndian.AppendUint16(b, 0x0001) // cipher suite
	b = appendVector(b, randomBytes(32))         // init_key
	// LeafNode
	b = appendVector(b, randomBytes(32))         // encryption_key
	b = appendVector(b, randomBytes(32))         // signature_key
	b = binary.BigEndian.AppendUint16(b, 0x0001) // credential type basic
	b = appendVector(b, identity)
	b = appendVector(b, []byte{0x00, 0x01})                         // versions
	b = appendVector(b, []byte{0x00, 0x01, 0x00, 0x02, 0x00, 0x03}) // cipher suites
	b = appendVector(b, nil)                                        // extensions
	b = appendVector(b, nil)                                        // proposals
	b = appendVector(b, []byte{0x00, 0x01})                         // credentials
	b = append(b, 0x01)                                             // leaf_node_source key_package
	b = binary.BigEndian.AppendUint64(b, 0)                         // not_before
	b = binary.BigEndian.AppendUint64(b, 1<<62)                     // not_after
	b = appendVector(b, nil)                                        // leaf extensions
	b = appendVector(b, randomBytes(64))                            // leaf signature
	// KeyPackage
	b = appendVector(b, nil)             // extensions
	b = appendVector(b, randomBytes(64)) // signature
	return b
}

// appendVector appends an RFC 9420 variable-length vector with the shortest
// length encoding.
func appendVector(b, value []byte) []byte {
	n := len(value)
	switch {
	case n < 1<<6:
		b = append(b, byte(n))
	case n < 1<<14:
		b = append(b, 0x40|byte(n>>8), byte(n))
	default:
		b = append(b, 0x80|byte(n>>24), byte(n>>16), byte(n>>8), byte(n))
	}
	return append(b, value...)
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}
