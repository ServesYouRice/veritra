package auth

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const testPassword = "owner-password-123"

func TestHashPasswordPolicyKeepsLegacyByteRange(t *testing.T) {
	if _, err := HashPassword("short"); err != ErrWeakPassword {
		t.Fatalf("short password err=%v want %v", err, ErrWeakPassword)
	}
	if _, err := HashPassword(strings.Repeat("a", 72)); err != nil {
		t.Fatalf("72-byte password should be accepted: %v", err)
	}
	if _, err := HashPassword(strings.Repeat("a", 73)); err != ErrPasswordTooLong {
		t.Fatalf("73-byte password err=%v want %v", err, ErrPasswordTooLong)
	}
}

func TestNewHashesAreSelfDescribingArgon2id(t *testing.T) {
	hash, err := HashPassword(testPassword)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if !strings.HasPrefix(hash, "$argon2id$v=19$m=65536,t=2,p=1$") || strings.Count(hash, "$") != 5 {
		t.Fatalf("hash is not a PHC Argon2id string: %q", hash)
	}
	if strings.Contains(hash, testPassword) {
		t.Fatal("hash contains the password")
	}
	other, err := HashPassword(testPassword)
	if err != nil || other == hash {
		t.Fatalf("hashes must use a fresh salt: err=%v equal=%v", err, other == hash)
	}
	ctx := context.Background()
	check, err := VerifyPassword(ctx, hash, testPassword, VerifyOptions{})
	if err != nil || !check.OK || check.Rehash || check.Legacy {
		t.Fatalf("verify current hash: %+v err=%v", check, err)
	}
	if check, _ := VerifyPassword(ctx, hash, "wrong-password-123", VerifyOptions{}); check.OK || check.Rehash {
		t.Fatalf("wrong password accepted: %+v", check)
	}
}

func TestVerifyPasswordRejectsUnknownAndMalformedHashes(t *testing.T) {
	valid, err := HashPassword(testPassword)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	parts := strings.Split(valid, "$")
	for name, stored := range map[string]string{
		"unknown_account": "",
		"deleted_marker":  "!",
		"argon2i":         strings.Replace(valid, "$argon2id$", "$argon2i$", 1),
		"old_version":     strings.Replace(valid, "$v=19$", "$v=16$", 1),
		"huge_memory":     strings.Replace(valid, "m=65536", "m=4194304", 1),
		"zero_passes":     strings.Replace(valid, "t=2", "t=0", 1),
		"extra_field":     valid + "$x",
		"padded_salt":     strings.Join([]string{"", parts[1], parts[2], parts[3], parts[4] + "==", parts[5]}, "$"),
		"short_key":       strings.Join([]string{"", parts[1], parts[2], parts[3], parts[4], "AAAA"}, "$"),
	} {
		t.Run(name, func(t *testing.T) {
			check, err := VerifyPassword(context.Background(), stored, testPassword, VerifyOptions{LegacyHashesPresent: true})
			if err != nil || check.OK || check.Rehash {
				t.Fatalf("stored %q: %+v err=%v", stored, check, err)
			}
		})
	}
}

func TestLegacyBcryptVerifiesAndAsksForRehash(t *testing.T) {
	legacy, err := bcrypt.GenerateFromPassword([]byte(testPassword), DefaultBcryptCost)
	if err != nil {
		t.Fatalf("legacy hash: %v", err)
	}
	ctx := context.Background()
	check, err := VerifyPassword(ctx, string(legacy), testPassword, VerifyOptions{LegacyHashesPresent: true})
	if err != nil || !check.OK || !check.Rehash || !check.Legacy {
		t.Fatalf("legacy verify: %+v err=%v", check, err)
	}
	check, err = VerifyPassword(ctx, string(legacy), "wrong-password-123", VerifyOptions{LegacyHashesPresent: true})
	if err != nil || check.OK || check.Rehash || !check.Legacy {
		t.Fatalf("legacy wrong password: %+v err=%v", check, err)
	}
	if !IsLegacyPasswordHash(string(legacy)) {
		t.Fatal("bcrypt hash not reported as legacy")
	}
}

