//! Internal protocol-v3 bytes. L0/v2 derivation and public ABI stay unchanged.

use super::{append_transcript_field, DeviceLinkVerification, MlsDevice, MlsError};
use openmls_traits::{crypto::OpenMlsCrypto, signatures::Signer, types::HashType, OpenMlsProvider};
use sha2::{Digest, Sha256};
use tls_codec::SecretVLBytes;

pub(crate) const VERSION: &[u8] = b"veritra-device-link-v3";

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct LinkContext {
    pub origin: Vec<u8>,
    pub link_id: Vec<u8>,
    pub account_id: Vec<u8>,
    pub nonce: [u8; 32],
    pub source_device_id: Vec<u8>,
    pub source_signing_key: [u8; 32],
    pub recipient_device_id: Vec<u8>,
    pub recipient_signing_key: [u8; 32],
    pub transfer_public_key: [u8; 32],
}

impl LinkContext {
    pub(crate) fn validate(&self) -> Result<(), MlsError> {
        if self.origin.is_empty()
            || self.origin.len() > 2048
            || !self.origin.is_ascii()
            || self.link_id.is_empty()
            || self.link_id.len() > 128
            || self.account_id.is_empty()
            || self.account_id.len() > 128
            || self.source_device_id.is_empty()
            || self.source_device_id.len() > 128
            || self.recipient_device_id.is_empty()
            || self.recipient_device_id.len() > 128
            || self.source_device_id == self.recipient_device_id
            || self.source_signing_key == self.recipient_signing_key
        {
            return Err(MlsError::InvalidIdentity);
        }
        Ok(())
    }

    pub(crate) fn transcript(&self) -> Result<Vec<u8>, MlsError> {
        self.validate()?;
        let mut bytes = Vec::with_capacity(512);
        for field in [
            super::DEVICE_LINK_TRANSCRIPT_DOMAIN,
            VERSION,
            self.origin.as_slice(),
            self.link_id.as_slice(),
            self.account_id.as_slice(),
            self.nonce.as_slice(),
            self.source_device_id.as_slice(),
            self.source_signing_key.as_slice(),
            self.recipient_device_id.as_slice(),
            self.recipient_signing_key.as_slice(),
            self.transfer_public_key.as_slice(),
        ] {
            append_transcript_field(&mut bytes, field)?;
        }
        Ok(bytes)
    }

    pub(crate) fn transcript_hash(&self) -> Result<[u8; 32], MlsError> {
        Ok(Sha256::digest(self.transcript()?).into())
    }
}

pub(crate) struct Verification {
    pub public: DeviceLinkVerification,
    pub link_key: SecretVLBytes,
}

pub(crate) fn derive(
    provider: &impl OpenMlsProvider,
    context: &LinkContext,
    secret: &[u8],
) -> Result<Verification, MlsError> {
    if secret.len() != 16 {
        return Err(MlsError::InvalidIdentity);
    }
    let transcript = context.transcript()?;
    let crypto = provider.crypto();
    let prk = crypto
        .hkdf_extract(HashType::Sha2_256, &[0; 32], secret)
        .map_err(|_| MlsError::KeyGeneration)?;
    let expand = |label: &[u8]| {
        crypto
            .hkdf_expand(HashType::Sha2_256, prk.as_slice(), label, 32)
            .map_err(|_| MlsError::KeyGeneration)
    };
    let mac = |label: &[u8]| {
        let key = expand(label)?;
        crypto
            .hmac(HashType::Sha2_256, key.as_slice(), &transcript)
            .map_err(|_| MlsError::KeyGeneration)
    };
    let sas = mac(b"veritra-link-sas-v3")?;
    let value = u32::from_be_bytes(
        sas.as_slice()[..4]
            .try_into()
            .map_err(|_| MlsError::InvalidState)?,
    ) % 100_000_000;
    Ok(Verification {
        public: DeviceLinkVerification {
            transcript_hash: Sha256::digest(&transcript).to_vec(),
            sas: format!("{value:08}"),
            claim_tag: mac(b"veritra-link-claim-v3")?.as_slice().to_vec(),
            approval_tag: mac(b"veritra-link-approval-v3")?.as_slice().to_vec(),
            sas_bytes: sas.as_slice()[..4].to_vec(),
        },
        link_key: expand(b"veritra-link-handoff-v3")?,
    })
}

pub(crate) fn equal_tag(left: &[u8], right: &[u8]) -> bool {
    left.len() == 32
        && right.len() == 32
        && left
            .iter()
            .zip(right)
            .fold(0u8, |difference, (a, b)| difference | (a ^ b))
            == 0
}

