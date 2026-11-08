package devicelist

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"testing"
)

// These tests build statements with the package's own Encode and Sign, and
// also check the byte layout and the hash and signed-message constructions
// against independent byte-by-byte builders written from the design
// (docs/designs/L1-approved-device-list.md, "List format (VDL1)"), so a change
// to either side shows. The shared vector file testing/vectors/l1-device-list-v1.json
// belongs to L1-1 (crypto core); when it lands, a Go test over it belongs here.

type actor struct {
	id   string
	pub  ed25519.PublicKey
	priv ed25519.PrivateKey
}

func newActor(id string, seedByte byte) actor {
	seed := bytes.Repeat([]byte{seedByte}, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	return actor{id: id, pub: priv.Public().(ed25519.PublicKey), priv: priv}
}

func (a actor) entry() Entry { return Entry{DeviceID: a.id, SigningKey: a.pub} }

const testAccount = "acct_1"

func sorted(actors ...actor) []Entry {
	entries := make([]Entry, 0, len(actors))
	for _, a := range actors {
		entries = append(entries, a.entry())
	}
	for i := 1; i < len(entries); i++ {
		for j := i; j > 0 && entries[j].DeviceID < entries[j-1].DeviceID; j-- {
			entries[j], entries[j-1] = entries[j-1], entries[j]
		}
	}
	return entries
}

func zeroHash() []byte { return make([]byte, 32) }

func mustParse(t *testing.T, raw []byte) Statement {
	t.Helper()
	statement, err := Parse(raw)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return statement
}

// chainFixture tracks what the server's History would hold.
type chainFixture struct {
	t       *testing.T
	head    *Statement
	devices map[string]bool
	keys    map[string]bool
}

func newChain(t *testing.T) *chainFixture {
	return &chainFixture{t: t, devices: map[string]bool{}, keys: map[string]bool{}}
}

func (c *chainFixture) history() History {
	return History{
		Head:       c.head,
		SeenDevice: func(id string) bool { return c.devices[id] },
		SeenKey:    func(k []byte) bool { return c.keys[string(k)] },
	}
}

func (c *chainFixture) accept(raw []byte) {
	c.t.Helper()
	statement := mustParse(c.t, raw)
	if err := CheckStep(testAccount, c.history(), statement); err != nil {
		c.t.Fatalf("expected step to be accepted: %v", err)
	}
	c.head = &statement
	for _, entry := range statement.Body.Entries {
		c.devices[entry.DeviceID] = true
		c.keys[string(entry.SigningKey)] = true
	}
}

func (c *chainFixture) refuse(raw []byte, want error) {
	c.t.Helper()
	statement, err := Parse(raw)
	if err != nil {
		if want == ErrMalformed {
			return
		}
		c.t.Fatalf("parse: %v, want %v", err, want)
	}
	if err := CheckStep(testAccount, c.history(), statement); !errors.Is(err, want) {
		c.t.Fatalf("CheckStep = %v, want %v", err, want)
	}
}

func (c *chainFixture) next(change Change, entries []Entry, recovery []byte) Body {
	body := Body{AccountID: testAccount, Version: 1, PrevHash: zeroHash(), CreatedAtMs: 1700000000000, Change: change, Entries: entries, RecoveryKey: recovery}
	if c.head != nil {
		body.Version = c.head.Body.Version + 1
		body.PrevHash = c.head.Hash()
	}
	return body
}

func TestLayoutHashAndSignedMessageMatchTheDesign(t *testing.T) {
	a := newActor("dev_a", 1)
	body := Body{AccountID: testAccount, Version: 1, PrevHash: zeroHash(), CreatedAtMs: 0x0102030405060708, Change: ChangeGenesis, Entries: []Entry{a.entry()}}
	raw := Sign(body, SignerDevice, a.id, a.priv)

	// The body, written out field by field.
	want := []byte("VDL1")
	want = append(want, 1)
	want = append(want, 0, byte(len(testAccount)))
	want = append(want, testAccount...)
	want = append(want, 0, 0, 0, 0, 0, 0, 0, 1)
	want = append(want, zeroHash()...)
	want = append(want, 1, 2, 3, 4, 5, 6, 7, 8)
	want = append(want, 1, 1)
	want = append(want, 0, byte(len(a.id)))
	want = append(want, a.id...)
	want = append(want, a.pub...)
	want = append(want, 0)
	bodyBytes := bytes.Clone(want)
	if !bytes.HasPrefix(raw, bodyBytes) {
		t.Fatalf("body bytes differ:\n got %x\nwant %x", raw[:len(bodyBytes)], bodyBytes)
	}
	statement := mustParse(t, raw)
	if !bytes.Equal(statement.BodyBytes, bodyBytes) {
		t.Fatal("BodyBytes is not the exact body")
	}
	// list_hash = SHA-256("veritra-l1-device-list-hash-v1" | body)
	hash := sha256.Sum256(append([]byte("veritra-l1-device-list-hash-v1"), bodyBytes...))
	if !bytes.Equal(statement.Hash(), hash[:]) {
		t.Fatal("list_hash differs from the design")
	}
	// signed message = "veritra-l1-device-list-sig-v1" | SHA-256(body) | kind | lp(signer)
	digest := sha256.Sum256(bodyBytes)
	message := []byte("veritra-l1-device-list-sig-v1")
	message = append(message, digest[:]...)
	message = append(message, 1, 0, byte(len(a.id)))
	message = append(message, a.id...)
	if !ed25519.Verify(a.pub, message, statement.Signature) {
		t.Fatal("signature does not verify over the design's signed message")
	}
	// Signature trailer: kind, lp(device id), 64 bytes.
	tail := raw[len(bodyBytes):]
	if len(tail) != 1+2+len(a.id)+64 || tail[0] != 1 {
		t.Fatalf("trailer layout: %x", tail)
	}
	// A recovery-key signature has an empty signer id.
	rk := newActor("", 9)
	recovery := Body{AccountID: testAccount, Version: 2, PrevHash: bytes.Repeat([]byte{1}, 32), Change: ChangeRecovery, Entries: []Entry{a.entry()}, RecoveryKey: rk.pub}
	rraw := Sign(recovery, SignerRecoveryKey, "", rk.priv)
	rst := mustParse(t, rraw)
	if rst.SignerKind != SignerRecoveryKey || rst.SignerDeviceID != "" || !rst.VerifySignature(rk.pub) {
		t.Fatal("recovery-key statement")
	}
}

func TestParseIsStrict(t *testing.T) {
	a, b := newActor("dev_a", 1), newActor("dev_b", 2)
	good := Sign(Body{AccountID: testAccount, Version: 1, PrevHash: zeroHash(), Change: ChangeMigrationGenesis, Entries: sorted(a, b)}, SignerDevice, a.id, a.priv)
	if _, err := Parse(good); err != nil {
		t.Fatalf("good statement refused: %v", err)
	}
	withEntries := func(change Change, entries []Entry, version uint64, prev []byte, recovery []byte) []byte {
		return Sign(Body{AccountID: testAccount, Version: version, PrevHash: prev, Change: change, Entries: entries, RecoveryKey: recovery}, SignerDevice, a.id, a.priv)
	}
	cases := map[string][]byte{
		"empty":             {},
		"truncated":         good[:len(good)-1],
		"trailing byte":     append(bytes.Clone(good), 0),
		"bad magic":         append([]byte("VDL2"), good[4:]...),
		"bad format":        func() []byte { m := bytes.Clone(good); m[4] = 2; return m }(),
		"unsorted entries":  withEntries(ChangeMigrationGenesis, []Entry{b.entry(), a.entry()}, 1, zeroHash(), nil),
		"repeated id":       withEntries(ChangeMigrationGenesis, []Entry{a.entry(), a.entry()}, 1, zeroHash(), nil),
		"repeated key":      withEntries(ChangeMigrationGenesis, []Entry{a.entry(), {DeviceID: "dev_b", SigningKey: a.pub}}, 1, zeroHash(), nil),
		"no entries":        withEntries(ChangeMigrationGenesis, nil, 1, zeroHash(), nil),
		"17 entries":        withEntries(ChangeMigrationGenesis, manyEntries(17), 1, zeroHash(), nil),
		"version 0":         withEntries(ChangeMigrationGenesis, sorted(a), 0, zeroHash(), nil),
		"v1 with prev hash": withEntries(ChangeMigrationGenesis, sorted(a), 1, bytes.Repeat([]byte{1}, 32), nil),
		"change 0":          withEntries(0, sorted(a), 1, zeroHash(), nil),
		"change 7":          withEntries(7, sorted(a), 1, zeroHash(), nil),
		"short key":         withEntries(ChangeGenesis, []Entry{{DeviceID: "dev_a", SigningKey: []byte{1}}}, 1, zeroHash(), nil),
	}
	for name, raw := range cases {
		if _, err := Parse(raw); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s: Parse = %v, want ErrMalformed", name, err)
		}
	}
	// 16 entries are fine; the 4 KiB limit is on the whole statement.
	if _, err := Parse(withEntries(ChangeMigrationGenesis, manyEntries(16), 1, zeroHash(), nil)); err != nil {
		t.Errorf("16 entries: %v", err)
	}
	if _, err := Parse(bytes.Repeat([]byte{0}, MaxStatementBytes+1)); !errors.Is(err, ErrMalformed) {
		t.Errorf("oversize: %v", err)
	}
	// Bad flag value, bad signer kind, a recovery signer that names a device.
	flag := bytes.Clone(good)
	flagAt := len(good) - 64 - (1 + 2 + len(a.id)) - 1
	flag[flagAt] = 2
	if _, err := Parse(flag); !errors.Is(err, ErrMalformed) {
		t.Errorf("recovery flag 2: %v", err)
	}
	kind := bytes.Clone(good)
	kind[len(good)-64-(1+2+len(a.id))] = 3
	if _, err := Parse(kind); !errors.Is(err, ErrMalformed) {
		t.Errorf("signer kind 3: %v", err)
	}
	rk := newActor("", 9)
	namedRecovery := Sign(Body{AccountID: testAccount, Version: 2, PrevHash: bytes.Repeat([]byte{1}, 32), Change: ChangeRecovery, Entries: sorted(a)}, SignerRecoveryKey, "dev_x", rk.priv)
	if _, err := Parse(namedRecovery); !errors.Is(err, ErrMalformed) {
		t.Errorf("recovery signer naming a device: %v", err)
	}
	// An id over 128 bytes (the crypto core's limit) or empty is refused; 128 is fine.
	long := string(bytes.Repeat([]byte("x"), MaxIDBytes+1))
	if _, err := Parse(withEntries(ChangeMigrationGenesis, []Entry{{DeviceID: long, SigningKey: a.pub}}, 1, zeroHash(), nil)); !errors.Is(err, ErrMalformed) {
		t.Errorf("129-byte device id: %v", err)
	}
	if _, err := Parse(withEntries(ChangeMigrationGenesis, []Entry{{DeviceID: long[:MaxIDBytes], SigningKey: a.pub}}, 1, zeroHash(), nil)); err != nil {
		t.Errorf("128-byte device id: %v", err)
	}
	// A listed key or recovery key that is not a usable point is refused: a
	// small-order point, a non-canonical encoding, and bytes that are not on
	// the curve.
	smallOrder := append([]byte{1}, make([]byte, 31)...)
	nonCanonical := bytes.Repeat([]byte{0xff}, 32)
	nonCanonical[31] = 0x7f // y = 2^255 - 1, over the field prime
	for name, key := range map[string][]byte{"small order": smallOrder, "non-canonical": nonCanonical} {
		if _, err := Parse(withEntries(ChangeMigrationGenesis, []Entry{{DeviceID: "dev_a", SigningKey: key}}, 1, zeroHash(), nil)); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s signing key: %v", name, err)
		}
		if _, err := Parse(withEntries(ChangeRecoveryKey, sorted(a), 2, bytes.Repeat([]byte{1}, 32), key)); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s recovery key: %v", name, err)
		}
	}
	// Version 1 must be a genesis and a genesis must be version 1.
	if _, err := Parse(withEntries(ChangeAdd, sorted(a), 1, zeroHash(), nil)); !errors.Is(err, ErrMalformed) {
		t.Errorf("version 1 that is an add: %v", err)
	}
	if _, err := Parse(withEntries(ChangeGenesis, sorted(a), 2, bytes.Repeat([]byte{1}, 32), nil)); !errors.Is(err, ErrMalformed) {
		t.Errorf("version 2 that is a genesis: %v", err)
	}
	if _, err := Parse(withEntries(ChangeMigrationGenesis, []Entry{{DeviceID: "", SigningKey: a.pub}}, 1, zeroHash(), nil)); !errors.Is(err, ErrMalformed) {
		t.Errorf("empty device id: %v", err)
	}
}

