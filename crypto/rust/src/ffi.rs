use crate::{mls::MlsDevice, PmByteSlice};
use core::ptr;
use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    sync::Mutex,
};

pub const PM_CRYPTO_OK: i32 = 0;
pub const PM_CRYPTO_INVALID_ARGUMENT: i32 = -2;
pub const PM_CRYPTO_ERROR: i32 = -3;
pub const PM_CRYPTO_PANIC: i32 = -4;

const MAX_ID_BYTES: usize = 128;
const STATE_KEY_BYTES: usize = 32;
const MAX_STATE_BYTES: usize = 32 * 1024 * 1024;
const MAX_CHALLENGE_BYTES: usize = 4096;
const MAX_KEY_PACKAGE_BYTES: usize = 48 * 1024;
const MAX_HANDSHAKE_BYTES: usize = 4 * 1024 * 1024;
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;

/// Opaque, library-owned device state. Callers receive only a pointer and must
/// destroy it exactly once with [`pm_crypto_device_destroy`].
pub struct PmCryptoHandle {
    device: Mutex<MlsDevice>,
}

/// Library-owned output. The caller must release it exactly once with
/// [`pm_crypto_buffer_free`]. Empty output is represented by a null pointer and
/// zero length.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct PmOwnedBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl Default for PmOwnedBuffer {
    fn default() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
        }
    }
}

fn ffi_call(operation: impl FnOnce() -> Result<(), i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => PM_CRYPTO_OK,
        Ok(Err(code)) => code,
        Err(_) => PM_CRYPTO_PANIC,
    }
}

