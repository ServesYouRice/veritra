//! L2-3 sealed sender (D122, ABI 26): the client half of the RFC 9497 POPRF
//! tokens a device spends to post without naming itself, and the franking
//! signature that keeps a sealed message reportable.
//!
//! Rules: `docs/crypto.md`, "Sealed sender with VOPRF tokens". The server
//! half (Go, `server/internal/sealedsender`) evaluates the blinded nonces
//! under `info` and later recomputes the output of a spent nonce; neither
//! side can link the two. Vectors: `testing/vectors/l2-sealed-v1.json`.

use ed25519_dalek::{Signature, VerifyingKey};
use voprf::{EvaluationElement, Group, PoprfClient, Proof, Ristretto255};

type Suite = Ristretto255;

/// The RFC 9497 suite identifier, for the record and the vectors.
pub const SUITE: &str = "ristretto255-SHA512";
/// Prefix of the POPRF `info` (public input) of every token.
pub const INFO_LABEL: &[u8] = b"veritra-l2-sealed-v1";
/// Prefix hashed with the server's public key into its `key_id`.
pub const KEY_ID_LABEL: &[u8] = b"veritra-l2-key-v1";
/// Prefix of the bytes a sender signs over a franking commitment. ASCII
/// `v` read as an RFC 9420 varint opens a two-byte length that would have
/// to be followed by `MLS 1.0 `, so this can never be an MLS SignContent.
pub const FRANK_SIG_LABEL: &[u8] = b"veritra-frank-sig-v1";
/// The state blob's magic.
pub const STATE_MAGIC: &[u8; 4] = b"VLT1";

pub const MAX_BATCH: usize = 32;
pub const NONCE_BYTES: usize = 32;
pub const OUTPUT_BYTES: usize = 64;
pub const ELEMENT_BYTES: usize = 32;
pub const PUBLIC_KEY_BYTES: usize = 32;
pub const PROOF_BYTES: usize = 64;
pub const KEY_ID_BYTES: usize = 16;
pub const CLIENT_STATE_BYTES: usize = 64;
pub const TOKEN_BYTES: usize = NONCE_BYTES + OUTPUT_BYTES;
pub const COMMIT_BYTES: usize = 32;
pub const SIGNATURE_BYTES: usize = 64;
pub const SIGNING_KEY_BYTES: usize = 32;
/// Conversation, account and device ids, as everywhere at this boundary.
pub const MAX_ID_BYTES: usize = 128;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SealedError {
    /// A malformed or out-of-range argument.
    InvalidInput,
    /// The server's proof or an element did not verify.
    Verification,
}

/// `info = label || u16 len(conversation) || conversation || u32 epoch`,
/// big-endian. Nothing per account or per member list goes in (review M1:
/// a server-chosen number here could tag each account's tokens).
pub fn info(conversation_id: &[u8], epoch: u32) -> Result<Vec<u8>, SealedError> {
    if conversation_id.is_empty() || conversation_id.len() > MAX_ID_BYTES {
        return Err(SealedError::InvalidInput);
    }
    let mut out = Vec::with_capacity(INFO_LABEL.len() + 2 + conversation_id.len() + 4);
    out.extend_from_slice(INFO_LABEL);
    out.extend_from_slice(&(conversation_id.len() as u16).to_be_bytes());
    out.extend_from_slice(conversation_id);
    out.extend_from_slice(&epoch.to_be_bytes());
    Ok(out)
}

/// The first 16 bytes of `SHA-256(KEY_ID_LABEL || public_key)`.
pub fn key_id(public_key: &[u8]) -> Result<[u8; KEY_ID_BYTES], SealedError> {
    use sha2::{Digest, Sha256};
    parse_public_key(public_key)?;
    let digest = Sha256::digest([KEY_ID_LABEL, public_key].concat());
    let mut id = [0u8; KEY_ID_BYTES];
    id.copy_from_slice(&digest[..KEY_ID_BYTES]);
    Ok(id)
}

fn parse_public_key(public_key: &[u8]) -> Result<<Suite as Group>::Elem, SealedError> {
    if public_key.len() != PUBLIC_KEY_BYTES {
        return Err(SealedError::InvalidInput);
    }
    // Refuses a non-canonical encoding and the identity (RFC 9497 §2.1).
    <Suite as Group>::deserialize_elem(public_key).map_err(|_| SealedError::InvalidInput)
}

/// A token request: the state the client keeps (secret: it holds the
/// blinds) and the blinded elements it sends.
pub struct TokenRequest {
    pub state: Vec<u8>,
    pub request: Vec<u8>,
}

/// Makes `count` fresh nonces and blinds them for the server's key under
/// `info(conversation_id, epoch)`.
pub fn token_request<R: rand_core::RngCore + rand_core::CryptoRng>(
    public_key: &[u8],
    conversation_id: &[u8],
    epoch: u32,
    count: usize,
    rng: &mut R,
) -> Result<TokenRequest, SealedError> {
    if count == 0 || count > MAX_BATCH {
        return Err(SealedError::InvalidInput);
    }
    parse_public_key(public_key)?;
    let info = info(conversation_id, epoch)?;
    let mut state = Vec::with_capacity(
        4 + 1 + PUBLIC_KEY_BYTES + 2 + info.len() + count * (NONCE_BYTES + CLIENT_STATE_BYTES),
    );
    state.extend_from_slice(STATE_MAGIC);
    state.push(count as u8);
    state.extend_from_slice(public_key);
    state.extend_from_slice(&(info.len() as u16).to_be_bytes());
    state.extend_from_slice(&info);
    let mut request = Vec::with_capacity(count * ELEMENT_BYTES);
    for _ in 0..count {
        let mut nonce = [0u8; NONCE_BYTES];
        rng.fill_bytes(&mut nonce);
        let blinded =
            PoprfClient::<Suite>::blind(&nonce, rng).map_err(|_| SealedError::InvalidInput)?;
        state.extend_from_slice(&nonce);
        state.extend_from_slice(&blinded.state.serialize());
        request.extend_from_slice(&blinded.message.serialize());
    }
    Ok(TokenRequest { state, request })
}

