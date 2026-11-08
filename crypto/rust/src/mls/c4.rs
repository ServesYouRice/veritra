//! C4 (ABI 20): the group role record as a Veritra GroupContext extension.
//!
//! Design: `docs/designs/C4-custom-roles.md`, wire rules in `docs/crypto.md`
//! ("Group role state (C4)"). Rust treats the record as opaque bytes; only
//! Dart decodes it (`governance_codec.dart`) and judges a change
//! (`validateCommit`). Rust enforces the carrier:
//!
//! - every leaf advertises extension type [`ROLE_EXTENSION_TYPE`];
//! - a record group lists it in its required capabilities from creation;
//! - a commit changes it only through one GroupContextExtensions proposal,
//!   by value, that rewrites this extension and leaves every other context
//!   extension byte for byte as it was;
//! - a remote commit is staged, reviewed by Dart, then merged or discarded.

use super::*;
use std::collections::HashMap;
use std::sync::Mutex;

/// The Veritra role record's GroupContext extension type (private-use range).
pub const ROLE_EXTENSION_TYPE: u16 = 0xF0C4;
/// The record codec's own ceiling (`docs/crypto.md`, format v2: 256 KiB).
pub const MAX_ROLE_RECORD_BYTES: usize = 256 * 1024;
/// Format byte of [`CommitReview::encode`] and [`encode_role_state`].
const REVIEW_FORMAT: u8 = 1;
const STATE_FORMAT: u8 = 1;

pub const REVIEW_REMOVED: u8 = 1;
pub const REVIEW_ADDED: u8 = 2;
pub const REVIEW_REMOVED_SELF: u8 = 4;
pub const REVIEW_RECORD_PROPOSAL: u8 = 8;
pub const REVIEW_RECORD_BEFORE: u8 = 16;
pub const REVIEW_RECORD_AFTER: u8 = 32;

fn role_type() -> ExtensionType {
    ExtensionType::Unknown(ROLE_EXTENSION_TYPE)
}

/// The capabilities every Veritra leaf advertises: OpenMLS's defaults plus
/// the role extension. Key packages and a creator's leaf use it, so any
/// ABI 20 device can join a record group.
pub(super) fn leaf_capabilities() -> Capabilities {
    Capabilities::new(None, None, Some(&[role_type()]), None, None)
}

/// A record is 1 to [`MAX_ROLE_RECORD_BYTES`] bytes; nothing else is
/// checked here (the codec and the rules are Dart's).
pub(super) fn check_record(record: &[u8]) -> Result<(), MlsError> {
    if record.is_empty() || record.len() > MAX_ROLE_RECORD_BYTES {
        return Err(MlsError::InvalidState);
    }
    Ok(())
}

/// The role record a group context carries, if any.
pub(super) fn record_of(extensions: &Extensions<GroupContext>) -> Option<&[u8]> {
    extensions
        .unknown(ROLE_EXTENSION_TYPE)
        .map(|unknown| unknown.0.as_slice())
}

/// Whether the context's required capabilities name the role extension.
fn requires_role(extensions: &Extensions<GroupContext>) -> bool {
    extensions
        .required_capabilities()
        .is_some_and(|required| required.extension_types().contains(&role_type()))
}

/// The genesis context extensions of a record group: required capabilities
/// naming the role extension, then the record.
pub(super) fn genesis_extensions(record: &[u8]) -> Result<Extensions<GroupContext>, MlsError> {
    check_record(record)?;
    Extensions::from_vec(vec![
        Extension::RequiredCapabilities(RequiredCapabilitiesExtension::new(
            &[role_type()],
            &[],
            &[],
        )),
        Extension::Unknown(ROLE_EXTENSION_TYPE, UnknownExtension(record.to_vec())),
    ])
    .map_err(|_| MlsError::InvalidState)
}

