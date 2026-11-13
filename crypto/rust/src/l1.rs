//! L1 approved-device list (`docs/designs/L1-approved-device-list.md`, step
//! L1-1, decision D94; ABI 14).
//!
//! One signed chain per account. A version lists the devices allowed to hold
//! the account's MLS leaves, names the hash of the version before it and is
//! signed by a device on that previous version, or by the key derived from
//! the recovery key (`recovery::list_*`). Nothing here is wired into the app.
//! Every piece needs the independent crypto review before release.
//!
//! ```text
//! lp(x) = u16 big-endian length | x          integers are big-endian
//! body  = "VDL1" | u8 format=1 | lp(account_id) | u64 version | [32] prev_hash
//!         | u64 created_at_ms | u8 change | u8 count (1..16)
//!         | count x ( lp(device_id) | [32] signing_key )    sorted by id bytes
//!         | u8 has_recovery | [32] recovery_key (only when has_recovery = 1)
//!         [ | u8 n (1..count) | n x ( lp(device_id) | [32] frank_key ) ]
//!                             format 2 only; sorted by id, ids listed
//! statement = body | u8 signer_kind | lp(signer device_id, empty for kind 2)
//!             | [64] signature
//! signed message = "veritra-l1-device-list-sig-v1" | SHA-256(body)
//!                  | u8 signer_kind | lp(signer device_id)
//! list_hash(v)   = SHA-256("veritra-l1-device-list-hash-v1" | body)
//! ```
//!
//! Format 2 (L2-3, ABI 26) adds the last section: each listed device's
//! X25519 franking key (`crate::l2_frank`). A body with no franking key is
//! written as format 1, byte for byte the earlier format, so every format-1
//! statement and the format-1 vector stay valid; a format-2 body always
//! names at least one key. A device's franking key is fixed: once a version
//! lists it, no later version may change or drop it while the device stays
//! listed. It is set by the device itself, in its genesis (1 or 6), in its
//! recovery version (4) or in change 7, which sets only the signer's own key
//! from none to some and changes nothing else. A device added by change 2
//! starts with none. A device without a listed key cannot send sealed
//! (`docs/crypto.md`, "Franking a sealed message").
//!
//! `created_at_ms` is the signer's clock: carried and shown, never trusted.
//! Parsing is strict: one canonical spelling per statement. The signature
//! sits outside the hash, so its malleability cannot fork the chain.
//!
//! Failures come in four kinds so the app can tell them apart: the bytes are
//! not a statement ([`L1Error::Malformed`]), they do not chain onto the
//! version before ([`L1Error::Chain`]), the signer or the change is not
//! allowed ([`L1Error::Rule`]), or the signature fails ([`L1Error::Signature`]).
//! The checks run in that order, so a statement with one fault reports it.

use ed25519_dalek::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};

pub const LABEL_SIG: &[u8] = b"veritra-l1-device-list-sig-v1";
pub const LABEL_HASH: &[u8] = b"veritra-l1-device-list-hash-v1";
pub const MAGIC: &[u8; 4] = b"VDL1";
pub const FORMAT: u8 = 1;
/// The format of a body that lists at least one franking key.
pub const FORMAT_FRANK: u8 = 2;
/// Largest whole statement.
pub const MAX_STATEMENT_BYTES: usize = 4096;
pub const MAX_ENTRIES: usize = 16;
pub const KEY_BYTES: usize = 32;
pub const SIGNATURE_BYTES: usize = 64;
pub const HASH_BYTES: usize = 32;
/// Most pairs a caller may hand over as history.
pub const MAX_HISTORY_PAIRS: usize = 1024;
/// Most statements one chain check reads.
pub const MAX_CHAIN_STATEMENTS: usize = 256;

pub const SIGNER_DEVICE: u8 = 1;
pub const SIGNER_RECOVERY: u8 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum L1Error {
    /// Not a canonical statement (or an input of the wrong shape).
    Malformed,
    /// The signature does not verify under the key the rules name.
    Signature,
    /// Wrong account, version or `prev_hash`, or a chain that does not start
    /// at a genesis.
    Chain,
    /// The signer may not make this change, or the entries are not what the
    /// change allows.
    Rule,
}

