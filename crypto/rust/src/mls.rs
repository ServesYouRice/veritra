//! OpenMLS core operations.
//!
//! This module is intentionally not exposed through the C ABI yet. It proves
//! the selected library and protocol flow while platform key wrapping and ABI
//! ownership semantics are still under review.

use openmls::prelude::*;
use openmls::treesync::LeafNodeParameters;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::{signatures::Signer, OpenMlsProvider};
use sha2::{Digest, Sha256, Sha512};
use tls_codec::{Deserialize as TlsDeserializeTrait, Serialize as TlsSerializeTrait};

#[allow(dead_code)]
pub(crate) mod link_v3;
mod state;
#[allow(dead_code)]
pub(crate) mod transfer;

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const MAX_ID_BYTES: usize = 128;
const PADDING_BYTES: usize = 256;
const CREDENTIAL_FORMAT_VERSION: u8 = 1;
const DEVICE_LINK_PROTOCOL_VERSION: &[u8] = b"veritra-device-link-v2";
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
}

/// One MLS device identity and its private provider state.
///
/// Provider state can be exported only as an authenticated encrypted envelope.
/// The production ABI remains disabled until platforms atomically commit that
/// envelope, its rollback counter, and the sync cursor under Keystore/Keychain
/// protection.
pub struct MlsDevice {
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    account_id: Vec<u8>,
    device_id: Vec<u8>,
    pending_transfers: transfer::PendingTransfers,
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
        let provider = OpenMlsRustCrypto::default();
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
        })
    }

    pub fn create_key_package(&self) -> Result<Vec<u8>, MlsError> {
        let bundle = KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential.clone(),
            )
            .map_err(|_| MlsError::KeyGeneration)?;
        bundle
            .key_package()
            .tls_serialize_detached()
            .map_err(|_| MlsError::KeyGeneration)
    }

    pub fn signing_public_key(&self) -> &[u8] {
        self.signer.public()
    }

    /// This device's side of [`derive_device_link_verification`]; see there
    /// for what the 8-digit SAS (about 26.6 bits) protects and when.
    // Explicit transcript fields mirror the ABI and make their order reviewable.
    #[allow(clippy::too_many_arguments)]
    pub fn derive_device_link_verification(
        &self,
        protocol_version: &[u8],
        server_origin: &[u8],
        link_id: &[u8],
        link_secret: &[u8],
        peer_device_id: &[u8],
        peer_signing_public_key: &[u8],
        link_nonce: &[u8],
        local_is_existing_device: bool,
    ) -> Result<DeviceLinkVerification, MlsError> {
        let (existing_device_id, existing_key, new_device_id, new_key) = if local_is_existing_device
        {
            (
                self.device_id.as_slice(),
                self.signing_public_key(),
                peer_device_id,
                peer_signing_public_key,
            )
        } else {
            (
                peer_device_id,
                peer_signing_public_key,
                self.device_id.as_slice(),
                self.signing_public_key(),
            )
        };
        derive_device_link_verification(
            protocol_version,
            server_origin,
            link_id,
            link_secret,
            &self.account_id,
            link_nonce,
            existing_device_id,
            existing_key,
            new_device_id,
            new_key,
        )
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
        MlsGroup::new_with_group_id(
            &self.provider,
            &self.signer,
            &group_create_config(),
            GroupId::from_slice(group_id),
            self.credential.clone(),
        )
        .map_err(|_| MlsError::GroupOperation)
    }

    pub fn load_group(&self, group_id: &[u8]) -> Result<MlsGroup, MlsError> {
        if group_id.is_empty() || group_id.len() > MAX_ID_BYTES {
            return Err(MlsError::InvalidIdentity);
        }
        MlsGroup::load(self.provider.storage(), &GroupId::from_slice(group_id))
            .map_err(|_| MlsError::Storage)?
            .ok_or(MlsError::InvalidState)
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
        if key_package.leaf_node().credential().serialized_content() != expected_identity {
            return Err(MlsError::InvalidKeyPackage);
        }
        ensure_added_identities_unique(&roster_identities(group, &[]), &[expected_identity])?;
        let (commit, welcome, _) = group
            .add_members(&self.provider, &self.signer, &[key_package])
            .map_err(|_| MlsError::GroupOperation)?;
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
        if adds.is_empty() && removes.is_empty() {
            return Err(MlsError::InvalidState);
        }
        if group.pending_commit().is_some() {
            return Err(MlsError::InvalidState);
        }
        let mut key_packages = Vec::with_capacity(adds.len());
        let mut added = Vec::with_capacity(adds.len());
        for add in adds {
            let key_package = KeyPackageIn::tls_deserialize_exact(add.key_package)
                .map_err(|_| MlsError::InvalidKeyPackage)?
                .validate(self.provider.crypto(), ProtocolVersion::Mls10)
                .map_err(|_| MlsError::InvalidKeyPackage)?;
            let expected = encode_device_identity(add.account_id, add.device_id)?;
            if key_package.leaf_node().credential().serialized_content() != expected {
                return Err(MlsError::InvalidKeyPackage);
            }
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
        let epoch = group.epoch().as_u64();
        let bundle = group
            .commit_builder()
            .propose_adds(key_packages)
            .propose_removals(removed)
            .load_psks(self.provider.storage())
            .map_err(|_| MlsError::GroupOperation)?
            .build(
                self.provider.rand(),
                self.provider.crypto(),
                &self.signer,
                |_| true,
            )
            .map_err(|_| MlsError::GroupOperation)?
            .stage_commit(&self.provider)
            .map_err(|_| MlsError::GroupOperation)?;
        let (commit, welcome, _) = bundle.into_messages();
        let commit = commit
            .tls_serialize_detached()
            .map_err(|_| MlsError::GroupOperation)?;
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

    /// Drops a staged commit the server did not accept.
    pub fn clear_pending_commit(&self, group: &mut MlsGroup) -> Result<(), MlsError> {
        group
            .clear_pending_commit(self.provider.storage())
            .map_err(|_| MlsError::Storage)
    }

    pub fn has_pending_commit(&self, group: &MlsGroup) -> bool {
        group.pending_commit().is_some()
    }

    pub fn group_epoch(&self, group: &MlsGroup) -> u64 {
        group.epoch().as_u64()
    }

    pub fn merge_pending_commit(&self, group: &mut MlsGroup) -> Result<(), MlsError> {
        group
            .merge_pending_commit(&self.provider)
            .map_err(|_| MlsError::GroupOperation)
    }

    pub fn self_update(&self, group: &mut MlsGroup) -> Result<Vec<u8>, MlsError> {
        let bundle = group
            .self_update(&self.provider, &self.signer, LeafNodeParameters::default())
            .map_err(|_| MlsError::GroupOperation)?;
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
        let (commit, _, _) = group
            .remove_members(&self.provider, &self.signer, members)
            .map_err(|_| MlsError::GroupOperation)?;
        commit
            .tls_serialize_detached()
            .map_err(|_| MlsError::GroupOperation)
    }

    pub fn process_commit(&self, group: &mut MlsGroup, commit: &[u8]) -> Result<(), MlsError> {
        let protocol_message = MlsMessageIn::tls_deserialize_exact(commit)
            .map_err(|_| MlsError::InvalidMessage)?
            .try_into_protocol_message()
            .map_err(|_| MlsError::InvalidMessage)?;
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
        // what decrypt() attributes messages to.
        inspect_commit(group, committer, &staged_commit)?;
        group
            .merge_staged_commit(&self.provider, *staged_commit)
            .map_err(|_| MlsError::GroupOperation)
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
        // Staging decrypts the Welcome (and consumes the key package) but
        // stores no group; into_group persists it, so every check runs first.
        let staged = StagedWelcome::new_from_welcome(
            &self.provider,
            group_create_config().join_config(),
            welcome,
            None,
        )
        .map_err(|_| MlsError::GroupOperation)?;
        if staged.group_context().group_id().as_slice() != expected_group_id {
            return Err(MlsError::InvalidMessage);
        }
        self.inspect_welcome(&staged)?;
        staged
            .into_group(&self.provider)
            .map_err(|_| MlsError::GroupOperation)
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
        Ok(())
    }

    pub fn encrypt(&self, group: &mut MlsGroup, plaintext: &[u8]) -> Result<Vec<u8>, MlsError> {
        group
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(|_| MlsError::GroupOperation)?
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
        let expected_identity =
            encode_device_identity(expected_sender_account, expected_sender_device)?;
        let protocol_message = MlsMessageIn::tls_deserialize_exact(ciphertext)
            .map_err(|_| MlsError::InvalidMessage)?
            .try_into_protocol_message()
            .map_err(|_| MlsError::InvalidMessage)?;
        let processed = group
            .process_message(&self.provider, protocol_message)
            .map_err(|_| MlsError::InvalidMessage)?;
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
            ProcessedMessageContent::ApplicationMessage(message) => Ok(message.into_bytes()),
            _ => Err(MlsError::UnexpectedMessage),
        }
    }
}

