//! Durable native transfer contexts. No public ABI exposes private material.

use super::{
    link_v3::{self, LinkContext},
    DeviceLinkVerification, MlsDevice, MlsError,
};
use crate::history::{self, FileSecrets, HandoffPayload, TransferContext, TransferKeyPair};
use openmls_traits::OpenMlsProvider;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use tls_codec::SecretVLBytes;

pub(super) const MAX_TRANSFERS: usize = 16;
pub(super) const MAX_TRANSFER_BYTES: usize = 12 * 1024;
const MAX_LINK_MS: u64 = 30 * 60 * 1000;
pub(crate) const TRANSFER_LIFETIME_MS: u64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Clone, Eq, PartialEq, Ord, PartialOrd)]
pub(crate) struct TransferId {
    pub origin: Vec<u8>,
    pub link_id: Vec<u8>,
}

impl TransferId {
    pub(crate) fn new(origin: &[u8], link_id: &[u8]) -> Self {
        Self {
            origin: origin.to_vec(),
            link_id: link_id.to_vec(),
        }
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub(crate) enum Direction {
    Outgoing = 1,
    Incoming = 2,
}
#[derive(Clone, Copy, Eq, PartialEq)]
pub(crate) enum Stage {
    WaitingApproval = 1,
    Approved = 2,
    Ready = 3,
    Delivered = 4,
}

pub(crate) struct SourceMaterial {
    pub secrets: FileSecrets,
    pub snapshot_counter: u64,
    pub header_sha256: [u8; 32],
    pub ciphertext_sha256: [u8; 32],
    pub ciphertext_size: u64,
}

pub(crate) struct SourceBundle {
    pub ciphertext: Vec<u8>,
    pub header_sha256: [u8; 32],
    pub ciphertext_sha256: [u8; 32],
    pub handoff: Vec<u8>,
    pub transfer_id: [u8; 64],
}

pub(crate) struct PendingTransfer {
    pub context: LinkContext,
    pub direction: Direction,
    pub stage: Stage,
    pub link_expires_at_ms: u64,
    pub approval_intent_at_ms: u64,
    pub approved_at_ms: u64,
    pub expires_at_ms: u64,
    pub verification: DeviceLinkVerification,
    link_key: SecretVLBytes,
    transfer_key: Option<TransferKeyPair>,
    source_material: Option<SourceMaterial>,
    verified_handoff_sha256: Option<[u8; 32]>,
}

pub(super) type PendingTransfers = BTreeMap<TransferId, PendingTransfer>;

fn invalid<T>(_: T) -> MlsError {
    MlsError::InvalidState
}

impl PendingTransfer {
    fn validate(
        &self,
        account: &[u8],
        device: &[u8],
        signing: &[u8],
        provider: &impl OpenMlsProvider,
    ) -> Result<(), MlsError> {
        self.context.validate()?;
        let (own_id, own_key) = match self.direction {
            Direction::Outgoing => (
                &self.context.source_device_id,
                &self.context.source_signing_key,
            ),
            Direction::Incoming => (
                &self.context.recipient_device_id,
                &self.context.recipient_signing_key,
            ),
        };
        if self.context.account_id != account
            || own_id != device
            || own_key != signing
            || self.link_key.as_slice().len() != 32
            || self.link_expires_at_ms == 0
            || self
                .link_expires_at_ms
                .checked_add(TRANSFER_LIFETIME_MS)
                .is_none()
            || self.expires_at_ms == 0
            || self.verification.transcript_hash != self.context.transcript_hash()?
            || self.verification.claim_tag.len() != 32
            || self.verification.approval_tag.len() != 32
            || self.verification.sas_bytes.len() != 4
        {
            return Err(MlsError::InvalidState);
        }
        let sas = u32::from_be_bytes(
            self.verification
                .sas_bytes
                .as_slice()
                .try_into()
                .map_err(invalid)?,
        ) % 100_000_000;
        if self.verification.sas != format!("{sas:08}") {
            return Err(MlsError::InvalidState);
        }
        if (self.stage == Stage::WaitingApproval) != (self.approved_at_ms == 0) {
            return Err(MlsError::InvalidState);
        }
        if self.stage == Stage::WaitingApproval && self.expires_at_ms != self.link_expires_at_ms {
            return Err(MlsError::InvalidState);
        }
        if self.approval_intent_at_ms > self.link_expires_at_ms
            || (self.direction == Direction::Incoming && self.approval_intent_at_ms != 0)
            || (self.direction == Direction::Outgoing
                && self.stage != Stage::WaitingApproval
                && self.approval_intent_at_ms == 0)
        {
            return Err(MlsError::InvalidState);
        }
        if self.approved_at_ms != 0
            && (self.approved_at_ms > self.link_expires_at_ms
                || self.approved_at_ms.checked_add(TRANSFER_LIFETIME_MS)
                    != Some(self.expires_at_ms))
        {
            return Err(MlsError::InvalidState);
        }
        match self.direction {
            Direction::Outgoing => {
                if self.transfer_key.is_some()
                    || self.verified_handoff_sha256.is_some()
                    || self.source_material.is_some()
                        != matches!(self.stage, Stage::Ready | Stage::Delivered)
                {
                    return Err(MlsError::InvalidState);
                }
                if let Some(material) = &self.source_material {
                    validate_material(material)?;
                }
            }
            Direction::Incoming => {
                if self.source_material.is_some() {
                    return Err(MlsError::InvalidState);
                }
                if self.verified_handoff_sha256.is_some()
                    != matches!(self.stage, Stage::Ready | Stage::Delivered)
                {
                    return Err(MlsError::InvalidState);
                }
                let key = self.transfer_key.as_ref().ok_or(MlsError::InvalidState)?;
                if key.public_key() != self.context.transfer_public_key {
                    return Err(MlsError::InvalidState);
                }
                // Full pair self-check is performed on untrusted deserialization,
                // not on every state update of an already checked in-memory key.
                let _ = provider;
            }
        }
        Ok(())
    }

    fn public_context(&self) -> Result<TransferContext<'_>, MlsError> {
        Ok(TransferContext {
            server_origin: &self.context.origin,
            link_id: &self.context.link_id,
            account_id: &self.context.account_id,
            source_device_id: &self.context.source_device_id,
            source_signing_key: &self.context.source_signing_key,
            recipient_device_id: &self.context.recipient_device_id,
            recipient_signing_key: &self.context.recipient_signing_key,
            transfer_public_key: &self.context.transfer_public_key,
            transcript_hash: self
                .verification
                .transcript_hash
                .as_slice()
                .try_into()
                .map_err(invalid)?,
        })
    }

    fn live(&self, now_ms: u64) -> Result<(), MlsError> {
        if now_ms == 0 || now_ms >= self.expires_at_ms {
            Err(MlsError::InvalidState)
        } else {
            Ok(())
        }
    }

    fn retention_deadline(&self) -> u64 {
        if self.stage == Stage::WaitingApproval {
            self.link_expires_at_ms.saturating_add(TRANSFER_LIFETIME_MS)
        } else {
            self.expires_at_ms
        }
    }
}

fn validate_material(material: &SourceMaterial) -> Result<(), MlsError> {
    if material.snapshot_counter == 0
        || material.ciphertext_size == 0
        || material.ciphertext_size > (history::MAX_PADDED_HISTORY + 64 * 20 + 416) as u64
    {
        return Err(MlsError::InvalidState);
    }
    Ok(())
}

impl MlsDevice {
    pub(crate) fn create_history_source_bundle(
        &mut self,
        id: &TransferId,
        payload: &[u8],
        created_at_ms: u64,
        snapshot_counter: u64,
        plaintext_version: u8,
        now_ms: u64,
    ) -> Result<SourceBundle, MlsError> {
        let record = self.history_record(id, now_ms)?;
        if record.direction != Direction::Outgoing
            || record.stage != Stage::Approved
            || created_at_ms == 0
            || created_at_ms > now_ms
        {
            return Err(MlsError::InvalidState);
        }
        let header = history::BundleHeader {
            account_id: record.context.account_id.clone(),
            source_device_id: record.context.source_device_id.clone(),
            created_at_ms,
            snapshot_counter,
            recovery_key_id: None,
            plaintext_version,
        };
        let bundle = history::seal_bundle(&self.provider, &header, payload).map_err(invalid)?;
        let transfer_id = history::transfer_id(
            record
                .verification
                .transcript_hash
                .as_slice()
                .try_into()
                .map_err(invalid)?,
            &bundle.ciphertext_sha256,
        );
        let payload = HandoffPayload {
            blob_id: transfer_id.to_vec(),
            ciphertext_sha256: bundle.ciphertext_sha256,
            ciphertext_size: bundle.ciphertext.len() as u64,
            snapshot_counter,
            header_sha256: bundle.header_sha256,
            secrets: bundle.secrets,
            recovery_identity: None,
        };
        let handoff = history::seal_handoff(
            &self.provider,
            &self.signer,
            &record.public_context()?,
            record.link_key.as_slice().try_into().map_err(invalid)?,
            &payload,
        )
        .map_err(invalid)?;
        self.record_history_source_material(
            id,
            SourceMaterial {
                secrets: payload.secrets,
                snapshot_counter,
                header_sha256: bundle.header_sha256,
                ciphertext_sha256: bundle.ciphertext_sha256,
                ciphertext_size: bundle.ciphertext.len() as u64,
            },
            now_ms,
        )?;
        Ok(SourceBundle {
            ciphertext: bundle.ciphertext,
            header_sha256: bundle.header_sha256,
            ciphertext_sha256: bundle.ciphertext_sha256,
            handoff,
            transfer_id,
        })
    }