/// The extension list a record proposal must carry: `current` in its order
/// with the role record's data replaced by `record`. Refused for a group
/// without a record (no migration: C0's rule), a malformed size, or a
/// record equal to the current one (a no-op proposal is never sent).
pub(super) fn replaced_extensions(
    current: &Extensions<GroupContext>,
    record: &[u8],
) -> Result<Extensions<GroupContext>, MlsError> {
    check_record(record)?;
    match record_of(current) {
        Some(existing) if existing != record => {}
        _ => return Err(MlsError::InvalidState),
    }
    let replaced = current
        .iter()
        .map(|extension| match extension {
            Extension::Unknown(ROLE_EXTENSION_TYPE, _) => {
                Extension::Unknown(ROLE_EXTENSION_TYPE, UnknownExtension(record.to_vec()))
            }
            other => other.clone(),
        })
        .collect();
    Extensions::from_vec(replaced).map_err(|_| MlsError::InvalidState)
}

/// The receiver's rule for a GroupContextExtensions proposal (C4 item 3):
/// the group already carries a record and requires the role extension; the
/// proposal lists the same extensions in the same order, each byte for byte
/// as now except the role record; the new record is well-formed in size and
/// differs from the current one. Anything else is refused.
pub(super) fn check_record_proposal(
    current: &Extensions<GroupContext>,
    proposed: &Extensions<GroupContext>,
) -> Result<(), MlsError> {
    let refused = MlsError::UnexpectedMessage;
    let before = record_of(current).ok_or(refused)?;
    if !requires_role(current) {
        return Err(refused);
    }
    let after = record_of(proposed).ok_or(refused)?;
    if after.is_empty() || after.len() > MAX_ROLE_RECORD_BYTES || after == before {
        return Err(refused);
    }
    let old: Vec<_> = current.iter().collect();
    let new: Vec<_> = proposed.iter().collect();
    if old.len() != new.len() {
        return Err(refused);
    }
    for (old, new) in old.iter().zip(&new) {
        if old.extension_type() != new.extension_type() {
            return Err(refused);
        }
        if old.extension_type() == role_type() {
            continue;
        }
        let old = old.tls_serialize_detached().map_err(|_| refused)?;
        let new = new.tls_serialize_detached().map_err(|_| refused)?;
        if old != new {
            return Err(refused);
        }
    }
    Ok(())
}

/// The structural rule for a group a Welcome brings in: a record, when
/// present, is well-formed in size and the group requires the role
/// extension, so every later member must support it.
pub(super) fn check_joined_context(extensions: &Extensions<GroupContext>) -> Result<(), MlsError> {
    match record_of(extensions) {
        None => Ok(()),
        Some(record) => {
            if record.is_empty()
                || record.len() > MAX_ROLE_RECORD_BYTES
                || !requires_role(extensions)
            {
                return Err(MlsError::InvalidIdentity);
            }
            Ok(())
        }
    }
}

/// The distinct accounts of `identities`, sorted by bytes.
fn accounts<'a>(identities: impl Iterator<Item = &'a [u8]>) -> Result<Vec<Vec<u8>>, MlsError> {
    let mut accounts = identities
        .map(|identity| decode_device_identity(identity).map(|(account, _)| account.to_vec()))
        .collect::<Result<Vec<_>, _>>()?;
    accounts.sort();
    accounts.dedup();
    Ok(accounts)
}

/// The account roster of `group` as it is now.
pub(super) fn roster_accounts(group: &MlsGroup) -> Result<Vec<Vec<u8>>, MlsError> {
    let identities = roster_identities(group, &[]);
    accounts(identities.iter().map(Vec::as_slice))
}

/// The account roster `staged` produces. Exact only once `inspect_commit`
/// passed: it guarantees that updates keep each leaf's identity, so the
/// roster after is the remaining leaves plus the added ones.
fn roster_after(group: &MlsGroup, staged: &StagedCommit) -> Result<Vec<Vec<u8>>, MlsError> {
    let removed: Vec<_> = staged
        .remove_proposals()
        .map(|proposal| proposal.remove_proposal().removed())
        .collect();
    let mut identities = roster_identities(group, &removed);
    for proposal in staged.add_proposals() {
        identities.push(
            proposal
                .add_proposal()
                .key_package()
                .leaf_node()
                .credential()
                .serialized_content()
                .to_vec(),
        );
    }
    accounts(identities.iter().map(Vec::as_slice))
}

