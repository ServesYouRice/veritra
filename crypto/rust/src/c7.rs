//! C7 channel history primitives (`docs/designs/C7-channel-history.md`,
//! revision 7, build step 2; owner decisions D83 and D84; ABI 13).
//!
//! Nothing here is wired into the app. Every piece needs the independent
//! crypto review before release, the exporter use in particular.
//!
//! ```text
//! c7_derive(k, label, info) = HKDF-Expand(HKDF-Extract(salt = label, ikm = k), info, 32)
//!   HKDF-SHA256 through the OpenMLS crypto provider, as report.rs does.
//!
//! root     = MLS-Exporter("veritra-c7-rekey-v1", lp(group_id) | u64(new_epoch), 32)
//!            computed in mls.rs inside the commit call, before the merge,
//!            for a removal commit only (RFC 9420 section 8.5)
//! CHK      = c7_derive(root, "veritra-c7-rekey-chk-v1", lp(community_id) | lp(channel_id))
//! body_key = c7_derive(CHK, "veritra-c7-post-v1",
//!                      lp(community_id) | lp(channel_id) | lp(sender_device_id) | lp(action_id))
//! slot_key = c7_derive(CHK, "veritra-c7-slot-v1", the same four fields)
//!
//! sealed   = kc[32] | nonce[12] | AES-256-GCM(K_enc, nonce, plaintext, aad)
//!   K_enc  = c7_derive(key, "veritra-c7-enc-v1", "")
//!   kc     = c7_derive(key, "veritra-c7-kc-v1", "")   (checked before opening)
//! ```
//!
//! `lp(x)` is a u16 big-endian length and then the bytes, and every `u32` and
//! `u64` is big-endian, in every C7 encoding (C6's franking uses u32 length
//! prefixes: do not share the helper). Every AEAD key is used for exactly one
//! message (the post and slot keys bind `action_id`), so the random 96-bit
//! nonce is safe. No new crate (D84).

use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use ed25519_dalek::{Signature, VerifyingKey};
use openmls_rust_crypto::RustCrypto;
use openmls_traits::{crypto::OpenMlsCrypto, random::OpenMlsRand, types::HashType};
use sha2::{Digest, Sha256};
use tls_codec::SecretVLBytes;

/// Every C7 key: a channel history key, a body key, a slot key, a root.
pub const KEY_BYTES: usize = 32;
/// Length of a key commitment, a hash, a `chk_commit`.
pub const HASH_BYTES: usize = 32;
const NONCE_BYTES: usize = 12;
const TAG_BYTES: usize = 16;
/// Ed25519 signature and public key lengths.
pub const SIGNATURE_BYTES: usize = 64;
pub const PUBLIC_KEY_BYTES: usize = 32;
/// Body framing without the plaintext: commitment, nonce, tag.
pub const SEAL_OVERHEAD: usize = HASH_BYTES + NONCE_BYTES + TAG_BYTES;
/// Largest plaintext a body holds: the 64 KiB VAP1 cap and its signature.
pub const MAX_PLAINTEXT_BYTES: usize = 64 * 1024 + SIGNATURE_BYTES;
/// Largest associated data and largest derive info accepted.
pub const MAX_AAD_BYTES: usize = 1024;
pub const MAX_INFO_BYTES: usize = 1024;
/// Largest id in a record (server ids are 36 bytes).
pub const MAX_ID_BYTES: usize = 64;

pub const LABEL_POST: &[u8] = b"veritra-c7-post-v1";
pub const LABEL_REKEY_CHK: &[u8] = b"veritra-c7-rekey-chk-v1";
pub const LABEL_SLOT: &[u8] = b"veritra-c7-slot-v1";
const LABEL_ENC: &[u8] = b"veritra-c7-enc-v1";
const LABEL_KC: &[u8] = b"veritra-c7-kc-v1";
const CHK_COMMIT_PREFIX: &[u8] = b"veritra-c7-chk-v1";
/// The one MLS exporter label C7 uses.
pub const EXPORTER_LABEL: &str = "veritra-c7-rekey-v1";

/// Labels a caller may name in a derive call. The encryption and
/// commitment labels stay inside seal and open.
pub const DERIVE_LABELS: [&[u8]; 3] = [LABEL_POST, LABEL_REKEY_CHK, LABEL_SLOT];