    pub(crate) fn history_record(
        &self,
        id: &TransferId,
        now_ms: u64,
    ) -> Result<&PendingTransfer, MlsError> {
        let record = self
            .pending_transfers
            .get(id)
            .ok_or(MlsError::InvalidState)?;
        record.live(now_ms)?;
        Ok(record)
    }

    pub(crate) fn history_approval_request(
        &self,
        id: &TransferId,
        now_ms: u64,
    ) -> Result<(&[u8], &[u8]), MlsError> {
        let record = self.history_record(id, now_ms)?;
        if record.direction != Direction::Outgoing
            || record.approval_intent_at_ms == 0
            || now_ms >= record.link_expires_at_ms
        {
            return Err(MlsError::InvalidState);
        }
        Ok((
            &record.verification.transcript_hash,
            &record.verification.approval_tag,
        ))
    }

    fn insert_transfer(
        &mut self,
        record: PendingTransfer,
        now_ms: u64,
    ) -> Result<DeviceLinkVerification, MlsError> {
        record.validate(
            &self.account_id,
            &self.device_id,
            self.signing_public_key(),
            &self.provider,
        )?;
        let id = TransferId::new(&record.context.origin, &record.context.link_id);
        if let Some(existing) = self.pending_transfers.get(&id) {
            existing.live(now_ms)?;
            return if existing.context == record.context
                && existing.direction == record.direction
                && existing.link_expires_at_ms == record.link_expires_at_ms
                && existing.verification == record.verification
                && link_v3::equal_tag(existing.link_key.as_slice(), record.link_key.as_slice())
            {
                Ok(existing.verification.clone())
            } else {
                Err(MlsError::InvalidState)
            };
        }
        if now_ms == 0
            || record.expires_at_ms <= now_ms
            || record.expires_at_ms - now_ms > MAX_LINK_MS
        {
            return Err(MlsError::InvalidState);
        }
        if self.pending_transfers.len() >= MAX_TRANSFERS {
            return Err(MlsError::InvalidState);
        }
        let public = record.verification.clone();
        self.pending_transfers.insert(id, record);
        Ok(public)
    }

