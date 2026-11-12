package sealedsender

// CommitSize is the size of a C6 franking commitment, which a sealed post
// carries beside its ciphertext as for an identified one.
//
// A sealed message's proof of sender is designated-verifier franking
// (docs/crypto.md, "Franking a sealed message"): tags only instance owners
// can check, inside the MLS ciphertext. The server never sees or checks
// them, so nothing here does; frank_dv_test.go checks the shared vector
// with an independent X25519 implementation.
const CommitSize = 32
