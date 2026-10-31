//! D70 S1: OpenMLS storage split by owner.
//!
//! [`PartitionedStorage`] implements the OpenMLS 0.9.2 storage trait by
//! delegating each call to one inner [`MemoryStorage`]:
//!
//! - `device`: the signature key pair and PSKs (unused today);
//! - one store per group: every call keyed by a group id, plus the
//!   standalone update-leaf encryption key pairs (they carry no group id and
//!   go to the group in scope);
//! - one store per key package, keyed by its hash reference.
//!
//! Inner keys and values are exactly what a single `MemoryStorage` writes,
//! so the stores together equal the flat map sealed in format 3.
//!
//! **Scope guard.** Every `MlsDevice` group operation runs inside
//! [`PartitionedStorage::scoped`]. A group-keyed call for another group, or
//! any group-keyed or standalone key-pair call with no scope, is refused and
//! fails the whole operation with `MlsError::Storage`, even when OpenMLS
//! swallows the storage error. A record can never be filed under the wrong
//! owner.
//!
//! **No serde_json.** The group id bytes OpenMLS uses as keys come from a
//! probe `MemoryStorage` (the same serializer), and restored keys are parsed
//! by a strict parser for the one JSON shape OpenMLS writes for a
//! length-prefixed id (`{"value":{"vec":[..]}}`).

use super::MlsError;
use openmls::prelude::{GroupId, LeafNodeIndex};
use openmls_rust_crypto::{MemoryStorage, MemoryStorageError, RustCrypto};
use openmls_traits::{
    storage::{traits, StorageProvider, CURRENT_VERSION},
    OpenMlsProvider,
};
use std::{
    collections::{BTreeMap, HashMap},
    fmt,
    sync::{Mutex, RwLock},
};

/// The OpenMLS provider of an `MlsDevice`: RustCrypto for crypto and
/// randomness, partitioned in-memory storage.
#[derive(Default)]
pub(crate) struct VeritraProvider {
    crypto: RustCrypto,
    storage: PartitionedStorage,
}

impl VeritraProvider {
    pub(crate) fn with_storage(storage: PartitionedStorage) -> Self {
        Self {
            crypto: RustCrypto::default(),
            storage,
        }
    }
}

impl OpenMlsProvider for VeritraProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = PartitionedStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

#[derive(Debug)]
pub(crate) enum PartitionError {
    /// A group-keyed or standalone key-pair call outside its group's scope.
    OutOfScope,
    /// A key OpenMLS wrote that does not have the expected shape.
    UnexpectedKey,
    Poisoned,
    Memory(MemoryStorageError),
}

impl fmt::Display for PartitionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::OutOfScope => "storage call outside its group scope",
            Self::UnexpectedKey => "unexpected storage key",
            Self::Poisoned => "storage lock poisoned",
            Self::Memory(_) => "memory storage error",
        })
    }
}

impl std::error::Error for PartitionError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Memory(error) => Some(error),
            _ => None,
        }
    }
}

impl From<MemoryStorageError> for PartitionError {
    fn from(error: MemoryStorageError) -> Self {
        Self::Memory(error)
    }
}

struct ActiveGroup {
    raw: Vec<u8>,
    json: Vec<u8>,
}

#[derive(Default)]
struct Scope {
    active: Option<ActiveGroup>,
    violated: bool,
}

type Store = HashMap<Vec<u8>, Vec<u8>>;

#[derive(Default)]
pub(crate) struct PartitionedStorage {
    device: MemoryStorage,
    groups: RwLock<BTreeMap<Vec<u8>, MemoryStorage>>,
    key_packages: RwLock<BTreeMap<Vec<u8>, MemoryStorage>>,
    /// Standalone encryption key pairs restored from a flat state, which no
    /// group can be proven to own. Veritra never writes them (it makes no
    /// update proposals), so this is empty in practice. Kept verbatim so
    /// format 3 re-seals byte-identically; never routed to OpenMLS.
    unowned: MemoryStorage,
    scope: Mutex<Scope>,
    /// Always empty: reads of a group that has no store.
    empty: MemoryStorage,
    /// Test-only flat twin that receives every successful write and delete;
    /// the partitions must always add up to it.
    #[cfg(test)]
    shadow: MemoryStorage,
    #[cfg(test)]
    hits: Mutex<std::collections::BTreeSet<&'static str>>,
}

/// Who owns one flat record.
#[derive(Debug, Eq, PartialEq)]
pub(crate) enum Owner {
    Device,
    Group(Vec<u8>),
    KeyPackage(Vec<u8>),
    Unowned,
}

#[derive(Clone, Copy)]
enum Shape {
    SignatureKey,
    Psk,
    KeyPackage,
    Standalone,
    Group,
    EpochKeyPairs,
    QueuedProposal,
}