unsafe fn borrowed<'a>(input: PmByteSlice, maximum: usize) -> Result<&'a [u8], i32> {
    if input.len == 0 || input.len > maximum || input.data.is_null() {
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    // SAFETY: The caller promises that non-null input memory is readable for
    // the duration of this FFI call; length was bounded above.
    Ok(unsafe { core::slice::from_raw_parts(input.data, input.len) })
}

unsafe fn output(target: *mut PmOwnedBuffer, bytes: Vec<u8>) -> Result<(), i32> {
    if target.is_null() || bytes.is_empty() {
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let data = Box::into_raw(boxed).cast::<u8>();
    // SAFETY: The caller provides writable storage for one PmOwnedBuffer.
    unsafe { target.write(PmOwnedBuffer { data, len }) };
    Ok(())
}

unsafe fn two_outputs(
    first_target: *mut PmOwnedBuffer,
    first: Vec<u8>,
    second_target: *mut PmOwnedBuffer,
    second: Vec<u8>,
) -> Result<(), i32> {
    if first_target.is_null() || second_target.is_null() || first.is_empty() || second.is_empty() {
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    let first = first.into_boxed_slice();
    let second = second.into_boxed_slice();
    let first_buffer = PmOwnedBuffer {
        len: first.len(),
        data: Box::into_raw(first).cast::<u8>(),
    };
    let second_buffer = PmOwnedBuffer {
        len: second.len(),
        data: Box::into_raw(second).cast::<u8>(),
    };
    // SAFETY: Both targets were checked before either is written.
    unsafe {
        first_target.write(first_buffer);
        second_target.write(second_buffer);
    }
    Ok(())
}

unsafe fn three_outputs(targets: [*mut PmOwnedBuffer; 3], values: [Vec<u8>; 3]) -> Result<(), i32> {
    if targets.iter().any(|target| target.is_null()) || values.iter().any(|value| value.is_empty())
    {
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    let [first, second, third] = values.map(Vec::into_boxed_slice);
    let buffers = [first, second, third].map(|value| PmOwnedBuffer {
        len: value.len(),
        data: Box::into_raw(value).cast::<u8>(),
    });
    // SAFETY: Every target was checked before any output is written.
    unsafe {
        targets[0].write(buffers[0]);
        targets[1].write(buffers[1]);
        targets[2].write(buffers[2]);
    }
    Ok(())
}

unsafe fn with_device<T>(
    handle: *mut PmCryptoHandle,
    operation: impl FnOnce(&MlsDevice) -> Result<T, i32>,
) -> Result<T, i32> {
    let handle = unsafe { handle.as_ref() }.ok_or(PM_CRYPTO_INVALID_ARGUMENT)?;
    let guard = handle.device.lock().map_err(|_| PM_CRYPTO_ERROR)?;
    operation(&guard)
}

/// Creates a device identity bound to the supplied reserved account/device IDs.
///
/// # Safety
/// All slices must remain readable for the call. `out_handle` must point to
/// writable pointer storage and must be destroyed exactly once on success.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_create(
    account_id: PmByteSlice,
    device_id: PmByteSlice,
    out_handle: *mut *mut PmCryptoHandle,
) -> i32 {
    ffi_call(|| {
        if out_handle.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let account_id = unsafe { borrowed(account_id, MAX_ID_BYTES)? };
        let device_id = unsafe { borrowed(device_id, MAX_ID_BYTES)? };
        let device = MlsDevice::new(account_id, device_id).map_err(|_| PM_CRYPTO_ERROR)?;
        let handle = Box::into_raw(Box::new(PmCryptoHandle {
            device: Mutex::new(device),
        }));
        // SAFETY: out_handle was checked and points to caller-owned writable
        // pointer storage for this call.
        unsafe { out_handle.write(handle) };
        Ok(())
    })
}

/// Restores a sealed device after checking its identity and rollback counter.
///
/// # Safety
/// All slices must remain readable for the call. Output pointers must be valid
/// writable storage. The returned handle must be destroyed exactly once.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_restore(
    account_id: PmByteSlice,
    device_id: PmByteSlice,
    state_key: PmByteSlice,
    minimum_counter: u64,
    sealed_state: PmByteSlice,
    out_handle: *mut *mut PmCryptoHandle,
    out_counter: *mut u64,
) -> i32 {
    ffi_call(|| {
        if out_handle.is_null() || out_counter.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let account_id = unsafe { borrowed(account_id, MAX_ID_BYTES)? };
        let device_id = unsafe { borrowed(device_id, MAX_ID_BYTES)? };
        let state_key = unsafe { borrowed(state_key, STATE_KEY_BYTES)? };
        if state_key.len() != STATE_KEY_BYTES {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let sealed = unsafe { borrowed(sealed_state, MAX_STATE_BYTES)? };
        let (device, counter) =
            MlsDevice::restore_state(account_id, device_id, state_key, minimum_counter, sealed)
                .map_err(|_| PM_CRYPTO_ERROR)?;
        let handle = Box::into_raw(Box::new(PmCryptoHandle {
            device: Mutex::new(device),
        }));
        // SAFETY: Both outputs were checked and are written only after a full
        // restore succeeds.
        unsafe {
            out_counter.write(counter);
            out_handle.write(handle);
        }
        Ok(())
    })
}

/// Destroys a device handle.
///
/// # Safety
/// `handle` must be null or a live pointer returned by this library. A live
/// pointer may be passed exactly once and must not be used after this call.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_destroy(handle: *mut PmCryptoHandle) {
    if !handle.is_null() {
        // SAFETY: Ownership is transferred back by the caller exactly once.
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Releases and zeroes a library-owned output buffer.
///
/// # Safety
/// A non-empty buffer must come from this library and be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_buffer_free(buffer: PmOwnedBuffer) {
    if buffer.data.is_null() || buffer.len == 0 {
        return;
    }
    let raw = ptr::slice_from_raw_parts_mut(buffer.data, buffer.len);
    // SAFETY: Ownership is transferred back by the caller exactly once.
    let mut boxed = unsafe { Box::from_raw(raw) };
    boxed.fill(0);
}

/// Returns the public Ed25519 key used by the MLS credential.
///
/// # Safety
/// `handle` must be live and `out` must point to writable buffer storage.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_signing_public_key(
    handle: *mut PmCryptoHandle,
    out: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let bytes =
            unsafe { with_device(handle, |device| Ok(device.signing_public_key().to_vec()))? };
        unsafe { output(out, bytes) }
    })
}

