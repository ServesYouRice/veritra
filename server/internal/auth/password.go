package auth

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/bcrypt"
)

var (
	ErrWeakPassword    = errors.New("password must be at least 12 characters")
	ErrPasswordTooLong = errors.New("password must be at most 72 bytes")
	// ErrPasswordHashingBusy means every hashing slot stayed taken for
	// passwordSlotWait. Callers answer 503 with Retry-After; it is not a
	// credential failure.
	ErrPasswordHashingBusy = errors.New("password hashing is busy")
)

// New password hashes are Argon2id (RFC 9106) in the PHC string format
// "$argon2id$v=19$m=<KiB>,t=<passes>,p=<lanes>$<salt>$<tag>", so every stored
// hash names its own algorithm, version and parameters. The values sit
// between the OWASP minimum (19 MiB, t=2, p=1) and the RFC 9106 low-memory
// option (64 MiB, t=3, p=4). See testing/evidence/T37C-password-sessions.md
// for the measurements behind them.
const (
	Argon2idMemoryKiB   uint32 = 64 * 1024
	Argon2idIterations  uint32 = 2
	Argon2idParallelism uint8  = 1
	argon2idSaltBytes          = 16
	argon2idKeyBytes           = 32

	// MaxConcurrentPasswordHashes bounds simultaneous hash and verify work
	// process-wide, so a burst holds at most this many Argon2id buffers
	// (3 x 64 MiB) instead of one per request. ReservedSignedInHashes of
	// them serve only callers that already hold a valid session
	// (reauthentication, password change, rehash after a full sign-in), so a
	// flood of anonymous sign-in attempts cannot block step-up
	// authentication. Existing sessions never hash at all.
	MaxConcurrentPasswordHashes = 3
	ReservedSignedInHashes      = 1
	passwordSlotWait            = 5 * time.Second

	// Bounds for parsing stored hashes, so a corrupt row cannot ask for an
	// unbounded allocation.
	maxStoredArgon2idMemoryKiB = 1 << 18
	maxStoredArgon2idPasses    = 16
	maxStoredArgon2idLanes     = 16

	// Legacy bcrypt verification. New hashes are never bcrypt.
	DefaultBcryptCost = 10
	MinBcryptCost     = 10
	MaxBcryptCost     = 15
)

var (
	sharedPasswordSlots   = make(chan struct{}, MaxConcurrentPasswordHashes-ReservedSignedInHashes)
	signedInPasswordSlots = make(chan struct{}, ReservedSignedInHashes)
)

// Caller says which hashing slots a request may use.
type Caller int

const (
	// Anonymous callers (sign-in, registration, setup) use the shared slots.
	Anonymous Caller = iota
	// SignedIn callers hold a valid session and may also use the reserved
	// slots.
	SignedIn
)

// The primitives are variables so tests can count the work each path does.
var (
	argon2idKey   = argon2.IDKey
	bcryptCompare = bcrypt.CompareHashAndPassword
)

func acquirePasswordSlot(ctx context.Context, caller Caller) (func(), error) {
	// A nil channel never receives, so anonymous callers never select the
	// reserved slots.
	var reserved chan struct{}
	if caller == SignedIn {
		reserved = signedInPasswordSlots
	}
	select {
	case sharedPasswordSlots <- struct{}{}:
		return releaseSharedSlot, nil
	case reserved <- struct{}{}:
		return releaseSignedInSlot, nil
	default:
	}
	timer := time.NewTimer(passwordSlotWait)
	defer timer.Stop()
	select {
	case sharedPasswordSlots <- struct{}{}:
		return releaseSharedSlot, nil
	case reserved <- struct{}{}:
		return releaseSignedInSlot, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-timer.C:
		return nil, ErrPasswordHashingBusy
	}
}

func releaseSharedSlot()   { <-sharedPasswordSlots }
func releaseSignedInSlot() { <-signedInPasswordSlots }

// ValidatePassword applies the account password policy. The 72-byte cap
// predates Argon2id (bcrypt truncates beyond it) and is kept so legacy and new
// hashes accept the same passwords. len() on a Go string counts bytes.
func ValidatePassword(password string) error {
	if len(password) < 12 {
		return ErrWeakPassword
	}
	if len(password) > 72 {
		return ErrPasswordTooLong
	}
	return nil
}

// HashPassword returns a new Argon2id hash. It is for callers without a
// request context (tests and offline tools); servers use HashPasswordContext.
func HashPassword(password string) (string, error) {
	return HashPasswordContext(context.Background(), Anonymous, password)
}

// HashPasswordContext validates the password policy and returns a new
// Argon2id hash, waiting for a hashing slot until ctx ends.
func HashPasswordContext(ctx context.Context, caller Caller, password string) (string, error) {
	if err := ValidatePassword(password); err != nil {
		return "", err
	}
	return hashArgon2id(ctx, caller, password)
}

// hashArgon2id hashes without the policy check. Rehash-on-success uses it so
// a password that predates a policy change still migrates.
func hashArgon2id(ctx context.Context, caller Caller, password string) (string, error) {
	salt := make([]byte, argon2idSaltBytes)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	release, err := acquirePasswordSlot(ctx, caller)
	if err != nil {
		return "", err
	}
	key := argon2idKey([]byte(password), salt, Argon2idIterations, Argon2idMemoryKiB, Argon2idParallelism, argon2idKeyBytes)
	release()
	return encodeArgon2id(currentArgon2idParams(), salt, key), nil
}

type argon2idParams struct {
	memoryKiB   uint32
	iterations  uint32
	parallelism uint8
}

func currentArgon2idParams() argon2idParams {
	return argon2idParams{memoryKiB: Argon2idMemoryKiB, iterations: Argon2idIterations, parallelism: Argon2idParallelism}
}