func manyEntries(n int) []Entry {
	entries := make([]Entry, 0, n)
	for i := 0; i < n; i++ {
		a := newActor(string([]byte{'d', byte('a' + i)}), byte(100+i))
		entries = append(entries, a.entry())
	}
	return entries
}

func TestChainEveryChangeKind(t *testing.T) {
	a, b, c, d := newActor("dev_a", 1), newActor("dev_b", 2), newActor("dev_c", 3), newActor("dev_d", 4)
	rk1, rk2 := newActor("", 11), newActor("", 12)
	chain := newChain(t)

	// 1 genesis.
	chain.accept(Sign(chain.next(ChangeGenesis, sorted(a), nil), SignerDevice, a.id, a.priv))
	// 2 add, signed by a listed device.
	chain.accept(Sign(chain.next(ChangeAdd, sorted(a, b), nil), SignerDevice, a.id, a.priv))
	// 5 recovery key: set, replaced, removed.
	chain.accept(Sign(chain.next(ChangeRecoveryKey, sorted(a, b), rk1.pub), SignerDevice, b.id, b.priv))
	chain.accept(Sign(chain.next(ChangeRecoveryKey, sorted(a, b), rk2.pub), SignerDevice, a.id, a.priv))
	// 2 add keeps the recovery key.
	chain.accept(Sign(chain.next(ChangeAdd, sorted(a, b, c), rk2.pub), SignerDevice, b.id, b.priv))
	// 3 remove: a device may remove itself.
	chain.accept(Sign(chain.next(ChangeRemove, sorted(a, c), rk2.pub), SignerDevice, b.id, b.priv))
	// 4 recovery: signed by the head's recovery key, one new pair, key unchanged.
	chain.accept(Sign(chain.next(ChangeRecovery, sorted(d), rk2.pub), SignerRecoveryKey, "", rk2.priv))
	if got := chain.head.Body.Version; got != 7 {
		t.Fatalf("head version %d", got)
	}
}