/// L0 device-link verification (`veritra-device-link-v2`).
///
/// The SAS is 8 decimal digits: the first four MAC bytes modulo 10^8, about
/// 26.6 bits (the modulo bias is negligible). It is not a hash of public
/// data. The SAS, the claim tag and the approval tag are HMAC-SHA256 over the
/// transcript under keys derived from the 128-bit link secret, which reaches
/// the new device only out of band (QR or typed code). A relay that does not
/// know the secret cannot evaluate them, so it cannot grind substitute keys
/// towards a matching SAS, and a substituted key already fails the claim or
/// approval tag before any SAS is shown. This replaces a commit-then-reveal
/// step (TASK-010/TASK-048). The 8 digits stand alone only if the secret
/// leaks: an active relay that knows it chooses both keys and needs about
/// 10^4 key generations per side for the two SAS values to collide. Any
/// transcript change needs a new protocol string and a new stable vector.
// Keep the complete ordered transcript visible at each derivation call.
#[allow(clippy::too_many_arguments)]
pub fn derive_device_link_verification(
    protocol_version: &[u8],
    server_origin: &[u8],
    link_id: &[u8],
    link_secret: &[u8],
    account_id: &[u8],
    link_nonce: &[u8],
    existing_device_id: &[u8],
    existing_signing_public_key: &[u8],
    new_device_id: &[u8],
    new_signing_public_key: &[u8],
) -> Result<DeviceLinkVerification, MlsError> {
    if server_origin.is_empty()
        || server_origin.len() > 2048
        || link_id.is_empty()
        || link_id.len() > MAX_ID_BYTES
        || link_secret.len() != 16
        || protocol_version != DEVICE_LINK_PROTOCOL_VERSION
        || account_id.is_empty()
        || account_id.len() > MAX_ID_BYTES
        || existing_device_id.is_empty()
        || existing_device_id.len() > MAX_ID_BYTES
        || new_device_id.is_empty()
        || new_device_id.len() > MAX_ID_BYTES
        || link_nonce.len() != 32
        || existing_signing_public_key.len() != 32
        || new_signing_public_key.len() != 32
    {
        return Err(MlsError::InvalidIdentity);
    }
    let mut transcript = Vec::with_capacity(256);
    append_transcript_field(&mut transcript, DEVICE_LINK_TRANSCRIPT_DOMAIN)?;
    append_transcript_field(&mut transcript, protocol_version)?;
    append_transcript_field(&mut transcript, server_origin)?;
    append_transcript_field(&mut transcript, link_id)?;
    append_transcript_field(&mut transcript, account_id)?;
    append_transcript_field(&mut transcript, link_nonce)?;
    append_transcript_field(&mut transcript, existing_device_id)?;
    append_transcript_field(&mut transcript, existing_signing_public_key)?;
    append_transcript_field(&mut transcript, new_device_id)?;
    append_transcript_field(&mut transcript, new_signing_public_key)?;
    let transcript_hash = Sha256::digest(&transcript).to_vec();
    let sas_mac = link_mac(link_secret, b"veritra-link-sas-v2", &transcript);
    let claim_tag = link_mac(link_secret, b"veritra-link-claim-v2", &transcript).to_vec();
    let approval_tag = link_mac(link_secret, b"veritra-link-approval-v2", &transcript).to_vec();
    let sas_value = u32::from_be_bytes(
        sas_mac[..4]
            .try_into()
            .map_err(|_| MlsError::InvalidState)?,
    ) % 100_000_000;
    Ok(DeviceLinkVerification {
        transcript_hash,
        sas: format!("{sas_value:08}"),
        claim_tag,
        approval_tag,
        sas_bytes: sas_mac[..4].to_vec(),
    })
}

