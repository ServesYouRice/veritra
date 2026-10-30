//! Internal K2 live-transfer primitives. No FFI or application path uses these
//! until protocol v3, durable enrollment and history-only import are integrated.

use crate::attachment::{decrypt_chunk, encrypt_chunk, MAX_ATTACHMENT_CHUNK};
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::{
    crypto::OpenMlsCrypto,
    random::OpenMlsRand,
    signatures::Signer,
    types::{
        HpkeAeadType, HpkeCiphertext, HpkeConfig, HpkeKdfType, HpkeKemType, HpkeKeyPair,
        SignatureScheme,
    },
    OpenMlsProvider,
};
use sha2::{Digest, Sha256};
use tls_codec::SecretVLBytes;

const MAGIC: &[u8; 4] = b"VHC1";
const BUNDLE_KIND: u8 = 2;
const FRAME_BUCKET: usize = 64 * 1024;
pub(crate) const MAX_PADDED_HISTORY: usize = 64 * 1024 * 1024;
pub(crate) const MAX_HISTORY_CIPHERTEXT: usize = MAX_PADDED_HISTORY + 64 * 20 + 416;

pub(crate) fn transfer_id(transcript: &[u8; 32], ciphertext_hash: &[u8; 32]) -> [u8; 64] {
    let mut hash = Sha256::new();
    hash.update(b"veritra-k2-transfer-id-v1");
    hash.update(transcript);
    hash.update(ciphertext_hash);
    let digest = hash.finalize();
    let mut id = [0u8; 64];
    let hex = b"0123456789abcdef";
    for (i, b) in digest.iter().enumerate() {
        id[2 * i] = hex[(b >> 4) as usize];
        id[2 * i + 1] = hex[(b & 15) as usize];
    }
    id
}
const MAX_ID: usize = 128;
const MAX_ORIGIN: usize = 2048;
const MAX_HEADER: usize = 416;
const MAX_HANDOFF: usize = 8 * 1024;
const HANDOFF_MAGIC: &[u8; 4] = b"VHH1";
const BUNDLE_CONTEXT: &[u8] = b"veritra-history-v1";
const HANDOFF_INFO: &[u8] = b"veritra-k2-handoff-v1";
const HANDOFF_AAD: &[u8] = b"veritra-k2-handoff-aad-v1";
const HANDOFF_SIGNATURE: &[u8] = b"veritra-k2-handoff-sig-v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum HistoryError {
    InvalidInput,
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

/// Key material has no Debug implementation. The existing TLS secret wrapper
/// zeroizes its allocation on drop, including early validation failures.
pub(crate) struct FileSecrets {
    key: SecretVLBytes,
    nonce_prefix: [u8; 8],
}

impl FileSecrets {
    pub(crate) fn fresh(provider: &impl OpenMlsProvider) -> Result<Self, HistoryError> {
        let key: SecretVLBytes = provider
            .rand()
            .random_vec(32)
            .map_err(|_| HistoryError::Crypto)?
            .into();
        let nonce_prefix = provider
            .rand()
            .random_array::<8>()
            .map_err(|_| HistoryError::Crypto)?;
        Ok(Self { key, nonce_prefix })
    }

    pub(crate) fn from_bytes(key: &[u8], nonce_prefix: &[u8]) -> Result<Self, HistoryError> {
        if key.len() != 32 || nonce_prefix.len() != 8 {
            return Err(HistoryError::InvalidInput);
        }
        Ok(Self {
            key: key.into(),
            nonce_prefix: nonce_prefix
                .try_into()
                .map_err(|_| HistoryError::InvalidInput)?,
        })
    }

    /// Native sealed-state serialization only; never exposed through FFI.
    pub(crate) fn state_parts(&self) -> (&[u8], &[u8; 8]) {
        (self.key.as_slice(), &self.nonce_prefix)
    }
}

pub(crate) struct TransferKeyPair(HpkeKeyPair);

impl TransferKeyPair {
    pub(crate) fn fresh(provider: &impl OpenMlsProvider) -> Result<Self, HistoryError> {
        let ikm: SecretVLBytes = provider
            .rand()
            .random_vec(32)
            .map_err(|_| HistoryError::Crypto)?
            .into();
        let pair = provider
            .crypto()
            .derive_hpke_keypair(suite(), ikm.as_slice())
            .map_err(|_| HistoryError::Crypto)?;
        if pair.public.len() != 32 || pair.private.len() != 32 {
            return Err(HistoryError::Crypto);
        }
        Ok(Self(pair))
    }

    pub(crate) fn public_key(&self) -> &[u8] {
        &self.0.public
    }

    /// Native sealed-state serialization only; never exposed through FFI.
    pub(crate) fn state_private(&self) -> &[u8] {
        &self.0.private
    }

