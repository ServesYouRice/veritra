//! ABI 28 (B6) entry points: the call group.
//!
//! Design: `docs/designs/B6-group-calls.md` ("Call-group marker (ABI 28)");
//! rules in `docs/crypto.md`. A call group carries GroupContext extension
//! `0xF0B6` (`u8(1) | lp(call_id) | lp(conversation_id)`), required by the
//! group and never changed. It is made only by
//! [`pm_crypto_group_b6_create`] and joined only by
//! [`pm_crypto_group_b6_join`]; [`super::pm_crypto_group_join`] refuses a
//! Welcome that carries the marker, and
//! [`super::pm_crypto_group_b6_media_key`] refuses any other group.

use super::{
    borrowed, ffi_call, with_device, PmCryptoHandle, MAX_HANDSHAKE_BYTES, MAX_ID_BYTES,
    PM_CRYPTO_ERROR, PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE,
};
use crate::{mls::MlsError, PmByteSlice};

/// ABI 28 (B6): creates and persists a call group under `group_id`, bound
/// to `call_id` and the parent `conversation_id` (each 1 to 128 bytes).
/// Nothing is stored on failure.
///
/// # Safety
/// `handle` must be live and every slice readable for the call.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_b6_create(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    call_id: PmByteSlice,
    conversation_id: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let call_id = unsafe { borrowed(call_id, crate::b6::MAX_ID_BYTES)? };
        let conversation_id = unsafe { borrowed(conversation_id, crate::b6::MAX_ID_BYTES)? };
        unsafe {
            with_device(handle, |device| {
                device
                    .create_call_group(group_id, call_id, conversation_id)
                    .map(|_| ())
                    .map_err(|_| PM_CRYPTO_ERROR)
            })
        }
    })
}

/// ABI 28 (B6): joins and persists the call group a Welcome carries, only
/// when its context is exactly the call-group genesis list for `call_id`
/// and `conversation_id` (the room this device asked to join).
/// `PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE` when the Welcome names no
/// key package this device holds (it is for someone else);
/// `PM_CRYPTO_ERROR` for every refusal, a wrong call or conversation
/// included. Nothing is stored on failure. The usual
/// [`super::pm_crypto_group_join`] rules apply too.
///
/// # Safety
/// `handle` must be live and every slice readable for the call.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_b6_join(
    handle: *mut PmCryptoHandle,
    expected_group_id: PmByteSlice,
    welcome: PmByteSlice,
    call_id: PmByteSlice,
    conversation_id: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let expected_group_id = unsafe { borrowed(expected_group_id, MAX_ID_BYTES)? };
        let welcome = unsafe { borrowed(welcome, MAX_HANDSHAKE_BYTES)? };
        let call_id = unsafe { borrowed(call_id, crate::b6::MAX_ID_BYTES)? };
        let conversation_id = unsafe { borrowed(conversation_id, crate::b6::MAX_ID_BYTES)? };
        unsafe {
            with_device(handle, |device| {
                device
                    .join_call_group(expected_group_id, welcome, call_id, conversation_id)
                    .map(|_| ())
                    .map_err(|error| match error {
                        MlsError::KeyPackageUnavailable => {
                            PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE
                        }
                        _ => PM_CRYPTO_ERROR,
                    })
            })
        }
    })
}