/// What Dart needs to judge a staged remote commit before it is merged.
pub struct CommitReview {
    pub flags: u8,
    pub new_epoch: u64,
    pub committer: LeafPair,
    pub added: Vec<LeafPair>,
    pub roster_before: Vec<Vec<u8>>,
    pub roster_after: Vec<Vec<u8>>,
    pub record_before: Option<Vec<u8>>,
    pub record_after: Option<Vec<u8>>,
}

impl CommitReview {
    fn of(group: &MlsGroup, staged: &StagedCommit, committer: LeafPair) -> Result<Self, MlsError> {
        let added = staged
            .add_proposals()
            .map(|proposal| {
                let leaf = proposal.add_proposal().key_package().leaf_node();
                LeafPair::from_credential(leaf.credential(), leaf.signature_key().as_slice())
            })
            .collect::<Result<Vec<_>, _>>()?;
        let record_proposal = staged
            .queued_proposals()
            .any(|proposal| matches!(proposal.proposal(), Proposal::GroupContextExtensions(_)));
        let record_before = record_of(group.extensions()).map(<[u8]>::to_vec);
        let record_after = record_of(staged.group_context().extensions()).map(<[u8]>::to_vec);
        let mut flags = 0;
        for (set, flag) in [
            (staged.remove_proposals().next().is_some(), REVIEW_REMOVED),
            (staged.add_proposals().next().is_some(), REVIEW_ADDED),
            (staged.self_removed(), REVIEW_REMOVED_SELF),
            (record_proposal, REVIEW_RECORD_PROPOSAL),
            (record_before.is_some(), REVIEW_RECORD_BEFORE),
            (record_after.is_some(), REVIEW_RECORD_AFTER),
        ] {
            if set {
                flags |= flag;
            }
        }
        // Without a record proposal the context extensions cannot change.
        if !record_proposal && record_before != record_after {
            return Err(MlsError::UnexpectedMessage);
        }
        Ok(Self {
            flags,
            new_epoch: staged.epoch().as_u64(),
            committer,
            added,
            roster_before: roster_accounts(group)?,
            roster_after: roster_after(group, staged)?,
            record_before,
            record_after,
        })
    }

    /// ```text
    /// u8  format = 1
    /// u8  flags      1 removed, 2 added, 4 removed self, 8 record proposal,
    ///                16 record before present, 32 record after present
    /// u64 new_epoch
    /// committer      lp16(account) lp16(device) [32] signature key
    /// u16 n_added    { lp16(account) lp16(device) [32] key }*
    /// u16 n_before   { lp16(account) }*   sorted by bytes, distinct
    /// u16 n_after    { lp16(account) }*   sorted by bytes, distinct
    /// u32 len || record_before            len 0 when absent
    /// u32 len || record_after             len 0 when absent
    /// ```
    pub fn encode(&self) -> Result<Vec<u8>, MlsError> {
        let mut out = vec![REVIEW_FORMAT, self.flags];
        out.extend_from_slice(&self.new_epoch.to_be_bytes());
        put_pair(&mut out, &self.committer)?;
        put_count(&mut out, self.added.len())?;
        for pair in &self.added {
            put_pair(&mut out, pair)?;
        }
        put_accounts(&mut out, &self.roster_before)?;
        put_accounts(&mut out, &self.roster_after)?;
        put_record(&mut out, self.record_before.as_deref())?;
        put_record(&mut out, self.record_after.as_deref())?;
        Ok(out)
    }
}

/// `u8 format = 1 | u8 flags (1: record present) | u16 n { lp16(account) }*
/// | u32 len || record` (len 0 when absent).
pub fn encode_role_state(record: Option<&[u8]>, roster: &[Vec<u8>]) -> Result<Vec<u8>, MlsError> {
    let mut out = vec![STATE_FORMAT, u8::from(record.is_some())];
    put_accounts(&mut out, roster)?;
    put_record(&mut out, record)?;
    Ok(out)
}