struct ParsedState<'a> {
    public_key: <Suite as Group>::Elem,
    info: &'a [u8],
    nonces: Vec<&'a [u8]>,
    clients: Vec<PoprfClient<Suite>>,
}

fn parse_state(state: &[u8]) -> Result<ParsedState<'_>, SealedError> {
    let bad = SealedError::InvalidInput;
    let rest = state.strip_prefix(STATE_MAGIC.as_slice()).ok_or(bad)?;
    let (&count, rest) = rest.split_first().ok_or(bad)?;
    let count = count as usize;
    if count == 0 || count > MAX_BATCH || rest.len() < PUBLIC_KEY_BYTES + 2 {
        return Err(bad);
    }
    let (public_key, rest) = rest.split_at(PUBLIC_KEY_BYTES);
    let public_key = parse_public_key(public_key)?;
    let (info_len, rest) = rest.split_at(2);
    let info_len = u16::from_be_bytes([info_len[0], info_len[1]]) as usize;
    if rest.len() != info_len + count * (NONCE_BYTES + CLIENT_STATE_BYTES)
        || !rest.starts_with(INFO_LABEL)
    {
        return Err(bad);
    }
    let (info, mut rest) = rest.split_at(info_len);
    let mut nonces = Vec::with_capacity(count);
    let mut clients = Vec::with_capacity(count);
    for _ in 0..count {
        let (nonce, after) = rest.split_at(NONCE_BYTES);
        let (client, after) = after.split_at(CLIENT_STATE_BYTES);
        nonces.push(nonce);
        clients.push(PoprfClient::<Suite>::deserialize(client).map_err(|_| bad)?);
        rest = after;
    }
    Ok(ParsedState {
        public_key,
        info,
        nonces,
        clients,
    })
}

/// Checks the server's batch proof against the key the state was made for
/// and returns `count × (nonce || output)`. `response` is `count` evaluated
/// elements followed by the 64-byte proof.
pub fn token_finalize(state: &[u8], response: &[u8]) -> Result<Vec<u8>, SealedError> {
    let parsed = parse_state(state)?;
    let count = parsed.nonces.len();
    if response.len() != count * ELEMENT_BYTES + PROOF_BYTES {
        return Err(SealedError::InvalidInput);
    }
    let (elements, proof) = response.split_at(count * ELEMENT_BYTES);
    let evaluated = elements
        .chunks_exact(ELEMENT_BYTES)
        .map(EvaluationElement::<Suite>::deserialize)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| SealedError::Verification)?;
    let proof = Proof::<Suite>::deserialize(proof).map_err(|_| SealedError::Verification)?;
    let outputs = PoprfClient::batch_finalize(
        parsed.nonces.iter().copied(),
        &parsed.clients,
        &evaluated,
        &proof,
        parsed.public_key,
        Some(parsed.info),
    )
    .map_err(|_| SealedError::Verification)?;
    let mut tokens = Vec::with_capacity(count * TOKEN_BYTES);
    for (nonce, output) in parsed.nonces.iter().zip(outputs) {
        let output = output.map_err(|_| SealedError::Verification)?;
        tokens.extend_from_slice(nonce);
        tokens.extend_from_slice(&output);
    }
    Ok(tokens)
}

fn push_id(out: &mut Vec<u8>, id: &[u8]) -> Result<(), SealedError> {
    if id.is_empty() || id.len() > MAX_ID_BYTES {
        return Err(SealedError::InvalidInput);
    }
    out.extend_from_slice(&(id.len() as u16).to_be_bytes());
    out.extend_from_slice(id);
    Ok(())
}

/// The bytes a sealed sender signs over its franking commitment:
/// `label || lp(conversation) || lp(account) || lp(device) || commit`.
pub fn frank_sig_input(
    conversation_id: &[u8],
    account_id: &[u8],
    device_id: &[u8],
    commit: &[u8],
) -> Result<Vec<u8>, SealedError> {
    if commit.len() != COMMIT_BYTES {
        return Err(SealedError::InvalidInput);
    }
    let mut out = FRANK_SIG_LABEL.to_vec();
    push_id(&mut out, conversation_id)?;
    push_id(&mut out, account_id)?;
    push_id(&mut out, device_id)?;
    out.extend_from_slice(commit);
    Ok(out)
}

/// Strict Ed25519 verification of a franking signature. `Ok(false)` for a
/// signature or key that does not verify; an error only for wrong lengths.
pub fn frank_verify(
    signing_key: &[u8],
    conversation_id: &[u8],
    account_id: &[u8],
    device_id: &[u8],
    commit: &[u8],
    signature: &[u8],
) -> Result<bool, SealedError> {
    let input = frank_sig_input(conversation_id, account_id, device_id, commit)?;
    let key: &[u8; SIGNING_KEY_BYTES] = signing_key
        .try_into()
        .map_err(|_| SealedError::InvalidInput)?;
    let signature: &[u8; SIGNATURE_BYTES] = signature
        .try_into()
        .map_err(|_| SealedError::InvalidInput)?;
    let Ok(key) = VerifyingKey::from_bytes(key) else {
        return Ok(false);
    };
    Ok(key
        .verify_strict(&input, &Signature::from_bytes(signature))
        .is_ok())
}

#[cfg(test)]
#[path = "l2_sealed_tests.rs"]
mod tests;
