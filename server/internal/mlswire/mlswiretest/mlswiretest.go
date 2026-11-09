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

// openMLSKeyPackageABI20Hex is one KeyPackage made by an ABI 20 client
// (C4): the same layout as openMLSKeyPackageHex, but the leaf's extension
// capabilities list the role-record GroupContext extension 0xF0C4, which
// every ABI 20 key package advertises. The server must accept it.
//
// Provenance: printed by a scratch example that called
// MlsDevice::new(b"acct_fixture", b"dev_fixture") and then
// MlsDevice::create_key_package (crypto/rust/src/mls.rs) on branch
// agent/c4-abi (ABI 20, OpenMLS 0.9.2), on 2026-11-08. Its lifetime runs to
// about 2027-02-06; the server does not check lifetimes.
const openMLSKeyPackageABI20Hex = "" +
	"0001000120cdedfd4453906d3dd6bfb07c9fc62276276d675480945611b89f85515d0a" +
	"667c20d67f226821a1477a8e7c4275d77d5a3264a73d554e2b1c688040dcb97bf4883e" +
	"20921dd1d7aa4ab02e75559b97d3440c3515397fe5ad7e12bdb3a1a6de1f9d33f40001" +
	"1c01000c616363745f66697874757265000b6465765f66697874757265020001060001" +
	"0002000302f0c40002000101000000006af02c6e000000006b5ef87e004040809809d3" +
	"f473ad9760d941fd2162a4335838d552d78423b4d91ff0feb380809154339082b70c75" +
	"f8390bbdb85b42f0d3e8ea5edf4361f3298fca767c28c77706004040ecef7704f05fef" +
	"2fcd6877a97fb68f1f8c8cacb6bf944da49b20db9b1bf6067a863af051da3dc5503413" +
	"f0f80ec68a99b26eb2d7feec3c22e6c3affffd0fcf0e"

// OpenMLSKeyPackageABI20 returns a copy of the ABI 20 client-made key
// package above.
func OpenMLSKeyPackageABI20() []byte {
	b, err := hex.DecodeString(openMLSKeyPackageABI20Hex)
	if err != nil {
		panic(err)
	}
	return b
}

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
	return KeyPackageWithSignatureKey(randomBytes(32))
}

// KeyPackageWithSignatureKey is [KeyPackage] whose leaf signature key is
// signatureKey (32 bytes), for tests of the L1 key-package gate.
func KeyPackageWithSignatureKey(signatureKey []byte) []byte {
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
	b = appendVector(b, signatureKey)            // signature_key
	b = binary.BigEndian.AppendUint16(b, 0x0001) // credential type basic
	b = appendVector(b, identity)
	b = appendVector(b, []byte{0x00, 0x01})                         // versions
	b = appendVector(b, []byte{0x00, 0x01, 0x00, 0x02, 0x00, 0x03}) // cipher suites
	b = appendVector(b, []byte{0xf0, 0xc4})                         // extensions: C4 role record (ABI 20)
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
