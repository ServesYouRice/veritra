//! D70 format 4: MLS state sealed as one record per owner.
//!
//! Each record is `header || u32 len || AES-256-GCM(state_key, nonce,
//! plaintext, aad = header)`:
//!
//! ```text
//! header = "PMMLSST1" || u16 version=4 || u8 kind || u64 generation
//!          || u16 len account_id || u16 len device_id || u16 len record_id
//!          || nonce12
//! kind   = 0 root | 1 device | 2 group (id = raw group id)
//!          | 3 key package (id = raw hash reference)
//! ```
//!
//! The device, group and key-package plaintext is the sorted record map of
//! that owner (`u32 n || n * (u32 key_len, u32 value_len, key, value)`);
//! the device record appends the K2 transfer section. The root plaintext is
//! the manifest: `u16 len signer_public_key || u32 n || n * (u8 kind,
//! u16 len id, u64 generation, SHA-256(sealed record))`, sorted by kind and
//! id. Every transaction reseals the root at the next generation, so a
//! stale, missing, extra or foreign record fails restore.

use super::{
    encode_device_identity,
    state::{push_u16_bytes, Reader},
    storage::{
        PartitionedStorage, RecordKey, Store, VeritraProvider, KIND_DEVICE, KIND_GROUP,
        KIND_KEY_PACKAGE, KIND_ROOT,
    },
    transfer, MlsDevice, MlsError, CIPHERSUITE,
};
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use openmls::prelude::{BasicCredential, CredentialWithKey, GroupId, MlsGroup};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::MemoryStorage;
use openmls_traits::{random::OpenMlsRand, OpenMlsProvider};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use tls_codec::SecretVLBytes;

const MAGIC: &[u8; 8] = b"PMMLSST1";
pub(crate) const FORMAT_VERSION: u16 = 4;
const NONCE_BYTES: usize = 12;
const KEY_BYTES: usize = 32;
const MAX_RECORD_ID_BYTES: usize = 255;

/// Per-record caps on the plaintext, checked on seal and on restore.
pub(crate) const MAX_ROOT_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const MAX_ROOT_ENTRIES: usize = 200_000;
pub(crate) const MAX_DEVICE_BYTES: usize = 1024 * 1024;
pub(crate) const MAX_GROUP_BYTES: usize = 32 * 1024 * 1024;
pub(crate) const MAX_GROUP_VALUE_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_GROUP_VALUES: usize = 10_000;
pub(crate) const MAX_KEY_PACKAGE_BYTES: usize = 256 * 1024;
/// Largest key-package pool; `create_key_package` refuses beyond it.
pub(crate) const MAX_KEY_PACKAGES: usize = 1_000;
/// Header, length prefix and AEAD tag of one record, generously bounded.
pub(crate) const RECORD_OVERHEAD: usize = 4096;
/// Largest sealed record of any kind.
pub(crate) const MAX_SEALED_RECORD_BYTES: usize = MAX_GROUP_BYTES + RECORD_OVERHEAD;
/// Largest sealed root.
pub(crate) const MAX_SEALED_ROOT_BYTES: usize = MAX_ROOT_BYTES + RECORD_OVERHEAD;
/// Key packages older than this past their `not_after` are pruned.
pub(crate) const KEY_PACKAGE_GRACE_SECONDS: u64 = 24 * 60 * 60;

/// What the root lists for one record.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Entry {
    generation: u64,
    digest: [u8; 32],
}

/// What this device last sealed or restored: the generation rule's
/// counter, the manifest, and the device record's plaintext digest.
#[derive(Default)]
pub(crate) struct SealedState {
    last_generation: u64,
    manifest: BTreeMap<RecordKey, Entry>,
    device_digest: Option<[u8; 32]>,
}

/// One record in a change set.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordChange {
    pub kind: u8,
    pub id: Vec<u8>,
    pub generation: u64,
    /// The sealed record to store, or `None` to delete the stored one.
    pub sealed: Option<Vec<u8>>,
}