    pub(crate) fn restore_for_state(
        provider: &impl OpenMlsProvider,
        private: &[u8],
        public: &[u8],
    ) -> Result<Self, HistoryError> {
        if private.len() != 32 || public.len() != 32 {
            return Err(HistoryError::InvalidInput);
        }
        let pair = HpkeKeyPair {
            private: private.into(),
            public: public.to_vec(),
        };
        // The envelope authenticates storage, but reject an internally
        // inconsistent pair before returning a resumable transfer handle.
        let label = b"veritra-k2-state-keypair-check-v1";
        let encrypted = provider
            .crypto()
            .hpke_seal(suite(), public, label, &[], label)
            .map_err(|_| HistoryError::Authentication)?;
        let opened: SecretVLBytes = provider
            .crypto()
            .hpke_open(suite(), &encrypted, &pair.private, label, &[])
            .map_err(|_| HistoryError::Authentication)?
            .into();
        if opened.as_slice() != label {
            return Err(HistoryError::Authentication);
        }
        Ok(Self(pair))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct BundleHeader {
    pub account_id: Vec<u8>,
    pub source_device_id: Vec<u8>,
    pub created_at_ms: u64,
    pub snapshot_counter: u64,
    pub recovery_key_id: Option<[u8; 16]>,
    pub plaintext_version: u8,
}

/// Expected values come from locally pinned identity and the authenticated
/// handoff, never from labels in the downloaded bundle itself.
pub(crate) struct ExpectedBundle<'a> {
    pub account_id: &'a [u8],
    pub source_device_id: &'a [u8],
    pub snapshot_counter: u64,
    pub header_sha256: &'a [u8; 32],
    pub ciphertext_sha256: &'a [u8; 32],
    pub ciphertext_size: u64,
    pub plaintext_version: u8,
}

pub(crate) struct SealedBundle {
    pub ciphertext: Vec<u8>,
    pub header_sha256: [u8; 32],
    pub ciphertext_sha256: [u8; 32],
    pub secrets: FileSecrets,
}

pub(crate) struct OpenedBundle {
    pub header: BundleHeader,
    pub payload: SecretVLBytes,
}

fn valid_id(id: &[u8]) -> bool {
    !id.is_empty() && id.len() <= MAX_ID
}

fn validate_header(header: &BundleHeader) -> Result<(), HistoryError> {
    if !valid_id(&header.account_id)
        || !valid_id(&header.source_device_id)
        || header.created_at_ms == 0
        || header.snapshot_counter == 0
        || header.plaintext_version == 0
    {
        return Err(HistoryError::InvalidInput);
    }
    Ok(())
}

fn append_lp(output: &mut Vec<u8>, bytes: &[u8]) -> Result<(), HistoryError> {
    let len = u16::try_from(bytes.len()).map_err(|_| HistoryError::InvalidInput)?;
    output.extend_from_slice(&len.to_be_bytes());
    output.extend_from_slice(bytes);
    Ok(())
}

fn padded_size(payload_len: usize) -> Result<usize, HistoryError> {
    let framed = payload_len
        .checked_add(8)
        .ok_or(HistoryError::InvalidInput)?;
    let rounded = framed
        .checked_add(FRAME_BUCKET - 1)
        .ok_or(HistoryError::InvalidInput)?
        / FRAME_BUCKET
        * FRAME_BUCKET;
    if rounded > MAX_PADDED_HISTORY {
        return Err(HistoryError::InvalidInput);
    }
    Ok(rounded)
}

fn encode_header(header: &BundleHeader, padded: usize) -> Result<Vec<u8>, HistoryError> {
    validate_header(header)?;
    if padded == 0 || padded > MAX_PADDED_HISTORY || !padded.is_multiple_of(FRAME_BUCKET) {
        return Err(HistoryError::InvalidInput);
    }
    let mut bytes = Vec::with_capacity(MAX_HEADER);
    bytes.extend_from_slice(MAGIC);
    bytes.push(BUNDLE_KIND);
    append_lp(&mut bytes, &header.account_id)?;
    append_lp(&mut bytes, &header.source_device_id)?;
    bytes.extend_from_slice(&header.created_at_ms.to_be_bytes());
    bytes.extend_from_slice(&header.snapshot_counter.to_be_bytes());
    append_lp(
        &mut bytes,
        header
            .recovery_key_id
            .as_ref()
            .map_or(&[], |id| id.as_slice()),
    )?;
    let chunks = padded.div_ceil(MAX_ATTACHMENT_CHUNK);
    bytes.extend_from_slice(&(chunks as u32).to_be_bytes());
    bytes.extend_from_slice(&(padded as u64).to_be_bytes());
    bytes.push(header.plaintext_version);
    // K0: kind2 bundles have no recovery HPKE encapsulation/sealed file key.
    append_lp(&mut bytes, &[])?;
    append_lp(&mut bytes, &[])?;
    Ok(bytes)
}

fn chunk_context(header: &[u8]) -> Vec<u8> {
    [BUNDLE_CONTEXT, Sha256::digest(header).as_slice()].concat()
}

pub(crate) fn seal_bundle(
    provider: &impl OpenMlsProvider,
    header: &BundleHeader,
    payload: &[u8],
) -> Result<SealedBundle, HistoryError> {
    let padded = padded_size(payload.len())?;
    let encoded_header = encode_header(header, padded)?;
    let secrets = FileSecrets::fresh(provider)?;
    let ciphertext = seal_with_secrets(&encoded_header, payload, padded, &secrets)?;
    Ok(SealedBundle {
        header_sha256: Sha256::digest(&encoded_header).into(),
        ciphertext_sha256: Sha256::digest(&ciphertext).into(),
        ciphertext,
        secrets,
    })
}

fn seal_with_secrets(
    encoded_header: &[u8],
    payload: &[u8],
    padded: usize,
    secrets: &FileSecrets,
) -> Result<Vec<u8>, HistoryError> {
    let mut frame = Vec::with_capacity(padded);
    frame.extend_from_slice(&(payload.len() as u64).to_be_bytes());
    frame.extend_from_slice(payload);
    frame.resize(padded, 0);
    let frame: SecretVLBytes = frame.into();
    let context = chunk_context(encoded_header);
    let mut ciphertext = Vec::with_capacity(
        encoded_header.len() + padded + padded.div_ceil(MAX_ATTACHMENT_CHUNK) * 20,
    );
    ciphertext.extend_from_slice(encoded_header);
    for (index, chunk) in frame.as_slice().chunks(MAX_ATTACHMENT_CHUNK).enumerate() {
        let encrypted = encrypt_chunk(
            secrets.key.as_slice(),
            &secrets.nonce_prefix,
            index as u32,
            &context,
            chunk,
        )
        .map_err(|_| HistoryError::Crypto)?;
        ciphertext.extend_from_slice(&(encrypted.len() as u32).to_be_bytes());
        ciphertext.extend_from_slice(&encrypted);
    }
    Ok(ciphertext)
}

fn read_header(reader: &mut Reader<'_>) -> Result<(BundleHeader, usize, usize), HistoryError> {
    if reader.take(4)? != MAGIC || reader.u8()? != BUNDLE_KIND {
        return Err(HistoryError::InvalidInput);
    }
    let account_id = reader.lp(MAX_ID)?.to_vec();
    let source_device_id = reader.lp(MAX_ID)?.to_vec();
    let created_at_ms = reader.u64()?;
    let snapshot_counter = reader.u64()?;
    let recovery_key_id = match reader.lp(16)? {
        [] => None,
        bytes if bytes.len() == 16 => {
            Some(bytes.try_into().map_err(|_| HistoryError::InvalidInput)?)
        }
        _ => return Err(HistoryError::InvalidInput),
    };
    let chunks = reader.u32()? as usize;
    let padded = usize::try_from(reader.u64()?).map_err(|_| HistoryError::InvalidInput)?;
    let plaintext_version = reader.u8()?;
    if !reader.lp(0)?.is_empty() || !reader.lp(0)?.is_empty() {
        return Err(HistoryError::InvalidInput);
    }
    let header = BundleHeader {
        account_id,
        source_device_id,
        created_at_ms,
        snapshot_counter,
        recovery_key_id,
        plaintext_version,
    };
    validate_header(&header)?;
    if padded == 0
        || padded > MAX_PADDED_HISTORY
        || !padded.is_multiple_of(FRAME_BUCKET)
        || chunks != padded.div_ceil(MAX_ATTACHMENT_CHUNK)
        || reader.offset > MAX_HEADER
    {
        return Err(HistoryError::InvalidInput);
    }
    Ok((header, padded, chunks))
}

pub(crate) fn open_bundle(
    ciphertext: &[u8],
    secrets: &FileSecrets,
    expected: &ExpectedBundle<'_>,
) -> Result<OpenedBundle, HistoryError> {
    // 64 chunks, each with u32 framing and a 16-byte GCM tag, plus header.
    let max_ciphertext = MAX_PADDED_HISTORY + 64 * 20 + MAX_HEADER;
    if ciphertext.len() > max_ciphertext
        || !valid_id(expected.account_id)
        || !valid_id(expected.source_device_id)
    {
        return Err(HistoryError::InvalidInput);
    }
    if ciphertext.len() as u64 != expected.ciphertext_size
        || <[u8; 32]>::from(Sha256::digest(ciphertext)) != *expected.ciphertext_sha256
    {
        return Err(HistoryError::Authentication);
    }
    let mut reader = Reader::new(ciphertext);
    let (header, padded, chunks) = read_header(&mut reader)?;
    let encoded_header = &ciphertext[..reader.offset];
    if header.account_id != expected.account_id
        || header.source_device_id != expected.source_device_id
        || header.snapshot_counter != expected.snapshot_counter
        || header.plaintext_version != expected.plaintext_version
        || <[u8; 32]>::from(Sha256::digest(encoded_header)) != *expected.header_sha256
    {
        return Err(HistoryError::Authentication);
    }
    let context = chunk_context(encoded_header);
    let mut frame = SecretVLBytes::new(Vec::with_capacity(padded));
    for index in 0..chunks {
        let plaintext_span = (padded - index * MAX_ATTACHMENT_CHUNK).min(MAX_ATTACHMENT_CHUNK);
        let length = reader.u32()? as usize;
        if length != plaintext_span + 16 {
            return Err(HistoryError::InvalidInput);
        }
        let encrypted = reader.take(length)?;
        let chunk: SecretVLBytes = decrypt_chunk(
            secrets.key.as_slice(),
            &secrets.nonce_prefix,
            index as u32,
            &context,
            encrypted,
        )
        .map_err(|_| HistoryError::Authentication)?
        .into();
        for byte in chunk.as_slice() {
            frame.push(*byte);
        }
    }
    if !reader.finished() || frame.as_slice().len() != padded {
        return Err(HistoryError::InvalidInput);
    }
    let payload_len = usize::try_from(u64::from_be_bytes(
        frame.as_slice()[..8]
            .try_into()
            .map_err(|_| HistoryError::InvalidInput)?,
    ))
    .map_err(|_| HistoryError::InvalidInput)?;
    let end = payload_len
        .checked_add(8)
        .ok_or(HistoryError::InvalidInput)?;
    if end > padded
        || padded_size(payload_len)? != padded
        || frame.as_slice()[end..].iter().any(|b| *b != 0)
    {
        return Err(HistoryError::InvalidInput);
    }
    Ok(OpenedBundle {
        header,
        payload: frame.as_slice()[8..end].into(),
    })
}

/// All values are locally pinned by the v3 keyed transcript. None may be
/// populated from the unverified downloaded handoff or bundle header.
pub(crate) struct TransferContext<'a> {
    pub server_origin: &'a [u8],
    pub link_id: &'a [u8],
    pub account_id: &'a [u8],
    pub source_device_id: &'a [u8],
    pub source_signing_key: &'a [u8; 32],
    pub recipient_device_id: &'a [u8],
    pub recipient_signing_key: &'a [u8; 32],
    pub transfer_public_key: &'a [u8; 32],
    pub transcript_hash: &'a [u8; 32],
}