/// Every label `openmls_memory_storage` 0.6.0 writes without the draft
/// features. A new OpenMLS label is refused, not guessed.
const LABELS: &[(&[u8], Shape)] = &[
    (b"SignatureKeyPair", Shape::SignatureKey),
    (b"Psk", Shape::Psk),
    (b"KeyPackage", Shape::KeyPackage),
    (b"EncryptionKeyPair", Shape::Standalone),
    (b"EpochKeyPairs", Shape::EpochKeyPairs),
    (b"QueuedProposal", Shape::QueuedProposal),
    (b"Tree", Shape::Group),
    (b"GroupContext", Shape::Group),
    (b"InterimTranscriptHash", Shape::Group),
    (b"ConfirmationTag", Shape::Group),
    (b"MlsGroupJoinConfig", Shape::Group),
    (b"OwnLeafNodes", Shape::Group),
    (b"GroupState", Shape::Group),
    (b"ProposalQueueRefs", Shape::Group),
    (b"OwnLeafNodeIndex", Shape::Group),
    (b"EpochSecrets", Shape::Group),
    (b"ResumptionPsk", Shape::Group),
    (b"MessageSecrets", Shape::Group),
];
const OWN_LEAF_NODE_INDEX_LABEL: &[u8] = b"OwnLeafNodeIndex";
const KEY_PACKAGE_LABEL: &[u8] = b"KeyPackage";
const VERSION_SUFFIX: [u8; 2] = CURRENT_VERSION.to_be_bytes();
const ID_PREFIX: &[u8] = br#"{"value":{"vec":["#;
const ID_SUFFIX: &[u8] = b"]}}";
const SIGNATURE_KEY_PREFIX: &[u8] = br#"{"value":["#;
const SIGNATURE_KEY_SUFFIX: &[u8] = b"}";

/// Splits one flat key into its owner. Exactly one label must match, the
/// key must end in the current storage version, and the id must be in
/// canonical form.
pub(crate) fn classify(key: &[u8]) -> Option<Owner> {
    let body = key.strip_suffix(&VERSION_SUFFIX)?;
    let mut matches = LABELS.iter().filter_map(|(label, shape)| {
        let rest = body.strip_prefix(*label)?;
        matches!(rest.first(), Some(b'{' | b'[')).then_some((rest, *shape))
    });
    let (rest, shape) = matches.next()?;
    if matches.next().is_some() {
        return None;
    }
    match shape {
        Shape::SignatureKey => {
            let list = rest
                .strip_prefix(SIGNATURE_KEY_PREFIX)?
                .strip_suffix(SIGNATURE_KEY_SUFFIX)?;
            let (_, used) = parse_byte_list(list)?;
            (&list[used..] == b"]").then_some(Owner::Device)
        }
        // Never written by Veritra; its key shape is OpenMLS's PSK id.
        Shape::Psk => Some(Owner::Device),
        Shape::KeyPackage => {
            let (raw, used) = parse_id(rest)?;
            (used == rest.len()).then_some(Owner::KeyPackage(raw))
        }
        Shape::Standalone => Some(Owner::Unowned),
        Shape::Group => {
            let (raw, used) = parse_id(rest)?;
            (used == rest.len()).then_some(Owner::Group(raw))
        }
        // group id || epoch || leaf index, the last two as bare decimals.
        Shape::EpochKeyPairs => {
            let (raw, used) = parse_id(rest)?;
            let tail = &rest[used..];
            (tail.len() >= 2 && tail.iter().all(u8::is_ascii_digit)).then_some(Owner::Group(raw))
        }
        // [group id, proposal ref]
        Shape::QueuedProposal => {
            let inner = rest.strip_prefix(b"[")?.strip_suffix(b"]")?;
            let (raw, used) = parse_id(inner)?;
            let reference = inner[used..].strip_prefix(b",")?;
            let (_, used) = parse_id(reference)?;
            (used == reference.len()).then_some(Owner::Group(raw))
        }
    }
}

/// Parses `{"value":{"vec":[b,b,...]}}` at the start of `bytes`: the JSON
/// OpenMLS writes for a group id or a hash reference. Returns the raw bytes
/// and the length consumed.
fn parse_id(bytes: &[u8]) -> Option<(Vec<u8>, usize)> {
    let list = bytes.strip_prefix(ID_PREFIX)?;
    let (raw, used) = parse_byte_list(list)?;
    if !list[used..].starts_with(ID_SUFFIX) {
        return None;
    }
    Some((raw, ID_PREFIX.len() + used + ID_SUFFIX.len()))
}