/// What one transaction stores: the root at the new generation and every
/// record that changed.
#[derive(Debug)]
pub struct ChangeSet {
    pub root: Vec<u8>,
    pub changes: Vec<RecordChange>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SealError {
    Mls(MlsError),
    /// A record is over its cap. Nothing was sealed and the change is kept,
    /// so the app can name the chat (D70 section 2).
    RecordLimit {
        kind: u8,
        id: Vec<u8>,
    },
}

impl From<MlsError> for SealError {
    fn from(error: MlsError) -> Self {
        Self::Mls(error)
    }
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn wipe(bytes: Vec<u8>) {
    drop(SecretVLBytes::new(bytes));
}

fn wipe_records(records: Vec<(Vec<u8>, Vec<u8>)>) {
    for (key, value) in records {
        wipe(key);
        wipe(value);
    }
}

pub(crate) fn wipe_store(store: Store) {
    for (key, value) in store {
        wipe(key);
        wipe(value);
    }
}

struct Limits {
    total: usize,
    values: usize,
    value: usize,
}

fn limits(kind: u8) -> Limits {
    match kind {
        KIND_DEVICE => Limits {
            total: MAX_DEVICE_BYTES,
            values: MAX_GROUP_VALUES,
            value: MAX_DEVICE_BYTES,
        },
        KIND_GROUP => Limits {
            total: MAX_GROUP_BYTES,
            values: MAX_GROUP_VALUES,
            value: MAX_GROUP_VALUE_BYTES,
        },
        _ => Limits {
            total: MAX_KEY_PACKAGE_BYTES,
            values: MAX_GROUP_VALUES,
            value: MAX_KEY_PACKAGE_BYTES,
        },
    }
}

/// Encodes one owner's sorted records, plus `tail` (the device record's
/// transfers). `None` when over the owner's cap.
fn encode_owner(kind: u8, records: &[(Vec<u8>, Vec<u8>)], tail: &[u8]) -> Option<SecretVLBytes> {
    let limits = limits(kind);
    if records.len() > limits.values {
        return None;
    }
    let mut size = 4usize.checked_add(tail.len())?;
    for (key, value) in records {
        if key.len() > limits.value || value.len() > limits.value {
            return None;
        }
        size = size
            .checked_add(8)?
            .checked_add(key.len())?
            .checked_add(value.len())?;
        if size > limits.total {
            return None;
        }
    }
    // Reserved once, so no secret is left behind by a reallocation.
    let mut out = SecretVLBytes::new(Vec::with_capacity(size));
    let mut put = |bytes: &[u8]| bytes.iter().for_each(|b| out.push(*b));
    put(&(records.len() as u32).to_be_bytes());
    for (key, value) in records {
        put(&(key.len() as u32).to_be_bytes());
        put(&(value.len() as u32).to_be_bytes());
        put(key);
        put(value);
    }
    put(tail);
    Some(out)
}

/// Decodes one owner's records and returns the bytes after them (the
/// device record's transfers; empty for the others).
fn decode_owner(kind: u8, plaintext: &[u8]) -> Result<(Store, &[u8]), MlsError> {
    let limits = limits(kind);
    if plaintext.len() > limits.total {
        return Err(MlsError::InvalidState);
    }
    let mut reader = Reader::new(plaintext);
    let count = reader.u32()? as usize;
    if count > limits.values {
        return Err(MlsError::InvalidState);
    }
    let mut store = Store::with_capacity(count);
    let mut previous: Option<Vec<u8>> = None;
    for _ in 0..count {
        let key_len = reader.u32()? as usize;
        let value_len = reader.u32()? as usize;
        if key_len > limits.value || value_len > limits.value {
            return Err(MlsError::InvalidState);
        }
        let key = reader.take(key_len)?.to_vec();
        let value = reader.take(value_len)?.to_vec();
        // Sorted and unique, as sealed.
        if previous.as_ref().is_some_and(|previous| previous >= &key) {
            return Err(MlsError::InvalidState);
        }
        previous = Some(key.clone());
        store.insert(key, value);
    }
    let rest = &plaintext[reader.offset..];
    if kind != KIND_DEVICE && !rest.is_empty() {
        return Err(MlsError::InvalidState);
    }
    Ok((store, rest))
}

struct Identity<'a> {
    account: &'a [u8],
    device: &'a [u8],
}

fn header(
    identity: &Identity<'_>,
    kind: u8,
    generation: u64,
    id: &[u8],
    nonce: &[u8],
) -> Result<Vec<u8>, MlsError> {
    if id.len() > MAX_RECORD_ID_BYTES {
        return Err(MlsError::InvalidState);
    }
    let mut out = Vec::with_capacity(64 + id.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
    out.push(kind);
    out.extend_from_slice(&generation.to_be_bytes());
    push_u16_bytes(&mut out, identity.account)?;
    push_u16_bytes(&mut out, identity.device)?;
    push_u16_bytes(&mut out, id)?;
    out.extend_from_slice(nonce);
    Ok(out)
}

fn seal_record(
    provider: &VeritraProvider,
    state_key: &[u8],
    identity: &Identity<'_>,
    kind: u8,
    generation: u64,
    id: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>, MlsError> {
    let nonce = provider
        .rand()
        .random_vec(NONCE_BYTES)
        .map_err(|_| MlsError::KeyGeneration)?;
    let mut sealed = header(identity, kind, generation, id, &nonce)?;
    let cipher = Aes256Gcm::new_from_slice(state_key).map_err(|_| MlsError::InvalidState)?;
    let nonce = Nonce::try_from(nonce.as_slice()).map_err(|_| MlsError::InvalidState)?;
    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: plaintext,
                aad: &sealed,
            },
        )
        .map_err(|_| MlsError::Storage)?;
    let length = u32::try_from(ciphertext.len()).map_err(|_| MlsError::InvalidState)?;
    sealed.reserve_exact(4 + ciphertext.len());
    sealed.extend_from_slice(&length.to_be_bytes());
    sealed.extend_from_slice(&ciphertext);
    Ok(sealed)
}

/// The authenticated header fields and plaintext of one record.
struct Opened {
    kind: u8,
    generation: u64,
    id: Vec<u8>,
    plaintext: SecretVLBytes,
}

/// Opens one format-4 record under this identity. A record with the right
/// magic and another version is [`MlsError::UnsupportedFormat`]; every
/// other failure is [`MlsError::InvalidState`].
fn open_record(
    state_key: &[u8],
    identity: &Identity<'_>,
    sealed: &[u8],
) -> Result<Opened, MlsError> {
    if state_key.len() != KEY_BYTES || sealed.len() > MAX_SEALED_RECORD_BYTES {
        return Err(MlsError::InvalidState);
    }
    let mut reader = Reader::new(sealed);
    if reader.take(MAGIC.len())? != MAGIC {
        return Err(MlsError::InvalidState);
    }
    if reader.u16()? != FORMAT_VERSION {
        return Err(MlsError::UnsupportedFormat);
    }
    let kind = reader.take(1)?[0];
    let generation = reader.u64()?;
    if reader.u16_bytes()? != identity.account || reader.u16_bytes()? != identity.device {
        return Err(MlsError::InvalidState);
    }
    let id = reader.u16_bytes()?.to_vec();
    let nonce = reader.take(NONCE_BYTES)?;
    let aad_end = reader.offset;
    let length = reader.u32()? as usize;
    let ciphertext = reader.take(length)?;
    if !reader.finished() || id.len() > MAX_RECORD_ID_BYTES || generation == 0 {
        return Err(MlsError::InvalidState);
    }
    let cipher = Aes256Gcm::new_from_slice(state_key).map_err(|_| MlsError::InvalidState)?;
    let nonce = Nonce::try_from(nonce).map_err(|_| MlsError::InvalidState)?;
    let plaintext: SecretVLBytes = cipher
        .decrypt(
            &nonce,
            Payload {
                msg: ciphertext,
                aad: &sealed[..aad_end],
            },
        )
        .map_err(|_| MlsError::InvalidState)?
        .into();
    Ok(Opened {
        kind,
        generation,
        id,
        plaintext,
    })
}

fn encode_root(
    signer_public: &[u8],
    manifest: &BTreeMap<RecordKey, Entry>,
) -> Result<Vec<u8>, SealError> {
    let limit = || SealError::RecordLimit {
        kind: KIND_ROOT,
        id: Vec::new(),
    };
    if manifest.len() > MAX_ROOT_ENTRIES {
        return Err(limit());
    }
    let mut out = Vec::new();
    push_u16_bytes(&mut out, signer_public)?;
    out.extend_from_slice(&(manifest.len() as u32).to_be_bytes());
    for (key, entry) in manifest {
        out.push(key.kind);
        push_u16_bytes(&mut out, &key.id)?;
        out.extend_from_slice(&entry.generation.to_be_bytes());
        out.extend_from_slice(&entry.digest);
        if out.len() > MAX_ROOT_BYTES {
            return Err(limit());
        }
    }
    Ok(out)
}

fn decode_root(
    plaintext: &[u8],
    generation: u64,
) -> Result<(Vec<u8>, BTreeMap<RecordKey, Entry>), MlsError> {
    if plaintext.len() > MAX_ROOT_BYTES {
        return Err(MlsError::InvalidState);
    }
    let mut reader = Reader::new(plaintext);
    let signer_public = reader.u16_bytes()?.to_vec();
    let count = reader.u32()? as usize;
    if count > MAX_ROOT_ENTRIES {
        return Err(MlsError::InvalidState);
    }
    let mut manifest = BTreeMap::new();
    let mut previous: Option<RecordKey> = None;
    for _ in 0..count {
        let kind = reader.take(1)?[0];
        let id = reader.u16_bytes()?.to_vec();
        let entry_generation = reader.u64()?;
        let digest: [u8; 32] = reader
            .take(32)?
            .try_into()
            .map_err(|_| MlsError::InvalidState)?;
        let key = RecordKey { kind, id };
        let valid_owner = match kind {
            KIND_DEVICE => key.id.is_empty(),
            KIND_GROUP | KIND_KEY_PACKAGE => {
                !key.id.is_empty() && key.id.len() <= MAX_RECORD_ID_BYTES
            }
            _ => false,
        };
        if !valid_owner
            || entry_generation == 0
            || entry_generation > generation
            || previous.as_ref().is_some_and(|previous| previous >= &key)
        {
            return Err(MlsError::InvalidState);
        }
        previous = Some(key.clone());
        manifest.insert(
            key,
            Entry {
                generation: entry_generation,
                digest,
            },
        );
    }
    if !reader.finished() || !manifest.contains_key(&RecordKey::device()) {
        return Err(MlsError::InvalidState);
    }
    Ok((signer_public, manifest))
}

impl MlsDevice {
    /// The device record's plaintext: the signer store and the transfers.
    fn device_plaintext(&self) -> Result<SecretVLBytes, SealError> {
        let storage = self.provider.storage();
        let records = storage
            .owner_records(&RecordKey::device())?
            .ok_or(MlsError::InvalidState)?;
        let transfers = transfer::encode(
            &self.pending_transfers,
            &self.account_id,
            &self.device_id,
            self.signer.public(),
            &self.provider,
        )?;
        let plaintext = encode_owner(KIND_DEVICE, &records, transfers.as_slice());
        wipe_records(records);
        plaintext.ok_or(SealError::RecordLimit {
            kind: KIND_DEVICE,
            id: Vec::new(),
        })
    }

