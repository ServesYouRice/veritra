//! L2-3 designated-verifier ("owner-only") franking of a sealed message
//! (owner decision 2026-11-12, ABI 26). Replaces the transferable Ed25519
//! franking signature `s`.
//!
//! A sealed sender proves "this device committed to `c`" to each instance
//! owner its app pinned, with a MAC under a static-static X25519 secret that
//! only the sender's device and that owner can compute. Nobody else can
//! check a tag, and the owner could have made it itself, so a leaked
//! `(P, kf, d)` convinces no third party (`docs/crypto.md`, "Franking a
//! sealed message", which also has the proof sketch).
//!
//! ```text
//! F_S = the sender device's franking public key (X25519), listed in its
//!       account's signed L1 device list (format 2, change 7)
//! pk_V = an owner's C6 report public key (X25519, from its report seed)
//! Z    = X25519(f_S, pk_V) == X25519(sk_V, F_S); refused when all zero
//! kid  = SHA-256("veritra-frank-dv-kid-v1" || pk_V)[0..16]
//! K    = HKDF-SHA256(salt = "veritra-frank-dv-v1", ikm = Z,
//!                    info = "veritra-frank-dv-v1 key" || F_S || pk_V), 32 bytes
//! t    = HMAC-SHA256(K, "veritra-frank-dv-v1" || lp(conversation_id)
//!                       || lp(account_id) || lp(device_id) || kid || c)
//! entry = kid || t          (48 bytes)
//! d     = entries sorted strictly ascending by kid, 1 to 16 of them
//! ```
//!
//! `lp` is a u16 big-endian length; ids are 1 to 128 bytes. `c` is the
//! 32-byte C6 franking commitment (`report::frank_commit`).
//!
//! Public keys are accepted only in their canonical spelling (bit 255 clear,
//! u < p) and never at a low-order point ([`crate::report`]'s list), so one
//! key has one encoding and `Z` is never forced. Secrets live in
//! `x25519_dalek::StaticSecret` (zeroized on drop) and HKDF/HMAC outputs in
//! `SecretVLBytes`; no function here returns a secret.

use crate::report;
use openmls_rust_crypto::RustCrypto;
use openmls_traits::{crypto::OpenMlsCrypto, types::HashType};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};

pub const LABEL: &[u8] = b"veritra-frank-dv-v1";
pub const KID_LABEL: &[u8] = b"veritra-frank-dv-kid-v1";
pub const KEY_LABEL: &[u8] = b"veritra-frank-dv-v1 key";
pub const KEY_BYTES: usize = 32;
pub const KID_BYTES: usize = 16;
pub const TAG_BYTES: usize = 32;
pub const ENTRY_BYTES: usize = KID_BYTES + TAG_BYTES;
/// Most verifier keys one message is designated to.
pub const MAX_VERIFIERS: usize = 16;
pub const COMMIT_BYTES: usize = 32;
pub const MAX_ID_BYTES: usize = 128;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DvError {
    /// A malformed or out-of-range argument.
    InvalidInput,
    /// An internal HKDF/HMAC failure.
    Crypto,
}

/// What an owner learns from a designation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DvVerdict {
    /// An entry for this owner's key exists and its tag does not check, or
    /// the designation or the sender key is unusable.
    Mismatch = 0,
    /// The tag for this owner's key checks.
    Valid = 1,
    /// The designation has no entry for this owner's key.
    NotDesignated = 2,
}

/// `p = 2^255 - 19`, little-endian.
const P: [u8; 32] = {
    let mut p = [0xffu8; 32];
    p[0] = 0xed;
    p[31] = 0x7f;
    p
};

/// Whether `u` (little-endian) is below `p`.
fn below_p(u: &[u8; 32]) -> bool {
    for index in (0..32).rev() {
        if u[index] != P[index] {
            return u[index] < P[index];
        }
    }
    false
}

/// A franking or report public key as this module accepts it: 32 bytes,
/// canonical (bit 255 clear, u < p), not a low-order point.
pub fn check_public(key: &[u8]) -> Result<[u8; KEY_BYTES], DvError> {
    let bytes: [u8; KEY_BYTES] = key.try_into().map_err(|_| DvError::InvalidInput)?;
    if bytes[31] & 0x80 != 0 || !below_p(&bytes) || report::is_low_order(&bytes) {
        return Err(DvError::InvalidInput);
    }
    Ok(bytes)
}

/// The 16-byte id of a verifier key.
pub fn kid(verifier_public: &[u8]) -> Result<[u8; KID_BYTES], DvError> {
    let key = check_public(verifier_public)?;
    let digest = Sha256::new()
        .chain_update(KID_LABEL)
        .chain_update(key)
        .finalize();
    let mut out = [0u8; KID_BYTES];
    out.copy_from_slice(&digest[..KID_BYTES]);
    Ok(out)
}

fn push_id(out: &mut Vec<u8>, id: &[u8]) -> Result<(), DvError> {
    if id.is_empty() || id.len() > MAX_ID_BYTES {
        return Err(DvError::InvalidInput);
    }
    out.extend_from_slice(&(id.len() as u16).to_be_bytes());
    out.extend_from_slice(id);
    Ok(())
}

