//! K0 recovery key (RK): generation, the display codec, derivation of the
//! public recovery values, and the recovery-enrollment proof (K0 R1,
//! `docs/designs/K0-recovery-enrollment.md`, D78).
//!
//! ```text
//! RK entropy (30 bytes)
//!  └─ PRK = HKDF-Extract(SHA-256, salt = "veritra-k0-v1", ikm = entropy)
//!      ├─ HKDF-Expand(PRK, "veritra-k0 recovery-hpke", 32)
//!      │    └─ DeriveKeyPair (DHKEM X25519, HKDF-SHA256) → rk_pub
//!      └─ HKDF-Expand(PRK, "veritra-k0 recovery-auth", 32)
//!           └─ Ed25519 seed → rk_auth_pub
//! rk_id = SHA-256("veritra-k0-rk-id-v1" || rk_pub)[0..16]
//! ```
//!
//! No function here returns a private key or seed. The proof is signed only
//! over the fixed message the server rebuilds, so the recovery auth key can
//! never sign caller-chosen bytes.

use ed25519_dalek::{Signer, SigningKey};
use openmls_rust_crypto::RustCrypto;
use openmls_traits::{
    crypto::OpenMlsCrypto,
    random::OpenMlsRand,
    types::{HashType, HpkeAeadType, HpkeConfig, HpkeKdfType, HpkeKemType},
};
use sha2::{Digest, Sha256};
use tls_codec::SecretVLBytes;

/// RK entropy length (240 bits).
pub const ENTROPY_BYTES: usize = 30;
/// Canonical display length: Crockford base32 of entropy || 2-byte check.
pub const DISPLAY_CHARS: usize = 52;
/// Largest typed RK text the decoder reads (separators included).
pub const MAX_DISPLAY_INPUT_BYTES: usize = 256;
pub const RK_PUB_BYTES: usize = 32;
pub const RK_ID_BYTES: usize = 16;
pub const RK_AUTH_PUB_BYTES: usize = 32;
pub const PROOF_SIGNATURE_BYTES: usize = 64;
pub const MAX_CHALLENGE_BYTES: usize = 4096;
pub const SIGNING_KEY_BYTES: usize = 32;
pub const MAX_KEY_PACKAGE_BYTES: usize = 48 * 1024;
pub const MAX_ORIGIN_BYTES: usize = 2048;

const EXTRACT_SALT: &[u8] = b"veritra-k0-v1";
const HPKE_LABEL: &[u8] = b"veritra-k0 recovery-hpke";
const AUTH_LABEL: &[u8] = b"veritra-k0 recovery-auth";
const RK_ID_LABEL: &[u8] = b"veritra-k0-rk-id-v1";
const CHECK_LABEL: &[u8] = b"veritra-k0-rk-check-v1";
/// The proof label the server's `recoveryProofMessage` uses.
pub const PROOF_LABEL: &[u8] = b"veritra-k0-recovery-proof-v1";

const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryError {
    InvalidInput,
    Crypto,
}

/// The public values derived from an RK. None of them is secret against the
/// device; `rk_pub` is integrity-critical and never goes to the server.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveryPublic {
    pub rk_pub: [u8; RK_PUB_BYTES],
    pub rk_id: [u8; RK_ID_BYTES],
    pub rk_auth_pub: [u8; RK_AUTH_PUB_BYTES],
}

fn check_entropy(entropy: &[u8]) -> Result<(), RecoveryError> {
    if entropy.len() == ENTROPY_BYTES {
        Ok(())
    } else {
        Err(RecoveryError::InvalidInput)
    }
}

/// Fresh RK entropy from the OS RNG.
pub fn generate() -> Result<SecretVLBytes, RecoveryError> {
    let entropy: SecretVLBytes = RustCrypto::default()
        .random_vec(ENTROPY_BYTES)
        .map_err(|_| RecoveryError::Crypto)?
        .into();
    check_entropy(entropy.as_slice())?;
    Ok(entropy)
}

fn check_bytes(entropy: &[u8]) -> [u8; 2] {
    // Hashed in two parts so no unwiped copy of the entropy is made.
    let digest = Sha256::new()
        .chain_update(CHECK_LABEL)
        .chain_update(entropy)
        .finalize();
    [digest[0], digest[1]]
}