fn context_aad(context: &TransferContext<'_>) -> Result<Vec<u8>, HistoryError> {
    if context.server_origin.is_empty()
        || context.server_origin.len() > MAX_ORIGIN
        || !valid_id(context.link_id)
        || !valid_id(context.account_id)
        || !valid_id(context.source_device_id)
        || !valid_id(context.recipient_device_id)
        || context.source_device_id == context.recipient_device_id
        || context.source_signing_key == context.recipient_signing_key
    {
        return Err(HistoryError::InvalidInput);
    }
    let mut bytes = Vec::with_capacity(MAX_ORIGIN + 512);
    bytes.extend_from_slice(HANDOFF_AAD);
    for field in [
        b"veritra-device-link-v3".as_slice(),
        context.server_origin,
        context.link_id,
        context.account_id,
        context.source_device_id,
        context.source_signing_key.as_slice(),
        context.recipient_device_id,
        context.recipient_signing_key.as_slice(),
        context.transfer_public_key.as_slice(),
        context.transcript_hash.as_slice(),
    ] {
        append_lp(&mut bytes, field)?;
    }
    Ok(bytes)
}

pub(crate) struct RecoveryIdentity {
    pub public_key: [u8; 32],
    pub id: [u8; 16],
}

pub(crate) struct HandoffPayload {
    pub blob_id: Vec<u8>,
    pub ciphertext_sha256: [u8; 32],
    pub ciphertext_size: u64,
    pub snapshot_counter: u64,
    pub header_sha256: [u8; 32],
    pub secrets: FileSecrets,
    pub recovery_identity: Option<RecoveryIdentity>,
}