fn put_count(out: &mut Vec<u8>, count: usize) -> Result<(), MlsError> {
    out.extend_from_slice(
        &u16::try_from(count)
            .map_err(|_| MlsError::InvalidState)?
            .to_be_bytes(),
    );
    Ok(())
}

fn put_pair(out: &mut Vec<u8>, pair: &LeafPair) -> Result<(), MlsError> {
    if pair.signing_key.len() != 32 {
        return Err(MlsError::InvalidIdentity);
    }
    append_transcript_field(out, &pair.account_id)?;
    append_transcript_field(out, &pair.device_id)?;
    out.extend_from_slice(&pair.signing_key);
    Ok(())
}

fn put_accounts(out: &mut Vec<u8>, accounts: &[Vec<u8>]) -> Result<(), MlsError> {
    put_count(out, accounts.len())?;
    for account in accounts {
        append_transcript_field(out, account)?;
    }
    Ok(())
}

fn put_record(out: &mut Vec<u8>, record: Option<&[u8]>) -> Result<(), MlsError> {
    let record = record.unwrap_or_default();
    let len = u32::try_from(record.len()).map_err(|_| MlsError::InvalidState)?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(record);
    Ok(())
}

/// The role record of a group (None without one) and its account roster.
pub type RoleState = (Option<Vec<u8>>, Vec<Vec<u8>>);

/// A remote commit staged by [`MlsDevice::stage_incoming_commit`], held in
/// memory (never sealed) until Dart merges or discards it.
pub(super) struct HeldCommit {
    /// The epoch authenticator of the epoch it was staged on: a merge on any
    /// other group state is refused.
    authenticator: Vec<u8>,
    /// SHA-256 of the commit bytes; the merge must name the same commit.
    digest: Vec<u8>,
    committer: LeafPair,
    staged: StagedCommit,
}

/// At most one held commit per group.
#[derive(Default)]
pub(crate) struct HeldCommits(Mutex<HashMap<Vec<u8>, HeldCommit>>);

impl HeldCommits {
    /// Drops what is held for `group_id`. Returns whether something was.
    pub(super) fn forget(&self, group_id: &[u8]) -> Result<bool, MlsError> {
        Ok(self
            .0
            .lock()
            .map_err(|_| MlsError::InvalidState)?
            .remove(group_id)
            .is_some())
    }

    fn put(&self, group_id: Vec<u8>, held: HeldCommit) -> Result<(), MlsError> {
        self.0
            .lock()
            .map_err(|_| MlsError::InvalidState)?
            .insert(group_id, held);
        Ok(())
    }

    /// Takes the held commit for `group_id` only when it was staged on the
    /// group's current epoch and is the commit `digest` names; otherwise it
    /// stays held and nothing changes.
    fn take_matching(
        &self,
        group_id: &[u8],
        authenticator: &[u8],
        digest: &[u8],
    ) -> Result<HeldCommit, MlsError> {
        let mut held = self.0.lock().map_err(|_| MlsError::InvalidState)?;
        match held.get(group_id) {
            Some(entry) if entry.authenticator == authenticator && entry.digest == digest => {
                held.remove(group_id).ok_or(MlsError::InvalidState)
            }
            _ => Err(MlsError::InvalidState),
        }
    }

    #[cfg(test)]
    pub(super) fn holds(&self, group_id: &[u8]) -> bool {
        self.0
            .lock()
            .map(|held| held.contains_key(group_id))
            .unwrap_or(false)
    }
}

impl MlsDevice {
    /// C4 item 2: creates a record group. Its context requires the role
    /// extension and carries `record` (Dart: `encodeGovernance(
    /// GovernanceState.genesis(creator))`), so the owner comes from MLS.
    pub fn create_group_with_record(
        &self,
        group_id: &[u8],
        record: &[u8],
    ) -> Result<MlsGroup, MlsError> {
        if group_id.is_empty() || group_id.len() > MAX_ID_BYTES {
            return Err(MlsError::InvalidIdentity);
        }
        let config = group_create_config_with(Some(genesis_extensions(record)?));
        self.held.forget(group_id)?;
        self.in_group(group_id, || {
            MlsGroup::new_with_group_id(
                &self.provider,
                &self.signer,
                &config,
                GroupId::from_slice(group_id),
                self.credential.clone(),
            )
            .map_err(|_| MlsError::GroupOperation)
        })
    }