func TestChainRuleViolations(t *testing.T) {
	a, b, c, x := newActor("dev_a", 1), newActor("dev_b", 2), newActor("dev_c", 3), newActor("dev_x", 7)
	rk, rkOther := newActor("", 11), newActor("", 12)
	build := func() *chainFixture {
		chain := newChain(t)
		chain.accept(Sign(chain.next(ChangeGenesis, sorted(a), nil), SignerDevice, a.id, a.priv))
		chain.accept(Sign(chain.next(ChangeAdd, sorted(a, b), nil), SignerDevice, a.id, a.priv))
		chain.accept(Sign(chain.next(ChangeRecoveryKey, sorted(a, b), rk.pub), SignerDevice, a.id, a.priv))
		return chain
	}
	chain := build()
	sign := func(body Body, signer actor) []byte { return Sign(body, SignerDevice, signer.id, signer.priv) }

	t.Run("version", func(t *testing.T) {
		body := chain.next(ChangeAdd, sorted(a, b, c), rk.pub)
		body.Version++
		chain.refuse(sign(body, a), ErrVersionGap)
		body.Version -= 2
		chain.refuse(sign(body, a), ErrVersionGap)
	})
	t.Run("prev_hash", func(t *testing.T) {
		body := chain.next(ChangeAdd, sorted(a, b, c), rk.pub)
		body.PrevHash = bytes.Repeat([]byte{9}, 32)
		chain.refuse(sign(body, a), ErrPrevHash)
	})
	t.Run("account", func(t *testing.T) {
		body := chain.next(ChangeAdd, sorted(a, b, c), rk.pub)
		body.AccountID = "acct_2"
		chain.refuse(sign(body, a), ErrWrongAccount)
	})
	t.Run("genesis on a head", func(t *testing.T) {
		body := Body{AccountID: testAccount, Version: 1, PrevHash: zeroHash(), Change: ChangeGenesis, Entries: sorted(a)}
		chain.refuse(sign(body, a), ErrVersionGap)
		body.Change = ChangeMigrationGenesis
		chain.refuse(sign(body, a), ErrVersionGap)
	})
	t.Run("a genesis kind after version 1 (not even well-formed)", func(t *testing.T) {
		body := chain.next(ChangeMigrationGenesis, sorted(a, b), rk.pub)
		chain.refuse(sign(body, a), ErrMalformed)
	})
	t.Run("add signed by an unlisted device", func(t *testing.T) {
		chain.refuse(sign(chain.next(ChangeAdd, sorted(a, b, c), rk.pub), x), ErrBadSigner)
	})
	t.Run("add signed by the recovery key", func(t *testing.T) {
		chain.refuse(Sign(chain.next(ChangeAdd, sorted(a, b, c), rk.pub), SignerRecoveryKey, "", rk.priv), ErrBadSigner)
	})
	t.Run("add two devices", func(t *testing.T) {
		chain.refuse(sign(chain.next(ChangeAdd, sorted(a, b, c, x), rk.pub), a), ErrBadEntries)
	})
	t.Run("add that swaps a key", func(t *testing.T) {
		swapped := sorted(a, b, c)
		swapped[0].SigningKey = x.pub
		chain.refuse(sign(chain.next(ChangeAdd, swapped, rk.pub), a), ErrBadEntries)
	})
	t.Run("add that drops one", func(t *testing.T) {
		chain.refuse(sign(chain.next(ChangeAdd, sorted(a, c), rk.pub), a), ErrBadEntries)
	})
	t.Run("add that changes the recovery key", func(t *testing.T) {
		chain.refuse(sign(chain.next(ChangeAdd, sorted(a, b, c), rkOther.pub), a), ErrBadRecoveryKey)
		chain.refuse(sign(chain.next(ChangeAdd, sorted(a, b, c), nil), a), ErrBadRecoveryKey)
	})
	t.Run("signed with the wrong key", func(t *testing.T) {
		impostor := actor{id: a.id, pub: a.pub, priv: x.priv}
		chain.refuse(sign(chain.next(ChangeAdd, sorted(a, b, c), rk.pub), impostor), ErrBadSignature)
	})
	t.Run("remove nothing or add", func(t *testing.T) {
		chain.refuse(sign(chain.next(ChangeRemove, sorted(a, b), rk.pub), a), ErrBadEntries)
		chain.refuse(sign(chain.next(ChangeRemove, sorted(a, b, c), rk.pub), a), ErrBadEntries)
	})
	t.Run("remove that invents a pair", func(t *testing.T) {
		chain.refuse(sign(chain.next(ChangeRemove, sorted(c), rk.pub), a), ErrBadEntries)
	})
	t.Run("remove signed by an unlisted device", func(t *testing.T) {
		chain.refuse(sign(chain.next(ChangeRemove, sorted(a), rk.pub), x), ErrBadSigner)
	})
	t.Run("remove everyone", func(t *testing.T) {
		// A count of 0 is not even a well-formed statement.
		chain.refuse(sign(chain.next(ChangeRemove, nil, rk.pub), a), ErrMalformed)
	})
	t.Run("recovery key change", func(t *testing.T) {
		chain.refuse(sign(chain.next(ChangeRecoveryKey, sorted(a, b, c), rkOther.pub), a), ErrBadEntries)
		chain.refuse(sign(chain.next(ChangeRecoveryKey, sorted(a), rkOther.pub), a), ErrBadEntries)
		chain.refuse(sign(chain.next(ChangeRecoveryKey, sorted(a, b), rkOther.pub), x), ErrBadSigner)
		chain.refuse(Sign(chain.next(ChangeRecoveryKey, sorted(a, b), rkOther.pub), SignerRecoveryKey, "", rk.priv), ErrBadSigner)
	})
	t.Run("recovery key change that leaves the key as it is", func(t *testing.T) {
		chain.refuse(sign(chain.next(ChangeRecoveryKey, sorted(a, b), rk.pub), a), ErrBadRecoveryKey)
	})
	t.Run("recovery", func(t *testing.T) {
		// Signed by a device, not the recovery key.
		chain.refuse(sign(chain.next(ChangeRecovery, sorted(c), rk.pub), a), ErrBadSigner)
		// Signed by another key than the head's.
		chain.refuse(Sign(chain.next(ChangeRecovery, sorted(c), rk.pub), SignerRecoveryKey, "", rkOther.priv), ErrBadSignature)
		// More than one pair, or the recovery key changed.
		chain.refuse(Sign(chain.next(ChangeRecovery, sorted(c, x), rk.pub), SignerRecoveryKey, "", rk.priv), ErrBadEntries)
		chain.refuse(Sign(chain.next(ChangeRecovery, sorted(c), rkOther.pub), SignerRecoveryKey, "", rk.priv), ErrBadRecoveryKey)
		// A device that is already listed is not new to the chain.
		chain.refuse(Sign(chain.next(ChangeRecovery, sorted(a), rk.pub), SignerRecoveryKey, "", rk.priv), ErrReturningDevice)
	})
	t.Run("recovery on a head with no recovery key", func(t *testing.T) {
		bare := newChain(t)
		bare.accept(sign(bare.next(ChangeGenesis, sorted(a), nil), a))
		bare.refuse(Sign(bare.next(ChangeRecovery, sorted(c), nil), SignerRecoveryKey, "", rk.priv), ErrBadSigner)
	})
	t.Run("genesis shapes", func(t *testing.T) {
		empty := newChain(t)
		genesis := func(change Change, entries []Entry, rkey []byte, signer actor) []byte {
			return sign(empty.next(change, entries, rkey), signer)
		}
		empty.refuse(genesis(ChangeGenesis, sorted(a, b), nil, a), ErrBadEntries)              // genesis lists exactly one
		empty.refuse(genesis(ChangeGenesis, sorted(a), nil, b), ErrBadSigner)                  // signer must be the listed device
		empty.refuse(genesis(ChangeGenesis, sorted(a), rk.pub, a), ErrBadRecoveryKey)          // no recovery key at genesis
		empty.refuse(genesis(ChangeMigrationGenesis, sorted(a), rk.pub, a), ErrBadRecoveryKey) // nor at a migration genesis
		empty.refuse(genesis(ChangeAdd, sorted(a), nil, a), ErrMalformed)                      // version 1 must be a genesis
		empty.accept(genesis(ChangeMigrationGenesis, sorted(a, b, c), nil, b))                 // a migration genesis lists the reviewed devices
		fresh := newChain(t)
		bad := fresh.next(ChangeAdd, sorted(a), nil)
		bad.Version = 2
		bad.PrevHash = bytes.Repeat([]byte{1}, 32)
		fresh.refuse(sign(bad, a), ErrNotGenesis) // an add with no head: the chain has no genesis
	})
}

