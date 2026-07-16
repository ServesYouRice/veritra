//! OpenMLS core operations.
//!
//! This module is intentionally not exposed through the C ABI yet. It proves
//! the selected library and protocol flow while platform key wrapping and ABI
//! ownership semantics are still under review.

use openmls::prelude::*;
use openmls::treesync::LeafNodeParameters;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::OpenMlsProvider;
use tls_codec::{Deserialize as TlsDeserializeTrait, Serialize as TlsSerializeTrait};

mod state;

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
const MAX_ID_BYTES: usize = 128;
const PADDING_BYTES: usize = 256;
const CREDENTIAL_FORMAT_VERSION: u8 = 1;

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
    ) -> Result<AddMemberMessages, MlsError> {
        let key_package = KeyPackageIn::tls_deserialize_exact(key_package_bytes)
            .map_err(|_| MlsError::InvalidKeyPackage)?
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(|_| MlsError::InvalidKeyPackage)?;
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

    pub fn join_group(&self, welcome_bytes: &[u8]) -> Result<MlsGroup, MlsError> {
        let message = MlsMessageIn::tls_deserialize_exact(welcome_bytes)
            .map_err(|_| MlsError::InvalidMessage)?;
        let MlsMessageBodyIn::Welcome(welcome) = message.extract() else {
            return Err(MlsError::UnexpectedMessage);
        };
        StagedWelcome::new_from_welcome(
            &self.provider,
            group_create_config().join_config(),
            welcome,
            None,
        )
        .map_err(|_| MlsError::GroupOperation)?
        .into_group(&self.provider)
        .map_err(|_| MlsError::GroupOperation)
    }

    pub fn encrypt(&self, group: &mut MlsGroup, plaintext: &[u8]) -> Result<Vec<u8>, MlsError> {
        group
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(|_| MlsError::GroupOperation)?
            .tls_serialize_detached()
            .map_err(|_| MlsError::GroupOperation)
    }

    pub fn decrypt(&self, group: &mut MlsGroup, ciphertext: &[u8]) -> Result<Vec<u8>, MlsError> {
        let protocol_message = MlsMessageIn::tls_deserialize_exact(ciphertext)
            .map_err(|_| MlsError::InvalidMessage)?
            .try_into_protocol_message()
            .map_err(|_| MlsError::InvalidMessage)?;
        let processed = group
            .process_message(&self.provider, protocol_message)
            .map_err(|_| MlsError::InvalidMessage)?;
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => Ok(message.into_bytes()),
            _ => Err(MlsError::UnexpectedMessage),
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
pub struct AddMemberMessages {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
}

fn group_create_config() -> MlsGroupCreateConfig {
    MlsGroupCreateConfig::builder()
        .padding_size(PADDING_BYTES)
        .use_ratchet_tree_extension(true)
        .ciphersuite(CIPHERSUITE)
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
            .add_member(&mut alice_group, &bob_key_package)
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let mut bob_group = bob.join_group(&add.welcome).unwrap();

        let alice_ciphertext = alice.encrypt(&mut alice_group, b"alice payload").unwrap();
        assert_ne!(alice_ciphertext, b"alice payload");
        assert_eq!(
            bob.decrypt(&mut bob_group, &alice_ciphertext).unwrap(),
            b"alice payload"
        );

        let bob_ciphertext = bob.encrypt(&mut bob_group, b"bob payload").unwrap();
        assert_ne!(bob_ciphertext, b"bob payload");
        assert_eq!(
            alice.decrypt(&mut alice_group, &bob_ciphertext).unwrap(),
            b"bob payload"
        );
    }

    #[test]
    fn malformed_or_foreign_messages_fail_closed() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let mut alice_group = alice.create_group(b"conv_alice").unwrap();
        let mut bob_group = bob.create_group(b"conv_bob").unwrap();

        assert_eq!(
            alice.decrypt(&mut alice_group, b"not an MLS message"),
            Err(MlsError::InvalidMessage)
        );
        let foreign = bob.encrypt(&mut bob_group, b"foreign").unwrap();
        assert_eq!(
            alice.decrypt(&mut alice_group, &foreign),
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
            .add_member(&mut alice_group, &bob_key_package)
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let mut bob_group = bob.join_group(&add.welcome).unwrap();

        let update = bob.self_update(&mut bob_group).unwrap();
        bob.merge_pending_commit(&mut bob_group).unwrap();
        alice.process_commit(&mut alice_group, &update).unwrap();
        let after_update = bob.encrypt(&mut bob_group, b"after update").unwrap();
        assert_eq!(
            alice.decrypt(&mut alice_group, &after_update).unwrap(),
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
            alice.add_member(&mut group, b"not a key package"),
            Err(MlsError::InvalidKeyPackage)
        );
    }
}
