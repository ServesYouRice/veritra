//! OpenMLS core operations.
//!
//! This module is intentionally not exposed through the C ABI yet. It proves
//! the selected library and protocol flow while platform key wrapping and ABI
//! ownership semantics are still under review.

use crate::c7;
use openmls::prelude::*;
use openmls::treesync::LeafNodeParameters;
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::{signatures::Signer, storage::StorageProvider as _, OpenMlsProvider};
use sha2::{Digest, Sha256, Sha512};
use tls_codec::{Deserialize as TlsDeserializeTrait, Serialize as TlsSerializeTrait};

mod c4;
pub mod leave_proof;
#[allow(dead_code)]
pub(crate) mod link_v3;
mod list;
mod records;
mod state;
mod storage;
pub use c4::{
    encode_role_state, CommitReview, MAX_ROLE_RECORD_BYTES, REVIEW_ADDED, REVIEW_RECORD_AFTER,
    REVIEW_RECORD_BEFORE, REVIEW_RECORD_PROPOSAL, REVIEW_REMOVED, REVIEW_REMOVED_SELF,
    ROLE_EXTENSION_TYPE,
};
pub use list::{LeafPair, RecoverySignError};
pub use records::{ChangeSet, RecordChange, RestoreLoader, SealError};
pub(crate) use records::{MAX_SEALED_RECORD_BYTES, MAX_SEALED_ROOT_BYTES};
#[allow(dead_code)]
pub(crate) mod transfer;

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const MAX_ID_BYTES: usize = 128;
const PADDING_BYTES: usize = 256;
const CREDENTIAL_FORMAT_VERSION: u8 = 1;
const DEVICE_LINK_TRANSCRIPT_DOMAIN: &[u8] = b"veritra-device-link-transcript";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MlsError {
    InvalidIdentity,
    KeyGeneration,
    Storage,
    InvalidKeyPackage,
    GroupOperation,
    InvalidMessage,
    UnexpectedMessage,
    InvalidState,
    Rollback,
    /// The message decrypted, but its MLS sender credential is not the
    /// account/device the transport claimed. The ratchet has already advanced.
    SenderMismatch,
    /// The message decrypted from a retained past epoch, but its sender is
    /// no longer in the group. The ratchet has already advanced.
    SenderRemoved,
    /// Sealed state with the right magic but a format version this build
    /// does not read (format 1 from OpenMLS 0.8.1, or a newer build). The
    /// version is read before authentication: a hint for the recovery path,
    /// never a reason to relax a check.
    UnsupportedFormat,
    /// A Welcome names no key package this device holds, or the one it
    /// names has expired (D74). Nothing was consumed. Refusing it forks
    /// nothing: the device is just not in the group, and someone has to
    /// add it again.
    KeyPackageUnavailable,
}

/// What a processed or merged commit did (C7, ABI 13), read from the staged
/// commit and never from a server label.
pub struct CommitOutcome {
    /// At least one Remove proposal (a device replacement included).
    pub removed_any: bool,
    /// At least one Add proposal.
    pub added_any: bool,
    /// The commit removed this device. Then there is no `root`.
    pub removed_self: bool,
    /// The epoch the commit produces.
    pub new_epoch: u64,
    /// L1 (ABI 14): the `(account, device, signature key)` of every leaf the
    /// commit's Add proposals bring in, read from the staged commit, already
    /// encoded (`l1::encode_leaf_pairs`). Encoded before the merge, so an
    /// encoding failure refuses the commit with the group untouched and can
    /// never be reported after the state has changed (D94).
    pub added_pairs: Vec<u8>,
    /// L1: the committer's pair (this device's own for its own commit), in
    /// the same encoding and with the same ordering guarantee.
    pub committer_pair: Vec<u8>,
    /// `MLS-Exporter("veritra-c7-rekey-v1", lp(group_id) | u64(new_epoch), 32)`
    /// for a removal commit that keeps this device; zeroized on drop.
    pub root: Option<tls_codec::SecretVLBytes>,
}

/// One MLS device identity and its private provider state.
///
/// Provider state can be exported only as an authenticated encrypted envelope.
/// The production ABI remains disabled until platforms atomically commit that
/// envelope, its rollback counter, and the sync cursor under Keystore/Keychain
/// protection.
pub struct MlsDevice {
    provider: storage::VeritraProvider,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    account_id: Vec<u8>,
    device_id: Vec<u8>,
    pending_transfers: transfer::PendingTransfers,
    /// What was last sealed or restored in format 4 (D70).
    sealed: records::SealedState,
    /// L1: the device-list recovery seed a waiting recovered phone holds
    /// (D94). Sealed in the device record; never leaves Rust.
    held_list_seed: Option<tls_codec::SecretVLBytes>,
    /// C4 (ABI 20): remote commits staged for Dart's review, by group. In
    /// memory only: never sealed, gone after a restore.
    held: c4::HeldCommits,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceLinkVerification {
    pub transcript_hash: Vec<u8>,
    pub sas: String,
    pub claim_tag: Vec<u8>,
    pub approval_tag: Vec<u8>,
    pub sas_bytes: Vec<u8>,
}

impl MlsDevice {
    pub(crate) fn validate_local_key_package(&self, bytes: &[u8]) -> Result<(), MlsError> {
        let package = KeyPackageIn::tls_deserialize_exact(bytes)
            .map_err(|_| MlsError::InvalidKeyPackage)?
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(|_| MlsError::InvalidKeyPackage)?;
        if package.leaf_node().credential().serialized_content()
            != encode_device_identity(&self.account_id, &self.device_id)?
            || package.leaf_node().signature_key().as_slice() != self.signing_public_key()
        {
            return Err(MlsError::InvalidKeyPackage);
        }
        Ok(())
    }

