//! C4 leave proof in the commit (ABI 24).
//!
//! Design and wire rules: `docs/crypto.md`, "C4 leave proof in the commit".
//! A governing member that leaves signs one statement with its leaf
//! signature key; a committer that removes it carries the statement in the
//! commit's authenticated data, so a member that joined after the leave
//! (and so never received the leaver's `member_leave`) can still verify the
//! removal was consented to.
//!
//! ```text
//! LeaveTBS    = VL(group_id) || u32 leaf_index || tls(EncryptionKey)
//! signature   = Ed25519(SignContent("VeritraC4Leave1", LeaveTBS))  (RFC 9420 SignWithLabel)
//! statement   = u32 leaf_index || u16 len (= 64) || signature       (70 bytes)
//! commit AAD  = "VCL1" || u8 count (1..16) || statement*            (leaf indices distinct)
//! ```
//!
//! The statement binds the leaf's HPKE encryption key, so it verifies only
//! while that leaf is unchanged: a self-update or a leave and re-add makes
//! it void. Nothing malformed here is ever a refusal of a received commit:
//! it proves nothing ([`proven_leaves`]).

use super::*;
use ed25519_dalek::{Signature, VerifyingKey};

/// The SignWithLabel label (RFC 9420 prefixes "MLS 1.0 ").
pub const LEAVE_LABEL: &[u8] = b"VeritraC4Leave1";
/// The first bytes of a commit AAD that carries leave statements.
pub const AAD_MAGIC: &[u8; 4] = b"VCL1";
/// Most statements one commit carries.
pub const MAX_STATEMENTS: usize = 16;
const SIGNATURE_BYTES: usize = 64;
/// Length of one encoded statement.
pub const STATEMENT_BYTES: usize = 4 + 2 + SIGNATURE_BYTES;

/// One leaver's signed statement.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LeaveStatement {
    pub leaf_index: u32,
    pub signature: [u8; SIGNATURE_BYTES],
}

impl LeaveStatement {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(STATEMENT_BYTES);
        self.put(&mut out);
        out
    }

    fn put(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.leaf_index.to_be_bytes());
        out.extend_from_slice(&(SIGNATURE_BYTES as u16).to_be_bytes());
        out.extend_from_slice(&self.signature);
    }

    /// Exactly one statement of [`STATEMENT_BYTES`].
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != STATEMENT_BYTES {
            return None;
        }
        Self::read(bytes).map(|(statement, _)| statement)
    }

    fn read(bytes: &[u8]) -> Option<(Self, &[u8])> {
        if bytes.len() < STATEMENT_BYTES {
            return None;
        }
        let leaf_index = u32::from_be_bytes(bytes[0..4].try_into().ok()?);
        if u16::from_be_bytes(bytes[4..6].try_into().ok()?) as usize != SIGNATURE_BYTES {
            return None;
        }
        let signature = bytes[6..STATEMENT_BYTES].try_into().ok()?;
        Some((
            Self {
                leaf_index,
                signature,
            },
            &bytes[STATEMENT_BYTES..],
        ))
    }
}

/// RFC 9420 section 2.1.2 variable-length vector prefix and body.
fn put_vl(out: &mut Vec<u8>, bytes: &[u8]) -> Result<(), MlsError> {
    let n = bytes.len();
    match n {
        0..=63 => out.push(n as u8),
        64..=16383 => out.extend_from_slice(&(0x4000 | n as u16).to_be_bytes()),
        16384..=0x3fff_ffff => out.extend_from_slice(&(0x8000_0000 | n as u32).to_be_bytes()),
        _ => return Err(MlsError::InvalidState),
    }
    out.extend_from_slice(bytes);
    Ok(())
}

/// `LeaveTBS` for a leaf: the group id, the leaf index and the TLS encoding
/// of the leaf's `EncryptionKey` (`opaque<V>`, as in the tree).
pub fn leave_tbs(
    group_id: &[u8],
    leaf_index: u32,
    encryption_key: &[u8],
) -> Result<Vec<u8>, MlsError> {
    let mut out = Vec::with_capacity(group_id.len() + encryption_key.len() + 8);
    put_vl(&mut out, group_id)?;
    out.extend_from_slice(&leaf_index.to_be_bytes());
    out.extend_from_slice(encryption_key);
    Ok(out)
}

/// The bytes Ed25519 signs: RFC 9420 `SignContent` with label
/// `"MLS 1.0 VeritraC4Leave1"`. It starts with the varint 0x17, which no
/// other raw signing domain of this crate starts with (every one is ASCII
/// `veritra-...`), and its label is none of RFC 9420's.
pub fn sign_content(tbs: &[u8]) -> Result<Vec<u8>, MlsError> {
    let mut label = b"MLS 1.0 ".to_vec();
    label.extend_from_slice(LEAVE_LABEL);
    let mut out = Vec::with_capacity(label.len() + tbs.len() + 6);
    put_vl(&mut out, &label)?;
    put_vl(&mut out, tbs)?;
    Ok(out)
}