impl L1Error {
    /// The name the shared vector uses.
    pub fn name(self) -> &'static str {
        match self {
            Self::Malformed => "malformed",
            Self::Signature => "signature",
            Self::Chain => "chain",
            Self::Rule => "rule",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Change {
    Genesis = 1,
    Add = 2,
    Remove = 3,
    Recovery = 4,
    RecoveryKey = 5,
    MigrationGenesis = 6,
    /// L2-3: a listed device sets its own franking key, from none to some.
    FrankKey = 7,
}

impl Change {
    fn from_byte(byte: u8) -> Option<Self> {
        Some(match byte {
            1 => Self::Genesis,
            2 => Self::Add,
            3 => Self::Remove,
            4 => Self::Recovery,
            5 => Self::RecoveryKey,
            6 => Self::MigrationGenesis,
            7 => Self::FrankKey,
            _ => return None,
        })
    }

    fn is_genesis(self) -> bool {
        matches!(self, Self::Genesis | Self::MigrationGenesis)
    }
}

/// One listed device: its id and its MLS credential signing key.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Pair {
    pub device_id: Vec<u8>,
    pub signing_key: [u8; KEY_BYTES],
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Signer {
    Device(Vec<u8>),
    Recovery,
}

impl Signer {
    fn kind(&self) -> u8 {
        match self {
            Self::Device(_) => SIGNER_DEVICE,
            Self::Recovery => SIGNER_RECOVERY,
        }
    }

    fn id(&self) -> &[u8] {
        match self {
            Self::Device(id) => id,
            Self::Recovery => &[],
        }
    }
}

/// A listed device's X25519 franking key (format 2).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FrankKey {
    pub device_id: Vec<u8>,
    pub key: [u8; KEY_BYTES],
}

/// The signed part of a statement, parsed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Body {
    pub account_id: Vec<u8>,
    pub version: u64,
    pub prev_hash: [u8; HASH_BYTES],
    pub created_at_ms: u64,
    pub change: Change,
    pub entries: Vec<Pair>,
    pub recovery_key: Option<[u8; KEY_BYTES]>,
    /// Sorted by id; every id is listed in `entries`. Empty in format 1.
    pub frank_keys: Vec<FrankKey>,
}

impl Body {
    /// The franking key this version lists for `device_id`.
    pub fn frank_key(&self, device_id: &[u8]) -> Option<&[u8; KEY_BYTES]> {
        self.frank_keys
            .iter()
            .find(|frank| frank.device_id == device_id)
            .map(|frank| &frank.key)
    }
}

/// A parsed statement. `raw` is exactly the bytes that were parsed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Statement {
    pub body: Body,
    pub signer: Signer,
    pub signature: [u8; SIGNATURE_BYTES],
    raw: Vec<u8>,
    body_len: usize,
}

impl Statement {
    pub fn raw(&self) -> &[u8] {
        &self.raw
    }

    pub fn body_bytes(&self) -> &[u8] {
        &self.raw[..self.body_len]
    }

    pub fn list_hash(&self) -> [u8; HASH_BYTES] {
        list_hash(self.body_bytes())
    }
}

// ---- encoding --------------------------------------------------------------

