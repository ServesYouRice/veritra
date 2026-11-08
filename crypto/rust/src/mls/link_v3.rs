//! Device-link protocol bytes for the K2 route (`veritra-device-link-v4`,
//! L1-3, docs/designs/L1-3-link-commitment.md).
//!
//! The existing (source) device commits to a fresh 32-byte random before the
//! new device exists; the new device puts its own fresh random in the claim;
//! the source reveals its random only after it has accepted that claim. The
//! SAS is a MAC over the claim transcript and the revealed random, so neither
//! side, nor a relay that knows the link secret, can choose it: a relay gets
//! one guess of about 10^-8 per run instead of a search.

use super::{append_transcript_field, DeviceLinkVerification, MlsDevice, MlsError};
use openmls_traits::{
    crypto::OpenMlsCrypto, random::OpenMlsRand, signatures::Signer, types::HashType,
    OpenMlsProvider,
};
use sha2::{Digest, Sha256};
use tls_codec::SecretVLBytes;

pub(crate) const VERSION: &[u8] = b"veritra-device-link-v4";
const COMMITMENT_DOMAIN: &[u8] = b"veritra-device-link-commitment";

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
    /// The source's commitment to its random, made before the link existed.
    pub source_commitment: [u8; 32],
    /// The new device's fresh random, sent in its claim.
    pub recipient_random: [u8; 32],
}

fn valid_origin(origin: &[u8]) -> bool {
    !origin.is_empty() && origin.len() <= 2048 && origin.is_ascii()
}

fn valid_id(id: &[u8]) -> bool {
    !id.is_empty() && id.len() <= 128
}

impl LinkContext {
    pub(crate) fn validate(&self) -> Result<(), MlsError> {
        if !valid_origin(&self.origin)
            || !valid_id(&self.link_id)
            || !valid_id(&self.account_id)
            || !valid_id(&self.source_device_id)
            || !valid_id(&self.recipient_device_id)
            || self.source_device_id == self.recipient_device_id
            || self.source_signing_key == self.recipient_signing_key
            || self.source_commitment == [0; 32]
            || self.recipient_random == [0; 32]
        {
            return Err(MlsError::InvalidIdentity);
        }
        Ok(())
    }

    /// The claim transcript: everything both devices know when the new
    /// device claims. The claim and approval tags cover it; the SAS covers it
    /// and the revealed source random.
    pub(crate) fn transcript(&self) -> Result<Vec<u8>, MlsError> {
        self.validate()?;
        let mut bytes = Vec::with_capacity(576);
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
            self.source_commitment.as_slice(),
            self.recipient_random.as_slice(),
        ] {
            append_transcript_field(&mut bytes, field)?;
        }
        Ok(bytes)
    }

    pub(crate) fn transcript_hash(&self) -> Result<[u8; 32], MlsError> {
        Ok(Sha256::digest(self.transcript()?).into())
    }

    /// Opens [`Self::source_commitment`] with `source_random` and returns
    /// the 8-digit SAS and its four MAC bytes. A random that does not open
    /// the commitment is refused before any SAS exists.
    pub(crate) fn reveal(
        &self,
        provider: &impl OpenMlsProvider,
        sas_key: &[u8],
        source_random: &[u8; 32],
    ) -> Result<(String, [u8; 4]), MlsError> {
        let opened = source_commitment(
            &self.origin,
            &self.account_id,
            &self.source_device_id,
            &self.source_signing_key,
            source_random,
        )?;
        if sas_key.len() != 32 || !equal_tag(&opened, &self.source_commitment) {
            return Err(MlsError::InvalidIdentity);
        }
        let mut input = self.transcript()?;
        append_transcript_field(&mut input, source_random)?;
        let mac = provider
            .crypto()
            .hmac(HashType::Sha2_256, sas_key, &input)
            .map_err(|_| MlsError::KeyGeneration)?;
        let bytes: [u8; 4] = mac.as_slice()[..4]
            .try_into()
            .map_err(|_| MlsError::InvalidState)?;
        Ok((sas_digits(&bytes), bytes))
    }
}

/// The SAS: four MAC bytes as a big-endian integer modulo 10^8, padded to
/// eight digits (about 26.6 bits; the modulo bias is about 2^-5 relative
/// and negligible next to the 10^-8 guess).
pub(crate) fn sas_digits(bytes: &[u8; 4]) -> String {
    format!("{:08}", u32::from_be_bytes(*bytes) % 100_000_000)
}

