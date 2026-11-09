// Package c7vector holds no production code. Its tests re-derive the C7
// (channel history for new members) vectors in testing/vectors from their
// inputs with the Go standard library alone, so the Rust core, the Dart app
// logic and Go agree on every byte and on every row of the ordering table.
// Design: docs/designs/C7-channel-history.md revision 7. The server never
// sees keys, records or the history setting; this package must stay free of
// server dependencies.
package c7vector