fn put_lp(out: &mut Vec<u8>, value: &[u8]) -> Result<(), L1Error> {
    let len = u16::try_from(value.len()).map_err(|_| L1Error::Malformed)?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

/// The canonical body bytes. Refuses what [`parse_body`] would refuse.
pub fn encode_body(body: &Body) -> Result<Vec<u8>, L1Error> {
    let mut out = Vec::with_capacity(512);
    out.extend_from_slice(MAGIC);
    out.push(if body.frank_keys.is_empty() {
        FORMAT
    } else {
        FORMAT_FRANK
    });
    put_lp(&mut out, &body.account_id)?;
    out.extend_from_slice(&body.version.to_be_bytes());
    out.extend_from_slice(&body.prev_hash);
    out.extend_from_slice(&body.created_at_ms.to_be_bytes());
    out.push(body.change as u8);
    out.push(u8::try_from(body.entries.len()).map_err(|_| L1Error::Malformed)?);
    for pair in &body.entries {
        put_lp(&mut out, &pair.device_id)?;
        out.extend_from_slice(&pair.signing_key);
    }
    match &body.recovery_key {
        None => out.push(0),
        Some(key) => {
            out.push(1);
            out.extend_from_slice(key);
        }
    }
    if !body.frank_keys.is_empty() {
        out.push(u8::try_from(body.frank_keys.len()).map_err(|_| L1Error::Malformed)?);
        for frank in &body.frank_keys {
            put_lp(&mut out, &frank.device_id)?;
            out.extend_from_slice(&frank.key);
        }
    }
    // Whatever was built must read back as itself.
    let (parsed, used) = parse_body_prefix(&out)?;
    if used != out.len() || parsed != *body {
        return Err(L1Error::Malformed);
    }
    Ok(out)
}

/// `body | signer_kind | lp(signer id) | signature`, checked by parsing it
/// back.
pub fn assemble_statement(
    body: &[u8],
    signer: &Signer,
    signature: &[u8; SIGNATURE_BYTES],
) -> Result<Vec<u8>, L1Error> {
    let mut out = Vec::with_capacity(body.len() + 1 + 2 + signer.id().len() + SIGNATURE_BYTES);
    out.extend_from_slice(body);
    out.push(signer.kind());
    put_lp(&mut out, signer.id())?;
    out.extend_from_slice(signature);
    parse_statement(&out)?;
    Ok(out)
}

// ---- parsing ---------------------------------------------------------------

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], L1Error> {
        let end = self.offset.checked_add(count).ok_or(L1Error::Malformed)?;
        let value = self.bytes.get(self.offset..end).ok_or(L1Error::Malformed)?;
        self.offset = end;
        Ok(value)
    }

    fn byte(&mut self) -> Result<u8, L1Error> {
        Ok(self.take(1)?[0])
    }

    fn u64(&mut self) -> Result<u64, L1Error> {
        let bytes: [u8; 8] = self.take(8)?.try_into().map_err(|_| L1Error::Malformed)?;
        Ok(u64::from_be_bytes(bytes))
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], L1Error> {
        self.take(N)?.try_into().map_err(|_| L1Error::Malformed)
    }

    /// `lp(x)` with `min..=max` bytes.
    fn lp(&mut self, min: usize, max: usize) -> Result<&'a [u8], L1Error> {
        let len = self.take(2)?;
        let len = usize::from(u16::from_be_bytes([len[0], len[1]]));
        if len < min || len > max {
            return Err(L1Error::Malformed);
        }
        self.take(len)
    }
}

/// A listed key must be a canonical, valid, non-small-order Ed25519 point:
/// a key the strict verifier would refuse can never sign for its device.
fn check_key(key: &[u8; KEY_BYTES]) -> Result<(), L1Error> {
    let verifying = VerifyingKey::from_bytes(key).map_err(|_| L1Error::Malformed)?;
    if verifying.is_weak() || verifying.to_bytes() != *key {
        return Err(L1Error::Malformed);
    }
    Ok(())
}