/// Signs the server-provided, domain-separated enrollment challenge.
///
/// # Safety
/// `handle` must be live, the challenge readable, and `out` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_sign_enrollment_challenge(
    handle: *mut PmCryptoHandle,
    challenge: PmByteSlice,
    out: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let challenge = unsafe { borrowed(challenge, MAX_CHALLENGE_BYTES)? };
        let signature = unsafe {
            with_device(handle, |device| {
                device
                    .sign_enrollment_challenge(challenge)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe { output(out, signature) }
    })
}

/// Creates a signed, single-use MLS key package for this device.
///
/// # Safety
/// `handle` must be live and `out` must point to writable buffer storage.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_create_key_package(
    handle: *mut PmCryptoHandle,
    out: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let package = unsafe {
            with_device(handle, |device| {
                device.create_key_package().map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe { output(out, package) }
    })
}

/// Creates the key package and signs its enrollment proof in one operation.
///
/// # Safety
/// `handle` must be live, `challenge` readable, and all outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_create_enrollment_credential(
    handle: *mut PmCryptoHandle,
    challenge: PmByteSlice,
    out_key_package: *mut PmOwnedBuffer,
    out_signing_public_key: *mut PmOwnedBuffer,
    out_challenge_signature: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_key_package.is_null()
            || out_signing_public_key.is_null()
            || out_challenge_signature.is_null()
        {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let challenge = unsafe { borrowed(challenge, MAX_CHALLENGE_BYTES)? };
        let credential = unsafe {
            with_device(handle, |device| {
                device
                    .create_enrollment_credential(challenge)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe {
            three_outputs(
                [
                    out_key_package,
                    out_signing_public_key,
                    out_challenge_signature,
                ],
                [
                    credential.key_package,
                    credential.signing_public_key,
                    credential.challenge_signature,
                ],
            )
        }
    })
}

/// Seals all provider state under the platform-unwrapped state key.
///
/// # Safety
/// `handle` must be live, `state_key` readable, and `out` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_seal_state(
    handle: *mut PmCryptoHandle,
    state_key: PmByteSlice,
    counter: u64,
    out: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let key = unsafe { borrowed(state_key, STATE_KEY_BYTES)? };
        if key.len() != STATE_KEY_BYTES || counter == 0 {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let sealed = unsafe {
            with_device(handle, |device| {
                device.seal_state(key, counter).map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe { output(out, sealed) }
    })
}

/// Creates and persists a new MLS group for `group_id`.
///
/// # Safety
/// `handle` must be live and `group_id` readable for the call.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_create(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        unsafe {
            with_device(handle, |device| {
                device
                    .create_group(group_id)
                    .map(|_| ())
                    .map_err(|_| PM_CRYPTO_ERROR)
            })
        }
    })
}

/// Joins and persists the group carried by an MLS Welcome.
///
/// # Safety
/// `handle` must be live and `welcome` readable for the call.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_join(
    handle: *mut PmCryptoHandle,
    welcome: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let welcome = unsafe { borrowed(welcome, MAX_HANDSHAKE_BYTES)? };
        unsafe {
            with_device(handle, |device| {
                device
                    .join_group(welcome)
                    .map(|_| ())
                    .map_err(|_| PM_CRYPTO_ERROR)
            })
        }
    })
}

/// Adds one verified key package and returns the commit and Welcome.
///
/// # Safety
/// `handle` must be live, slices readable, and both outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_add_member(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    key_package: PmByteSlice,
    out_commit: *mut PmOwnedBuffer,
    out_welcome: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_commit.is_null() || out_welcome.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let key_package = unsafe { borrowed(key_package, MAX_KEY_PACKAGE_BYTES)? };
        let messages = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                let messages = device
                    .add_member(&mut group, key_package)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .merge_pending_commit(&mut group)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                Ok(messages)
            })?
        };
        unsafe { two_outputs(out_commit, messages.commit, out_welcome, messages.welcome) }
    })
}

/// Applies and persists a remote MLS commit.
///
/// # Safety
/// `handle` must be live and both slices readable for the call.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_process_commit(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    commit: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let commit = unsafe { borrowed(commit, MAX_HANDSHAKE_BYTES)? };
        unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .process_commit(&mut group, commit)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })
        }
    })
}