    /// Seals what changed since the last seal or restore at `generation`,
    /// which must be the previous generation plus one. Returns the root
    /// and the changed records; the dirty set is cleared. On
    /// [`SealError::RecordLimit`] (or any other error) nothing changes, and
    /// the caller restores from storage before going on.
    pub fn seal_changes(
        &mut self,
        state_key: &[u8],
        generation: u64,
    ) -> Result<ChangeSet, SealError> {
        if state_key.len() != KEY_BYTES
            || generation == 0
            || self.sealed.last_generation.checked_add(1) != Some(generation)
        {
            return Err(MlsError::InvalidState.into());
        }
        let storage = self.provider.storage();
        // Only migration leaves standalone pairs unowned, and it files or
        // drops them first.
        if !storage.unowned_is_empty()? {
            return Err(MlsError::InvalidState.into());
        }
        let mut dirty = storage.dirty()?;
        let device_plaintext = self.device_plaintext()?;
        let device_digest = sha256(device_plaintext.as_slice());
        if self.sealed.device_digest != Some(device_digest)
            || !self.sealed.manifest.contains_key(&RecordKey::device())
        {
            dirty.insert(RecordKey::device());
        }
        // Every plaintext is built and checked against its cap before
        // anything is sealed.
        let mut prepared: Vec<(RecordKey, Option<SecretVLBytes>)> = Vec::new();
        for key in &dirty {
            let plaintext = if key.kind == KIND_DEVICE {
                Some(device_plaintext.clone())
            } else {
                match storage.owner_records(key)? {
                    None => None,
                    Some(records) => {
                        let plaintext = encode_owner(key.kind, &records, &[]);
                        wipe_records(records);
                        Some(plaintext.ok_or_else(|| SealError::RecordLimit {
                            kind: key.kind,
                            id: key.id.clone(),
                        })?)
                    }
                }
            };
            prepared.push((key.clone(), plaintext));
        }
        let identity = Identity {
            account: &self.account_id,
            device: &self.device_id,
        };
        let mut manifest = self.sealed.manifest.clone();
        let mut changes = Vec::new();
        for (key, plaintext) in prepared {
            match plaintext {
                Some(plaintext) => {
                    let sealed = seal_record(
                        &self.provider,
                        state_key,
                        &identity,
                        key.kind,
                        generation,
                        &key.id,
                        plaintext.as_slice(),
                    )?;
                    manifest.insert(
                        key.clone(),
                        Entry {
                            generation,
                            digest: sha256(&sealed),
                        },
                    );
                    changes.push(RecordChange {
                        kind: key.kind,
                        id: key.id,
                        generation,
                        sealed: Some(sealed),
                    });
                }
                None => {
                    if manifest.remove(&key).is_some() {
                        changes.push(RecordChange {
                            kind: key.kind,
                            id: key.id,
                            generation,
                            sealed: None,
                        });
                    }
                }
            }
        }
        let root_plaintext = SecretVLBytes::new(encode_root(self.signer.public(), &manifest)?);
        let root = seal_record(
            &self.provider,
            state_key,
            &identity,
            KIND_ROOT,
            generation,
            &[],
            root_plaintext.as_slice(),
        )?;
        storage.clear_dirty(&dirty)?;
        self.sealed = SealedState {
            last_generation: generation,
            manifest,
            device_digest: Some(device_digest),
        };
        Ok(ChangeSet { root, changes })
    }