fn parse_body_prefix(bytes: &[u8]) -> Result<(Body, usize), L1Error> {
    let mut reader = Reader { bytes, offset: 0 };
    if reader.take(4)? != MAGIC {
        return Err(L1Error::Malformed);
    }
    let format = reader.byte()?;
    if format != FORMAT && format != FORMAT_FRANK {
        return Err(L1Error::Malformed);
    }
    let account_id = reader.lp(1, crate::MAX_ACCOUNT_ID_BYTES)?.to_vec();
    let version = reader.u64()?;
    if version == 0 {
        return Err(L1Error::Malformed);
    }
    let prev_hash = reader.array()?;
    let created_at_ms = reader.u64()?;
    let change = Change::from_byte(reader.byte()?).ok_or(L1Error::Malformed)?;
    let count = usize::from(reader.byte()?);
    if count == 0 || count > MAX_ENTRIES {
        return Err(L1Error::Malformed);
    }
    let mut entries: Vec<Pair> = Vec::with_capacity(count);
    for _ in 0..count {
        let device_id = reader.lp(1, crate::MAX_DEVICE_ID_BYTES)?.to_vec();
        let signing_key: [u8; KEY_BYTES] = reader.array()?;
        check_key(&signing_key)?;
        // Strictly ascending ids: sorted and unique in one comparison.
        if entries
            .last()
            .is_some_and(|last| last.device_id >= device_id)
        {
            return Err(L1Error::Malformed);
        }
        if entries.iter().any(|pair| pair.signing_key == signing_key) {
            return Err(L1Error::Malformed);
        }
        entries.push(Pair {
            device_id,
            signing_key,
        });
    }
    let recovery_key = match reader.byte()? {
        0 => None,
        1 => {
            let key: [u8; KEY_BYTES] = reader.array()?;
            check_key(&key)?;
            Some(key)
        }
        _ => return Err(L1Error::Malformed),
    };
    let mut frank_keys: Vec<FrankKey> = Vec::new();
    if format == FORMAT_FRANK {
        // At least one key (a body with none is format 1), at most one per
        // listed device.
        let n = usize::from(reader.byte()?);
        if n == 0 || n > entries.len() {
            return Err(L1Error::Malformed);
        }
        for _ in 0..n {
            let device_id = reader.lp(1, crate::MAX_DEVICE_ID_BYTES)?.to_vec();
            let key: [u8; KEY_BYTES] = reader.array()?;
            // Canonical and not of low order, as the tag computation needs.
            crate::l2_frank::check_public(&key).map_err(|_| L1Error::Malformed)?;
            if frank_keys
                .last()
                .is_some_and(|last| last.device_id >= device_id)
                || !entries.iter().any(|pair| pair.device_id == device_id)
                || frank_keys.iter().any(|frank| frank.key == key)
            {
                return Err(L1Error::Malformed);
            }
            frank_keys.push(FrankKey { device_id, key });
        }
    }
    // Genesis and recovery bodies are versions of a chain: version 1 is a
    // genesis and only version 1 is.
    if change.is_genesis() != (version == 1) {
        return Err(L1Error::Malformed);
    }
    if change.is_genesis() && prev_hash != [0u8; HASH_BYTES] {
        return Err(L1Error::Malformed);
    }
    let body = Body {
        account_id,
        version,
        prev_hash,
        created_at_ms,
        change,
        entries,
        recovery_key,
        frank_keys,
    };
    Ok((body, reader.offset))
}

/// Parses a body that has nothing after it.
pub fn parse_body(bytes: &[u8]) -> Result<Body, L1Error> {
    if bytes.len() > MAX_STATEMENT_BYTES {
        return Err(L1Error::Malformed);
    }
    let (body, used) = parse_body_prefix(bytes)?;
    if used != bytes.len() {
        return Err(L1Error::Malformed);
    }
    Ok(body)
}

pub fn parse_statement(bytes: &[u8]) -> Result<Statement, L1Error> {
    if bytes.len() > MAX_STATEMENT_BYTES {
        return Err(L1Error::Malformed);
    }
    let (body, body_len) = parse_body_prefix(bytes)?;
    let mut reader = Reader {
        bytes,
        offset: body_len,
    };
    let signer = match reader.byte()? {
        SIGNER_DEVICE => Signer::Device(reader.lp(1, crate::MAX_DEVICE_ID_BYTES)?.to_vec()),
        SIGNER_RECOVERY => {
            reader.lp(0, 0)?;
            Signer::Recovery
        }
        _ => return Err(L1Error::Malformed),
    };
    let signature = reader.array()?;
    if reader.offset != bytes.len() {
        return Err(L1Error::Malformed);
    }
    Ok(Statement {
        body,
        signer,
        signature,
        raw: bytes.to_vec(),
        body_len,
    })
}

