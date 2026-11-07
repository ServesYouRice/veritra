//! C1 invitation binding v2 (`docs/designs/C1-invite-format.md`): the
//! known answer `testing/vectors/invite-binding-v2.json`, and the properties
//! the joiner relies on. The Go test (`TestInviteBindingV2Vector`) and the
//! Dart tests (`membership_invite_link_test.dart`, `invite_binding_native_test.dart`)
//! read the same file. This builds the bytes from the written layout and does
//! not call the app's builder, so a drift on either side fails a test.

use super::*;
use ed25519_dalek::{Signer, SigningKey};
use serde_json::{json, Value};

const VECTOR: &str = include_str!("../../../testing/vectors/invite-binding-v2.json");

const LOCATOR_LABEL: &[u8] = b"veritra/membership-invite/v1/locator\0";
const KEY_COMMIT_LABEL: &[u8] = b"veritra/membership-invite/v2/key-commit\0";

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

fn lp(out: &mut Vec<u8>, field: &[u8]) {
    out.extend_from_slice(&(field.len() as u16).to_be_bytes());
    out.extend_from_slice(field);
}

/// Every output of the vector, from its inputs alone.
fn compute(inputs: &Value) -> Value {
    let secret = unhex(&inputs["secret_hex"]);
    let signing = SigningKey::from_bytes(&unhex(&inputs["signing_seed_hex"]).try_into().unwrap());
    let public = signing.verifying_key().to_bytes();
    let locator = hex(&Sha256::digest([LOCATOR_LABEL, &secret].concat()));
    let commitment = Sha256::digest([KEY_COMMIT_LABEL, &public[..]].concat());
    let mut message = Vec::new();
    for field in [
        inputs["origin"].as_str().unwrap().as_bytes(),
        inputs["target_kind"].as_str().unwrap().as_bytes(),
        inputs["target_id"].as_str().unwrap().as_bytes(),
        inputs["inviter_account_id"].as_str().unwrap().as_bytes(),
        inputs["inviter_device_id"].as_str().unwrap().as_bytes(),
        &public[..],
        locator.as_bytes(),
    ] {
        lp(&mut message, field);
    }
    let signature = signing
        .sign(&signing_input(SIGN_DOMAIN_INVITE, &message).unwrap())
        .to_bytes();
    json!({
        "signing_public_key_hex": hex(&public),
        "locator": locator,
        "key_commitment_hex": hex(&commitment[..16]),
        "signed_message_hex": hex(&message),
        "signature_hex": hex(&signature),
    })
}

#[test]
fn the_vector_matches_the_written_layout() {
    let vector: Value = serde_json::from_str(VECTOR).expect("vector parses");
    let computed = compute(&vector["inputs"]);
    for (name, value) in computed.as_object().unwrap() {
        assert_eq!(&vector["outputs"][name], value, "{name}");
    }
    // The strict verifier, as the joiner's app calls it, accepts it.
    let key = unhex(&vector["outputs"]["signing_public_key_hex"]);
    let message = unhex(&vector["outputs"]["signed_message_hex"]);
    let signature = unhex(&vector["outputs"]["signature_hex"]);
    assert!(verify(SIGN_DOMAIN_INVITE, &key, &message, &signature).unwrap());
    // It is no signature in any other domain, nor over any other bytes.
    assert!(!verify(SIGN_DOMAIN_POST, &key, &message, &signature).unwrap());
    assert!(!verify(SIGN_DOMAIN_HISTORY, &key, &message, &signature).unwrap());
    for i in 0..message.len() {
        let mut other = message.clone();
        other[i] ^= 1;
        assert!(!verify(SIGN_DOMAIN_INVITE, &key, &other, &signature).unwrap());
    }
    let mut other_key = key.clone();
    other_key[0] ^= 1;
    assert!(!verify(SIGN_DOMAIN_INVITE, &other_key, &message, &signature).unwrap());
}

#[test]
fn no_signing_domain_is_a_prefix_of_another() {
    for (i, a) in SIGN_DOMAINS.iter().enumerate() {
        for (j, b) in SIGN_DOMAINS.iter().enumerate() {
            if i != j {
                assert!(!b.starts_with(a), "{a:?} prefixes {b:?}");
            }
        }
    }
}

/// Prints a fresh vector from the inputs in the file. Run by hand when the
/// encodings change on purpose:
/// `cargo test --lib invite_binding_tests::print_vector -- --ignored --nocapture`
#[test]
#[ignore]
fn print_vector() {
    let vector: Value = serde_json::from_str(VECTOR).expect("vector parses");
    let inputs = vector["inputs"].clone();
    let document = json!({
        "version": vector["version"],
        "description": vector["description"],
        "inputs": inputs,
        "outputs": compute(&inputs),
    });
    println!("{}", serde_json::to_string_pretty(&document).unwrap());
}