    /// Migrates a format 2 or 3 blob (D70 section 5). Runs every check of
    /// the old restore, requires its counter to equal `counter`, drops
    /// inactive groups and standalone key pairs no group owns, and checks
    /// the result against the input. Every record is then dirty: the next
    /// [`Self::seal_changes`] at `counter + 1` emits all of them. Returns
    /// the device and the number of records dropped.
    pub fn migrate_v3(
        account_id: &[u8],
        device_id: &[u8],
        state_key: &[u8],
        counter: u64,
        sealed: &[u8],
    ) -> Result<(Self, usize), MlsError> {
        let version = sealed
            .get(MAGIC.len()..MAGIC.len() + 2)
            .ok_or(MlsError::InvalidState)?;
        if &sealed[..MAGIC.len()] != MAGIC {
            return Err(MlsError::InvalidState);
        }
        if version != 2u16.to_be_bytes() && version != 3u16.to_be_bytes() {
            return Err(MlsError::UnsupportedFormat);
        }
        let (mut device, restored) =
            Self::restore_state(account_id, device_id, state_key, counter, sealed)?;
        if restored != counter {
            return Err(MlsError::InvalidState);
        }
        let storage = device.provider.storage();
        let before = storage.flat_records()?;
        let dropped = storage.settle_for_migration()?;
        let after = storage.flat_records()?;
        // Self-check: every record kept is the input record, unchanged, and
        // the kept and the dropped add up to the input.
        let consistent = after.len().checked_add(dropped) == Some(before.len())
            && after
                .iter()
                .all(|(key, value)| before.get(key) == Some(value));
        wipe_store(after);
        if !consistent {
            wipe_store(before);
            return Err(MlsError::InvalidState);
        }
        // Every kept group loads at the same epoch from the input and from
        // its own store.
        let flat = MemoryStorage::default();
        *flat.values.write().map_err(|_| MlsError::Storage)? = before;
        let mut same = true;
        for id in storage.group_ids()? {
            let from_flat = MlsGroup::load(&flat, &GroupId::from_slice(&id))
                .ok()
                .flatten()
                .map(|group| group.epoch().as_u64());
            let from_store = device
                .in_group(&id, || {
                    MlsGroup::load(storage, &GroupId::from_slice(&id))
                        .map_err(|_| MlsError::Storage)
                })?
                .map(|group| group.epoch().as_u64());
            same &= from_flat.is_some() && from_flat == from_store;
        }
        let flat = flat.values.into_inner().map_err(|_| MlsError::Storage)?;
        wipe_store(flat);
        if !same {
            return Err(MlsError::InvalidState);
        }
        storage.mark_all_dirty()?;
        device.sealed.last_generation = counter;
        Ok((device, dropped))
    }
}

/// A format-4 restore in progress: the root is open and checked, records
/// are added one at a time and each is checked against the manifest.
pub struct RestoreLoader {
    account_id: Vec<u8>,
    device_id: Vec<u8>,
    state_key: SecretVLBytes,
    generation: u64,
    signer_public: Vec<u8>,
    manifest: BTreeMap<RecordKey, Entry>,
    added: BTreeSet<RecordKey>,
    device: Option<SecretVLBytes>,
    groups: BTreeMap<Vec<u8>, Store>,
    key_packages: BTreeMap<Vec<u8>, Store>,
    failed: bool,
}

impl Drop for RestoreLoader {
    fn drop(&mut self) {
        for (_, store) in std::mem::take(&mut self.groups) {
            wipe_store(store);
        }
        for (_, store) in std::mem::take(&mut self.key_packages) {
            wipe_store(store);
        }
    }
}

impl RestoreLoader {
    /// Opens the root. The root generation must be at least
    /// `minimum_generation` ([`MlsError::Rollback`] otherwise); the caller
    /// also requires it to equal its stored counter.
    pub fn begin(
        account_id: &[u8],
        device_id: &[u8],
        state_key: &[u8],
        minimum_generation: u64,
        root: &[u8],
    ) -> Result<Self, MlsError> {
        encode_device_identity(account_id, device_id)?;
        if state_key.len() != KEY_BYTES || root.len() > MAX_SEALED_ROOT_BYTES {
            return Err(MlsError::InvalidState);
        }
        let identity = Identity {
            account: account_id,
            device: device_id,
        };
        let opened = open_record(state_key, &identity, root)?;
        if opened.kind != KIND_ROOT || !opened.id.is_empty() {
            return Err(MlsError::InvalidState);
        }
        if opened.generation < minimum_generation {
            return Err(MlsError::Rollback);
        }
        let (signer_public, manifest) =
            decode_root(opened.plaintext.as_slice(), opened.generation)?;
        Ok(Self {
            account_id: account_id.to_vec(),
            device_id: device_id.to_vec(),
            state_key: state_key.to_vec().into(),
            generation: opened.generation,
            signer_public,
            manifest,
            added: BTreeSet::new(),
            device: None,
            groups: BTreeMap::new(),
            key_packages: BTreeMap::new(),
            failed: false,
        })
    }