/// Parses canonical decimal bytes separated by commas, up to (not
/// including) the closing `]`. No whitespace, no leading zeros.
fn parse_byte_list(bytes: &[u8]) -> Option<(Vec<u8>, usize)> {
    let mut raw = Vec::new();
    let mut at = 0;
    if bytes.first() == Some(&b']') {
        return Some((raw, 0));
    }
    loop {
        let digits = bytes[at..]
            .iter()
            .take_while(|b| b.is_ascii_digit())
            .count();
        if digits == 0 || digits > 3 || (digits > 1 && bytes[at] == b'0') {
            return None;
        }
        let value: u16 = std::str::from_utf8(&bytes[at..at + digits])
            .ok()?
            .parse()
            .ok()?;
        raw.push(u8::try_from(value).ok()?);
        at += digits;
        match bytes.get(at) {
            Some(b',') => at += 1,
            Some(b']') => return Some((raw, at)),
            _ => return None,
        }
    }
}

/// The exact bytes OpenMLS's storage uses for this group id, from a probe
/// store that runs the same serializer.
fn group_json<G: traits::GroupId<CURRENT_VERSION>>(
    group_id: &G,
) -> Result<Vec<u8>, PartitionError> {
    let probe = MemoryStorage::default();
    probe.write_own_leaf_index(group_id, &LeafNodeIndex::new(0))?;
    let values = probe
        .values
        .into_inner()
        .map_err(|_| PartitionError::Poisoned)?;
    let mut keys = values.into_keys();
    let (Some(key), None) = (keys.next(), keys.next()) else {
        return Err(PartitionError::UnexpectedKey);
    };
    key.strip_prefix(OWN_LEAF_NODE_INDEX_LABEL)
        .and_then(|rest| rest.strip_suffix(&VERSION_SUFFIX))
        .map(<[u8]>::to_vec)
        .ok_or(PartitionError::UnexpectedKey)
}

fn is_empty(store: &MemoryStorage) -> bool {
    store.values.read().map(|v| v.is_empty()).unwrap_or(false)
}

type Op<'a, T> = &'a dyn Fn(&MemoryStorage) -> Result<T, MemoryStorageError>;