/// Domains the credential key signs through the ABI 13 sign and verify
/// calls. Rust prepends the label itself, so such a signature can never be a
/// valid MLS or other-protocol signature. No label is a prefix of another
/// (a test pins it), so `domain | message` has one reading.
pub const SIGN_DOMAIN_POST: &[u8] = b"veritra-c7-post-sig-v1";
pub const SIGN_DOMAIN_HISTORY: &[u8] = b"veritra-c7-history-v1";
/// C1 invitation binding v2 (`docs/designs/C1-invite-format.md`): the
/// creating device signs the target, its own account and device, its key and
/// the link's locator. Part of ABI 21; a library without the entry refuses
/// the domain and the app fails closed.
pub const SIGN_DOMAIN_INVITE: &[u8] = b"veritra-invite-binding-v2";
pub const SIGN_DOMAINS: [&[u8]; 4] = [
    SIGN_DOMAIN_POST,
    SIGN_DOMAIN_HISTORY,
    SIGN_DOMAIN_INVITE,
    crate::b6::SIGN_DOMAIN_JOIN,
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum C7Error {
    InvalidInput,
    /// The commitment does not match: this is not the key (try the next
    /// candidate). Nothing was decrypted.
    KeyMismatch,
    /// The commitment matched but the ciphertext, aad or tag did not.
    Authentication,
    Crypto,
}

// ---- encoding helpers ----------------------------------------------------

/// `u16` big-endian length, then the bytes.
fn lp(out: &mut Vec<u8>, value: &[u8]) -> Result<(), C7Error> {
    let len = u16::try_from(value.len()).map_err(|_| C7Error::InvalidInput)?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

/// An id inside a record: 1 to [`MAX_ID_BYTES`] bytes.
fn lp_id(out: &mut Vec<u8>, value: &[u8]) -> Result<(), C7Error> {
    if value.is_empty() || value.len() > MAX_ID_BYTES {
        return Err(C7Error::InvalidInput);
    }
    lp(out, value)
}

/// The channel id in an aad may be empty (a group-level message).
fn lp_aad_id(out: &mut Vec<u8>, value: &[u8]) -> Result<(), C7Error> {
    if value.len() > MAX_ID_BYTES {
        return Err(C7Error::InvalidInput);
    }
    lp(out, value)
}

struct Reader<'a> {
    bytes: &'a [u8],
}

impl<'a> Reader<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8], C7Error> {
        if self.bytes.len() < count {
            return Err(C7Error::InvalidInput);
        }
        let (head, rest) = self.bytes.split_at(count);
        self.bytes = rest;
        Ok(head)
    }
    fn array<const N: usize>(&mut self) -> Result<[u8; N], C7Error> {
        self.take(N)?.try_into().map_err(|_| C7Error::InvalidInput)
    }
    fn u8(&mut self) -> Result<u8, C7Error> {
        Ok(self.take(1)?[0])
    }
    fn u32(&mut self) -> Result<u32, C7Error> {
        Ok(u32::from_be_bytes(self.array()?))
    }
    fn u64(&mut self) -> Result<u64, C7Error> {
        Ok(u64::from_be_bytes(self.array()?))
    }
    fn lp_id(&mut self) -> Result<Vec<u8>, C7Error> {
        let len = u16::from_be_bytes(self.array()?) as usize;
        if len == 0 || len > MAX_ID_BYTES {
            return Err(C7Error::InvalidInput);
        }
        Ok(self.take(len)?.to_vec())
    }
    /// The rest must be zero padding.
    fn zero_rest(&self) -> Result<(), C7Error> {
        if self.bytes.iter().any(|byte| *byte != 0) {
            return Err(C7Error::InvalidInput);
        }
        Ok(())
    }
}

// ---- derive, commitments ---------------------------------------------------

fn hkdf(key: &[u8], label: &[u8], info: &[u8]) -> Result<SecretVLBytes, C7Error> {
    if key.len() != KEY_BYTES || info.len() > MAX_INFO_BYTES {
        return Err(C7Error::InvalidInput);
    }
    let crypto = RustCrypto::default();
    let prk = crypto
        .hkdf_extract(HashType::Sha2_256, label, key)
        .map_err(|_| C7Error::Crypto)?;
    let okm = crypto
        .hkdf_expand(HashType::Sha2_256, prk.as_slice(), info, KEY_BYTES)
        .map_err(|_| C7Error::Crypto)?;
    if okm.as_slice().len() != KEY_BYTES {
        return Err(C7Error::Crypto);
    }
    Ok(okm)
}