// A stored bcrypt hash may name any cost up to 31; the request context cannot
// interrupt the comparison, so a cost above the policy ceiling is never run
// (VAL-208). The primitive is stubbed so a regression cannot hang the test.
func TestVerifyPasswordNeverRunsBcryptAboveMaxCost(t *testing.T) {
	legacy, err := bcrypt.GenerateFromPassword([]byte(testPassword), DefaultBcryptCost)
	if err != nil {
		t.Fatalf("legacy hash: %v", err)
	}
	oversized := strings.Replace(string(legacy), "$10$", "$31$", 1)
	if cost, err := bcrypt.Cost([]byte(oversized)); err != nil || cost != 31 {
		t.Fatalf("test hash cost = %d, %v", cost, err)
	}
	realBcrypt := bcryptCompare
	t.Cleanup(func() { bcryptCompare = realBcrypt })
	var costs []int
	bcryptCompare = func(hash, password []byte) error {
		cost, err := bcrypt.Cost(hash)
		if err != nil {
			t.Fatalf("bcrypt.Cost: %v", err)
		}
		costs = append(costs, cost)
		return bcrypt.ErrMismatchedHashAndPassword
	}
	for _, present := range []bool{true, false} {
		costs = nil
		check, err := VerifyPassword(context.Background(), oversized, testPassword, VerifyOptions{LegacyHashesPresent: present})
		if err != nil || check.OK || check.Rehash || !check.Legacy {
			t.Fatalf("oversized cost: %+v err=%v", check, err)
		}
		for _, cost := range costs {
			if cost > MaxBcryptCost {
				t.Fatalf("bcryptCompare received a hash of cost %d, ceiling is %d", cost, MaxBcryptCost)
			}
		}
		if len(costs) != 1 {
			t.Fatalf("legacyPresent=%v: %d bcrypt comparisons, want 1 (the dummy)", present, len(costs))
		}
	}
	// Truncated bcrypt-looking strings are unusable too, not an error.
	check, err := VerifyPassword(context.Background(), "$2a$10$short", testPassword, VerifyOptions{})
	if err != nil || check.OK || !check.Legacy {
		t.Fatalf("malformed bcrypt: %+v err=%v", check, err)
	}
}

func TestOlderArgon2idParametersAskForRehash(t *testing.T) {
	salt := make([]byte, argon2idSaltBytes)
	old := argon2idParams{memoryKiB: 19 * 1024, iterations: 2, parallelism: 1}
	stored := encodeArgon2id(old, salt, argon2idKey([]byte(testPassword), salt, old.iterations, old.memoryKiB, old.parallelism, argon2idKeyBytes))
	check, err := VerifyPassword(context.Background(), stored, testPassword, VerifyOptions{})
	if err != nil || !check.OK || !check.Rehash || check.Legacy {
		t.Fatalf("older parameters: %+v err=%v", check, err)
	}
}

// countPrimitives counts the hash primitives VerifyPassword runs, so the
// constant-work property is checked without timing.
func countPrimitives(t *testing.T) (argonCalls, bcryptCalls *atomic.Int64) {
	t.Helper()
	argonCalls, bcryptCalls = new(atomic.Int64), new(atomic.Int64)
	realArgon, realBcrypt := argon2idKey, bcryptCompare
	argon2idKey = func(password, salt []byte, time, memory uint32, threads uint8, keyLen uint32) []byte {
		argonCalls.Add(1)
		return realArgon(password, salt, time, memory, threads, keyLen)
	}
	bcryptCompare = func(hash, password []byte) error {
		bcryptCalls.Add(1)
		return realBcrypt(hash, password)
	}
	t.Cleanup(func() { argon2idKey, bcryptCompare = realArgon, realBcrypt })
	return argonCalls, bcryptCalls
}

