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
use sha2::{Digest, Sha256};
use tls_codec::{Deserialize as TlsDeserializeTrait, Serialize as TlsSerializeTrait};

mod state;

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const MAX_ID_BYTES: usize = 128;
const PADDING_BYTES: usize = 256;
const CREDENTIAL_FORMAT_VERSION: u8 = 1;
const DEVICE_LINK_PROTOCOL_VERSION: &[u8] = b"veritra-device-link-v1";
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
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceLinkVerification {
    pub transcript_hash: Vec<u8>,
    pub sas: String,
}

impl MlsDevice {
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

    pub fn derive_device_link_verification(
        &self,
        protocol_version: &[u8],
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
            &self.account_id,
            link_nonce,
            existing_device_id,
            existing_key,
            new_device_id,
            new_key,
        )
    }

    /// Signs a server challenge with the same Ed25519 identity key carried by
    /// this device's MLS credential. The server must domain-separate and bind
    /// the challenge to its reserved account and device identifiers.
    pub fn sign_enrollment_challenge(&self, challenge: &[u8]) -> Result<Vec<u8>, MlsError> {
        if challenge.is_empty() {
            return Err(MlsError::InvalidIdentity);
        }
        self.signer
            .sign(challenge)
            .map_err(|_| MlsError::KeyGeneration)
    }

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
        let challenge_signature = self.sign_enrollment_challenge(&proof)?;
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
        }
        let mut removed = Vec::with_capacity(removes.len());
        for member in removes {
            removed.push(self.member_index(group, member.account_id, member.device_id)?);
        }
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

    pub fn remove_member(
        &self,
        group: &mut MlsGroup,
        member: LeafNodeIndex,
    ) -> Result<Vec<u8>, MlsError> {
        let (commit, _, _) = group
            .remove_members(&self.provider, &self.signer, &[member])
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
        let ProcessedMessageContent::StagedCommitMessage(staged_commit) = processed.into_content()
        else {
            return Err(MlsError::UnexpectedMessage);
        };
        group
            .merge_staged_commit(&self.provider, *staged_commit)
            .map_err(|_| MlsError::GroupOperation)
    }

    pub fn member_index(
        &self,
        group: &MlsGroup,
        account_id: &[u8],
        device_id: &[u8],
    ) -> Result<LeafNodeIndex, MlsError> {
        let identity = encode_device_identity(account_id, device_id)?;
        group
            .members()
            .find(|member| member.credential.serialized_content() == identity)
            .map(|member| member.index)
            .ok_or(MlsError::InvalidIdentity)
    }

    pub fn conversation_safety_number(
        &self,
        group: &MlsGroup,
    ) -> Result<DeviceLinkVerification, MlsError> {
        let mut members = group
            .members()
            .map(|member| {
                let mut value = Vec::new();
                append_transcript_field(&mut value, member.credential.serialized_content())?;
                append_transcript_field(&mut value, member.signature_key.as_slice())?;
                Ok(value)
            })
            .collect::<Result<Vec<_>, MlsError>>()?;
        members.sort();
        let mut transcript = Vec::new();
        append_transcript_field(&mut transcript, b"veritra-conversation-safety-v1")?;
        append_transcript_field(&mut transcript, group.group_id().as_slice())?;
        append_transcript_field(&mut transcript, &group.epoch().as_u64().to_be_bytes())?;
        for member in members {
            append_transcript_field(&mut transcript, &member)?;
        }
        let transcript_hash = Sha256::digest(&transcript).to_vec();
        let sas_value = u64::from_be_bytes(
            transcript_hash[..8]
                .try_into()
                .map_err(|_| MlsError::InvalidState)?,
        ) % 1_000_000_000_000;
        Ok(DeviceLinkVerification {
            transcript_hash,
            sas: format!("{sas_value:012}"),
        })
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
        let group = StagedWelcome::new_from_welcome(
            &self.provider,
            group_create_config().join_config(),
            welcome,
            None,
        )
        .map_err(|_| MlsError::GroupOperation)?
        .into_group(&self.provider)
        .map_err(|_| MlsError::GroupOperation)?;
        if group.group_id().as_slice() != expected_group_id {
            return Err(MlsError::InvalidMessage);
        }
        Ok(group)
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
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) if sender_matches => {
                Ok(message.into_bytes())
            }
            ProcessedMessageContent::ApplicationMessage(_) => Err(MlsError::SenderMismatch),
            _ => Err(MlsError::UnexpectedMessage),
        }
    }
}

