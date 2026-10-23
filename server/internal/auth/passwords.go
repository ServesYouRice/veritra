package auth

import (
	"context"
	"log/slog"
	"sync"
)

// PasswordStore is the storage the password service needs.
type PasswordStore interface {
	// UpgradePasswordHash replaces currentHash with updatedHash only if the
	// account still holds currentHash, and reports whether it did.
	UpgradePasswordHash(ctx context.Context, accountID, currentHash, updatedHash string) (bool, error)
	// HasLegacyPasswordHashes reports whether any live account still has a
	// bcrypt hash.
	HasLegacyPasswordHashes(ctx context.Context) (bool, error)
}

type legacyState int

const (
	legacyUnknown legacyState = iota
	legacyPresent
	legacyAbsent
)

// Passwords verifies account passwords with uniform cost and migrates stored
// hashes to the current Argon2id parameters after a fully successful sign-in.
// Neither the password nor a hash is ever logged.
type Passwords struct {
	store      PasswordStore
	bcryptCost int
	log        *slog.Logger

	mu     sync.Mutex
	legacy legacyState
}

func NewPasswords(store PasswordStore, legacyBcryptCost int, log *slog.Logger) *Passwords {
	if legacyBcryptCost < MinBcryptCost || legacyBcryptCost > MaxBcryptCost {
		legacyBcryptCost = DefaultBcryptCost
	}
	if log == nil {
		log = slog.Default()
	}
	return &Passwords{store: store, bcryptCost: legacyBcryptCost, log: log}
}

// Verify checks password against stored, the hash read for the account ("" if
// there is no such account). It never writes; call Upgrade after every other
// credential check has passed. caller is SignedIn only for a request that
// already holds a valid session.
func (p *Passwords) Verify(ctx context.Context, caller Caller, stored, password string) (PasswordCheck, error) {
	legacy := p.legacyPresent(ctx)
	check, err := VerifyPassword(ctx, stored, password, VerifyOptions{Caller: caller, LegacyBcryptCost: p.bcryptCost, LegacyHashesPresent: legacy})
	if err != nil {
		return PasswordCheck{}, err
	}
	if check.Legacy && !legacy {
		// A bcrypt hash the probe did not see: equalise timing from now on.
		p.setLegacy(legacyPresent)
	}
	return check, nil
}

// Upgrade rehashes a verified password with the current Argon2id parameters
// and stores it if the account still holds stored. Failures are logged and
// left for the next sign-in; they never fail the sign-in itself.
func (p *Passwords) Upgrade(ctx context.Context, accountID, stored, password string, check PasswordCheck) {
	if !check.OK || !check.Rehash || accountID == "" {
		return
	}
	// Every credential has been checked, so the rehash may use the reserved
	// slots and is not starved by anonymous sign-in attempts.
	updated, err := hashArgon2id(ctx, SignedIn, password)
	if err != nil {
		p.log.Warn("password_rehash_failed", "err", err)
		return
	}
	changed, err := p.store.UpgradePasswordHash(ctx, accountID, stored, updated)
	if err != nil {
		p.log.Warn("password_rehash_update_failed", "err", err)
		return
	}
	if changed && check.Legacy {
		p.refreshLegacy(ctx)
	}
}

func (p *Passwords) legacyPresent(ctx context.Context) bool {
	p.mu.Lock()
	state := p.legacy
	p.mu.Unlock()
	if state != legacyUnknown {
		return state == legacyPresent
	}
	return p.refreshLegacy(ctx)
}

// refreshLegacy re-reads whether bcrypt hashes remain. On error it assumes
// they do (the safe, slower choice) and leaves the state unknown so the next
// verification asks again.
func (p *Passwords) refreshLegacy(ctx context.Context) bool {
	present, err := p.store.HasLegacyPasswordHashes(ctx)
	if err != nil {
		p.log.Warn("password_legacy_probe_failed", "err", err)
		return true
	}
	if present {
		p.setLegacy(legacyPresent)
	} else {
		p.setLegacy(legacyAbsent)
	}
	return present
}

func (p *Passwords) setLegacy(state legacyState) {
	p.mu.Lock()
	p.legacy = state
	p.mu.Unlock()
}