/// The MAC input: `label || lp(conversation) || lp(account) || lp(device)
/// || kid || commit`.
pub fn tag_input(
    conversation_id: &[u8],
    account_id: &[u8],
    device_id: &[u8],
    kid: &[u8; KID_BYTES],
    commit: &[u8],
) -> Result<Vec<u8>, DvError> {
    if commit.len() != COMMIT_BYTES {
        return Err(DvError::InvalidInput);
    }
    let mut out = Vec::with_capacity(LABEL.len() + 6 + 3 * MAX_ID_BYTES + KID_BYTES + COMMIT_BYTES);
    out.extend_from_slice(LABEL);
    push_id(&mut out, conversation_id)?;
    push_id(&mut out, account_id)?;
    push_id(&mut out, device_id)?;
    out.extend_from_slice(kid);
    out.extend_from_slice(commit);
    Ok(out)
}

/// The tag over `input` for the static secret `z` between `sender_public`
/// and `verifier_public`. `z` must already be checked contributory.
fn tag(
    z: &[u8; 32],
    sender_public: &[u8; KEY_BYTES],
    verifier_public: &[u8; KEY_BYTES],
    input: &[u8],
) -> Result<[u8; TAG_BYTES], DvError> {
    let crypto = RustCrypto::default();
    let prk = crypto
        .hkdf_extract(HashType::Sha2_256, LABEL, z)
        .map_err(|_| DvError::Crypto)?;
    let mut info = Vec::with_capacity(KEY_LABEL.len() + 2 * KEY_BYTES);
    info.extend_from_slice(KEY_LABEL);
    info.extend_from_slice(sender_public);
    info.extend_from_slice(verifier_public);
    let key = crypto
        .hkdf_expand(HashType::Sha2_256, prk.as_slice(), &info, 32)
        .map_err(|_| DvError::Crypto)?;
    let mac = crypto
        .hmac(HashType::Sha2_256, key.as_slice(), input)
        .map_err(|_| DvError::Crypto)?;
    mac.as_slice().try_into().map_err(|_| DvError::Crypto)
}

/// `Z` for `secret` and `public`, or `None` when it is all zero (a forced,
/// non-contributory result). The caller has checked `public`.
fn shared(secret: &StaticSecret, public: &[u8; KEY_BYTES]) -> Option<[u8; 32]> {
    let z = secret.diffie_hellman(&PublicKey::from(*public));
    z.was_contributory().then(|| z.to_bytes())
}

fn wipe_array(bytes: &mut [u8; 32]) {
    for byte in bytes.iter_mut() {
        // SAFETY: a valid, aligned pointer to a byte of `bytes`.
        unsafe { core::ptr::write_volatile(byte, 0) };
    }
}

/// The franking public key of `secret`.
pub fn public_key(secret: &StaticSecret) -> [u8; KEY_BYTES] {
    PublicKey::from(secret).to_bytes()
}

/// The designation of a sealed message by the device holding `secret`
/// (identity `account_id`, `device_id`) to `verifiers` (`n × 32` bytes,
/// `1 ≤ n ≤ 16`). A verifier key that is not canonical, is low-order or
/// gives an all-zero `Z` is skipped, never refused (the key list must not
/// be able to fail a send), and a repeated key yields one entry. Returns
/// `m × 48` bytes sorted by kid, `m ≤ n`; `m = 0` means the plain form.
pub fn designate(
    secret: &StaticSecret,
    verifiers: &[u8],
    conversation_id: &[u8],
    account_id: &[u8],
    device_id: &[u8],
    commit: &[u8],
) -> Result<Vec<u8>, DvError> {
    if verifiers.is_empty()
        || !verifiers.len().is_multiple_of(KEY_BYTES)
        || verifiers.len() / KEY_BYTES > MAX_VERIFIERS
    {
        return Err(DvError::InvalidInput);
    }
    // Every id and the commitment are checked once, before any DH.
    tag_input(
        conversation_id,
        account_id,
        device_id,
        &[0u8; KID_BYTES],
        commit,
    )?;
    let sender_public = public_key(secret);
    let mut entries: Vec<([u8; KID_BYTES], [u8; TAG_BYTES])> = Vec::new();
    for key in verifiers.chunks_exact(KEY_BYTES) {
        let Ok(verifier) = check_public(key) else {
            continue;
        };
        let id = kid(&verifier)?;
        if entries.iter().any(|(seen, _)| *seen == id) {
            continue;
        }
        // The input first: checked above, so this cannot fail, and no
        // shared secret exists yet if it ever did.
        let input = tag_input(conversation_id, account_id, device_id, &id, commit)?;
        let Some(mut z) = shared(secret, &verifier) else {
            continue;
        };
        let result = tag(&z, &sender_public, &verifier, &input);
        wipe_array(&mut z);
        entries.push((id, result?));
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let mut out = Vec::with_capacity(entries.len() * ENTRY_BYTES);
    for (id, mac) in entries {
        out.extend_from_slice(&id);
        out.extend_from_slice(&mac);
    }
    Ok(out)
}

/// Splits a designation into its entries: `1..=16` of 48 bytes, kids
/// strictly ascending. `None` for anything else.
pub fn parse_designation(designation: &[u8]) -> Option<Vec<(&[u8], &[u8])>> {
    if designation.is_empty()
        || !designation.len().is_multiple_of(ENTRY_BYTES)
        || designation.len() / ENTRY_BYTES > MAX_VERIFIERS
    {
        return None;
    }
    let entries: Vec<(&[u8], &[u8])> = designation
        .chunks_exact(ENTRY_BYTES)
        .map(|entry| entry.split_at(KID_BYTES))
        .collect();
    if entries.windows(2).any(|pair| pair[0].0 >= pair[1].0) {
        return None;
    }
    Some(entries)
}

/// Constant-time equality of two 32-byte tags.
fn tags_equal(a: &[u8], b: &[u8; TAG_BYTES]) -> bool {
    if a.len() != TAG_BYTES {
        return false;
    }
    let difference = a
        .iter()
        .zip(b.iter())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y));
    core::hint::black_box(difference) == 0
}

