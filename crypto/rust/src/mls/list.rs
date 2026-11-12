//! L1 (ABI 14): what the device does with the approved-device list. The
//! format and every rule live in `crate::l1`; this file holds the three
//! things that need the device itself: signing as the device, the sealed
//! recovery-signing seed a waiting recovered phone keeps, and reading
//! leaves as `(account, device, key)` triples.

use super::{decode_device_identity, MlsDevice, MlsError};
use crate::{
    l1::{self, Change, L1Error, Signer},
    recovery,
};
use openmls::prelude::{Credential, MlsGroup};
use openmls_traits::signatures::Signer as _;
use tls_codec::SecretVLBytes;

/// The account, device and credential signature key of one leaf.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LeafPair {
    pub account_id: Vec<u8>,
    pub device_id: Vec<u8>,
    pub signing_key: Vec<u8>,
}

impl LeafPair {
    pub(crate) fn from_credential(credential: &Credential, key: &[u8]) -> Result<Self, MlsError> {
        let (account_id, device_id) = decode_device_identity(credential.serialized_content())?;
        Ok(Self {
            account_id: account_id.to_vec(),
            device_id: device_id.to_vec(),
            signing_key: key.to_vec(),
        })
    }

    pub fn as_triple(&self) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        (
            self.account_id.clone(),
            self.device_id.clone(),
            self.signing_key.clone(),
        )
    }
}

/// Why a recovery signature was not made.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoverySignError {
    /// Neither a held seed nor typed entropy was available.
    NoSeed,
    /// The body or the step was refused (the signature is never returned).
    Refused(L1Error),
    /// A bad argument or a crypto failure.
    Failed,
}

/// The sealed record's held-seed section: `"VL1H" | u8 1 | [32] seed`.
pub(crate) const HELD_SECTION_MAGIC: &[u8; 4] = b"VL1H";
pub(crate) const HELD_SECTION_BYTES: usize = 4 + 1 + recovery::LIST_SEED_BYTES;

pub(crate) fn encode_held_section(seed: &SecretVLBytes) -> SecretVLBytes {
    let mut out = SecretVLBytes::new(Vec::with_capacity(HELD_SECTION_BYTES));
    for byte in HELD_SECTION_MAGIC
        .iter()
        .chain([1u8].iter())
        .chain(seed.as_slice())
    {
        out.push(*byte);
    }
    out
}

pub(crate) fn decode_held_section(bytes: &[u8]) -> Result<Option<SecretVLBytes>, MlsError> {
    if bytes.is_empty() {
        return Ok(None);
    }
    if bytes.len() != HELD_SECTION_BYTES || &bytes[..4] != HELD_SECTION_MAGIC || bytes[4] != 1 {
        return Err(MlsError::InvalidState);
    }
    Ok(Some(SecretVLBytes::new(bytes[5..].to_vec())))
}

/// L2-3 (ABI 26): the sealed record's franking-key section, after the held
/// seed: `"VFK1" | u8 1 | [32] secret`. A record written before it has
/// none, and the device makes its key when it is restored.
pub(crate) const FRANK_SECTION_MAGIC: &[u8; 4] = b"VFK1";
pub(crate) const FRANK_SECTION_BYTES: usize = 4 + 1 + 32;

pub(crate) fn encode_frank_section(secret: &[u8; 32]) -> SecretVLBytes {
    let mut out = SecretVLBytes::new(Vec::with_capacity(FRANK_SECTION_BYTES));
    for byte in FRANK_SECTION_MAGIC
        .iter()
        .chain([1u8].iter())
        .chain(secret.iter())
    {
        out.push(*byte);
    }
    out
}

/// The device record's sections after the transfers: an optional held
/// seed, then an optional franking secret, in that order and nothing else.
pub(crate) fn decode_device_sections(
    bytes: &[u8],
) -> Result<(Option<SecretVLBytes>, Option<x25519_dalek::StaticSecret>), MlsError> {
    let (held, frank) = if bytes.starts_with(HELD_SECTION_MAGIC) {
        if bytes.len() < HELD_SECTION_BYTES {
            return Err(MlsError::InvalidState);
        }
        bytes.split_at(HELD_SECTION_BYTES)
    } else {
        (&bytes[..0], bytes)
    };
    let held = decode_held_section(held)?;
    if frank.is_empty() {
        return Ok((held, None));
    }
    if frank.len() != FRANK_SECTION_BYTES || &frank[..4] != FRANK_SECTION_MAGIC || frank[4] != 1 {
        return Err(MlsError::InvalidState);
    }
    let secret =
        crate::l2_frank::secret_from_bytes(&frank[5..]).map_err(|_| MlsError::InvalidState)?;
    Ok((held, Some(secret)))
}