func TestVerificationWorkDoesNotDependOnAccountOrOutcome(t *testing.T) {
	legacy, err := bcrypt.GenerateFromPassword([]byte(testPassword), DefaultBcryptCost)
	if err != nil {
		t.Fatalf("legacy hash: %v", err)
	}
	migrated, err := HashPassword(testPassword)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	cases := map[string]string{"unknown": "", "legacy": string(legacy), "migrated": migrated}
	for _, legacyPresent := range []bool{true, false} {
		for name, stored := range cases {
			if name == "legacy" && !legacyPresent {
				continue // a bcrypt hash means legacy hashes are present
			}
			for _, password := range []string{testPassword, "wrong-password-123"} {
				argonCalls, bcryptCalls := countPrimitives(t)
				if _, err := VerifyPassword(context.Background(), stored, password, VerifyOptions{LegacyHashesPresent: legacyPresent}); err != nil {
					t.Fatalf("%s verify: %v", name, err)
				}
				wantBcrypt := int64(0)
				if legacyPresent {
					wantBcrypt = 1
				}
				if argonCalls.Load() != 1 || bcryptCalls.Load() != wantBcrypt {
					t.Fatalf("legacyPresent=%v %s: argon2id=%d bcrypt=%d want 1/%d", legacyPresent, name, argonCalls.Load(), bcryptCalls.Load(), wantBcrypt)
				}
			}
		}
	}
}

// workUnits records the cost of each primitive call as a string: Argon2id as
// memory KiB x passes, bcrypt as its cost. It is the deterministic stand-in
// for timing, so the policy below is checked without a clock.
func workUnits(t *testing.T) *[]string {
	t.Helper()
	var units []string
	realArgon, realBcrypt := argon2idKey, bcryptCompare
	argon2idKey = func(password, salt []byte, time, memory uint32, threads uint8, keyLen uint32) []byte {
		units = append(units, fmt.Sprintf("argon2id %dKiB x%d", memory, time))
		return realArgon(password, salt, time, memory, threads, keyLen)
	}
	bcryptCompare = func(hash, password []byte) error {
		cost, err := bcrypt.Cost(hash)
		if err != nil {
			t.Fatalf("bcrypt.Cost: %v", err)
		}
		units = append(units, fmt.Sprintf("bcrypt cost %d", cost))
		return realBcrypt(hash, password)
	}
	t.Cleanup(func() { argon2idKey, bcryptCompare = realArgon, realBcrypt })
	return &units
}

// VerifyPassword work units (audit plan Q-003 and its Q-OUTCOME constraint):
// the work done never depends on whether the password matched, for every
// stored profile (VAL-303). It does depend on the stored profile: an older
// supported Argon2id profile or an off-configuration bcrypt cost runs at its
// own cost, which an unknown account cannot imitate. That residual is open:
// the owner has not chosen a timing policy (pad, extra dummy, or accept), and
// this test only records today's behaviour (VAL-209) so that changing it is a
// visible decision.
func TestVerificationWorkUnitsDoNotDependOnOutcome(t *testing.T) {
	const configured = DefaultBcryptCost
	legacyConfigured, err := bcrypt.GenerateFromPassword([]byte(testPassword), configured)
	if err != nil {
		t.Fatal(err)
	}
	legacyOffCost, err := bcrypt.GenerateFromPassword([]byte(testPassword), configured+1)
	if err != nil {
		t.Fatal(err)
	}
	current, err := HashPassword(testPassword)
	if err != nil {
		t.Fatal(err)
	}
	salt := make([]byte, argon2idSaltBytes)
	old := argon2idParams{memoryKiB: 19 * 1024, iterations: 2, parallelism: 1}
	older := encodeArgon2id(old, salt, argon2idKey([]byte(testPassword), salt, old.iterations, old.memoryKiB, old.parallelism, argon2idKeyBytes))

	profiles := []struct {
		name   string
		stored string
		legacy bool // a bcrypt hash exists, so legacy hashes are present
	}{
		{"unknown", "", false},
		{"unknown_legacy_present", "", true},
		{"current", current, false},
		{"current_legacy_present", current, true},
		{"older_argon2id", older, false},
		{"older_argon2id_legacy_present", older, true},
		{"legacy_configured_cost", string(legacyConfigured), true},
		{"legacy_off_cost", string(legacyOffCost), true},
	}
	units := make(map[string][]string)
	for _, profile := range profiles {
		var match, mismatch []string
		for i, password := range []string{testPassword, "wrong-password-123"} {
			recorded := workUnits(t)
			if _, err := VerifyPassword(context.Background(), profile.stored, password, VerifyOptions{LegacyHashesPresent: profile.legacy, LegacyBcryptCost: configured}); err != nil {
				t.Fatalf("%s: %v", profile.name, err)
			}
			if i == 0 {
				match = append(match, *recorded...)
			} else {
				mismatch = append(mismatch, *recorded...)
			}
		}
		if strings.Join(match, ",") != strings.Join(mismatch, ",") {
			t.Fatalf("%s: work depends on the outcome: match %v, mismatch %v", profile.name, match, mismatch)
		}
		units[profile.name] = match
	}

	// Residual (accepted, asserted): profiles other than the configured one
	// run their own cost.
	if got := strings.Join(units["unknown"], ","); got != "argon2id 65536KiB x2" {
		t.Fatalf("unknown account work = %q", got)
	}
	if got := strings.Join(units["older_argon2id"], ","); got != "argon2id 19456KiB x2" {
		t.Fatalf("older Argon2id work = %q", got)
	}
	if got := strings.Join(units["legacy_off_cost"], ","); got != fmt.Sprintf("bcrypt cost %d,argon2id 65536KiB x2", configured+1) {
		t.Fatalf("off-cost bcrypt work = %q", got)
	}
	// What is equal: the configured legacy cost and the current profile cost
	// the same as an unknown account.
	if got, want := strings.Join(units["legacy_configured_cost"], ","), strings.Join(units["unknown_legacy_present"], ","); got != want {
		t.Fatalf("configured-cost legacy work %q differs from unknown account %q", got, want)
	}
	if got, want := strings.Join(units["current_legacy_present"], ","), strings.Join(units["unknown_legacy_present"], ","); got != want {
		t.Fatalf("current-profile work %q differs from unknown account %q", got, want)
	}
}

func shortContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	t.Cleanup(cancel)
	return ctx
}

func TestPasswordHashingConcurrencyIsBounded(t *testing.T) {
	// An anonymous flood holding every shared slot blocks only anonymous work.
	for i := 0; i < cap(sharedPasswordSlots); i++ {
		sharedPasswordSlots <- struct{}{}
	}
	_, verifyErr := VerifyPassword(shortContext(t), "", testPassword, VerifyOptions{Caller: Anonymous})
	_, hashErr := HashPasswordContext(shortContext(t), Anonymous, testPassword)
	_, signedInErr := VerifyPassword(shortContext(t), "", testPassword, VerifyOptions{Caller: SignedIn})
	_, signedInHashErr := HashPasswordContext(shortContext(t), SignedIn, testPassword)
	signedInPasswordSlots <- struct{}{}
	_, exhaustedErr := VerifyPassword(shortContext(t), "", testPassword, VerifyOptions{Caller: SignedIn})
	<-signedInPasswordSlots
	for i := 0; i < cap(sharedPasswordSlots); i++ {
		<-sharedPasswordSlots
	}
	if !errors.Is(verifyErr, context.DeadlineExceeded) || !errors.Is(hashErr, context.DeadlineExceeded) {
		t.Fatalf("full shared slots: anonymous verify err=%v hash err=%v", verifyErr, hashErr)
	}
	if signedInErr != nil || signedInHashErr != nil {
		t.Fatalf("reserved slot unavailable to signed-in callers: verify err=%v hash err=%v", signedInErr, signedInHashErr)
	}
	if !errors.Is(exhaustedErr, context.DeadlineExceeded) {
		t.Fatalf("all slots full: signed-in verify err=%v", exhaustedErr)
	}
	if cap(sharedPasswordSlots)+cap(signedInPasswordSlots) != MaxConcurrentPasswordHashes {
		t.Fatalf("slot pools %d+%d do not add up to %d", cap(sharedPasswordSlots), cap(signedInPasswordSlots), MaxConcurrentPasswordHashes)
	}

	var active, peak atomic.Int64
	realArgon := argon2idKey
	argon2idKey = func(password, salt []byte, time, memory uint32, threads uint8, keyLen uint32) []byte {
		now := active.Add(1)
		for {
			old := peak.Load()
			if now <= old || peak.CompareAndSwap(old, now) {
				break
			}
		}
		defer active.Add(-1)
		return realArgon(password, salt, time, memory, threads, keyLen)
	}
	t.Cleanup(func() { argon2idKey = realArgon })
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func(caller Caller) {
			defer wg.Done()
			if _, err := VerifyPassword(context.Background(), "", testPassword, VerifyOptions{Caller: caller}); err != nil {
				t.Errorf("burst verify: %v", err)
			}
		}(Caller(i % 2))
	}
	wg.Wait()
	if peak.Load() > MaxConcurrentPasswordHashes {
		t.Fatalf("peak concurrent Argon2id=%d want <= %d", peak.Load(), MaxConcurrentPasswordHashes)
	}
}

