package devicelist

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"math/big"
)

// Ed25519 public-key screening shared by the account recovery key (K0) and the
// keys of an approved-device list (L1). It matches the clients' check in the
// crypto core (crypto/rust/src/l1.rs check_key): a canonical, valid, non-weak
// point.

// SmallOrderKeys are the canonical encodings of the eight Ed25519
// points of small order. A signature for any message can be forged under
// them without a secret key, so none may be a recovery auth key.
var SmallOrderKeys = func() [][]byte {
	hexKeys := []string{
		"0100000000000000000000000000000000000000000000000000000000000000",
		"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
		"0000000000000000000000000000000000000000000000000000000000000000",
		"0000000000000000000000000000000000000000000000000000000000000080",
		"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
		"26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
		"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
		"c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
	}
	keys := make([][]byte, len(hexKeys))
	for i, value := range hexKeys {
		key, err := hex.DecodeString(value)
		if err != nil || len(key) != ed25519.PublicKeySize {
			panic("bad small-order key")
		}
		keys[i] = key
	}
	return keys
}()

var (
	ed25519FieldPrime = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 255), big.NewInt(19))
	// ed25519CurveD is -121665/121666 mod p.
	ed25519CurveD = func() *big.Int {
		d := new(big.Int).ModInverse(big.NewInt(121666), ed25519FieldPrime)
		d.Mul(d, big.NewInt(-121665))
		return d.Mod(d, ed25519FieldPrime)
	}()
)

// ValidPublicKey reports whether key is a canonical encoding of an
// Ed25519 point on the curve that is not of small order. The big-integer
// check is for the rare places a key is accepted: a recovery key, and the keys
// of an approved-device list version (L1: a key the clients' strict verifier
// would refuse can never sign for its device).
func ValidPublicKey(key []byte) bool {
	if len(key) != ed25519.PublicKeySize {
		return false
	}
	for _, small := range SmallOrderKeys {
		if bytes.Equal(key, small) {
			return false
		}
	}
	littleEndian := bytes.Clone(key)
	sign := littleEndian[31] >> 7
	littleEndian[31] &= 0x7f
	bigEndian := make([]byte, len(littleEndian))
	for i, b := range littleEndian {
		bigEndian[len(littleEndian)-1-i] = b
	}
	y := new(big.Int).SetBytes(bigEndian)
	if y.Cmp(ed25519FieldPrime) >= 0 {
		return false
	}
	// x^2 = (y^2 - 1) / (d*y^2 + 1) must have a square root.
	y2 := new(big.Int).Mul(y, y)
	y2.Mod(y2, ed25519FieldPrime)
	u := new(big.Int).Sub(y2, big.NewInt(1))
	u.Mod(u, ed25519FieldPrime)
	v := new(big.Int).Mul(ed25519CurveD, y2)
	v.Add(v, big.NewInt(1))
	v.Mod(v, ed25519FieldPrime)
	vInverse := new(big.Int).ModInverse(v, ed25519FieldPrime)
	if vInverse == nil {
		return false
	}
	x2 := u.Mul(u, vInverse)
	x2.Mod(x2, ed25519FieldPrime)
	x := new(big.Int).ModSqrt(x2, ed25519FieldPrime)
	if x == nil {
		return false
	}
	// x = 0 has only the positive encoding.
	return x.Sign() != 0 || sign == 0
}
