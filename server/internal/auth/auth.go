package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"sync"

	"golang.org/x/crypto/bcrypt"
)

var (
	ErrWeakPassword    = errors.New("password must be at least 12 characters")
	ErrPasswordTooLong = errors.New("password must be at most 72 bytes")
)

const (
	DefaultBcryptCost = 10
	MinBcryptCost     = 10
	MaxBcryptCost     = 15
)

func HashPassword(password string) (string, error) {
	return HashPasswordWithCost(password, DefaultBcryptCost)
}

func HashPasswordWithCost(password string, cost int) (string, error) {
	if len(password) < 12 {
		return "", ErrWeakPassword
	}
	// bcrypt silently truncates input beyond 72 bytes, so any entropy past
	// byte 72 (e.g. a long passphrase-manager secret) would be ignored. Reject
	// it explicitly rather than hash a silently-truncated password. len() on a
	// Go string is the byte count, which is exactly bcrypt's limit unit.
	if len(password) > 72 {
		return "", ErrPasswordTooLong
	}
	if cost < MinBcryptCost || cost > MaxBcryptCost {
		return "", errors.New("invalid bcrypt cost")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), cost)
	if err != nil {
		return "", err
	}
	return string(hash), nil
}

func VerifyPassword(hash, password string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

// dummyHash is generated once at startup with the same cost as real password
// hashes. VerifyPasswordOrDummy compares against it for non-existent accounts so
// the response time matches the populated path. It is initialized eagerly (not
// lazily) and panics on failure: if bcrypt cannot produce the hash we fail at
// startup rather than silently skipping the dummy compare and reopening the
// username-enumeration timing side-channel.
var dummyHash = mustGenerateDummyHash(DefaultBcryptCost)

var dummyHashes = struct {
	sync.Mutex
	byCost map[int][]byte
}{byCost: map[int][]byte{DefaultBcryptCost: dummyHash}}

func mustGenerateDummyHash(cost int) []byte {
	hash, err := bcrypt.GenerateFromPassword([]byte("veritra-timing-dummy"), cost)
	if err != nil {
		panic("auth: unable to generate dummy bcrypt hash: " + err.Error())
	}
	return hash
}

func dummyHashForCost(cost int) []byte {
	if cost < MinBcryptCost || cost > MaxBcryptCost {
		cost = DefaultBcryptCost
	}
	dummyHashes.Lock()
	defer dummyHashes.Unlock()
	if hash, ok := dummyHashes.byCost[cost]; ok {
		return hash
	}
	hash := mustGenerateDummyHash(cost)
	dummyHashes.byCost[cost] = hash
	return hash
}

// VerifyPasswordOrDummy verifies password against hash. When hash is empty
// (caller hit a non-existent account) it still performs a bcrypt comparison
// against a fixed dummy hash so the response time matches the populated path,
// closing a username-enumeration timing side-channel.
func VerifyPasswordOrDummy(hash, password string) bool {
	return VerifyPasswordOrDummyWithCost(hash, password, DefaultBcryptCost)
}

func VerifyPasswordOrDummyWithCost(hash, password string, cost int) bool {
	if hash == "" {
		_ = bcrypt.CompareHashAndPassword(dummyHashForCost(cost), []byte(password))
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

func NeedsPasswordRehash(hash string, targetCost int) bool {
	if targetCost < MinBcryptCost || targetCost > MaxBcryptCost {
		return false
	}
	cost, err := bcrypt.Cost([]byte(hash))
	return err == nil && cost < targetCost
}

func RehashPasswordIfNeeded(hash, password string, targetCost int) (string, bool, error) {
	if !NeedsPasswordRehash(hash, targetCost) {
		return hash, false, nil
	}
	updated, err := HashPasswordWithCost(password, targetCost)
	if err != nil {
		return hash, false, err
	}
	return updated, true, nil
}

func NewToken() (plain string, hash string, err error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", "", err
	}
	plain = base64.RawURLEncoding.EncodeToString(buf)
	return plain, HashToken(plain), nil
}

func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