    /// The root generation.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Adds one sealed record. It must be listed, not yet added, and match
    /// its listed generation and digest. Any failure poisons the loader.
    pub fn add(&mut self, sealed: &[u8]) -> Result<(), MlsError> {
        let result = self.add_inner(sealed);
        if result.is_err() {
            self.failed = true;
        }
        result
    }

    fn add_inner(&mut self, sealed: &[u8]) -> Result<(), MlsError> {
        if self.failed || sealed.len() > MAX_SEALED_RECORD_BYTES {
            return Err(MlsError::InvalidState);
        }
        let identity = Identity {
            account: &self.account_id,
            device: &self.device_id,
        };
        let opened = open_record(self.state_key.as_slice(), &identity, sealed)?;
        let key = RecordKey {
            kind: opened.kind,
            id: opened.id,
        };
        let entry = self.manifest.get(&key).ok_or(MlsError::InvalidState)?;
        if entry.generation != opened.generation
            || entry.digest != sha256(sealed)
            || !self.added.insert(key.clone())
        {
            return Err(MlsError::InvalidState);
        }
        match key.kind {
            KIND_DEVICE => {
                decode_owner(KIND_DEVICE, opened.plaintext.as_slice())?;
                self.device = Some(opened.plaintext);
            }
            KIND_GROUP => {
                let (store, _) = decode_owner(KIND_GROUP, opened.plaintext.as_slice())?;
                self.groups.insert(key.id, store);
            }
            KIND_KEY_PACKAGE => {
                let (store, _) = decode_owner(KIND_KEY_PACKAGE, opened.plaintext.as_slice())?;
                self.key_packages.insert(key.id, store);
            }
            _ => return Err(MlsError::InvalidState),
        }
        Ok(())
    }

