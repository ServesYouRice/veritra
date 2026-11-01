//! C6 reports (`docs/designs/C6-reports-franking.md`, D80): the HPKE seal a
//! report travels in, and the message-franking commitment it proves.
//!
//! ```text
//! report key seed (32 bytes, held by the recipient app)
//!  └─ PRK = HKDF-Extract(SHA-256, salt = "veritra-c6-report-key-v1", ikm = seed)
//!      └─ HKDF-Expand(PRK, "veritra-c6 report-hpke", 32)
//!           └─ DeriveKeyPair (DHKEM X25519, HKDF-SHA256) → report public key
//!
//! sealed = "VRP1" || enc (32) || HPKE ciphertext
//!   HPKE: RFC 9180 base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
//!   AES-256-GCM; info = "veritra-c6-report-v1" (fixed here); aad from caller.
//!
//! commit = HMAC-SHA256(kf, "veritra-frank-v1" || lp(conversation_id)
//!          || lp(sender_device_id) || lp(action_id) || lp(payload))
//!   lp = u32 big-endian length; the same bytes as server/internal/franking.
//! ```
//!
//! No function returns the X25519 private key: open takes the seed and
//! derives the pair inside Rust. The info label is fixed so a report key can
//! open nothing sealed for another purpose, and no other HPKE key in this
//! crate (K0 `rk_pub`, K2 transfer keys) opens a report.

use openmls_rust_crypto::RustCrypto;
use openmls_traits::{
    crypto::OpenMlsCrypto,
    random::OpenMlsRand,
    types::{
        HashType, HpkeAeadType, HpkeCiphertext, HpkeConfig, HpkeKdfType, HpkeKemType, HpkeKeyPair,
    },
};
use tls_codec::SecretVLBytes;

/// Report key seed length.
pub const SEED_BYTES: usize = 32;
/// X25519 public key length.
pub const PUBLIC_KEY_BYTES: usize = 32;
/// Largest associated data a seal or open accepts.
pub const MAX_AAD_BYTES: usize = 1024;
/// Largest report plaintext. A report carries one canonical payload (at most
/// 64 KiB, `docs/crypto.md` §7), its franking key and its context.
pub const MAX_PLAINTEXT_BYTES: usize = 256 * 1024;
const MAGIC: &[u8; 4] = b"VRP1";
const ENC_BYTES: usize = 32;
const TAG_BYTES: usize = 16;
/// Largest sealed report: magic, enc, the plaintext and the AEAD tag.
pub const MAX_SEALED_BYTES: usize = MAGIC.len() + ENC_BYTES + MAX_PLAINTEXT_BYTES + TAG_BYTES;
const MIN_SEALED_BYTES: usize = MAGIC.len() + ENC_BYTES + 1 + TAG_BYTES;

const KEY_SALT: &[u8] = b"veritra-c6-report-key-v1";
const KEY_LABEL: &[u8] = b"veritra-c6 report-hpke";
const INFO: &[u8] = b"veritra-c6-report-v1";

/// Franking key (`kf`) length.
pub const FRANK_KEY_BYTES: usize = 32;
/// Commitment length.
pub const FRANK_COMMIT_BYTES: usize = 32;
/// Largest context field (conversation, device or action id).
pub const MAX_FRANK_ID_BYTES: usize = 128;
/// Largest canonical payload: the padded payload cap (`docs/crypto.md` §7).
pub const MAX_FRANK_PAYLOAD_BYTES: usize = 64 * 1024;
const FRANK_LABEL: &[u8] = b"veritra-frank-v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReportError {
    InvalidInput,
    /// The sealed report does not open with this key and aad.
    Authentication,
    Crypto,
}

fn suite() -> HpkeConfig {
    HpkeConfig(
        HpkeKemType::DhKem25519,
        HpkeKdfType::HkdfSha256,
        HpkeAeadType::AesGcm256,
    )
}

/// Fresh report key seed from the OS RNG.
pub fn generate_seed() -> Result<SecretVLBytes, ReportError> {
    let seed: SecretVLBytes = RustCrypto::default()
        .random_vec(SEED_BYTES)
        .map_err(|_| ReportError::Crypto)?
        .into();
    if seed.as_slice().len() != SEED_BYTES {
        return Err(ReportError::Crypto);
    }
    Ok(seed)
}

fn key_pair(crypto: &RustCrypto, seed: &[u8]) -> Result<HpkeKeyPair, ReportError> {
    if seed.len() != SEED_BYTES {
        return Err(ReportError::InvalidInput);
    }
    let prk = crypto
        .hkdf_extract(HashType::Sha2_256, KEY_SALT, seed)
        .map_err(|_| ReportError::Crypto)?;
    let ikm = crypto
        .hkdf_expand(HashType::Sha2_256, prk.as_slice(), KEY_LABEL, 32)
        .map_err(|_| ReportError::Crypto)?;
    // HpkeKeyPair.private zeroizes on drop; prk and ikm are SecretVLBytes.
    let pair = crypto
        .derive_hpke_keypair(suite(), ikm.as_slice())
        .map_err(|_| ReportError::Crypto)?;
    if pair.public.len() != PUBLIC_KEY_BYTES || pair.private.len() != 32 {
        return Err(ReportError::Crypto);
    }
    Ok(pair)
}

