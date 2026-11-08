// Package devicelist parses and checks the account approved-device list of
// docs/designs/L1-approved-device-list.md (format VDL1, decision D94).
//
// An account's list is a hash chain of signed statements. Each version is
// signed by a device on the previous version, or by the recovery key the
// previous version names, and carries the hash of that previous version. The
// server stores and serves the chain; it holds no signing key, so it cannot
// create a version. It checks every upload with the same rules clients apply
// (defence in depth: clients never rely on this).
//
// The byte format is specified by the design and, on the client side, by the
// Rust crypto core (L1-1). Parsing is strict: anything the format does not
// produce is refused.
package devicelist

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"sort"
)

const (
	// MaxStatementBytes is the size limit for one whole statement.
	MaxStatementBytes = 4096
	// MaxEntries is the most devices one version may list. The server allows
	// fewer devices per account (config/limits.go); the format leaves room.
	MaxEntries = 16
	// MaxIDBytes bounds an account or device id inside a statement, as the
	// crypto core does (crypto/rust/src/lib.rs MAX_ACCOUNT_ID_BYTES and
	// MAX_DEVICE_ID_BYTES). Server-made ids are shorter; the format leaves room.
	MaxIDBytes = 128

	keySize  = 32
	hashSize = 32
	sigSize  = 64

	formatVersion = 1
	bodyMagic     = "VDL1"
	// signLabel and hashLabel are the domain labels of the signed message and
	// of list_hash. Every Veritra label starts with "veritra-".
	signLabel = "veritra-l1-device-list-sig-v1"
	hashLabel = "veritra-l1-device-list-hash-v1"
)

// Change says what a version did to its predecessor.
type Change uint8

const (
	ChangeGenesis          Change = 1
	ChangeAdd              Change = 2
	ChangeRemove           Change = 3
	ChangeRecovery         Change = 4
	ChangeRecoveryKey      Change = 5
	ChangeMigrationGenesis Change = 6
)

// SignerKind says what kind of key signed a version.
type SignerKind uint8

const (
	SignerDevice      SignerKind = 1
	SignerRecoveryKey SignerKind = 2
)

// ErrMalformed reports bytes that are not one well-formed VDL1 statement.
var ErrMalformed = errors.New("devicelist: malformed statement")

// Rule violations of a step. They all mean the same to a caller (the
// upload is refused), but tests and logs can tell them apart.
var (
	ErrWrongAccount    = errors.New("devicelist: statement is for another account")
	ErrVersionGap      = errors.New("devicelist: version is not head + 1")
	ErrPrevHash        = errors.New("devicelist: prev_hash does not match the head")
	ErrBadChange       = errors.New("devicelist: change kind not allowed here")
	ErrBadSigner       = errors.New("devicelist: signer not allowed for this change")
	ErrBadSignature    = errors.New("devicelist: signature does not verify")
	ErrBadEntries      = errors.New("devicelist: listed devices do not follow the rules for this change")
	ErrBadRecoveryKey  = errors.New("devicelist: recovery key does not follow the rules for this change")
	ErrReturningDevice = errors.New("devicelist: a removed or recovered-away device or key cannot return")
	ErrNotGenesis      = errors.New("devicelist: first version must be a genesis")
)

// Entry is one approved device: its id and Ed25519 signing key (the MLS
// credential key).
type Entry struct {
	DeviceID   string
	SigningKey []byte
}

// Body is the signed content of a version.
type Body struct {
	AccountID   string
	Version     uint64
	PrevHash    []byte // all zero for version 1
	CreatedAtMs uint64 // the signer's clock: shown, never trusted
	Change      Change
	Entries     []Entry // sorted by device id; ids and keys unique
	// RecoveryKey is the 32-byte key derived from the user's recovery key,
	// or nil when the list has none.
	RecoveryKey []byte
}

// Statement is a parsed, signed version.
type Statement struct {
	Body Body
	// BodyBytes are the exact bytes the hash and the signature cover.
	BodyBytes      []byte
	SignerKind     SignerKind
	SignerDeviceID string // empty for SignerRecoveryKey
	Signature      []byte
	// Raw is the whole statement as parsed.
	Raw []byte
}

type reader struct {
	data []byte
	pos  int
	ok   bool
}

func (r *reader) take(n int) []byte {
	if !r.ok || n < 0 || len(r.data)-r.pos < n {
		r.ok = false
		return nil
	}
	out := r.data[r.pos : r.pos+n]
	r.pos += n
	return out
}

func (r *reader) u8() uint8 {
	b := r.take(1)
	if b == nil {
		return 0
	}
	return b[0]
}

func (r *reader) u16() int {
	b := r.take(2)
	if b == nil {
		return 0
	}
	return int(b[0])<<8 | int(b[1])
}