impl PartitionedStorage {
    /// Runs one group operation with `group_id` as the only group the
    /// storage may touch. Any refused storage call fails the operation with
    /// `MlsError::Storage`, whatever OpenMLS made of the error. Scopes do
    /// not nest.
    pub(crate) fn scoped<T>(
        &self,
        group_id: &[u8],
        operation: impl FnOnce() -> Result<T, MlsError>,
    ) -> Result<T, MlsError> {
        let json = group_json(&GroupId::from_slice(group_id)).map_err(|_| MlsError::Storage)?;
        {
            let mut scope = self.scope.lock().map_err(|_| MlsError::Storage)?;
            if scope.active.is_some() {
                return Err(MlsError::Storage);
            }
            *scope = Scope {
                active: Some(ActiveGroup {
                    raw: group_id.to_vec(),
                    json,
                }),
                violated: false,
            };
        }
        // Clears the scope on every exit, unwinding included.
        struct Exit<'a>(&'a Mutex<Scope>);
        impl Drop for Exit<'_> {
            fn drop(&mut self) {
                let mut scope = self.0.lock().unwrap_or_else(|e| e.into_inner());
                scope.active = None;
            }
        }
        let exit = Exit(&self.scope);
        let result = operation();
        let violated = {
            let mut scope = self.scope.lock().map_err(|_| MlsError::Storage)?;
            std::mem::take(&mut scope.violated)
        };
        drop(exit);
        if violated {
            Err(MlsError::Storage)
        } else {
            result
        }
    }

    /// Splits a decoded flat format-2/3 map into its owners. Moves every
    /// record (no secret copies). Fails on any key it cannot place.
    pub(crate) fn from_records(records: Store) -> Result<Self, MlsError> {
        let storage = Self::default();
        #[cfg(test)]
        {
            *storage
                .shadow
                .values
                .write()
                .map_err(|_| MlsError::Storage)? = records.clone();
        }
        {
            let mut groups = storage.groups.write().map_err(|_| MlsError::Storage)?;
            let mut packages = storage
                .key_packages
                .write()
                .map_err(|_| MlsError::Storage)?;
            let mut device = storage
                .device
                .values
                .write()
                .map_err(|_| MlsError::Storage)?;
            let mut unowned = storage
                .unowned
                .values
                .write()
                .map_err(|_| MlsError::Storage)?;
            for (key, value) in records {
                let owner = classify(&key).ok_or(MlsError::InvalidState)?;
                let target = match owner {
                    Owner::Device => &mut *device,
                    Owner::Unowned => &mut *unowned,
                    Owner::Group(id) => groups
                        .entry(id)
                        .or_default()
                        .values
                        .get_mut()
                        .map_err(|_| MlsError::Storage)?,
                    Owner::KeyPackage(id) => packages
                        .entry(id)
                        .or_default()
                        .values
                        .get_mut()
                        .map_err(|_| MlsError::Storage)?,
                };
                if target.insert(key, value).is_some() {
                    return Err(MlsError::InvalidState);
                }
            }
        }
        Ok(storage)
    }

    /// Calls `encode` with every record of every owner, sorted by key: the
    /// flat map format 3 seals. Read locks are held throughout and nothing
    /// is copied. A key held by two owners fails.
    pub(crate) fn with_records<T>(
        &self,
        encode: impl FnOnce(&[(&[u8], &[u8])]) -> Result<T, MlsError>,
    ) -> Result<T, MlsError> {
        let groups = self.groups.read().map_err(|_| MlsError::Storage)?;
        let packages = self.key_packages.read().map_err(|_| MlsError::Storage)?;
        let guards = std::iter::once(&self.device)
            .chain(groups.values())
            .chain(packages.values())
            .chain(std::iter::once(&self.unowned))
            .map(|store| store.values.read().map_err(|_| MlsError::Storage))
            .collect::<Result<Vec<_>, _>>()?;
        let count = guards.iter().map(|guard| guard.len()).sum();
        let mut records = Vec::with_capacity(count);
        for guard in &guards {
            records.extend(guard.iter().map(|(k, v)| (k.as_slice(), v.as_slice())));
        }
        records.sort_unstable_by(|left, right| left.0.cmp(right.0));
        if records.windows(2).any(|pair| pair[0].0 == pair[1].0) {
            return Err(MlsError::InvalidState);
        }
        encode(&records)
    }

    fn hit(&self, _name: &'static str) {
        #[cfg(test)]
        self.hits.lock().unwrap().insert(_name);
    }

    #[cfg(test)]
    fn mirror<T>(&self, operation: Op<'_, T>) {
        operation(&self.shadow).expect("shadow store refused a routed call");
        self.assert_consistent();
    }

    #[cfg(not(test))]
    #[inline(always)]
    fn mirror<T>(&self, _operation: Op<'_, T>) {}

    /// The group id of the active scope, if the call may proceed. A
    /// refusal is remembered so `scoped` fails the operation.
    fn scope_for(&self, json: Option<&[u8]>) -> Result<Vec<u8>, PartitionError> {
        let mut scope = self.scope.lock().map_err(|_| PartitionError::Poisoned)?;
        let allowed = match (&scope.active, json) {
            (Some(active), Some(json)) if active.json == json => Some(active.raw.clone()),
            (Some(active), None) => Some(active.raw.clone()),
            _ => None,
        };
        allowed.ok_or_else(|| {
            scope.violated = true;
            PartitionError::OutOfScope
        })
    }

    fn group<G: traits::GroupId<CURRENT_VERSION>, T>(
        &self,
        name: &'static str,
        group_id: &G,
        write: bool,
        operation: Op<'_, T>,
    ) -> Result<T, PartitionError> {
        self.hit(name);
        let json = group_json(group_id)?;
        let id = self.scope_for(Some(&json))?;
        self.in_group(id, write, operation)
    }

    /// Standalone update-leaf key pairs: no group id, so the scope decides.
    fn scoped_key_pair<T>(
        &self,
        name: &'static str,
        write: bool,
        operation: Op<'_, T>,
    ) -> Result<T, PartitionError> {
        self.hit(name);
        let id = self.scope_for(None)?;
        self.in_group(id, write, operation)
    }

    fn in_group<T>(
        &self,
        id: Vec<u8>,
        write: bool,
        operation: Op<'_, T>,
    ) -> Result<T, PartitionError> {
        if !write {
            let groups = self.groups.read().map_err(|_| PartitionError::Poisoned)?;
            return Ok(operation(groups.get(&id).unwrap_or(&self.empty))?);
        }
        // Deletes go through here too: MemoryStorage's list removal writes
        // an empty list for a missing key, and the flat map would hold it.
        let result = {
            let mut groups = self.groups.write().map_err(|_| PartitionError::Poisoned)?;
            let store = groups.entry(id.clone()).or_default();
            let result = operation(store);
            if is_empty(store) {
                groups.remove(&id);
            }
            result?
        };
        self.mirror(operation);
        Ok(result)
    }

    fn device<T>(
        &self,
        name: &'static str,
        write: bool,
        operation: Op<'_, T>,
    ) -> Result<T, PartitionError> {
        self.hit(name);
        let result = operation(&self.device)?;
        if write {
            self.mirror(operation);
        }
        Ok(result)
    }
}