func TestNoReturn(t *testing.T) {
	a, b, c := newActor("dev_a", 1), newActor("dev_b", 2), newActor("dev_c", 3)
	rk := newActor("", 11)
	chain := newChain(t)
	sign := func(body Body, signer actor) []byte { return Sign(body, SignerDevice, signer.id, signer.priv) }
	chain.accept(sign(chain.next(ChangeGenesis, sorted(a), nil), a))
	chain.accept(sign(chain.next(ChangeAdd, sorted(a, b), nil), a))
	chain.accept(sign(chain.next(ChangeRecoveryKey, sorted(a, b), rk.pub), a))
	chain.accept(sign(chain.next(ChangeRemove, sorted(a), rk.pub), a)) // b leaves
	// b never comes back, under its id or under its key.
	chain.refuse(sign(chain.next(ChangeAdd, sorted(a, b), rk.pub), a), ErrReturningDevice)
	rebadged := Entry{DeviceID: "dev_z", SigningKey: b.pub}
	chain.refuse(sign(chain.next(ChangeAdd, []Entry{a.entry(), rebadged}, rk.pub), a), ErrReturningDevice)
	// A removed id with a new key is the same device id coming back.
	again := Entry{DeviceID: "dev_b", SigningKey: c.pub}
	chain.refuse(sign(chain.next(ChangeAdd, []Entry{a.entry(), again}, rk.pub), a), ErrReturningDevice)
	// A recovered-away device does not return either.
	chain.refuse(Sign(chain.next(ChangeRecovery, sorted(b), rk.pub), SignerRecoveryKey, "", rk.priv), ErrReturningDevice)
	// A genuinely new pair is fine.
	chain.accept(sign(chain.next(ChangeAdd, sorted(a, c), rk.pub), a))
	// One key, one device: the new key cannot be reused under another id.
	d := Entry{DeviceID: "dev_d", SigningKey: c.pub}
	// (Within one version it is not even well-formed.)
	chain.refuse(sign(chain.next(ChangeAdd, []Entry{a.entry(), c.entry(), d}, rk.pub), a), ErrMalformed)
}

