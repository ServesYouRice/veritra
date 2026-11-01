use super::*;
use crate::{
    ffi::{
        pm_crypto_buffer_free, pm_crypto_frank_commit, pm_crypto_report_key_generate,
        pm_crypto_report_key_public, pm_crypto_report_open, pm_crypto_report_seal, PmOwnedBuffer,
        PM_CRYPTO_ERROR, PM_CRYPTO_INVALID_ARGUMENT, PM_CRYPTO_OK,
    },
    PmByteSlice,
};

/// testing/vectors/c6-franking-v1.json: the shared known-answer vector the
/// Go reference (`server/internal/franking`) and the Dart binding check too.
const VECTOR: &str = include_str!("../../../testing/vectors/c6-franking-v1.json");

fn vector() -> serde_json::Value {
    serde_json::from_str(VECTOR).expect("vector parses")
}

fn hex(value: &serde_json::Value) -> Vec<u8> {
    let text = value.as_str().expect("hex string");
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

fn text(value: &serde_json::Value) -> &[u8] {
    value.as_str().expect("string").as_bytes()
}

#[test]
fn frank_commit_matches_the_shared_vector() {
    let v = vector();
    let c = &v["commitment"];
    let commit = frank_commit(
        &hex(&c["key_hex"]),
        text(&c["conversation_id"]),
        text(&c["sender_device_id"]),
        text(&c["action_id"]),
        text(&c["payload"]),
    )
    .unwrap();
    assert_eq!(commit.to_vec(), hex(&c["commit_hex"]));
}

#[test]
fn frank_commit_binds_every_field_and_refuses_bad_sizes() {
    let key = [7u8; FRANK_KEY_BYTES];
    let base = frank_commit(&key, b"C", b"D", b"A", b"P").unwrap();
    for changed in [
        frank_commit(&[8u8; 32], b"C", b"D", b"A", b"P").unwrap(),
        frank_commit(&key, b"X", b"D", b"A", b"P").unwrap(),
        frank_commit(&key, b"C", b"X", b"A", b"P").unwrap(),
        frank_commit(&key, b"C", b"D", b"X", b"P").unwrap(),
        frank_commit(&key, b"C", b"D", b"A", b"Q").unwrap(),
    ] {
        assert_ne!(changed, base);
    }
    assert_ne!(
        frank_commit(&key, b"ab", b"c", b"A", b"P").unwrap(),
        frank_commit(&key, b"a", b"bc", b"A", b"P").unwrap()
    );
    let long = [b'x'; MAX_FRANK_ID_BYTES + 1];
    let big = vec![b'x'; MAX_FRANK_PAYLOAD_BYTES + 1];
    for bad in [
        frank_commit(&key[..31], b"C", b"D", b"A", b"P"),
        frank_commit(&key, b"", b"D", b"A", b"P"),
        frank_commit(&key, b"C", b"", b"A", b"P"),
        frank_commit(&key, b"C", b"D", b"", b"P"),
        frank_commit(&key, b"C", b"D", b"A", b""),
        frank_commit(&key, &long, b"D", b"A", b"P"),
        frank_commit(&key, b"C", b"D", b"A", &big),
    ] {
        assert_eq!(bad, Err(ReportError::InvalidInput));
    }
    let max = vec![b'x'; MAX_FRANK_PAYLOAD_BYTES];
    assert!(frank_commit(&key, &long[1..], b"D", b"A", &max).is_ok());
}

#[test]
fn report_key_and_open_match_the_shared_vector() {
    let v = vector();
    let r = &v["report_hpke"];
    let seed = hex(&r["seed_hex"]);
    assert_eq!(public_key(&seed).unwrap().to_vec(), hex(&r["public_hex"]));
    let opened = open(&seed, text(&r["aad"]), &hex(&r["sealed_hex"])).unwrap();
    assert_eq!(opened.as_slice(), text(&r["plaintext"]));
}

#[test]
fn seal_round_trips_and_is_randomized() {
    let seed = generate_seed().unwrap();
    let public = public_key(seed.as_slice()).unwrap();
    let first = seal(&public, b"aad", b"report").unwrap();
    let second = seal(&public, b"aad", b"report").unwrap();
    assert_ne!(first, second);
    assert_eq!(&first[..4], b"VRP1");
    assert_eq!(first.len(), 4 + 32 + 6 + 16);
    for sealed in [&first, &second] {
        assert_eq!(
            open(seed.as_slice(), b"aad", sealed).unwrap().as_slice(),
            b"report"
        );
    }
    let max = vec![1u8; MAX_PLAINTEXT_BYTES];
    let sealed = seal(&public, b"aad", &max).unwrap();
    assert_eq!(sealed.len(), MAX_SEALED_BYTES);
    assert_eq!(
        open(seed.as_slice(), b"aad", &sealed).unwrap().as_slice(),
        max
    );
}

#[test]
fn open_refuses_any_change() {
    let seed = [3u8; SEED_BYTES];
    let public = public_key(&seed).unwrap();
    let sealed = seal(&public, b"aad", b"report").unwrap();
    // Every byte after the magic is authenticated (enc through the KEM, the
    // rest by the AEAD).
    for index in 4..sealed.len() {
        let mut changed = sealed.clone();
        changed[index] ^= 1;
        assert_eq!(
            open(&seed, b"aad", &changed),
            Err(ReportError::Authentication),
            "byte {index}"
        );
    }
    let mut magic = sealed.clone();
    magic[0] ^= 1;
    assert_eq!(open(&seed, b"aad", &magic), Err(ReportError::InvalidInput));
    assert_eq!(
        open(&seed, b"aaD", &sealed),
        Err(ReportError::Authentication)
    );
    assert_eq!(
        open(&[4u8; SEED_BYTES], b"aad", &sealed),
        Err(ReportError::Authentication)
    );
    assert_eq!(
        open(&seed, b"aad", &sealed[..sealed.len() - 1]),
        Err(ReportError::Authentication)
    );
    assert_eq!(
        open(&seed, b"aad", &sealed[..4 + 32 + 16]),
        Err(ReportError::InvalidInput)
    );
}

#[test]
fn info_label_separates_reports_from_other_hpke_uses() {
    // The same key opened with another info (as K0/K2 use) fails, and a
    // report sealed by a raw HPKE call with another info does not open.
    let crypto = RustCrypto::default();
    let seed = [5u8; SEED_BYTES];
    let pair = key_pair(&crypto, &seed).unwrap();
    let other = crypto
        .hpke_seal(
            suite(),
            &pair.public,
            b"veritra-k2-handoff-v1",
            b"aad",
            b"x",
        )
        .unwrap();
    let mut sealed = MAGIC.to_vec();
    sealed.extend_from_slice(other.kem_output.as_slice());
    sealed.extend_from_slice(other.ciphertext.as_slice());
    assert_eq!(
        open(&seed, b"aad", &sealed),
        Err(ReportError::Authentication)
    );
}

#[test]
fn seal_refuses_bad_keys_and_sizes() {
    let public = public_key(&[3u8; SEED_BYTES]).unwrap();
    // All-zero and other low-order points give an all-zero DH output.
    let low_order: [[u8; 32]; 2] = [[0u8; 32], {
        let mut one = [0u8; 32];
        one[0] = 1;
        one
    }];
    for key in low_order {
        assert_eq!(seal(&key, b"aad", b"x"), Err(ReportError::InvalidInput));
    }
    let too_big = vec![0u8; MAX_PLAINTEXT_BYTES + 1];
    let long_aad = vec![0u8; MAX_AAD_BYTES + 1];
    for bad in [
        seal(&public[..31], b"aad", b"x"),
        seal(&public, b"", b"x"),
        seal(&public, &long_aad, b"x"),
        seal(&public, b"aad", b""),
        seal(&public, b"aad", &too_big),
    ] {
        assert_eq!(bad, Err(ReportError::InvalidInput));
    }
    assert_eq!(public_key(&[0u8; 31]), Err(ReportError::InvalidInput));
    assert!(seal(&public, &vec![0u8; MAX_AAD_BYTES], b"x").is_ok());
}

#[test]
fn seed_derivation_is_deterministic_and_distinct_per_seed() {
    let a = public_key(&[1u8; 32]).unwrap();
    assert_eq!(a, public_key(&[1u8; 32]).unwrap());
    assert_ne!(a, public_key(&[2u8; 32]).unwrap());
    let fresh = generate_seed().unwrap();
    assert_eq!(fresh.as_slice().len(), SEED_BYTES);
    assert_ne!(fresh.as_slice(), generate_seed().unwrap().as_slice());
}

fn slice(bytes: &[u8]) -> PmByteSlice {
    PmByteSlice {
        data: bytes.as_ptr(),
        len: bytes.len(),
    }
}

fn take(buffer: PmOwnedBuffer) -> Vec<u8> {
    assert!(!buffer.data.is_null());
    // SAFETY: an OK call wrote a live library-owned buffer.
    let bytes = unsafe { core::slice::from_raw_parts(buffer.data, buffer.len) }.to_vec();
    unsafe { pm_crypto_buffer_free(buffer) };
    bytes
}

#[test]
fn ffi_matches_the_vector_and_round_trips() {
    let v = vector();
    let c = &v["commitment"];
    let r = &v["report_hpke"];
    unsafe {
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_frank_commit(
                slice(&hex(&c["key_hex"])),
                slice(text(&c["conversation_id"])),
                slice(text(&c["sender_device_id"])),
                slice(text(&c["action_id"])),
                slice(text(&c["payload"])),
                &mut out,
            ),
            PM_CRYPTO_OK
        );
        assert_eq!(take(out), hex(&c["commit_hex"]));

        let seed = hex(&r["seed_hex"]);
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_report_key_public(slice(&seed), &mut out),
            PM_CRYPTO_OK
        );
        let public = take(out);
        assert_eq!(public, hex(&r["public_hex"]));

        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_report_open(
                slice(&seed),
                slice(text(&r["aad"])),
                slice(&hex(&r["sealed_hex"])),
                &mut out
            ),
            PM_CRYPTO_OK
        );
        assert_eq!(take(out), text(&r["plaintext"]));

        let mut out = PmOwnedBuffer::default();
        assert_eq!(pm_crypto_report_key_generate(&mut out), PM_CRYPTO_OK);
        let fresh = take(out);
        assert_eq!(fresh.len(), SEED_BYTES);
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_report_key_public(slice(&fresh), &mut out),
            PM_CRYPTO_OK
        );
        let fresh_public = take(out);
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_report_seal(slice(&fresh_public), slice(b"a"), slice(b"msg"), &mut out),
            PM_CRYPTO_OK
        );
        let sealed = take(out);
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_report_open(slice(&fresh), slice(b"a"), slice(&sealed), &mut out),
            PM_CRYPTO_OK
        );
        assert_eq!(take(out), b"msg");
    }
}