#[cfg(test)]
impl PartitionedStorage {
    /// Every owner's records, cloned, keyed by owner. Test inspection only.
    pub(crate) fn snapshot(&self) -> BTreeMap<String, Store> {
        let mut out = BTreeMap::new();
        out.insert(
            "device".to_owned(),
            self.device.values.read().unwrap().clone(),
        );
        out.insert(
            "unowned".to_owned(),
            self.unowned.values.read().unwrap().clone(),
        );
        for (id, store) in self.groups.read().unwrap().iter() {
            out.insert(
                format!("group:{}", String::from_utf8_lossy(id)),
                store.values.read().unwrap().clone(),
            );
        }
        for (id, store) in self.key_packages.read().unwrap().iter() {
            out.insert(
                format!("kp:{}", hex(id)),
                store.values.read().unwrap().clone(),
            );
        }
        out.retain(|_, store| !store.is_empty());
        out
    }

    pub(crate) fn flat(&self) -> Store {
        self.with_records(|records| {
            Ok(records
                .iter()
                .map(|(k, v)| (k.to_vec(), v.to_vec()))
                .collect())
        })
        .unwrap()
    }

    pub(crate) fn assert_consistent(&self) {
        let shadow = self.shadow.values.read().unwrap().clone();
        assert!(
            self.flat() == shadow,
            "partitions differ from the flat twin"
        );
        for (_, store) in self.groups.read().unwrap().iter() {
            assert!(!is_empty(store));
        }
    }

    pub(crate) fn hits(&self) -> std::collections::BTreeSet<&'static str> {
        self.hits.lock().unwrap().clone()
    }

    pub(crate) fn unowned_count(&self) -> usize {
        self.unowned.values.read().unwrap().len()
    }
}

#[cfg(test)]
#[path = "storage_tests.rs"]
mod tests;