/// `c7_derive` for a caller: the label must be one of [`DERIVE_LABELS`].
pub fn derive(key: &[u8], label: &[u8], info: &[u8]) -> Result<SecretVLBytes, C7Error> {
    if !DERIVE_LABELS.contains(&label) {
        return Err(C7Error::InvalidInput);
    }
    hkdf(key, label, info)
}

/// `lp(community_id) | lp(channel_id)`, the info of a rekey.
pub fn rekey_info(community_id: &[u8], channel_id: &[u8]) -> Result<Vec<u8>, C7Error> {
    let mut info = Vec::new();
    lp_id(&mut info, community_id)?;
    lp_id(&mut info, channel_id)?;
    Ok(info)
}

/// The info of a post key and a slot key:
/// `lp(community_id) | lp(channel_id) | lp(sender_device_id) | lp(action_id)`.
pub fn message_info(
    community_id: &[u8],
    channel_id: &[u8],
    sender_device_id: &[u8],
    action_id: &[u8],
) -> Result<Vec<u8>, C7Error> {
    let mut info = Vec::new();
    lp_id(&mut info, community_id)?;
    lp_id(&mut info, channel_id)?;
    lp_id(&mut info, sender_device_id)?;
    lp_id(&mut info, action_id)?;
    Ok(info)
}

/// The channel history key of the generation a removal commit opens.
pub fn rekey_chk(
    root: &[u8],
    community_id: &[u8],
    channel_id: &[u8],
) -> Result<SecretVLBytes, C7Error> {
    hkdf(
        root,
        LABEL_REKEY_CHK,
        &rekey_info(community_id, channel_id)?,
    )
}

/// The body key of a post sealed under generation key `chk`.
pub fn post_body_key(
    chk: &[u8],
    community_id: &[u8],
    channel_id: &[u8],
    sender_device_id: &[u8],
    action_id: &[u8],
) -> Result<SecretVLBytes, C7Error> {
    hkdf(
        chk,
        LABEL_POST,
        &message_info(community_id, channel_id, sender_device_id, action_id)?,
    )
}

/// The key a `history_sync` slot is sealed under (`chk` is the slot's
/// `key_c`).
pub fn slot_key(
    chk: &[u8],
    community_id: &[u8],
    channel_id: &[u8],
    sender_device_id: &[u8],
    action_id: &[u8],
) -> Result<SecretVLBytes, C7Error> {
    hkdf(
        chk,
        LABEL_SLOT,
        &message_info(community_id, channel_id, sender_device_id, action_id)?,
    )
}

/// `sha256("veritra-c7-chk-v1" | key)`: a record's `chk_commit` and a
/// generation entry's `key_commit`.
pub fn chk_commit(key: &[u8]) -> Result<[u8; HASH_BYTES], C7Error> {
    if key.len() != KEY_BYTES {
        return Err(C7Error::InvalidInput);
    }
    let mut hash = Sha256::new();
    hash.update(CHK_COMMIT_PREFIX);
    hash.update(key);
    Ok(hash.finalize().into())
}

/// The exporter context: `lp(group_id) | u64(new_epoch)`. Group ids go up to
/// 128 bytes in this crate, wider than a record's id limit, and the exporter
/// must never fail on a group the rest of the core accepts.
pub fn exporter_context(group_id: &[u8], new_epoch: u64) -> Result<Vec<u8>, C7Error> {
    if group_id.is_empty() || group_id.len() > 128 {
        return Err(C7Error::InvalidInput);
    }
    let mut context = Vec::with_capacity(2 + group_id.len() + 8);
    lp(&mut context, group_id)?;
    context.extend_from_slice(&new_epoch.to_be_bytes());
    Ok(context)
}

// ---- seal and open --------------------------------------------------------