// The signature is outside list_hash, so another signature over the same body
// does not fork the chain; and a body tampered after signing fails.
func TestHashExcludesSignatureAndSignatureCoversBody(t *testing.T) {
	a := newActor("dev_a", 1)
	body := Body{AccountID: testAccount, Version: 1, PrevHash: zeroHash(), CreatedAtMs: 5, Change: ChangeGenesis, Entries: sorted(a)}
	first := mustParse(t, Sign(body, SignerDevice, a.id, a.priv))
	// Ed25519 is deterministic; flip the signature to prove the hash ignores it.
	altered := bytes.Clone(first.Raw)
	altered[len(altered)-1] ^= 1
	second := mustParse(t, altered)
	if !bytes.Equal(first.Hash(), second.Hash()) {
		t.Fatal("list_hash depends on the signature")
	}
	if second.VerifySignature(a.pub) {
		t.Fatal("a changed signature verified")
	}
	tampered := bytes.Clone(first.Raw)
	tampered[len(testAccount)+8+1+2+8+32] ^= 1 // inside created_at_ms
	if mustParse(t, tampered).VerifySignature(a.pub) {
		t.Fatal("a changed body verified")
	}
	// The signer kind and id are signed too.
	rebound := bytes.Clone(first.Raw)
	copy(rebound[len(rebound)-64-len(a.id):], "dev_b")
	if mustParse(t, rebound).VerifySignature(a.pub) {
		t.Fatal("the signature does not cover the signer id")
	}
}
