use super::{encode_device_identity, MlsDevice, MlsError, CIPHERSUITE};
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use openmls::prelude::{BasicCredential, CredentialWithKey};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::{random::OpenMlsRand, OpenMlsProvider};
use std::collections::HashMap;

const MAGIC: &[u8; 8] = b"PMMLSST1";
const FORMAT_VERSION: u16 = 1;
const NONCE_BYTES: usize = 12;
const KEY_BYTES: usize = 32;
const MAX_STATE_BYTES: usize = 32 * 1024 * 1024;
const MAX_RECORDS: usize = 100_000;
const MAX_RECORD_BYTES: usize = 4 * 1024 * 1024;

impl MlsDevice {
    /// Encrypts all MLS provider state under a platform-unwrapped state key.
    /// The monotonically increasing counter must be atomically committed by
    /// the platform together with this blob and its sync cursor.
    pub fn seal_state(&self, state_key: &[u8], counter: u64) -> Result<Vec<u8>, MlsError> {
        if state_key.len() != KEY_BYTES || counter == 0 {
            return Err(MlsError::InvalidState);
        }
        let values = self
            .provider
            .storage()
            .values
            .read()
            .map_err(|_| MlsError::Storage)?;
        let plaintext = encode_records(&values)?;
        let nonce = self
            .provider
            .rand()
            .random_vec(NONCE_BYTES)
            .map_err(|_| MlsError::KeyGeneration)?;
        let mut header = Vec::new();
        header.extend_from_slice(MAGIC);
        header.extend_from_slice(&FORMAT_VERSION.to_be_bytes());
        header.extend_from_slice(&counter.to_be_bytes());
        push_u16_bytes(&mut header, &self.account_id)?;
        push_u16_bytes(&mut header, &self.device_id)?;
        push_u16_bytes(&mut header, self.signer.public())?;
        header.extend_from_slice(&nonce);
        let cipher = Aes256Gcm::new_from_slice(state_key).map_err(|_| MlsError::InvalidState)?;
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &plaintext,
                    aad: &header,
                },
            )
            .map_err(|_| MlsError::Storage)?;
        if header.len() + 4 + ciphertext.len() > MAX_STATE_BYTES {
            return Err(MlsError::InvalidState);
        }
        header.extend_from_slice(&(ciphertext.len() as u32).to_be_bytes());
        header.extend_from_slice(&ciphertext);
        Ok(header)
    }

    /// Restores a state only when its identity and rollback counter match the
    /// platform-protected record. Authentication failure is deliberately
    /// indistinguishable from corrupt state.
    pub fn restore_state(
        account_id: &[u8],
        device_id: &[u8],
        state_key: &[u8],
        minimum_counter: u64,
        sealed: &[u8],
    ) -> Result<(Self, u64), MlsError> {
        encode_device_identity(account_id, device_id)?;
        if state_key.len() != KEY_BYTES || sealed.len() > MAX_STATE_BYTES {
            return Err(MlsError::InvalidState);
        }
        let mut reader = Reader::new(sealed);
        if reader.take(MAGIC.len())? != MAGIC {
            return Err(MlsError::InvalidState);
        }
        if reader.u16()? != FORMAT_VERSION {
            return Err(MlsError::InvalidState);
        }
        let counter = reader.u64()?;
        if counter < minimum_counter || counter == 0 {
            return Err(MlsError::Rollback);
        }
        if reader.u16_bytes()? != account_id || reader.u16_bytes()? != device_id {
            return Err(MlsError::InvalidState);
        }
        let public_key = reader.u16_bytes()?.to_vec();
        let nonce = reader.take(NONCE_BYTES)?.to_vec();
        let aad_end = reader.offset;
        let ciphertext_len = reader.u32()? as usize;
        let ciphertext = reader.take(ciphertext_len)?;
        if !reader.finished() {
            return Err(MlsError::InvalidState);
        }
        let cipher = Aes256Gcm::new_from_slice(state_key).map_err(|_| MlsError::InvalidState)?;
        let plaintext = cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: ciphertext,
                    aad: &sealed[..aad_end],
                },
            )
            .map_err(|_| MlsError::InvalidState)?;
        let records = decode_records(&plaintext)?;
        let provider = OpenMlsRustCrypto::default();
        *provider
            .storage()
            .values
            .write()
            .map_err(|_| MlsError::Storage)? = records;
        let signer = SignatureKeyPair::read(
            provider.storage(),
            &public_key,
            CIPHERSUITE.signature_algorithm(),
        )
        .ok_or(MlsError::InvalidState)?;
        let identity = encode_device_identity(account_id, device_id)?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity).into(),
            signature_key: signer.public().into(),
        };
        Ok((
            Self {
                provider,
                signer,
                credential,
                account_id: account_id.to_vec(),
                device_id: device_id.to_vec(),
            },
            counter,
        ))
    }
}