fn recovery_id(public_key: &[u8; 32]) -> [u8; 16] {
    let digest = Sha256::digest([b"veritra-k0-rk-id-v1".as_slice(), public_key].concat());
    let mut id = [0; 16];
    id.copy_from_slice(&digest[..16]);
    id
}

fn encode_payload(
    context: &TransferContext<'_>,
    payload: &HandoffPayload,
) -> Result<SecretVLBytes, HistoryError> {
    if !valid_id(&payload.blob_id)
        || payload.ciphertext_size == 0
        || payload.ciphertext_size > (MAX_PADDED_HISTORY + 64 * 20 + MAX_HEADER) as u64
        || payload.snapshot_counter == 0
        || payload
            .recovery_identity
            .as_ref()
            .is_some_and(|rk| recovery_id(&rk.public_key) != rk.id)
    {
        return Err(HistoryError::InvalidInput);
    }
    // All fallible identity/size checks precede copying file-key material.
    // Keep secret fields in one allocation through the complete encoding.
    let mut bytes = Vec::with_capacity(MAX_HANDOFF);
    bytes.push(1);
    append_lp(&mut bytes, context.link_id)?;
    bytes.extend_from_slice(context.transcript_hash);
    append_lp(&mut bytes, context.account_id)?;
    append_lp(&mut bytes, context.source_device_id)?;
    append_lp(&mut bytes, context.recipient_device_id)?;
    append_lp(&mut bytes, &payload.blob_id)?;
    bytes.extend_from_slice(&payload.ciphertext_sha256);
    bytes.extend_from_slice(&payload.ciphertext_size.to_be_bytes());
    bytes.extend_from_slice(&payload.snapshot_counter.to_be_bytes());
    bytes.extend_from_slice(&payload.header_sha256);
    bytes.extend_from_slice(payload.secrets.key.as_slice());
    bytes.extend_from_slice(&payload.secrets.nonce_prefix);
    match &payload.recovery_identity {
        None => bytes.push(0),
        Some(rk) => {
            bytes.push(1);
            bytes.extend_from_slice(&rk.public_key);
            bytes.extend_from_slice(&rk.id);
        }
    }
    Ok(bytes.into())
}

fn decode_payload(
    bytes: &[u8],
    context: &TransferContext<'_>,
) -> Result<HandoffPayload, HistoryError> {
    let mut reader = Reader::new(bytes);
    if reader.u8()? != 1
        || reader.lp(MAX_ID)? != context.link_id
        || reader.take(32)? != context.transcript_hash
        || reader.lp(MAX_ID)? != context.account_id
        || reader.lp(MAX_ID)? != context.source_device_id
        || reader.lp(MAX_ID)? != context.recipient_device_id
    {
        return Err(HistoryError::Authentication);
    }
    let blob_id = reader.lp(MAX_ID)?.to_vec();
    let ciphertext_sha256 = reader.array::<32>()?;
    let ciphertext_size = reader.u64()?;
    let snapshot_counter = reader.u64()?;
    let header_sha256 = reader.array::<32>()?;
    let secrets = FileSecrets::from_bytes(reader.take(32)?, reader.take(8)?)?;
    let recovery_identity = match reader.u8()? {
        0 => None,
        1 => Some(RecoveryIdentity {
            public_key: reader.array()?,
            id: reader.array()?,
        }),
        _ => return Err(HistoryError::InvalidInput),
    };
    let payload = HandoffPayload {
        blob_id,
        ciphertext_sha256,
        ciphertext_size,
        snapshot_counter,
        header_sha256,
        secrets,
        recovery_identity,
    };
    if !reader.finished() {
        return Err(HistoryError::InvalidInput);
    }
    // Reuse the exact allow-list checks without accepting extra plaintext.
    let _checked = encode_payload(context, &payload)?;
    Ok(payload)
}