// ---- hashes and signatures -------------------------------------------------

pub fn list_hash(body: &[u8]) -> [u8; HASH_BYTES] {
    Sha256::new()
        .chain_update(LABEL_HASH)
        .chain_update(body)
        .finalize()
        .into()
}

/// The exact bytes a signer signs.
pub fn signed_message(body: &[u8], signer: &Signer) -> Result<Vec<u8>, L1Error> {
    let mut out = Vec::with_capacity(LABEL_SIG.len() + HASH_BYTES + 3 + signer.id().len());
    out.extend_from_slice(LABEL_SIG);
    out.extend_from_slice(&Sha256::digest(body));
    out.push(signer.kind());
    put_lp(&mut out, signer.id())?;
    Ok(out)
}

fn verify_signature(key: &[u8; KEY_BYTES], statement: &Statement) -> Result<(), L1Error> {
    let message = signed_message(statement.body_bytes(), &statement.signer)?;
    let key = VerifyingKey::from_bytes(key).map_err(|_| L1Error::Signature)?;
    key.verify_strict(&message, &Signature::from_bytes(&statement.signature))
        .map_err(|_| L1Error::Signature)
}

// ---- the rules -------------------------------------------------------------

fn key_of<'a>(entries: &'a [Pair], id: &[u8]) -> Option<&'a [u8; KEY_BYTES]> {
    entries
        .iter()
        .find(|pair| pair.device_id == id)
        .map(|pair| &pair.signing_key)
}

/// Whether `pair` (by id or by key) was listed in `history`.
fn seen_before(history: &[Pair], pair: &Pair) -> bool {
    history
        .iter()
        .any(|seen| seen.device_id == pair.device_id || seen.signing_key == pair.signing_key)
}