fn encode_records(values: &HashMap<Vec<u8>, Vec<u8>>) -> Result<Vec<u8>, MlsError> {
    if values.len() > MAX_RECORDS {
        return Err(MlsError::InvalidState);
    }
    let mut output = Vec::new();
    output.extend_from_slice(&(values.len() as u32).to_be_bytes());
    for (key, value) in values {
        if key.len() > MAX_RECORD_BYTES || value.len() > MAX_RECORD_BYTES {
            return Err(MlsError::InvalidState);
        }
        output.extend_from_slice(&(key.len() as u32).to_be_bytes());
        output.extend_from_slice(&(value.len() as u32).to_be_bytes());
        output.extend_from_slice(key);
        output.extend_from_slice(value);
        if output.len() > MAX_STATE_BYTES {
            return Err(MlsError::InvalidState);
        }
    }
    Ok(output)
}

fn decode_records(bytes: &[u8]) -> Result<HashMap<Vec<u8>, Vec<u8>>, MlsError> {
    let mut reader = Reader::new(bytes);
    let count = reader.u32()? as usize;
    if count > MAX_RECORDS {
        return Err(MlsError::InvalidState);
    }
    let mut records = HashMap::with_capacity(count);
    for _ in 0..count {
        let key_len = reader.u32()? as usize;
        let value_len = reader.u32()? as usize;
        if key_len > MAX_RECORD_BYTES || value_len > MAX_RECORD_BYTES {
            return Err(MlsError::InvalidState);
        }
        let key = reader.take(key_len)?.to_vec();
        let value = reader.take(value_len)?.to_vec();
        if records.insert(key, value).is_some() {
            return Err(MlsError::InvalidState);
        }
    }
    if !reader.finished() {
        return Err(MlsError::InvalidState);
    }
    Ok(records)
}

fn push_u16_bytes(output: &mut Vec<u8>, bytes: &[u8]) -> Result<(), MlsError> {
    let len = u16::try_from(bytes.len()).map_err(|_| MlsError::InvalidState)?;
    output.extend_from_slice(&len.to_be_bytes());
    output.extend_from_slice(bytes);
    Ok(())
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn take(&mut self, len: usize) -> Result<&'a [u8], MlsError> {
        let end = self.offset.checked_add(len).ok_or(MlsError::InvalidState)?;
        let value = self
            .bytes
            .get(self.offset..end)
            .ok_or(MlsError::InvalidState)?;
        self.offset = end;
        Ok(value)
    }

    fn u16(&mut self) -> Result<u16, MlsError> {
        Ok(u16::from_be_bytes(
            self.take(2)?
                .try_into()
                .map_err(|_| MlsError::InvalidState)?,
        ))
    }

    fn u32(&mut self) -> Result<u32, MlsError> {
        Ok(u32::from_be_bytes(
            self.take(4)?
                .try_into()
                .map_err(|_| MlsError::InvalidState)?,
        ))
    }

    fn u64(&mut self) -> Result<u64, MlsError> {
        Ok(u64::from_be_bytes(
            self.take(8)?
                .try_into()
                .map_err(|_| MlsError::InvalidState)?,
        ))
    }

    fn u16_bytes(&mut self) -> Result<&'a [u8], MlsError> {
        let len = self.u16()? as usize;
        self.take(len)
    }

    fn finished(&self) -> bool {
        self.offset == self.bytes.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: [u8; KEY_BYTES] = [7; KEY_BYTES];

    #[test]
    fn sealed_state_restores_groups_and_signing_identity() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let mut group = alice.create_group(b"conv_restart").unwrap();
        alice.encrypt(&mut group, b"advance state").unwrap();
        let sealed = alice.seal_state(&KEY, 9).unwrap();

        let (restored, counter) =
            MlsDevice::restore_state(b"acct_alice", b"dev_alice", &KEY, 9, &sealed).unwrap();
        let mut restored_group = restored.load_group(b"conv_restart").unwrap();

        assert_eq!(counter, 9);
        assert!(restored.create_key_package().is_ok());
        assert!(restored
            .encrypt(&mut restored_group, b"after restart")
            .is_ok());
    }

    #[test]
    fn corruption_identity_mismatch_and_rollback_fail_closed() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let sealed = alice.seal_state(&KEY, 4).unwrap();
        assert!(matches!(
            MlsDevice::restore_state(b"acct_alice", b"dev_alice", &KEY, 5, &sealed),
            Err(MlsError::Rollback)
        ));
        assert!(matches!(
            MlsDevice::restore_state(b"acct_alice", b"dev_other", &KEY, 4, &sealed),
            Err(MlsError::InvalidState)
        ));
        let mut corrupt = sealed.clone();
        let last = corrupt.len() - 1;
        corrupt[last] ^= 1;
        assert!(matches!(
            MlsDevice::restore_state(b"acct_alice", b"dev_alice", &KEY, 4, &corrupt),
            Err(MlsError::InvalidState)
        ));
        assert!(matches!(
            MlsDevice::restore_state(b"acct_alice", b"dev_alice", &[8; KEY_BYTES], 4, &sealed),
            Err(MlsError::InvalidState)
        ));
    }
}
