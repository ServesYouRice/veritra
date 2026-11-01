use super::*;
use crate::{
    ffi::{
        pm_crypto_buffer_free, pm_crypto_recovery_key_decode, pm_crypto_recovery_key_derive,
        pm_crypto_recovery_key_encode, pm_crypto_recovery_key_generate,
        pm_crypto_recovery_proof_sign, PmOwnedBuffer, PM_CRYPTO_INVALID_ARGUMENT, PM_CRYPTO_OK,
    },
    PmByteSlice,
};
use ed25519_dalek::{Signature, VerifyingKey};

/// The shared known-answer vector, also checked by the Go server
/// (`server/internal/httpapi/account_recovery_vector_test.go`) and the Dart
/// bindings. `include_str!` makes a missing file a build failure.
const VECTOR: &str = include_str!("../../../testing/vectors/k0-recovery-v1.json");

struct Vector {
    entropy: Vec<u8>,
    display: String,
    rk_pub: Vec<u8>,
    rk_id: Vec<u8>,
    rk_auth_pub: Vec<u8>,
    challenge: Vec<u8>,
    signing_key: Vec<u8>,
    key_package: Vec<u8>,
    origin: String,
    message: Vec<u8>,
    signature: Vec<u8>,
}

fn hex(value: &serde_json::Value) -> Vec<u8> {
    let text = value.as_str().expect("hex string");
    assert!(!text.is_empty() && text.len().is_multiple_of(2));
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

fn vector() -> Vector {
    let root: serde_json::Value = serde_json::from_str(VECTOR).expect("vector JSON");
    let key = &root["recovery_key"];
    let proof = &root["proof"];
    Vector {
        entropy: hex(&key["entropy_hex"]),
        display: key["display"].as_str().expect("display").to_owned(),
        rk_pub: hex(&key["rk_pub_hex"]),
        rk_id: hex(&key["rk_id_hex"]),
        rk_auth_pub: hex(&key["rk_auth_pub_hex"]),
        challenge: hex(&proof["challenge_hex"]),
        signing_key: hex(&proof["signing_key_hex"]),
        key_package: hex(&proof["key_package_hex"]),
        origin: proof["origin"].as_str().expect("origin").to_owned(),
        message: hex(&proof["message_hex"]),
        signature: hex(&proof["signature_hex"]),
    }
}

#[test]
fn known_answer_vector() {
    let v = vector();
    assert_eq!(v.entropy.len(), ENTROPY_BYTES);
    assert_eq!(encode(&v.entropy).unwrap(), v.display);
    assert_eq!(
        decode(v.display.as_bytes()).unwrap().as_slice(),
        v.entropy.as_slice()
    );
    let derived = derive(&v.entropy).unwrap();
    assert_eq!(derived.rk_pub.as_slice(), v.rk_pub.as_slice());
    assert_eq!(derived.rk_id.as_slice(), v.rk_id.as_slice());
    assert_eq!(derived.rk_auth_pub.as_slice(), v.rk_auth_pub.as_slice());
    let message = proof_message(
        &v.challenge,
        &v.signing_key,
        &v.key_package,
        v.origin.as_bytes(),
    )
    .unwrap();
    assert_eq!(message, v.message);
    let signature = sign_proof(
        &v.entropy,
        &v.challenge,
        &v.signing_key,
        &v.key_package,
        v.origin.as_bytes(),
    )
    .unwrap();
    assert_eq!(signature.as_slice(), v.signature.as_slice());
    let key = VerifyingKey::from_bytes(&derived.rk_auth_pub).unwrap();
    key.verify_strict(&message, &Signature::from_bytes(&signature))
        .unwrap();
}

#[test]
fn proof_binds_the_origin_and_every_field() {
    let v = vector();
    let key = VerifyingKey::from_bytes(&derive(&v.entropy).unwrap().rk_auth_pub).unwrap();
    let signature = Signature::from_bytes(&v.signature.as_slice().try_into().unwrap());
    let mut other_key = v.signing_key.clone();
    other_key[0] ^= 1;
    for message in [
        proof_message(
            &v.challenge,
            &v.signing_key,
            &v.key_package,
            b"https://chat.example.com.evil",
        ),
        proof_message(
            &v.challenge[1..],
            &v.signing_key,
            &v.key_package,
            v.origin.as_bytes(),
        ),
        proof_message(
            &v.challenge,
            &other_key,
            &v.key_package,
            v.origin.as_bytes(),
        ),
        proof_message(
            &v.challenge,
            &v.signing_key,
            &v.key_package[1..],
            v.origin.as_bytes(),
        ),
    ] {
        assert!(key.verify_strict(&message.unwrap(), &signature).is_err());
    }
}

#[test]
fn decode_accepts_typing_variants_only() {
    let v = vector();
    let grouped: String = v
        .display
        .as_bytes()
        .chunks(4)
        .map(|chunk| core::str::from_utf8(chunk).unwrap())
        .collect::<Vec<_>>()
        .join("-");
    let lower = v.display.to_ascii_lowercase();
    let spaced = grouped.replace('-', " ");
    // The vector's display holds 0s and 1s, so the aliases are exercised.
    assert!(v.display.contains('0') && v.display.contains('1'));
    let aliased = v
        .display
        .replacen('0', "O", 1)
        .replacen('1', "l", 1)
        .replacen('1', "I", 1);
    for text in [&grouped, &lower, &spaced, &aliased] {
        assert_eq!(
            decode(text.as_bytes()).unwrap().as_slice(),
            v.entropy.as_slice()
        );
    }

    let mut refused: Vec<Vec<u8>> = vec![
        Vec::new(),
        v.display.as_bytes()[..51].to_vec(),
        [v.display.as_bytes(), b"0"].concat(),
        v.display.replacen('W', "U", 1).into_bytes(),
        v.display.replacen('W', "*", 1).into_bytes(),
        v.display.replacen('W', "_", 1).into_bytes(),
        vec![b'-'; 300],
    ];
    // One changed symbol breaks the check.
    let mut typo = v.display.clone().into_bytes();
    typo[10] = if typo[10] == b'A' { b'B' } else { b'A' };
    refused.push(typo);
    // The last symbol carries 1 data bit and 4 padding bits. Setting a
    // padding bit keeps the 32 decoded bytes and the check, but the text
    // is not canonical, so it is refused.
    let mut padded = v.display.clone().into_bytes();
    let last = CROCKFORD.iter().position(|&c| c == padded[51]).unwrap();
    padded[51] = CROCKFORD[last | 1];
    assert_ne!(padded[51], v.display.as_bytes()[51]);
    refused.push(padded);
    for text in refused {
        assert_eq!(decode(&text).err(), Some(RecoveryError::InvalidInput));
    }
}

#[test]
fn generate_round_trips_and_differs() {
    let first = generate().unwrap();
    let second = generate().unwrap();
    assert_eq!(first.as_slice().len(), ENTROPY_BYTES);
    assert_ne!(first.as_slice(), second.as_slice());
    let text = encode(first.as_slice()).unwrap();
    assert_eq!(text.len(), DISPLAY_CHARS);
    assert!(text.bytes().all(|byte| CROCKFORD.contains(&byte)));
    assert_eq!(
        decode(text.as_bytes()).unwrap().as_slice(),
        first.as_slice()
    );
    let derived = derive(first.as_slice()).unwrap();
    assert_ne!(derived, derive(second.as_slice()).unwrap());
}

#[test]
fn inputs_out_of_bounds_are_refused() {
    let v = vector();
    let origin = v.origin.as_bytes();
    for entropy in [&v.entropy[..29], &[v.entropy.as_slice(), &[0]].concat()[..]] {
        assert_eq!(encode(entropy).err(), Some(RecoveryError::InvalidInput));
        assert_eq!(derive(entropy).err(), Some(RecoveryError::InvalidInput));
        assert_eq!(
            sign_proof(
                entropy,
                &v.challenge,
                &v.signing_key,
                &v.key_package,
                origin
            )
            .err(),
            Some(RecoveryError::InvalidInput)
        );
    }
    let long_challenge = vec![1; MAX_CHALLENGE_BYTES + 1];
    let long_package = vec![1; MAX_KEY_PACKAGE_BYTES + 1];
    let long_origin = vec![b'a'; MAX_ORIGIN_BYTES + 1];
    type Case<'a> = (&'a [u8], &'a [u8], &'a [u8], &'a [u8]);
    let cases: [Case; 11] = [
        (&[], &v.signing_key, &v.key_package, origin),
        (&long_challenge, &v.signing_key, &v.key_package, origin),
        (&v.challenge, &v.signing_key[..31], &v.key_package, origin),
        (&v.challenge, &[0; 33], &v.key_package, origin),
        (&v.challenge, &v.signing_key, &[], origin),
        (&v.challenge, &v.signing_key, &long_package, origin),
        (&v.challenge, &v.signing_key, &v.key_package, &[]),
        (&v.challenge, &v.signing_key, &v.key_package, &long_origin),
        (
            &v.challenge,
            &v.signing_key,
            &v.key_package,
            b"https://a.example\n",
        ),
        (
            &v.challenge,
            &v.signing_key,
            &v.key_package,
            b"https://a .example",
        ),
        (&v.challenge, &v.signing_key, &v.key_package, &[0xff, 0xfe]),
    ];
    for (challenge, signing_key, key_package, origin) in cases {
        assert_eq!(
            proof_message(challenge, signing_key, key_package, origin).err(),
            Some(RecoveryError::InvalidInput)
        );
        assert_eq!(
            sign_proof(&v.entropy, challenge, signing_key, key_package, origin).err(),
            Some(RecoveryError::InvalidInput)
        );
    }
    // The largest accepted inputs still fit the u16 length prefixes.
    assert!(proof_message(
        &vec![7; MAX_CHALLENGE_BYTES],
        &v.signing_key,
        &long_package[..MAX_KEY_PACKAGE_BYTES],
        &long_origin[..MAX_ORIGIN_BYTES],
    )
    .is_ok());
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
fn ffi_matches_the_vector() {
    let v = vector();
    unsafe {
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_recovery_key_encode(slice(&v.entropy), &mut out),
            PM_CRYPTO_OK
        );
        assert_eq!(take(out), v.display.as_bytes());

        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_recovery_key_decode(slice(v.display.as_bytes()), &mut out),
            PM_CRYPTO_OK
        );
        assert_eq!(take(out), v.entropy);

        let (mut a, mut b, mut c) = Default::default();
        assert_eq!(
            pm_crypto_recovery_key_derive(slice(&v.entropy), &mut a, &mut b, &mut c),
            PM_CRYPTO_OK
        );
        assert_eq!(take(a), v.rk_pub);
        assert_eq!(take(b), v.rk_id);
        assert_eq!(take(c), v.rk_auth_pub);

        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_recovery_proof_sign(
                slice(&v.entropy),
                slice(&v.challenge),
                slice(&v.signing_key),
                slice(&v.key_package),
                slice(v.origin.as_bytes()),
                &mut out,
            ),
            PM_CRYPTO_OK
        );
        assert_eq!(take(out), v.signature);

        let mut out = PmOwnedBuffer::default();
        assert_eq!(pm_crypto_recovery_key_generate(&mut out), PM_CRYPTO_OK);
        assert_eq!(take(out).len(), ENTROPY_BYTES);
    }
}