func (r *reader) u64() uint64 {
	b := r.take(8)
	if b == nil {
		return 0
	}
	var v uint64
	for _, c := range b {
		v = v<<8 | uint64(c)
	}
	return v
}

// id reads lp(x) where x must be 1..MaxIDBytes bytes.
func (r *reader) id() string {
	n := r.u16()
	if !r.ok || n == 0 || n > MaxIDBytes {
		r.ok = false
		return ""
	}
	b := r.take(n)
	if b == nil {
		return ""
	}
	return string(b)
}

// Parse reads exactly one statement. It refuses a statement over
// MaxStatementBytes, a wrong magic or format, a trailing byte, a count of 0 or
// above MaxEntries, entries that are not strictly ascending by device id bytes,
// a repeated signing key, a signing key or recovery key that is not a canonical,
// valid, non-small-order Ed25519 point (a key the clients' strict verifier
// would refuse), a recovery flag other than 0 or 1, a version 0, a genesis
// (change 1 or 6) that is not version 1 or a version 1 that is not a genesis,
// a prev_hash that is not all zero on version 1, and a signer that does not fit
// its kind. Whether the chain rules hold is CheckStep's business.
func Parse(statement []byte) (Statement, error) {
	if len(statement) == 0 || len(statement) > MaxStatementBytes {
		return Statement{}, ErrMalformed
	}
	r := reader{data: statement, ok: true}
	if string(r.take(len(bodyMagic))) != bodyMagic || r.u8() != formatVersion {
		return Statement{}, ErrMalformed
	}
	var body Body
	body.AccountID = r.id()
	body.Version = r.u64()
	body.PrevHash = append([]byte(nil), r.take(hashSize)...)
	body.CreatedAtMs = r.u64()
	body.Change = Change(r.u8())
	count := int(r.u8())
	if !r.ok || body.Version == 0 || count < 1 || count > MaxEntries ||
		body.Change < ChangeGenesis || body.Change > ChangeMigrationGenesis {
		return Statement{}, ErrMalformed
	}
	zero := make([]byte, hashSize)
	genesis := body.Change == ChangeGenesis || body.Change == ChangeMigrationGenesis
	if genesis != (body.Version == 1) || (genesis && !bytes.Equal(body.PrevHash, zero)) {
		return Statement{}, ErrMalformed
	}
	keys := make(map[string]bool, count)
	for i := 0; i < count; i++ {
		deviceID := r.id()
		key := r.take(keySize)
		if !r.ok || !ValidPublicKey(key) {
			return Statement{}, ErrMalformed
		}
		if i > 0 && deviceID <= body.Entries[i-1].DeviceID {
			return Statement{}, ErrMalformed
		}
		if keys[string(key)] {
			return Statement{}, ErrMalformed
		}
		keys[string(key)] = true
		body.Entries = append(body.Entries, Entry{DeviceID: deviceID, SigningKey: append([]byte(nil), key...)})
	}
	switch r.u8() {
	case 0:
	case 1:
		body.RecoveryKey = append([]byte(nil), r.take(keySize)...)
		if !r.ok || !ValidPublicKey(body.RecoveryKey) {
			return Statement{}, ErrMalformed
		}
	default:
		return Statement{}, ErrMalformed
	}
	if !r.ok {
		return Statement{}, ErrMalformed
	}
	bodyEnd := r.pos
	out := Statement{Body: body, BodyBytes: statement[:bodyEnd:bodyEnd]}
	out.SignerKind = SignerKind(r.u8())
	switch out.SignerKind {
	case SignerDevice:
		out.SignerDeviceID = r.id()
	case SignerRecoveryKey:
		if r.u16() != 0 {
			return Statement{}, ErrMalformed
		}
	default:
		return Statement{}, ErrMalformed
	}
	out.Signature = append([]byte(nil), r.take(sigSize)...)
	if !r.ok || r.pos != len(statement) {
		return Statement{}, ErrMalformed
	}
	out.Raw = append([]byte(nil), statement...)
	return out, nil
}

// Hash is list_hash: SHA-256 of the hash label and the body. The signature is
// outside it, so a different signature over the same body cannot fork the
// chain.
func (s Statement) Hash() []byte {
	h := sha256.New()
	h.Write([]byte(hashLabel))
	h.Write(s.BodyBytes)
	return h.Sum(nil)
}

// signedMessage is the label, the SHA-256 of the body, the signer kind and
// lp(signer device id, empty for the recovery key). The design writes the
// label with no length prefix.
func (s Statement) signedMessage() []byte {
	digest := sha256.Sum256(s.BodyBytes)
	msg := make([]byte, 0, len(signLabel)+hashSize+3+len(s.SignerDeviceID))
	msg = append(msg, signLabel...)
	msg = append(msg, digest[:]...)
	msg = append(msg, byte(s.SignerKind))
	msg = append(msg, byte(len(s.SignerDeviceID)>>8), byte(len(s.SignerDeviceID)))
	msg = append(msg, s.SignerDeviceID...)
	return msg
}