    /// Builds the device once every listed record was added.
    pub fn finish(mut self) -> Result<(MlsDevice, u64), MlsError> {
        if self.failed || self.added.len() != self.manifest.len() {
            return Err(MlsError::InvalidState);
        }
        let device_plaintext = self.device.take().ok_or(MlsError::InvalidState)?;
        let (device_store, transfers) = decode_owner(KIND_DEVICE, device_plaintext.as_slice())?;
        let storage = PartitionedStorage::from_owners(
            device_store,
            std::mem::take(&mut self.groups),
            std::mem::take(&mut self.key_packages),
        )?;
        let provider = VeritraProvider::with_storage(storage);
        let pending_transfers = transfer::decode(
            transfers,
            &self.account_id,
            &self.device_id,
            &self.signer_public,
            &provider,
        )?;
        let signer = SignatureKeyPair::read(
            provider.storage(),
            &self.signer_public,
            CIPHERSUITE.signature_algorithm(),
        )
        .ok_or(MlsError::InvalidState)?;
        let identity = encode_device_identity(&self.account_id, &self.device_id)?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity).into(),
            signature_key: signer.public().into(),
        };
        let device_digest = sha256(device_plaintext.as_slice());
        Ok((
            MlsDevice {
                provider,
                signer,
                credential,
                account_id: std::mem::take(&mut self.account_id),
                device_id: std::mem::take(&mut self.device_id),
                pending_transfers,
                sealed: SealedState {
                    last_generation: self.generation,
                    manifest: std::mem::take(&mut self.manifest),
                    device_digest: Some(device_digest),
                },
            },
            self.generation,
        ))
    }
}

