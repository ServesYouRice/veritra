use super::{
    encode_device_identity,
    storage::{PartitionedStorage, VeritraProvider},
    transfer, MlsDevice, MlsError, CIPHERSUITE,
};
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use openmls::prelude::{BasicCredential, CredentialWithKey};
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::{random::OpenMlsRand, OpenMlsProvider};
use std::collections::HashMap;
use tls_codec::SecretVLBytes;

const MAGIC: &[u8; 8] = b"PMMLSST1";
// V2 provider-only state remains readable. V3 adds typed durable transfer
// records. V1 (OpenMLS 0.8.1) and unknown future formats still fail closed.
const FORMAT_VERSION: u16 = 3;
const LEGACY_FORMAT_VERSION: u16 = 2;
const PLAINTEXT_MAGIC: &[u8; 8] = b"PMMLSPL3";
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
        // The union of every owner's store: format 3 is the flat map.
        let records: SecretVLBytes = self.provider.storage().with_records(encode_records)?.into();
        let transfers = transfer::encode(
            &self.pending_transfers,
            &self.account_id,
            &self.device_id,
            self.signer.public(),
            &self.provider,
        )?;
        let plaintext_size = PLAINTEXT_MAGIC
            .len()
            .checked_add(4)
            .and_then(|len| len.checked_add(records.as_slice().len()))
            .and_then(|len| len.checked_add(transfers.as_slice().len()))
            .ok_or(MlsError::InvalidState)?;
        if plaintext_size > MAX_STATE_BYTES {
            return Err(MlsError::InvalidState);
        }
        // Reserve once: growing a Vec after copying secrets would leave an
        // old allocation outside the zero-on-drop wrapper's final buffer.
        let mut plaintext = SecretVLBytes::new(Vec::with_capacity(plaintext_size));
        for byte in PLAINTEXT_MAGIC
            .iter()
            .chain((records.as_slice().len() as u32).to_be_bytes().iter())
            .chain(records.as_slice())
            .chain(transfers.as_slice())
        {
            plaintext.push(*byte);
        }
        if plaintext.as_slice().len() > MAX_STATE_BYTES {
            return Err(MlsError::InvalidState);
        }
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
        let nonce = Nonce::try_from(nonce.as_slice()).map_err(|_| MlsError::InvalidState)?;
        let ciphertext = cipher
            .encrypt(
                &nonce,
                Payload {
                    msg: plaintext.as_slice(),
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
    /// indistinguishable from corrupt state. The one exception is a sealed
    /// blob with the right magic and a format version this build does not
    /// read, reported as [`MlsError::UnsupportedFormat`] (still refused).
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
        let version = reader.u16()?;
        if version != FORMAT_VERSION && version != LEGACY_FORMAT_VERSION {
            // Unauthenticated, like the rest of the header at this point: a
            // hint that sends the app to re-linking, never a weaker check.
            return Err(MlsError::UnsupportedFormat);
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
        let nonce = Nonce::try_from(nonce.as_slice()).map_err(|_| MlsError::InvalidState)?;
        let plaintext: SecretVLBytes = cipher
            .decrypt(
                &nonce,
                Payload {
                    msg: ciphertext,
                    aad: &sealed[..aad_end],
                },
            )
            .map_err(|_| MlsError::InvalidState)?
            .into();
        // Every restore splits the flat map by owner (D70 S1), so the
        // classifier runs on real state before any format depends on it.
        let (records, transfers) = if version == LEGACY_FORMAT_VERSION {
            (decode_records(plaintext.as_slice())?, None)
        } else {
            let mut payload = Reader::new(plaintext.as_slice());
            if payload.take(PLAINTEXT_MAGIC.len())? != PLAINTEXT_MAGIC {
                return Err(MlsError::InvalidState);
            }
            let record_bytes = payload.u32()? as usize;
            if record_bytes > MAX_STATE_BYTES {
                return Err(MlsError::InvalidState);
            }
            let records = decode_records(payload.take(record_bytes)?)?;
            (records, Some(&plaintext.as_slice()[payload.offset..]))
        };
        let provider = VeritraProvider::with_storage(PartitionedStorage::from_records(records)?);
        let pending_transfers = match transfers {
            Some(bytes) => transfer::decode(bytes, account_id, device_id, &public_key, &provider)?,
            None => Default::default(),
        };
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
                pending_transfers,
            },
            counter,
        ))
    }
}