    pub fn new(account_id: &[u8], device_id: &[u8]) -> Result<Self, MlsError> {
        let identity = encode_device_identity(account_id, device_id)?;
        let provider = storage::VeritraProvider::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
            .map_err(|_| MlsError::KeyGeneration)?;
        signer
            .store(provider.storage())
            .map_err(|_| MlsError::Storage)?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity).into(),
            signature_key: signer.public().into(),
        };
        Ok(Self {
            provider,
            signer,
            credential,
            account_id: account_id.to_vec(),
            device_id: device_id.to_vec(),
            pending_transfers: Default::default(),
            sealed: Default::default(),
            held_list_seed: None,
            held: Default::default(),
        })
    }

    pub fn create_key_package(&self) -> Result<Vec<u8>, MlsError> {
        // A full pool is refused at creation, so the sealed state never
        // carries more key packages than restore accepts (D70).
        if self.provider.storage().key_package_count()? >= records::MAX_KEY_PACKAGES {
            return Err(MlsError::InvalidState);
        }
        // L2-1 (ABI 23): the package is padded to a size bucket by one pad
        // extension. Its unpadded size depends only on the credential, so a
        // throwaway package with the same credential, built in memory and
        // never stored, measures it.
        let bare = self.bare_key_package_size()?;
        let pad = crate::l2::key_package_pad(bare);
        let extensions = match pad {
            Some(pad) => Extensions::single(crate::l2::pad_extension(pad))
                .map_err(|_| MlsError::KeyGeneration)?,
            None => Extensions::default(),
        };
        // C4 (ABI 20): every leaf advertises the role extension.
        let bundle = KeyPackage::builder()
            .leaf_node_capabilities(c4::leaf_capabilities())
            .key_package_extensions(extensions)
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential.clone(),
            )
            .map_err(|_| MlsError::KeyGeneration)?;
        let bytes = bundle
            .key_package()
            .tls_serialize_detached()
            .map_err(|_| MlsError::KeyGeneration)?;
        debug_assert!(pad.is_none() || crate::l2::bucket(bytes.len()) == Some(bytes.len()));
        Ok(bytes)
    }

    /// The size of this device's key package with no extensions, from a
    /// throwaway package (fresh keys, the same credential and capabilities)
    /// that only an in-memory provider ever sees.
    fn bare_key_package_size(&self) -> Result<usize, MlsError> {
        let provider = openmls_rust_crypto::OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
            .map_err(|_| MlsError::KeyGeneration)?;
        let credential = CredentialWithKey {
            credential: self.credential.credential.clone(),
            signature_key: signer.public().into(),
        };
        let bundle = KeyPackage::builder()
            .leaf_node_capabilities(c4::leaf_capabilities())
            .build(CIPHERSUITE, &provider, &signer, credential)
            .map_err(|_| MlsError::KeyGeneration)?;
        bundle
            .key_package()
            .tls_serialize_detached()
            .map(|bytes| bytes.len())
            .map_err(|_| MlsError::KeyGeneration)
    }

    pub fn signing_public_key(&self) -> &[u8] {
        self.signer.public()
    }

    /// Creates a key package and signs the server's enrollment proof with
    /// the Ed25519 key of this device's MLS credential. The signed message is
    /// always `veritra-enrollment-proof-v1 || u16 len || challenge ||
    /// signing key || SHA-256(key package)`: the fixed ASCII prefix cannot
    /// start an RFC 9420 SignContent (a varint length, then "MLS 1.0 "), so
    /// the server cannot use this to obtain an MLS signature. There is no
    /// raw signing entry point.
    pub fn create_enrollment_credential(
        &self,
        challenge: &[u8],
    ) -> Result<EnrollmentCredential, MlsError> {
        if challenge.is_empty() || challenge.len() > u16::MAX as usize {
            return Err(MlsError::InvalidIdentity);
        }
        let key_package = self.create_key_package()?;
        let signing_public_key = self.signing_public_key().to_vec();
        let mut proof = b"veritra-enrollment-proof-v1".to_vec();
        proof.extend_from_slice(&(challenge.len() as u16).to_be_bytes());
        proof.extend_from_slice(challenge);
        proof.extend_from_slice(&signing_public_key);
        proof.extend_from_slice(&Sha256::digest(&key_package));
        let challenge_signature = self
            .signer
            .sign(&proof)
            .map_err(|_| MlsError::KeyGeneration)?;
        Ok(EnrollmentCredential {
            key_package,
            signing_public_key,
            challenge_signature,
        })
    }

    pub fn create_group(&self, group_id: &[u8]) -> Result<MlsGroup, MlsError> {
        if group_id.is_empty() || group_id.len() > MAX_ID_BYTES {
            return Err(MlsError::InvalidIdentity);
        }
        self.in_group(group_id, || {
            MlsGroup::new_with_group_id(
                &self.provider,
                &self.signer,
                &group_create_config(),
                GroupId::from_slice(group_id),
                self.credential.clone(),
            )
            .map_err(|_| MlsError::GroupOperation)
        })
    }

    /// Runs one group operation with storage scoped to `group_id` (D70):
    /// a storage call for any other group fails it with
    /// [`MlsError::Storage`].
    fn in_group<T>(
        &self,
        group_id: &[u8],
        operation: impl FnOnce() -> Result<T, MlsError>,
    ) -> Result<T, MlsError> {
        self.provider.storage().scoped(group_id, operation)
    }

    pub fn load_group(&self, group_id: &[u8]) -> Result<MlsGroup, MlsError> {
        if group_id.is_empty() || group_id.len() > MAX_ID_BYTES {
            return Err(MlsError::InvalidIdentity);
        }
        self.in_group(group_id, || {
            MlsGroup::load(self.provider.storage(), &GroupId::from_slice(group_id))
                .map_err(|_| MlsError::Storage)?
                .ok_or(MlsError::InvalidState)
        })
    }

    pub fn add_member(
        &self,
        group: &mut MlsGroup,
        key_package_bytes: &[u8],
        expected_account_id: &[u8],
        expected_device_id: &[u8],
    ) -> Result<AddMemberMessages, MlsError> {
        let key_package = KeyPackageIn::tls_deserialize_exact(key_package_bytes)
            .map_err(|_| MlsError::InvalidKeyPackage)?
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(|_| MlsError::InvalidKeyPackage)?;
        let expected_identity = encode_device_identity(expected_account_id, expected_device_id)?;
        // The same check receivers run on the commit (inspect_commit).
        if basic_identity(key_package.leaf_node().credential())
            .map_err(|_| MlsError::InvalidKeyPackage)?
            != expected_identity
        {
            return Err(MlsError::InvalidKeyPackage);
        }
        ensure_added_identities_unique(&roster_identities(group, &[]), &[expected_identity])?;
        let id = group.group_id().as_slice().to_vec();
        let (commit, welcome, _) = self.in_group(&id, || {
            group
                .add_members(&self.provider, &self.signer, &[key_package])
                .map_err(|_| MlsError::GroupOperation)
        })?;
        let commit = commit
            .tls_serialize_detached()
            .map_err(|_| MlsError::GroupOperation)?;
        let welcome = welcome
            .tls_serialize_detached()
            .map_err(|_| MlsError::GroupOperation)?;
        Ok(AddMemberMessages { commit, welcome })
    }

    /// Stages one commit that adds and removes any number of devices (card
    /// I51). The commit is not merged: the caller merges it only after the
    /// server accepts it for this epoch, or clears it if another commit won,
    /// so a rejected commit never forks local state.
    pub fn stage_membership_commit(
        &self,
        group: &mut MlsGroup,
        adds: &[MemberAdd<'_>],
        removes: &[MemberIdentity<'_>],
    ) -> Result<StagedCommitMessages, MlsError> {
        self.stage_membership_commit_checked(group, adds, &vec![None; adds.len()], removes)
    }

    /// [`Self::stage_membership_commit`] with the signature key each added
    /// device is expected to hold (L1, ABI 14: change list version 2). Where
    /// `expected_keys[i]` is `Some(key)`, a key package whose leaf signature
    /// key differs is refused, which closes the gap between "the approved
    /// list says key K" and "the key package the server handed over".
    pub fn stage_membership_commit_checked(
        &self,
        group: &mut MlsGroup,
        adds: &[MemberAdd<'_>],
        expected_keys: &[Option<&[u8]>],
        removes: &[MemberIdentity<'_>],
    ) -> Result<StagedCommitMessages, MlsError> {
        self.stage_commit_with_record(group, adds, expected_keys, removes, None)
    }

    /// [`Self::stage_membership_commit_checked`] that may also carry the
    /// group's new role record (C4, ABI 20) as one GroupContextExtensions
    /// proposal. With a record, `adds` and `removes` may both be empty (a
    /// role change alone). The record must differ from the current one, and
    /// the group must already carry one (a group without a record never
    /// gains one). The staged commit is checked with the receivers' rule
    /// before it is returned; a commit they would refuse is cleared.
    pub fn stage_commit_with_record(
        &self,
        group: &mut MlsGroup,
        adds: &[MemberAdd<'_>],
        expected_keys: &[Option<&[u8]>],
        removes: &[MemberIdentity<'_>],
        record: Option<&[u8]>,
    ) -> Result<StagedCommitMessages, MlsError> {
        self.stage_commit_proven(group, adds, expected_keys, removes, record, None)
    }

    /// [`Self::stage_commit_with_record`] that also carries the leave
    /// statements the app holds for the devices it removes (C4 leave proof
    /// in the commit, ABI 24) in the commit's authenticated data.
    /// `leave_proofs` is a `VCL1` list ([`leave_proof::encode_aad`]); a
    /// malformed one is refused. Statements whose leaf this commit keeps or
    /// that no longer verify against the tree (the leaf changed since it
    /// signed) are dropped, and with none left the commit has no AAD.
    ///
    /// OpenMLS clears the AAD after each staged commit, and a padded
    /// Welcome stages up to seven times, so the AAD is set inside every
    /// attempt. After staging, the commit's bytes are read back and their
    /// AAD must be exactly the one chosen, or the commit is cleared.
    pub fn stage_commit_proven(
        &self,
        group: &mut MlsGroup,
        adds: &[MemberAdd<'_>],
        expected_keys: &[Option<&[u8]>],
        removes: &[MemberIdentity<'_>],
        record: Option<&[u8]>,
        leave_proofs: Option<&[u8]>,
    ) -> Result<StagedCommitMessages, MlsError> {
        if expected_keys.len() != adds.len() {
            return Err(MlsError::InvalidKeyPackage);
        }
        if adds.is_empty() && removes.is_empty() && record.is_none() {
            return Err(MlsError::InvalidState);
        }
        if group.pending_commit().is_some() {
            return Err(MlsError::InvalidState);
        }
        let record_extensions = record
            .map(|record| c4::replaced_extensions(group.extensions(), record))
            .transpose()?;
        let mut key_packages = Vec::with_capacity(adds.len());
        let mut added = Vec::with_capacity(adds.len());
        for (add, expected_key) in adds.iter().zip(expected_keys) {
            let key_package = KeyPackageIn::tls_deserialize_exact(add.key_package)
                .map_err(|_| MlsError::InvalidKeyPackage)?
                .validate(self.provider.crypto(), ProtocolVersion::Mls10)
                .map_err(|_| MlsError::InvalidKeyPackage)?;
            let expected = encode_device_identity(add.account_id, add.device_id)?;
            // The same check receivers run on the commit (inspect_commit).
            if basic_identity(key_package.leaf_node().credential())
                .map_err(|_| MlsError::InvalidKeyPackage)?
                != expected
            {
                return Err(MlsError::InvalidKeyPackage);
            }
            if expected_key
                .is_some_and(|key| key_package.leaf_node().signature_key().as_slice() != key)
            {
                return Err(MlsError::InvalidKeyPackage);
            }
            check_key_package_pad(&key_package)?;
            key_packages.push(key_package);
            added.push(expected);
        }
        // A removed device loses every leaf that carries its identity.
        let mut removed = Vec::with_capacity(removes.len());
        for member in removes {
            removed.extend(self.member_indices(group, member.account_id, member.device_id)?);
        }
        removed.sort();
        removed.dedup();
        ensure_added_identities_unique(&roster_identities(group, &removed), &added)?;
        let aad = match leave_proofs {
            Some(proofs) => leave_proof::committer_aad(group, &removed, proofs)?,
            None => None,
        }
        .unwrap_or_default();
        let epoch = group.epoch().as_u64();
        let id = group.group_id().as_slice().to_vec();
        let stage = |group: &mut MlsGroup, pad: Option<usize>| {
            // Every attempt: OpenMLS resets the AAD once a commit is staged.
            group.set_aad(aad.clone());
            self.in_group(&id, || {
                let builder = group
                    .commit_builder()
                    .propose_adds(key_packages.clone())
                    .propose_removals(removed.iter().copied());
                let builder = match &record_extensions {
                    Some(extensions) => builder
                        .propose_group_context_extensions(extensions.clone())
                        .map_err(|_| MlsError::GroupOperation)?,
                    None => builder,
                };
                let builder = builder
                    .load_psks(self.provider.storage())
                    .map_err(|_| MlsError::GroupOperation)?;
                let builder = match pad {
                    Some(pad) => builder
                        .create_group_info_with_extensions([crate::l2::pad_extension(pad)])
                        .map_err(|_| MlsError::GroupOperation)?,
                    None => builder,
                };
                builder
                    .build(
                        self.provider.rand(),
                        self.provider.crypto(),
                        &self.signer,
                        |_| true,
                    )
                    .map_err(|_| MlsError::GroupOperation)?
                    .stage_commit(&self.provider)
                    .map_err(|_| MlsError::GroupOperation)
            })
        };
        let bundle = if adds.is_empty() {
            stage(group, None)
        } else {
            self.stage_padded_welcome(group, stage)
        };
        // A failed build leaves the AAD set; it must never ride on the next
        // application message.
        group.set_aad(Vec::new());
        let bundle = bundle?;
        // The sender runs the receivers' check on its own commit, so it never
        // sends what every receiver refuses (and never merges it).
        let checked = match group.pending_commit() {
            Some(staged) => inspect_commit(group, group.own_leaf_index(), staged, true),
            None => Err(MlsError::GroupOperation),
        };
        let (commit, welcome, _) = bundle.into_messages();
        let commit = checked.and_then(|()| {
            let commit = commit
                .tls_serialize_detached()
                .map_err(|_| MlsError::GroupOperation)?;
            // The AAD that went out is the one chosen, and what it proves is
            // what a receiver will read from it.
            if commit_aad(&commit)? != aad
                || (!aad.is_empty()
                    && leave_proof::proven_leaves(group, &removed, &aad).len()
                        != leave_proof::parse_aad(&aad).map_or(0, |s| s.len()))
            {
                return Err(MlsError::GroupOperation);
            }
            Ok(commit)
        });
        let commit = match commit {
            Ok(commit) => commit,
            Err(error) => {
                let _ = self.clear_pending_commit(group);
                return Err(error);
            }
        };
        let welcome = match welcome {
            Some(welcome) => welcome
                .tls_serialize_detached()
                .map_err(|_| MlsError::GroupOperation)?,
            None => Vec::new(),
        };
        if adds.is_empty() != welcome.is_empty() {
            return Err(MlsError::GroupOperation);
        }
        Ok(StagedCommitMessages {
            commit,
            welcome,
            epoch,
        })
    }

    /// L2-1 (ABI 23): stages a commit whose Welcome is padded to a size
    /// bucket ([`crate::l2::bucket`]) by a pad extension in its GroupInfo,
    /// which is encrypted and signed, so neither the server nor a network
    /// observer reads the unpadded length.
    ///
    /// The GroupInfo's size is known only once the commit is built, so the
    /// commit is staged with a 64-byte pad, measured, cleared and staged
    /// again with the pad that reaches the bucket (64 bytes keeps the pad's
    /// own length prefix at two bytes, so the size grows by one per pad
    /// byte). A third stage is needed only when a vector length prefix
    /// crosses 16 KiB; a bucket that a prefix step jumps over is replaced by
    /// the next one. Building writes nothing; each discarded stage costs one
    /// handshake ratchet generation, which receivers skip as they would a
    /// lost message. A Welcome already over [`crate::l2::MAX_PADDED`] keeps
    /// its 64-byte pad.
    fn stage_padded_welcome(
        &self,
        group: &mut MlsGroup,
        stage: impl Fn(&mut MlsGroup, Option<usize>) -> Result<CommitMessageBundle, MlsError>,
    ) -> Result<CommitMessageBundle, MlsError> {
        const FIRST_PAD: usize = 64;
        const MAX_STAGES: usize = 6;
        let mut pad = FIRST_PAD;
        let mut target: Option<usize> = None;
        let mut tried = Vec::with_capacity(MAX_STAGES);
        for _ in 0..MAX_STAGES {
            let bundle = stage(group, Some(pad))?;
            let size = bundle
                .to_welcome_msg()
                .ok_or(MlsError::GroupOperation)?
                .tls_serialized_len();
            tried.push(pad);
            let goal = match target {
                Some(goal) => goal,
                None => match crate::l2::bucket(size) {
                    Some(goal) => goal,
                    None => return Ok(bundle),
                },
            };
            if size == goal {
                return Ok(bundle);
            }
            self.clear_pending_commit(group)?;
            let mut next = if size < goal {
                pad + (goal - size)
            } else {
                pad.saturating_sub(size - goal).max(FIRST_PAD)
            };
            let mut goal = goal;
            if tried.contains(&next) {
                // A length prefix step skips this bucket: take the next one.
                goal = crate::l2::next_bucket(goal).ok_or(MlsError::GroupOperation)?;
                next = pad + (goal - size.min(goal));
            }
            target = Some(goal);
            pad = next;
        }
        // Not reached for any size the tests cover. Padding is a privacy
        // measure, so it never blocks a membership change: the commit goes
        // with the first pad, off-bucket.
        stage(group, Some(FIRST_PAD))
    }

    /// Stages one commit that adds and removes no one and carries an update
    /// path (periodic self-update): this device's leaf gets a fresh HPKE key
    /// and every path secret from it to the root changes, which is what
    /// gives post-compromise security. The credential and signature key stay
    /// the same, so the safety number does not change. Like
    /// [`Self::stage_membership_commit`] it is not merged: the caller merges
    /// only after the server accepts it on this epoch, or clears it.
    ///
    /// No proposal goes in, not even a queued one, so the commit is exactly
    /// an update path. A commit that came out without one is cleared and
    /// refused rather than sent.
    pub fn stage_self_update(
        &self,
        group: &mut MlsGroup,
    ) -> Result<StagedCommitMessages, MlsError> {
        if group.pending_commit().is_some() {
            return Err(MlsError::InvalidState);
        }
        let epoch = group.epoch().as_u64();
        let id = group.group_id().as_slice().to_vec();
        let bundle = self.in_group(&id, || {
            group
                .commit_builder()
                .consume_proposal_store(false)
                .force_self_update(true)
                .load_psks(self.provider.storage())
                .map_err(|_| MlsError::GroupOperation)?
                .build(
                    self.provider.rand(),
                    self.provider.crypto(),
                    &self.signer,
                    |_| false,
                )
                .map_err(|_| MlsError::GroupOperation)?
                .stage_commit(&self.provider)
                .map_err(|_| MlsError::GroupOperation)
        })?;
        let path_only = group.pending_commit().is_some_and(|staged| {
            staged.queued_proposals().next().is_none() && staged.update_path_leaf_node().is_some()
        });
        let (commit, welcome, _) = bundle.into_messages();
        if !path_only || welcome.is_some() {
            let _ = self.in_group(&id, || {
                group
                    .clear_pending_commit(self.provider.storage())
                    .map_err(|_| MlsError::Storage)
            });
            return Err(MlsError::GroupOperation);
        }
        let commit = commit
            .tls_serialize_detached()
            .map_err(|_| MlsError::GroupOperation)?;
        Ok(StagedCommitMessages {
            commit,
            welcome: Vec::new(),
            epoch,
        })
    }

    /// Drops a staged commit the server did not accept.
    pub fn clear_pending_commit(&self, group: &mut MlsGroup) -> Result<(), MlsError> {
        let id = group.group_id().as_slice().to_vec();
        self.in_group(&id, || {
            group
                .clear_pending_commit(self.provider.storage())
                .map_err(|_| MlsError::Storage)
        })
    }

    pub fn has_pending_commit(&self, group: &MlsGroup) -> bool {
        group.pending_commit().is_some()
    }

    pub fn group_epoch(&self, group: &MlsGroup) -> u64 {
        group.epoch().as_u64()
    }

    pub fn merge_pending_commit(&self, group: &mut MlsGroup) -> Result<(), MlsError> {
        let id = group.group_id().as_slice().to_vec();
        self.held.forget(&id)?;
        self.in_group(&id, || {
            group
                .merge_pending_commit(&self.provider)
                .map_err(|_| MlsError::GroupOperation)
        })
    }

    /// C7 (ABI 13): merges this device's own staged commit and reports what
    /// it did, read from the staged commit itself. For a removal commit the
    /// exporter root is computed from `group.pending_commit()` before the
    /// merge. Fails with [`MlsError::InvalidState`], touching nothing, when
    /// no commit is staged: the caller cannot tell a no-op from a
    /// membership change then, so it is not guessed.
    pub fn merge_pending_commit_with_outcome(
        &self,
        group: &mut MlsGroup,
    ) -> Result<CommitOutcome, MlsError> {
        let id = group.group_id().as_slice().to_vec();
        if group.pending_commit().is_none() {
            return Err(MlsError::InvalidState);
        }
        self.held.forget(&id)?;
        self.in_group(&id, || {
            let staged = group.pending_commit().ok_or(MlsError::InvalidState)?;
            let own = LeafPair {
                account_id: self.account_id.clone(),
                device_id: self.device_id.clone(),
                signing_key: self.signing_public_key().to_vec(),
            };
            let outcome = self.commit_outcome(group.group_id().as_slice(), staged, own)?;
            group
                .merge_pending_commit(&self.provider)
                .map_err(|_| MlsError::GroupOperation)?;
            Ok(outcome)
        })
    }

    /// Builds and stages an update commit; the FFI caller merges it at once.
    /// The app never uses this path, because merging before the server
    /// accepts the commit can fork the group. Periodic updates go through
    /// [`Self::stage_self_update`].
    pub fn self_update(&self, group: &mut MlsGroup) -> Result<Vec<u8>, MlsError> {
        let id = group.group_id().as_slice().to_vec();
        let bundle = self.in_group(&id, || {
            group
                .self_update(&self.provider, &self.signer, LeafNodeParameters::default())
                .map_err(|_| MlsError::GroupOperation)
        })?;
        let (commit, _, _) = bundle.into_contents();
        commit
            .tls_serialize_detached()
            .map_err(|_| MlsError::GroupOperation)
    }

    pub fn remove_members(
        &self,
        group: &mut MlsGroup,
        members: &[LeafNodeIndex],
    ) -> Result<Vec<u8>, MlsError> {
        if members.is_empty() {
            return Err(MlsError::InvalidIdentity);
        }
        let id = group.group_id().as_slice().to_vec();
        let (commit, _, _) = self.in_group(&id, || {
            group
                .remove_members(&self.provider, &self.signer, members)
                .map_err(|_| MlsError::GroupOperation)
        })?;
        commit
            .tls_serialize_detached()
            .map_err(|_| MlsError::GroupOperation)
    }

    pub fn process_commit(&self, group: &mut MlsGroup, commit: &[u8]) -> Result<(), MlsError> {
        self.process_commit_with_outcome(group, commit).map(drop)
    }

    /// C7 (ABI 13): [`Self::process_commit`] that also reports what the
    /// commit did, from the staged commit itself and never from a server
    /// label. For a removal commit that leaves this device in the group,
    /// `root` is the exporter output of the epoch the commit produces,
    /// computed before the merge. A commit that removes this device returns
    /// `removed_any` and `removed_self` with no root, not an error.
    pub fn process_commit_with_outcome(
        &self,
        group: &mut MlsGroup,
        commit: &[u8],
    ) -> Result<CommitOutcome, MlsError> {
        let protocol_message = MlsMessageIn::tls_deserialize_exact(commit)
            .map_err(|_| MlsError::InvalidMessage)?
            .try_into_protocol_message()
            .map_err(|_| MlsError::InvalidMessage)?;
        let id = group.group_id().as_slice().to_vec();
        self.held.forget(&id)?;
        let outcome = self.in_group(&id, || {
            self.process_commit_in_scope(group, protocol_message)
        })?;
        // Own removal applied: the group can never be used again, so its
        // whole store goes now, past-epoch key pairs included (D70). A
        // later Welcome for this id is a fresh join.
        if !group.is_active() {
            self.provider.storage().drop_group(&id)?;
        }
        Ok(outcome)
    }

    /// What `staged` does, read from MLS itself (C7, decision 5). The
    /// exporter runs only for a removal commit that keeps this device, with
    /// the one label and context C7 uses, so no other exporter output
    /// leaves the core.
    fn commit_outcome(
        &self,
        group_id: &[u8],
        staged: &StagedCommit,
        committer: LeafPair,
    ) -> Result<CommitOutcome, MlsError> {
        let removed_any = staged.remove_proposals().next().is_some();
        let added_any = staged.add_proposals().next().is_some();
        let removed_self = staged.self_removed();
        let new_epoch = staged.epoch().as_u64();
        let root = if removed_any && !removed_self {
            let context =
                c7::exporter_context(group_id, new_epoch).map_err(|_| MlsError::InvalidIdentity)?;
            let secret = staged
                .export_secret(
                    self.provider.crypto(),
                    c7::EXPORTER_LABEL,
                    &context,
                    c7::KEY_BYTES,
                )
                .map_err(|_| MlsError::GroupOperation)?;
            let secret = tls_codec::SecretVLBytes::new(secret);
            if secret.as_slice().len() != c7::KEY_BYTES {
                return Err(MlsError::GroupOperation);
            }
            Some(secret)
        } else {
            None
        };
        let added = staged
            .add_proposals()
            .map(|proposal| {
                let leaf = proposal.add_proposal().key_package().leaf_node();
                LeafPair::from_credential(leaf.credential(), leaf.signature_key().as_slice())
            })
            .collect::<Result<Vec<_>, _>>()?;
        // Encode both buffers now: `commit_outcome` runs before the merge on
        // both paths, so a failure here leaves the group as it was.
        let added_triples: Vec<_> = added.iter().map(LeafPair::as_triple).collect();
        let added_pairs =
            crate::l1::encode_leaf_pairs(&added_triples).map_err(|_| MlsError::InvalidIdentity)?;
        let committer_pair = crate::l1::encode_leaf_pairs(&[committer.as_triple()])
            .map_err(|_| MlsError::InvalidIdentity)?;
        Ok(CommitOutcome {
            removed_any,
            added_any,
            removed_self,
            new_epoch,
            added_pairs,
            committer_pair,
            root,
        })
    }

    /// Drops a group and every record it holds. Only for a user's action
    /// (leaving or deleting a chat), never on a server's word: a server
    /// could otherwise clear an active group and plant a forked Welcome
    /// (docs/crypto.md, "Rejoining a conversation"). Returns whether the
    /// group was stored.
    pub fn delete_group(&self, group_id: &[u8]) -> Result<bool, MlsError> {
        if group_id.is_empty() || group_id.len() > MAX_ID_BYTES {
            return Err(MlsError::InvalidIdentity);
        }
        self.held.forget(group_id)?;
        self.provider.storage().drop_group(group_id)
    }

    /// Drops every key package whose `not_after` passed more than 24 hours
    /// before `now_unix_seconds` (D70). Returns how many went.
    pub fn prune_key_packages(&self, now_unix_seconds: u64) -> Result<usize, MlsError> {
        let storage = self.provider.storage();
        let mut removed = 0;
        for (id, not_after) in storage.key_package_expiries()? {
            if not_after.saturating_add(records::KEY_PACKAGE_GRACE_SECONDS) < now_unix_seconds
                && storage.drop_key_package(&id)?
            {
                removed += 1;
            }
        }
        Ok(removed)
    }

    /// The number of key packages this device holds.
    pub fn key_package_count(&self) -> Result<usize, MlsError> {
        self.provider.storage().key_package_count()
    }

    fn process_commit_in_scope(
        &self,
        group: &mut MlsGroup,
        protocol_message: ProtocolMessage,
    ) -> Result<CommitOutcome, MlsError> {
        let processed = group
            .process_message(&self.provider, protocol_message)
            .map_err(|_| MlsError::InvalidMessage)?;
        // Veritra commits come from members only. An external commit would
        // bring in a new leaf without an Add proposal to inspect.
        let Sender::Member(committer) = *processed.sender() else {
            return Err(MlsError::UnexpectedMessage);
        };
        let ProcessedMessageContent::StagedCommitMessage(staged_commit) = processed.into_content()
        else {
            return Err(MlsError::UnexpectedMessage);
        };
        // Inspect before merging: once merged, the leaves it brings in are
        // what decrypt() attributes messages to. The one-shot path refuses a
        // role-record proposal (C4): only the two-phase calls let Dart judge
        // one before it merges.
        inspect_commit(group, committer, &staged_commit, false)?;
        // The committer's pair, from the tree before the merge (an update
        // path cannot change it: `inspect_commit` keeps identity and key).
        let committer_member = group
            .member_at(committer)
            .ok_or(MlsError::InvalidIdentity)?;
        let committer_pair = LeafPair::from_credential(
            &committer_member.credential,
            &committer_member.signature_key,
        )?;
        // The exporter root comes out of the staged commit, before the merge
        // replaces the epoch secrets. A failed merge drops (and wipes) it.
        let outcome =
            self.commit_outcome(group.group_id().as_slice(), &staged_commit, committer_pair)?;
        group
            .merge_staged_commit(&self.provider, *staged_commit)
            .map_err(|_| MlsError::GroupOperation)?;
        Ok(outcome)
    }

    /// Every leaf carrying this account/device credential. A device is one
    /// logical member, so removing it removes all of them. Fails when there
    /// is none.
    pub fn member_indices(
        &self,
        group: &MlsGroup,
        account_id: &[u8],
        device_id: &[u8],
    ) -> Result<Vec<LeafNodeIndex>, MlsError> {
        let identity = encode_device_identity(account_id, device_id)?;
        let indices: Vec<_> = group
            .members()
            .filter(|member| member.credential.serialized_content() == identity)
            .map(|member| member.index)
            .collect();
        if indices.is_empty() {
            return Err(MlsError::InvalidIdentity);
        }
        Ok(indices)
    }

    /// C7 (ABI 13): the signature public key of the member device with this
    /// account and device id, read from the group's current tree. Fails when
    /// there is no such member, or when several leaves carry the identity
    /// with different keys (nothing is guessed).
    pub fn member_signature_key(
        &self,
        group: &MlsGroup,
        account_id: &[u8],
        device_id: &[u8],
    ) -> Result<Vec<u8>, MlsError> {
        let identity = encode_device_identity(account_id, device_id)?;
        let mut keys = group
            .members()
            .filter(|member| member.credential.serialized_content() == identity)
            .map(|member| member.signature_key);
        let first = keys.next().ok_or(MlsError::InvalidIdentity)?;
        if keys.any(|key| key != first) {
            return Err(MlsError::InvalidIdentity);
        }
        Ok(first)
    }

    /// C7 (ABI 13): signs `domain | message` with this device's credential
    /// key. `domain` must be one of [`c7::SIGN_DOMAINS`].
    /// L2-3 (ABI 26): signs a franking commitment for a sealed message with
    /// this device's MLS signing key, over this device's own identity
    /// (`crate::l2_sealed::frank_sig_input`). The caller names only the
    /// conversation and the 32-byte commitment, so no other bytes and no
    /// other identity can be signed through it.
    pub fn l2_frank_sign(
        &self,
        conversation_id: &[u8],
        commit: &[u8],
    ) -> Result<Vec<u8>, MlsError> {
        let input = crate::l2_sealed::frank_sig_input(
            conversation_id,
            &self.account_id,
            &self.device_id,
            commit,
        )
        .map_err(|_| MlsError::InvalidMessage)?;
        self.signer
            .sign(&input)
            .map_err(|_| MlsError::GroupOperation)
    }

    pub fn c7_sign(&self, domain: &[u8], message: &[u8]) -> Result<Vec<u8>, MlsError> {
        let input = c7::signing_input(domain, message).map_err(|_| MlsError::InvalidMessage)?;
        self.signer
            .sign(&input)
            .map_err(|_| MlsError::GroupOperation)
    }

    /// B6 (ABI 22): the media key `K(s,t)` of the call group's current epoch
    /// for the sender device (found by identity, so the app never guesses a
    /// leaf index across blank leaves) and stream slot `stream`. The exporter
    /// secret `E` stays here; only the derived key leaves.
    pub fn b6_media_key(
        &self,
        group: &MlsGroup,
        call_id: &[u8],
        sender_account_id: &[u8],
        sender_device_id: &[u8],
        stream: u8,
    ) -> Result<tls_codec::SecretVLBytes, MlsError> {
        let context = crate::b6::exporter_context(call_id, group.epoch().as_u64())
            .map_err(|_| MlsError::InvalidMessage)?;
        let identity = encode_device_identity(sender_account_id, sender_device_id)?;
        let mut leaves = group
            .members()
            .filter(|member| member.credential.serialized_content() == identity)
            .map(|member| member.index.u32());
        let leaf_index = leaves.next().ok_or(MlsError::InvalidIdentity)?;
        if leaves.next().is_some() {
            return Err(MlsError::InvalidIdentity);
        }
        let secret = tls_codec::SecretVLBytes::new(
            group
                .export_secret(
                    self.provider.crypto(),
                    crate::b6::EXPORTER_LABEL,
                    &context,
                    crate::b6::KEY_BYTES,
                )
                .map_err(|_| MlsError::GroupOperation)?,
        );
        crate::b6::sender_key(secret.as_slice(), leaf_index, stream).map_err(|error| match error {
            crate::b6::B6Error::InvalidInput => MlsError::InvalidMessage,
            crate::b6::B6Error::Crypto => MlsError::GroupOperation,
        })
    }

    /// The conversation's safety number (v2): the group id and every member
    /// device's credential and signature key. The epoch and encryption keys
    /// are left out, so routine commits keep the number; a device that joins,
    /// leaves or changes its signing key changes it.
    pub fn conversation_safety_number(
        &self,
        group: &MlsGroup,
    ) -> Result<DeviceLinkVerification, MlsError> {
        let members = group
            .members()
            .map(|member| {
                (
                    member.credential.serialized_content().to_vec(),
                    member.signature_key.clone(),
                )
            })
            .collect::<Vec<_>>();
        conversation_safety_number_v2(group.group_id().as_slice(), &members)
    }

    pub fn join_group(
        &self,
        expected_group_id: &[u8],
        welcome_bytes: &[u8],
    ) -> Result<MlsGroup, MlsError> {
        if expected_group_id.is_empty() || expected_group_id.len() > MAX_ID_BYTES {
            return Err(MlsError::InvalidIdentity);
        }
        let message = MlsMessageIn::tls_deserialize_exact(welcome_bytes)
            .map_err(|_| MlsError::InvalidMessage)?;
        let MlsMessageBodyIn::Welcome(welcome) = message.extract() else {
            return Err(MlsError::UnexpectedMessage);
        };
        // A device removed and later re-added still holds the old group
        // under this id. Only an inactive one (its own removal applied) may
        // go; an active one is refused here, before the key package is used.
        self.held.forget(expected_group_id)?;
        self.in_group(expected_group_id, || {
            self.join_group_in_scope(expected_group_id, welcome)
        })
    }

    fn join_group_in_scope(
        &self,
        expected_group_id: &[u8],
        welcome: Welcome,
    ) -> Result<MlsGroup, MlsError> {
        let group_id = GroupId::from_slice(expected_group_id);
        let stored =
            MlsGroup::load(self.provider.storage(), &group_id).map_err(|_| MlsError::Storage)?;
        if let Some(stored) = &stored {
            ensure_replaceable(stored)?;
        }
        self.ensure_welcome_key_package(&welcome)?;
        // Staging decrypts the Welcome (and consumes the key package) but
        // stores no group; into_group persists it, so every check runs first.
        let builder = StagedWelcome::build_from_welcome(
            &self.provider,
            group_create_config().join_config(),
            welcome,
        )
        .map_err(|_| MlsError::GroupOperation)?;
        let group_info = builder.processed_welcome().unverified_group_info();
        // L2-1: the GroupInfo's pad, if any, is zeros within the cap.
        if group_info.group_id() != &group_id
            || group_info.extensions().iter().any(crate::l2::malformed_pad)
        {
            return Err(MlsError::InvalidMessage);
        }
        // OpenMLS refuses to stage over a stored group unless told to.
        let builder = if stored.is_some() {
            builder.replace_old_group()
        } else {
            builder
        };
        let staged = builder.build().map_err(|_| MlsError::GroupOperation)?;
        if staged.group_context().group_id().as_slice() != expected_group_id {
            return Err(MlsError::InvalidMessage);
        }
        self.inspect_welcome(&staged)?;
        if let Some(mut stored) = stored {
            // into_group only writes, so the old group's leftovers (own leaf
            // nodes, proposal queue, epoch key pairs) are deleted first.
            stored
                .delete(self.provider.storage())
                .map_err(|_| MlsError::Storage)?;
        }
        staged
            .into_group(&self.provider)
            .map_err(|_| MlsError::GroupOperation)
    }

    /// D74: the Welcome must name a key package this device still holds,
    /// and that package must not have expired. Checked before anything is
    /// consumed; OpenMLS would refuse both anyway (its join verifies leaf
    /// lifetimes), but only as a generic failure that stops sync.
    fn ensure_welcome_key_package(&self, welcome: &Welcome) -> Result<(), MlsError> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| MlsError::InvalidState)?
            .as_secs();
        for secrets in welcome.secrets() {
            let bundle: Option<KeyPackageBundle> = self
                .provider
                .storage()
                .key_package(&secrets.new_member())
                .map_err(|_| MlsError::Storage)?;
            if let Some(bundle) = bundle {
                return if bundle.key_package().life_time().not_after() <= now {
                    Err(MlsError::KeyPackageUnavailable)
                } else {
                    Ok(())
                };
            }
        }
        Err(MlsError::KeyPackageUnavailable)
    }

    /// The structural checks a Welcome must pass before its group is stored:
    /// every leaf holds a well-formed, unique device identity; this device's
    /// leaf carries its own identity and signing key; the sender is another
    /// leaf in the tree. Which members and inviters to expect needs a trust
    /// anchor (L1) and is not decided here.
    fn inspect_welcome(&self, staged: &StagedWelcome) -> Result<(), MlsError> {
        let refused = MlsError::InvalidIdentity;
        let identities = staged
            .members()
            .map(|member| basic_identity(&member.credential))
            .collect::<Result<Vec<_>, _>>()?;
        ensure_added_identities_unique(&[], &identities)?;
        let own = staged.own_leaf_node().ok_or(refused)?;
        if basic_identity(own.credential())?
            != encode_device_identity(&self.account_id, &self.device_id)?
            || own.signature_key().as_slice() != self.signing_public_key()
        {
            return Err(refused);
        }
        if staged.welcome_sender_index() == staged.own_leaf_index()
            || staged.welcome_sender().is_err()
        {
            return Err(refused);
        }
        // C4: a record, when present, is well-formed in size and required.
        c4::check_joined_context(staged.group_context().extensions())
    }

    pub fn encrypt(&self, group: &mut MlsGroup, plaintext: &[u8]) -> Result<Vec<u8>, MlsError> {
        let id = group.group_id().as_slice().to_vec();
        self.in_group(&id, || {
            group
                .create_message(&self.provider, &self.signer, plaintext)
                .map_err(|_| MlsError::GroupOperation)
        })?
        .tls_serialize_detached()
        .map_err(|_| MlsError::GroupOperation)
    }

    /// Decrypts one application message and binds it to its sender.
    ///
    /// The server labels every envelope with a sender account and device, but
    /// the server is untrusted. The MLS credential inside the authenticated
    /// message is the only trustworthy sender, so it must match the claimed
    /// one; otherwise a group member (or the server) could present a message
    /// as coming from someone else.
    pub fn decrypt(
        &self,
        group: &mut MlsGroup,
        ciphertext: &[u8],
        expected_sender_account: &[u8],
        expected_sender_device: &[u8],
    ) -> Result<Vec<u8>, MlsError> {
        self.decrypt_with_epoch(
            group,
            ciphertext,
            expected_sender_account,
            expected_sender_device,
        )
        .map(|(plaintext, _)| plaintext)
    }

    /// C7 (ABI 13): [`Self::decrypt`] that also returns the epoch the
    /// message was encrypted in, from MLS itself (a record's signed `epoch`
    /// and a post's freshness are judged against it).
    pub fn decrypt_with_epoch(
        &self,
        group: &mut MlsGroup,
        ciphertext: &[u8],
        expected_sender_account: &[u8],
        expected_sender_device: &[u8],
    ) -> Result<(Vec<u8>, u64), MlsError> {
        let expected_identity =
            encode_device_identity(expected_sender_account, expected_sender_device)?;
        let protocol_message = MlsMessageIn::tls_deserialize_exact(ciphertext)
            .map_err(|_| MlsError::InvalidMessage)?
            .try_into_protocol_message()
            .map_err(|_| MlsError::InvalidMessage)?;
        let id = group.group_id().as_slice().to_vec();
        let processed = self.in_group(&id, || {
            group
                .process_message(&self.provider, protocol_message)
                .map_err(|_| MlsError::InvalidMessage)
        })?;
        let message_epoch = processed.epoch().as_u64();
        let sender_matches = processed.credential().serialized_content() == expected_identity;
        // Two past epochs stay decryptable (I51), so a device removed at
        // epoch N could keep writing in epoch N by never applying its
        // removal. A past-epoch message counts only while its sender is
        // still a member. Q-003: a genuine late message from a removed
        // device is dropped too; the receiver cannot tell the two apart.
        // Past-epoch signature keys are not exposed, so this compares the
        // identity only (L1 binds identities to keys).
        let removed = processed.epoch() != group.epoch()
            && !group
                .members()
                .any(|member| member.credential.serialized_content() == expected_identity);
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) if !sender_matches => {
                wipe(message.into_bytes());
                Err(MlsError::SenderMismatch)
            }
            ProcessedMessageContent::ApplicationMessage(message) if removed => {
                wipe(message.into_bytes());
                Err(MlsError::SenderRemoved)
            }
            ProcessedMessageContent::ApplicationMessage(message) => {
                Ok((message.into_bytes(), message_epoch))
            }
            _ => Err(MlsError::UnexpectedMessage),
        }
    }
}

/// Plaintext, sender account id and sender device id of a sealed message.
pub type SealedMessage = (Vec<u8>, Vec<u8>, Vec<u8>);

impl MlsDevice {
    /// L2-3 (ABI 23): decrypts an application message whose sender the
    /// transport does not name (sealed sender) and returns the sender that
    /// MLS authenticated, `(plaintext, account_id, device_id)`. The binding
    /// of D25 moves from "the envelope says, MLS confirms" to "MLS says":
    /// nothing the server sends is compared, so a forged outer sender has
    /// no effect. A past-epoch message counts only while its sender is
    /// still a member, as in [`Self::decrypt_with_epoch`]. Not used by the
    /// app yet; [`Self::decrypt`] keeps its D25 check unchanged.
    pub fn decrypt_sealed(
        &self,
        group: &mut MlsGroup,
        ciphertext: &[u8],
    ) -> Result<SealedMessage, MlsError> {
        let protocol_message = MlsMessageIn::tls_deserialize_exact(ciphertext)
            .map_err(|_| MlsError::InvalidMessage)?
            .try_into_protocol_message()
            .map_err(|_| MlsError::InvalidMessage)?;
        let id = group.group_id().as_slice().to_vec();
        let processed = self.in_group(&id, || {
            group
                .process_message(&self.provider, protocol_message)
                .map_err(|_| MlsError::InvalidMessage)
        })?;
        let identity = processed.credential().serialized_content().to_vec();
        let removed = processed.epoch() != group.epoch()
            && !group
                .members()
                .any(|member| member.credential.serialized_content() == identity.as_slice());
        let content = processed.into_content();
        let sender = decode_device_identity(&identity)
            .map(|(account, device)| (account.to_vec(), device.to_vec()));
        match content {
            ProcessedMessageContent::ApplicationMessage(message) => match sender {
                _ if removed => {
                    wipe(message.into_bytes());
                    Err(MlsError::SenderRemoved)
                }
                Ok((account, device)) => Ok((message.into_bytes(), account, device)),
                Err(_) => {
                    wipe(message.into_bytes());
                    Err(MlsError::SenderMismatch)
                }
            },
            _ => Err(MlsError::UnexpectedMessage),
        }
    }
}

// The v2 link derivation (`veritra-device-link-v2`) was retired in ABI 18
// (L1-3): device links use `mls::link_v3` with a commitment to the
// existing device's random before the new device's values are known.

/// Fixed 128-bit input; only the one-way locator is sent to the server.
pub fn device_link_locator(secret: &[u8]) -> Result<Vec<u8>, MlsError> {
    if secret.len() != 16 {
        return Err(MlsError::InvalidIdentity);
    }
    Ok(Sha256::digest([b"veritra-link-locator-v2".as_slice(), secret].concat()).to_vec())
}

/// Number of digits in a conversation safety number: twelve groups of five,
/// about 199 bits, so a device key cannot be ground to match it.
pub const CONVERSATION_SAFETY_DIGITS: usize = 60;

/// Safety number v2 from the group id and (credential, signature key) pairs.
/// Members are sorted so every device derives the same value; a repeated
/// member is refused rather than hashed.
fn conversation_safety_number_v2(
    group_id: &[u8],
    members: &[(Vec<u8>, Vec<u8>)],
) -> Result<DeviceLinkVerification, MlsError> {
    let mut entries = members
        .iter()
        .map(|(credential, signature_key)| {
            let mut value = Vec::new();
            append_transcript_field(&mut value, credential)?;
            append_transcript_field(&mut value, signature_key)?;
            Ok(value)
        })
        .collect::<Result<Vec<_>, MlsError>>()?;
    entries.sort();
    if entries.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(MlsError::InvalidState);
    }
    let count = u32::try_from(entries.len()).map_err(|_| MlsError::InvalidState)?;
    let mut transcript = Vec::new();
    append_transcript_field(&mut transcript, b"veritra-conversation-safety-v2")?;
    append_transcript_field(&mut transcript, group_id)?;
    transcript.extend_from_slice(&count.to_be_bytes());
    for entry in entries {
        append_transcript_field(&mut transcript, &entry)?;
    }
    let transcript_hash = Sha256::digest(&transcript).to_vec();
    let mut digit_input = b"veritra-safety-digits-v2".to_vec();
    digit_input.extend_from_slice(&transcript_hash);
    let digit_bytes = Sha512::digest(&digit_input);
    let mut sas = String::with_capacity(CONVERSATION_SAFETY_DIGITS);
    for chunk in digit_bytes[..60].chunks_exact(5) {
        let mut value = 0u64;
        for byte in chunk {
            value = (value << 8) | u64::from(*byte);
        }
        sas.push_str(&format!("{:05}", value % 100_000));
    }
    Ok(DeviceLinkVerification {
        transcript_hash,
        sas,
        claim_tag: Vec::new(),
        approval_tag: Vec::new(),
        sas_bytes: Vec::new(),
    })
}

fn append_transcript_field(out: &mut Vec<u8>, value: &[u8]) -> Result<(), MlsError> {
    let length = u16::try_from(value.len()).map_err(|_| MlsError::InvalidIdentity)?;
    out.extend_from_slice(&length.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

#[derive(Debug, Eq, PartialEq)]
pub struct AddMemberMessages {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
}

/// One device to add in a staged membership commit.
#[derive(Clone, Copy, Debug)]
pub struct MemberAdd<'a> {
    pub key_package: &'a [u8],
    pub account_id: &'a [u8],
    pub device_id: &'a [u8],
}

/// One device identity in the group.
#[derive(Clone, Copy, Debug)]
pub struct MemberIdentity<'a> {
    pub account_id: &'a [u8],
    pub device_id: &'a [u8],
}

/// A staged, unmerged commit. `welcome` is empty when nothing was added.
/// `epoch` is the group epoch the commit was built on.
#[derive(Debug, Eq, PartialEq)]
pub struct StagedCommitMessages {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
    pub epoch: u64,
}

#[derive(Debug, Eq, PartialEq)]
pub struct EnrollmentCredential {
    pub key_package: Vec<u8>,
    pub signing_public_key: Vec<u8>,
    pub challenge_signature: Vec<u8>,
}

fn group_create_config() -> MlsGroupCreateConfig {
    group_create_config_with(None)
}

/// The group configuration, with `extensions` as the initial context
/// extensions of a record group (C4). The creator's leaf always advertises
/// the role extension, as every key package does.
fn group_create_config_with(extensions: Option<Extensions<GroupContext>>) -> MlsGroupCreateConfig {
    let builder = MlsGroupCreateConfig::builder()
        .capabilities(c4::leaf_capabilities())
        .padding_size(PADDING_BYTES)
        .use_ratchet_tree_extension(true)
        .ciphersuite(CIPHERSUITE)
        // After a membership change, a message sent in the previous epoch
        // can still arrive after the commit (card I51). Two past epochs are
        // kept for decryption only.
        .max_past_epochs(2);
    match extensions {
        Some(extensions) => builder.with_group_context_extensions(extensions),
        None => builder,
    }
    .build()
}

/// Drops plaintext that is not handed out through a non-elidable wipe.
fn wipe(bytes: Vec<u8>) {
    drop(tls_codec::SecretVLBytes::new(bytes));
}

fn encode_device_identity(account_id: &[u8], device_id: &[u8]) -> Result<Vec<u8>, MlsError> {
    if account_id.is_empty()
        || device_id.is_empty()
        || account_id.len() > MAX_ID_BYTES
        || device_id.len() > MAX_ID_BYTES
    {
        return Err(MlsError::InvalidIdentity);
    }
    let mut identity = Vec::with_capacity(5 + account_id.len() + device_id.len());
    identity.push(CREDENTIAL_FORMAT_VERSION);
    identity.extend_from_slice(&(account_id.len() as u16).to_be_bytes());
    identity.extend_from_slice(account_id);
    identity.extend_from_slice(&(device_id.len() as u16).to_be_bytes());
    identity.extend_from_slice(device_id);
    Ok(identity)
}

/// Splits a credential identity written by [`encode_device_identity`] into
/// its account and device IDs. Anything else is refused.
fn decode_device_identity(identity: &[u8]) -> Result<(&[u8], &[u8]), MlsError> {
    let invalid = MlsError::InvalidIdentity;
    let (&version, rest) = identity.split_first().ok_or(invalid)?;
    if version != CREDENTIAL_FORMAT_VERSION {
        return Err(invalid);
    }
    let field = |input: &[u8]| -> Result<usize, MlsError> {
        let length = input.get(..2).ok_or(invalid)?;
        let length = usize::from(u16::from_be_bytes([length[0], length[1]]));
        if length == 0 || length > MAX_ID_BYTES || input.len() < 2 + length {
            return Err(invalid);
        }
        Ok(2 + length)
    };
    let end = field(rest)?;
    let (account, rest) = (&rest[2..end], &rest[end..]);
    let end = field(rest)?;
    if end != rest.len() {
        return Err(invalid);
    }
    Ok((account, &rest[2..end]))
}

/// L2-1: refuses a key package whose pad extension is malformed.
fn check_key_package_pad(key_package: &KeyPackage) -> Result<(), MlsError> {
    if key_package
        .extensions()
        .iter()
        .any(crate::l2::malformed_pad)
    {
        return Err(MlsError::InvalidKeyPackage);
    }
    Ok(())
}

/// The structural checks a remote commit must pass before it is merged.
/// Who may commit, and whether an identity really belongs to its signing
/// key, needs a trust anchor (L1) and is not decided here.
///
/// - Only Add, Remove and Update proposals: Veritra sends nothing else.
///   With `allow_record` (C4, ABI 20: the two-phase calls only) also at
///   most one GroupContextExtensions proposal, by value, that rewrites the
///   role record and nothing else (`c4::check_record_proposal`).
/// - Every credential it brings in is a Basic credential holding a
///   well-formed device identity.
/// - An added identity appears once in the roster the commit produces.
/// - An update (proposal or update path) keeps the leaf's identity.
fn inspect_commit(
    group: &MlsGroup,
    committer: LeafNodeIndex,
    staged: &StagedCommit,
    allow_record: bool,
) -> Result<(), MlsError> {
    let refused = MlsError::InvalidIdentity;
    let mut records = 0usize;
    for proposal in staged.queued_proposals() {
        match proposal.proposal() {
            Proposal::Add(_) | Proposal::Remove(_) | Proposal::Update(_) => {}
            Proposal::GroupContextExtensions(extensions) if allow_record => {
                records += 1;
                if records > 1
                    || proposal.proposal_or_ref_type() != ProposalOrRefType::Proposal
                    || *proposal.sender() != Sender::Member(committer)
                {
                    return Err(MlsError::UnexpectedMessage);
                }
                c4::check_record_proposal(group.extensions(), extensions.extensions())?;
            }
            _ => return Err(MlsError::UnexpectedMessage),
        }
    }
    let removed: Vec<_> = staged
        .remove_proposals()
        .map(|proposal| proposal.remove_proposal().removed())
        .collect();
    let added = staged
        .add_proposals()
        .map(|proposal| {
            basic_identity(
                proposal
                    .add_proposal()
                    .key_package()
                    .leaf_node()
                    .credential(),
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    ensure_added_identities_unique(&roster_identities(group, &removed), &added)?;
    // L2-1: an added key package's pad, if any, is zeros within the cap.
    for proposal in staged.add_proposals() {
        check_key_package_pad(proposal.add_proposal().key_package())?;
    }

    // C7 (decision 8): credential keys never change in place. An update
    // keeps the identity and the signature key; a changed key is only a
    // replacement (remove and add), which rekeys.
    let keeps_identity = |leaf: LeafNodeIndex, node: &LeafNode| {
        let current = group.member_at(leaf).ok_or(refused)?;
        if basic_identity(node.credential())? != current.credential.serialized_content()
            || node.signature_key().as_slice() != current.signature_key.as_slice()
        {
            return Err(refused);
        }
        Ok(())
    };
    for update in staged.update_proposals() {
        let Sender::Member(leaf) = *update.sender() else {
            return Err(refused);
        };
        keeps_identity(leaf, update.update_proposal().leaf_node())?;
    }
    if let Some(leaf_node) = staged.update_path_leaf_node() {
        keeps_identity(committer, leaf_node)?;
    }
    Ok(())
}

/// The authenticated data of a serialized PrivateMessage commit.
fn commit_aad(commit: &[u8]) -> Result<Vec<u8>, MlsError> {
    match MlsMessageIn::tls_deserialize_exact(commit)
        .map_err(|_| MlsError::GroupOperation)?
        .try_into_protocol_message()
        .map_err(|_| MlsError::GroupOperation)?
    {
        ProtocolMessage::PrivateMessage(message) => Ok(message.aad().to_vec()),
        // Veritra's wire policy is pure ciphertext, so no commit is public;
        // were one, the comparison below would see an empty AAD.
        ProtocolMessage::PublicMessage(_) => Ok(Vec::new()),
    }
}

/// The device identity inside a Basic credential, checked for format.
fn basic_identity(credential: &Credential) -> Result<Vec<u8>, MlsError> {
    if credential.credential_type() != CredentialType::Basic {
        return Err(MlsError::InvalidIdentity);
    }
    let identity = credential.serialized_content();
    decode_device_identity(identity)?;
    Ok(identity.to_vec())
}

/// Whether a verified Welcome may replace the group this device already
/// stores under the same id (a re-add after a removal).
///
/// Only an inactive group goes: this device applied its own removal, holds
/// no live group under the id, and the Welcome is taken as a fresh join
/// (with the fresh-join trust of the L1 gap). An active group is the one
/// this device still believes it is in, and it is never replaced. A Welcome
/// cannot prove the device was removed: a malicious server with any member,
/// even a removed one, could otherwise make the device delete its real
/// group for a fork at an epoch of their choosing, which withholding events
/// alone cannot do. A device removed while offline must first be given its
/// removal commit.
fn ensure_replaceable(stored: &MlsGroup) -> Result<(), MlsError> {
    if stored.is_active() {
        return Err(MlsError::GroupOperation);
    }
    Ok(())
}

/// Identities of the current members, leaving out the `removed` leaves.
fn roster_identities(group: &MlsGroup, removed: &[LeafNodeIndex]) -> Vec<Vec<u8>> {
    group
        .members()
        .filter(|member| !removed.contains(&member.index))
        .map(|member| member.credential.serialized_content().to_vec())
        .collect()
}

/// Each added identity must be well-formed and appear once in the roster a
/// change produces: the members that remain plus everything added. Only the
/// additions are judged, so a group that already holds a duplicate can still
/// remove it.
fn ensure_added_identities_unique(
    remaining: &[Vec<u8>],
    added: &[Vec<u8>],
) -> Result<(), MlsError> {
    for (position, identity) in added.iter().enumerate() {
        decode_device_identity(identity)?;
        if remaining.contains(identity) || added[..position].contains(identity) {
            return Err(MlsError::InvalidIdentity);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_devices_exchange_authenticated_application_messages() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let bob_key_package = bob.create_key_package().unwrap();

        let mut alice_group = alice.create_group(b"conv_test").unwrap();
        let add = alice
            .add_member(&mut alice_group, &bob_key_package, b"acct_bob", b"dev_bob")
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let mut bob_group = bob.join_group(b"conv_test", &add.welcome).unwrap();

        let alice_ciphertext = alice.encrypt(&mut alice_group, b"alice payload").unwrap();
        assert_ne!(alice_ciphertext, b"alice payload");
        assert_eq!(
            bob.decrypt(
                &mut bob_group,
                &alice_ciphertext,
                b"acct_alice",
                b"dev_alice"
            )
            .unwrap(),
            b"alice payload"
        );

        let bob_ciphertext = bob.encrypt(&mut bob_group, b"bob payload").unwrap();
        assert_ne!(bob_ciphertext, b"bob payload");
        assert_eq!(
            alice
                .decrypt(&mut alice_group, &bob_ciphertext, b"acct_bob", b"dev_bob")
                .unwrap(),
            b"bob payload"
        );
    }

    #[test]
    fn staged_commit_adds_several_devices_with_one_welcome() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let bob_phone = MlsDevice::new(b"acct_bob", b"dev_bob_phone").unwrap();
        let bob_kp = bob.create_key_package().unwrap();
        let phone_kp = bob_phone.create_key_package().unwrap();
        let mut alice_group = alice.create_group(b"conv_multi").unwrap();

        let staged = alice
            .stage_membership_commit(
                &mut alice_group,
                &[
                    MemberAdd {
                        key_package: &bob_kp,
                        account_id: b"acct_bob",
                        device_id: b"dev_bob",
                    },
                    MemberAdd {
                        key_package: &phone_kp,
                        account_id: b"acct_bob",
                        device_id: b"dev_bob_phone",
                    },
                ],
                &[],
            )
            .unwrap();
        assert_eq!(staged.epoch, 0);
        assert!(!staged.welcome.is_empty());
        assert!(alice.has_pending_commit(&alice_group));
        // Not merged yet: the epoch has not moved.
        assert_eq!(alice.group_epoch(&alice_group), 0);
        // A second change cannot be staged on top of the first.
        assert_eq!(
            alice.stage_membership_commit(
                &mut alice_group,
                &[],
                &[MemberIdentity {
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                }],
            ),
            Err(MlsError::InvalidState)
        );

        alice.merge_pending_commit(&mut alice_group).unwrap();
        assert_eq!(alice.group_epoch(&alice_group), 1);
        let mut bob_group = bob.join_group(b"conv_multi", &staged.welcome).unwrap();
        let mut phone_group = bob_phone
            .join_group(b"conv_multi", &staged.welcome)
            .unwrap();
        let hello = alice.encrypt(&mut alice_group, b"hello both").unwrap();
        assert_eq!(
            bob.decrypt(&mut bob_group, &hello, b"acct_alice", b"dev_alice")
                .unwrap(),
            b"hello both"
        );
        assert_eq!(
            bob_phone
                .decrypt(&mut phone_group, &hello, b"acct_alice", b"dev_alice")
                .unwrap(),
            b"hello both"
        );

        // A removal is one more staged commit that the others process.
        let removal = alice
            .stage_membership_commit(
                &mut alice_group,
                &[],
                &[MemberIdentity {
                    account_id: b"acct_bob",
                    device_id: b"dev_bob_phone",
                }],
            )
            .unwrap();
        assert!(removal.welcome.is_empty());
        assert_eq!(removal.epoch, 1);
        alice.merge_pending_commit(&mut alice_group).unwrap();
        bob.process_commit(&mut bob_group, &removal.commit).unwrap();
        let after = alice.encrypt(&mut alice_group, b"without phone").unwrap();
        assert_eq!(
            bob.decrypt(&mut bob_group, &after, b"acct_alice", b"dev_alice")
                .unwrap(),
            b"without phone"
        );
    }

    /// Parses a device's own key package, so a test can add it through
    /// OpenMLS directly and bypass this wrapper's checks.
    /// Runs a direct OpenMLS call on `group` inside its storage scope, as
    /// every `MlsDevice` method does (D70).
    fn in_scope<T>(
        device: &MlsDevice,
        group: &mut MlsGroup,
        call: impl FnOnce(&mut MlsGroup) -> T,
    ) -> T {
        let id = group.group_id().as_slice().to_vec();
        let mut out = None;
        device
            .in_group(&id, || {
                out = Some(call(group));
                Ok(())
            })
            .unwrap();
        out.unwrap()
    }

    fn raw_key_package(device: &MlsDevice) -> KeyPackage {
        KeyPackageIn::tls_deserialize_exact(device.create_key_package().unwrap())
            .unwrap()
            .validate(device.provider.crypto(), ProtocolVersion::Mls10)
            .unwrap()
    }

    fn identities(group: &MlsGroup) -> Vec<Vec<u8>> {
        let mut all: Vec<_> = group
            .members()
            .map(|member| member.credential.serialized_content().to_vec())
            .collect();
        all.sort();
        all
    }

    #[test]
    fn adding_an_identity_twice_is_refused() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        // A second key with the same account/device credential.
        let twin = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let mut group = alice.create_group(b"conv_dup").unwrap();
        alice
            .add_member(
                &mut group,
                &bob.create_key_package().unwrap(),
                b"acct_bob",
                b"dev_bob",
            )
            .unwrap();
        alice.merge_pending_commit(&mut group).unwrap();

        // Already in the roster.
        let twin_kp = twin.create_key_package().unwrap();
        assert_eq!(
            alice.add_member(&mut group, &twin_kp, b"acct_bob", b"dev_bob"),
            Err(MlsError::InvalidIdentity)
        );
        assert_eq!(
            alice.stage_membership_commit(
                &mut group,
                &[MemberAdd {
                    key_package: &twin_kp,
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                }],
                &[],
            ),
            Err(MlsError::InvalidIdentity)
        );
        // Repeated within one batch.
        let carol = MlsDevice::new(b"acct_carol", b"dev_carol").unwrap();
        let carol_twin = MlsDevice::new(b"acct_carol", b"dev_carol").unwrap();
        let (carol_kp, carol_twin_kp) = (
            carol.create_key_package().unwrap(),
            carol_twin.create_key_package().unwrap(),
        );
        assert_eq!(
            alice.stage_membership_commit(
                &mut group,
                &[
                    MemberAdd {
                        key_package: &carol_kp,
                        account_id: b"acct_carol",
                        device_id: b"dev_carol",
                    },
                    MemberAdd {
                        key_package: &carol_twin_kp,
                        account_id: b"acct_carol",
                        device_id: b"dev_carol",
                    },
                ],
                &[],
            ),
            Err(MlsError::InvalidIdentity)
        );
        assert!(!alice.has_pending_commit(&group));
        // Replacing a device in one commit (remove, then add the same
        // identity with a new key) leaves one leaf, so it is allowed.
        alice
            .stage_membership_commit(
                &mut group,
                &[MemberAdd {
                    key_package: &twin_kp,
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                }],
                &[MemberIdentity {
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                }],
            )
            .unwrap();
        alice.merge_pending_commit(&mut group).unwrap();
        assert_eq!(group.members().count(), 2);
    }

    #[test]
    fn device_identities_decode_exactly() {
        let identity = encode_device_identity(b"acct_a", b"dev_a").unwrap();
        assert_eq!(
            decode_device_identity(&identity),
            Ok((b"acct_a".as_slice(), b"dev_a".as_slice()))
        );
        let mut trailing = identity.clone();
        trailing.push(0);
        let mut version = identity.clone();
        version[0] = 2;
        for bad in [
            &[][..],
            &identity[..identity.len() - 1],
            &trailing,
            &version,
            &[1, 0, 0, 0, 1, b'd'],
            &[1, 0, 1, b'a', 0, 0],
            b"not an identity",
        ] {
            assert_eq!(decode_device_identity(bad), Err(MlsError::InvalidIdentity));
        }
    }

    #[test]
    fn removing_a_device_removes_every_leaf_with_its_identity() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let twin = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let carol = MlsDevice::new(b"acct_carol", b"dev_carol").unwrap();
        let mut group = alice.create_group(b"conv_twins").unwrap();
        // Duplicates can only come in through another client (or a test
        // that calls OpenMLS directly).
        in_scope(&alice, &mut group, |g| {
            g.add_members(
                &alice.provider,
                &alice.signer,
                &[
                    raw_key_package(&bob),
                    raw_key_package(&twin),
                    raw_key_package(&carol),
                ],
            )
        })
        .unwrap();
        alice.merge_pending_commit(&mut group).unwrap();
        assert_eq!(group.members().count(), 4);

        let staged = alice
            .stage_membership_commit(
                &mut group,
                &[],
                &[MemberIdentity {
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                }],
            )
            .unwrap();
        assert!(staged.welcome.is_empty());
        alice.merge_pending_commit(&mut group).unwrap();
        let bob_identity = encode_device_identity(b"acct_bob", b"dev_bob").unwrap();
        assert!(!identities(&group).contains(&bob_identity));
        assert_eq!(group.members().count(), 2);

        // The single-device FFI path removes every leaf too.
        let mut group = alice.create_group(b"conv_twins_ffi").unwrap();
        in_scope(&alice, &mut group, |g| {
            g.add_members(
                &alice.provider,
                &alice.signer,
                &[raw_key_package(&bob), raw_key_package(&twin)],
            )
        })
        .unwrap();
        alice.merge_pending_commit(&mut group).unwrap();
        let indices = alice
            .member_indices(&group, b"acct_bob", b"dev_bob")
            .unwrap();
        assert_eq!(indices.len(), 2);
        alice.remove_members(&mut group, &indices).unwrap();
        alice.merge_pending_commit(&mut group).unwrap();
        assert_eq!(group.members().count(), 1);
        assert_eq!(
            alice.member_indices(&group, b"acct_bob", b"dev_bob"),
            Err(MlsError::InvalidIdentity)
        );
    }

    /// A key package whose credential carries an arbitrary identity, signed
    /// by a fresh key: what a hostile client or server can hand out.
    fn forged_key_package(identity: &[u8]) -> KeyPackage {
        let forger = MlsDevice::new(b"acct_forger", b"dev_forger").unwrap();
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.to_vec()).into(),
            signature_key: forger.signer.public().into(),
        };
        KeyPackage::builder()
            .build(CIPHERSUITE, &forger.provider, &forger.signer, credential)
            .unwrap()
            .key_package()
            .clone()
    }

    #[test]
    fn the_sender_runs_the_receivers_credential_check() {
        // Same identity bytes, but not a Basic credential: receivers refuse
        // it (basic_identity), so the sender runs that check too. OpenMLS
        // already refused this one later (GroupOperation, unsupported
        // credential type); now both sides run the same check first.
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let other = CredentialType::Other(0xF000);
        let credential = CredentialWithKey {
            credential: Credential::new(
                other,
                encode_device_identity(b"acct_bob", b"dev_bob").unwrap(),
            ),
            signature_key: bob.signer.public().into(),
        };
        let package = KeyPackage::builder()
            .leaf_node_capabilities(Capabilities::new(
                None,
                None,
                None,
                None,
                Some(&[CredentialType::Basic, other]),
            ))
            .build(CIPHERSUITE, &bob.provider, &bob.signer, credential)
            .unwrap()
            .key_package()
            .tls_serialize_detached()
            .unwrap();
        let mut group = alice.create_group(b"conv_other_credential").unwrap();
        assert!(matches!(
            alice.add_member(&mut group, &package, b"acct_bob", b"dev_bob"),
            Err(MlsError::InvalidKeyPackage)
        ));
        assert!(matches!(
            alice.stage_membership_commit(
                &mut group,
                &[MemberAdd {
                    key_package: &package,
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                }],
                &[],
            ),
            Err(MlsError::InvalidKeyPackage)
        ));
        assert!(group.pending_commit().is_none());
    }

    /// Alice, Bob and Carol in one group at epoch 1.
    fn three_members(group_id: &[u8]) -> ([MlsDevice; 3], [MlsGroup; 3]) {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let carol = MlsDevice::new(b"acct_carol", b"dev_carol").unwrap();
        let mut alice_group = alice.create_group(group_id).unwrap();
        let (bob_kp, carol_kp) = (
            bob.create_key_package().unwrap(),
            carol.create_key_package().unwrap(),
        );
        let staged = alice
            .stage_membership_commit(
                &mut alice_group,
                &[
                    MemberAdd {
                        key_package: &bob_kp,
                        account_id: b"acct_bob",
                        device_id: b"dev_bob",
                    },
                    MemberAdd {
                        key_package: &carol_kp,
                        account_id: b"acct_carol",
                        device_id: b"dev_carol",
                    },
                ],
                &[],
            )
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let bob_group = bob.join_group(group_id, &staged.welcome).unwrap();
        let carol_group = carol.join_group(group_id, &staged.welcome).unwrap();
        ([alice, bob, carol], [alice_group, bob_group, carol_group])
    }

    /// Alice refuses `commit`; her stored group keeps its epoch, and a valid
    /// commit Bob makes afterwards on the same epoch still applies.
    fn assert_refused_then_recovers(
        devices: &[MlsDevice; 3],
        groups: &mut [MlsGroup; 3],
        group_id: &[u8],
        commit: &[u8],
    ) {
        let [alice, bob, _] = devices;
        let [alice_group, bob_group, _] = groups;
        let epoch = alice.group_epoch(alice_group);
        assert_eq!(
            alice.process_commit(alice_group, commit),
            Err(MlsError::InvalidIdentity)
        );
        assert_eq!(alice.group_epoch(alice_group), epoch);
        let mut stored = alice.load_group(group_id).unwrap();
        assert_eq!(alice.group_epoch(&stored), epoch);
        // Bob's refused commit is dropped and he commits again.
        bob.clear_pending_commit(bob_group).unwrap();
        let update = bob.self_update(bob_group).unwrap();
        bob.merge_pending_commit(bob_group).unwrap();
        alice.process_commit(&mut stored, &update).unwrap();
        assert_eq!(alice.group_epoch(&stored), epoch + 1);
        let message = bob.encrypt(bob_group, b"after").unwrap();
        assert_eq!(
            alice
                .decrypt(&mut stored, &message, b"acct_bob", b"dev_bob")
                .unwrap(),
            b"after"
        );
        *alice_group = stored;
    }

    #[test]
    fn a_commit_adding_a_malformed_identity_is_refused() {
        let (devices, mut groups) = three_members(b"conv_bad_add");
        let commit = {
            let [_, bob, _] = &devices;
            let (commit, _, _) = in_scope(bob, &mut groups[1], |g| {
                g.add_members(
                    &bob.provider,
                    &bob.signer,
                    &[forged_key_package(b"garbage")],
                )
            })
            .unwrap();
            commit.tls_serialize_detached().unwrap()
        };
        assert_refused_then_recovers(&devices, &mut groups, b"conv_bad_add", &commit);
    }

    #[test]
    fn a_commit_adding_an_identity_already_present_is_refused() {
        let (devices, mut groups) = three_members(b"conv_twin_add");
        let carol_identity = encode_device_identity(b"acct_carol", b"dev_carol").unwrap();
        let commit = {
            let [_, bob, _] = &devices;
            let (commit, _, _) = in_scope(bob, &mut groups[1], |g| {
                g.add_members(
                    &bob.provider,
                    &bob.signer,
                    &[forged_key_package(&carol_identity)],
                )
            })
            .unwrap();
            commit.tls_serialize_detached().unwrap()
        };
        assert_refused_then_recovers(&devices, &mut groups, b"conv_twin_add", &commit);

        // The same new identity twice in one commit.
        let dave = encode_device_identity(b"acct_dave", b"dev_dave").unwrap();
        let commit = {
            let [_, bob, _] = &devices;
            let (commit, _, _) = in_scope(bob, &mut groups[1], |g| {
                g.add_members(
                    &bob.provider,
                    &bob.signer,
                    &[forged_key_package(&dave), forged_key_package(&dave)],
                )
            })
            .unwrap();
            commit.tls_serialize_detached().unwrap()
        };
        assert_refused_then_recovers(&devices, &mut groups, b"conv_twin_add", &commit);
    }

    #[test]
    fn a_commit_changing_a_leaf_identity_is_refused() {
        let (devices, mut groups) = three_members(b"conv_rename");
        // Bob's update path claims to be Alice, with his own key.
        let commit = {
            let [_, bob, _] = &devices;
            let disguise = CredentialWithKey {
                credential: BasicCredential::new(
                    encode_device_identity(b"acct_alice", b"dev_alice").unwrap(),
                )
                .into(),
                signature_key: bob.signer.public().into(),
            };
            let parameters = LeafNodeParameters::builder()
                .with_credential_with_key(disguise)
                .build();
            in_scope(bob, &mut groups[1], |g| {
                g.self_update(&bob.provider, &bob.signer, parameters)
            })
            .unwrap()
            .into_contents()
            .0
            .tls_serialize_detached()
            .unwrap()
        };
        assert_refused_then_recovers(&devices, &mut groups, b"conv_rename", &commit);
    }

    /// A key package stored in `holder`'s provider (so `holder` can open a
    /// Welcome built from it) but carrying `identity` under `signer`.
    fn key_package_in(
        holder: &MlsDevice,
        signer: &SignatureKeyPair,
        identity: &[u8],
    ) -> KeyPackage {
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.to_vec()).into(),
            signature_key: signer.public().into(),
        };
        KeyPackage::builder()
            .build(CIPHERSUITE, &holder.provider, signer, credential)
            .unwrap()
            .key_package()
            .clone()
    }

    /// Alice builds a group through OpenMLS directly from `packages` and
    /// returns the Welcome; `bob` must refuse it and persist nothing.
    fn assert_welcome_refused(group_id: &[u8], bob: &MlsDevice, packages: &[KeyPackage]) {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let mut group = alice.create_group(group_id).unwrap();
        let (_, welcome, _) = in_scope(&alice, &mut group, |g| {
            g.add_members(&alice.provider, &alice.signer, packages)
        })
        .unwrap();
        let welcome = welcome.tls_serialize_detached().unwrap();
        assert!(bob.join_group(group_id, &welcome).is_err());
        assert_eq!(bob.load_group(group_id).err(), Some(MlsError::InvalidState));
    }

    #[test]
    fn a_welcome_with_a_malformed_or_repeated_identity_is_refused() {
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        assert_welcome_refused(
            b"conv_w_garbage",
            &bob,
            &[raw_key_package(&bob), forged_key_package(b"garbage")],
        );
        let carol = encode_device_identity(b"acct_carol", b"dev_carol").unwrap();
        assert_welcome_refused(
            b"conv_w_twins",
            &bob,
            &[
                raw_key_package(&bob),
                forged_key_package(&carol),
                forged_key_package(&carol),
            ],
        );
        // A second leaf claiming Bob himself.
        let own = encode_device_identity(b"acct_bob", b"dev_bob").unwrap();
        assert_welcome_refused(
            b"conv_w_self_twin",
            &bob,
            &[raw_key_package(&bob), forged_key_package(&own)],
        );
    }

    #[test]
    fn a_welcome_must_place_this_device_under_its_own_identity_and_key() {
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        // Bob's own key material, but another identity on the leaf.
        let mallory = encode_device_identity(b"acct_mallory", b"dev_mallory").unwrap();
        assert_welcome_refused(
            b"conv_w_identity",
            &bob,
            &[key_package_in(&bob, &bob.signer, &mallory)],
        );
        // Bob's identity, but a signing key that is not his.
        let other = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).unwrap();
        let own = encode_device_identity(b"acct_bob", b"dev_bob").unwrap();
        assert_welcome_refused(b"conv_w_key", &bob, &[key_package_in(&bob, &other, &own)]);
    }

    #[test]
    fn a_welcome_for_another_group_persists_nothing() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let mut group = alice.create_group(b"conv_real").unwrap();
        let add = alice
            .add_member(
                &mut group,
                &bob.create_key_package().unwrap(),
                b"acct_bob",
                b"dev_bob",
            )
            .unwrap();
        assert_eq!(
            bob.join_group(b"conv_expected", &add.welcome).err(),
            Some(MlsError::InvalidMessage)
        );
        assert!(bob.load_group(b"conv_real").is_err());
        assert!(bob.load_group(b"conv_expected").is_err());
    }

    #[test]
    fn a_staged_self_update_refreshes_the_leaf_only_after_acceptance() {
        let group_id = b"conv_self_update";
        let (devices, mut groups) = three_members(group_id);
        let [alice, bob, carol] = &devices;
        let [alice_group, bob_group, carol_group] = &mut groups;
        let epoch = carol.group_epoch(carol_group);
        let leaf_key = carol_group
            .own_leaf_node()
            .unwrap()
            .encryption_key()
            .clone();
        let safety = carol.conversation_safety_number(carol_group).unwrap();

        let staged = carol.stage_self_update(carol_group).unwrap();
        assert_eq!(staged.epoch, epoch);
        assert!(staged.welcome.is_empty());
        // Staged, not merged: the epoch waits for the server.
        assert!(carol.has_pending_commit(carol_group));
        assert_eq!(carol.group_epoch(carol_group), epoch);
        // A second stage on top of a waiting commit is refused.
        assert_eq!(
            carol.stage_self_update(carol_group).err(),
            Some(MlsError::InvalidState)
        );

        carol.merge_pending_commit(carol_group).unwrap();
        assert_eq!(carol.group_epoch(carol_group), epoch + 1);
        // The commit carried an update path: Carol's leaf key is new.
        assert_ne!(
            carol_group.own_leaf_node().unwrap().encryption_key(),
            &leaf_key
        );
        for (device, group) in [(alice, &mut *alice_group), (bob, &mut *bob_group)] {
            device.process_commit(group, &staged.commit).unwrap();
            assert_eq!(device.group_epoch(group), epoch + 1);
            assert_eq!(
                group.epoch_authenticator().as_slice(),
                carol_group.epoch_authenticator().as_slice()
            );
        }
        // Identities and signature keys are unchanged, so is the number.
        assert_eq!(
            carol
                .conversation_safety_number(carol_group)
                .unwrap()
                .transcript_hash,
            safety.transcript_hash
        );

        let message = alice.encrypt(alice_group, b"after update").unwrap();
        assert_eq!(
            carol
                .decrypt(carol_group, &message, b"acct_alice", b"dev_alice")
                .unwrap(),
            b"after update"
        );
        let reply = carol.encrypt(carol_group, b"reply").unwrap();
        assert_eq!(
            bob.decrypt(bob_group, &reply, b"acct_carol", b"dev_carol")
                .unwrap(),
            b"reply"
        );
    }

    #[test]
    fn a_refused_self_update_is_cleared_and_the_winner_applies() {
        let group_id = b"conv_self_update_race";
        let (devices, mut groups) = three_members(group_id);
        let [alice, bob, _] = &devices;
        let [alice_group, bob_group, _] = &mut groups;
        let epoch = alice.group_epoch(alice_group);
        alice.stage_self_update(alice_group).unwrap();
        let winner = bob.stage_self_update(bob_group).unwrap();
        bob.merge_pending_commit(bob_group).unwrap();
        // Bob's commit won the epoch: Alice drops hers and applies his.
        alice.clear_pending_commit(alice_group).unwrap();
        alice.process_commit(alice_group, &winner.commit).unwrap();
        assert_eq!(alice.group_epoch(alice_group), epoch + 1);
        assert!(!alice.has_pending_commit(alice_group));
        let message = bob.encrypt(bob_group, b"still in step").unwrap();
        assert_eq!(
            alice
                .decrypt(alice_group, &message, b"acct_bob", b"dev_bob")
                .unwrap(),
            b"still in step"
        );
    }

    #[test]
    fn a_refused_staged_commit_is_cleared_without_forking() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let carol = MlsDevice::new(b"acct_carol", b"dev_carol").unwrap();
        let dave = MlsDevice::new(b"acct_dave", b"dev_dave").unwrap();
        let mut alice_group = alice.create_group(b"conv_race").unwrap();
        let add = alice
            .add_member(
                &mut alice_group,
                &bob.create_key_package().unwrap(),
                b"acct_bob",
                b"dev_bob",
            )
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let mut bob_group = bob.join_group(b"conv_race", &add.welcome).unwrap();

        // Both stage a commit on epoch 1; the server accepts Alice's.
        let carol_kp = carol.create_key_package().unwrap();
        let alice_commit = alice
            .stage_membership_commit(
                &mut alice_group,
                &[MemberAdd {
                    key_package: &carol_kp,
                    account_id: b"acct_carol",
                    device_id: b"dev_carol",
                }],
                &[],
            )
            .unwrap();
        let dave_kp = dave.create_key_package().unwrap();
        let bob_commit = bob
            .stage_membership_commit(
                &mut bob_group,
                &[MemberAdd {
                    key_package: &dave_kp,
                    account_id: b"acct_dave",
                    device_id: b"dev_dave",
                }],
                &[],
            )
            .unwrap();
        assert_eq!(alice_commit.epoch, bob_commit.epoch);
        alice.merge_pending_commit(&mut alice_group).unwrap();

        // Bob's is refused: he clears it and applies Alice's commit.
        bob.clear_pending_commit(&mut bob_group).unwrap();
        assert!(!bob.has_pending_commit(&bob_group));
        bob.process_commit(&mut bob_group, &alice_commit.commit)
            .unwrap();
        assert_eq!(bob.group_epoch(&bob_group), 2);
        let mut carol_group = carol
            .join_group(b"conv_race", &alice_commit.welcome)
            .unwrap();
        let message = bob.encrypt(&mut bob_group, b"still one group").unwrap();
        assert_eq!(
            alice
                .decrypt(&mut alice_group, &message, b"acct_bob", b"dev_bob")
                .unwrap(),
            b"still one group"
        );
        let again = bob.encrypt(&mut bob_group, b"and carol").unwrap();
        assert_eq!(
            carol
                .decrypt(&mut carol_group, &again, b"acct_bob", b"dev_bob")
                .unwrap(),
            b"and carol"
        );
    }

    #[test]
    fn a_message_from_the_previous_epoch_still_decrypts() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let carol = MlsDevice::new(b"acct_carol", b"dev_carol").unwrap();
        let mut alice_group = alice.create_group(b"conv_past").unwrap();
        let add = alice
            .add_member(
                &mut alice_group,
                &bob.create_key_package().unwrap(),
                b"acct_bob",
                b"dev_bob",
            )
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let mut bob_group = bob.join_group(b"conv_past", &add.welcome).unwrap();

        // Bob sends before he has seen Alice's next commit.
        let late = bob.encrypt(&mut bob_group, b"sent at epoch 1").unwrap();
        let carol_kp = carol.create_key_package().unwrap();
        let staged = alice
            .stage_membership_commit(
                &mut alice_group,
                &[MemberAdd {
                    key_package: &carol_kp,
                    account_id: b"acct_carol",
                    device_id: b"dev_carol",
                }],
                &[],
            )
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        assert_eq!(
            alice
                .decrypt(&mut alice_group, &late, b"acct_bob", b"dev_bob")
                .unwrap(),
            b"sent at epoch 1"
        );
        bob.process_commit(&mut bob_group, &staged.commit).unwrap();
    }

    #[test]
    fn a_removed_device_cannot_inject_through_a_past_epoch() {
        let ([alice, bob, carol], [mut alice_group, mut bob_group, mut carol_group]) =
            three_members(b"conv_removed");
        let removal = alice
            .stage_membership_commit(
                &mut alice_group,
                &[],
                &[MemberIdentity {
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                }],
            )
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        carol
            .process_commit(&mut carol_group, &removal.commit)
            .unwrap();

        // Bob ignores his removal and keeps writing in the old epoch.
        let injected = bob.encrypt(&mut bob_group, b"still here").unwrap();
        assert_eq!(
            carol.decrypt(&mut carol_group, &injected, b"acct_bob", b"dev_bob"),
            Err(MlsError::SenderRemoved)
        );
        // A past-epoch message from a member who stays still decrypts.
        let ([a, b, c], [mut ag, mut bg, mut cg]) = three_members(b"conv_stays");
        let late = c.encrypt(&mut cg, b"late but welcome").unwrap();
        let dave = MlsDevice::new(b"acct_dave", b"dev_dave").unwrap();
        let dave_kp = dave.create_key_package().unwrap();
        let add = a
            .stage_membership_commit(
                &mut ag,
                &[MemberAdd {
                    key_package: &dave_kp,
                    account_id: b"acct_dave",
                    device_id: b"dev_dave",
                }],
                &[],
            )
            .unwrap();
        a.merge_pending_commit(&mut ag).unwrap();
        b.process_commit(&mut bg, &add.commit).unwrap();
        assert_eq!(
            b.decrypt(&mut bg, &late, b"acct_carol", b"dev_carol")
                .unwrap(),
            b"late but welcome"
        );
    }

    #[test]
    fn the_committer_drops_a_late_message_from_the_device_it_removed() {
        // The cost of the rule (Q-003): Bob's message is sent, and accepted
        // by the server, before Alice's removal commit, but Alice merges her
        // commit on acceptance and reads Bob's message afterwards.
        let ([alice, bob, _carol], [mut alice_group, mut bob_group, _]) =
            three_members(b"conv_race_removed");
        let late = bob.encrypt(&mut bob_group, b"sent before removal").unwrap();
        alice
            .stage_membership_commit(
                &mut alice_group,
                &[],
                &[MemberIdentity {
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                }],
            )
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        assert_eq!(
            alice.decrypt(&mut alice_group, &late, b"acct_bob", b"dev_bob"),
            Err(MlsError::SenderRemoved)
        );
    }

    #[test]
    fn decrypt_rejects_a_spoofed_sender() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let mut alice_group = alice.create_group(b"conv_spoof").unwrap();
        let add = alice
            .add_member(
                &mut alice_group,
                &bob.create_key_package().unwrap(),
                b"acct_bob",
                b"dev_bob",
            )
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let mut bob_group = bob.join_group(b"conv_spoof", &add.welcome).unwrap();

        // The server claims the message came from someone else.
        let first = alice.encrypt(&mut alice_group, b"from alice").unwrap();
        assert_eq!(
            bob.decrypt(&mut bob_group, &first, b"acct_mallory", b"dev_mallory"),
            Err(MlsError::SenderMismatch)
        );
        // Same account, wrong device is also a mismatch.
        let second = alice.encrypt(&mut alice_group, b"again").unwrap();
        assert_eq!(
            bob.decrypt(&mut bob_group, &second, b"acct_alice", b"dev_other"),
            Err(MlsError::SenderMismatch)
        );
        // The group keeps working for correctly labelled messages.
        let third = alice.encrypt(&mut alice_group, b"honest").unwrap();
        assert_eq!(
            bob.decrypt(&mut bob_group, &third, b"acct_alice", b"dev_alice")
                .unwrap(),
            b"honest"
        );
    }

    #[test]
    fn malformed_or_foreign_messages_fail_closed() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let mut alice_group = alice.create_group(b"conv_alice").unwrap();
        let mut bob_group = bob.create_group(b"conv_bob").unwrap();

        assert_eq!(
            alice.decrypt(
                &mut alice_group,
                b"not an MLS message",
                b"acct_bob",
                b"dev_bob"
            ),
            Err(MlsError::InvalidMessage)
        );
        let foreign = bob.encrypt(&mut bob_group, b"foreign").unwrap();
        assert_eq!(
            alice.decrypt(&mut alice_group, &foreign, b"acct_bob", b"dev_bob"),
            Err(MlsError::InvalidMessage)
        );
    }

    #[test]
    fn update_and_revocation_converge_across_devices() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let bob_key_package = bob.create_key_package().unwrap();
        let mut alice_group = alice.create_group(b"conv_test").unwrap();
        let add = alice
            .add_member(&mut alice_group, &bob_key_package, b"acct_bob", b"dev_bob")
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let mut bob_group = bob.join_group(b"conv_test", &add.welcome).unwrap();

        let update = bob.self_update(&mut bob_group).unwrap();
        bob.merge_pending_commit(&mut bob_group).unwrap();
        alice.process_commit(&mut alice_group, &update).unwrap();
        let after_update = bob.encrypt(&mut bob_group, b"after update").unwrap();
        assert_eq!(
            alice
                .decrypt(&mut alice_group, &after_update, b"acct_bob", b"dev_bob")
                .unwrap(),
            b"after update"
        );

        let bob_leaves = alice
            .member_indices(&alice_group, b"acct_bob", b"dev_bob")
            .unwrap();
        let removal = alice.remove_members(&mut alice_group, &bob_leaves).unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        bob.process_commit(&mut bob_group, &removal).unwrap();
        assert!(!bob_group.is_active());
        assert!(bob.encrypt(&mut bob_group, b"must fail").is_err());
    }

    #[test]
    fn identity_and_key_package_inputs_are_bounded_and_verified() {
        assert!(matches!(
            MlsDevice::new(b"", b"device"),
            Err(MlsError::InvalidIdentity)
        ));
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let mut group = alice.create_group(b"conv_test").unwrap();
        assert_eq!(
            alice.add_member(&mut group, b"not a key package", b"acct_bob", b"dev_bob",),
            Err(MlsError::InvalidKeyPackage)
        );

        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let bob_package = bob.create_key_package().unwrap();
        assert_eq!(
            alice.add_member(&mut group, &bob_package, b"acct_mallory", b"dev_bob",),
            Err(MlsError::InvalidKeyPackage)
        );
        let add = alice
            .add_member(&mut group, &bob_package, b"acct_bob", b"dev_bob")
            .unwrap();
        alice.merge_pending_commit(&mut group).unwrap();
        assert!(matches!(
            bob.join_group(b"conv_substituted", &add.welcome),
            Err(MlsError::InvalidMessage)
        ));
    }

    #[test]
    fn enrollment_signature_covers_only_the_prefixed_proof() {
        let device = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let challenge = b"reserved server challenge";
        let enrollment = device.create_enrollment_credential(challenge).unwrap();
        assert!(enrollment.key_package.len() >= crate::MIN_KEY_PACKAGE_BYTES);
        assert_eq!(enrollment.signing_public_key, device.signing_public_key());
        assert_eq!(enrollment.challenge_signature.len(), 64);
        assert_eq!(
            device.create_enrollment_credential(b""),
            Err(MlsError::InvalidIdentity)
        );

        let mut proof = b"veritra-enrollment-proof-v1".to_vec();
        proof.extend_from_slice(&(challenge.len() as u16).to_be_bytes());
        proof.extend_from_slice(challenge);
        proof.extend_from_slice(&enrollment.signing_public_key);
        proof.extend_from_slice(&Sha256::digest(&enrollment.key_package));
        let verify = |message: &[u8]| {
            device.provider.crypto().verify_signature(
                SignatureScheme::ED25519,
                message,
                device.signing_public_key(),
                &enrollment.challenge_signature,
            )
        };
        assert!(verify(&proof).is_ok());
        assert!(verify(challenge).is_err());
        // The prefix cannot be read as an RFC 9420 SignContent: its first
        // byte (0x76) is a two-byte varint, after which "MLS 1.0 " would
        // have to follow.
        assert_eq!(proof[0] >> 6, 1);
        assert_ne!(&proof[2..10], b"MLS 1.0 ");
    }

    const SAFETY_V2_VECTOR_HASH: [u8; 32] = [
        199, 97, 106, 126, 125, 100, 152, 75, 31, 62, 200, 8, 86, 156, 164, 244, 18, 235, 179, 91,
        174, 229, 24, 52, 183, 179, 180, 38, 66, 118, 82, 204,
    ];
    const SAFETY_V2_VECTOR_DIGITS: &str =
        "019092511060372463067519010870521113969160651898535434359873";

    #[test]
    fn safety_number_ignores_epochs_but_not_devices() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let bob_key_package = bob.create_key_package().unwrap();
        let mut alice_group = alice.create_group(b"conv_safety").unwrap();
        let add = alice
            .add_member(&mut alice_group, &bob_key_package, b"acct_bob", b"dev_bob")
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let mut bob_group = bob.join_group(b"conv_safety", &add.welcome).unwrap();

        let first = alice.conversation_safety_number(&alice_group).unwrap();
        assert_eq!(first, bob.conversation_safety_number(&bob_group).unwrap());
        assert_eq!(first.sas.len(), CONVERSATION_SAFETY_DIGITS);
        assert!(first.sas.bytes().all(|byte| byte.is_ascii_digit()));

        // A routine commit moves the epoch but keeps every device's keys.
        let update = bob.self_update(&mut bob_group).unwrap();
        bob.merge_pending_commit(&mut bob_group).unwrap();
        alice.process_commit(&mut alice_group, &update).unwrap();
        assert_ne!(alice_group.epoch(), GroupEpoch::from(1));
        assert_eq!(
            first,
            alice.conversation_safety_number(&alice_group).unwrap()
        );
        assert_eq!(first, bob.conversation_safety_number(&bob_group).unwrap());

        // A new device is a new reader, so the number changes.
        let tablet = MlsDevice::new(b"acct_bob", b"dev_bob_tablet").unwrap();
        let tablet_key_package = tablet.create_key_package().unwrap();
        let link = alice
            .add_member(
                &mut alice_group,
                &tablet_key_package,
                b"acct_bob",
                b"dev_bob_tablet",
            )
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        bob.process_commit(&mut bob_group, &link.commit).unwrap();
        let second = alice.conversation_safety_number(&alice_group).unwrap();
        assert_ne!(first, second);
        assert_eq!(second, bob.conversation_safety_number(&bob_group).unwrap());
    }

    #[test]
    fn safety_number_v2_has_a_stable_vector_and_refuses_duplicates() {
        let members = vec![
            (b"cred-b".to_vec(), vec![0x22; 32]),
            (b"cred-a".to_vec(), vec![0x11; 32]),
        ];
        let reversed: Vec<_> = members.iter().rev().cloned().collect();
        let value = conversation_safety_number_v2(b"conv_vector", &members).unwrap();
        assert_eq!(
            value,
            conversation_safety_number_v2(b"conv_vector", &reversed).unwrap()
        );
        assert_ne!(
            value,
            conversation_safety_number_v2(b"conv_other", &members).unwrap()
        );
        assert_eq!(value.transcript_hash, SAFETY_V2_VECTOR_HASH.to_vec());
        assert_eq!(value.sas, SAFETY_V2_VECTOR_DIGITS);

        let duplicated = vec![members[0].clone(), members[0].clone()];
        assert!(conversation_safety_number_v2(b"conv_vector", &duplicated).is_err());
    }

    #[test]
    fn device_link_locator_has_a_stable_vector() {
        assert_eq!(
            device_link_locator(&[0x55; 16]).unwrap(),
            vec![
                0x89, 0x6e, 0x62, 0x7a, 0x33, 0x81, 0xce, 0x62, 0x5a, 0x8b, 0x3f, 0xd2, 0x0a, 0xd0,
                0x90, 0xb4, 0x44, 0xa8, 0x8c, 0x0a, 0x20, 0x1c, 0x3c, 0x8f, 0xa5, 0xb6, 0xa6, 0xf1,
                0x6a, 0x48, 0xe2, 0x5a
            ]
        );
        for size in [0, 15, 17] {
            assert!(device_link_locator(&vec![1; size]).is_err());
        }
    }

    // ---- C7 (ABI 13): commit outcome, exporter root, epoch, keys ----

    fn root_of(outcome: &CommitOutcome) -> Vec<u8> {
        outcome.root.as_ref().expect("root").as_slice().to_vec()
    }

    /// The exporter value of the group's current epoch, through OpenMLS.
    fn exported_root(device: &MlsDevice, group: &MlsGroup) -> Vec<u8> {
        group
            .export_secret(
                device.provider.crypto(),
                c7::EXPORTER_LABEL,
                &c7::exporter_context(group.group_id().as_slice(), group.epoch().as_u64()).unwrap(),
                32,
            )
            .unwrap()
    }

    fn removal_of<'a>(account: &'a [u8], device: &'a [u8]) -> [MemberIdentity<'a>; 1] {
        [MemberIdentity {
            account_id: account,
            device_id: device,
        }]
    }

    // ---- B6 (ABI 22): media keys of a call group ----

    #[test]
    fn b6_media_keys_follow_the_epoch_and_leave_with_the_removed_member() {
        let ([alice, bob, carol], [mut alice_group, mut bob_group, mut carol_group]) =
            three_members(b"call_group_b6");
        let call = b"call_b6";
        // Senders by identity; leaves are alice 0, bob 1, carol 2.
        let who = |leaf: u32| -> (&'static [u8], &'static [u8]) {
            match leaf {
                0 => (b"acct_alice", b"dev_alice"),
                1 => (b"acct_bob", b"dev_bob"),
                _ => (b"acct_carol", b"dev_carol"),
            }
        };
        let key = |device: &MlsDevice, group: &MlsGroup, leaf: u32, stream: u8| {
            let (account, dev) = who(leaf);
            device
                .b6_media_key(group, call, account, dev, stream)
                .unwrap()
                .as_slice()
                .to_vec()
        };
        // Every member derives the same key for the same sender and stream,
        // and it is the exporter run through the documented schedule.
        let (a0, b0, c0) = (
            key(&alice, &alice_group, 0, 0),
            key(&bob, &bob_group, 0, 0),
            key(&carol, &carol_group, 0, 0),
        );
        assert_eq!(a0, b0);
        assert_eq!(a0, c0);
        let exported = alice_group
            .export_secret(
                alice.provider.crypto(),
                crate::b6::EXPORTER_LABEL,
                &crate::b6::exporter_context(call, alice_group.epoch().as_u64()).unwrap(),
                32,
            )
            .unwrap();
        assert_eq!(
            a0,
            crate::b6::sender_key(&exported, 0, 0).unwrap().as_slice()
        );
        // Per sender, per stream, per call.
        assert_ne!(a0, key(&alice, &alice_group, 1, 0));
        assert_ne!(a0, key(&alice, &alice_group, 0, 2));
        assert_ne!(
            a0,
            alice
                .b6_media_key(&alice_group, b"call_other", b"acct_alice", b"dev_alice", 0)
                .unwrap()
                .as_slice()
        );
        // A device that is not in the group and a bad stream are refused.
        assert!(alice
            .b6_media_key(&alice_group, call, b"acct_zed", b"dev_zed", 0)
            .is_err());
        assert!(alice
            .b6_media_key(&alice_group, call, b"acct_alice", b"dev_alice", 4)
            .is_err());
        // The exporter label is the only secret that matches: the C7 label gives another.
        let c7_root = exported_root(&alice, &alice_group);
        assert_ne!(
            a0,
            crate::b6::sender_key(&c7_root, 0, 0).unwrap().as_slice()
        );

        // Removing bob moves the epoch: the key changes, carol follows, and
        // bob, who processes his own removal, can derive no key at all.
        let staged = alice
            .stage_membership_commit(&mut alice_group, &[], &removal_of(b"acct_bob", b"dev_bob"))
            .unwrap();
        alice
            .merge_pending_commit_with_outcome(&mut alice_group)
            .unwrap();
        let a1 = key(&alice, &alice_group, 0, 0);
        assert_ne!(a0, a1);
        carol
            .process_commit_with_outcome(&mut carol_group, &staged.commit)
            .unwrap();
        assert_eq!(a1, key(&carol, &carol_group, 0, 0));
        // Bob's key for himself is gone from the new epoch too.
        assert!(alice
            .b6_media_key(&alice_group, call, b"acct_bob", b"dev_bob", 0)
            .is_err());
        let removed = bob
            .process_commit_with_outcome(&mut bob_group, &staged.commit)
            .unwrap();
        assert!(removed.removed_self);
        // His group is gone, so the FFI's load fails and nothing is derived.
        assert_eq!(
            bob.load_group(b"call_group_b6").err(),
            Some(MlsError::InvalidState)
        );
        // Even the stale in-memory handle cannot give the new epoch's key.
        if let Ok(stale) = bob.b6_media_key(&bob_group, call, b"acct_alice", b"dev_alice", 0) {
            assert_ne!(stale.as_slice(), a1.as_slice());
        }
    }

    #[test]
    fn c7_removal_returns_the_staged_export_that_the_merged_epoch_also_gives() {
        let ([alice, bob, carol], [mut alice_group, mut bob_group, mut carol_group]) =
            three_members(b"conv_c7_root");
        let staged = alice
            .stage_membership_commit(&mut alice_group, &[], &removal_of(b"acct_bob", b"dev_bob"))
            .unwrap();
        // The committer's own pending commit.
        let own = alice
            .merge_pending_commit_with_outcome(&mut alice_group)
            .unwrap();
        assert!(own.removed_any && !own.added_any && !own.removed_self);
        assert_eq!(own.new_epoch, staged.epoch + 1);
        assert_eq!(own.new_epoch, alice_group.epoch().as_u64());
        // The export taken before the merge is the one MlsGroup gives after.
        assert_eq!(root_of(&own), exported_root(&alice, &alice_group));
        assert_eq!(root_of(&own).len(), 32);

        // Another member's staged commit gives the same value.
        let other = carol
            .process_commit_with_outcome(&mut carol_group, &staged.commit)
            .unwrap();
        assert!(other.removed_any && !other.added_any && !other.removed_self);
        assert_eq!(other.new_epoch, own.new_epoch);
        assert_eq!(root_of(&other), root_of(&own));
        assert_eq!(root_of(&other), exported_root(&carol, &carol_group));

        // The removed device: removed, no root, no error, group gone (D70).
        let removed = bob
            .process_commit_with_outcome(&mut bob_group, &staged.commit)
            .unwrap();
        assert!(removed.removed_any && removed.removed_self);
        assert!(removed.root.is_none());
        assert_eq!(removed.new_epoch, own.new_epoch);
        assert_eq!(
            bob.load_group(b"conv_c7_root").err(),
            Some(MlsError::InvalidState)
        );
    }

    #[test]
    fn c7_roots_differ_by_group_and_by_epoch() {
        let ([alice, _, _], [mut alice_group, ..]) = three_members(b"conv_c7_a");
        let ([alice_b, _, _], [mut other_group, ..]) = three_members(b"conv_c7_b");
        alice
            .stage_membership_commit(&mut alice_group, &[], &removal_of(b"acct_bob", b"dev_bob"))
            .unwrap();
        let a = alice
            .merge_pending_commit_with_outcome(&mut alice_group)
            .unwrap();
        alice_b
            .stage_membership_commit(&mut other_group, &[], &removal_of(b"acct_bob", b"dev_bob"))
            .unwrap();
        let b = alice_b
            .merge_pending_commit_with_outcome(&mut other_group)
            .unwrap();
        // Same epoch number, different groups (and different key schedules).
        assert_eq!(a.new_epoch, b.new_epoch);
        assert_ne!(root_of(&a), root_of(&b));
        // Another removal moves to a new epoch with a new root.
        alice
            .stage_membership_commit(
                &mut alice_group,
                &[],
                &removal_of(b"acct_carol", b"dev_carol"),
            )
            .unwrap();
        let c = alice
            .merge_pending_commit_with_outcome(&mut alice_group)
            .unwrap();
        assert_eq!(c.new_epoch, a.new_epoch + 1);
        assert_ne!(root_of(&c), root_of(&a));
    }

    #[test]
    fn c7_add_update_and_replacement_report_what_the_commit_holds() {
        let ([alice, bob, carol], [mut alice_group, mut bob_group, mut carol_group]) =
            three_members(b"conv_c7_kinds");
        // An add: Added, no root.
        let dave = MlsDevice::new(b"acct_dave", b"dev_dave").unwrap();
        let dave_kp = dave.create_key_package().unwrap();
        let add = alice
            .stage_membership_commit(
                &mut alice_group,
                &[MemberAdd {
                    key_package: &dave_kp,
                    account_id: b"acct_dave",
                    device_id: b"dev_dave",
                }],
                &[],
            )
            .unwrap();
        let own = alice
            .merge_pending_commit_with_outcome(&mut alice_group)
            .unwrap();
        assert!(own.added_any && !own.removed_any && !own.removed_self);
        assert!(own.root.is_none());
        let seen = bob
            .process_commit_with_outcome(&mut bob_group, &add.commit)
            .unwrap();
        assert!(seen.added_any && !seen.removed_any && seen.root.is_none());
        carol.process_commit(&mut carol_group, &add.commit).unwrap();

        // A self-update: nothing, no root, the next epoch.
        let update = bob.stage_self_update(&mut bob_group).unwrap();
        let own = bob
            .merge_pending_commit_with_outcome(&mut bob_group)
            .unwrap();
        assert!(!own.added_any && !own.removed_any && !own.removed_self);
        assert!(own.root.is_none());
        let seen = alice
            .process_commit_with_outcome(&mut alice_group, &update.commit)
            .unwrap();
        assert!(!seen.added_any && !seen.removed_any && seen.root.is_none());
        assert_eq!(seen.new_epoch, alice_group.epoch().as_u64());
        carol
            .process_commit(&mut carol_group, &update.commit)
            .unwrap();

        // A replacement: carol's identity removed and added again with a new
        // key package in one commit. Both flags, and a root: it rekeys.
        let carol_new = MlsDevice::new(b"acct_carol", b"dev_carol").unwrap();
        let carol_new_kp = carol_new.create_key_package().unwrap();
        let replace = alice
            .stage_membership_commit(
                &mut alice_group,
                &[MemberAdd {
                    key_package: &carol_new_kp,
                    account_id: b"acct_carol",
                    device_id: b"dev_carol",
                }],
                &removal_of(b"acct_carol", b"dev_carol"),
            )
            .unwrap();
        let own = alice
            .merge_pending_commit_with_outcome(&mut alice_group)
            .unwrap();
        assert!(own.added_any && own.removed_any && !own.removed_self);
        assert_eq!(root_of(&own), exported_root(&alice, &alice_group));
        let seen = bob
            .process_commit_with_outcome(&mut bob_group, &replace.commit)
            .unwrap();
        assert_eq!(root_of(&seen), root_of(&own));
        // The old carol device is removed by it.
        let gone = carol
            .process_commit_with_outcome(&mut carol_group, &replace.commit)
            .unwrap();
        assert!(gone.removed_self && gone.root.is_none());
        // The replaced device's key is now the new one in the tree.
        assert_eq!(
            alice
                .member_signature_key(&alice_group, b"acct_carol", b"dev_carol")
                .unwrap(),
            carol_new.signing_public_key()
        );
    }

    #[test]
    fn c7_outcome_comes_from_the_commit_bytes_alone() {
        // The server's label is not an input: the same bytes give the same
        // outcome whatever the transport called them, so a removal labelled
        // as an add still reports a removal and a root.
        let ([alice, _bob, carol], [mut alice_group, _bob_group, mut carol_group]) =
            three_members(b"conv_c7_label");
        let removal = alice
            .stage_membership_commit(&mut alice_group, &[], &removal_of(b"acct_bob", b"dev_bob"))
            .unwrap();
        let outcome = carol
            .process_commit_with_outcome(&mut carol_group, &removal.commit)
            .unwrap();
        assert!(outcome.removed_any && !outcome.added_any);
        assert!(outcome.root.is_some());
    }

    #[test]
    fn c7_merge_without_a_staged_commit_is_refused_and_changes_nothing() {
        let ([alice, ..], [mut alice_group, ..]) = three_members(b"conv_c7_nopending");
        let epoch = alice.group_epoch(&alice_group);
        assert!(matches!(
            alice.merge_pending_commit_with_outcome(&mut alice_group),
            Err(MlsError::InvalidState)
        ));
        assert_eq!(alice.group_epoch(&alice_group), epoch);
    }

    #[test]
    fn c7_failed_commit_processing_returns_no_root_and_keeps_the_epoch() {
        let ([alice, _, carol], [mut alice_group, _, mut carol_group]) =
            three_members(b"conv_c7_fail");
        let staged = alice
            .stage_membership_commit(&mut alice_group, &[], &removal_of(b"acct_bob", b"dev_bob"))
            .unwrap();
        let epoch = carol.group_epoch(&carol_group);
        let mut damaged = staged.commit.clone();
        let last = damaged.len() - 1;
        damaged[last] ^= 0x01;
        assert!(carol
            .process_commit_with_outcome(&mut carol_group, &damaged)
            .is_err());
        assert_eq!(carol.group_epoch(&carol_group), epoch);
        // The undamaged commit still applies afterwards.
        let outcome = carol
            .process_commit_with_outcome(&mut carol_group, &staged.commit)
            .unwrap();
        assert!(outcome.root.is_some());
    }

    #[test]
    fn c7_an_update_that_changes_the_signature_key_is_refused() {
        let (devices, mut groups) = three_members(b"conv_c7_rekeyed");
        // Bob keeps his identity but rotates his credential key in an update
        // path (the path OpenMLS offers for it).
        let commit = {
            let [_, bob, _] = &devices;
            let new_signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).unwrap();
            new_signer.store(bob.provider.storage()).unwrap();
            let credential = CredentialWithKey {
                credential: BasicCredential::new(
                    encode_device_identity(b"acct_bob", b"dev_bob").unwrap(),
                )
                .into(),
                signature_key: new_signer.public().into(),
            };
            let bundle = NewSignerBundle {
                signer: &new_signer,
                credential_with_key: credential,
            };
            in_scope(bob, &mut groups[1], |g| {
                g.self_update_with_new_signer(
                    &bob.provider,
                    &bob.signer,
                    bundle,
                    LeafNodeParameters::default(),
                )
            })
            .unwrap()
            .into_contents()
            .0
            .tls_serialize_detached()
            .unwrap()
        };
        assert_refused_then_recovers(&devices, &mut groups, b"conv_c7_rekeyed", &commit);
    }

    #[test]
    fn c7_decrypt_returns_the_epoch_the_message_was_sent_in() {
        let ([alice, bob, carol], [mut alice_group, mut bob_group, mut carol_group]) =
            three_members(b"conv_c7_epoch");
        let early = bob.encrypt(&mut bob_group, b"early").unwrap();
        let (plain, epoch) = alice
            .decrypt_with_epoch(&mut alice_group, &early, b"acct_bob", b"dev_bob")
            .unwrap();
        assert_eq!((plain.as_slice(), epoch), (&b"early"[..], 1));
        // A message from a past epoch reports that epoch, not the current.
        let late = carol.encrypt(&mut carol_group, b"late").unwrap();
        let update = alice.stage_self_update(&mut alice_group).unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        assert_eq!(alice.group_epoch(&alice_group), 2);
        let (plain, epoch) = alice
            .decrypt_with_epoch(&mut alice_group, &late, b"acct_carol", b"dev_carol")
            .unwrap();
        assert_eq!((plain.as_slice(), epoch), (&b"late"[..], 1));
        bob.process_commit(&mut bob_group, &update.commit).unwrap();
        let fresh = bob.encrypt(&mut bob_group, b"fresh").unwrap();
        let (_, epoch) = alice
            .decrypt_with_epoch(&mut alice_group, &fresh, b"acct_bob", b"dev_bob")
            .unwrap();
        assert_eq!(epoch, 2);
        // A wrong claimed sender is still refused.
        let spoof = bob.encrypt(&mut bob_group, b"spoof").unwrap();
        assert_eq!(
            alice
                .decrypt_with_epoch(&mut alice_group, &spoof, b"acct_carol", b"dev_carol")
                .err(),
            Some(MlsError::SenderMismatch)
        );
    }

    #[test]
    fn c7_member_key_read_and_signatures_cross_devices() {
        let ([alice, bob, _], [alice_group, ..]) = three_members(b"conv_c7_keys");
        let key = alice
            .member_signature_key(&alice_group, b"acct_bob", b"dev_bob")
            .unwrap();
        assert_eq!(key, bob.signing_public_key());
        assert_eq!(
            alice
                .member_signature_key(&alice_group, b"acct_alice", b"dev_alice")
                .unwrap(),
            alice.signing_public_key()
        );
        assert_eq!(
            alice
                .member_signature_key(&alice_group, b"acct_zed", b"dev_zed")
                .err(),
            Some(MlsError::InvalidIdentity)
        );
        // Bob signs; Alice verifies with the key she read from the tree.
        let message = b"history record fields";
        for domain in c7::SIGN_DOMAINS {
            let signature = bob.c7_sign(domain, message).unwrap();
            assert_eq!(signature.len(), 64);
            assert!(c7::verify(domain, &key, message, &signature).unwrap());
            assert!(!c7::verify(domain, &key, b"other fields", &signature).unwrap());
        }
        // A signature under one domain is no signature under the other.
        let post = bob.c7_sign(c7::SIGN_DOMAIN_POST, message).unwrap();
        assert!(!c7::verify(c7::SIGN_DOMAIN_HISTORY, &key, message, &post).unwrap());
        // Unlisted domains are refused for signing.
        assert!(bob.c7_sign(b"veritra-c7-other-v1", message).is_err());
        assert!(bob.c7_sign(b"MLS 1.0 anything", message).is_err());
    }
}