#[derive(Clone, Copy)]
pub(crate) struct EnrollmentProof<'a> {
    pub origin: &'a [u8],
    pub locator: &'a [u8],
    pub reservation_request_id: &'a [u8; 32],
    pub link_id: &'a [u8],
    pub account_id: &'a [u8],
    pub device_id: &'a [u8],
    pub device_name: &'a [u8],
    pub challenge: &'a [u8],
    pub key_package: &'a [u8],
    pub transfer_public_key: &'a [u8; 32],
    pub transcript_hash: &'a [u8; 32],
    pub claim_tag: &'a [u8; 32],
    pub claim_token_hash: &'a [u8; 32],
    pub device_secret_hash: &'a [u8; 32],
    pub initial_session_token_hash: &'a [u8; 32],
}

impl MlsDevice {
    pub(crate) fn sign_link_v3_enrollment(
        &self,
        proof: &EnrollmentProof<'_>,
    ) -> Result<Vec<u8>, MlsError> {
        if proof.account_id != self.account_id || proof.device_id != self.device_id {
            return Err(MlsError::InvalidIdentity);
        }
        self.signer
            .sign(&proof.message(self.signing_public_key())?)
            .map_err(|_| MlsError::KeyGeneration)
    }
}

impl EnrollmentProof<'_> {
    pub(crate) fn message(&self, signing_key: &[u8]) -> Result<Vec<u8>, MlsError> {
        let name = std::str::from_utf8(self.device_name).map_err(|_| MlsError::InvalidIdentity)?;
        if self.origin.is_empty()
            || self.origin.len() > 2048
            || !self.origin.is_ascii()
            || self.locator.len() != 64
            || !self
                .locator
                .iter()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
            || self.link_id.is_empty()
            || self.link_id.len() > 128
            || self.account_id.is_empty()
            || self.account_id.len() > 128
            || self.device_id.is_empty()
            || self.device_id.len() > 128
            || name.is_empty()
            || name.len() > 64
            || name.trim() != name
            || self.challenge.is_empty()
            || self.challenge.len() > 4096
            || !(64..=48 * 1024).contains(&self.key_package.len())
            || signing_key.len() != 32
        {
            return Err(MlsError::InvalidIdentity);
        }
        let mut message = b"veritra-device-link-enrollment-v3".to_vec();
        for field in [
            self.origin,
            self.locator,
            self.reservation_request_id.as_slice(),
            self.link_id,
            self.account_id,
            self.device_id,
            self.device_name,
            self.challenge,
        ] {
            append_transcript_field(&mut message, field)?;
        }
        message.extend_from_slice(signing_key);
        message.extend_from_slice(&Sha256::digest(self.key_package));
        for field in [
            self.transfer_public_key,
            self.transcript_hash,
            self.claim_tag,
            self.claim_token_hash,
            self.device_secret_hash,
            self.initial_session_token_hash,
        ] {
            message.extend_from_slice(field);
        }
        Ok(message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls_rust_crypto::OpenMlsRustCrypto;
    use openmls_traits::types::SignatureScheme;

    fn context() -> LinkContext {
        LinkContext {
            origin: b"https://example.test".to_vec(),
            link_id: b"link_01".to_vec(),
            account_id: b"acct_01".to_vec(),
            nonce: [0x11; 32],
            source_device_id: b"dev_old".to_vec(),
            source_signing_key: [0x22; 32],
            recipient_device_id: b"dev_new".to_vec(),
            recipient_signing_key: [0x33; 32],
            transfer_public_key: [0x44; 32],
        }
    }
    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn v3_transcript_and_tags_match_independent_python_vector() {
        let result = derive(&OpenMlsRustCrypto::default(), &context(), &[0x55; 16]).unwrap();
        assert_eq!(
            hex(&result.public.transcript_hash),
            "ad52136463e49d1c1484e12a2745de1722c99d402666dd533de03150391fb9db"
        );
        assert_eq!(hex(&result.public.sas_bytes), "57c5550c");
        assert_eq!(
            hex(&result.public.claim_tag),
            "c2a9ecda4a99dcab01dd4fc6550ff0f8e63c4d8d5fd9e68945e90461cc58f9a0"
        );
        assert_eq!(
            hex(&result.public.approval_tag),
            "286ebde23c3dd37261b73740c50486f76105dfd0e2924ad6173cfccc80b9ba27"
        );
        assert_eq!(
            hex(result.link_key.as_slice()),
            "9903ca5dc2658eb6b718de04202cc3d90268e6a6cc723a4d211fba1694092b58"
        );
    }

    #[test]
    fn v3_binds_all_fields_and_does_not_accept_clone_identity() {
        let provider = OpenMlsRustCrypto::default();
        let original = derive(&provider, &context(), &[0x55; 16]).unwrap();
        for field in 0..10 {
            let mut changed = context();
            match field {
                0 => changed.origin.push(b'x'),
                1 => changed.link_id.push(b'x'),
                2 => changed.account_id.push(b'x'),
                3 => changed.nonce[0] ^= 1,
                4 => changed.source_device_id.push(b'x'),
                5 => changed.source_signing_key[0] ^= 1,
                6 => changed.recipient_device_id.push(b'x'),
                7 => changed.recipient_signing_key[0] ^= 1,
                8 => changed.transfer_public_key[0] ^= 1,
                _ => {}
            }
            let secret = if field == 9 { [0x56; 16] } else { [0x55; 16] };
            let actual = derive(&provider, &changed, &secret).unwrap();
            assert_ne!(original.public.claim_tag, actual.public.claim_tag);
            assert_ne!(original.public.approval_tag, actual.public.approval_tag);
        }
        for size in [0, 15, 17] {
            assert!(derive(&provider, &context(), &vec![1; size]).is_err());
        }
        let mut cloned = context();
        cloned.recipient_device_id = cloned.source_device_id.clone();
        assert!(derive(&provider, &cloned, &[0x55; 16]).is_err());
        cloned = context();
        cloned.recipient_signing_key = cloned.source_signing_key;
        assert!(derive(&provider, &cloned, &[0x55; 16]).is_err());
    }

    fn proof() -> EnrollmentProof<'static> {
        EnrollmentProof {
            origin: b"https://example.test",
            locator: b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            reservation_request_id: &[0x11; 32],
            link_id: b"link_vector",
            account_id: b"acct_vector",
            device_id: b"dev_vector",
            device_name: b"Vector phone",
            challenge: b"vector-challenge",
            key_package: &[0x33; 64],
            transfer_public_key: &[0x44; 32],
            transcript_hash: &[0x55; 32],
            claim_tag: &[0x66; 32],
            claim_token_hash: &[0x77; 32],
            device_secret_hash: &[0x88; 32],
            initial_session_token_hash: &[0x99; 32],
        }
    }

    #[test]
    fn signed_proof_encoding_matches_shared_server_vector() {
        let bytes = proof().message(&[0x22; 32]).unwrap();
        assert_eq!(bytes.len(), 481);
        assert_eq!(
            hex(&Sha256::digest(bytes)),
            "70e1a994b2e4e2878cdab80c38c26012177780bd93b2cacaf73c1699389d6f78"
        );
        for name in [b"".as_slice(), b" outer", b"outer ", &[0xff], &[b'x'; 65]] {
            let mut invalid = proof();
            invalid.device_name = name;
            assert!(invalid.message(&[0x22; 32]).is_err());
        }
    }

    #[test]
    fn signing_is_identity_bound_and_domain_separated() {
        let device = MlsDevice::new(b"acct_vector", b"dev_vector").unwrap();
        let signature = device.sign_link_v3_enrollment(&proof()).unwrap();
        let message = proof().message(device.signing_public_key()).unwrap();
        device
            .provider
            .crypto()
            .verify_signature(
                SignatureScheme::ED25519,
                &message,
                device.signing_public_key(),
                &signature,
            )
            .unwrap();
        for field in 0..16 {
            let mut changed = proof();
            match field {
                0 => changed.origin = b"https://other.test",
                1 => {
                    changed.locator =
                        b"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                }
                2 => changed.reservation_request_id = &[1; 32],
                3 => changed.link_id = b"other",
                4 => changed.account_id = b"other",
                5 => changed.device_id = b"other",
                6 => changed.device_name = b"Different phone",
                7 => changed.challenge = b"different",
                8 => changed.key_package = &[2; 64],
                9 => changed.transfer_public_key = &[3; 32],
                10 => changed.transcript_hash = &[4; 32],
                11 => changed.claim_tag = &[5; 32],
                12 => changed.claim_token_hash = &[6; 32],
                13 => changed.device_secret_hash = &[7; 32],
                14 => changed.initial_session_token_hash = &[8; 32],
                _ => {}
            }
            let mut changed_message = changed.message(device.signing_public_key()).unwrap();
            if field == 15 {
                changed_message[0] ^= 1;
            }
            assert!(device
                .provider
                .crypto()
                .verify_signature(
                    SignatureScheme::ED25519,
                    &changed_message,
                    device.signing_public_key(),
                    &signature
                )
                .is_err());
        }
        let mut wrong_identity = proof();
        wrong_identity.device_id = b"other";
        assert!(device.sign_link_v3_enrollment(&wrong_identity).is_err());
    }
}