#[test]
fn ffi_fails_closed() {
    let v = vector();
    let null = PmByteSlice {
        data: core::ptr::null(),
        len: 30,
    };
    unsafe {
        assert_eq!(
            pm_crypto_recovery_key_generate(core::ptr::null_mut()),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        for entropy in [
            null,
            slice(&v.entropy[..29]),
            slice(&[v.entropy.as_slice(), &[1]].concat()),
        ] {
            let mut out = PmOwnedBuffer::default();
            assert_eq!(
                pm_crypto_recovery_key_encode(entropy, &mut out),
                PM_CRYPTO_INVALID_ARGUMENT
            );
            assert!(out.data.is_null());
            let (mut a, mut b, mut c) = Default::default();
            assert_eq!(
                pm_crypto_recovery_key_derive(entropy, &mut a, &mut b, &mut c),
                PM_CRYPTO_INVALID_ARGUMENT
            );
            assert!(a.data.is_null() && b.data.is_null() && c.data.is_null());
        }
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_recovery_key_encode(slice(&v.entropy), core::ptr::null_mut()),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_recovery_key_decode(slice(b"not a recovery key"), &mut out),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert!(out.data.is_null());
        let (mut a, mut b) = Default::default();
        assert_eq!(
            pm_crypto_recovery_key_derive(slice(&v.entropy), &mut a, &mut b, core::ptr::null_mut()),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert!(a.data.is_null() && b.data.is_null());
        assert_eq!(
            pm_crypto_recovery_proof_sign(
                slice(&v.entropy),
                slice(&v.challenge),
                slice(&v.signing_key[..31]),
                slice(&v.key_package),
                slice(v.origin.as_bytes()),
                &mut out,
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_recovery_proof_sign(
                slice(&v.entropy),
                slice(&v.challenge),
                slice(&v.signing_key),
                slice(&v.key_package),
                slice(b"https://chat.example.com\0"),
                &mut out,
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_recovery_proof_sign(
                slice(&v.entropy),
                slice(&v.challenge),
                slice(&v.signing_key),
                slice(&v.key_package),
                slice(v.origin.as_bytes()),
                core::ptr::null_mut(),
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert!(out.data.is_null());
    }
}