    pub(crate) fn begin_history_receive(
        &mut self,
        mut context: LinkContext,
        secret: &[u8],
        link_expires_ms: u64,
        now_ms: u64,
    ) -> Result<([u8; 32], DeviceLinkVerification), MlsError> {
        if context.account_id != self.account_id
            || context.recipient_device_id != self.device_id
            || context.recipient_signing_key != self.signing_public_key()
        {
            return Err(MlsError::InvalidIdentity);
        }
        let id = TransferId::new(&context.origin, &context.link_id);
        if let Some(existing) = self.pending_transfers.get(&id) {
            existing.live(now_ms)?;
            // The transfer public key is a native output, not a new caller
            // choice on retry. Never generate a second private key here.
            if context.transfer_public_key != [0; 32]
                && context.transfer_public_key != existing.context.transfer_public_key
            {
                return Err(MlsError::InvalidIdentity);
            }
            context.transfer_public_key = existing.context.transfer_public_key;
            let verified = link_v3::derive(&self.provider, &context, secret)?;
            if existing.direction != Direction::Incoming
                || existing.context != context
                || existing.link_expires_at_ms != link_expires_ms
                || existing.verification != verified.public
                || !link_v3::equal_tag(existing.link_key.as_slice(), verified.link_key.as_slice())
            {
                return Err(MlsError::InvalidState);
            }
            return Ok((
                existing.context.transfer_public_key,
                existing.verification.clone(),
            ));
        }
        let key = TransferKeyPair::fresh(&self.provider).map_err(invalid)?;
        let public: [u8; 32] = key.public_key().try_into().map_err(invalid)?;
        context.transfer_public_key = public;
        let verification = link_v3::derive(&self.provider, &context, secret)?;
        let output = self.insert_transfer(
            PendingTransfer {
                context,
                direction: Direction::Incoming,
                stage: Stage::WaitingApproval,
                link_expires_at_ms: link_expires_ms,
                approval_intent_at_ms: 0,
                approved_at_ms: 0,
                expires_at_ms: link_expires_ms,
                verification: verification.public,
                link_key: verification.link_key,
                transfer_key: Some(key),
                source_material: None,
                verified_handoff_sha256: None,
            },
            now_ms,
        )?;
        Ok((public, output))
    }

    pub(crate) fn accept_history_claim(
        &mut self,
        context: LinkContext,
        secret: &[u8],
        link_expires_ms: u64,
        now_ms: u64,
        transcript_hash: &[u8],
        claim_tag: &[u8],
    ) -> Result<DeviceLinkVerification, MlsError> {
        let verification = link_v3::derive(&self.provider, &context, secret)?;
        if !link_v3::equal_tag(&verification.public.transcript_hash, transcript_hash)
            || !link_v3::equal_tag(&verification.public.claim_tag, claim_tag)
        {
            return Err(MlsError::InvalidIdentity);
        }
        self.insert_transfer(
            PendingTransfer {
                context,
                direction: Direction::Outgoing,
                stage: Stage::WaitingApproval,
                link_expires_at_ms: link_expires_ms,
                approval_intent_at_ms: 0,
                approved_at_ms: 0,
                expires_at_ms: link_expires_ms,
                verification: verification.public,
                link_key: verification.link_key,
                transfer_key: None,
                source_material: None,
                verified_handoff_sha256: None,
            },
            now_ms,
        )
    }

    pub(crate) fn history_verification(
        &self,
        id: &TransferId,
        now_ms: u64,
    ) -> Result<DeviceLinkVerification, MlsError> {
        let record = self
            .pending_transfers
            .get(id)
            .ok_or(MlsError::InvalidState)?;
        record.live(now_ms)?;
        Ok(record.verification.clone())
    }

    pub(crate) fn history_transfer_context(
        &self,
        id: &TransferId,
        now_ms: u64,
    ) -> Result<LinkContext, MlsError> {
        let record = self
            .pending_transfers
            .get(id)
            .ok_or(MlsError::InvalidState)?;
        record.live(now_ms)?;
        Ok(record.context.clone())
    }

    /// The caller must seal/commit this mutation before sending the returned
    /// tag to HTTP. A future FFI must mask the source tag until this step.
    pub(crate) fn prepare_history_approval(
        &mut self,
        id: &TransferId,
        typed_sas: &[u8],
        now_ms: u64,
    ) -> Result<Vec<u8>, MlsError> {
        let record = self
            .pending_transfers
            .get_mut(id)
            .ok_or(MlsError::InvalidState)?;
        record.live(now_ms)?;
        if record.direction != Direction::Outgoing
            || record.stage != Stage::WaitingApproval
            || typed_sas.len() != 8
            || !typed_sas.iter().all(u8::is_ascii_digit)
            || typed_sas
                .iter()
                .zip(record.verification.sas.as_bytes())
                .fold(0u8, |difference, (a, b)| difference | (a ^ b))
                != 0
        {
            return Err(MlsError::InvalidIdentity);
        }
        if record.approval_intent_at_ms == 0 {
            record.approval_intent_at_ms = now_ms;
        }
        Ok(record.verification.approval_tag.clone())
    }

    pub(crate) fn approve_history_transfer(
        &mut self,
        id: &TransferId,
        approval_tag: &[u8],
        approved_at_ms: u64,
        now_ms: u64,
    ) -> Result<(), MlsError> {
        let record = self
            .pending_transfers
            .get_mut(id)
            .ok_or(MlsError::InvalidState)?;
        if now_ms == 0 || now_ms >= record.retention_deadline() {
            return Err(MlsError::InvalidState);
        }
        if !link_v3::equal_tag(&record.verification.approval_tag, approval_tag)
            || approved_at_ms == 0
            || approved_at_ms > now_ms
            || approved_at_ms > record.link_expires_at_ms
        {
            return Err(MlsError::InvalidIdentity);
        }
        if record.direction == Direction::Outgoing && record.approval_intent_at_ms == 0 {
            return Err(MlsError::InvalidState);
        }
        if record.stage != Stage::WaitingApproval {
            return if record.approved_at_ms == approved_at_ms {
                Ok(())
            } else {
                Err(MlsError::InvalidState)
            };
        }
        let expires = approved_at_ms
            .checked_add(TRANSFER_LIFETIME_MS)
            .ok_or(MlsError::InvalidState)?;
        if expires <= now_ms {
            return Err(MlsError::InvalidState);
        }
        record.approved_at_ms = approved_at_ms;
        record.expires_at_ms = expires;
        record.stage = Stage::Approved;
        Ok(())
    }

    pub(crate) fn record_history_source_material(
        &mut self,
        id: &TransferId,
        material: SourceMaterial,
        now_ms: u64,
    ) -> Result<(), MlsError> {
        validate_material(&material)?;
        let record = self
            .pending_transfers
            .get_mut(id)
            .ok_or(MlsError::InvalidState)?;
        record.live(now_ms)?;
        if record.direction != Direction::Outgoing {
            return Err(MlsError::InvalidState);
        }
        if matches!(record.stage, Stage::Ready | Stage::Delivered) {
            let existing = record
                .source_material
                .as_ref()
                .ok_or(MlsError::InvalidState)?;
            let (old_key, old_nonce) = existing.secrets.state_parts();
            let (new_key, new_nonce) = material.secrets.state_parts();
            return if existing.snapshot_counter == material.snapshot_counter
                && existing.header_sha256 == material.header_sha256
                && existing.ciphertext_sha256 == material.ciphertext_sha256
                && existing.ciphertext_size == material.ciphertext_size
                && old_nonce == new_nonce
                && link_v3::equal_tag(old_key, new_key)
            {
                Ok(())
            } else {
                Err(MlsError::InvalidState)
            };
        }
        if record.stage != Stage::Approved {
            return Err(MlsError::InvalidState);
        }
        record.source_material = Some(material);
        record.stage = Stage::Ready;
        Ok(())
    }