fn signature_message(hash: &[u8; 32], encrypted: &HpkeCiphertext) -> Result<Vec<u8>, HistoryError> {
    let mut message = HANDOFF_SIGNATURE.to_vec();
    message.extend_from_slice(hash);
    append_lp(&mut message, encrypted.kem_output.as_slice())?;
    append_lp(&mut message, encrypted.ciphertext.as_slice())?;
    Ok(message)
}

pub(crate) fn seal_handoff(
    provider: &impl OpenMlsProvider,
    signer: &SignatureKeyPair,
    context: &TransferContext<'_>,
    link_key: &[u8; 32],
    payload: &HandoffPayload,
) -> Result<Vec<u8>, HistoryError> {
    if signer.public() != context.source_signing_key
        || signer.signature_scheme() != SignatureScheme::ED25519
    {
        return Err(HistoryError::InvalidInput);
    }
    let aad = context_aad(context)?;
    let plaintext = encode_payload(context, payload)?;
    let info: SecretVLBytes = [
        HANDOFF_INFO,
        link_key.as_slice(),
        context.transcript_hash.as_slice(),
    ]
    .concat()
    .into();
    let encrypted = provider
        .crypto()
        .hpke_seal(
            suite(),
            context.transfer_public_key,
            info.as_slice(),
            &aad,
            plaintext.as_slice(),
        )
        .map_err(|_| HistoryError::Crypto)?;
    let signature = signer
        .sign(&signature_message(context.transcript_hash, &encrypted)?)
        .map_err(|_| HistoryError::Crypto)?;
    if encrypted.kem_output.as_slice().len() != 32 || signature.len() != 64 {
        return Err(HistoryError::Crypto);
    }
    let mut bytes = HANDOFF_MAGIC.to_vec();
    append_lp(&mut bytes, encrypted.kem_output.as_slice())?;
    append_lp(&mut bytes, encrypted.ciphertext.as_slice())?;
    append_lp(&mut bytes, &signature)?;
    if bytes.len() > MAX_HANDOFF {
        return Err(HistoryError::InvalidInput);
    }
    Ok(bytes)
}

