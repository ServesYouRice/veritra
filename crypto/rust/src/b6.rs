//! B6 (group calls, ABI 22; call-group marker ABI 28): the media-key
//! schedule, the join signature domain and the call-group marker. See
//! `docs/designs/B6-group-calls.md`.
//!
//! The call group's MLS exporter gives one secret `E` per epoch. `E` never
//! leaves the core: only `K(s,t)`, one key per sender leaf and stream slot,
//! does, through one call scoped to [`EXPORTER_LABEL`]. This is the single
//! exception to C7's rule that no stand-alone exporter output leaves the
//! core, and it needs the independent crypto review before release.

use openmls_rust_crypto::RustCrypto;
use openmls_traits::{crypto::OpenMlsCrypto, types::HashType};
use sha2::{Digest, Sha256};
use tls_codec::SecretVLBytes;

/// The one exporter label B6 uses.
pub const EXPORTER_LABEL: &str = "veritra-b6-media-v1";
/// HKDF salt of the per-sender key.
pub const SENDER_SALT: &[u8] = b"veritra-b6-sender-v1";
/// Join signature domain. Rust prepends it; it is in the C7 sign list, so
/// `pm_crypto_c7_sign` and `pm_crypto_c7_verify` carry it.
pub const SIGN_DOMAIN_JOIN: &[u8] = b"veritra-b6-join-v1";

pub const KEY_BYTES: usize = 32;
pub const MAX_ID_BYTES: usize = 128;
/// Stream slots: voice, camera, screen, screen audio.
pub const STREAM_SLOTS: u8 = 4;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum B6Error {
    InvalidInput,
    Crypto,
}

fn lp(out: &mut Vec<u8>, value: &[u8]) -> Result<(), B6Error> {
    if value.is_empty() || value.len() > MAX_ID_BYTES {
        return Err(B6Error::InvalidInput);
    }
    out.extend_from_slice(&(value.len() as u16).to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

/// The exporter context: `lp(call_id) | u64(epoch)`.
pub fn exporter_context(call_id: &[u8], epoch: u64) -> Result<Vec<u8>, B6Error> {
    let mut out = Vec::new();
    lp(&mut out, call_id)?;
    out.extend_from_slice(&epoch.to_be_bytes());
    Ok(out)
}

/// `K(s,t) = HKDF-SHA256(salt = SENDER_SALT, ikm = E,
/// info = u32(leaf) | u8(stream), 32)`.
pub fn sender_key(
    exporter_secret: &[u8],
    leaf_index: u32,
    stream: u8,
) -> Result<SecretVLBytes, B6Error> {
    if exporter_secret.len() != KEY_BYTES || stream >= STREAM_SLOTS {
        return Err(B6Error::InvalidInput);
    }
    let mut info = Vec::with_capacity(5);
    info.extend_from_slice(&leaf_index.to_be_bytes());
    info.push(stream);
    let crypto = RustCrypto::default();
    let prk = crypto
        .hkdf_extract(HashType::Sha2_256, SENDER_SALT, exporter_secret)
        .map_err(|_| B6Error::Crypto)?;
    let okm = crypto
        .hkdf_expand(HashType::Sha2_256, prk.as_slice(), &info, KEY_BYTES)
        .map_err(|_| B6Error::Crypto)?;
    if okm.as_slice().len() != KEY_BYTES {
        return Err(B6Error::Crypto);
    }
    Ok(okm)
}

/// ABI 28: the GroupContext extension type of the call-group marker
/// (private-use range; C4 is `0xF0C4`, the L2 pad `0xF0A2`).
pub const CALL_EXTENSION_TYPE: u16 = 0xF0B6;
/// Format byte of the marker's data.
pub const CALL_MARKER_FORMAT: u8 = 1;

/// The call-group marker's data:
/// `u8(1) | lp(call_id) | lp(conversation_id)`, each id 1 to 128 bytes.
pub fn encode_call_marker(call_id: &[u8], conversation_id: &[u8]) -> Result<Vec<u8>, B6Error> {
    let mut out = vec![CALL_MARKER_FORMAT];
    lp(&mut out, call_id)?;
    lp(&mut out, conversation_id)?;
    Ok(out)
}

fn read_lp<'a>(input: &mut &'a [u8]) -> Result<&'a [u8], B6Error> {
    let (len, rest) = input
        .split_first_chunk::<2>()
        .ok_or(B6Error::InvalidInput)?;
    let len = usize::from(u16::from_be_bytes(*len));
    if len == 0 || len > MAX_ID_BYTES || rest.len() < len {
        return Err(B6Error::InvalidInput);
    }
    let (value, rest) = rest.split_at(len);
    *input = rest;
    Ok(value)
}

/// Decodes a marker strictly: format 1, both ids 1 to 128 bytes, nothing
/// after them. Returns `(call_id, conversation_id)`.
pub fn decode_call_marker(data: &[u8]) -> Result<(&[u8], &[u8]), B6Error> {
    let Some((&CALL_MARKER_FORMAT, mut rest)) = data.split_first() else {
        return Err(B6Error::InvalidInput);
    };
    let call_id = read_lp(&mut rest)?;
    let conversation_id = read_lp(&mut rest)?;
    if !rest.is_empty() {
        return Err(B6Error::InvalidInput);
    }
    Ok((call_id, conversation_id))
}

/// The signed message of a join, without the domain:
/// `lp(group_id) | lp(nonce) | u64(expires_at) | sha256(key_package)`.
pub fn join_message(
    group_id: &[u8],
    nonce: &[u8],
    expires_at: u64,
    key_package: &[u8],
) -> Result<Vec<u8>, B6Error> {
    if key_package.is_empty() {
        return Err(B6Error::InvalidInput);
    }
    let mut out = Vec::new();
    lp(&mut out, group_id)?;
    lp(&mut out, nonce)?;
    out.extend_from_slice(&expires_at.to_be_bytes());
    out.extend_from_slice(&Sha256::digest(key_package));
    Ok(out)
}

#[cfg(test)]
#[path = "b6_tests.rs"]
mod tests;