#[test]
fn ffi_fails_closed_and_writes_nothing() {
    let seed = [3u8; SEED_BYTES];
    let public = public_key(&seed).unwrap();
    let sealed = seal(&public, b"aad", b"report").unwrap();
    let mut tampered = sealed.clone();
    let last = tampered.len() - 1;
    tampered[last] ^= 1;
    let null = PmByteSlice {
        data: core::ptr::null(),
        len: 32,
    };
    unsafe {
        assert_eq!(
            pm_crypto_report_key_generate(core::ptr::null_mut()),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_report_key_public(slice(&seed), core::ptr::null_mut()),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        let cases: [(i32, Box<dyn Fn(*mut PmOwnedBuffer) -> i32>); 9] = [
            (
                PM_CRYPTO_ERROR,
                Box::new(|o| {
                    pm_crypto_report_open(slice(&seed), slice(b"aad"), slice(&tampered), o)
                }),
            ),
            (
                PM_CRYPTO_ERROR,
                Box::new(|o| pm_crypto_report_open(slice(&seed), slice(b"aaD"), slice(&sealed), o)),
            ),
            (
                PM_CRYPTO_INVALID_ARGUMENT,
                Box::new(|o| pm_crypto_report_open(null, slice(b"aad"), slice(&sealed), o)),
            ),
            (
                PM_CRYPTO_INVALID_ARGUMENT,
                Box::new(|o| {
                    pm_crypto_report_open(slice(&seed[..31]), slice(b"aad"), slice(&sealed), o)
                }),
            ),
            (
                PM_CRYPTO_INVALID_ARGUMENT,
                Box::new(|o| pm_crypto_report_seal(slice(&public), slice(b""), slice(b"x"), o)),
            ),
            (
                PM_CRYPTO_INVALID_ARGUMENT,
                Box::new(|o| pm_crypto_report_seal(slice(&[0u8; 32]), slice(b"a"), slice(b"x"), o)),
            ),
            (
                PM_CRYPTO_INVALID_ARGUMENT,
                Box::new(|o| pm_crypto_report_seal(slice(&public), slice(b"a"), null, o)),
            ),
            (
                PM_CRYPTO_INVALID_ARGUMENT,
                Box::new(|o| {
                    pm_crypto_frank_commit(
                        slice(&[7u8; 31]),
                        slice(b"C"),
                        slice(b"D"),
                        slice(b"A"),
                        slice(b"P"),
                        o,
                    )
                }),
            ),
            (
                PM_CRYPTO_INVALID_ARGUMENT,
                Box::new(|o| {
                    pm_crypto_frank_commit(
                        slice(&[7u8; 32]),
                        slice(&[b'c'; 129]),
                        slice(b"D"),
                        slice(b"A"),
                        slice(b"P"),
                        o,
                    )
                }),
            ),
        ];
        for (index, (code, call)) in cases.iter().enumerate() {
            let mut out = PmOwnedBuffer::default();
            assert_eq!(call(&mut out), *code, "case {index}");
            assert!(
                out.data.is_null() && out.len == 0,
                "case {index} wrote output"
            );
            assert_eq!(
                call(core::ptr::null_mut()),
                PM_CRYPTO_INVALID_ARGUMENT,
                "case {index} null out"
            );
        }
    }
}