/// Checks `next` as the version after `prev` (`None` for a genesis).
///
/// `history` is every pair that any version before `next` ever listed
/// (`prev`'s entries included, and added to it automatically): it carries the
/// no-return and one-key-one-device rules across the whole chain. A device
/// that keeps its own table passes it here; [`check_chain`] builds it.
///
/// `expected_account` is the account the caller asked about. A statement of
/// any other account is refused as [`L1Error::Chain`], genesis or not, so a
/// validly signed chain of another account (a server's substitute answer)
/// can never pass for this one.
///
/// The order is parse (done), chain, rules, signature.
pub fn check_step(
    expected_account: &[u8],
    prev: Option<&Statement>,
    next: &Statement,
    history: &[Pair],
) -> Result<(), L1Error> {
    let body = &next.body;
    if body.account_id != expected_account {
        return Err(L1Error::Chain);
    }
    if body.change.is_genesis() {
        return check_genesis(prev, next);
    }
    let prev = prev.ok_or(L1Error::Chain)?;
    if body.account_id != prev.body.account_id
        || prev.body.version.checked_add(1) != Some(body.version)
        || body.prev_hash != prev.list_hash()
    {
        return Err(L1Error::Chain);
    }
    let before = &prev.body.entries;
    let after = &body.entries;
    // Every pair the chain ever listed: the caller's table and `prev`.
    let mut ever: Vec<Pair> = history.to_vec();
    ever.extend(before.iter().cloned());
    let unchanged = after == before;
    let same_recovery = body.recovery_key == prev.body.recovery_key;
    // A franking key is fixed: every device listed before and after keeps
    // exactly the key (or the absence of one) it had. Change 7 is the one
    // exception, for its signer only, and is checked in its arm.
    let frank_kept_except = |except: Option<&[u8]>| {
        after.iter().all(|pair| {
            !before.iter().any(|old| old.device_id == pair.device_id)
                || Some(pair.device_id.as_slice()) == except
                || body.frank_key(&pair.device_id) == prev.body.frank_key(&pair.device_id)
        })
    };
    if body.change != Change::FrankKey && !frank_kept_except(None) {
        return Err(L1Error::Rule);
    }
    let verifier = match (&body.change, &next.signer) {
        (Change::Add, Signer::Device(id)) => {
            let key = *key_of(before, id).ok_or(L1Error::Rule)?;
            // The signer stays listed, with the same key.
            if key_of(after, id) != Some(&key) || !same_recovery {
                return Err(L1Error::Rule);
            }
            // Exactly one pair more, and it is new to the chain. It starts
            // without a franking key: only the device itself sets one.
            let added: Vec<&Pair> = after.iter().filter(|pair| !before.contains(pair)).collect();
            if after.len() != before.len() + 1
                || added.len() != 1
                || !before.iter().all(|pair| after.contains(pair))
                || seen_before(&ever, added[0])
                || body.frank_key(&added[0].device_id).is_some()
            {
                return Err(L1Error::Rule);
            }
            key
        }
        (Change::Remove, Signer::Device(id)) => {
            let key = *key_of(before, id).ok_or(L1Error::Rule)?;
            // A strict subset of `prev` (the signer may remove itself); the
            // list is never empty (a body cannot be).
            if after.len() >= before.len()
                || !after.iter().all(|pair| before.contains(pair))
                || !same_recovery
            {
                return Err(L1Error::Rule);
            }
            key
        }
        (Change::Recovery, Signer::Recovery) => {
            let key = prev.body.recovery_key.ok_or(L1Error::Rule)?;
            if after.len() != 1 || !same_recovery || seen_before(&ever, &after[0]) {
                return Err(L1Error::Rule);
            }
            key
        }
        (Change::RecoveryKey, Signer::Device(id)) => {
            let key = *key_of(before, id).ok_or(L1Error::Rule)?;
            // The entries stay and the recovery key actually changes.
            if !unchanged || same_recovery {
                return Err(L1Error::Rule);
            }
            key
        }
        (Change::FrankKey, Signer::Device(id)) => {
            let key = *key_of(before, id).ok_or(L1Error::Rule)?;
            // Only the signer's own franking key changes, from none to some;
            // the entries, the recovery key and every other key stay.
            if !unchanged
                || !same_recovery
                || prev.body.frank_key(id).is_some()
                || body.frank_key(id).is_none()
                || !frank_kept_except(Some(id))
            {
                return Err(L1Error::Rule);
            }
            key
        }
        _ => return Err(L1Error::Rule),
    };
    verify_signature(&verifier, next)
}

fn check_genesis(prev: Option<&Statement>, next: &Statement) -> Result<(), L1Error> {
    let body = &next.body;
    // `parse` already tied genesis to version 1 and a zero `prev_hash`.
    if prev.is_some() {
        return Err(L1Error::Chain);
    }
    if body.recovery_key.is_some() {
        return Err(L1Error::Rule);
    }
    let Signer::Device(id) = &next.signer else {
        return Err(L1Error::Rule);
    };
    let key = *key_of(&body.entries, id).ok_or(L1Error::Rule)?;
    if body.change == Change::Genesis && body.entries.len() != 1 {
        return Err(L1Error::Rule);
    }
    // A genesis may carry the signer's own franking key and no other: the
    // other devices of a migration genesis set theirs with change 7.
    if body.frank_keys.iter().any(|frank| frank.device_id != *id) {
        return Err(L1Error::Rule);
    }
    verify_signature(&key, next)
}

/// A pair a chain listed, with the versions that added and removed it
/// (`removed_version` is 0 while it is listed) and the franking key the
/// chain gave the device, if any (fixed once set).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ListedPair {
    pub pair: Pair,
    pub added_version: u64,
    pub removed_version: u64,
    pub frank_key: Option<[u8; KEY_BYTES]>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChainResult {
    pub head: Statement,
    /// `list_hash` of version 1: the account's list identity.
    pub list_id: [u8; HASH_BYTES],
    pub pairs: Vec<ListedPair>,
}