/// A stand-in for the app's `local_crypto_records` table and singleton:
/// change sets are applied to it and restores read from it.
#[cfg(test)]
#[derive(Clone, Default)]
pub(crate) struct SealedTable {
    pub(crate) generation: u64,
    pub(crate) root: Vec<u8>,
    pub(crate) records: BTreeMap<(u8, Vec<u8>), Vec<u8>>,
}

#[cfg(test)]
impl SealedTable {
    /// Seals `device`'s changes at the next generation and applies them.
    pub(crate) fn commit(&mut self, device: &mut MlsDevice, key: &[u8]) -> ChangeSet {
        let set = device.seal_changes(key, self.generation + 1).unwrap();
        self.apply(&set);
        set
    }

    pub(crate) fn apply(&mut self, set: &ChangeSet) {
        self.generation += 1;
        self.root = set.root.clone();
        for change in &set.changes {
            let key = (change.kind, change.id.clone());
            match &change.sealed {
                Some(sealed) => {
                    self.records.insert(key, sealed.clone());
                }
                None => {
                    self.records.remove(&key);
                }
            }
        }
    }

    pub(crate) fn restore(
        &self,
        account: &[u8],
        device: &[u8],
        key: &[u8],
    ) -> Result<MlsDevice, MlsError> {
        let mut loader = RestoreLoader::begin(account, device, key, self.generation, &self.root)?;
        for sealed in self.records.values() {
            loader.add(sealed)?;
        }
        let (device, generation) = loader.finish()?;
        assert_eq!(generation, self.generation);
        Ok(device)
    }

    /// A fresh device sealed once at generation 1.
    pub(crate) fn start(device: &mut MlsDevice, key: &[u8]) -> Self {
        let mut table = Self::default();
        table.commit(device, key);
        table
    }
}

/// Seals every record at the next generation and restores a new device
/// from them, as an app restart over a complete table would.
#[cfg(test)]
impl MlsDevice {
    pub(crate) fn reload_for_test(&mut self, state_key: &[u8]) -> MlsDevice {
        self.provider.storage().mark_all_dirty().unwrap();
        let generation = self.sealed.last_generation + 1;
        let set = self.seal_changes(state_key, generation).unwrap();
        let mut loader = RestoreLoader::begin(
            &self.account_id,
            &self.device_id,
            state_key,
            generation,
            &set.root,
        )
        .unwrap();
        for change in &set.changes {
            if let Some(sealed) = &change.sealed {
                loader.add(sealed).unwrap();
            }
        }
        loader.finish().unwrap().0
    }

    /// Puts one value over the per-value cap into group `id`.
    pub(crate) fn oversize_group_for_test(&self, id: &[u8]) {
        self.provider
            .storage()
            .pad_group_for_test(id, 0, MAX_GROUP_VALUE_BYTES + 1);
    }
}

#[cfg(test)]
#[path = "records_tests.rs"]
mod tests;