// VerifySignature checks the signature under key. Go's crypto/ed25519 is the
// check here; clients verify strictly. An honest signer's signature passes
// both.
func (s Statement) VerifySignature(key []byte) bool {
	return len(key) == ed25519.PublicKeySize && ed25519.Verify(ed25519.PublicKey(key), s.signedMessage(), s.Signature)
}

// Find returns the entry of deviceID.
func (b Body) Find(deviceID string) (Entry, bool) {
	i := sort.Search(len(b.Entries), func(i int) bool { return b.Entries[i].DeviceID >= deviceID })
	if i < len(b.Entries) && b.Entries[i].DeviceID == deviceID {
		return b.Entries[i], true
	}
	return Entry{}, false
}

// History is what a step is checked against: the head and every pair any
// earlier version listed. The server derives it from device_list_devices.
type History struct {
	// Head is the newest version, or nil when the account has no list.
	Head *Statement
	// Seen reports whether deviceID, or this exact signing key under any
	// device id, was listed by any version up to the head.
	SeenDevice func(deviceID string) bool
	SeenKey    func(key []byte) bool
}

// CheckStep applies the chain rules to next, given the history. It checks the
// account, the version, prev_hash, the change kind, who signed, the signature,
// and how the entries and recovery key differ from the head. It does not know
// the database: whether each listed device exists, is live and has the same
// signing key, and whether the route's own action matches, are the caller's
// checks (docs/designs/L1-approved-device-list.md, "Checks on every upload").
func CheckStep(accountID string, history History, next Statement) error {
	body := next.Body
	if body.AccountID != accountID {
		return ErrWrongAccount
	}
	head := history.Head
	if head == nil {
		return checkGenesis(next)
	}
	if body.Version != head.Body.Version+1 {
		return ErrVersionGap
	}
	if !bytes.Equal(body.PrevHash, head.Hash()) {
		return ErrPrevHash
	}
	prev := head.Body
	switch body.Change {
	case ChangeAdd:
		if next.SignerKind != SignerDevice {
			return ErrBadSigner
		}
		if !sameRecovery(prev, body) {
			return ErrBadRecoveryKey
		}
		added, ok := onlyAdded(prev, body)
		if !ok || len(body.Entries) != len(prev.Entries)+1 {
			return ErrBadEntries
		}
		if _, listed := body.Find(next.SignerDeviceID); !listed {
			// The signer must be listed in prev and stay listed.
			return ErrBadSigner
		}
		if _, inPrev := prev.Find(next.SignerDeviceID); !inPrev {
			return ErrBadSigner
		}
		if history.SeenDevice(added.DeviceID) || history.SeenKey(added.SigningKey) {
			return ErrReturningDevice
		}
	case ChangeRemove:
		if next.SignerKind != SignerDevice {
			return ErrBadSigner
		}
		if !sameRecovery(prev, body) {
			return ErrBadRecoveryKey
		}
		// Every entry kept must be one prev listed, with its key; at least one
		// pair goes. The list is never empty (Parse refuses count 0).
		if len(body.Entries) >= len(prev.Entries) {
			return ErrBadEntries
		}
		for _, entry := range body.Entries {
			old, ok := prev.Find(entry.DeviceID)
			if !ok || !bytes.Equal(old.SigningKey, entry.SigningKey) {
				return ErrBadEntries
			}
		}
		if _, inPrev := prev.Find(next.SignerDeviceID); !inPrev {
			return ErrBadSigner
		}
	case ChangeRecovery:
		if next.SignerKind != SignerRecoveryKey {
			return ErrBadSigner
		}
		if prev.RecoveryKey == nil {
			return ErrBadSigner
		}
		if !sameRecovery(prev, body) {
			return ErrBadRecoveryKey
		}
		if len(body.Entries) != 1 {
			return ErrBadEntries
		}
		if history.SeenDevice(body.Entries[0].DeviceID) || history.SeenKey(body.Entries[0].SigningKey) {
			return ErrReturningDevice
		}
	case ChangeRecoveryKey:
		if next.SignerKind != SignerDevice {
			return ErrBadSigner
		}
		if !sameEntries(prev, body) {
			return ErrBadEntries
		}
		if sameRecovery(prev, body) {
			// The recovery key must actually change: set, replaced or removed.
			return ErrBadRecoveryKey
		}
		if _, inPrev := prev.Find(next.SignerDeviceID); !inPrev {
			return ErrBadSigner
		}
	default:
		// A genesis (1, 6) can only be version 1.
		return ErrBadChange
	}
	switch next.SignerKind {
	case SignerDevice:
		signer, _ := prev.Find(next.SignerDeviceID)
		if !next.VerifySignature(signer.SigningKey) {
			return ErrBadSignature
		}
	case SignerRecoveryKey:
		if !next.VerifySignature(prev.RecoveryKey) {
			return ErrBadSignature
		}
	}
	return nil
}