/// Rotates this member's leaf and returns the committed update message.
///
/// # Safety
/// `handle` must be live, `group_id` readable, and `out_commit` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_self_update(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    out_commit: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let commit = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                let commit = device
                    .self_update(&mut group)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .merge_pending_commit(&mut group)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                Ok(commit)
            })?
        };
        unsafe { output(out_commit, commit) }
    })
}

/// Removes the account/device credential and returns the committed removal.
///
/// # Safety
/// `handle` must be live, slices readable, and `out_commit` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_remove_member(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    account_id: PmByteSlice,
    device_id: PmByteSlice,
    out_commit: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let account_id = unsafe { borrowed(account_id, MAX_ID_BYTES)? };
        let device_id = unsafe { borrowed(device_id, MAX_ID_BYTES)? };
        let commit = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                let index = device
                    .member_index(&group, account_id, device_id)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                let commit = device
                    .remove_member(&mut group, index)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .merge_pending_commit(&mut group)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                Ok(commit)
            })?
        };
        unsafe { output(out_commit, commit) }
    })
}

/// Encrypts one padded application payload in the current group epoch.
///
/// # Safety
/// `handle` must be live, slices readable, and `out_ciphertext` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_encrypt(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    plaintext: PmByteSlice,
    out_ciphertext: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let plaintext = unsafe { borrowed(plaintext, MAX_MESSAGE_BYTES)? };
        let ciphertext = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .encrypt(&mut group, plaintext)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe { output(out_ciphertext, ciphertext) }
    })
}

