//! W12 (ABI 27): verification of the Windows update feed's detached
//! signature (`docs/release-engineering.md`, "Update channel";
//! `docs/crypto.md`, "Update feed signature").
//!
//! The feed (`update.json`) is signed offline by the owner's update key with
//! `scripts/update-feed.py`: strict Ed25519 over [`DOMAIN`] followed by the
//! exact feed bytes. This module only verifies. There is no sign function for
//! this domain anywhere in the library, and [`DOMAIN`] is in neither
//! `c7::SIGN_DOMAINS` nor the L1 list label, so no device key held by the
//! library can be made to produce an update-feed signature, and a signature
//! made for another domain never verifies here.

use ed25519_dalek::{Signature, VerifyingKey};

/// Prepended to the feed bytes before signing and verifying.
pub const DOMAIN: &[u8] = b"veritra-update-feed-v1";
/// The app's `maxUpdateFeedBytes`: the largest feed it downloads.
pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
pub const PUBLIC_KEY_BYTES: usize = 32;
pub const SIGNATURE_BYTES: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UpdateFeedError {
    /// A key that is not 32 bytes, a signature that is not 64 bytes, or a
    /// message that is empty or over [`MAX_MESSAGE_BYTES`].
    InvalidInput,
}

/// The exact bytes the update key signs: [`DOMAIN`], then `message`.
pub fn signing_input(message: &[u8]) -> Result<Vec<u8>, UpdateFeedError> {
    if message.is_empty() || message.len() > MAX_MESSAGE_BYTES {
        return Err(UpdateFeedError::InvalidInput);
    }
    let mut input = Vec::with_capacity(DOMAIN.len() + message.len());
    input.extend_from_slice(DOMAIN);
    input.extend_from_slice(message);
    Ok(input)
}

/// Strict Ed25519 verification of `DOMAIN | message`. `Ok(false)` for every
/// signature that does not verify, a malformed or weak key included; a wrong
/// length is an error.
pub fn verify(
    public_key: &[u8],
    message: &[u8],
    signature: &[u8],
) -> Result<bool, UpdateFeedError> {
    let input = signing_input(message)?;
    let public_key: &[u8; PUBLIC_KEY_BYTES] = public_key
        .try_into()
        .map_err(|_| UpdateFeedError::InvalidInput)?;
    let signature: &[u8; SIGNATURE_BYTES] = signature
        .try_into()
        .map_err(|_| UpdateFeedError::InvalidInput)?;
    let Ok(key) = VerifyingKey::from_bytes(public_key) else {
        return Ok(false);
    };
    Ok(key
        .verify_strict(&input, &Signature::from_bytes(signature))
        .is_ok())
}

#[cfg(test)]
#[path = "update_feed_tests.rs"]
mod tests;