    pub(crate) fn mark_history_handoff_posted(
        &mut self,
        id: &TransferId,
        now_ms: u64,
    ) -> Result<(), MlsError> {
        let record = self
            .pending_transfers
            .get_mut(id)
            .ok_or(MlsError::InvalidState)?;
        record.live(now_ms)?;
        if record.direction != Direction::Outgoing
            || !matches!(record.stage, Stage::Ready | Stage::Delivered)
        {
            return Err(MlsError::InvalidState);
        }
        record.stage = Stage::Delivered;
        Ok(())
    }

    pub(crate) fn open_history_handoff(
        &mut self,
        id: &TransferId,
        ciphertext: &[u8],
        now_ms: u64,
    ) -> Result<HandoffPayload, MlsError> {
        self.open_history_handoff_checked(id, ciphertext, now_ms, false)
    }

    pub(crate) fn open_history_stream_handoff(
        &mut self,
        id: &TransferId,
        ciphertext: &[u8],
        now_ms: u64,
    ) -> Result<HandoffPayload, MlsError> {
        self.open_history_handoff_checked(id, ciphertext, now_ms, true)
    }

    fn open_history_handoff_checked(
        &mut self,
        id: &TransferId,
        ciphertext: &[u8],
        now_ms: u64,
        canonical_id: bool,
    ) -> Result<HandoffPayload, MlsError> {
        let record = self
            .pending_transfers
            .get_mut(id)
            .ok_or(MlsError::InvalidState)?;
        record.live(now_ms)?;
        if record.direction != Direction::Incoming
            || !matches!(
                record.stage,
                Stage::Approved | Stage::Ready | Stage::Delivered
            )
        {
            return Err(MlsError::InvalidState);
        }
        let digest: [u8; 32] = Sha256::digest(ciphertext).into();
        if record
            .verified_handoff_sha256
            .is_some_and(|existing| existing != digest)
        {
            return Err(MlsError::InvalidState);
        }
        let context = record.public_context()?;
        let key = record.transfer_key.as_ref().ok_or(MlsError::InvalidState)?;
        let payload = history::open_handoff(
            &self.provider,
            key,
            &context,
            record.link_key.as_slice().try_into().map_err(invalid)?,
            ciphertext,
        )
        .map_err(invalid)?;
        if canonical_id
            && payload.blob_id
                != history::transfer_id(
                    record
                        .verification
                        .transcript_hash
                        .as_slice()
                        .try_into()
                        .map_err(invalid)?,
                    &payload.ciphertext_sha256,
                )
        {
            return Err(MlsError::InvalidIdentity);
        }
        record.verified_handoff_sha256 = Some(digest);
        if record.stage == Stage::Approved {
            record.stage = Stage::Ready;
        }
        Ok(payload)
    }

    pub(crate) fn mark_history_importing(
        &mut self,
        id: &TransferId,
        now_ms: u64,
    ) -> Result<(), MlsError> {
        let record = self
            .pending_transfers
            .get_mut(id)
            .ok_or(MlsError::InvalidState)?;
        record.live(now_ms)?;
        if record.direction != Direction::Incoming
            || !matches!(record.stage, Stage::Ready | Stage::Delivered)
        {
            return Err(MlsError::InvalidState);
        }
        record.stage = Stage::Delivered;
        Ok(())
    }

    pub(crate) fn cancel_history_transfer(&mut self, id: &TransferId) -> bool {
        // Dropping the record drops the existing zeroizing secret wrappers.
        self.pending_transfers.remove(id).is_some()
    }

    pub(crate) fn expire_history_transfers(&mut self, now_ms: u64) -> usize {
        let before = self.pending_transfers.len();
        self.pending_transfers
            .retain(|_, record| now_ms < record.retention_deadline());
        before - self.pending_transfers.len()
    }
}

struct SecretWriter(SecretVLBytes);
impl SecretWriter {
    fn new(capacity: usize) -> Self {
        Self(Vec::with_capacity(capacity).into())
    }
    fn put(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0.push(*byte);
        }
    }
    fn byte(&mut self, byte: u8) {
        self.0.push(byte);
    }
    fn lp(&mut self, bytes: &[u8]) -> Result<(), MlsError> {
        let length = u16::try_from(bytes.len()).map_err(invalid)?;
        self.put(&length.to_be_bytes());
        self.put(bytes);
        Ok(())
    }
}

pub(super) fn encode(
    map: &PendingTransfers,
    account: &[u8],
    device: &[u8],
    signing: &[u8],
    provider: &impl OpenMlsProvider,
) -> Result<SecretVLBytes, MlsError> {
    if map.len() > MAX_TRANSFERS {
        return Err(MlsError::InvalidState);
    }
    let mut output = SecretWriter::new(2 + map.len() * (4 + MAX_TRANSFER_BYTES));
    output.put(&(map.len() as u16).to_be_bytes());
    for (id, record) in map {
        record.validate(account, device, signing, provider)?;
        if id != &TransferId::new(&record.context.origin, &record.context.link_id) {
            return Err(MlsError::InvalidState);
        }
        let mut encoded = SecretWriter::new(MAX_TRANSFER_BYTES);
        encoded.byte(1);
        encoded.byte(record.direction as u8);
        encoded.byte(record.stage as u8);
        for field in [
            &record.context.origin,
            &record.context.link_id,
            &record.context.account_id,
        ] {
            encoded.lp(field)?;
        }
        encoded.put(&record.context.nonce);
        encoded.lp(&record.context.source_device_id)?;
        encoded.put(&record.context.source_signing_key);
        encoded.lp(&record.context.recipient_device_id)?;
        encoded.put(&record.context.recipient_signing_key);
        encoded.put(&record.context.transfer_public_key);
        encoded.put(&record.context.transcript_hash()?);
        encoded.put(&record.link_expires_at_ms.to_be_bytes());
        encoded.put(&record.approval_intent_at_ms.to_be_bytes());
        encoded.put(&record.approved_at_ms.to_be_bytes());
        encoded.put(&record.expires_at_ms.to_be_bytes());
        encoded.put(&record.verification.sas_bytes);
        encoded.put(&record.verification.claim_tag);
        encoded.put(&record.verification.approval_tag);
        encoded.put(record.link_key.as_slice());
        match &record.transfer_key {
            None => encoded.byte(0),
            Some(key) => {
                encoded.byte(1);
                encoded.put(key.state_private());
            }
        }
        match &record.source_material {
            None => encoded.byte(0),
            Some(material) => {
                encoded.byte(1);
                let (key, nonce) = material.secrets.state_parts();
                encoded.put(key);
                encoded.put(nonce);
                encoded.put(&material.snapshot_counter.to_be_bytes());
                encoded.put(&material.header_sha256);
                encoded.put(&material.ciphertext_sha256);
                encoded.put(&material.ciphertext_size.to_be_bytes());
            }
        }
        match record.verified_handoff_sha256 {
            None => encoded.byte(0),
            Some(digest) => {
                encoded.byte(1);
                encoded.put(&digest);
            }
        }
        if encoded.0.as_slice().len() > MAX_TRANSFER_BYTES {
            return Err(MlsError::InvalidState);
        }
        output.put(&(encoded.0.as_slice().len() as u32).to_be_bytes());
        output.put(encoded.0.as_slice());
    }
    Ok(output.0)
}