/// Decrypts and authenticates one MLS application message.
///
/// # Safety
/// `handle` must be live, slices readable, and `out_plaintext` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_decrypt(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    ciphertext: PmByteSlice,
    out_plaintext: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let ciphertext = unsafe { borrowed(ciphertext, MAX_MESSAGE_BYTES)? };
        let plaintext = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .decrypt(&mut group, ciphertext)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe { output(out_plaintext, plaintext) }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slice(bytes: &[u8]) -> PmByteSlice {
        PmByteSlice {
            data: bytes.as_ptr(),
            len: bytes.len(),
        }
    }

    unsafe fn take(buffer: PmOwnedBuffer) -> Vec<u8> {
        let value = unsafe { core::slice::from_raw_parts(buffer.data, buffer.len) }.to_vec();
        unsafe { pm_crypto_buffer_free(buffer) };
        value
    }

    #[test]
    fn handle_ownership_state_restore_and_outputs_round_trip() {
        let mut handle = ptr::null_mut();
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b"acct_a"), slice(b"dev_a"), &mut handle) },
            PM_CRYPTO_OK
        );
        assert!(!handle.is_null());

        let mut public_key = PmOwnedBuffer::default();
        assert_eq!(
            unsafe { pm_crypto_device_signing_public_key(handle, &mut public_key) },
            PM_CRYPTO_OK
        );
        assert_eq!(unsafe { take(public_key) }.len(), 32);

        let mut enrollment_package = PmOwnedBuffer::default();
        let mut enrollment_key = PmOwnedBuffer::default();
        let mut enrollment_signature = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_device_create_enrollment_credential(
                    handle,
                    slice(b"reserved challenge"),
                    &mut enrollment_package,
                    &mut enrollment_key,
                    &mut enrollment_signature,
                )
            },
            PM_CRYPTO_OK
        );
        assert!(unsafe { take(enrollment_package) }.len() >= crate::MIN_KEY_PACKAGE_BYTES);
        assert_eq!(unsafe { take(enrollment_key) }.len(), 32);
        assert_eq!(unsafe { take(enrollment_signature) }.len(), 64);

        let mut package = PmOwnedBuffer::default();
        assert_eq!(
            unsafe { pm_crypto_device_create_key_package(handle, &mut package) },
            PM_CRYPTO_OK
        );
        assert!(unsafe { take(package) }.len() >= crate::MIN_KEY_PACKAGE_BYTES);

        let key = [9_u8; STATE_KEY_BYTES];
        let mut sealed = PmOwnedBuffer::default();
        assert_eq!(
            unsafe { pm_crypto_device_seal_state(handle, slice(&key), 7, &mut sealed) },
            PM_CRYPTO_OK
        );
        let sealed = unsafe { take(sealed) };
        unsafe { pm_crypto_device_destroy(handle) };

        let mut restored = ptr::null_mut();
        let mut counter = 0;
        assert_eq!(
            unsafe {
                pm_crypto_device_restore(
                    slice(b"acct_a"),
                    slice(b"dev_a"),
                    slice(&key),
                    7,
                    slice(&sealed),
                    &mut restored,
                    &mut counter,
                )
            },
            PM_CRYPTO_OK
        );
        assert_eq!(counter, 7);
        unsafe { pm_crypto_device_destroy(restored) };
    }

    #[test]
    fn invalid_ffi_inputs_fail_without_partial_outputs() {
        let mut handle = ptr::null_mut();
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b""), slice(b"dev_a"), &mut handle) },
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert!(handle.is_null());
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b"acct_a"), slice(b"dev_a"), ptr::null_mut()) },
            PM_CRYPTO_INVALID_ARGUMENT
        );
    }

    #[test]
    fn ffi_group_lifecycle_exchanges_and_revokes_messages() {
        let mut alice = ptr::null_mut();
        let mut bob = ptr::null_mut();
        assert_eq!(
            unsafe {
                pm_crypto_device_create(slice(b"acct_alice"), slice(b"dev_alice"), &mut alice)
            },
            PM_CRYPTO_OK
        );
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b"acct_bob"), slice(b"dev_bob"), &mut bob) },
            PM_CRYPTO_OK
        );
        let mut bob_package = PmOwnedBuffer::default();
        assert_eq!(
            unsafe { pm_crypto_device_create_key_package(bob, &mut bob_package) },
            PM_CRYPTO_OK
        );
        let bob_package = unsafe { take(bob_package) };
        assert_eq!(
            unsafe { pm_crypto_group_create(alice, slice(b"conv_test")) },
            PM_CRYPTO_OK
        );
        let mut commit = PmOwnedBuffer::default();
        let mut welcome = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_group_add_member(
                    alice,
                    slice(b"conv_test"),
                    slice(&bob_package),
                    &mut commit,
                    &mut welcome,
                )
            },
            PM_CRYPTO_OK
        );
        let commit = unsafe { take(commit) };
        let welcome = unsafe { take(welcome) };
        assert!(!commit.is_empty());
        assert_eq!(
            unsafe { pm_crypto_group_join(bob, slice(&welcome)) },
            PM_CRYPTO_OK
        );

        let mut ciphertext = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_group_encrypt(
                    alice,
                    slice(b"conv_test"),
                    slice(b"authenticated payload"),
                    &mut ciphertext,
                )
            },
            PM_CRYPTO_OK
        );
        let ciphertext = unsafe { take(ciphertext) };
        let mut plaintext = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_group_decrypt(
                    bob,
                    slice(b"conv_test"),
                    slice(&ciphertext),
                    &mut plaintext,
                )
            },
            PM_CRYPTO_OK
        );
        assert_eq!(unsafe { take(plaintext) }, b"authenticated payload");

        let mut removal = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_group_remove_member(
                    alice,
                    slice(b"conv_test"),
                    slice(b"acct_bob"),
                    slice(b"dev_bob"),
                    &mut removal,
                )
            },
            PM_CRYPTO_OK
        );
        let removal = unsafe { take(removal) };
        assert_eq!(
            unsafe { pm_crypto_group_process_commit(bob, slice(b"conv_test"), slice(&removal)) },
            PM_CRYPTO_OK
        );
        let mut forbidden = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_group_encrypt(
                    bob,
                    slice(b"conv_test"),
                    slice(b"must fail"),
                    &mut forbidden,
                )
            },
            PM_CRYPTO_ERROR
        );
        assert!(forbidden.data.is_null());
        unsafe {
            pm_crypto_device_destroy(alice);
            pm_crypto_device_destroy(bob);
        }
    }
}
