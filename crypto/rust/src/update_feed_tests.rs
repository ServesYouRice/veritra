use super::*;
use ed25519_dalek::{Signer, SigningKey};

// The signed vector `scripts/update-feed.py sign` made (its private key was
// thrown away): `mobile/test/fixtures/update-feed/`. Dart checks the same
// bytes through the FFI (`mobile/test/update_feed_native_test.dart`).
const FEED: &[u8] = include_bytes!("../../../mobile/test/fixtures/update-feed/update.json");
const SIGNATURE: &[u8] =
    include_bytes!("../../../mobile/test/fixtures/update-feed/update.json.sig");
const PUBLIC_KEY_HEX: &str =
    include_str!("../../../mobile/test/fixtures/update-feed/public-key.hex");

fn unhex(text: &str) -> Vec<u8> {
    let text = text.trim();
    assert_eq!(text.len() % 2, 0);
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

#[test]
fn the_committed_vector_verifies() {
    let key = unhex(PUBLIC_KEY_HEX);
    assert_eq!(key.len(), PUBLIC_KEY_BYTES);
    assert_eq!(SIGNATURE.len(), SIGNATURE_BYTES);
    assert_eq!(verify(&key, FEED, SIGNATURE), Ok(true));
}

#[test]
fn any_changed_byte_fails() {
    let key = unhex(PUBLIC_KEY_HEX);
    for index in [0, FEED.len() / 2, FEED.len() - 1] {
        let mut feed = FEED.to_vec();
        feed[index] ^= 1;
        assert_eq!(
            verify(&key, &feed, SIGNATURE),
            Ok(false),
            "feed byte {index}"
        );
    }
    for index in [0, 31, 32, 63] {
        let mut signature = SIGNATURE.to_vec();
        signature[index] ^= 1;
        assert_eq!(
            verify(&key, FEED, &signature),
            Ok(false),
            "signature byte {index}"
        );
    }
    let mut other_key = key.clone();
    other_key[0] ^= 1;
    assert_eq!(verify(&other_key, FEED, SIGNATURE), Ok(false));
}

#[test]
fn the_domain_is_required_and_no_other_domain_verifies() {
    let signing = SigningKey::from_bytes(&[7u8; 32]);
    let key = signing.verifying_key().to_bytes();
    let feed = b"{\"version\":\"1\"}";
    // Signed with the update-feed domain: valid.
    let good = signing.sign(&signing_input(feed).unwrap()).to_bytes();
    assert_eq!(verify(&key, feed, &good), Ok(true));
    // The raw feed without the domain, and the same feed under each domain
    // the library itself can sign (C7, invite binding, L1 list), never verify.
    let mut others: Vec<&[u8]> = vec![b""];
    others.extend(crate::c7::SIGN_DOMAINS);
    others.push(crate::l1::LABEL_SIG);
    for domain in others {
        let mut input = domain.to_vec();
        input.extend_from_slice(feed);
        let signature = signing.sign(&input).to_bytes();
        assert_eq!(verify(&key, feed, &signature), Ok(false), "{domain:?}");
    }
    // The library's own signers never take this domain.
    assert!(!crate::c7::SIGN_DOMAINS.contains(&DOMAIN));
    assert_ne!(crate::l1::LABEL_SIG, DOMAIN);
}

#[test]
fn lengths_are_refused() {
    let key = unhex(PUBLIC_KEY_HEX);
    assert_eq!(
        verify(&key[..31], FEED, SIGNATURE),
        Err(UpdateFeedError::InvalidInput)
    );
    let mut long_key = key.clone();
    long_key.push(0);
    assert_eq!(
        verify(&long_key, FEED, SIGNATURE),
        Err(UpdateFeedError::InvalidInput)
    );
    assert_eq!(
        verify(&key, FEED, &SIGNATURE[..63]),
        Err(UpdateFeedError::InvalidInput)
    );
    assert_eq!(
        verify(&key, b"", SIGNATURE),
        Err(UpdateFeedError::InvalidInput)
    );
    // At the cap a message is checked; one byte over it is refused.
    let signing = SigningKey::from_bytes(&[9u8; 32]);
    let at_cap = vec![b'a'; MAX_MESSAGE_BYTES];
    let signature = signing.sign(&signing_input(&at_cap).unwrap()).to_bytes();
    assert_eq!(
        verify(&signing.verifying_key().to_bytes(), &at_cap, &signature),
        Ok(true)
    );
    let over = vec![b'a'; MAX_MESSAGE_BYTES + 1];
    assert_eq!(
        verify(&signing.verifying_key().to_bytes(), &over, &signature),
        Err(UpdateFeedError::InvalidInput)
    );
}

#[test]
fn a_small_order_key_never_verifies() {
    // The identity point: with a non-strict check, (R = identity, s = 0)
    // would verify any message under it.
    let mut identity = [0u8; 32];
    identity[0] = 1;
    let mut signature = [0u8; 64];
    signature[..32].copy_from_slice(&identity);
    assert_eq!(verify(&identity, FEED, &signature), Ok(false));
}
