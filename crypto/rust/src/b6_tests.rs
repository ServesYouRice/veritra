use super::*;
use crate::c7::{
    signing_input, verify, SIGN_DOMAINS, SIGN_DOMAIN_HISTORY, SIGN_DOMAIN_INVITE, SIGN_DOMAIN_POST,
};
use ed25519_dalek::{Signer, SigningKey};
use serde_json::{json, Value};

/// `testing/vectors/b6-media-v1.json`: known answers for the B6 key schedule
/// and the join signature. Rust, Go (`server/internal/b6vector`) check it.
/// The exporter secret `E` is an input here (OpenMLS cannot start a group
/// from fixed secrets); `mls.rs` tests tie the real exporter to
/// `sender_key`.
const VECTOR: &str = include_str!("../../../testing/vectors/b6-media-v1.json");

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn unhex(value: &Value) -> Vec<u8> {
    let text = value.as_str().expect("hex string");
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

const EXPORTER: [u8; 32] = [0x5a; 32];

fn build() -> Value {
    let call_id = b"call_0123456789";
    let group_id = [0x11u8; 32];
    let nonce = [0x22u8; 16];
    let expires_at = 1_800_000_060u64;
    let key_package = [0x33u8; 200];
    let seed = [0x44u8; 32];
    let signing = SigningKey::from_bytes(&seed);
    let message = join_message(&group_id, &nonce, expires_at, &key_package).unwrap();
    let signature = signing
        .sign(&signing_input(SIGN_DOMAIN_JOIN, &message).unwrap())
        .to_bytes();
    let keys: Vec<Value> = [(0u32, 0u8), (0, 1), (1, 0), (1, 2), (7, 3), (0xffff, 0)]
        .iter()
        .map(|(leaf, stream)| {
            json!({"leaf": leaf, "stream": stream,
                   "key_hex": hex(sender_key(&EXPORTER, *leaf, *stream).unwrap().as_slice())})
        })
        .collect();
    json!({
        "version": 1,
        "description": "B6 media keys and join signature (docs/designs/B6-group-calls.md, ABI 28). E is an input; the real exporter is tied to it in crypto/rust/src/mls.rs tests. Regenerate: cargo test --lib b6::tests::print_vector -- --ignored --nocapture.",
        "inputs": {
            "exporter_label": EXPORTER_LABEL,
            "sender_salt": String::from_utf8_lossy(SENDER_SALT),
            "call_id": String::from_utf8_lossy(call_id),
            "epoch": 3,
            "exporter_secret_hex": hex(&EXPORTER),
            "join_domain": String::from_utf8_lossy(SIGN_DOMAIN_JOIN),
            "join_group_id_hex": hex(&group_id),
            "join_nonce_hex": hex(&nonce),
            "join_expires_at": expires_at,
            "join_key_package_hex": hex(&key_package),
            "join_seed_hex": hex(&seed)
        },
        "outputs": {
            "exporter_context_hex": hex(&exporter_context(call_id, 3).unwrap()),
            "keys": keys,
            "join_public_key_hex": hex(signing.verifying_key().as_bytes()),
            "join_message_hex": hex(&message),
            "join_signature_hex": hex(&signature)
        }
    })
}

#[test]
#[ignore]
fn print_vector() {
    println!("{}", serde_json::to_string_pretty(&build()).unwrap());
}

#[test]
fn the_vector_matches() {
    let expected: Value = serde_json::from_str(VECTOR).unwrap();
    assert_eq!(expected, build());
    let out = &expected["outputs"];
    let public = unhex(&out["join_public_key_hex"]);
    let message = unhex(&out["join_message_hex"]);
    let signature = unhex(&out["join_signature_hex"]);
    assert!(verify(SIGN_DOMAIN_JOIN, &public, &message, &signature).unwrap());
}

#[test]
fn keys_differ_per_sender_stream_and_secret() {
    let base = sender_key(&EXPORTER, 1, 0).unwrap().as_slice().to_vec();
    assert_ne!(base, sender_key(&EXPORTER, 2, 0).unwrap().as_slice());
    assert_ne!(base, sender_key(&EXPORTER, 1, 1).unwrap().as_slice());
    assert_ne!(base, sender_key(&[0x5b; 32], 1, 0).unwrap().as_slice());
    assert_eq!(base, sender_key(&EXPORTER, 1, 0).unwrap().as_slice());
    assert!(sender_key(&EXPORTER, 1, STREAM_SLOTS).is_err());
    assert!(sender_key(&EXPORTER[..31], 1, 0).is_err());
}

#[test]
fn context_binds_call_and_epoch() {
    assert_ne!(
        exporter_context(b"a", 1).unwrap(),
        exporter_context(b"a", 2).unwrap()
    );
    assert_ne!(
        exporter_context(b"a", 1).unwrap(),
        exporter_context(b"b", 1).unwrap()
    );
    assert!(exporter_context(b"", 1).is_err());
    assert!(exporter_context(&[1; 129], 1).is_err());
}

#[test]
fn join_signature_is_its_own_domain() {
    let message = join_message(&[1; 32], &[2; 16], 99, &[3; 100]).unwrap();
    let signing = SigningKey::from_bytes(&[9; 32]);
    let public = signing.verifying_key().to_bytes();
    let signature = signing
        .sign(&signing_input(SIGN_DOMAIN_JOIN, &message).unwrap())
        .to_bytes();
    assert!(verify(SIGN_DOMAIN_JOIN, &public, &message, &signature).unwrap());
    for other in [SIGN_DOMAIN_POST, SIGN_DOMAIN_HISTORY, SIGN_DOMAIN_INVITE] {
        assert!(!verify(other, &public, &message, &signature).unwrap());
    }
    // Each field is bound.
    for changed in [
        join_message(&[2; 32], &[2; 16], 99, &[3; 100]).unwrap(),
        join_message(&[1; 32], &[3; 16], 99, &[3; 100]).unwrap(),
        join_message(&[1; 32], &[2; 16], 100, &[3; 100]).unwrap(),
        join_message(&[1; 32], &[2; 16], 99, &[4; 100]).unwrap(),
    ] {
        assert!(!verify(SIGN_DOMAIN_JOIN, &public, &changed, &signature).unwrap());
    }
    // No signing domain is a prefix of another, so `domain | message` has one reading.
    for (i, a) in SIGN_DOMAINS.iter().enumerate() {
        for (j, b) in SIGN_DOMAINS.iter().enumerate() {
            assert!(i == j || !b.starts_with(a));
        }
    }
    assert!(!SENDER_SALT.starts_with(SIGN_DOMAIN_JOIN));
}
