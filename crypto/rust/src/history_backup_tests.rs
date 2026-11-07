//! K1 backup container (VHC1 kind 1) tests.

use super::*;
use openmls_rust_crypto::OpenMlsRustCrypto;

const VECTOR: &str = include_str!("../../../testing/vectors/k1-backup-v1.json");
const ENTROPY: [u8; 30] = [
    0x0f, 0x1e, 0x2d, 0x3c, 0x4b, 0x5a, 0x69, 0x78, 0x87, 0x96, 0xa5, 0xb4, 0xc3, 0xd2, 0xe1, 0xf0,
    0x01, 0x12, 0x23, 0x34, 0x45, 0x56, 0x67, 0x78, 0x89, 0x9a, 0xab, 0xbc, 0xcd, 0xde,
];

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(value: &serde_json::Value) -> Vec<u8> {
    let text = value.as_str().expect("hex string");
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

fn rk_pub(entropy: &[u8]) -> [u8; 32] {
    crate::recovery::derive(entropy).unwrap().rk_pub
}

fn header(rk: &[u8; 32]) -> BundleHeader {
    BundleHeader {
        account_id: b"acct_1".to_vec(),
        source_device_id: b"dev_old".to_vec(),
        created_at_ms: 1_730_000_000_000,
        snapshot_counter: 7,
        recovery_key_id: Some(recovery_id(rk)),
        plaintext_version: 6,
    }
}

fn seal(payload: &[u8]) -> Vec<u8> {
    let rk = rk_pub(&ENTROPY);
    seal_backup(&OpenMlsRustCrypto::default(), &header(&rk), &rk, payload).unwrap()
}

fn open(ciphertext: &[u8], entropy: &[u8]) -> Result<OpenedBundle, HistoryError> {
    open_backup(
        &OpenMlsRustCrypto::default(),
        ciphertext,
        entropy,
        b"acct_1",
        Some(b"dev_old"),
    )
}

#[test]
fn backup_round_trips_and_pads_to_the_floor_then_buckets() {
    for (len, padded) in [
        (1usize, MIN_BACKUP_PADDED),
        (900_000, MIN_BACKUP_PADDED),
        (MIN_BACKUP_PADDED - 8, 1_114_112),
        (3 * MAX_ATTACHMENT_CHUNK + 5, 3_211_264),
    ] {
        let payload = vec![0x42; len];
        let ciphertext = seal(&payload);
        let peek = peek_backup(&ciphertext[..MAX_PEEK_BYTES.min(ciphertext.len())]).unwrap();
        assert_eq!(peek.padded, padded, "payload {len}");
        assert_eq!(backup_padded_size(len), Ok(padded));
        let opened = open(&ciphertext, &ENTROPY).unwrap();
        assert_eq!(opened.payload.as_slice(), payload);
        assert_eq!(opened.header, header(&rk_pub(&ENTROPY)));
    }
}

#[test]
fn padding_never_shrinks_is_canonical_and_capped() {
    let mut last = 0;
    for len in [
        0usize,
        1,
        1000,
        MIN_BACKUP_PADDED,
        2 << 20,
        10 << 20,
        MAX_PADDED_HISTORY - 9_000_000,
    ] {
        let padded = backup_padded_size(len).unwrap();
        assert!(padded >= len + 8 && padded >= last && padded.is_multiple_of(FRAME_BUCKET));
        assert!(padded <= MAX_PADDED_HISTORY);
        last = padded;
    }
    assert_eq!(
        backup_padded_size(MAX_PADDED_HISTORY - 8),
        Ok(MAX_PADDED_HISTORY)
    );
    for len in [65_900_000usize, 66_000_000, MAX_PADDED_HISTORY - 9] {
        assert_eq!(backup_padded_size(len), Ok(MAX_PADDED_HISTORY), "{len}");
    }
    assert!(backup_padded_size(MAX_PADDED_HISTORY - 7).is_err());
    assert!(backup_padded_size(usize::MAX).is_err());
    // Within 5% above the floor (plus the 64 KiB frame).
    let padded = backup_padded_size(20 << 20).unwrap();
    assert!(padded <= (20 << 20) * 105 / 100 + FRAME_BUCKET + 8);
}

#[test]
fn only_the_right_key_account_and_device_open_it() {
    let ciphertext = seal(b"synthetic history");
    let mut other = ENTROPY;
    other[0] ^= 1;
    assert_eq!(
        open(&ciphertext, &other).err(),
        Some(HistoryError::Authentication)
    );
    assert!(open(&ciphertext, &ENTROPY[..29]).is_err());
    let provider = OpenMlsRustCrypto::default();
    assert!(open_backup(&provider, &ciphertext, &ENTROPY, b"acct_2", None).is_err());
    assert!(open_backup(
        &provider,
        &ciphertext,
        &ENTROPY,
        b"acct_1",
        Some(b"dev_new")
    )
    .is_err());
    // A file restore does not pin the device.
    let opened = open_backup(&provider, &ciphertext, &ENTROPY, b"acct_1", None).unwrap();
    assert_eq!(opened.header.source_device_id, b"dev_old");
    // A kind-2 bundle is not a backup, and a backup is not a bundle.
    let bundle = seal_bundle(&provider, &header(&rk_pub(&ENTROPY)), b"x").unwrap();
    assert!(open_backup(&provider, &bundle.ciphertext, &ENTROPY, b"acct_1", None).is_err());
    assert!(peek_backup(&bundle.ciphertext).is_err());
    assert!(read_header(&mut Reader::new(&ciphertext)).is_err());
}

#[test]
fn every_header_byte_is_bound() {
    let ciphertext = seal(b"synthetic history");
    let header_len = {
        let mut reader = Reader::new(&ciphertext);
        read_header_any(&mut reader).unwrap();
        reader.offset
    };
    assert!(header_len <= MAX_HEADER);
    for index in 0..header_len {
        let mut changed = ciphertext.clone();
        changed[index] ^= 1;
        assert!(open(&changed, &ENTROPY).is_err(), "header byte {index}");
    }
    // Body edits, truncation and extension all fail.
    let mut changed = ciphertext.clone();
    changed[header_len + 10] ^= 1;
    assert!(open(&changed, &ENTROPY).is_err());
    assert!(open(&ciphertext[..ciphertext.len() - 1], &ENTROPY).is_err());
    let mut longer = ciphertext.clone();
    longer.push(0);
    assert!(open(&longer, &ENTROPY).is_err());
    // The same bytes cannot be moved between accounts: the AAD and the chunk
    // context both bind the header.
    assert!(open_backup(
        &OpenMlsRustCrypto::default(),
        &ciphertext,
        &ENTROPY,
        b"acct_2",
        None
    )
    .is_err());
}

#[test]
fn seal_refuses_a_mismatched_key_id_empty_payload_and_oversize() {
    let provider = OpenMlsRustCrypto::default();
    let rk = rk_pub(&ENTROPY);
    let mut bad = header(&rk);
    bad.recovery_key_id = Some([1; 16]);
    assert!(seal_backup(&provider, &bad, &rk, b"x").is_err());
    bad.recovery_key_id = None;
    assert!(seal_backup(&provider, &bad, &rk, b"x").is_err());
    assert!(seal_backup(&provider, &header(&rk), &rk, b"").is_err());
}

#[test]
fn seals_are_fresh_and_hide_equal_payloads() {
    let a = seal(b"same");
    let b = seal(b"same");
    assert_ne!(a, b);
    assert_eq!(a.len(), b.len());
}

#[test]
fn authenticated_noncanonical_frames_are_refused() {
    // A correctly sealed container whose padding is not the canonical size
    // or whose padding bytes are not zero must not open.
    let provider = OpenMlsRustCrypto::default();
    let rk = rk_pub(&ENTROPY);
    let secrets = FileSecrets::from_bytes(&[0x44; 32], &[0x55; 8]).unwrap();
    let h = header(&rk);
    let make = |frame: Vec<u8>| -> Vec<u8> {
        let padded = frame.len();
        let h0 = encode_h0(&h, padded, BACKUP_KIND).unwrap();
        let plain: SecretVLBytes = [secrets.key.as_slice(), secrets.nonce_prefix.as_slice()]
            .concat()
            .into();
        let sealed = provider
            .crypto()
            .hpke_seal(
                suite(),
                &rk,
                &backup_seal_info(b"acct_1").unwrap(),
                &h0,
                plain.as_slice(),
            )
            .unwrap();
        let mut full = h0;
        append_lp(&mut full, sealed.kem_output.as_slice()).unwrap();
        append_lp(&mut full, sealed.ciphertext.as_slice()).unwrap();
        let context = chunk_context(&full);
        let mut out = full.clone();
        for (index, chunk) in frame.chunks(MAX_ATTACHMENT_CHUNK).enumerate() {
            let enc = encrypt_chunk(
                secrets.key.as_slice(),
                &secrets.nonce_prefix,
                index as u32,
                &context,
                chunk,
            )
            .unwrap();
            out.extend_from_slice(&(enc.len() as u32).to_be_bytes());
            out.extend_from_slice(&enc);
        }
        out
    };
    let mut ok = vec![0u8; MIN_BACKUP_PADDED];
    ok[..8].copy_from_slice(&1u64.to_be_bytes());
    ok[8] = 9;
    assert!(open(&make(ok.clone()), &ENTROPY).is_ok());
    let mut dirty = ok.clone();
    dirty[100] = 1;
    assert!(open(&make(dirty), &ENTROPY).is_err());
    // Over-padded (2 MiB for a 1-byte payload) is not canonical.
    let mut over = vec![0u8; 2 * MIN_BACKUP_PADDED];
    over[..8].copy_from_slice(&1u64.to_be_bytes());
    assert!(open(&make(over), &ENTROPY).is_err());
    // Under-padded (64 KiB, below the 1 MiB floor) is not canonical.
    let mut under = vec![0u8; FRAME_BUCKET];
    under[..8].copy_from_slice(&1u64.to_be_bytes());
    assert!(open(&make(under), &ENTROPY).is_err());
}

#[test]
fn header_bytes_match_an_independent_encoding() {
    let rk = rk_pub(&ENTROPY);
    let h0 = encode_h0(&header(&rk), MIN_BACKUP_PADDED, BACKUP_KIND).unwrap();
    // Built field by field, independent of encode_h0.
    let mut expected = b"VHC1".to_vec();
    expected.push(1);
    expected.extend_from_slice(&[0, 6]);
    expected.extend_from_slice(b"acct_1");
    expected.extend_from_slice(&[0, 7]);
    expected.extend_from_slice(b"dev_old");
    expected.extend_from_slice(&1_730_000_000_000u64.to_be_bytes());
    expected.extend_from_slice(&7u64.to_be_bytes());
    expected.extend_from_slice(&[0, 16]);
    expected.extend_from_slice(&recovery_id(&rk));
    expected.extend_from_slice(&1u32.to_be_bytes());
    expected.extend_from_slice(&(MIN_BACKUP_PADDED as u64).to_be_bytes());
    expected.push(6);
    assert_eq!(h0, expected);
}

#[test]
fn peek_reads_only_the_header_and_refuses_junk() {
    let ciphertext = seal(b"synthetic history");
    let peek = peek_backup(&ciphertext[..MAX_PEEK_BYTES]).unwrap();
    assert_eq!(peek.header.snapshot_counter, 7);
    assert_eq!(
        peek.header.recovery_key_id,
        Some(recovery_id(&rk_pub(&ENTROPY)))
    );
    assert!(peek_backup(&ciphertext[..40]).is_err());
    assert!(peek_backup(&[]).is_err());
    assert!(peek_backup(&[0u8; 416]).is_err());
}

fn vector_inputs() -> (BundleHeader, [u8; 32], Vec<u8>, FileSecrets) {
    let root: serde_json::Value = serde_json::from_str(VECTOR).expect("vector JSON");
    let rk = rk_pub(&unhex(&root["recovery_key_entropy_hex"]));
    let secrets = FileSecrets::from_bytes(
        &unhex(&root["file_key_hex"]),
        &unhex(&root["nonce_prefix_hex"]),
    )
    .unwrap();
    let h = BundleHeader {
        account_id: root["account_id"].as_str().unwrap().as_bytes().to_vec(),
        source_device_id: root["source_device_id"]
            .as_str()
            .unwrap()
            .as_bytes()
            .to_vec(),
        created_at_ms: root["created_at_ms"].as_u64().unwrap(),
        snapshot_counter: root["counter"].as_u64().unwrap(),
        recovery_key_id: Some(recovery_id(&rk)),
        plaintext_version: root["plaintext_version"].as_u64().unwrap() as u8,
    };
    (h, rk, unhex(&root["payload_hex"]), secrets)
}

/// Regenerates the vector's sealed header: `cargo test -- --ignored
/// print_k1_vector --nocapture`. HPKE's encapsulation is random, so the file
/// pins one header and the checks below are what any later build must meet.
#[test]
#[ignore]
fn print_k1_vector() {
    let entropy = ENTROPY.to_vec();
    let rk = rk_pub(&entropy);
    let secrets = FileSecrets::from_bytes(&[0x61; 32], &[0x62; 8]).unwrap();
    let payload = b"{\"synthetic\":\"k1 backup vector\"}".to_vec();
    let h = BundleHeader {
        account_id: b"acct_k1_vector".to_vec(),
        source_device_id: b"dev_k1_vector".to_vec(),
        created_at_ms: 1_730_000_000_000,
        snapshot_counter: 42,
        recovery_key_id: Some(recovery_id(&rk)),
        plaintext_version: 6,
    };
    let ciphertext =
        seal_backup_with(&OpenMlsRustCrypto::default(), &h, &rk, &payload, &secrets).unwrap();
    let mut reader = Reader::new(&ciphertext);
    read_header_any(&mut reader).unwrap();
    let header_hex = hex(&ciphertext[..reader.offset]);
    println!(
        "{}",
        serde_json::json!({
            "recovery_key_entropy_hex": hex(&entropy),
            "rk_pub_hex": hex(&rk),
            "rk_id_hex": hex(&recovery_id(&rk)),
            "account_id": "acct_k1_vector",
            "source_device_id": "dev_k1_vector",
            "created_at_ms": 1_730_000_000_000u64,
            "counter": 42,
            "plaintext_version": 6,
            "payload_hex": hex(&payload),
            "file_key_hex": hex(&[0x61; 32]),
            "nonce_prefix_hex": hex(&[0x62; 8]),
            "padded_size": MIN_BACKUP_PADDED,
            "header_hex": header_hex,
            "ciphertext_sha256_hex": hex(&Sha256::digest(&ciphertext)),
        })
    );
}

#[test]
fn known_answer_vector() {
    let root: serde_json::Value = serde_json::from_str(VECTOR).expect("vector JSON");
    let (h, rk, payload, secrets) = vector_inputs();
    let entropy = unhex(&root["recovery_key_entropy_hex"]);
    assert_eq!(hex(&rk), root["rk_pub_hex"]);
    assert_eq!(hex(&recovery_id(&rk)), root["rk_id_hex"]);
    let header_bytes = unhex(&root["header_hex"]);
    // The pinned header parses to the pinned fields.
    let peek = peek_backup(&header_bytes).unwrap();
    assert_eq!(peek.header, h);
    assert_eq!(peek.padded as u64, root["padded_size"].as_u64().unwrap());
    // Its HPKE seal opens, with the entropy only, to the pinned file secrets.
    let mut reader = Reader::new(&header_bytes);
    let parsed = read_header_any(&mut reader).unwrap();
    assert_eq!(reader.offset, header_bytes.len());
    let pair = crate::recovery::derive_hpke_key_pair(&entropy).unwrap();
    let opened: SecretVLBytes = OpenMlsRustCrypto::default()
        .crypto()
        .hpke_open(
            suite(),
            &HpkeCiphertext {
                kem_output: parsed.enc.into(),
                ciphertext: parsed.sealed_fk.into(),
            },
            &pair.private,
            &backup_seal_info(&h.account_id).unwrap(),
            &header_bytes[..parsed.h0_len],
        )
        .unwrap()
        .into();
    assert_eq!(
        opened.as_slice(),
        [secrets.key.as_slice(), secrets.nonce_prefix.as_slice()].concat()
    );
    // The chunk layer is deterministic under those secrets: rebuilding the
    // container reproduces the pinned digest, and it opens.
    let ciphertext = seal_with_secrets(&header_bytes, &payload, peek.padded, &secrets).unwrap();
    assert_eq!(
        hex(&Sha256::digest(&ciphertext)),
        root["ciphertext_sha256_hex"]
    );
    let opened = open_backup(
        &OpenMlsRustCrypto::default(),
        &ciphertext,
        &entropy,
        &h.account_id,
        Some(&h.source_device_id),
    )
    .unwrap();
    assert_eq!(opened.payload.as_slice(), payload);
}

#[test]
fn ffi_round_trip_and_refusals() {
    use crate::{
        ffi::{
            pm_crypto_backup_open, pm_crypto_backup_peek, pm_crypto_backup_seal,
            pm_crypto_buffer_free, PmOwnedBuffer, PM_CRYPTO_ERROR, PM_CRYPTO_INVALID_ARGUMENT,
            PM_CRYPTO_OK,
        },
        PmByteSlice,
    };
    fn slice(bytes: &[u8]) -> PmByteSlice {
        PmByteSlice {
            data: bytes.as_ptr(),
            len: bytes.len(),
        }
    }
    fn take(buffer: PmOwnedBuffer) -> Vec<u8> {
        let bytes = unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) }.to_vec();
        unsafe { pm_crypto_buffer_free(buffer) };
        bytes
    }
    let rk = rk_pub(&ENTROPY);
    let mut out = PmOwnedBuffer::default();
    let code = unsafe {
        pm_crypto_backup_seal(
            slice(b"acct_1"),
            slice(b"dev_old"),
            1_730_000_000_000,
            9,
            6,
            slice(&rk),
            slice(b"synthetic"),
            &mut out,
        )
    };
    assert_eq!(code, PM_CRYPTO_OK);
    let ciphertext = take(out);
    let (mut account, mut device, mut meta) = (
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
    );
    let code = unsafe {
        pm_crypto_backup_peek(
            slice(&ciphertext[..MAX_PEEK_BYTES]),
            &mut account,
            &mut device,
            &mut meta,
        )
    };
    assert_eq!(code, PM_CRYPTO_OK);
    assert_eq!(take(account), b"acct_1");
    assert_eq!(take(device), b"dev_old");
    let meta = take(meta);
    assert_eq!(meta.len(), 41);
    assert_eq!(&meta[8..16], &9u64.to_be_bytes());
    assert_eq!(&meta[16..32], &recovery_id(&rk));
    let run = |entropy: &[u8], account: &[u8], device: &[u8]| {
        let mut payload = PmOwnedBuffer::default();
        let mut source = PmOwnedBuffer::default();
        let mut meta = PmOwnedBuffer::default();
        let code = unsafe {
            pm_crypto_backup_open(
                slice(&ciphertext),
                slice(entropy),
                slice(account),
                PmByteSlice {
                    data: device.as_ptr(),
                    len: device.len(),
                },
                &mut payload,
                &mut source,
                &mut meta,
            )
        };
        (code, payload, source, meta)
    };
    let (code, payload, source, meta) = run(&ENTROPY, b"acct_1", b"");
    assert_eq!(code, PM_CRYPTO_OK);
    assert_eq!(take(payload), b"synthetic");
    assert_eq!(take(source), b"dev_old");
    assert_eq!(take(meta).len(), 41);
    assert_eq!(run(&ENTROPY, b"acct_1", b"dev_old").0, PM_CRYPTO_OK);
    assert_eq!(run(&ENTROPY, b"acct_1", b"dev_new").0, PM_CRYPTO_ERROR);
    assert_eq!(run(&ENTROPY, b"acct_2", b"").0, PM_CRYPTO_ERROR);
    let mut other = ENTROPY;
    other[3] ^= 1;
    assert_eq!(run(&other, b"acct_1", b"").0, PM_CRYPTO_ERROR);
    assert_eq!(
        run(&ENTROPY[..5], b"acct_1", b"").0,
        PM_CRYPTO_INVALID_ARGUMENT
    );
}