/// Fixed 128-bit input; only the one-way locator is sent to the server.
pub fn device_link_locator(secret: &[u8]) -> Result<Vec<u8>, MlsError> {
    if secret.len() != 16 {
        return Err(MlsError::InvalidIdentity);
    }
    Ok(Sha256::digest([b"veritra-link-locator-v2".as_slice(), secret].concat()).to_vec())
}

// HMAC (RFC 2104), followed by HKDF Extract/one-block Expand (RFC 5869).
// Keys here are at most 32 bytes; accept general keys for standard vectors.
fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut block = [0u8; 64];
    if key.len() > 64 {
        block[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let mut inner = Sha256::new();
    inner.update(block.map(|b| b ^ 0x36));
    inner.update(message);
    let mut outer = Sha256::new();
    outer.update(block.map(|b| b ^ 0x5c));
    outer.update(inner.finalize());
    outer.finalize().into()
}

fn link_mac(secret: &[u8], label: &[u8], transcript: &[u8]) -> [u8; 32] {
    let prk = hmac_sha256(&[0u8; 32], secret);
    let mut info = label.to_vec();
    info.push(1);
    let key = hmac_sha256(&prk, &info);
    hmac_sha256(&key, transcript)
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
    MlsGroupCreateConfig::builder()
        .padding_size(PADDING_BYTES)
        .use_ratchet_tree_extension(true)
        .ciphersuite(CIPHERSUITE)
        // After a membership change, a message sent in the previous epoch
        // can still arrive after the commit (card I51). Two past epochs are
        // kept for decryption only.
        .max_past_epochs(2)
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

/// The structural checks a remote commit must pass before it is merged.
/// Who may commit, and whether an identity really belongs to its signing
/// key, needs a trust anchor (L1) and is not decided here.
///
/// - Only Add, Remove and Update proposals: Veritra sends nothing else.
/// - Every credential it brings in is a Basic credential holding a
///   well-formed device identity.
/// - An added identity appears once in the roster the commit produces.
/// - An update (proposal or update path) keeps the leaf's identity.
fn inspect_commit(
    group: &MlsGroup,
    committer: LeafNodeIndex,
    staged: &StagedCommit,
) -> Result<(), MlsError> {
    let refused = MlsError::InvalidIdentity;
    if staged.queued_proposals().any(|proposal| {
        !matches!(
            proposal.proposal(),
            Proposal::Add(_) | Proposal::Remove(_) | Proposal::Update(_)
        )
    }) {
        return Err(MlsError::UnexpectedMessage);
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

    let keeps_identity = |leaf: LeafNodeIndex, credential: &Credential| {
        let current = group.member_at(leaf).ok_or(refused)?;
        if basic_identity(credential)? != current.credential.serialized_content() {
            return Err(refused);
        }
        Ok(())
    };
    for update in staged.update_proposals() {
        let Sender::Member(leaf) = *update.sender() else {
            return Err(refused);
        };
        keeps_identity(leaf, update.update_proposal().leaf_node().credential())?;
    }
    if let Some(leaf_node) = staged.update_path_leaf_node() {
        keeps_identity(committer, leaf_node.credential())?;
    }
    Ok(())
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
        group
            .add_members(
                &alice.provider,
                &alice.signer,
                &[
                    raw_key_package(&bob),
                    raw_key_package(&twin),
                    raw_key_package(&carol),
                ],
            )
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
        group
            .add_members(
                &alice.provider,
                &alice.signer,
                &[raw_key_package(&bob), raw_key_package(&twin)],
            )
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
            let (commit, _, _) = groups[1]
                .add_members(
                    &bob.provider,
                    &bob.signer,
                    &[forged_key_package(b"garbage")],
                )
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
            let (commit, _, _) = groups[1]
                .add_members(
                    &bob.provider,
                    &bob.signer,
                    &[forged_key_package(&carol_identity)],
                )
                .unwrap();
            commit.tls_serialize_detached().unwrap()
        };
        assert_refused_then_recovers(&devices, &mut groups, b"conv_twin_add", &commit);

        // The same new identity twice in one commit.
        let dave = encode_device_identity(b"acct_dave", b"dev_dave").unwrap();
        let commit = {
            let [_, bob, _] = &devices;
            let (commit, _, _) = groups[1]
                .add_members(
                    &bob.provider,
                    &bob.signer,
                    &[forged_key_package(&dave), forged_key_package(&dave)],
                )
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
            groups[1]
                .self_update(&bob.provider, &bob.signer, parameters)
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
        let (_, welcome, _) = group
            .add_members(&alice.provider, &alice.signer, packages)
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

    #[test]
    fn device_link_sas_is_credential_bound_and_symmetric() {
        let existing = MlsDevice::new(b"account-vector", b"device-existing").unwrap();
        let new = MlsDevice::new(b"account-vector", b"device-new").unwrap();
        let nonce = [0x42; 32];
        let from_existing = existing
            .derive_device_link_verification(
                DEVICE_LINK_PROTOCOL_VERSION,
                b"https://example.test",
                b"link_01",
                &[0x55; 16],
                b"device-new",
                new.signing_public_key(),
                &nonce,
                true,
            )
            .unwrap();
        let from_new = new
            .derive_device_link_verification(
                DEVICE_LINK_PROTOCOL_VERSION,
                b"https://example.test",
                b"link_01",
                &[0x55; 16],
                b"device-existing",
                existing.signing_public_key(),
                &nonce,
                false,
            )
            .unwrap();
        assert_eq!(from_existing, from_new);

        let mut substituted_key = new.signing_public_key().to_vec();
        substituted_key[0] ^= 1;
        let substituted = existing
            .derive_device_link_verification(
                DEVICE_LINK_PROTOCOL_VERSION,
                b"https://example.test",
                b"link_01",
                &[0x55; 16],
                b"device-new",
                &substituted_key,
                &nonce,
                true,
            )
            .unwrap();
        assert_ne!(from_existing, substituted);

        let mismatched_nonce = existing
            .derive_device_link_verification(
                DEVICE_LINK_PROTOCOL_VERSION,
                b"https://example.test",
                b"link_01",
                &[0x55; 16],
                b"device-new",
                new.signing_public_key(),
                &[0x43; 32],
                true,
            )
            .unwrap();
        assert_ne!(from_existing, mismatched_nonce);
        assert_eq!(
            existing.derive_device_link_verification(
                b"veritra-device-link-v1",
                b"https://example.test",
                b"link_01",
                &[0x55; 16],
                b"device-new",
                new.signing_public_key(),
                &nonce,
                true,
            ),
            Err(MlsError::InvalidIdentity)
        );
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
    fn link_hmac_and_hkdf_match_rfc_vectors() {
        assert_eq!(
            hmac_sha256(&[0x0b; 20], b"Hi There").to_vec(),
            vec![
                0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53, 0x5c, 0xa8, 0xaf, 0xce, 0xaf, 0x0b,
                0xf1, 0x2b, 0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7, 0x26, 0xe9, 0x37, 0x6c,
                0x2e, 0x32, 0xcf, 0xf7
            ]
        );
        assert_eq!(
            hmac_sha256(
                &[0xaa; 131],
                b"Test Using Larger Than Block-Size Key - Hash Key First"
            )
            .to_vec(),
            vec![
                0x60, 0xe4, 0x31, 0x59, 0x1e, 0xe0, 0xb6, 0x7f, 0x0d, 0x8a, 0x26, 0xaa, 0xcb, 0xf5,
                0xb7, 0x7f, 0x8e, 0x0b, 0xc6, 0x21, 0x37, 0x28, 0xc5, 0x14, 0x05, 0x46, 0x04, 0x0f,
                0x0e, 0xe3, 0x7f, 0x54
            ]
        );
        let prk = hmac_sha256(&[0; 32], &[0x0b; 22]);
        assert_eq!(
            prk.to_vec(),
            vec![
                0x19, 0xef, 0x24, 0xa3, 0x2c, 0x71, 0x7b, 0x16, 0x7f, 0x33, 0xa9, 0x1d, 0x6f, 0x64,
                0x8b, 0xdf, 0x96, 0x59, 0x67, 0x76, 0xaf, 0xdb, 0x63, 0x77, 0xac, 0x43, 0x4c, 0x1c,
                0x29, 0x3c, 0xcb, 0x04
            ]
        );
        assert_eq!(
            hmac_sha256(&prk, &[1]).to_vec(),
            vec![
                0x8d, 0xa4, 0xe7, 0x75, 0xa5, 0x63, 0xc1, 0x8f, 0x71, 0x5f, 0x80, 0x2a, 0x06, 0x3c,
                0x5a, 0x31, 0xb8, 0xa1, 0x1f, 0x5c, 0x5e, 0xe1, 0x87, 0x9e, 0xc3, 0x45, 0x4e, 0x5f,
                0x3c, 0x73, 0x8d, 0x2d
            ]
        );
    }

    #[test]
    fn link_v2_binds_every_context_field_and_separates_directions() {
        let fields: Vec<Vec<u8>> = vec![
            DEVICE_LINK_PROTOCOL_VERSION.to_vec(),
            b"https://example.test".to_vec(),
            b"link_01".to_vec(),
            vec![0x55; 16],
            b"acct_01".to_vec(),
            vec![0x11; 32],
            b"dev_old".to_vec(),
            vec![0x22; 32],
            b"dev_new".to_vec(),
            vec![0x33; 32],
        ];
        let derive = |f: &[Vec<u8>]| {
            derive_device_link_verification(
                &f[0], &f[1], &f[2], &f[3], &f[4], &f[5], &f[6], &f[7], &f[8], &f[9],
            )
        };
        let expected = derive(&fields).unwrap();
        assert_ne!(expected.claim_tag, expected.approval_tag);
        for i in 0..fields.len() {
            let mut changed = fields.clone();
            changed[i][0] ^= 1;
            match derive(&changed) {
                Ok(actual) => {
                    assert_ne!(expected.claim_tag, actual.claim_tag);
                    assert_ne!(expected.approval_tag, actual.approval_tag);
                }
                Err(e) => assert_eq!(e, MlsError::InvalidIdentity),
            }
        }
        for length in [0, 15, 17] {
            let mut changed = fields.clone();
            changed[3] = vec![1; length];
            assert_eq!(derive(&changed), Err(MlsError::InvalidIdentity));
        }
    }

    #[test]
    fn a_relay_cannot_compute_the_sas_from_public_link_data() {
        // TASK-010/TASK-048: grinding needs the SAS as a function of values
        // the relay sees. Two secrets give the same public transcript hash
        // but unrelated SAS values and tags, so a relay without the secret
        // has nothing to grind against.
        let derive = |secret: &[u8], new_key: &[u8]| {
            derive_device_link_verification(
                DEVICE_LINK_PROTOCOL_VERSION,
                b"https://example.test",
                b"link_01",
                secret,
                b"acct_01",
                &[0x11; 32],
                b"dev_old",
                &[0x22; 32],
                b"dev_new",
                new_key,
            )
            .unwrap()
        };
        let real = derive(&[0x55; 16], &[0x33; 32]);
        let guessed = derive(&[0x56; 16], &[0x33; 32]);
        assert_eq!(real.transcript_hash, guessed.transcript_hash);
        assert_ne!(real.sas_bytes, guessed.sas_bytes);
        assert_ne!(real.claim_tag, guessed.claim_tag);
        assert_ne!(real.approval_tag, guessed.approval_tag);
        // A substituted new-device key needs a fresh claim tag under the
        // secret; the old device rejects the honest one for it.
        let substituted = derive(&[0x55; 16], &[0x34; 32]);
        assert_ne!(real.claim_tag, substituted.claim_tag);
        assert_eq!(real.sas.len(), 8);
    }

    #[test]
    fn device_link_transcript_has_a_stable_vector() {
        let verification = derive_device_link_verification(
            DEVICE_LINK_PROTOCOL_VERSION,
            b"https://example.test",
            b"link_01",
            &[0x55; 16],
            b"acct_01",
            &[0x11; 32],
            b"dev_old",
            &[0x22; 32],
            b"dev_new",
            &[0x33; 32],
        )
        .unwrap();
        assert_eq!(
            verification.transcript_hash,
            vec![
                0x9b, 0xba, 0xf8, 0xd8, 0xf6, 0x05, 0x79, 0x2d, 0xae, 0xa6, 0xc0, 0x2d, 0x88, 0x4a,
                0x4e, 0x12, 0x4d, 0x26, 0x34, 0x61, 0xb9, 0x4c, 0xca, 0xd6, 0xf8, 0x04, 0xb6, 0x74,
                0xc0, 0x10, 0x96, 0xd8
            ]
        );
        assert_eq!(
            verification.claim_tag,
            vec![
                0x44, 0x6c, 0xdb, 0xea, 0x4d, 0x4b, 0xfa, 0x24, 0xd7, 0x0c, 0xda, 0xc8, 0x39, 0xde,
                0x69, 0xc6, 0x49, 0x04, 0x91, 0x4f, 0x32, 0x32, 0x77, 0xdc, 0xb1, 0xcb, 0xc2, 0x1e,
                0xe3, 0xed, 0x6e, 0x9f
            ]
        );
        assert_eq!(
            verification.approval_tag,
            vec![
                0xfc, 0x82, 0xfe, 0x05, 0x43, 0xa9, 0x2b, 0x13, 0xb4, 0x54, 0xe3, 0x88, 0xa6, 0x86,
                0x71, 0xe0, 0xe3, 0x58, 0x72, 0x05, 0x34, 0x28, 0x1e, 0x88, 0xd8, 0x89, 0x5b, 0xf5,
                0x4b, 0x97, 0x88, 0x11
            ]
        );
        assert_eq!(verification.sas, "94112245");
        assert_eq!(
            device_link_locator(&[0x55; 16]).unwrap(),
            vec![
                0x89, 0x6e, 0x62, 0x7a, 0x33, 0x81, 0xce, 0x62, 0x5a, 0x8b, 0x3f, 0xd2, 0x0a, 0xd0,
                0x90, 0xb4, 0x44, 0xa8, 0x8c, 0x0a, 0x20, 0x1c, 0x3c, 0x8f, 0xa5, 0xb6, 0xa6, 0xf1,
                0x6a, 0x48, 0xe2, 0x5a
            ]
        );
    }
}