/// The owner's check with its X25519 report `secret`: is `designation` a
/// valid designation, to this owner, by the device whose franking public
/// key is `sender_public`, of `commit` in `conversation_id` as
/// `(account_id, device_id)`? `sender_public` must come from the claimed
/// account's L1 list, never from the report. A sender key that is not
/// canonical or is low-order, an all-zero `Z`, or a malformed designation is
/// [`DvVerdict::Mismatch`]; wrong id or commitment lengths are errors.
pub fn verify(
    secret: &StaticSecret,
    sender_public: &[u8],
    conversation_id: &[u8],
    account_id: &[u8],
    device_id: &[u8],
    commit: &[u8],
    designation: &[u8],
) -> Result<DvVerdict, DvError> {
    tag_input(
        conversation_id,
        account_id,
        device_id,
        &[0u8; KID_BYTES],
        commit,
    )?;
    let Some(entries) = parse_designation(designation) else {
        return Ok(DvVerdict::Mismatch);
    };
    let verifier_public = public_key(secret);
    let own = kid(&verifier_public)?;
    let Some((_, received)) = entries.iter().find(|(id, _)| *id == own.as_slice()) else {
        return Ok(DvVerdict::NotDesignated);
    };
    let Ok(sender) = check_public(sender_public) else {
        return Ok(DvVerdict::Mismatch);
    };
    // Before the shared secret, as in `designate`.
    let input = tag_input(conversation_id, account_id, device_id, &own, commit)?;
    let Some(mut z) = shared(secret, &sender) else {
        return Ok(DvVerdict::Mismatch);
    };
    let expected = tag(&z, &sender, &verifier_public, &input);
    wipe_array(&mut z);
    Ok(if tags_equal(received, &expected?) {
        DvVerdict::Valid
    } else {
        DvVerdict::Mismatch
    })
}

/// [`verify`] with the owner's C6 report seed: the X25519 pair is derived
/// inside (`report::x25519_secret`), so no caller ever holds the private key.
#[allow(clippy::too_many_arguments)]
pub fn verify_with_report_seed(
    report_seed: &[u8],
    sender_public: &[u8],
    conversation_id: &[u8],
    account_id: &[u8],
    device_id: &[u8],
    commit: &[u8],
    designation: &[u8],
) -> Result<DvVerdict, DvError> {
    let secret = report::x25519_secret(report_seed).map_err(|error| match error {
        report::ReportError::InvalidInput => DvError::InvalidInput,
        _ => DvError::Crypto,
    })?;
    verify(
        &secret,
        sender_public,
        conversation_id,
        account_id,
        device_id,
        commit,
        designation,
    )
}

/// A fresh franking secret from the OS RNG (the provider's, as
/// `report::generate_seed`). Kept by the device in its sealed record.
pub(crate) fn generate_secret() -> Result<StaticSecret, DvError> {
    use openmls_traits::random::OpenMlsRand;
    let random = tls_codec::SecretVLBytes::from(
        RustCrypto::default()
            .random_vec(KEY_BYTES)
            .map_err(|_| DvError::Crypto)?,
    );
    secret_from_bytes(random.as_slice())
}

/// A [`StaticSecret`] from 32 stored bytes; the temporary copy is wiped.
/// Refuses a secret whose public key would be refused (it cannot happen
/// for random bytes, which clamping makes a multiple of 8 times a scalar).
pub(crate) fn secret_from_bytes(bytes: &[u8]) -> Result<StaticSecret, DvError> {
    let mut array: [u8; KEY_BYTES] = bytes.try_into().map_err(|_| DvError::InvalidInput)?;
    let secret = StaticSecret::from(array);
    wipe_array(&mut array);
    check_public(&public_key(&secret))?;
    Ok(secret)
}

#[cfg(test)]
#[path = "l2_frank_tests.rs"]
mod tests;