type fakePasswordStore struct {
	mu      sync.Mutex
	hash    string
	legacy  bool
	probes  int
	updates int
}

func (s *fakePasswordStore) UpgradePasswordHash(_ context.Context, _, currentHash, updatedHash string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.hash != currentHash {
		return false, nil
	}
	s.hash = updatedHash
	s.legacy = IsLegacyPasswordHash(updatedHash)
	s.updates++
	return true, nil
}

func (s *fakePasswordStore) HasLegacyPasswordHashes(context.Context) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.probes++
	return s.legacy, nil
}

func TestPasswordsMigrateLegacyHashOnlyThroughUpgrade(t *testing.T) {
	legacy, err := bcrypt.GenerateFromPassword([]byte(testPassword), DefaultBcryptCost)
	if err != nil {
		t.Fatalf("legacy hash: %v", err)
	}
	store := &fakePasswordStore{hash: string(legacy), legacy: true}
	passwords := NewPasswords(store, DefaultBcryptCost, nil)
	ctx := context.Background()

	wrong, err := passwords.Verify(ctx, Anonymous, store.hash, "wrong-password-123")
	if err != nil || wrong.OK {
		t.Fatalf("wrong password: %+v err=%v", wrong, err)
	}
	passwords.Upgrade(ctx, "acct", store.hash, "wrong-password-123", wrong)
	check, err := passwords.Verify(ctx, Anonymous, store.hash, testPassword)
	if err != nil || !check.OK || !check.Rehash {
		t.Fatalf("legacy verify: %+v err=%v", check, err)
	}
	if store.updates != 0 {
		t.Fatal("Verify wrote a hash before the caller finished its checks")
	}
	passwords.Upgrade(ctx, "acct", string(legacy), testPassword, check)
	if store.updates != 1 || !strings.HasPrefix(store.hash, "$argon2id$") {
		t.Fatalf("legacy hash not migrated: updates=%d", store.updates)
	}
	if store.probes != 2 {
		t.Fatalf("legacy probes=%d want 2 (startup and after the last bcrypt hash migrated)", store.probes)
	}

	argonCalls, bcryptCalls := countPrimitives(t)
	check, err = passwords.Verify(ctx, SignedIn, store.hash, testPassword)
	if err != nil || !check.OK || check.Rehash {
		t.Fatalf("migrated verify: %+v err=%v", check, err)
	}
	if argonCalls.Load() != 1 || bcryptCalls.Load() != 0 {
		t.Fatalf("after migration argon2id=%d bcrypt=%d want 1/0", argonCalls.Load(), bcryptCalls.Load())
	}
	// A concurrent change wins over a stale upgrade.
	passwords.Upgrade(ctx, "acct", string(legacy), testPassword, PasswordCheck{OK: true, Rehash: true, Legacy: true})
	if store.updates != 1 {
		t.Fatal("stale upgrade replaced a newer hash")
	}
}

func BenchmarkPasswordVerification(b *testing.B) {
	ctx := context.Background()
	current, err := HashPassword(testPassword)
	if err != nil {
		b.Fatalf("hash: %v", err)
	}
	legacy10, err := bcrypt.GenerateFromPassword([]byte(testPassword), 10)
	if err != nil {
		b.Fatalf("legacy hash: %v", err)
	}
	for _, bench := range []struct {
		name   string
		stored string
		legacy bool
	}{
		{"argon2id", current, false},
		{"argon2id-while-legacy-present", current, true},
		{"unknown-account", "", false},
		{"unknown-account-while-legacy-present", "", true},
		{"bcrypt-10-legacy", string(legacy10), true},
	} {
		b.Run(bench.name, func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				if _, err := VerifyPassword(ctx, bench.stored, testPassword, VerifyOptions{LegacyHashesPresent: bench.legacy}); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