fn seal_with(
    key: &[u8],
    nonce: [u8; NONCE_BYTES],
    aad: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>, C7Error> {
    if plaintext.len() > MAX_PLAINTEXT_BYTES || aad.len() > MAX_AAD_BYTES {
        return Err(C7Error::InvalidInput);
    }
    let enc = hkdf(key, LABEL_ENC, b"")?;
    let kc = hkdf(key, LABEL_KC, b"")?;
    let cipher = Aes256Gcm::new_from_slice(enc.as_slice()).map_err(|_| C7Error::InvalidInput)?;
    let nonce_value = Nonce::try_from(nonce.as_slice()).map_err(|_| C7Error::InvalidInput)?;
    let ciphertext = cipher
        .encrypt(
            &nonce_value,
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| C7Error::Crypto)?;
    let mut sealed = Vec::with_capacity(SEAL_OVERHEAD + plaintext.len());
    sealed.extend_from_slice(kc.as_slice());
    sealed.extend_from_slice(&nonce);
    sealed.extend_from_slice(&ciphertext);
    Ok(sealed)
}

/// Seals `plaintext` under `key` with a fresh random nonce:
/// `kc | nonce | ciphertext | tag`.
pub fn seal(key: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, C7Error> {
    let nonce: [u8; NONCE_BYTES] = RustCrypto::default()
        .random_array()
        .map_err(|_| C7Error::Crypto)?;
    seal_with(key, nonce, aad, plaintext)
}

/// Seals with a fixed nonce, for known-answer vectors only.
#[cfg(test)]
pub(crate) fn seal_with_nonce(
    key: &[u8],
    nonce: [u8; NONCE_BYTES],
    aad: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>, C7Error> {
    seal_with(key, nonce, aad, plaintext)
}

/// Whether `sealed` carries the commitment of `key`. Does not decrypt.
pub fn key_matches(key: &[u8], sealed: &[u8]) -> Result<bool, C7Error> {
    if sealed.len() < SEAL_OVERHEAD {
        return Err(C7Error::InvalidInput);
    }
    let kc = hkdf(key, LABEL_KC, b"")?;
    Ok(constant_time_eq(kc.as_slice(), &sealed[..HASH_BYTES]))
}

/// Opens a sealed value. The commitment is checked first:
/// [`C7Error::KeyMismatch`] means this was not the key, and no decryption
/// was attempted.
pub fn open(key: &[u8], aad: &[u8], sealed: &[u8]) -> Result<SecretVLBytes, C7Error> {
    if sealed.len() < SEAL_OVERHEAD
        || sealed.len() > SEAL_OVERHEAD + MAX_PLAINTEXT_BYTES
        || aad.len() > MAX_AAD_BYTES
    {
        return Err(C7Error::InvalidInput);
    }
    if !key_matches(key, sealed)? {
        return Err(C7Error::KeyMismatch);
    }
    let enc = hkdf(key, LABEL_ENC, b"")?;
    let cipher = Aes256Gcm::new_from_slice(enc.as_slice()).map_err(|_| C7Error::InvalidInput)?;
    let nonce = Nonce::try_from(&sealed[HASH_BYTES..HASH_BYTES + NONCE_BYTES])
        .map_err(|_| C7Error::InvalidInput)?;
    let plaintext = cipher
        .decrypt(
            &nonce,
            Payload {
                msg: &sealed[HASH_BYTES + NONCE_BYTES..],
                aad,
            },
        )
        .map_err(|_| C7Error::Authentication)?;
    Ok(SecretVLBytes::new(plaintext))
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}

/// `lp(conversation_id) | lp(channel_id or "") | lp(sender_device_id) | lp(action_id)`,
/// the envelope's own fields, bound as the aad of a body and of its slots.
pub fn body_aad(
    conversation_id: &[u8],
    channel_id: &[u8],
    sender_device_id: &[u8],
    action_id: &[u8],
) -> Result<Vec<u8>, C7Error> {
    let mut aad = Vec::new();
    lp_id(&mut aad, conversation_id)?;
    lp_aad_id(&mut aad, channel_id)?;
    lp_id(&mut aad, sender_device_id)?;
    lp_id(&mut aad, action_id)?;
    Ok(aad)
}

// ---- signatures ----------------------------------------------------------

/// The bytes after the `veritra-c7-post-sig-v1` label that a post's `sig`
/// covers:
/// `lp(community_id) | lp(channel_id) | lp(action_id) | lp(group_id) | u64(epoch) | lp(sender_device_id) | u64(gen) | sha256(padded VAP1)`.
#[allow(clippy::too_many_arguments)]
pub fn post_signed_fields(
    community_id: &[u8],
    channel_id: &[u8],
    action_id: &[u8],
    group_id: &[u8],
    epoch: u64,
    sender_device_id: &[u8],
    generation: u64,
    padded_vap1_hash: &[u8; HASH_BYTES],
) -> Result<Vec<u8>, C7Error> {
    let mut out = Vec::new();
    lp_id(&mut out, community_id)?;
    lp_id(&mut out, channel_id)?;
    lp_id(&mut out, action_id)?;
    lp_id(&mut out, group_id)?;
    out.extend_from_slice(&epoch.to_be_bytes());
    lp_id(&mut out, sender_device_id)?;
    out.extend_from_slice(&generation.to_be_bytes());
    out.extend_from_slice(padded_vap1_hash);
    Ok(out)
}

/// The exact bytes signed: the label, then `message`.
pub fn signing_input(domain: &[u8], message: &[u8]) -> Result<Vec<u8>, C7Error> {
    if !SIGN_DOMAINS.contains(&domain) {
        return Err(C7Error::InvalidInput);
    }
    let mut input = Vec::with_capacity(domain.len() + message.len());
    input.extend_from_slice(domain);
    input.extend_from_slice(message);
    Ok(input)
}

/// Strict Ed25519 verification over `domain | message`. `false` for every
/// failure, a malformed key or signature included; an unknown domain or a
/// wrong length is an error.
pub fn verify(
    domain: &[u8],
    public_key: &[u8],
    message: &[u8],
    signature: &[u8],
) -> Result<bool, C7Error> {
    let input = signing_input(domain, message)?;
    let public_key: &[u8; PUBLIC_KEY_BYTES] =
        public_key.try_into().map_err(|_| C7Error::InvalidInput)?;
    let signature: &[u8; SIGNATURE_BYTES] =
        signature.try_into().map_err(|_| C7Error::InvalidInput)?;
    let Ok(key) = VerifyingKey::from_bytes(public_key) else {
        return Ok(false);
    };
    Ok(key
        .verify_strict(&input, &Signature::from_bytes(signature))
        .is_ok())
}

// ---- history_sync pieces --------------------------------------------------

/// A head record slot, full form, zero-padded.
pub const RECORD_BYTES: usize = 512;
/// A generation entry, zero-padded.
pub const ENTRY_BYTES: usize = 128;
const ENTRY_USED_BYTES: usize = 80;
/// `slot_plain = head record | generation entry`.
pub const SLOT_PLAIN_BYTES: usize = RECORD_BYTES + ENTRY_BYTES;
/// A sealed slot: commitment, nonce, plaintext, tag (700 bytes).
pub const SLOT_BYTES: usize = SEAL_OVERHEAD + SLOT_PLAIN_BYTES;
/// Budget of one body0 channel entry (at most 115 bytes with 64-byte ids).
pub const BODY0_ENTRY_BUDGET: usize = 128;
/// The VAP1 payload cap (`docs/crypto.md` W7 section 1).
pub const MAX_VAP1_BYTES: usize = 64 * 1024;

/// `P(N) = 256 * ceil((512 + 128 N) / 256)`: the padded VAP1 of body0.
pub fn body0_padded_len(channels: usize) -> Result<usize, C7Error> {
    if channels == 0 {
        return Err(C7Error::InvalidInput);
    }
    let raw = 512usize
        .checked_add(
            BODY0_ENTRY_BUDGET
                .checked_mul(channels)
                .ok_or(C7Error::InvalidInput)?,
        )
        .ok_or(C7Error::InvalidInput)?;
    let padded = raw.div_ceil(256) * 256;
    if padded > MAX_VAP1_BYTES {
        return Err(C7Error::InvalidInput);
    }
    Ok(padded)
}

/// `P(N) + 124 + 700 N`: the `sealed_body` length of a `history_sync`
/// naming `channels` channels (body0 framing is 124 bytes).
pub fn history_sync_body_len(channels: usize) -> Result<usize, C7Error> {
    Ok(body0_padded_len(channels)? + SEAL_OVERHEAD + SIGNATURE_BYTES + SLOT_BYTES * channels)
}

/// The `N` a `history_sync` body of `len` bytes names, or `None` when no
/// `N` fits (the server and receivers refuse any other length).
pub fn history_sync_channel_count(len: usize) -> Option<usize> {
    (1..=(MAX_VAP1_BYTES - 512) / BODY0_ENTRY_BUDGET)
        .find(|n| history_sync_body_len(*n).is_ok_and(|expected| expected == len))
}

/// One generation entry: the generation current at a `history_sync`'s
/// `for_epoch`, and a wrap of the previous generation in the same group.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GenerationEntry {
    /// Opening epoch of the current generation.
    pub epoch: u64,
    /// `chk_commit` of the current generation's key.
    pub key_commit: [u8; HASH_BYTES],
    /// Epoch and key of the previous generation in this group; `None` at
    /// the period's first generation and when it lives in another group.
    pub previous: Option<(u64, [u8; KEY_BYTES])>,
}

impl GenerationEntry {
    /// `u64 E_cur | key_commit[32] | u64 E_prev | CHK_prev[32]`, zero-padded
    /// to 128 bytes. An absent wrap is 40 zero bytes.
    pub fn encode(&self) -> [u8; ENTRY_BYTES] {
        let mut out = [0u8; ENTRY_BYTES];
        out[..8].copy_from_slice(&self.epoch.to_be_bytes());
        out[8..40].copy_from_slice(&self.key_commit);
        if let Some((epoch, key)) = &self.previous {
            out[40..48].copy_from_slice(&epoch.to_be_bytes());
            out[48..80].copy_from_slice(key);
        }
        out
    }

    /// The zero entry (a slot with no key): `Ok(None)` for 128 zero bytes.
    /// A wrap is present exactly when its key is not all zero (a real key
    /// is never zero, and epoch 0 is a valid previous epoch); a zero key
    /// with a non-zero epoch, or non-zero padding, is invalid.
    pub fn decode(bytes: &[u8]) -> Result<Option<Self>, C7Error> {
        let bytes: &[u8; ENTRY_BYTES] = bytes.try_into().map_err(|_| C7Error::InvalidInput)?;
        if bytes.iter().all(|byte| *byte == 0) {
            return Ok(None);
        }
        let mut reader = Reader { bytes };
        let epoch = reader.u64()?;
        let key_commit = reader.array::<HASH_BYTES>()?;
        let previous_epoch = reader.u64()?;
        let previous_key = reader.array::<KEY_BYTES>()?;
        reader.zero_rest()?;
        let previous = if previous_key.iter().all(|byte| *byte == 0) {
            if previous_epoch != 0 {
                return Err(C7Error::InvalidInput);
            }
            None
        } else {
            Some((previous_epoch, previous_key))
        };
        debug_assert_eq!(ENTRY_USED_BYTES, 8 + 32 + 8 + 32);
        Ok(Some(Self {
            epoch,
            key_commit,
            previous,
        }))
    }
}

/// `slot_plain = head record (512) | generation entry (128)`.
pub fn slot_plain(head: &[u8], entry: &[u8]) -> Result<Vec<u8>, C7Error> {
    if head.len() != RECORD_BYTES || entry.len() != ENTRY_BYTES {
        return Err(C7Error::InvalidInput);
    }
    let mut out = Vec::with_capacity(SLOT_PLAIN_BYTES);
    out.extend_from_slice(head);
    out.extend_from_slice(entry);
    Ok(out)
}

/// Seals one `history_sync` slot under `key_c`: the slot key binds the
/// channel, the sender and the action; the aad is the envelope's.
#[allow(clippy::too_many_arguments)]
pub fn slot_seal(
    key_c: &[u8],
    community_id: &[u8],
    channel_id: &[u8],
    sender_device_id: &[u8],
    action_id: &[u8],
    aad: &[u8],
    plain: &[u8],
) -> Result<Vec<u8>, C7Error> {
    if plain.len() != SLOT_PLAIN_BYTES {
        return Err(C7Error::InvalidInput);
    }
    let key = slot_key(key_c, community_id, channel_id, sender_device_id, action_id)?;
    seal(key.as_slice(), aad, plain)
}

/// Opens a slot with a candidate `key_c`; [`C7Error::KeyMismatch`] when the
/// slot belongs to another key.
#[allow(clippy::too_many_arguments)]
pub fn slot_open(
    key_c: &[u8],
    community_id: &[u8],
    channel_id: &[u8],
    sender_device_id: &[u8],
    action_id: &[u8],
    aad: &[u8],
    sealed: &[u8],
) -> Result<SecretVLBytes, C7Error> {
    if sealed.len() != SLOT_BYTES {
        return Err(C7Error::InvalidInput);
    }
    let key = slot_key(key_c, community_id, channel_id, sender_device_id, action_id)?;
    let plain = open(key.as_slice(), aad, sealed)?;
    if plain.as_slice().len() != SLOT_PLAIN_BYTES {
        return Err(C7Error::Authentication);
    }
    Ok(plain)
}

// ---- history records ------------------------------------------------------

pub const RECORD_VERSION: u8 = 1;
pub const COMPACT_BYTES: usize = 143;
pub const MOVE_WRAP_BYTES: usize = 128;
pub const MODE_MEMBERS_FROM_JOIN: u8 = 0;
pub const MODE_FULL: u8 = 1;
pub const REASON_CREATE: u8 = 0;
pub const REASON_SWITCH: u8 = 1;
pub const REASON_MOVE: u8 = 2;
/// A record with this `seq` is invalid, so `seq` never wraps.
pub const SEQ_LIMIT: u32 = u32::MAX;

/// A history record in full form (decision 3). Encoding and decoding check
/// structure only (lengths, enumerations, zero padding, `seq` below the
/// limit). The ordering table, freshness and authority are the app's.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistoryRecord {
    pub community_id: Vec<u8>,
    pub channel_id: Vec<u8>,
    pub seq: u32,
    pub prev: [u8; HASH_BYTES],
    pub mode: u8,
    pub reason: u8,
    pub group_id: Vec<u8>,
    pub epoch: u64,
    pub close_group_id: Vec<u8>,
    pub close_epoch: u64,
    pub chk_commit: [u8; HASH_BYTES],
    pub actor_device_id: Vec<u8>,
    pub sig: [u8; SIGNATURE_BYTES],
}

impl HistoryRecord {
    fn check(&self) -> Result<(), C7Error> {
        if self.seq == SEQ_LIMIT || self.mode > MODE_FULL || self.reason > REASON_MOVE {
            return Err(C7Error::InvalidInput);
        }
        Ok(())
    }

    /// The bytes after the `veritra-c7-history-v1` label that `sig` covers:
    /// the full form without its version byte and signature.
    pub fn signed_fields(&self) -> Result<Vec<u8>, C7Error> {
        self.check()?;
        let mut out = Vec::new();
        lp_id(&mut out, &self.community_id)?;
        lp_id(&mut out, &self.channel_id)?;
        out.extend_from_slice(&self.seq.to_be_bytes());
        out.extend_from_slice(&self.prev);
        out.push(self.mode);
        out.push(self.reason);
        lp_id(&mut out, &self.group_id)?;
        out.extend_from_slice(&self.epoch.to_be_bytes());
        lp_id(&mut out, &self.close_group_id)?;
        out.extend_from_slice(&self.close_epoch.to_be_bytes());
        out.extend_from_slice(&self.chk_commit);
        lp_id(&mut out, &self.actor_device_id)?;
        Ok(out)
    }

    /// Full form, zero-padded to 512 bytes (at most 481 used).
    pub fn encode(&self) -> Result<[u8; RECORD_BYTES], C7Error> {
        let fields = self.signed_fields()?;
        let mut out = Vec::with_capacity(RECORD_BYTES);
        out.push(RECORD_VERSION);
        out.extend_from_slice(&fields);
        out.extend_from_slice(&self.sig);
        if out.len() > RECORD_BYTES {
            return Err(C7Error::InvalidInput);
        }
        out.resize(RECORD_BYTES, 0);
        out.try_into().map_err(|_| C7Error::InvalidInput)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, C7Error> {
        if bytes.len() != RECORD_BYTES {
            return Err(C7Error::InvalidInput);
        }
        let mut reader = Reader { bytes };
        if reader.u8()? != RECORD_VERSION {
            return Err(C7Error::InvalidInput);
        }
        let record = Self {
            community_id: reader.lp_id()?,
            channel_id: reader.lp_id()?,
            seq: reader.u32()?,
            prev: reader.array()?,
            mode: reader.u8()?,
            reason: reader.u8()?,
            group_id: reader.lp_id()?,
            epoch: reader.u64()?,
            close_group_id: reader.lp_id()?,
            close_epoch: reader.u64()?,
            chk_commit: reader.array()?,
            actor_device_id: reader.lp_id()?,
            sig: reader.array()?,
        };
        reader.zero_rest()?;
        record.check()?;
        Ok(record)
    }

    /// `sha256` of the full 512-byte form: the next record's `prev`.
    pub fn hash(&self) -> Result<[u8; HASH_BYTES], C7Error> {
        Ok(Sha256::digest(self.encode()?).into())
    }
}

/// A record as it travels in its channel message (the proposal form).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactRecord {
    pub seq: u32,
    pub prev: [u8; HASH_BYTES],
    pub mode: u8,
    pub reason: u8,
    pub close_epoch: u64,
    /// The new `CHK` when the record opens a key (mode `full`), else
    /// 32 random bytes.
    pub key: [u8; KEY_BYTES],
    pub sig: [u8; SIGNATURE_BYTES],
    /// A `move` adds the old group and a 128-byte wrap field.
    pub moved: Option<(Vec<u8>, [u8; MOVE_WRAP_BYTES])>,
}

/// What the receiver supplies when it rebuilds the full form.
#[derive(Clone, Copy, Debug)]
pub struct RecordContext<'a> {
    pub community_id: &'a [u8],
    pub channel_id: &'a [u8],
    pub group_id: &'a [u8],
    pub epoch: u64,
    pub actor_device_id: &'a [u8],
}