pub(super) fn decode(
    bytes: &[u8],
    account: &[u8],
    device: &[u8],
    signing: &[u8],
    provider: &impl OpenMlsProvider,
) -> Result<PendingTransfers, MlsError> {
    let mut reader = Reader { bytes, offset: 0 };
    let count = reader.u16()? as usize;
    if count > MAX_TRANSFERS {
        return Err(MlsError::InvalidState);
    }
    let mut map = BTreeMap::new();
    let mut previous: Option<TransferId> = None;
    for _ in 0..count {
        let length = reader.u32()? as usize;
        if length > MAX_TRANSFER_BYTES {
            return Err(MlsError::InvalidState);
        }
        let mut item = Reader {
            bytes: reader.take(length)?,
            offset: 0,
        };
        if item.byte()? != 1 {
            return Err(MlsError::InvalidState);
        }
        let direction = match item.byte()? {
            1 => Direction::Outgoing,
            2 => Direction::Incoming,
            _ => return Err(MlsError::InvalidState),
        };
        let stage = match item.byte()? {
            1 => Stage::WaitingApproval,
            2 => Stage::Approved,
            3 => Stage::Ready,
            4 => Stage::Delivered,
            _ => return Err(MlsError::InvalidState),
        };
        let origin = item.lp(2048)?.to_vec();
        let link_id = item.lp(128)?.to_vec();
        let account_id = item.lp(128)?.to_vec();
        let nonce = item.array()?;
        let source_device_id = item.lp(128)?.to_vec();
        let source_signing_key = item.array()?;
        let recipient_device_id = item.lp(128)?.to_vec();
        let recipient_signing_key = item.array()?;
        let transfer_public_key = item.array()?;
        let transcript_hash: [u8; 32] = item.array()?;
        let link_expires_at_ms = item.u64()?;
        let approval_intent_at_ms = item.u64()?;
        let approved_at_ms = item.u64()?;
        let expires_at_ms = item.u64()?;
        let sas_bytes: [u8; 4] = item.array()?;
        let claim_tag: [u8; 32] = item.array()?;
        let approval_tag: [u8; 32] = item.array()?;
        let link_key: SecretVLBytes = item.take(32)?.into();
        let transfer_key = match item.byte()? {
            0 => None,
            1 => Some(
                TransferKeyPair::restore_for_state(provider, item.take(32)?, &transfer_public_key)
                    .map_err(invalid)?,
            ),
            _ => return Err(MlsError::InvalidState),
        };
        let source_material = match item.byte()? {
            0 => None,
            1 => Some(SourceMaterial {
                secrets: FileSecrets::from_bytes(item.take(32)?, item.take(8)?).map_err(invalid)?,
                snapshot_counter: item.u64()?,
                header_sha256: item.array()?,
                ciphertext_sha256: item.array()?,
                ciphertext_size: item.u64()?,
            }),
            _ => return Err(MlsError::InvalidState),
        };
        let verified_handoff_sha256 = match item.byte()? {
            0 => None,
            1 => Some(item.array()?),
            _ => return Err(MlsError::InvalidState),
        };
        if item.offset != item.bytes.len() {
            return Err(MlsError::InvalidState);
        }
        let record = PendingTransfer {
            context: LinkContext {
                origin,
                link_id,
                account_id,
                nonce,
                source_device_id,
                source_signing_key,
                recipient_device_id,
                recipient_signing_key,
                transfer_public_key,
            },
            direction,
            stage,
            link_expires_at_ms,
            approval_intent_at_ms,
            approved_at_ms,
            expires_at_ms,
            verification: DeviceLinkVerification {
                transcript_hash: transcript_hash.to_vec(),
                sas: format!("{:08}", u32::from_be_bytes(sas_bytes) % 100_000_000),
                claim_tag: claim_tag.to_vec(),
                approval_tag: approval_tag.to_vec(),
                sas_bytes: sas_bytes.to_vec(),
            },
            link_key,
            transfer_key,
            source_material,
            verified_handoff_sha256,
        };
        record.validate(account, device, signing, provider)?;
        let id = TransferId::new(&record.context.origin, &record.context.link_id);
        if previous.as_ref().is_some_and(|last| &id <= last) {
            return Err(MlsError::InvalidState);
        }
        previous = Some(id.clone());
        map.insert(id, record);
    }
    if reader.offset != bytes.len() {
        return Err(MlsError::InvalidState);
    }
    Ok(map)
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}
impl<'a> Reader<'a> {
    fn take(&mut self, len: usize) -> Result<&'a [u8], MlsError> {
        let end = self.offset.checked_add(len).ok_or(MlsError::InvalidState)?;
        let value = self
            .bytes
            .get(self.offset..end)
            .ok_or(MlsError::InvalidState)?;
        self.offset = end;
        Ok(value)
    }
    fn array<const N: usize>(&mut self) -> Result<[u8; N], MlsError> {
        self.take(N)?.try_into().map_err(invalid)
    }
    fn byte(&mut self) -> Result<u8, MlsError> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, MlsError> {
        Ok(u16::from_be_bytes(self.array()?))
    }
    fn u32(&mut self) -> Result<u32, MlsError> {
        Ok(u32::from_be_bytes(self.array()?))
    }
    fn u64(&mut self) -> Result<u64, MlsError> {
        Ok(u64::from_be_bytes(self.array()?))
    }
    fn lp(&mut self, max: usize) -> Result<&'a [u8], MlsError> {
        let len = self.u16()? as usize;
        if len > max {
            return Err(MlsError::InvalidState);
        }
        self.take(len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem;

    fn pair() -> (MlsDevice, MlsDevice, LinkContext, DeviceLinkVerification) {
        let mut source = MlsDevice::new(b"acct_transfer", b"dev_old").unwrap();
        let mut recipient = MlsDevice::new(b"acct_transfer", b"dev_new").unwrap();
        let mut context = LinkContext {
            origin: b"https://example.test".to_vec(),
            link_id: b"link_1".to_vec(),
            account_id: b"acct_transfer".to_vec(),
            nonce: [1; 32],
            source_device_id: b"dev_old".to_vec(),
            source_signing_key: source.signing_public_key().try_into().unwrap(),
            recipient_device_id: b"dev_new".to_vec(),
            recipient_signing_key: recipient.signing_public_key().try_into().unwrap(),
            transfer_public_key: [0; 32],
        };
        let (public, verification) = recipient
            .begin_history_receive(context.clone(), &[7; 16], 2_000, 1_000)
            .unwrap();
        context.transfer_public_key = public;
        let old = source
            .accept_history_claim(
                context.clone(),
                &[7; 16],
                2_000,
                1_000,
                &verification.transcript_hash,
                &verification.claim_tag,
            )
            .unwrap();
        assert_eq!(old, verification);
        (source, recipient, context, verification)
    }

    #[test]
    fn incoming_exact_retry_reuses_private_key_before_and_after_approval() {
        let (_, mut recipient, context, verification) = pair();
        let id = TransferId::new(&context.origin, &context.link_id);
        let original_private = recipient.pending_transfers[&id]
            .transfer_key
            .as_ref()
            .unwrap()
            .state_private()
            .to_vec();
        let mut request = context.clone();
        request.transfer_public_key = [0; 32];
        let (public, repeated) = recipient
            .begin_history_receive(request.clone(), &[7; 16], 2_000, 1_001)
            .unwrap();
        assert_eq!(public, context.transfer_public_key);
        assert_eq!(repeated, verification);
        assert!(
            recipient.pending_transfers[&id]
                .transfer_key
                .as_ref()
                .unwrap()
                .state_private()
                == original_private
        );
        recipient
            .approve_history_transfer(&id, &verification.approval_tag, 1_100, 1_100)
            .unwrap();
        let sealed = recipient.seal_state(&[8; 32], 8).unwrap();
        let (mut recipient, _) =
            MlsDevice::restore_state(b"acct_transfer", b"dev_new", &[8; 32], 8, &sealed).unwrap();
        // Original claim window elapsed; exact retry retrieves the same native
        // output while the fixed history-transfer deadline is still live.
        let (public, repeated) = recipient
            .begin_history_receive(request.clone(), &[7; 16], 2_000, 3_000)
            .unwrap();
        assert_eq!(public, context.transfer_public_key);
        assert_eq!(repeated, verification);
        assert!(
            recipient.pending_transfers[&id]
                .transfer_key
                .as_ref()
                .unwrap()
                .state_private()
                == original_private
        );
        assert_eq!(recipient.pending_transfers[&id].link_expires_at_ms, 2_000);
        assert_eq!(
            recipient.pending_transfers[&id].expires_at_ms,
            1_100 + TRANSFER_LIFETIME_MS
        );
        assert!(recipient.pending_transfers[&id].stage == Stage::Approved);
        assert!(recipient
            .begin_history_receive(request.clone(), &[7; 16], 2_001, 3_000)
            .is_err());
        assert!(recipient
            .begin_history_receive(request.clone(), &[8; 16], 2_000, 3_000)
            .is_err());
        request.nonce[0] ^= 1;
        assert!(recipient
            .begin_history_receive(request, &[7; 16], 2_000, 3_000)
            .is_err());
    }

    fn material() -> SourceMaterial {
        SourceMaterial {
            secrets: FileSecrets::from_bytes(&[0x41; 32], &[0x42; 8]).unwrap(),
            snapshot_counter: 7,
            header_sha256: [0x43; 32],
            ciphertext_sha256: [0x44; 32],
            ciphertext_size: 70_000,
        }
    }

    #[test]
    fn source_material_exact_retry_preserves_ready_and_posted_state() {
        let (mut source, _, context, verification) = pair();
        let id = TransferId::new(&context.origin, &context.link_id);
        source
            .prepare_history_approval(&id, verification.sas.as_bytes(), 1_050)
            .unwrap();
        source
            .approve_history_transfer(&id, &verification.approval_tag, 1_100, 1_100)
            .unwrap();
        source
            .record_history_source_material(&id, material(), 1_200)
            .unwrap();
        source
            .record_history_source_material(&id, material(), 1_201)
            .unwrap();
        assert!(source.pending_transfers[&id].stage == Stage::Ready);
        source.mark_history_handoff_posted(&id, 1_202).unwrap();
        let sealed = source.seal_state(&[8; 32], 6).unwrap();
        let (mut source, _) =
            MlsDevice::restore_state(b"acct_transfer", b"dev_old", &[8; 32], 6, &sealed).unwrap();
        source
            .record_history_source_material(&id, material(), 3_000)
            .unwrap();
        assert!(source.pending_transfers[&id].stage == Stage::Delivered);
        for field in 0..6 {
            let mut changed = material();
            match field {
                0 => changed.snapshot_counter += 1,
                1 => changed.header_sha256[0] ^= 1,
                2 => changed.ciphertext_sha256[0] ^= 1,
                3 => changed.ciphertext_size += 1,
                4 => changed.secrets = FileSecrets::from_bytes(&[0x45; 32], &[0x42; 8]).unwrap(),
                _ => changed.secrets = FileSecrets::from_bytes(&[0x41; 32], &[0x46; 8]).unwrap(),
            }
            assert!(source
                .record_history_source_material(&id, changed, 3_000)
                .is_err());
        }
        assert!(source.pending_transfers[&id].stage == Stage::Delivered);
    }

    #[test]
    fn transfer_keys_context_tags_and_native_identity_survive_restart() {
        let (mut source, recipient, context, verification) = pair();
        let id = TransferId::new(&context.origin, &context.link_id);
        for device in [&source, &recipient] {
            let sealed = device.seal_state(&[9; 32], 4).unwrap();
            let (restored, count) = MlsDevice::restore_state(
                &device.account_id,
                &device.device_id,
                &[9; 32],
                4,
                &sealed,
            )
            .unwrap();
            assert_eq!(count, 4);
            assert_eq!(restored.signing_public_key(), device.signing_public_key());
            assert_eq!(
                restored.history_verification(&id, 1_001).unwrap(),
                verification
            );
            assert!(restored.history_transfer_context(&id, 1_001).unwrap() == context);
            assert!(restored.pending_transfers.get(&id).unwrap().context == context);
        }
        // Exact source refresh is idempotent, but cannot change the deadline.
        assert_eq!(
            source
                .accept_history_claim(
                    context.clone(),
                    &[7; 16],
                    2_000,
                    1_001,
                    &verification.transcript_hash,
                    &verification.claim_tag
                )
                .unwrap(),
            verification
        );
        assert!(source
            .accept_history_claim(
                context,
                &[7; 16],
                2_001,
                1_001,
                &verification.transcript_hash,
                &verification.claim_tag
            )
            .is_err());
    }

    #[test]
    fn authentic_late_approval_recovers_only_within_bounded_retention() {
        let (mut source, recipient, context, verification) = pair();
        let id = TransferId::new(&context.origin, &context.link_id);
        assert!(source
            .approve_history_transfer(&id, &verification.approval_tag, 1_500, 3_000)
            .is_err());
        assert!(source
            .prepare_history_approval(&id, b"bad-code", 1_050)
            .is_err());
        let tag = source
            .prepare_history_approval(&id, verification.sas.as_bytes(), 1_050)
            .unwrap();
        assert_eq!(tag, verification.approval_tag);
        source
            .prepare_history_approval(&id, verification.sas.as_bytes(), 1_100)
            .unwrap();
        assert_eq!(source.pending_transfers[&id].approval_intent_at_ms, 1_050);
        let sealed = source.seal_state(&[8; 32], 4).unwrap();
        let (mut source, _) =
            MlsDevice::restore_state(b"acct_transfer", b"dev_old", &[8; 32], 4, &sealed).unwrap();
        let sealed = recipient.seal_state(&[8; 32], 4).unwrap();
        let (mut recipient, _) =
            MlsDevice::restore_state(b"acct_transfer", b"dev_new", &[8; 32], 4, &sealed).unwrap();
        for device in [&mut source, &mut recipient] {
            assert_eq!(device.expire_history_transfers(3_000), 0);
            assert!(device.history_verification(&id, 3_000).is_err());
            assert!(device.history_transfer_context(&id, 3_000).is_err());
            assert!(device
                .prepare_history_approval(&id, verification.sas.as_bytes(), 3_000)
                .is_err());
            assert!(device
                .approve_history_transfer(&id, &verification.claim_tag, 1_500, 3_000)
                .is_err());
            assert!(device
                .approve_history_transfer(&id, &verification.approval_tag, 2_001, 3_000)
                .is_err());
            device
                .approve_history_transfer(&id, &verification.approval_tag, 1_500, 3_000)
                .unwrap();
            assert_eq!(device.pending_transfers[&id].link_expires_at_ms, 2_000);
            assert_eq!(
                device.pending_transfers[&id].expires_at_ms,
                1_500 + TRANSFER_LIFETIME_MS
            );
            assert!(device.pending_transfers[&id].stage == Stage::Approved);
        }
        let (_, mut expired, context, verification) = pair();
        let id = TransferId::new(&context.origin, &context.link_id);
        let limit = 2_000 + TRANSFER_LIFETIME_MS;
        assert!(expired
            .approve_history_transfer(&id, &verification.approval_tag, 2_000, limit)
            .is_err());
        assert_eq!(expired.expire_history_transfers(limit), 1);
        assert!(expired.pending_transfers.is_empty());
    }

    #[test]
    fn approval_status_deadlines_and_cleanup_do_not_extend_on_retries() {
        let (mut source, mut recipient, context, verification) = pair();
        let id = TransferId::new(&context.origin, &context.link_id);
        assert!(recipient
            .approve_history_transfer(&id, &verification.claim_tag, 1_100, 1_100)
            .is_err());
        source
            .prepare_history_approval(&id, verification.sas.as_bytes(), 1_050)
            .unwrap();
        for device in [&mut source, &mut recipient] {
            device
                .approve_history_transfer(&id, &verification.approval_tag, 1_100, 1_100)
                .unwrap();
            let deadline = 1_100 + TRANSFER_LIFETIME_MS;
            assert_eq!(device.pending_transfers[&id].expires_at_ms, deadline);
            device
                .approve_history_transfer(&id, &verification.approval_tag, 1_100, 1_200)
                .unwrap();
            assert!(device
                .approve_history_transfer(&id, &verification.approval_tag, 1_200, 1_200)
                .is_err());
            assert_eq!(device.pending_transfers[&id].expires_at_ms, deadline);
            assert!(device.history_verification(&id, deadline).is_err());
            assert_eq!(device.expire_history_transfers(deadline), 1);
            assert!(device.pending_transfers.is_empty());
            assert_eq!(device.expire_history_transfers(deadline), 0);
        }
        let (mut source, _, context, _) = pair();
        let id = TransferId::new(&context.origin, &context.link_id);
        assert!(source.cancel_history_transfer(&id));
        assert!(!source.cancel_history_transfer(&id));
        assert_eq!(
            encode(
                &source.pending_transfers,
                &source.account_id,
                &source.device_id,
                source.signing_public_key(),
                &source.provider
            )
            .unwrap()
            .as_slice(),
            &[0, 0]
        );
        // Existing secret wrappers drop/zero their allocations; no unsafe
        // reads of freed memory are used to pretend to test the allocator.
        assert!(mem::needs_drop::<TransferKeyPair>());
        assert!(mem::needs_drop::<FileSecrets>());
        assert!(mem::needs_drop::<SecretVLBytes>());
    }

    #[test]
    fn full_handoff_can_resume_from_a_sealed_recipient_record() {
        let (mut source, mut recipient, context, verification) = pair();
        let id = TransferId::new(&context.origin, &context.link_id);
        source
            .prepare_history_approval(&id, verification.sas.as_bytes(), 1_050)
            .unwrap();
        for device in [&mut source, &mut recipient] {
            device
                .approve_history_transfer(&id, &verification.approval_tag, 1_100, 1_100)
                .unwrap();
        }
        let source_record = &source.pending_transfers[&id];
        let secrets = FileSecrets::fresh(&source.provider).unwrap();
        let payload = HandoffPayload {
            blob_id: b"blob_1".to_vec(),
            ciphertext_sha256: [1; 32],
            ciphertext_size: 70_000,
            snapshot_counter: 7,
            header_sha256: [2; 32],
            secrets,
            recovery_identity: None,
        };
        let handoff = history::seal_handoff(
            &source.provider,
            &source.signer,
            &source_record.public_context().unwrap(),
            source_record.link_key.as_slice().try_into().unwrap(),
            &payload,
        )
        .unwrap();
        let (key, nonce) = payload.secrets.state_parts();
        source
            .record_history_source_material(
                &id,
                SourceMaterial {
                    secrets: FileSecrets::from_bytes(key, nonce).unwrap(),
                    snapshot_counter: 7,
                    header_sha256: [2; 32],
                    ciphertext_sha256: [1; 32],
                    ciphertext_size: 70_000,
                },
                1_200,
            )
            .unwrap();
        source.mark_history_handoff_posted(&id, 1_200).unwrap();
        let sealed = recipient.seal_state(&[8; 32], 5).unwrap();
        let (mut restored, _) =
            MlsDevice::restore_state(b"acct_transfer", b"dev_new", &[8; 32], 5, &sealed).unwrap();
        let opened = restored.open_history_handoff(&id, &handoff, 1_300).unwrap();
        assert_eq!(opened.blob_id, b"blob_1");
        restored.mark_history_importing(&id, 1_300).unwrap();
        let sealed = restored.seal_state(&[8; 32], 6).unwrap();
        let (mut restored, _) =
            MlsDevice::restore_state(b"acct_transfer", b"dev_new", &[8; 32], 6, &sealed).unwrap();
        // Crash after persisting importing but before the database import:
        // reopening the same handoff must recover plaintext without rollback.
        let reopened = restored.open_history_handoff(&id, &handoff, 1_400).unwrap();
        assert_eq!(reopened.blob_id, b"blob_1");
        assert!(restored.pending_transfers[&id].stage == Stage::Delivered);
        let old_record = &source.pending_transfers[&id];
        let different_encapsulation = history::seal_handoff(
            &source.provider,
            &source.signer,
            &old_record.public_context().unwrap(),
            old_record.link_key.as_slice().try_into().unwrap(),
            &payload,
        )
        .unwrap();
        assert_ne!(different_encapsulation, handoff);
        assert!(restored
            .open_history_handoff(&id, &different_encapsulation, 1_400)
            .is_err());
        assert!(restored.cancel_history_transfer(&id));
        let sealed = restored.seal_state(&[8; 32], 7).unwrap();
        let (empty, _) =
            MlsDevice::restore_state(b"acct_transfer", b"dev_new", &[8; 32], 7, &sealed).unwrap();
        assert!(empty.pending_transfers.is_empty());
        let sealed = source.seal_state(&[8; 32], 6).unwrap();
        let (source, _) =
            MlsDevice::restore_state(b"acct_transfer", b"dev_old", &[8; 32], 6, &sealed).unwrap();
        assert!(source.pending_transfers[&id].stage == Stage::Delivered);
        assert_eq!(
            source.pending_transfers[&id]
                .source_material
                .as_ref()
                .unwrap()
                .snapshot_counter,
            7
        );
    }

    #[test]
    fn native_transfer_parser_refuses_malformed_keys_identity_and_framing() {
        let (_, recipient, _, _) = pair();
        let encoded = encode(
            &recipient.pending_transfers,
            &recipient.account_id,
            &recipient.device_id,
            recipient.signing_public_key(),
            &recipient.provider,
        )
        .unwrap();
        let read = |bytes: &[u8]| {
            decode(
                bytes,
                &recipient.account_id,
                &recipient.device_id,
                recipient.signing_public_key(),
                &recipient.provider,
            )
        };
        for len in 0..encoded.as_slice().len() {
            assert!(read(&encoded.as_slice()[..len]).is_err());
        }
        for (offset, value) in [(6, 2), (7, 0), (8, 5), (encoded.as_slice().len() - 1, 2)] {
            let mut changed = encoded.as_slice().to_vec();
            changed[offset] = value;
            assert!(read(&changed).is_err());
        }
        let mut changed = encoded.as_slice().to_vec();
        changed[..2].copy_from_slice(&17u16.to_be_bytes());
        assert!(read(&changed).is_err());
        changed = encoded.as_slice().to_vec();
        changed[2..6].copy_from_slice(&((MAX_TRANSFER_BYTES + 1) as u32).to_be_bytes());
        assert!(read(&changed).is_err());
        changed = encoded.as_slice().to_vec();
        changed.push(0);
        assert!(read(&changed).is_err());
        let record = recipient.pending_transfers.values().next().unwrap();
        let private = record.transfer_key.as_ref().unwrap().state_private();
        let position = encoded
            .as_slice()
            .windows(32)
            .position(|bytes| bytes == private)
            .unwrap();
        changed = encoded.as_slice().to_vec();
        changed[position + 16] ^= 1;
        assert!(read(&changed).is_err());
        assert!(decode(
            encoded.as_slice(),
            b"wrong",
            &recipient.device_id,
            recipient.signing_public_key(),
            &recipient.provider
        )
        .is_err());
        assert!(decode(
            encoded.as_slice(),
            &recipient.account_id,
            b"wrong",
            recipient.signing_public_key(),
            &recipient.provider
        )
        .is_err());
        assert!(decode(
            encoded.as_slice(),
            &recipient.account_id,
            &recipient.device_id,
            &[1; 32],
            &recipient.provider
        )
        .is_err());
        // Duplicate or out-of-order map keys cannot produce alternate encodings.
        changed = encoded.as_slice().to_vec();
        changed[..2].copy_from_slice(&2u16.to_be_bytes());
        changed.extend_from_slice(&encoded.as_slice()[2..]);
        assert!(read(&changed).is_err());
    }
}