    /// C4 item 4, phase one: processes a remote commit up to the staged
    /// commit, runs `inspect_commit` (a record proposal allowed), and holds
    /// the staged commit without merging it. The group's stored epoch does
    /// not move. Staging again for the same group replaces what was held.
    ///
    /// The handshake ratchet step the commit used is persisted by OpenMLS
    /// when it is staged, so the same bytes cannot be staged twice: after a
    /// discard the app restores its committed state and does not seal.
    pub fn stage_incoming_commit(
        &self,
        group: &mut MlsGroup,
        commit: &[u8],
    ) -> Result<CommitReview, MlsError> {
        let protocol_message = MlsMessageIn::tls_deserialize_exact(commit)
            .map_err(|_| MlsError::InvalidMessage)?
            .try_into_protocol_message()
            .map_err(|_| MlsError::InvalidMessage)?;
        let id = group.group_id().as_slice().to_vec();
        self.held.forget(&id)?;
        let authenticator = group.epoch_authenticator().as_slice().to_vec();
        let (review, staged, committer) = self.in_group(&id, || {
            let processed = group
                .process_message(&self.provider, protocol_message)
                .map_err(|_| MlsError::InvalidMessage)?;
            let Sender::Member(committer) = *processed.sender() else {
                return Err(MlsError::UnexpectedMessage);
            };
            let ProcessedMessageContent::StagedCommitMessage(staged) = processed.into_content()
            else {
                return Err(MlsError::UnexpectedMessage);
            };
            inspect_commit(group, committer, &staged, true)?;
            let member = group
                .member_at(committer)
                .ok_or(MlsError::InvalidIdentity)?;
            let committer = LeafPair::from_credential(&member.credential, &member.signature_key)?;
            let review = CommitReview::of(group, &staged, committer.clone())?;
            Ok((review, *staged, committer))
        })?;
        self.held.put(
            id,
            HeldCommit {
                authenticator,
                digest: Sha256::digest(commit).to_vec(),
                committer,
                staged,
            },
        )?;
        Ok(review)
    }

    /// C4 item 4, phase two: merges the commit held for this group, as
    /// [`Self::process_commit_with_outcome`] would have. `commit` must be
    /// the bytes that were staged, and the group must still be on the epoch
    /// they were staged on; otherwise nothing changes and the commit stays
    /// held. The C7 root is computed here, never at staging, so a discarded
    /// commit lets no exporter output out.
    pub fn merge_incoming_commit(
        &self,
        group: &mut MlsGroup,
        commit: &[u8],
    ) -> Result<CommitOutcome, MlsError> {
        let id = group.group_id().as_slice().to_vec();
        let held = self.held.take_matching(
            &id,
            group.epoch_authenticator().as_slice(),
            &Sha256::digest(commit),
        )?;
        let outcome = self.in_group(&id, || {
            let outcome = self.commit_outcome(&id, &held.staged, held.committer)?;
            group
                .merge_staged_commit(&self.provider, held.staged)
                .map_err(|_| MlsError::GroupOperation)?;
            Ok(outcome)
        })?;
        if !group.is_active() {
            self.provider.storage().drop_group(&id)?;
        }
        Ok(outcome)
    }

    /// Drops the commit held for `group_id` (Dart refused it). The group is
    /// not touched. Returns whether one was held.
    pub fn discard_incoming_commit(&self, group_id: &[u8]) -> Result<bool, MlsError> {
        self.held.forget(group_id)
    }

    /// C4 item 5: the current role record (None in a group without one) and
    /// the account roster, for after a join or a restore.
    pub fn role_state(&self, group: &MlsGroup) -> Result<RoleState, MlsError> {
        Ok((
            record_of(group.extensions()).map(<[u8]>::to_vec),
            roster_accounts(group)?,
        ))
    }
}

#[cfg(test)]
#[path = "c4_tests.rs"]
mod tests;
