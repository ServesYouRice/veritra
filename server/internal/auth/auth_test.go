package auth

import (
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestHashPasswordRejectsBcryptTruncationRange(t *testing.T) {
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

func TestVerifyPasswordOrDummyAlwaysRejectsMissingHash(t *testing.T) {
	if VerifyPasswordOrDummy("", "owner-password-123") {
		t.Fatal("missing hash should not authenticate")
	}
}

func TestLegacyBcryptHashNeedsMigration(t *testing.T) {
	legacy, err := bcrypt.GenerateFromPassword([]byte("owner-password-123"), 10)
	if err != nil {
		t.Fatalf("legacy hash: %v", err)
	}
	if !NeedsPasswordRehash(string(legacy), 12) {
		t.Fatal("cost-10 hash was not marked for migration")
	}
	updated, changed, err := RehashPasswordIfNeeded(string(legacy), "owner-password-123", 12)
	if err != nil || !changed || !VerifyPassword(updated, "owner-password-123") {
		t.Fatalf("rehash changed=%v err=%v valid=%v", changed, err, VerifyPassword(updated, "owner-password-123"))
	}
}

func BenchmarkPasswordVerificationCosts(b *testing.B) {
	for _, cost := range []int{DefaultBcryptCost, 12} {
		hash, err := bcrypt.GenerateFromPassword([]byte("owner-password-123"), cost)
		if err != nil {
			b.Fatalf("hash cost %d: %v", cost, err)
		}
		b.Run("cost-"+itoa(cost), func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if !VerifyPassword(string(hash), "owner-password-123") {
					b.Fatal("verification failed")
				}
			}
		})
	}
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	var digits [20]byte
	index := len(digits)
	for value > 0 {
		index--
		digits[index] = byte('0' + value%10)
		value /= 10
	}
	return string(digits[index:])
}