/// The report public key for `seed`.
pub fn public_key(seed: &[u8]) -> Result<[u8; PUBLIC_KEY_BYTES], ReportError> {
    let pair = key_pair(&RustCrypto::default(), seed)?;
    pair.public
        .as_slice()
        .try_into()
        .map_err(|_| ReportError::Crypto)
}

fn check_aad(aad: &[u8]) -> Result<(), ReportError> {
    // Required: the transport must bind its routing context.
    if aad.is_empty() || aad.len() > MAX_AAD_BYTES {
        return Err(ReportError::InvalidInput);
    }
    Ok(())
}

/// Seals `plaintext` to `recipient_public` (RFC 9180 base mode, fixed info).
pub fn seal(recipient_public: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, ReportError> {
    check_aad(aad)?;
    if recipient_public.len() != PUBLIC_KEY_BYTES
        || plaintext.is_empty()
        || plaintext.len() > MAX_PLAINTEXT_BYTES
    {
        return Err(ReportError::InvalidInput);
    }
    let sealed = RustCrypto::default()
        .hpke_seal(suite(), recipient_public, INFO, aad, plaintext)
        // A public key that is not a valid X25519 point (or a low-order point,
        // whose shared secret is all zeros) fails here (RFC 9180 §7.1.4).
        .map_err(|_| ReportError::InvalidInput)?;
    let enc = sealed.kem_output.as_slice();
    let ciphertext = sealed.ciphertext.as_slice();
    if enc.len() != ENC_BYTES || ciphertext.len() != plaintext.len() + TAG_BYTES {
        return Err(ReportError::Crypto);
    }
    let mut out = Vec::with_capacity(MAGIC.len() + ENC_BYTES + ciphertext.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(enc);
    out.extend_from_slice(ciphertext);
    Ok(out)
}

/// Opens a sealed report with the recipient's seed. Any change to the
/// sealed bytes, the aad or the key is [`ReportError::Authentication`].
pub fn open(seed: &[u8], aad: &[u8], sealed: &[u8]) -> Result<SecretVLBytes, ReportError> {
    check_aad(aad)?;
    if seed.len() != SEED_BYTES
        || sealed.len() < MIN_SEALED_BYTES
        || sealed.len() > MAX_SEALED_BYTES
        || &sealed[..MAGIC.len()] != MAGIC
    {
        return Err(ReportError::InvalidInput);
    }
    let crypto = RustCrypto::default();
    let pair = key_pair(&crypto, seed)?;
    let (enc, ciphertext) = sealed[MAGIC.len()..].split_at(ENC_BYTES);
    let input = HpkeCiphertext {
        kem_output: enc.into(),
        ciphertext: ciphertext.into(),
    };
    let plaintext: SecretVLBytes = crypto
        .hpke_open(suite(), &input, &pair.private, INFO, aad)
        .map_err(|_| ReportError::Authentication)?
        .into();
    Ok(plaintext)
}

fn append_lp(message: &mut Vec<u8>, value: &[u8]) {
    // Every field is bounded far below u32::MAX by the checks in commit.
    message.extend_from_slice(&(value.len() as u32).to_be_bytes());
    message.extend_from_slice(value);
}

/// The franking commitment (C6 mechanism step 3) over the canonical payload
/// bytes `payload` (`docs/crypto.md`, "Franking v1"). Byte for byte what
/// `franking.Commit` in `server/internal/franking` computes.
pub fn frank_commit(
    key: &[u8],
    conversation_id: &[u8],
    sender_device_id: &[u8],
    action_id: &[u8],
    payload: &[u8],
) -> Result<[u8; FRANK_COMMIT_BYTES], ReportError> {
    let id = |value: &[u8]| !value.is_empty() && value.len() <= MAX_FRANK_ID_BYTES;
    if key.len() != FRANK_KEY_BYTES
        || !id(conversation_id)
        || !id(sender_device_id)
        || !id(action_id)
        || payload.is_empty()
        || payload.len() > MAX_FRANK_PAYLOAD_BYTES
    {
        return Err(ReportError::InvalidInput);
    }
    let mut message = Vec::with_capacity(
        FRANK_LABEL.len()
            + 16
            + conversation_id.len()
            + sender_device_id.len()
            + action_id.len()
            + payload.len(),
    );
    message.extend_from_slice(FRANK_LABEL);
    for field in [conversation_id, sender_device_id, action_id, payload] {
        append_lp(&mut message, field);
    }
    // The message holds message text: wipe it on drop.
    let message = SecretVLBytes::new(message);
    let mac = RustCrypto::default()
        .hmac(HashType::Sha2_256, key, message.as_slice())
        .map_err(|_| ReportError::Crypto)?;
    mac.as_slice().try_into().map_err(|_| ReportError::Crypto)
}

#[cfg(test)]
#[path = "report_tests.rs"]
mod tests;