pub fn derive_device_link_verification(
    protocol_version: &[u8],
    account_id: &[u8],
    link_nonce: &[u8],
    existing_device_id: &[u8],
    existing_signing_public_key: &[u8],
    new_device_id: &[u8],
    new_signing_public_key: &[u8],
) -> Result<DeviceLinkVerification, MlsError> {
    if protocol_version != DEVICE_LINK_PROTOCOL_VERSION
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
    append_transcript_field(&mut transcript, account_id)?;
    append_transcript_field(&mut transcript, link_nonce)?;
    append_transcript_field(&mut transcript, existing_device_id)?;
    append_transcript_field(&mut transcript, existing_signing_public_key)?;
    append_transcript_field(&mut transcript, new_device_id)?;
    append_transcript_field(&mut transcript, new_signing_public_key)?;
    let transcript_hash = Sha256::digest(&transcript).to_vec();
    let sas_value = u32::from_be_bytes(
        transcript_hash[..4]
            .try_into()
            .map_err(|_| MlsError::InvalidState)?,
    ) % 100_000_000;
    Ok(DeviceLinkVerification {
        transcript_hash,
        sas: format!("{sas_value:08}"),
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

        let bob_index = alice
            .member_index(&alice_group, b"acct_bob", b"dev_bob")
            .unwrap();
        let removal = alice.remove_member(&mut alice_group, bob_index).unwrap();
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
    fn enrollment_challenge_uses_mls_credential_signer() {
        let device = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let signature = device
            .sign_enrollment_challenge(b"veritra-enrollment-v1 challenge")
            .unwrap();
        assert_eq!(device.signing_public_key().len(), 32);
        assert_eq!(signature.len(), 64);
        assert_eq!(
            device.sign_enrollment_challenge(b""),
            Err(MlsError::InvalidIdentity)
        );
        let enrollment = device
            .create_enrollment_credential(b"reserved server challenge")
            .unwrap();
        assert!(enrollment.key_package.len() >= crate::MIN_KEY_PACKAGE_BYTES);
        assert_eq!(enrollment.signing_public_key, device.signing_public_key());
        assert_eq!(enrollment.challenge_signature.len(), 64);
    }

    #[test]
    fn device_link_sas_is_credential_bound_and_symmetric() {
        let existing = MlsDevice::new(b"account-vector", b"device-existing").unwrap();
        let new = MlsDevice::new(b"account-vector", b"device-new").unwrap();
        let nonce = [0x42; 32];
        let from_existing = existing
            .derive_device_link_verification(
                DEVICE_LINK_PROTOCOL_VERSION,
                b"device-new",
                new.signing_public_key(),
                &nonce,
                true,
            )
            .unwrap();
        let from_new = new
            .derive_device_link_verification(
                DEVICE_LINK_PROTOCOL_VERSION,
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
                b"device-new",
                new.signing_public_key(),
                &[0x43; 32],
                true,
            )
            .unwrap();
        assert_ne!(from_existing, mismatched_nonce);
        assert_eq!(
            existing.derive_device_link_verification(
                b"veritra-device-link-v2",
                b"device-new",
                new.signing_public_key(),
                &nonce,
                true,
            ),
            Err(MlsError::InvalidIdentity)
        );
    }

    #[test]
    fn device_link_transcript_has_a_stable_vector() {
        let verification = derive_device_link_verification(
            DEVICE_LINK_PROTOCOL_VERSION,
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
                0x8c, 0xce, 0x0b, 0x98, 0x04, 0x9c, 0xcb, 0xd2, 0x0f, 0xb4, 0x97, 0x73, 0x2f, 0xb8,
                0xe2, 0xc2, 0x06, 0x07, 0xb5, 0x93, 0xfa, 0xc2, 0x9f, 0xa8, 0xf3, 0xd4, 0x46, 0x31,
                0x12, 0x24, 0xf0, 0x43,
            ]
        );
        assert_eq!(verification.sas, "62313624");
    }
}