/// SHA-256 over length-prefixed `domain, version, origin, account, source
/// device, source signing key, source random`. The link ID is not known yet
/// when the source commits; the transcript binds it.
pub(crate) fn source_commitment(
    origin: &[u8],
    account_id: &[u8],
    source_device_id: &[u8],
    source_signing_key: &[u8; 32],
    source_random: &[u8; 32],
) -> Result<[u8; 32], MlsError> {
    if !valid_origin(origin)
        || !valid_id(account_id)
        || !valid_id(source_device_id)
        || source_random == &[0; 32]
    {
        return Err(MlsError::InvalidIdentity);
    }
    let mut bytes = Vec::with_capacity(2048 + 384);
    for field in [
        COMMITMENT_DOMAIN,
        VERSION,
        origin,
        account_id,
        source_device_id,
        source_signing_key.as_slice(),
        source_random.as_slice(),
    ] {
        append_transcript_field(&mut bytes, field)?;
    }
    Ok(Sha256::digest(bytes).into())
}

/// A fresh nonzero 32-byte random from the provider's RNG.
pub(crate) fn fresh_random(provider: &impl OpenMlsProvider) -> Result<[u8; 32], MlsError> {
    let bytes: [u8; 32] = provider
        .rand()
        .random_vec(32)
        .map_err(|_| MlsError::KeyGeneration)?
        .try_into()
        .map_err(|_| MlsError::KeyGeneration)?;
    if bytes == [0; 32] {
        return Err(MlsError::KeyGeneration);
    }
    Ok(bytes)
}