/// Checks a whole chain from its genesis: every step, with the no-return and
/// one-key-one-device rules over the history so far. Every statement must be
/// of `expected_account` ([`L1Error::Chain`] otherwise). A franking key is
/// also one device's for the whole chain: a version that gives another
/// device a key the chain ever listed is refused ([`L1Error::Rule`]), which
/// [`check_step`] alone, with only signing-key history, cannot see.
pub fn check_chain(
    expected_account: &[u8],
    statements: &[Statement],
) -> Result<ChainResult, L1Error> {
    let first = statements.first().ok_or(L1Error::Malformed)?;
    if statements.len() > MAX_CHAIN_STATEMENTS {
        return Err(L1Error::Malformed);
    }
    let mut pairs: Vec<ListedPair> = Vec::new();
    let mut previous: Option<&Statement> = None;
    for statement in statements {
        let history: Vec<Pair> = pairs.iter().map(|listed| listed.pair.clone()).collect();
        check_step(expected_account, previous, statement, &history)?;
        let version = statement.body.version;
        for entry in &statement.body.entries {
            if !pairs.iter().any(|listed| listed.pair == *entry) {
                pairs.push(ListedPair {
                    pair: entry.clone(),
                    added_version: version,
                    removed_version: 0,
                    frank_key: None,
                });
            }
        }
        for frank in &statement.body.frank_keys {
            if pairs.iter().any(|listed| {
                listed.frank_key == Some(frank.key) && listed.pair.device_id != frank.device_id
            }) {
                return Err(L1Error::Rule);
            }
            if let Some(listed) = pairs.iter_mut().find(|listed| {
                listed.removed_version == 0 && listed.pair.device_id == frank.device_id
            }) {
                listed.frank_key = Some(frank.key);
            }
        }
        for listed in &mut pairs {
            if listed.removed_version == 0 && !statement.body.entries.contains(&listed.pair) {
                listed.removed_version = version;
            }
        }
        previous = Some(statement);
    }
    Ok(ChainResult {
        head: statements[statements.len() - 1].clone(),
        list_id: first.list_hash(),
        pairs,
    })
}

// ---- encodings the C ABI hands out and reads --------------------------------

/// Summary of one statement for the app, so it never parses a body itself:
///
/// ```text
/// u8 1 | u8 change | u8 signer_kind | lp(signer id) | u64 version
///   | [32] list_hash | [32] prev_hash | u64 created_at_ms | lp(account_id)
///   | u8 count | count x (lp(device_id) | [32] key) | u8 has_recovery
///   | [32] recovery_key (when has_recovery = 1)
///   | u8 n | n x (lp(device_id) | [32] frank_key)       (n may be 0)
/// ```
pub fn encode_summary(statement: &Statement) -> Result<Vec<u8>, L1Error> {
    let body = &statement.body;
    let mut out = vec![1, body.change as u8, statement.signer.kind()];
    put_lp(&mut out, statement.signer.id())?;
    out.extend_from_slice(&body.version.to_be_bytes());
    out.extend_from_slice(&statement.list_hash());
    out.extend_from_slice(&body.prev_hash);
    out.extend_from_slice(&body.created_at_ms.to_be_bytes());
    put_lp(&mut out, &body.account_id)?;
    out.push(u8::try_from(body.entries.len()).map_err(|_| L1Error::Malformed)?);
    for pair in &body.entries {
        put_lp(&mut out, &pair.device_id)?;
        out.extend_from_slice(&pair.signing_key);
    }
    match &body.recovery_key {
        None => out.push(0),
        Some(key) => {
            out.push(1);
            out.extend_from_slice(key);
        }
    }
    out.push(u8::try_from(body.frank_keys.len()).map_err(|_| L1Error::Malformed)?);
    for frank in &body.frank_keys {
        put_lp(&mut out, &frank.device_id)?;
        out.extend_from_slice(&frank.key);
    }
    Ok(out)
}

