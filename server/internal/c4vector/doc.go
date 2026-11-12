// Package c4vector holds no production code. Its tests re-derive the C4
// leave proof in the commit vector (testing/vectors/c4-leave-proof-v1.json,
// crypto ABI 24) from its inputs with the Go standard library alone, so the
// Rust core, the Dart app and Go agree on LeaveTBS, its signing content and
// the VCL1 commit AAD byte for byte. The server never parses the AAD (it
// travels inside the MLS ciphertext's authenticated data and the server
// stores ciphertext only); this package must stay free of server
// dependencies. Design: docs/crypto.md, "C4 leave proof in the commit".
package c4vector