type argon2idHash struct {
	params argon2idParams
	salt   []byte
	key    []byte
}

func encodeArgon2id(params argon2idParams, salt, key []byte) string {
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, params.memoryKiB, params.iterations, params.parallelism,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(key))
}

// parseArgon2id accepts only the exact encoding encodeArgon2id writes, with
// bounded parameters.
func parseArgon2id(encoded string) (argon2idHash, bool) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" || parts[2] != "v="+strconv.Itoa(argon2.Version) {
		return argon2idHash{}, false
	}
	fields := strings.Split(parts[3], ",")
	if len(fields) != 3 {
		return argon2idHash{}, false
	}
	memory, okM := parseParam(fields[0], "m=", 32, maxStoredArgon2idMemoryKiB)
	passes, okT := parseParam(fields[1], "t=", 32, maxStoredArgon2idPasses)
	lanes, okP := parseParam(fields[2], "p=", 8, maxStoredArgon2idLanes)
	if !okM || !okT || !okP || passes < 1 || lanes < 1 || memory < 8*lanes {
		return argon2idHash{}, false
	}
	salt, err := base64.RawStdEncoding.Strict().DecodeString(parts[4])
	if err != nil || len(salt) < 8 || len(salt) > 64 {
		return argon2idHash{}, false
	}
	key, err := base64.RawStdEncoding.Strict().DecodeString(parts[5])
	if err != nil || len(key) < 16 || len(key) > 64 {
		return argon2idHash{}, false
	}
	return argon2idHash{
		params: argon2idParams{memoryKiB: uint32(memory), iterations: uint32(passes), parallelism: uint8(lanes)},
		salt:   salt,
		key:    key,
	}, true
}

// parseParam parses a decimal parameter that fits bitSize bits (the width of
// the field it is converted to) and does not exceed limit.
func parseParam(field, prefix string, bitSize int, limit uint64) (uint64, bool) {
	raw, ok := strings.CutPrefix(field, prefix)
	if !ok {
		return 0, false
	}
	value, err := strconv.ParseUint(raw, 10, bitSize)
	return value, err == nil && value <= limit
}

func (h argon2idHash) matches(password []byte) bool {
	key := argon2idKey(password, h.salt, h.params.iterations, h.params.memoryKiB, h.params.parallelism, uint32(len(h.key)))
	return subtle.ConstantTimeCompare(key, h.key) == 1
}

// IsLegacyPasswordHash reports whether stored is a bcrypt hash that
// rehash-on-success has not yet replaced. storage.HasLegacyPasswordHashes
// matches the same three prefixes in SQL.
func IsLegacyPasswordHash(stored string) bool {
	return strings.HasPrefix(stored, "$2a$") || strings.HasPrefix(stored, "$2b$") || strings.HasPrefix(stored, "$2y$")
}

var dummyArgon2idSalt = func() []byte {
	salt := make([]byte, argon2idSaltBytes)
	if _, err := rand.Read(salt); err != nil {
		panic("auth: unable to generate dummy Argon2id salt: " + err.Error())
	}
	return salt
}()

func dummyArgon2id(password []byte) {
	_ = argon2idKey(password, dummyArgon2idSalt, Argon2idIterations, Argon2idMemoryKiB, Argon2idParallelism, argon2idKeyBytes)
}

// dummyHash is generated eagerly at startup with the default legacy cost and
// panics on failure: if bcrypt cannot produce it we fail at startup rather
// than skip the dummy compare and reopen a username-enumeration side-channel.
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

// VerifyOptions carries the caller and the instance-wide legacy state into
// VerifyPassword.
type VerifyOptions struct {
	Caller Caller
	// LegacyBcryptCost is the cost of the dummy bcrypt comparison.
	LegacyBcryptCost int
	// LegacyHashesPresent is true while any live account still has a bcrypt
	// hash. Every verification then also pays one bcrypt comparison, so an
	// unknown account, a migrated account and a legacy account all cost
	// bcrypt plus Argon2id. Once no bcrypt hash remains, all cost Argon2id.
	LegacyHashesPresent bool
}

// PasswordCheck is the result of VerifyPassword.
type PasswordCheck struct {
	OK bool
	// Rehash is true when OK and the stored hash is bcrypt or uses older
	// Argon2id parameters. Callers rehash only after every other credential
	// check has passed, so the extra work is not a password oracle.
	Rehash bool
	// Legacy is true when the stored hash was bcrypt, whatever the outcome.
	Legacy bool
}

// VerifyPassword checks password against stored. An empty stored hash means
// the account does not exist; the work done is the same as for a real
// account, and it never depends on whether the password matched.
func VerifyPassword(ctx context.Context, stored, password string, opts VerifyOptions) (PasswordCheck, error) {
	release, err := acquirePasswordSlot(ctx, opts.Caller)
	if err != nil {
		return PasswordCheck{}, err
	}
	defer release()
	secret := []byte(password)
	if IsLegacyPasswordHash(stored) {
		ok := bcryptCompare([]byte(stored), secret) == nil
		dummyArgon2id(secret)
		return PasswordCheck{OK: ok, Rehash: ok, Legacy: true}, nil
	}
	if opts.LegacyHashesPresent {
		_ = bcryptCompare(dummyHashForCost(opts.LegacyBcryptCost), secret)
	}
	parsed, ok := parseArgon2id(stored)
	if !ok {
		dummyArgon2id(secret)
		return PasswordCheck{}, nil
	}
	if !parsed.matches(secret) {
		return PasswordCheck{}, nil
	}
	return PasswordCheck{OK: true, Rehash: parsed.params != currentArgon2idParams() || len(parsed.key) != argon2idKeyBytes || len(parsed.salt) != argon2idSaltBytes}, nil
}