/// A chain result for the app: the head summary, the list identity and every
/// pair the chain listed.
///
/// ```text
/// summary(head) | [32] list_id | u16 n
///   | n x (lp(device_id) | [32] key | u64 added_version | u64 removed_version
///          | u8 has_frank_key | [32] frank_key (when has_frank_key = 1))
/// ```
pub fn encode_chain_result(result: &ChainResult) -> Result<Vec<u8>, L1Error> {
    let mut out = encode_summary(&result.head)?;
    out.extend_from_slice(&result.list_id);
    out.extend_from_slice(
        &u16::try_from(result.pairs.len())
            .map_err(|_| L1Error::Malformed)?
            .to_be_bytes(),
    );
    for listed in &result.pairs {
        put_lp(&mut out, &listed.pair.device_id)?;
        out.extend_from_slice(&listed.pair.signing_key);
        out.extend_from_slice(&listed.added_version.to_be_bytes());
        out.extend_from_slice(&listed.removed_version.to_be_bytes());
        match &listed.frank_key {
            None => out.push(0),
            Some(key) => {
                out.push(1);
                out.extend_from_slice(key);
            }
        }
    }
    Ok(out)
}

/// Reads `u16 n | n x (lp(device_id) | [32] key)`; empty input is no pairs.
/// Keys are not point-checked here: history only ever excludes.
pub fn decode_pairs(bytes: &[u8]) -> Result<Vec<Pair>, L1Error> {
    if bytes.is_empty() {
        return Ok(Vec::new());
    }
    let mut reader = Reader { bytes, offset: 0 };
    let count = usize::from(u16::from_be_bytes(reader.array()?));
    if count > MAX_HISTORY_PAIRS {
        return Err(L1Error::Malformed);
    }
    let mut pairs = Vec::with_capacity(count);
    for _ in 0..count {
        pairs.push(Pair {
            device_id: reader.lp(1, crate::MAX_DEVICE_ID_BYTES)?.to_vec(),
            signing_key: reader.array()?,
        });
    }
    if reader.offset != bytes.len() {
        return Err(L1Error::Malformed);
    }
    Ok(pairs)
}

/// Reads `u16 count | count x (u16 len | statement)`.
pub fn decode_chain(bytes: &[u8]) -> Result<Vec<Statement>, L1Error> {
    let mut reader = Reader { bytes, offset: 0 };
    let count = usize::from(u16::from_be_bytes(reader.array()?));
    if count == 0 || count > MAX_CHAIN_STATEMENTS {
        return Err(L1Error::Malformed);
    }
    let mut statements = Vec::with_capacity(count);
    for _ in 0..count {
        statements.push(parse_statement(reader.lp(1, MAX_STATEMENT_BYTES)?)?);
    }
    if reader.offset != bytes.len() {
        return Err(L1Error::Malformed);
    }
    Ok(statements)
}

/// The leaves of a group as the C ABI hands them out (`pm_crypto_group_members`
/// and the commit calls): `u16 n | n x (lp(account_id) | lp(device_id) |
/// [32] signing_key)`. `n` may be 0.
pub fn encode_leaf_pairs(leaves: &[(Vec<u8>, Vec<u8>, Vec<u8>)]) -> Result<Vec<u8>, L1Error> {
    let mut out = Vec::new();
    out.extend_from_slice(
        &u16::try_from(leaves.len())
            .map_err(|_| L1Error::Malformed)?
            .to_be_bytes(),
    );
    for (account_id, device_id, key) in leaves {
        put_lp(&mut out, account_id)?;
        put_lp(&mut out, device_id)?;
        if key.len() != KEY_BYTES {
            return Err(L1Error::Malformed);
        }
        out.extend_from_slice(key);
    }
    Ok(out)
}

#[cfg(test)]
#[path = "l1_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "l1_v2_tests.rs"]
mod v2_tests;
