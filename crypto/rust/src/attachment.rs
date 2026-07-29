use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};

const DOMAIN: &[u8] = b"veritra-attachment-v1";
pub const MAX_ATTACHMENT_CHUNK: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentError {
    InvalidInput,
    Authentication,
}

fn nonce(prefix: &[u8], index: u32) -> Result<[u8; 12], AttachmentError> {
    if prefix.len() != 8 {
        return Err(AttachmentError::InvalidInput);
    }
    let mut value = [0u8; 12];
    value[..8].copy_from_slice(prefix);
    value[8..].copy_from_slice(&index.to_be_bytes());
    Ok(value)
}

fn aad(context: &[u8], index: u32) -> Vec<u8> {
    let mut value = Vec::with_capacity(DOMAIN.len() + 4 + context.len());
    value.extend_from_slice(DOMAIN);
    value.extend_from_slice(&index.to_be_bytes());
    value.extend_from_slice(context);
    value
}

pub fn encrypt_chunk(
    key: &[u8],
    nonce_prefix: &[u8],
    index: u32,
    context: &[u8],
    plaintext: &[u8],
) -> Result<Vec<u8>, AttachmentError> {
    if plaintext.len() > MAX_ATTACHMENT_CHUNK {
        return Err(AttachmentError::InvalidInput);
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| AttachmentError::InvalidInput)?;
    let nonce_bytes = nonce(nonce_prefix, index)?;
    let chunk_nonce =
        Nonce::try_from(nonce_bytes.as_slice()).map_err(|_| AttachmentError::InvalidInput)?;
    cipher
        .encrypt(
            &chunk_nonce,
            Payload {
                msg: plaintext,
                aad: &aad(context, index),
            },
        )
        .map_err(|_| AttachmentError::Authentication)
}

pub fn decrypt_chunk(
    key: &[u8],
    nonce_prefix: &[u8],
    index: u32,
    context: &[u8],
    ciphertext: &[u8],
) -> Result<Vec<u8>, AttachmentError> {
    if ciphertext.len() > MAX_ATTACHMENT_CHUNK + 16 {
        return Err(AttachmentError::InvalidInput);
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| AttachmentError::InvalidInput)?;
    let nonce_bytes = nonce(nonce_prefix, index)?;
    let chunk_nonce =
        Nonce::try_from(nonce_bytes.as_slice()).map_err(|_| AttachmentError::InvalidInput)?;
    cipher
        .decrypt(
            &chunk_nonce,
            Payload {
                msg: ciphertext,
                aad: &aad(context, index),
            },
        )
        .map_err(|_| AttachmentError::Authentication)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_context_and_order_are_authenticated() {
        let key = [7u8; 32];
        let nonce = [8u8; 8];
        let encrypted = encrypt_chunk(&key, &nonce, 2, b"conv/file", b"synthetic").unwrap();
        assert_eq!(
            decrypt_chunk(&key, &nonce, 2, b"conv/file", &encrypted).unwrap(),
            b"synthetic"
        );
        assert!(decrypt_chunk(&key, &nonce, 1, b"conv/file", &encrypted).is_err());
        assert!(decrypt_chunk(&key, &nonce, 2, b"other", &encrypted).is_err());
    }
}