pub(crate) struct Verification {
    /// Transcript hash, claim tag and approval tag; `sas` and `sas_bytes`
    /// are empty (the SAS needs the revealed source random).
    pub public: DeviceLinkVerification,
    pub link_key: SecretVLBytes,
    /// Keys the SAS MAC. The new device keeps it in its record because it
    /// wipes the link secret after the claim, before the reveal.
    pub sas_key: SecretVLBytes,
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
    Ok(Verification {
        public: DeviceLinkVerification {
            transcript_hash: Sha256::digest(&transcript).to_vec(),
            sas: String::new(),
            claim_tag: mac(b"veritra-link-claim-v4")?.as_slice().to_vec(),
            approval_tag: mac(b"veritra-link-approval-v4")?.as_slice().to_vec(),
            sas_bytes: Vec::new(),
        },
        link_key: expand(b"veritra-link-handoff-v4")?,
        sas_key: expand(b"veritra-link-sas-v4")?,
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

    const SOURCE_RANDOM: [u8; 32] = [0x66; 32];
    const VECTOR: &str = include_str!("../../../../testing/vectors/device-link-v4.json");

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
            source_commitment: source_commitment(
                b"https://example.test",
                b"acct_01",
                b"dev_old",
                &[0x22; 32],
                &SOURCE_RANDOM,
            )
            .unwrap(),
            recipient_random: [0x77; 32],
        }
    }
    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }
    fn sas_of(context: &LinkContext, secret: &[u8], random: &[u8; 32]) -> Result<String, MlsError> {
        let provider = OpenMlsRustCrypto::default();
        let derived = derive(&provider, context, secret)?;
        context
            .reveal(&provider, derived.sas_key.as_slice(), random)
            .map(|(sas, _)| sas)
    }

    #[test]
    fn v4_matches_independent_python_vector() {
        let root: serde_json::Value = serde_json::from_str(VECTOR).unwrap();
        let text = |key: &str| root[key].as_str().unwrap().to_owned();
        assert_eq!(text("protocol_version").as_bytes(), VERSION);
        let input = &root["inputs"];
        let expected = context();
        assert_eq!(
            input["origin"].as_str().unwrap().as_bytes(),
            expected.origin
        );
        assert_eq!(input["source_random"], hex(&SOURCE_RANDOM).as_str());
        assert_eq!(
            input["recipient_random"],
            hex(&expected.recipient_random).as_str()
        );
        let provider = OpenMlsRustCrypto::default();
        let result = derive(&provider, &expected, &[0x55; 16]).unwrap();
        assert_eq!(hex(&expected.source_commitment), text("source_commitment"));
        assert_eq!(hex(&result.public.transcript_hash), text("transcript_hash"));
        assert_eq!(hex(&result.public.claim_tag), text("claim_tag"));
        assert_eq!(hex(&result.public.approval_tag), text("approval_tag"));
        assert_eq!(hex(result.link_key.as_slice()), text("link_key"));
        assert!(result.public.sas.is_empty() && result.public.sas_bytes.is_empty());
        let (sas, bytes) = expected
            .reveal(&provider, result.sas_key.as_slice(), &SOURCE_RANDOM)
            .unwrap();
        assert_eq!(hex(&bytes), text("sas_bytes"));
        assert_eq!(sas, text("sas"));
    }

    #[test]
    fn v4_binds_all_fields_and_does_not_accept_clone_identity() {
        let provider = OpenMlsRustCrypto::default();
        let original = derive(&provider, &context(), &[0x55; 16]).unwrap();
        let original_sas = sas_of(&context(), &[0x55; 16], &SOURCE_RANDOM).unwrap();
        for field in 0..12 {
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
                9 => changed.source_commitment[0] ^= 1,
                10 => changed.recipient_random[0] ^= 1,
                _ => {}
            }
            let secret = if field == 11 { [0x56; 16] } else { [0x55; 16] };
            let actual = derive(&provider, &changed, &secret).unwrap();
            assert_ne!(original.public.claim_tag, actual.public.claim_tag);
            assert_ne!(original.public.approval_tag, actual.public.approval_tag);
            // A changed origin, account or source identity or commitment no
            // longer opens with the source random; every other change opens
            // and gives another SAS.
            match sas_of(&changed, &secret, &SOURCE_RANDOM) {
                Ok(sas) => {
                    assert!([1, 3, 6, 7, 8, 10, 11].contains(&field), "{field}");
                    assert_ne!(sas, original_sas, "{field}");
                }
                Err(error) => {
                    assert!([0, 2, 4, 5, 9].contains(&field), "{field}");
                    assert_eq!(error, MlsError::InvalidIdentity);
                }
            }
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
        // The placeholder zero values never stand for a commitment or random.
        cloned = context();
        cloned.source_commitment = [0; 32];
        assert!(derive(&provider, &cloned, &[0x55; 16]).is_err());
        cloned = context();
        cloned.recipient_random = [0; 32];
        assert!(derive(&provider, &cloned, &[0x55; 16]).is_err());
        assert!(
            source_commitment(b"https://example.test", b"a", b"d", &[1; 32], &[0; 32]).is_err()
        );
        assert!(sas_of(&context(), &[0x55; 16], &[0; 32]).is_err());
    }

    #[test]
    fn a_random_substituted_after_the_commitment_fails_before_any_sas() {
        // VAL-004 / VAL-066: the only random that opens the commitment is the
        // one the source committed to; anything else yields no SAS at all.
        let provider = OpenMlsRustCrypto::default();
        let derived = derive(&provider, &context(), &[0x55; 16]).unwrap();
        let mut random = SOURCE_RANDOM;
        for byte in 0..32 {
            random[byte] ^= 1;
            assert_eq!(
                context().reveal(&provider, derived.sas_key.as_slice(), &random),
                Err(MlsError::InvalidIdentity)
            );
            random[byte] ^= 1;
        }
        assert!(context()
            .reveal(&provider, derived.sas_key.as_slice(), &SOURCE_RANDOM)
            .is_ok());
    }

    #[test]
    fn a_relay_holding_the_secret_has_nothing_to_grind() {
        // The audit's attack (TASK-010/TASK-048), with the QR secret leaked.
        // Before v4 the relay ground the nonce it relays until the source's
        // SAS matched the new device's: about 3,600 HMAC tries matched four of
        // eight digits. In v4 both SAS values depend on a random the relay
        // must fix before the other one is known.
        let secret = [0x55; 16];
        let provider = OpenMlsRustCrypto::default();
        // Towards the source the relay claims with its own key and random.
        // Until the source reveals, the relay only has the commitment: no
        // guessed random opens it, so it has no SAS to compare against.
        let mut towards_source = context();
        towards_source.recipient_signing_key = [0x99; 32];
        let sas_key = derive(&provider, &towards_source, &secret).unwrap().sas_key;
        for guess in 1u32..=5000 {
            let mut random = [0u8; 32];
            random[..4].copy_from_slice(&guess.to_be_bytes());
            assert!(towards_source
                .reveal(&provider, sas_key.as_slice(), &random)
                .is_err());
        }
        // The source reveals only after it accepted that claim (transfer.rs
        // refuses a second one), so the relay learns the target SAS too late
        // to change anything it sent the source.
        let target = sas_of(&towards_source, &secret, &SOURCE_RANDOM).unwrap();
        // Towards the new device the relay posed as the source with its own
        // commitment, given before the new device chose its random. One
        // opening exists; the new device's fresh random then sets the SAS.
        let relay_random = [0xab; 32];
        let mut towards_new = context();
        towards_new.source_signing_key = [0x98; 32];
        towards_new.source_commitment = source_commitment(
            &towards_new.origin,
            &towards_new.account_id,
            &towards_new.source_device_id,
            &towards_new.source_signing_key,
            &relay_random,
        )
        .unwrap();
        let mut matches = 0;
        let runs = 2000u32;
        for run in 1..=runs {
            towards_new.recipient_random = [0x01; 32];
            towards_new.recipient_random[..4].copy_from_slice(&run.to_be_bytes());
            if sas_of(&towards_new, &secret, &relay_random).unwrap() == target {
                matches += 1;
            }
            // The relay cannot open its commitment with a second random.
            let mut other = relay_random;
            other[0] ^= 0x80;
            assert!(sas_of(&towards_new, &secret, &other).is_err());
        }
        // Each run is a fresh 10^-8 chance; 2000 runs give no match.
        assert_eq!(matches, 0);
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