/// The canonical 52-character display (upper case, no separators). The UI
/// groups it into 13 groups of 4.
pub fn encode(entropy: &[u8]) -> Result<String, RecoveryError> {
    check_entropy(entropy)?;
    let bytes = SecretVLBytes::new([entropy, check_bytes(entropy).as_slice()].concat());
    let mut out = String::with_capacity(DISPLAY_CHARS);
    let mut buffer: u16 = 0;
    let mut bits = 0u32;
    for &byte in bytes.as_slice() {
        buffer = (buffer << 8) | u16::from(byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(char::from(CROCKFORD[usize::from((buffer >> bits) & 0x1f)]));
        }
        buffer &= (1 << bits) - 1;
    }
    if bits > 0 {
        out.push(char::from(
            CROCKFORD[usize::from((buffer << (5 - bits)) & 0x1f)],
        ));
    }
    debug_assert_eq!(out.len(), DISPLAY_CHARS);
    Ok(out)
}

fn symbol_value(symbol: u8) -> Option<u8> {
    let upper = symbol.to_ascii_uppercase();
    let upper = match upper {
        b'O' => b'0',
        b'I' | b'L' => b'1',
        other => other,
    };
    CROCKFORD
        .iter()
        .position(|&candidate| candidate == upper)
        .and_then(|value| u8::try_from(value).ok())
}

/// Decodes typed RK text. Case-insensitive; `O` reads as 0 and `I`/`L` as 1;
/// `-` and space are ignored; `U` and anything else is refused. The 4
/// padding bits of the last symbol must be zero (one canonical spelling),
/// and the check must match. Returns the 30-byte entropy.
pub fn decode(text: &[u8]) -> Result<SecretVLBytes, RecoveryError> {
    if text.is_empty() || text.len() > MAX_DISPLAY_INPUT_BYTES {
        return Err(RecoveryError::InvalidInput);
    }
    let mut out = Vec::with_capacity(ENTROPY_BYTES + 3);
    let mut buffer: u16 = 0;
    let mut bits = 0u32;
    let mut symbols = 0usize;
    let mut failed = false;
    for &symbol in text {
        if symbol == b'-' || symbol == b' ' {
            continue;
        }
        let Some(value) = symbol_value(symbol) else {
            failed = true;
            break;
        };
        symbols += 1;
        if symbols > DISPLAY_CHARS {
            failed = true;
            break;
        }
        buffer = (buffer << 5) | u16::from(value);
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push(u8::try_from((buffer >> bits) & 0xff).unwrap_or(0));
            buffer &= (1 << bits) - 1;
        }
    }
    // Wiped on drop, on every path below.
    let decoded = SecretVLBytes::new(out);
    // 52 symbols carry 260 bits: 32 bytes and 4 padding bits, which must be
    // zero so each RK has one spelling.
    if failed
        || symbols != DISPLAY_CHARS
        || bits != 4
        || buffer != 0
        || decoded.as_slice().len() != ENTROPY_BYTES + 2
    {
        return Err(RecoveryError::InvalidInput);
    }
    let (entropy, check) = decoded.as_slice().split_at(ENTROPY_BYTES);
    if check != check_bytes(entropy) {
        return Err(RecoveryError::InvalidInput);
    }
    Ok(SecretVLBytes::new(entropy.to_vec()))
}

fn prk(crypto: &RustCrypto, entropy: &[u8]) -> Result<SecretVLBytes, RecoveryError> {
    check_entropy(entropy)?;
    crypto
        .hkdf_extract(HashType::Sha2_256, EXTRACT_SALT, entropy)
        .map_err(|_| RecoveryError::Crypto)
}

fn expand(crypto: &RustCrypto, prk: &[u8], label: &[u8]) -> Result<SecretVLBytes, RecoveryError> {
    crypto
        .hkdf_expand(HashType::Sha2_256, prk, label, 32)
        .map_err(|_| RecoveryError::Crypto)
}

fn auth_key(crypto: &RustCrypto, prk: &[u8]) -> Result<SigningKey, RecoveryError> {
    let seed = expand(crypto, prk, AUTH_LABEL)?;
    let seed: &[u8; 32] = seed
        .as_slice()
        .try_into()
        .map_err(|_| RecoveryError::Crypto)?;
    // SigningKey zeroizes its secret on drop (ed25519-dalek "zeroize").
    Ok(SigningKey::from_bytes(seed))
}

