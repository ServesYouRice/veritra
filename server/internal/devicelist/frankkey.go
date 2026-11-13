package devicelist

import (
	"bytes"
	"encoding/hex"
)

// X25519 franking-key screening for format 2 (L2-3). It matches the clients'
// check in the crypto core (crypto/rust/src/l2_frank.rs check_public): 32
// bytes, canonical (bit 255 clear, u < p) and not a point of low order.

// lowOrderFrankKeys are the canonical u-coordinates of the X25519 points of
// low order (0, 1, the two of order 8, and p-1). Any of them gives the same
// shared secret with every private key. Non-canonical spellings of these
// (p, p+1 and the forms with bit 255 set) fail the canonical check first.
var lowOrderFrankKeys = func() [][]byte {
	hexKeys := []string{
		"0000000000000000000000000000000000000000000000000000000000000000",
		"0100000000000000000000000000000000000000000000000000000000000000",
		"e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
		"5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
		"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	}
	keys := make([][]byte, len(hexKeys))
	for i, value := range hexKeys {
		key, err := hex.DecodeString(value)
		if err != nil || len(key) != keySize {
			panic("bad low-order key")
		}
		keys[i] = key
	}
	return keys
}()

// fieldPrime is p = 2^255 - 19, little-endian.
var fieldPrime = func() []byte {
	p, err := hex.DecodeString("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
	if err != nil {
		panic("bad prime")
	}
	return p
}()

// ValidFrankKey reports whether key is a franking key a list may carry.
func ValidFrankKey(key []byte) bool {
	if len(key) != keySize || key[31]&0x80 != 0 {
		return false
	}
	// Compare little-endian u with p from the most significant byte.
	below := false
	for i := keySize - 1; i >= 0; i-- {
		if key[i] != fieldPrime[i] {
			below = key[i] < fieldPrime[i]
			break
		}
	}
	if !below {
		return false
	}
	for _, low := range lowOrderFrankKeys {
		if bytes.Equal(key, low) {
			return false
		}
	}
	return true
}