/// The AAD for 1 to [`MAX_STATEMENTS`] statements with distinct leaves.
pub fn encode_aad(statements: &[LeaveStatement]) -> Result<Vec<u8>, MlsError> {
    if statements.is_empty() || statements.len() > MAX_STATEMENTS || !distinct(statements) {
        return Err(MlsError::InvalidState);
    }
    let mut out = Vec::with_capacity(5 + statements.len() * STATEMENT_BYTES);
    out.extend_from_slice(AAD_MAGIC);
    out.push(statements.len() as u8);
    for statement in statements {
        statement.put(&mut out);
    }
    Ok(out)
}

/// The statements of a well-formed AAD, or None: another magic, a count
/// outside 1..16, a bad length, trailing bytes or a repeated leaf.
pub fn parse_aad(bytes: &[u8]) -> Option<Vec<LeaveStatement>> {
    let rest = bytes.strip_prefix(AAD_MAGIC.as_slice())?;
    let (&count, mut rest) = rest.split_first()?;
    let count = count as usize;
    if count == 0 || count > MAX_STATEMENTS {
        return None;
    }
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let (statement, next) = LeaveStatement::read(rest)?;
        out.push(statement);
        rest = next;
    }
    (rest.is_empty() && distinct(&out)).then_some(out)
}

fn distinct(statements: &[LeaveStatement]) -> bool {
    let mut leaves: Vec<u32> = statements.iter().map(|s| s.leaf_index).collect();
    leaves.sort_unstable();
    leaves.windows(2).all(|pair| pair[0] != pair[1])
}

/// The leaf a statement names, in `group`'s current tree, when the
/// statement verifies against it.
fn verified_leaf<'a>(group: &'a MlsGroup, statement: &LeaveStatement) -> Option<&'a LeafNode> {
    let leaf = group
        .public_group()
        .leaf(LeafNodeIndex::new(statement.leaf_index))?;
    let encryption_key = leaf.encryption_key().tls_serialize_detached().ok()?;
    let tbs = leave_tbs(
        group.group_id().as_slice(),
        statement.leaf_index,
        &encryption_key,
    )
    .ok()?;
    let content = sign_content(&tbs).ok()?;
    let key: [u8; 32] = leaf.signature_key().as_slice().try_into().ok()?;
    VerifyingKey::from_bytes(&key)
        .ok()?
        .verify_strict(&content, &Signature::from_bytes(&statement.signature))
        .ok()?;
    Some(leaf)
}

/// The statements of `statements` whose leaf is in `removed` and that
/// verify against `group`'s tree before the commit.
fn verified<'a>(
    group: &MlsGroup,
    removed: &[LeafNodeIndex],
    statements: &'a [LeaveStatement],
) -> Vec<(&'a LeaveStatement, LeafPair)> {
    statements
        .iter()
        .filter(|statement| removed.contains(&LeafNodeIndex::new(statement.leaf_index)))
        .filter_map(|statement| {
            let leaf = verified_leaf(group, statement)?;
            let pair =
                LeafPair::from_credential(leaf.credential(), leaf.signature_key().as_slice())
                    .ok()?;
            Some((statement, pair))
        })
        .collect()
}

/// Receiver: the leaves a commit's AAD proves gone by their own consent.
/// `group` is the state before the commit. Anything malformed proves
/// nothing.
pub(super) fn proven_leaves(
    group: &MlsGroup,
    removed: &[LeafNodeIndex],
    aad: &[u8],
) -> Vec<LeafPair> {
    match parse_aad(aad) {
        Some(statements) => verified(group, removed, &statements)
            .into_iter()
            .map(|(_, pair)| pair)
            .collect(),
        None => Vec::new(),
    }
}

/// Committer: the AAD to attach for a commit that removes `removed`, from
/// the statements the app holds (`proofs`, an AAD-shaped list). Statements
/// that no longer verify (the leaf changed) or name a leaf the commit keeps
/// are dropped; None when none is left. A malformed list is refused.
pub(super) fn committer_aad(
    group: &MlsGroup,
    removed: &[LeafNodeIndex],
    proofs: &[u8],
) -> Result<Option<Vec<u8>>, MlsError> {
    let statements = parse_aad(proofs).ok_or(MlsError::InvalidMessage)?;
    let kept: Vec<LeaveStatement> = verified(group, removed, &statements)
        .into_iter()
        .map(|(statement, _)| statement.clone())
        .collect();
    if kept.is_empty() {
        return Ok(None);
    }
    encode_aad(&kept).map(Some)
}

impl MlsDevice {
    /// Signs this device's leave statement for `group`: its own leaf index
    /// and leaf encryption key now. Valid until this leaf changes.
    pub fn sign_leave(&self, group: &MlsGroup) -> Result<Vec<u8>, MlsError> {
        let leaf = group.own_leaf_node().ok_or(MlsError::InvalidState)?;
        let leaf_index = group.own_leaf_index().u32();
        let encryption_key = leaf
            .encryption_key()
            .tls_serialize_detached()
            .map_err(|_| MlsError::GroupOperation)?;
        let tbs = leave_tbs(group.group_id().as_slice(), leaf_index, &encryption_key)?;
        let signature: [u8; SIGNATURE_BYTES] = self
            .signer
            .sign(&sign_content(&tbs)?)
            .map_err(|_| MlsError::GroupOperation)?
            .try_into()
            .map_err(|_| MlsError::GroupOperation)?;
        Ok(LeaveStatement {
            leaf_index,
            signature,
        }
        .encode())
    }
}

#[cfg(test)]
#[path = "leave_proof_tests.rs"]
mod tests;