#[cfg(test)]
pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl StorageProvider<CURRENT_VERSION> for PartitionedStorage {
    type Error = PartitionError;

    // --- group state writers ---

    fn write_mls_join_config<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MlsGroupJoinConfig: traits::MlsGroupJoinConfig<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        config: &MlsGroupJoinConfig,
    ) -> Result<(), Self::Error> {
        self.group("write_mls_join_config", group_id, true, &|s| {
            s.write_mls_join_config(group_id, config)
        })
    }

    fn append_own_leaf_node<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNode: traits::LeafNode<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        leaf_node: &LeafNode,
    ) -> Result<(), Self::Error> {
        self.group("append_own_leaf_node", group_id, true, &|s| {
            s.append_own_leaf_node(group_id, leaf_node)
        })
    }

    fn queue_proposal<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
        QueuedProposal: traits::QueuedProposal<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        proposal_ref: &ProposalRef,
        proposal: &QueuedProposal,
    ) -> Result<(), Self::Error> {
        self.group("queue_proposal", group_id, true, &|s| {
            s.queue_proposal(group_id, proposal_ref, proposal)
        })
    }

    fn write_tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        TreeSync: traits::TreeSync<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        tree: &TreeSync,
    ) -> Result<(), Self::Error> {
        self.group("write_tree", group_id, true, &|s| {
            s.write_tree(group_id, tree)
        })
    }

    fn write_interim_transcript_hash<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        InterimTranscriptHash: traits::InterimTranscriptHash<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        interim_transcript_hash: &InterimTranscriptHash,
    ) -> Result<(), Self::Error> {
        self.group("write_interim_transcript_hash", group_id, true, &|s| {
            s.write_interim_transcript_hash(group_id, interim_transcript_hash)
        })
    }

    fn write_context<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupContext: traits::GroupContext<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        group_context: &GroupContext,
    ) -> Result<(), Self::Error> {
        self.group("write_context", group_id, true, &|s| {
            s.write_context(group_id, group_context)
        })
    }

    fn write_confirmation_tag<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ConfirmationTag: traits::ConfirmationTag<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        confirmation_tag: &ConfirmationTag,
    ) -> Result<(), Self::Error> {
        self.group("write_confirmation_tag", group_id, true, &|s| {
            s.write_confirmation_tag(group_id, confirmation_tag)
        })
    }

    fn write_group_state<
        GroupState: traits::GroupState<CURRENT_VERSION>,
        GroupId: traits::GroupId<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        group_state: &GroupState,
    ) -> Result<(), Self::Error> {
        self.group("write_group_state", group_id, true, &|s| {
            s.write_group_state(group_id, group_state)
        })
    }

    fn write_message_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MessageSecrets: traits::MessageSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        message_secrets: &MessageSecrets,
    ) -> Result<(), Self::Error> {
        self.group("write_message_secrets", group_id, true, &|s| {
            s.write_message_secrets(group_id, message_secrets)
        })
    }

    fn write_resumption_psk_store<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ResumptionPskStore: traits::ResumptionPskStore<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        resumption_psk_store: &ResumptionPskStore,
    ) -> Result<(), Self::Error> {
        self.group("write_resumption_psk_store", group_id, true, &|s| {
            s.write_resumption_psk_store(group_id, resumption_psk_store)
        })
    }

    fn write_own_leaf_index<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNodeIndex: traits::LeafNodeIndex<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        own_leaf_index: &LeafNodeIndex,
    ) -> Result<(), Self::Error> {
        self.group("write_own_leaf_index", group_id, true, &|s| {
            s.write_own_leaf_index(group_id, own_leaf_index)
        })
    }

    fn write_group_epoch_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupEpochSecrets: traits::GroupEpochSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        group_epoch_secrets: &GroupEpochSecrets,
    ) -> Result<(), Self::Error> {
        self.group("write_group_epoch_secrets", group_id, true, &|s| {
            s.write_group_epoch_secrets(group_id, group_epoch_secrets)
        })
    }

    // --- crypto object writers ---

    fn write_signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<CURRENT_VERSION>,
        SignatureKeyPair: traits::SignatureKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &SignaturePublicKey,
        signature_key_pair: &SignatureKeyPair,
    ) -> Result<(), Self::Error> {
        self.device("write_signature_key_pair", true, &|s| {
            s.write_signature_key_pair(public_key, signature_key_pair)
        })
    }

    fn write_encryption_key_pair<
        EncryptionKey: traits::EncryptionKey<CURRENT_VERSION>,
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &EncryptionKey,
        key_pair: &HpkeKeyPair,
    ) -> Result<(), Self::Error> {
        self.scoped_key_pair("write_encryption_key_pair", true, &|s| {
            s.write_encryption_key_pair(public_key, key_pair)
        })
    }

    fn write_encryption_epoch_key_pairs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        EpochKey: traits::EpochKey<CURRENT_VERSION>,
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
        key_pairs: &[HpkeKeyPair],
    ) -> Result<(), Self::Error> {
        self.group("write_encryption_epoch_key_pairs", group_id, true, &|s| {
            s.write_encryption_epoch_key_pairs(group_id, epoch, leaf_index, key_pairs)
        })
    }

    fn write_key_package<
        HashReference: traits::HashReference<CURRENT_VERSION>,
        KeyPackage: traits::KeyPackage<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &HashReference,
        key_package: &KeyPackage,
    ) -> Result<(), Self::Error> {
        self.hit("write_key_package");
        // Written into its own store first: the one key it holds names the
        // owner.
        let fresh = MemoryStorage::default();
        fresh.write_key_package(hash_ref, key_package)?;
        let id = {
            let values = fresh.values.read().map_err(|_| PartitionError::Poisoned)?;
            let mut keys = values.keys();
            let (Some(key), None) = (keys.next(), keys.next()) else {
                return Err(PartitionError::UnexpectedKey);
            };
            if !key.starts_with(KEY_PACKAGE_LABEL) {
                return Err(PartitionError::UnexpectedKey);
            }
            match classify(key) {
                Some(Owner::KeyPackage(id)) => id,
                _ => return Err(PartitionError::UnexpectedKey),
            }
        };
        {
            let mut packages = self
                .key_packages
                .write()
                .map_err(|_| PartitionError::Poisoned)?;
            match packages.entry(id) {
                std::collections::btree_map::Entry::Vacant(slot) => {
                    slot.insert(fresh);
                }
                std::collections::btree_map::Entry::Occupied(slot) => {
                    let records = fresh
                        .values
                        .into_inner()
                        .map_err(|_| PartitionError::Poisoned)?;
                    slot.get()
                        .values
                        .write()
                        .map_err(|_| PartitionError::Poisoned)?
                        .extend(records);
                }
            }
        }
        self.mirror(&|s| s.write_key_package(hash_ref, key_package));
        Ok(())
    }

    fn write_psk<
        PskId: traits::PskId<CURRENT_VERSION>,
        PskBundle: traits::PskBundle<CURRENT_VERSION>,
    >(
        &self,
        psk_id: &PskId,
        psk: &PskBundle,
    ) -> Result<(), Self::Error> {
        self.device("write_psk", true, &|s| s.write_psk(psk_id, psk))
    }

    // --- group state getters ---

    fn mls_group_join_config<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MlsGroupJoinConfig: traits::MlsGroupJoinConfig<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<MlsGroupJoinConfig>, Self::Error> {
        self.group("mls_group_join_config", group_id, false, &|s| {
            s.mls_group_join_config(group_id)
        })
    }

    fn own_leaf_nodes<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNode: traits::LeafNode<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<LeafNode>, Self::Error> {
        self.group("own_leaf_nodes", group_id, false, &|s| {
            s.own_leaf_nodes(group_id)
        })
    }

    fn queued_proposal_refs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<ProposalRef>, Self::Error> {
        self.group("queued_proposal_refs", group_id, false, &|s| {
            s.queued_proposal_refs(group_id)
        })
    }

    fn queued_proposals<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
        QueuedProposal: traits::QueuedProposal<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Vec<(ProposalRef, QueuedProposal)>, Self::Error> {
        self.group("queued_proposals", group_id, false, &|s| {
            s.queued_proposals(group_id)
        })
    }

    fn tree<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        TreeSync: traits::TreeSync<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<TreeSync>, Self::Error> {
        self.group("tree", group_id, false, &|s| s.tree(group_id))
    }

    fn group_context<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupContext: traits::GroupContext<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupContext>, Self::Error> {
        self.group("group_context", group_id, false, &|s| {
            s.group_context(group_id)
        })
    }

    fn interim_transcript_hash<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        InterimTranscriptHash: traits::InterimTranscriptHash<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<InterimTranscriptHash>, Self::Error> {
        self.group("interim_transcript_hash", group_id, false, &|s| {
            s.interim_transcript_hash(group_id)
        })
    }

    fn confirmation_tag<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ConfirmationTag: traits::ConfirmationTag<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ConfirmationTag>, Self::Error> {
        self.group("confirmation_tag", group_id, false, &|s| {
            s.confirmation_tag(group_id)
        })
    }

    fn group_state<
        GroupState: traits::GroupState<CURRENT_VERSION>,
        GroupId: traits::GroupId<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupState>, Self::Error> {
        self.group("group_state", group_id, false, &|s| s.group_state(group_id))
    }

    fn message_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        MessageSecrets: traits::MessageSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<MessageSecrets>, Self::Error> {
        self.group("message_secrets", group_id, false, &|s| {
            s.message_secrets(group_id)
        })
    }

    fn resumption_psk_store<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ResumptionPskStore: traits::ResumptionPskStore<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<ResumptionPskStore>, Self::Error> {
        self.group("resumption_psk_store", group_id, false, &|s| {
            s.resumption_psk_store(group_id)
        })
    }

    fn own_leaf_index<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        LeafNodeIndex: traits::LeafNodeIndex<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<LeafNodeIndex>, Self::Error> {
        self.group("own_leaf_index", group_id, false, &|s| {
            s.own_leaf_index(group_id)
        })
    }

    fn group_epoch_secrets<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        GroupEpochSecrets: traits::GroupEpochSecrets<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<Option<GroupEpochSecrets>, Self::Error> {
        self.group("group_epoch_secrets", group_id, false, &|s| {
            s.group_epoch_secrets(group_id)
        })
    }

    // --- crypto object getters ---

    fn signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<CURRENT_VERSION>,
        SignatureKeyPair: traits::SignatureKeyPair<CURRENT_VERSION>,
    >(
        &self,
        public_key: &SignaturePublicKey,
    ) -> Result<Option<SignatureKeyPair>, Self::Error> {
        self.device("signature_key_pair", false, &|s| {
            s.signature_key_pair(public_key)
        })
    }

    fn encryption_key_pair<
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
        EncryptionKey: traits::EncryptionKey<CURRENT_VERSION>,
    >(
        &self,
        public_key: &EncryptionKey,
    ) -> Result<Option<HpkeKeyPair>, Self::Error> {
        self.scoped_key_pair("encryption_key_pair", false, &|s| {
            s.encryption_key_pair(public_key)
        })
    }

    fn encryption_epoch_key_pairs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        EpochKey: traits::EpochKey<CURRENT_VERSION>,
        HpkeKeyPair: traits::HpkeKeyPair<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
    ) -> Result<Vec<HpkeKeyPair>, Self::Error> {
        self.group("encryption_epoch_key_pairs", group_id, false, &|s| {
            s.encryption_epoch_key_pairs(group_id, epoch, leaf_index)
        })
    }

    fn key_package<
        KeyPackageRef: traits::HashReference<CURRENT_VERSION>,
        KeyPackage: traits::KeyPackage<CURRENT_VERSION>,
    >(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<Option<KeyPackage>, Self::Error> {
        self.hit("key_package");
        // The reference cannot be turned into bytes without the
        // serializer, so each package store is asked; only its own answers.
        let packages = self
            .key_packages
            .read()
            .map_err(|_| PartitionError::Poisoned)?;
        for store in packages.values() {
            if let Some(package) = store.key_package(hash_ref)? {
                return Ok(Some(package));
            }
        }
        Ok(None)
    }

    fn psk<PskBundle: traits::PskBundle<CURRENT_VERSION>, PskId: traits::PskId<CURRENT_VERSION>>(
        &self,
        psk_id: &PskId,
    ) -> Result<Option<PskBundle>, Self::Error> {
        self.device("psk", false, &|s| s.psk(psk_id))
    }

    // --- group state deleters ---

    fn remove_proposal<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        proposal_ref: &ProposalRef,
    ) -> Result<(), Self::Error> {
        self.group("remove_proposal", group_id, true, &|s| {
            s.remove_proposal(group_id, proposal_ref)
        })
    }

    fn delete_own_leaf_nodes<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_own_leaf_nodes", group_id, true, &|s| {
            s.delete_own_leaf_nodes(group_id)
        })
    }

    fn delete_group_config<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_group_config", group_id, true, &|s| {
            s.delete_group_config(group_id)
        })
    }

    fn delete_tree<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_tree", group_id, true, &|s| s.delete_tree(group_id))
    }

    fn delete_confirmation_tag<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_confirmation_tag", group_id, true, &|s| {
            s.delete_confirmation_tag(group_id)
        })
    }

    fn delete_group_state<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_group_state", group_id, true, &|s| {
            s.delete_group_state(group_id)
        })
    }

    fn delete_context<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_context", group_id, true, &|s| {
            s.delete_context(group_id)
        })
    }

    fn delete_interim_transcript_hash<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_interim_transcript_hash", group_id, true, &|s| {
            s.delete_interim_transcript_hash(group_id)
        })
    }

    fn delete_message_secrets<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_message_secrets", group_id, true, &|s| {
            s.delete_message_secrets(group_id)
        })
    }

    fn delete_all_resumption_psk_secrets<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_all_resumption_psk_secrets", group_id, true, &|s| {
            s.delete_all_resumption_psk_secrets(group_id)
        })
    }

    fn delete_own_leaf_index<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_own_leaf_index", group_id, true, &|s| {
            s.delete_own_leaf_index(group_id)
        })
    }

    fn delete_group_epoch_secrets<GroupId: traits::GroupId<CURRENT_VERSION>>(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("delete_group_epoch_secrets", group_id, true, &|s| {
            s.delete_group_epoch_secrets(group_id)
        })
    }

    fn clear_proposal_queue<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        ProposalRef: traits::ProposalRef<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
    ) -> Result<(), Self::Error> {
        self.group("clear_proposal_queue", group_id, true, &|s| {
            s.clear_proposal_queue::<GroupId, ProposalRef>(group_id)
        })
    }

    // --- crypto object deleters ---

    fn delete_signature_key_pair<
        SignaturePublicKey: traits::SignaturePublicKey<CURRENT_VERSION>,
    >(
        &self,
        public_key: &SignaturePublicKey,
    ) -> Result<(), Self::Error> {
        self.device("delete_signature_key_pair", true, &|s| {
            s.delete_signature_key_pair(public_key)
        })
    }

    fn delete_encryption_key_pair<EncryptionKey: traits::EncryptionKey<CURRENT_VERSION>>(
        &self,
        public_key: &EncryptionKey,
    ) -> Result<(), Self::Error> {
        self.scoped_key_pair("delete_encryption_key_pair", true, &|s| {
            s.delete_encryption_key_pair(public_key)
        })
    }

    fn delete_encryption_epoch_key_pairs<
        GroupId: traits::GroupId<CURRENT_VERSION>,
        EpochKey: traits::EpochKey<CURRENT_VERSION>,
    >(
        &self,
        group_id: &GroupId,
        epoch: &EpochKey,
        leaf_index: u32,
    ) -> Result<(), Self::Error> {
        self.group("delete_encryption_epoch_key_pairs", group_id, true, &|s| {
            s.delete_encryption_epoch_key_pairs(group_id, epoch, leaf_index)
        })
    }

    fn delete_key_package<KeyPackageRef: traits::HashReference<CURRENT_VERSION>>(
        &self,
        hash_ref: &KeyPackageRef,
    ) -> Result<(), Self::Error> {
        self.hit("delete_key_package");
        {
            let mut packages = self
                .key_packages
                .write()
                .map_err(|_| PartitionError::Poisoned)?;
            for store in packages.values() {
                store.delete_key_package(hash_ref)?;
            }
            packages.retain(|_, store| !is_empty(store));
        }
        self.mirror(&|s| s.delete_key_package(hash_ref));
        Ok(())
    }

    fn delete_psk<PskKey: traits::PskId<CURRENT_VERSION>>(
        &self,
        psk_id: &PskKey,
    ) -> Result<(), Self::Error> {
        self.device("delete_psk", true, &|s| s.delete_psk(psk_id))
    }
}
