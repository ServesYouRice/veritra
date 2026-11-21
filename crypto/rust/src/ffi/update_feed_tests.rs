//! ABI 27 (W12): `pm_crypto_update_feed_verify`, called the way Dart calls it.

use super::*;

const FEED: &[u8] = include_bytes!("../../../../mobile/test/fixtures/update-feed/update.json");
const SIGNATURE: &[u8] =
    include_bytes!("../../../../mobile/test/fixtures/update-feed/update.json.sig");
const PUBLIC_KEY_HEX: &str =
    include_str!("../../../../mobile/test/fixtures/update-feed/public-key.hex");

fn slice(bytes: &[u8]) -> PmByteSlice {
    PmByteSlice {
        data: bytes.as_ptr(),
        len: bytes.len(),
    }
}

fn key() -> Vec<u8> {
    let text = PUBLIC_KEY_HEX.trim();
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

fn call(key: &[u8], message: &[u8], signature: &[u8]) -> (i32, u8) {
    let mut valid = 0xaa;
    let status = unsafe {
        pm_crypto_update_feed_verify(slice(key), slice(message), slice(signature), &mut valid)
    };
    (status, valid)
}

#[test]
fn the_committed_vector_verifies_through_the_abi() {
    assert_eq!(call(&key(), FEED, SIGNATURE), (PM_CRYPTO_OK, 1));
    let mut feed = FEED.to_vec();
    let last = feed.len() - 2;
    feed[last] ^= 1;
    assert_eq!(call(&key(), &feed, SIGNATURE), (PM_CRYPTO_OK, 0));
}

#[test]
fn wrong_lengths_and_null_output_are_invalid_arguments() {
    let key = key();
    let over = vec![b'a'; crate::update_feed::MAX_MESSAGE_BYTES + 1];
    let mut long_key = key.clone();
    long_key.push(0);
    for (k, m, s) in [
        (&key[..31], FEED, SIGNATURE),
        (&long_key[..], FEED, SIGNATURE),
        (&key[..], FEED, &SIGNATURE[..63]),
        (&key[..], &over[..], SIGNATURE),
        (&key[..], b"".as_slice(), SIGNATURE),
    ] {
        // `out_valid` is left alone on a refusal.
        assert_eq!(call(k, m, s), (PM_CRYPTO_INVALID_ARGUMENT, 0xaa));
    }
    let status = unsafe {
        pm_crypto_update_feed_verify(slice(&key), slice(FEED), slice(SIGNATURE), ptr::null_mut())
    };
    assert_eq!(status, PM_CRYPTO_INVALID_ARGUMENT);
}

#[test]
fn the_abi_version_names_this_function() {
    assert_eq!(crate::pm_crypto_abi_version(), 27);
}