/// Derives `rk_pub`, `rk_id` and `rk_auth_pub` from the RK entropy.
pub fn derive(entropy: &[u8]) -> Result<RecoveryPublic, RecoveryError> {
    let crypto = RustCrypto::default();
    let prk = prk(&crypto, entropy)?;
    let hpke_ikm = expand(&crypto, prk.as_slice(), HPKE_LABEL)?;
    let pair = crypto
        .derive_hpke_keypair(
            HpkeConfig(
                HpkeKemType::DhKem25519,
                HpkeKdfType::HkdfSha256,
                HpkeAeadType::AesGcm256,
            ),
            hpke_ikm.as_slice(),
        )
        .map_err(|_| RecoveryError::Crypto)?;
    // The private half (pair.private) is a zeroizing wrapper and is dropped
    // here unused: K1 derives it again inside Rust only to open a backup.
    let rk_pub: [u8; RK_PUB_BYTES] = pair
        .public
        .as_slice()
        .try_into()
        .map_err(|_| RecoveryError::Crypto)?;
    let digest = Sha256::digest([RK_ID_LABEL, rk_pub.as_slice()].concat());
    let mut rk_id = [0u8; RK_ID_BYTES];
    rk_id.copy_from_slice(&digest[..RK_ID_BYTES]);
    let rk_auth_pub = auth_key(&crypto, prk.as_slice())?
        .verifying_key()
        .to_bytes();
    Ok(RecoveryPublic {
        rk_pub,
        rk_id,
        rk_auth_pub,
    })
}

fn append_length_prefixed(output: &mut Vec<u8>, value: &[u8]) -> Result<(), RecoveryError> {
    let size = u16::try_from(value.len()).map_err(|_| RecoveryError::InvalidInput)?;
    output.extend_from_slice(&size.to_be_bytes());
    output.extend_from_slice(value);
    Ok(())
}

/// The message the recovery auth key signs, byte for byte what the server's
/// `recoveryProofMessage` (`account_recovery_handlers.go`) rebuilds:
/// `"veritra-k0-recovery-proof-v1" | lp(challenge) | signing_key |
/// SHA-256(key_package) | lp(origin)`, with lp a u16 big-endian length.
pub fn proof_message(
    challenge: &[u8],
    signing_key: &[u8],
    key_package: &[u8],
    origin: &[u8],
) -> Result<Vec<u8>, RecoveryError> {
    if challenge.is_empty()
        || challenge.len() > MAX_CHALLENGE_BYTES
        || signing_key.len() != SIGNING_KEY_BYTES
        || key_package.is_empty()
        || key_package.len() > MAX_KEY_PACKAGE_BYTES
        || origin.is_empty()
        || origin.len() > MAX_ORIGIN_BYTES
        || core::str::from_utf8(origin).is_err()
        || origin
            .iter()
            .any(|&byte| byte.is_ascii_control() || byte == b' ')
    {
        return Err(RecoveryError::InvalidInput);
    }
    let mut message = Vec::with_capacity(
        PROOF_LABEL.len() + 2 + challenge.len() + SIGNING_KEY_BYTES + 32 + 2 + origin.len(),
    );
    message.extend_from_slice(PROOF_LABEL);
    append_length_prefixed(&mut message, challenge)?;
    message.extend_from_slice(signing_key);
    message.extend_from_slice(&Sha256::digest(key_package));
    append_length_prefixed(&mut message, origin)?;
    Ok(message)
}

/// Signs the recovery proof with the auth key derived from the RK entropy.
/// The seed and signing key never leave this function.
pub fn sign_proof(
    entropy: &[u8],
    challenge: &[u8],
    signing_key: &[u8],
    key_package: &[u8],
    origin: &[u8],
) -> Result<[u8; PROOF_SIGNATURE_BYTES], RecoveryError> {
    check_entropy(entropy)?;
    let message = proof_message(challenge, signing_key, key_package, origin)?;
    let crypto = RustCrypto::default();
    let prk = prk(&crypto, entropy)?;
    let key = auth_key(&crypto, prk.as_slice())?;
    Ok(key.sign(&message).to_bytes())
}

#[cfg(test)]
#[path = "recovery_tests.rs"]
mod tests;