/// `records` must be sorted by key and unique (`with_records` ensures it).
fn encode_records(records: &[(&[u8], &[u8])]) -> Result<Vec<u8>, MlsError> {
    if records.len() > MAX_RECORDS {
        return Err(MlsError::InvalidState);
    }
    let mut output_size = 4usize;
    for (key, value) in records {
        if key.len() > MAX_RECORD_BYTES || value.len() > MAX_RECORD_BYTES {
            return Err(MlsError::InvalidState);
        }
        output_size = output_size
            .checked_add(8)
            .and_then(|len| len.checked_add(key.len()))
            .and_then(|len| len.checked_add(value.len()))
            .ok_or(MlsError::InvalidState)?;
        if output_size > MAX_STATE_BYTES {
            return Err(MlsError::InvalidState);
        }
    }
    let mut output = Vec::with_capacity(output_size);
    output.extend_from_slice(&(records.len() as u32).to_be_bytes());
    for (key, value) in records {
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
    fn genuine_v2_fixture_upgrades_without_losing_signer_or_live_group() {
        let sealed = include_bytes!("../../tests/fixtures/state-v2/source.bin");
        assert_eq!(&sealed[8..10], &2u16.to_be_bytes());
        let (source, count) =
            MlsDevice::restore_state(b"acct_fixture", b"dev_old", &[0x71; 32], 41, sealed).unwrap();
        assert_eq!(count, 41);
        assert_eq!(
            source.signing_public_key(),
            include_bytes!("../../tests/fixtures/state-v2/source-public.bin")
        );
        assert!(source.pending_transfers.is_empty());
        let mut group = source.load_group(b"conv_fixture").unwrap();
        assert_eq!(
            source
                .decrypt(
                    &mut group,
                    include_bytes!("../../tests/fixtures/state-v2/peer-next.bin"),
                    b"acct_peer",
                    b"dev_peer"
                )
                .unwrap(),
            b"synthetic-after-upgrade"
        );
        let upgraded = source.seal_state(&[0x71; 32], 42).unwrap();
        assert_eq!(&upgraded[8..10], &3u16.to_be_bytes());
        let (source, count) =
            MlsDevice::restore_state(b"acct_fixture", b"dev_old", &[0x71; 32], 42, &upgraded)
                .unwrap();
        assert_eq!(count, 42);
        assert_eq!(
            source.signing_public_key(),
            include_bytes!("../../tests/fixtures/state-v2/source-public.bin")
        );
        let mut group = source.load_group(b"conv_fixture").unwrap();
        let (peer, _) = MlsDevice::restore_state(
            b"acct_peer",
            b"dev_peer",
            &[0x72; 32],
            42,
            include_bytes!("../../tests/fixtures/state-v2/peer.bin"),
        )
        .unwrap();
        let mut peer_group = peer.load_group(b"conv_fixture").unwrap();
        let message = source
            .encrypt(&mut group, b"synthetic-upgraded-source")
            .unwrap();
        assert_eq!(
            peer.decrypt(&mut peer_group, &message, b"acct_fixture", b"dev_old")
                .unwrap(),
            b"synthetic-upgraded-source"
        );
        let reply = peer
            .encrypt(&mut peer_group, b"synthetic-peer-reply")
            .unwrap();
        assert_eq!(
            source
                .decrypt(&mut group, &reply, b"acct_peer", b"dev_peer")
                .unwrap(),
            b"synthetic-peer-reply"
        );
        assert!(matches!(
            MlsDevice::restore_state(b"acct_fixture", b"dev_old", &[0x71; 32], 43, &upgraded),
            Err(MlsError::Rollback)
        ));
    }

    /// The authenticated plaintext of a sealed format-2/3 blob.
    fn open_plaintext(sealed: &[u8], key: &[u8]) -> Vec<u8> {
        let mut reader = Reader::new(sealed);
        reader.take(8).unwrap();
        reader.u16().unwrap();
        reader.u64().unwrap();
        for _ in 0..3 {
            reader.u16_bytes().unwrap();
        }
        let nonce = reader.take(NONCE_BYTES).unwrap().to_vec();
        let aad_end = reader.offset;
        let length = reader.u32().unwrap() as usize;
        let ciphertext = reader.take(length).unwrap();
        Aes256Gcm::new_from_slice(key)
            .unwrap()
            .decrypt(
                &Nonce::try_from(nonce.as_slice()).unwrap(),
                Payload {
                    msg: ciphertext,
                    aad: &sealed[..aad_end],
                },
            )
            .unwrap()
    }

    /// D70 S1: the genuine v3 fixture (sealed before the storage split)
    /// splits by owner, re-seals to the same plaintext byte for byte, and
    /// every part of it still works: the staged commit merges, the peer
    /// interoperates, the inactive group stays inactive, the unclaimed key
    /// packages open a Welcome and the K2 transfers survive.
    #[test]
    fn genuine_v3_fixture_splits_by_owner_and_reseals_byte_identically() {
        use super::super::storage::hex;
        use openmls::prelude::{KeyPackageIn, ProtocolVersion};
        use tls_codec::Deserialize as _;
        const SOURCE_KEY: [u8; 32] = [0x73; 32];
        let sealed = include_bytes!("../../tests/fixtures/state-v3/source.bin");
        assert_eq!(&sealed[8..10], &3u16.to_be_bytes());
        let original = open_plaintext(sealed, &SOURCE_KEY);
        let (source, counter) =
            MlsDevice::restore_state(b"acct_fixture3", b"dev_src", &SOURCE_KEY, 51, sealed)
                .unwrap();
        assert_eq!(counter, 51);
        assert_eq!(
            source.signing_public_key(),
            include_bytes!("../../tests/fixtures/state-v3/source-public.bin")
        );
        assert_eq!(source.pending_transfers.len(), 2);

        let unclaimed = [
            &include_bytes!("../../tests/fixtures/state-v3/unclaimed-1.bin")[..],
            include_bytes!("../../tests/fixtures/state-v3/unclaimed-2.bin"),
        ];
        let package_owner = |bytes: &[u8]| {
            let package = KeyPackageIn::tls_deserialize_exact(bytes)
                .unwrap()
                .validate(source.provider.crypto(), ProtocolVersion::Mls10)
                .unwrap();
            let id = package.hash_ref(source.provider.crypto()).unwrap();
            format!("kp:{}", hex(id.as_slice()))
        };
        let snapshot = source.provider.storage().snapshot();
        let mut expected: Vec<String> = [
            "device",
            "group:conv_alpha",
            "group:conv_beta",
            "group:conv_gamma",
        ]
        .map(str::to_owned)
        .to_vec();
        expected.extend(unclaimed.iter().map(|bytes| package_owner(bytes)));
        expected.sort();
        assert_eq!(snapshot.keys().cloned().collect::<Vec<_>>(), expected);
        assert_eq!(snapshot["device"].len(), 1);
        assert_eq!(source.provider.storage().unowned_count(), 0);

        // Restore -> classify -> re-seal reproduces the exact plaintext.
        let resealed = source.seal_state(&SOURCE_KEY, 51).unwrap();
        assert_ne!(&resealed[..], &sealed[..]);
        assert_eq!(open_plaintext(&resealed, &SOURCE_KEY), original);
        let (again, _) =
            MlsDevice::restore_state(b"acct_fixture3", b"dev_src", &SOURCE_KEY, 51, &resealed)
                .unwrap();
        assert_eq!(again.provider.storage().snapshot(), snapshot);
        drop(again);

        // The staged self-update merges and the peer follows it.
        let (peer, _) = MlsDevice::restore_state(
            b"acct_peer3",
            b"dev_peer",
            &[0x74; 32],
            52,
            include_bytes!("../../tests/fixtures/state-v3/peer.bin"),
        )
        .unwrap();
        let mut alpha = source.load_group(b"conv_alpha").unwrap();
        assert!(source.has_pending_commit(&alpha));
        let epoch = source.group_epoch(&alpha);
        source.merge_pending_commit(&mut alpha).unwrap();
        let mut peer_alpha = peer.load_group(b"conv_alpha").unwrap();
        peer.process_commit(
            &mut peer_alpha,
            include_bytes!("../../tests/fixtures/state-v3/staged-update.bin"),
        )
        .unwrap();
        assert_eq!(peer.group_epoch(&peer_alpha), epoch + 1);
        let message = source.encrypt(&mut alpha, b"synthetic-alpha-3").unwrap();
        assert_eq!(
            peer.decrypt(&mut peer_alpha, &message, b"acct_fixture3", b"dev_src")
                .unwrap(),
            b"synthetic-alpha-3"
        );
        let reply = peer.encrypt(&mut peer_alpha, b"synthetic-alpha-4").unwrap();
        assert_eq!(
            source
                .decrypt(&mut alpha, &reply, b"acct_peer3", b"dev_peer")
                .unwrap(),
            b"synthetic-alpha-4"
        );

        // The peer's continuation in conv_beta decrypts.
        let mut beta = source.load_group(b"conv_beta").unwrap();
        assert_eq!(
            source
                .decrypt(
                    &mut beta,
                    include_bytes!("../../tests/fixtures/state-v3/peer-next.bin"),
                    b"acct_peer3",
                    b"dev_peer"
                )
                .unwrap(),
            b"synthetic-beta-after-upgrade"
        );

        // The inactive group is kept as it was (S1 prunes nothing).
        assert!(!source.load_group(b"conv_gamma").unwrap().is_active());

        // An unclaimed key package still opens a Welcome; its store goes.
        let mut fresh = peer.create_group(b"conv_delta").unwrap();
        let add = peer
            .add_member(&mut fresh, unclaimed[0], b"acct_fixture3", b"dev_src")
            .unwrap();
        peer.merge_pending_commit(&mut fresh).unwrap();
        source.join_group(b"conv_delta", &add.welcome).unwrap();
        let owners = source.provider.storage().snapshot();
        assert!(!owners.contains_key(&package_owner(unclaimed[0])));
        assert!(owners.contains_key(&package_owner(unclaimed[1])));
        assert!(owners.contains_key("group:conv_delta"));
    }

    #[test]
    fn genuine_v2_fixture_splits_by_owner_and_reseals_its_records_unchanged() {
        let sealed = include_bytes!("../../tests/fixtures/state-v2/source.bin");
        let original = open_plaintext(sealed, &[0x71; 32]);
        let (source, _) =
            MlsDevice::restore_state(b"acct_fixture", b"dev_old", &[0x71; 32], 41, sealed).unwrap();
        assert_eq!(
            source
                .provider
                .storage()
                .snapshot()
                .into_keys()
                .collect::<Vec<_>>(),
            ["device", "group:conv_fixture"]
        );
        // v2 plaintext is the bare record map (its writer did not sort it);
        // v3 wraps the same records, sorted, and an empty transfer list.
        let resealed = open_plaintext(&source.seal_state(&[0x71; 32], 41).unwrap(), &[0x71; 32]);
        let mut reader = Reader::new(&resealed);
        assert_eq!(reader.take(8).unwrap(), PLAINTEXT_MAGIC);
        let length = reader.u32().unwrap() as usize;
        let records = reader.take(length).unwrap();
        assert_eq!(records.len(), original.len());
        assert!(decode_records(records).unwrap() == decode_records(&original).unwrap());
        assert_eq!(reader.take(2).unwrap(), [0, 0]);
        assert!(reader.finished());
    }

    #[test]
    fn authenticated_v3_wrapper_must_be_exact_and_keep_provider_record_checks() {
        let device = MlsDevice::new(b"acct_wrapper", b"dev_wrapper").unwrap();
        let sealed = device.seal_state(&KEY, 3).unwrap();
        let mut reader = Reader::new(&sealed);
        reader.take(8).unwrap();
        reader.u16().unwrap();
        reader.u64().unwrap();
        reader.u16_bytes().unwrap();
        reader.u16_bytes().unwrap();
        reader.u16_bytes().unwrap();
        let nonce = reader.take(12).unwrap().to_vec();
        let aad_end = reader.offset;
        let length = reader.u32().unwrap() as usize;
        let ciphertext = reader.take(length).unwrap();
        let cipher = Aes256Gcm::new_from_slice(&KEY).unwrap();
        let nonce = Nonce::try_from(nonce.as_slice()).unwrap();
        let original = cipher
            .decrypt(
                &nonce,
                Payload {
                    msg: ciphertext,
                    aad: &sealed[..aad_end],
                },
            )
            .unwrap();
        for change in 0..4 {
            let mut payload = original.clone();
            match change {
                0 => payload[0] ^= 1,
                1 => payload[8..12].copy_from_slice(&u32::MAX.to_be_bytes()),
                2 => payload.push(0),
                _ => {
                    let duplicate = [
                        0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, b'k', 1, 0, 0, 0, 1, 0, 0, 0, 1, b'k',
                        2,
                    ];
                    payload = PLAINTEXT_MAGIC.to_vec();
                    payload.extend_from_slice(&(duplicate.len() as u32).to_be_bytes());
                    payload.extend_from_slice(&duplicate);
                    payload.extend_from_slice(&0u16.to_be_bytes());
                }
            }
            let encrypted = cipher
                .encrypt(
                    &nonce,
                    Payload {
                        msg: &payload,
                        aad: &sealed[..aad_end],
                    },
                )
                .unwrap();
            let mut malformed = sealed[..aad_end].to_vec();
            malformed.extend_from_slice(&(encrypted.len() as u32).to_be_bytes());
            malformed.extend_from_slice(&encrypted);
            assert!(matches!(
                MlsDevice::restore_state(b"acct_wrapper", b"dev_wrapper", &KEY, 3, &malformed),
                Err(MlsError::InvalidState)
            ));
        }
    }

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

    #[test]
    fn older_format_version_fails_closed() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let sealed = alice.seal_state(&KEY, 3).unwrap();
        let version = MAGIC.len();
        // Format 1 (OpenMLS 0.8.1) and an unknown newer format are refused
        // with their own error, so the app can offer a re-link, not a
        // "corrupt or attacked" message.
        for unsupported in [0u16, 1, 4, u16::MAX] {
            let mut blob = sealed.clone();
            blob[version..version + 2].copy_from_slice(&unsupported.to_be_bytes());
            assert!(matches!(
                MlsDevice::restore_state(b"acct_alice", b"dev_alice", &KEY, 3, &blob),
                Err(MlsError::UnsupportedFormat)
            ));
        }
        // Everything else stays indistinguishable from corruption.
        let mut magic = sealed.clone();
        magic[0] ^= 1;
        let mut tampered = sealed.clone();
        *tampered.last_mut().unwrap() ^= 1;
        let mut trailing = sealed.clone();
        trailing.push(0);
        for blob in [
            &magic,
            &tampered,
            &trailing,
            &sealed[..version + 1].to_vec(),
        ] {
            assert!(matches!(
                MlsDevice::restore_state(b"acct_alice", b"dev_alice", &KEY, 3, blob),
                Err(MlsError::InvalidState)
            ));
        }
        assert!(matches!(
            MlsDevice::restore_state(b"acct_alice", b"dev_alice", &[8; 32], 3, &sealed),
            Err(MlsError::InvalidState)
        ));
        assert!(matches!(
            MlsDevice::restore_state(b"acct_mallory", b"dev_alice", &KEY, 3, &sealed),
            Err(MlsError::InvalidState)
        ));
    }

    #[test]
    fn skipped_epoch_fails_without_advancing_group_state() {
        let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
        let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
        let mut alice_group = alice.create_group(b"conv_epoch_gap").unwrap();
        let add = alice
            .add_member(
                &mut alice_group,
                &bob.create_key_package().unwrap(),
                b"acct_bob",
                b"dev_bob",
            )
            .unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let mut bob_group = bob.join_group(b"conv_epoch_gap", &add.welcome).unwrap();

        let first = alice.self_update(&mut alice_group).unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        let second = alice.self_update(&mut alice_group).unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();

        assert_eq!(
            bob.process_commit(&mut bob_group, &second),
            Err(MlsError::InvalidMessage)
        );
        bob.process_commit(&mut bob_group, &first).unwrap();
        bob.process_commit(&mut bob_group, &second).unwrap();
    }
}