impl CompactRecord {
    /// 143 bytes, or with a move `143 + lp(close_group_id) + 128`:
    /// `u8 version | u32 seq | prev | u8 mode | u8 reason | u64 close_epoch | key | sig`.
    pub fn encode(&self) -> Result<Vec<u8>, C7Error> {
        if self.seq == SEQ_LIMIT
            || self.mode > MODE_FULL
            || self.reason > REASON_MOVE
            || (self.reason == REASON_MOVE) != self.moved.is_some()
        {
            return Err(C7Error::InvalidInput);
        }
        let mut out = Vec::with_capacity(COMPACT_BYTES + 2 + MAX_ID_BYTES + MOVE_WRAP_BYTES);
        out.push(RECORD_VERSION);
        out.extend_from_slice(&self.seq.to_be_bytes());
        out.extend_from_slice(&self.prev);
        out.push(self.mode);
        out.push(self.reason);
        out.extend_from_slice(&self.close_epoch.to_be_bytes());
        out.extend_from_slice(&self.key);
        out.extend_from_slice(&self.sig);
        if let Some((close_group_id, wrap)) = &self.moved {
            lp_id(&mut out, close_group_id)?;
            out.extend_from_slice(wrap);
        }
        Ok(out)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, C7Error> {
        let mut reader = Reader { bytes };
        if reader.u8()? != RECORD_VERSION {
            return Err(C7Error::InvalidInput);
        }
        let seq = reader.u32()?;
        let prev = reader.array()?;
        let mode = reader.u8()?;
        let reason = reader.u8()?;
        let close_epoch = reader.u64()?;
        let key = reader.array()?;
        let sig = reader.array()?;
        let moved = if reason == REASON_MOVE {
            Some((reader.lp_id()?, reader.array::<MOVE_WRAP_BYTES>()?))
        } else {
            None
        };
        if !reader.bytes.is_empty() || seq == SEQ_LIMIT || mode > MODE_FULL || reason > REASON_MOVE
        {
            return Err(C7Error::InvalidInput);
        }
        Ok(Self {
            seq,
            prev,
            mode,
            reason,
            close_epoch,
            key,
            sig,
            moved,
        })
    }

    /// Rebuilds the full form: the context fills the ids and the carried
    /// group and epoch; `close_group_id` is the group itself unless a move;
    /// `chk_commit` comes from `key` when the record opens one (mode
    /// `full`) and is zero otherwise.
    pub fn expand(&self, context: &RecordContext<'_>) -> Result<HistoryRecord, C7Error> {
        let chk = if self.mode == MODE_FULL {
            chk_commit(&self.key)?
        } else {
            [0u8; HASH_BYTES]
        };
        let close_group_id = match &self.moved {
            Some((close_group_id, _)) => close_group_id.clone(),
            None => context.group_id.to_vec(),
        };
        let record = HistoryRecord {
            community_id: context.community_id.to_vec(),
            channel_id: context.channel_id.to_vec(),
            seq: self.seq,
            prev: self.prev,
            mode: self.mode,
            reason: self.reason,
            group_id: context.group_id.to_vec(),
            epoch: context.epoch,
            close_group_id,
            close_epoch: self.close_epoch,
            chk_commit: chk,
            actor_device_id: context.actor_device_id.to_vec(),
            sig: self.sig,
        };
        record.check()?;
        record.signed_fields()?;
        Ok(record)
    }
}

#[cfg(test)]
#[path = "c7_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "invite_binding_tests.rs"]
mod invite_binding_tests;