impl MlsDevice {
    /// Signs a device-list body as this device (signer kind 1) and returns
    /// the 64-byte signature over
    /// `"veritra-l1-device-list-sig-v1" | SHA-256(body) | 0x01 | lp(own id)`.
    ///
    /// The body is parsed strictly first. It must name this device's own
    /// account, and a genesis (change 1) must list exactly this device and
    /// its own key; a migration genesis (change 6) must list this device with
    /// its own key. A franking key the body lists for this device must be
    /// this device's own (L2-3), and change 7 must list it. The rest of the
    /// rules need the previous version and are checked by
    /// [`l1::check_step`] before a version is used.
    pub fn l1_sign_device_list(&self, body: &[u8]) -> Result<Vec<u8>, MlsError> {
        let parsed = l1::parse_body(body).map_err(|_| MlsError::InvalidMessage)?;
        if parsed.account_id != self.account_id {
            return Err(MlsError::InvalidIdentity);
        }
        let own_frank = parsed.frank_key(&self.device_id);
        if own_frank.is_some_and(|key| *key != self.l2_frank_public_key()) {
            return Err(MlsError::InvalidIdentity);
        }
        let own_pair = |pair: &l1::Pair| {
            pair.device_id == self.device_id
                && pair.signing_key.as_slice() == self.signing_public_key()
        };
        match parsed.change {
            Change::Genesis => {
                if parsed.entries.len() != 1 || !own_pair(&parsed.entries[0]) {
                    return Err(MlsError::InvalidIdentity);
                }
            }
            Change::MigrationGenesis => {
                if !parsed.entries.iter().any(own_pair) {
                    return Err(MlsError::InvalidIdentity);
                }
            }
            // A device that is not on the previous version cannot sign for
            // it; the verifier refuses such a statement.
            Change::Add | Change::Remove | Change::RecoveryKey => {}
            Change::FrankKey => {
                if own_frank.is_none() {
                    return Err(MlsError::InvalidIdentity);
                }
            }
            // Only the recovery key signs a recovery version.
            Change::Recovery => return Err(MlsError::InvalidIdentity),
        }
        let message = l1::signed_message(body, &Signer::Device(self.device_id.clone()))
            .map_err(|_| MlsError::InvalidMessage)?;
        self.signer
            .sign(&message)
            .map_err(|_| MlsError::GroupOperation)
    }

    /// Keeps the device-list recovery seed derived from the typed RK entropy
    /// in the sealed device record, for a recovered phone that waits out the
    /// recovery delay (D94, owner question 1). The entropy is not kept and
    /// the seed never leaves Rust. An older library refuses a record that
    /// holds one (fail closed).
    pub fn hold_recovery_list_seed(&mut self, entropy: &[u8]) -> Result<(), MlsError> {
        let seed = recovery::list_seed(entropy).map_err(|_| MlsError::InvalidIdentity)?;
        self.held_list_seed = Some(seed);
        Ok(())
    }

    /// The public key of the held seed, when one is held.
    pub fn held_recovery_list_public(&self) -> Result<Option<[u8; 32]>, MlsError> {
        self.held_list_seed
            .as_ref()
            .map(|seed| recovery::list_public(seed.as_slice()).map_err(|_| MlsError::InvalidState))
            .transpose()
    }

    /// Forgets the held seed (a cancelled or expired claim). `true` when one
    /// was held.
    pub fn drop_recovery_list_hold(&mut self) -> bool {
        self.held_list_seed.take().is_some()
    }

    /// Signs change 4 (a recovery version) with the recovery-derived key:
    /// the held seed when `entropy` is `None`, else the seed derived from the
    /// typed entropy. Returns the whole statement.
    ///
    /// The body must be a change-4 version for this device's account listing
    /// exactly this device with its own key, and the finished statement must
    /// pass [`l1::check_step`] against `prev` (the head at completion) and
    /// `history`, so a signature is never made for a version the chain
    /// would refuse (the head's recovery key differing from the seed's
    /// included). A held seed is dropped once the statement is made; it can
    /// sign this one thing.
    pub fn l1_sign_recovery(
        &mut self,
        prev: &[u8],
        history: &[l1::Pair],
        body: &[u8],
        entropy: Option<&[u8]>,
    ) -> Result<Vec<u8>, RecoverySignError> {
        let refused = RecoverySignError::Refused;
        let parsed = l1::parse_body(body).map_err(refused)?;
        let prev = l1::parse_statement(prev).map_err(refused)?;
        if parsed.change != Change::Recovery
            || parsed.account_id != self.account_id
            || parsed.entries.len() != 1
            || parsed.entries[0].device_id != self.device_id
            || parsed.entries[0].signing_key.as_slice() != self.signing_public_key()
            || parsed
                .frank_key(&self.device_id)
                .is_some_and(|key| *key != self.l2_frank_public_key())
        {
            return Err(refused(L1Error::Rule));
        }
        let derived;
        let seed: &[u8] = match entropy {
            Some(entropy) => {
                derived = recovery::list_seed(entropy).map_err(|_| RecoverySignError::Failed)?;
                derived.as_slice()
            }
            None => self
                .held_list_seed
                .as_ref()
                .ok_or(RecoverySignError::NoSeed)?
                .as_slice(),
        };
        let message = l1::signed_message(body, &Signer::Recovery).map_err(refused)?;
        let signature =
            recovery::list_sign(seed, &message).map_err(|_| RecoverySignError::Failed)?;
        let statement =
            l1::assemble_statement(body, &Signer::Recovery, &signature).map_err(refused)?;
        let parsed_statement = l1::parse_statement(&statement).map_err(refused)?;
        l1::check_step(&self.account_id, Some(&prev), &parsed_statement, history)
            .map_err(refused)?;
        if entropy.is_none() {
            self.held_list_seed = None;
        }
        Ok(statement)
    }

    /// Every leaf of `group` as `(account, device, signature key)`, in leaf
    /// order. Duplicate identities are listed as they are.
    pub fn group_leaf_pairs(&self, group: &MlsGroup) -> Result<Vec<LeafPair>, MlsError> {
        group
            .members()
            .map(|member| LeafPair::from_credential(&member.credential, &member.signature_key))
            .collect()
    }
}