// checkGenesis is the first version of a chain: change 1 (the one registering
// device lists itself and signs) or change 6 (a listed device signs the
// account's reviewed devices). Neither carries a recovery key.
func checkGenesis(next Statement) error {
	body := next.Body
	if body.Version != 1 {
		return ErrNotGenesis
	}
	if body.Change != ChangeGenesis && body.Change != ChangeMigrationGenesis {
		return ErrNotGenesis
	}
	if body.RecoveryKey != nil {
		return ErrBadRecoveryKey
	}
	if next.SignerKind != SignerDevice {
		return ErrBadSigner
	}
	signer, listed := body.Find(next.SignerDeviceID)
	if !listed {
		return ErrBadSigner
	}
	if body.Change == ChangeGenesis && len(body.Entries) != 1 {
		return ErrBadEntries
	}
	if !next.VerifySignature(signer.SigningKey) {
		return ErrBadSignature
	}
	return nil
}

func sameRecovery(prev, next Body) bool {
	return bytes.Equal(prev.RecoveryKey, next.RecoveryKey) && (prev.RecoveryKey == nil) == (next.RecoveryKey == nil)
}

func sameEntries(prev, next Body) bool {
	if len(prev.Entries) != len(next.Entries) {
		return false
	}
	for i := range prev.Entries {
		if prev.Entries[i].DeviceID != next.Entries[i].DeviceID || !bytes.Equal(prev.Entries[i].SigningKey, next.Entries[i].SigningKey) {
			return false
		}
	}
	return true
}

// onlyAdded returns the one entry next has that prev lacks, when next is prev
// plus exactly that entry with every old pair unchanged.
func onlyAdded(prev, next Body) (Entry, bool) {
	var added []Entry
	for _, entry := range next.Entries {
		old, ok := prev.Find(entry.DeviceID)
		switch {
		case !ok:
			added = append(added, entry)
		case !bytes.Equal(old.SigningKey, entry.SigningKey):
			return Entry{}, false
		}
	}
	if len(added) != 1 {
		return Entry{}, false
	}
	return added[0], true
}

// Removed returns the device ids prev lists that next does not.
func Removed(prev, next Body) []string {
	var out []string
	for _, entry := range prev.Entries {
		if _, ok := next.Find(entry.DeviceID); !ok {
			out = append(out, entry.DeviceID)
		}
	}
	return out
}

// Added returns the entries next lists that prev does not (all of next's
// entries when prev is the zero Body).
func Added(prev, next Body) []Entry {
	var out []Entry
	for _, entry := range next.Entries {
		if _, ok := prev.Find(entry.DeviceID); !ok {
			out = append(out, entry)
		}
	}
	return out
}

// Encode serialises a body, and a statement when signed, in the VDL1 byte
// format. The server never calls it; tests use it to build fixtures.
func Encode(body Body, kind SignerKind, signerDeviceID string, signature []byte) []byte {
	var out []byte
	out = append(out, bodyMagic...)
	out = append(out, formatVersion)
	out = appendLP(out, body.AccountID)
	out = appendU64(out, body.Version)
	out = append(out, body.PrevHash...)
	out = appendU64(out, body.CreatedAtMs)
	out = append(out, byte(body.Change), byte(len(body.Entries)))
	for _, entry := range body.Entries {
		out = appendLP(out, entry.DeviceID)
		out = append(out, entry.SigningKey...)
	}
	if body.RecoveryKey == nil {
		out = append(out, 0)
	} else {
		out = append(out, 1)
		out = append(out, body.RecoveryKey...)
	}
	if signature == nil {
		return out
	}
	out = append(out, byte(kind))
	out = appendLP(out, signerDeviceID)
	return append(out, signature...)
}

// Sign builds a signed statement with key. For SignerRecoveryKey,
// signerDeviceID must be empty. It is for tests and tools.
func Sign(body Body, kind SignerKind, signerDeviceID string, key ed25519.PrivateKey) []byte {
	unsigned := Encode(body, kind, signerDeviceID, nil)
	probe := Statement{BodyBytes: unsigned, SignerKind: kind, SignerDeviceID: signerDeviceID}
	return Encode(body, kind, signerDeviceID, ed25519.Sign(key, probe.signedMessage()))
}

func appendLP(out []byte, s string) []byte {
	out = append(out, byte(len(s)>>8), byte(len(s)))
	return append(out, s...)
}

func appendU64(out []byte, v uint64) []byte {
	return append(out, byte(v>>56), byte(v>>48), byte(v>>40), byte(v>>32), byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
}