pub(crate) fn open_handoff(
    provider: &impl OpenMlsProvider,
    transfer_key: &TransferKeyPair,
    context: &TransferContext<'_>,
    link_key: &[u8; 32],
    bytes: &[u8],
) -> Result<HandoffPayload, HistoryError> {
    if bytes.len() > MAX_HANDOFF || transfer_key.public_key() != context.transfer_public_key {
        return Err(HistoryError::InvalidInput);
    }
    let aad = context_aad(context)?;
    let mut reader = Reader::new(bytes);
    if reader.take(4)? != HANDOFF_MAGIC {
        return Err(HistoryError::InvalidInput);
    }
    let enc = reader.lp(32)?;
    let ciphertext = reader.lp(MAX_HANDOFF)?;
    let signature = reader.lp(64)?;
    if enc.len() != 32 || signature.len() != 64 || ciphertext.len() < 16 || !reader.finished() {
        return Err(HistoryError::InvalidInput);
    }
    let encrypted = HpkeCiphertext {
        kem_output: enc.into(),
        ciphertext: ciphertext.into(),
    };
    provider
        .crypto()
        .verify_signature(
            SignatureScheme::ED25519,
            &signature_message(context.transcript_hash, &encrypted)?,
            context.source_signing_key,
            signature,
        )
        .map_err(|_| HistoryError::Authentication)?;
    let info: SecretVLBytes = [
        HANDOFF_INFO,
        link_key.as_slice(),
        context.transcript_hash.as_slice(),
    ]
    .concat()
    .into();
    let plaintext: SecretVLBytes = provider
        .crypto()
        .hpke_open(
            suite(),
            &encrypted,
            &transfer_key.0.private,
            info.as_slice(),
            &aad,
        )
        .map_err(|_| HistoryError::Authentication)?
        .into();
    decode_payload(plaintext.as_slice(), context)
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }
    fn take(&mut self, len: usize) -> Result<&'a [u8], HistoryError> {
        let end = self
            .offset
            .checked_add(len)
            .ok_or(HistoryError::InvalidInput)?;
        let bytes = self
            .bytes
            .get(self.offset..end)
            .ok_or(HistoryError::InvalidInput)?;
        self.offset = end;
        Ok(bytes)
    }
    fn array<const N: usize>(&mut self) -> Result<[u8; N], HistoryError> {
        self.take(N)?
            .try_into()
            .map_err(|_| HistoryError::InvalidInput)
    }
    fn u8(&mut self) -> Result<u8, HistoryError> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, HistoryError> {
        Ok(u16::from_be_bytes(self.array()?))
    }
    fn u32(&mut self) -> Result<u32, HistoryError> {
        Ok(u32::from_be_bytes(self.array()?))
    }
    fn u64(&mut self) -> Result<u64, HistoryError> {
        Ok(u64::from_be_bytes(self.array()?))
    }
    fn lp(&mut self, max: usize) -> Result<&'a [u8], HistoryError> {
        let length = self.u16()? as usize;
        if length > max {
            return Err(HistoryError::InvalidInput);
        }
        self.take(length)
    }
    fn finished(&self) -> bool {
        self.offset == self.bytes.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls_rust_crypto::OpenMlsRustCrypto;

    fn header() -> BundleHeader {
        BundleHeader {
            account_id: b"acct_1".to_vec(),
            source_device_id: b"dev_old".to_vec(),
            created_at_ms: 1_730_000_000_000,
            snapshot_counter: 7,
            recovery_key_id: None,
            plaintext_version: 5,
        }
    }

    fn expected<'a>(bundle: &'a SealedBundle) -> ExpectedBundle<'a> {
        ExpectedBundle {
            account_id: b"acct_1",
            source_device_id: b"dev_old",
            snapshot_counter: 7,
            header_sha256: &bundle.header_sha256,
            ciphertext_sha256: &bundle.ciphertext_sha256,
            ciphertext_size: bundle.ciphertext.len() as u64,
            plaintext_version: 5,
        }
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn canonical_k0_bundle_header_has_an_independent_vector() {
        // Python struct.pack/hashlib, independent of this Rust encoder.
        let encoded = encode_header(&header(), FRAME_BUCKET).unwrap();
        assert_eq!(hex(&encoded), "56484331020006616363745f3100076465765f6f6c6400000192cc091400000000000000000700000000000100000000000100000500000000");
        assert_eq!(
            hex(&Sha256::digest(&encoded)),
            "7a91fb3a0bcdf84232d0a8f181bed8773782eda0f2752b803808be9e32358395"
        );
        let mut reader = Reader::new(&encoded);
        let (decoded, padded, chunks) = read_header(&mut reader).unwrap();
        assert_eq!(decoded, header());
        assert_eq!((padded, chunks), (FRAME_BUCKET, 1));
        assert!(reader.finished());
        let mut with_rk = header();
        with_rk.recovery_key_id = Some([9; 16]);
        let encoded = encode_header(&with_rk, FRAME_BUCKET).unwrap();
        assert_eq!(read_header(&mut Reader::new(&encoded)).unwrap().0, with_rk);
    }

    #[test]
    fn bundle_round_trips_empty_bucket_and_multiple_chunks_with_fresh_keys() {
        let provider = OpenMlsRustCrypto::default();
        for len in [
            0,
            FRAME_BUCKET - 8,
            FRAME_BUCKET - 7,
            MAX_ATTACHMENT_CHUNK + 3,
        ] {
            let payload = vec![0x42; len];
            let bundle = seal_bundle(&provider, &header(), &payload).unwrap();
            let opened =
                open_bundle(&bundle.ciphertext, &bundle.secrets, &expected(&bundle)).unwrap();
            assert_eq!(opened.header, header());
            assert_eq!(opened.payload.as_slice(), payload);
        }
        let first = seal_bundle(&provider, &header(), b"synthetic").unwrap();
        let second = seal_bundle(&provider, &header(), b"synthetic").unwrap();
        assert!(first.secrets.key.as_slice() != second.secrets.key.as_slice());
        assert_ne!(first.secrets.nonce_prefix, second.secrets.nonce_prefix);
        assert_ne!(first.ciphertext_sha256, second.ciphertext_sha256);
    }

    #[test]
    fn bounded_frame_math_refuses_overflow_and_noncanonical_headers() {
        assert_eq!(padded_size(0), Ok(FRAME_BUCKET));
        assert_eq!(padded_size(MAX_PADDED_HISTORY - 8), Ok(MAX_PADDED_HISTORY));
        assert_eq!(
            padded_size(MAX_PADDED_HISTORY - 7),
            Err(HistoryError::InvalidInput)
        );
        assert_eq!(padded_size(usize::MAX), Err(HistoryError::InvalidInput));
        let mut invalid = header();
        invalid.account_id.clear();
        assert!(encode_header(&invalid, FRAME_BUCKET).is_err());
        invalid = header();
        invalid.source_device_id = vec![1; MAX_ID + 1];
        assert!(encode_header(&invalid, FRAME_BUCKET).is_err());
        for field in 0..3 {
            invalid = header();
            match field {
                0 => invalid.created_at_ms = 0,
                1 => invalid.snapshot_counter = 0,
                _ => invalid.plaintext_version = 0,
            }
            assert!(encode_header(&invalid, FRAME_BUCKET).is_err());
        }
        let encoded = encode_header(&header(), FRAME_BUCKET).unwrap();
        for len in 0..encoded.len() {
            assert!(read_header(&mut Reader::new(&encoded[..len])).is_err());
        }
        let mut changed = encoded.clone();
        changed[4] = 1; // Recovery containers are not implemented by K2.
        assert!(read_header(&mut Reader::new(&changed)).is_err());
        changed = encoded.clone();
        changed[5..7].copy_from_slice(&u16::MAX.to_be_bytes());
        assert!(read_header(&mut Reader::new(&changed)).is_err());
        for index in [encoded.len() - 3, encoded.len() - 1] {
            changed = encoded.clone();
            changed[index] = 1; // Both HPKE fields must be empty for bundles.
            assert!(read_header(&mut Reader::new(&changed)).is_err());
        }
    }

    #[test]
    fn bundle_open_requires_pinned_identity_digest_version_and_counter() {
        let bundle = seal_bundle(&OpenMlsRustCrypto::default(), &header(), b"synthetic").unwrap();
        for field in 0..7 {
            let mut check = expected(&bundle);
            let wrong = [7u8; 32];
            match field {
                0 => check.account_id = b"other",
                1 => check.source_device_id = b"other",
                2 => check.snapshot_counter += 1,
                3 => check.plaintext_version += 1,
                4 => check.header_sha256 = &wrong,
                5 => check.ciphertext_sha256 = &wrong,
                _ => check.ciphertext_size += 1,
            }
            assert!(open_bundle(&bundle.ciphertext, &bundle.secrets, &check).is_err());
        }
        let wrong_key = FileSecrets::from_bytes(&[0x55; 32], &bundle.secrets.nonce_prefix).unwrap();
        assert!(open_bundle(&bundle.ciphertext, &wrong_key, &expected(&bundle)).is_err());
        let wrong_nonce =
            FileSecrets::from_bytes(bundle.secrets.key.as_slice(), &[0x66; 8]).unwrap();
        assert!(open_bundle(&bundle.ciphertext, &wrong_nonce, &expected(&bundle)).is_err());
    }

    fn raw_bundle(frame: &[u8], secrets: &FileSecrets) -> SealedBundle {
        let encoded_header = encode_header(&header(), frame.len()).unwrap();
        let mut ciphertext = encoded_header.clone();
        let context = chunk_context(&encoded_header);
        for (index, plaintext) in frame.chunks(MAX_ATTACHMENT_CHUNK).enumerate() {
            let chunk = encrypt_chunk(
                secrets.key.as_slice(),
                &secrets.nonce_prefix,
                index as u32,
                &context,
                plaintext,
            )
            .unwrap();
            ciphertext.extend_from_slice(&(chunk.len() as u32).to_be_bytes());
            ciphertext.extend_from_slice(&chunk);
        }
        SealedBundle {
            ciphertext_sha256: Sha256::digest(&ciphertext).into(),
            header_sha256: Sha256::digest(&encoded_header).into(),
            ciphertext,
            secrets: FileSecrets::from_bytes(secrets.key.as_slice(), &secrets.nonce_prefix)
                .unwrap(),
        }
    }

    #[test]
    fn authenticated_malformed_frames_and_bad_chunk_framing_are_rejected() {
        let secrets = FileSecrets::from_bytes(&[0x44; 32], &[0x55; 8]).unwrap();
        let mut frame = vec![0; FRAME_BUCKET];
        frame[..8].copy_from_slice(&1u64.to_be_bytes());
        frame[8] = 7;
        frame[9] = 1; // Authenticated nonzero padding is still noncanonical.
        let bad_padding = raw_bundle(&frame, &secrets);
        assert!(open_bundle(&bad_padding.ciphertext, &secrets, &expected(&bad_padding)).is_err());
        frame.fill(0);
        frame[..8].copy_from_slice(&u64::MAX.to_be_bytes());
        let bad_len = raw_bundle(&frame, &secrets);
        assert!(open_bundle(&bad_len.ciphertext, &secrets, &expected(&bad_len)).is_err());
        let overpadded = raw_bundle(&vec![0; 2 * FRAME_BUCKET], &secrets);
        assert!(open_bundle(&overpadded.ciphertext, &secrets, &expected(&overpadded)).is_err());
        let bundle = seal_bundle(&OpenMlsRustCrypto::default(), &header(), b"test").unwrap();
        let header_len = encode_header(&header(), FRAME_BUCKET).unwrap().len();
        for change in 0..4 {
            let mut ciphertext = bundle.ciphertext.clone();
            match change {
                0 => {
                    ciphertext.push(0);
                }
                1 => {
                    ciphertext.pop();
                }
                2 => {
                    ciphertext[header_len..header_len + 4].copy_from_slice(&16u32.to_be_bytes());
                }
                _ => {
                    ciphertext[header_len + 5] ^= 1;
                }
            }
            let digest: [u8; 32] = Sha256::digest(&ciphertext).into();
            let mut check = expected(&bundle);
            check.ciphertext_sha256 = &digest;
            check.ciphertext_size = ciphertext.len() as u64;
            assert!(open_bundle(&ciphertext, &bundle.secrets, &check).is_err());
        }
    }

    #[test]
    fn same_sized_chunks_cannot_be_reordered() {
        let bundle = seal_bundle(
            &OpenMlsRustCrypto::default(),
            &header(),
            &vec![0x33; 2 * MAX_ATTACHMENT_CHUNK],
        )
        .unwrap();
        let header_len = encode_header(&header(), 2 * MAX_ATTACHMENT_CHUNK + FRAME_BUCKET)
            .unwrap()
            .len();
        let span = MAX_ATTACHMENT_CHUNK + 16 + 4;
        let mut ciphertext = bundle.ciphertext.clone();
        ciphertext[header_len..header_len + span]
            .copy_from_slice(&bundle.ciphertext[header_len + span..header_len + 2 * span]);
        ciphertext[header_len + span..header_len + 2 * span]
            .copy_from_slice(&bundle.ciphertext[header_len..header_len + span]);
        let digest: [u8; 32] = Sha256::digest(&ciphertext).into();
        let mut check = expected(&bundle);
        check.ciphertext_sha256 = &digest;
        assert!(open_bundle(&ciphertext, &bundle.secrets, &check).is_err());
    }

    struct Fixture {
        provider: OpenMlsRustCrypto,
        signer: SignatureKeyPair,
        transfer: TransferKeyPair,
        public: [u8; 32],
        source_signing: [u8; 32],
    }

    impl Fixture {
        fn new() -> Self {
            let provider = OpenMlsRustCrypto::default();
            let signer = SignatureKeyPair::new(SignatureScheme::ED25519).unwrap();
            let transfer = TransferKeyPair::fresh(&provider).unwrap();
            let public = transfer.public_key().try_into().unwrap();
            let source_signing = signer.public().try_into().unwrap();
            Self {
                provider,
                signer,
                transfer,
                public,
                source_signing,
            }
        }
        fn context(&self) -> TransferContext<'_> {
            TransferContext {
                server_origin: b"https://example.test",
                link_id: b"link_1",
                account_id: b"acct_1",
                source_device_id: b"dev_old",
                source_signing_key: &self.source_signing,
                recipient_device_id: b"dev_new",
                recipient_signing_key: &[2; 32],
                transfer_public_key: &self.public,
                transcript_hash: &[3; 32],
            }
        }
        fn payload(&self) -> HandoffPayload {
            HandoffPayload {
                blob_id: b"blob_1".to_vec(),
                ciphertext_sha256: [0x22; 32],
                ciphertext_size: 70_000,
                snapshot_counter: 7,
                header_sha256: [0x33; 32],
                secrets: FileSecrets::from_bytes(&[0x44; 32], &[0x55; 8]).unwrap(),
                recovery_identity: None,
            }
        }
    }

    #[test]
    fn hpke_handoff_authenticates_the_source_and_round_trips_bundle_keys() {
        let fixture = Fixture::new();
        let mut payload = fixture.payload();
        let public_key = [0x66; 32];
        payload.recovery_identity = Some(RecoveryIdentity {
            public_key,
            id: recovery_id(&public_key),
        });
        let sealed = seal_handoff(
            &fixture.provider,
            &fixture.signer,
            &fixture.context(),
            &[7; 32],
            &payload,
        )
        .unwrap();
        let opened = open_handoff(
            &fixture.provider,
            &fixture.transfer,
            &fixture.context(),
            &[7; 32],
            &sealed,
        )
        .unwrap();
        assert_eq!(opened.blob_id, payload.blob_id);
        assert_eq!(opened.ciphertext_sha256, payload.ciphertext_sha256);
        assert_eq!(opened.ciphertext_size, payload.ciphertext_size);
        assert_eq!(opened.header_sha256, payload.header_sha256);
        assert_eq!(opened.snapshot_counter, payload.snapshot_counter);
        assert!(opened.secrets.key.as_slice() == payload.secrets.key.as_slice());
        assert_eq!(opened.secrets.nonce_prefix, payload.secrets.nonce_prefix);
        assert_eq!(
            opened.recovery_identity.unwrap().id,
            recovery_id(&public_key)
        );
        let other = TransferKeyPair::fresh(&fixture.provider).unwrap();
        assert_ne!(fixture.transfer.public_key(), other.public_key());
        assert!(open_handoff(
            &fixture.provider,
            &other,
            &fixture.context(),
            &[7; 32],
            &sealed
        )
        .is_err());
        let wrong_signer = SignatureKeyPair::new(SignatureScheme::ED25519).unwrap();
        assert!(seal_handoff(
            &fixture.provider,
            &wrong_signer,
            &fixture.context(),
            &[7; 32],
            &payload
        )
        .is_err());
    }

    #[test]
    fn hpke_handoff_binds_every_pinned_context_and_refuses_substitution() {
        let fixture = Fixture::new();
        let sealed = seal_handoff(
            &fixture.provider,
            &fixture.signer,
            &fixture.context(),
            &[7; 32],
            &fixture.payload(),
        )
        .unwrap();
        for field in 0..9 {
            let mut changed = fixture.context();
            let wrong = [8u8; 32];
            match field {
                0 => changed.server_origin = b"https://other.test",
                1 => changed.link_id = b"other",
                2 => changed.account_id = b"other",
                3 => changed.source_device_id = b"other",
                4 => changed.source_signing_key = &wrong,
                5 => changed.recipient_device_id = b"other",
                6 => changed.recipient_signing_key = &wrong,
                7 => changed.transfer_public_key = &wrong,
                _ => changed.transcript_hash = &wrong,
            }
            assert!(open_handoff(
                &fixture.provider,
                &fixture.transfer,
                &changed,
                &[7; 32],
                &sealed
            )
            .is_err());
        }
        assert!(open_handoff(
            &fixture.provider,
            &fixture.transfer,
            &fixture.context(),
            &[8; 32],
            &sealed
        )
        .is_err());
        for index in [0, 5, 7, 40, sealed.len() - 1] {
            let mut changed = sealed.clone();
            changed[index] ^= 1;
            assert!(open_handoff(
                &fixture.provider,
                &fixture.transfer,
                &fixture.context(),
                &[7; 32],
                &changed
            )
            .is_err());
        }
        for len in [0, 4, 5, sealed.len() - 1] {
            assert!(open_handoff(
                &fixture.provider,
                &fixture.transfer,
                &fixture.context(),
                &[7; 32],
                &sealed[..len]
            )
            .is_err());
        }
        let mut trailing = sealed.clone();
        trailing.push(0);
        assert!(open_handoff(
            &fixture.provider,
            &fixture.transfer,
            &fixture.context(),
            &[7; 32],
            &trailing
        )
        .is_err());
        assert!(open_handoff(
            &fixture.provider,
            &fixture.transfer,
            &fixture.context(),
            &[7; 32],
            &vec![0; MAX_HANDOFF + 1]
        )
        .is_err());
    }

    #[test]
    fn handoff_plaintext_is_bounded_and_recovery_key_identity_is_checked() {
        let fixture = Fixture::new();
        let mut payload = fixture.payload();
        payload.recovery_identity = Some(RecoveryIdentity {
            public_key: [1; 32],
            id: [2; 16],
        });
        assert!(seal_handoff(
            &fixture.provider,
            &fixture.signer,
            &fixture.context(),
            &[7; 32],
            &payload
        )
        .is_err());
        for field in 0..3 {
            payload = fixture.payload();
            match field {
                0 => payload.blob_id = vec![1; MAX_ID + 1],
                1 => payload.ciphertext_size = u64::MAX,
                _ => payload.snapshot_counter = 0,
            }
            assert!(seal_handoff(
                &fixture.provider,
                &fixture.signer,
                &fixture.context(),
                &[7; 32],
                &payload
            )
            .is_err());
        }
        let encoded = encode_payload(&fixture.context(), &fixture.payload()).unwrap();
        for len in 0..encoded.as_slice().len() {
            assert!(decode_payload(&encoded.as_slice()[..len], &fixture.context()).is_err());
        }
        let mut trailing = encoded.as_slice().to_vec();
        trailing.push(0);
        assert!(decode_payload(&trailing, &fixture.context()).is_err());
    }
}
