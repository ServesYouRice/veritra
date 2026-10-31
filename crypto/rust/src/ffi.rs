use crate::{
    attachment,
    mls::{
        ChangeSet, MemberAdd, MemberIdentity, MlsDevice, MlsError, RestoreLoader, SealError,
        MAX_SEALED_RECORD_BYTES, MAX_SEALED_ROOT_BYTES,
    },
    PmByteSlice,
};
use core::ptr;
use std::{
    collections::HashMap,
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock, Weak,
    },
};

mod k2;

pub const PM_CRYPTO_OK: i32 = 0;
pub const PM_CRYPTO_INVALID_ARGUMENT: i32 = -2;
pub const PM_CRYPTO_ERROR: i32 = -3;
pub const PM_CRYPTO_PANIC: i32 = -4;
/// Decryption succeeded but the MLS sender is not the claimed account/device.
/// The group ratchet has already advanced past the message.
pub const PM_CRYPTO_SENDER_MISMATCH: i32 = -5;
/// Sealed state with a format version this build does not read (ABI 9). The
/// version is not authenticated: use it only to offer re-linking the
/// device, never to relax a check. Every other restore failure stays
/// [`PM_CRYPTO_ERROR`].
pub const PM_CRYPTO_STATE_FORMAT_UNSUPPORTED: i32 = -6;
/// Decryption succeeded from a retained past epoch, but the sender is no
/// longer a member of the group (ABI 9). The ratchet has already advanced;
/// handle it like [`PM_CRYPTO_SENDER_MISMATCH`]: commit, show no content.
pub const PM_CRYPTO_SENDER_REMOVED: i32 = -7;
/// A sealed record would be over its cap (ABI 10, D70). Nothing was sealed
/// and nothing is stored; the output buffer holds `u8 kind || id` so the
/// app can name the chat. The caller restores the committed state.
pub const PM_CRYPTO_RECORD_LIMIT: i32 = -8;
/// The Welcome names no key package this device holds, or the one it names
/// has expired (ABI 10, D74). Nothing was consumed: the device is not in
/// the group and has to be added again.
pub const PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE: i32 = -9;

const MAX_ID_BYTES: usize = 128;
const STATE_KEY_BYTES: usize = 32;
/// Largest format 2/3 blob the migration reads (the ABI-9 restore bound).
const MAX_LEGACY_STATE_BYTES: usize = 32 * 1024 * 1024;
/// Largest change set pm_crypto_device_seal_changes returns. A full set
/// after migration holds every record, so it is above one record's cap.
const MAX_CHANGE_SET_BYTES: usize = 128 * 1024 * 1024;
const MAX_CHALLENGE_BYTES: usize = 4096;
const MAX_KEY_PACKAGE_BYTES: usize = 48 * 1024;
const MAX_HANDSHAKE_BYTES: usize = 4 * 1024 * 1024;
/// Largest application plaintext pm_crypto_group_encrypt accepts.
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
/// Largest MLS application ciphertext pm_crypto_group_decrypt accepts. The
/// margin covers padding to 256 bytes, the framing (group id of at most 128
/// bytes, epoch, encrypted sender data), the AEAD tag, the Ed25519 signature
/// and the length prefixes; a MAX_MESSAGE_BYTES plaintext needs 312 bytes of
/// it with an 8-byte group id (tested). Encrypt refuses output above it, so every successful
/// encrypt can be decrypted.
const MAX_CIPHERTEXT_BYTES: usize = MAX_MESSAGE_BYTES + 4096;
const ATTACHMENT_KEY_BYTES: usize = 32;
const MEMBERSHIP_CHANGES_VERSION: u8 = 1;
const MAX_MEMBERSHIP_CHANGES: usize = 256;
const ATTACHMENT_NONCE_PREFIX_BYTES: usize = 8;

/// Opaque, library-owned device state. Callers receive only a pointer and must
/// destroy it exactly once with [`pm_crypto_device_destroy`].
pub struct PmCryptoHandle {
    device: Arc<Mutex<MlsDevice>>,
    active_stream: Mutex<Weak<Mutex<k2::streams::StreamState>>>,
}

impl Drop for PmCryptoHandle {
    fn drop(&mut self) {
        k2::streams::invalidate(self);
    }
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

/// Drops a Vec through a non-elidable wipe of its whole capacity.
fn wipe(bytes: Vec<u8>) {
    drop(tls_codec::SecretVLBytes::new(bytes));
}

/// Hands `bytes` over as a library-owned buffer of exactly its length. A Vec
/// with spare capacity is copied and the original wiped, instead of being
/// shrunk in place: a realloc may move the block and free the source with
/// its contents intact. Empty input stays (null, 0).
fn into_owned(bytes: Vec<u8>) -> PmOwnedBuffer {
    if bytes.is_empty() {
        wipe(bytes);
        return PmOwnedBuffer::default();
    }
    let boxed = if bytes.capacity() == bytes.len() {
        // No reallocation: capacity already equals length.
        bytes.into_boxed_slice()
    } else {
        let copy = Box::<[u8]>::from(bytes.as_slice());
        wipe(bytes);
        copy
    };
    PmOwnedBuffer {
        len: boxed.len(),
        data: Box::into_raw(boxed).cast::<u8>(),
    }
}

unsafe fn output(target: *mut PmOwnedBuffer, bytes: Vec<u8>) -> Result<(), i32> {
    if target.is_null() || bytes.is_empty() {
        wipe(bytes);
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    let buffer = into_owned(bytes);
    // SAFETY: The caller provides writable storage for one PmOwnedBuffer.
    unsafe { target.write(buffer) };
    Ok(())
}

unsafe fn two_outputs(
    first_target: *mut PmOwnedBuffer,
    first: Vec<u8>,
    second_target: *mut PmOwnedBuffer,
    second: Vec<u8>,
) -> Result<(), i32> {
    if first_target.is_null() || second_target.is_null() || first.is_empty() || second.is_empty() {
        wipe(first);
        wipe(second);
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    let first_buffer = into_owned(first);
    let second_buffer = into_owned(second);
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
        values.into_iter().for_each(wipe);
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    let buffers = values.map(into_owned);
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

unsafe fn with_device_mut<T>(
    handle: *mut PmCryptoHandle,
    operation: impl FnOnce(&mut MlsDevice) -> Result<T, i32>,
) -> Result<T, i32> {
    let handle = unsafe { handle.as_ref() }.ok_or(PM_CRYPTO_INVALID_ARGUMENT)?;
    let mut guard = handle.device.lock().map_err(|_| PM_CRYPTO_ERROR)?;
    operation(&mut guard)
}

fn new_handle(device: MlsDevice) -> *mut PmCryptoHandle {
    Box::into_raw(Box::new(PmCryptoHandle {
        device: Arc::new(Mutex::new(device)),
        active_stream: Mutex::new(Weak::new()),
    }))
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
            device: Arc::new(Mutex::new(device)),
            active_stream: Mutex::new(Weak::new()),
        }));
        // SAFETY: out_handle was checked and points to caller-owned writable
        // pointer storage for this call.
        unsafe { out_handle.write(handle) };
        Ok(())
    })
}

/// Restores in progress, by token (ABI 10). A token is never reused; each
/// entry leaves on finish or abort.
fn loaders() -> &'static Mutex<HashMap<u64, RestoreLoader>> {
    static LOADERS: OnceLock<Mutex<HashMap<u64, RestoreLoader>>> = OnceLock::new();
    LOADERS.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_LOADER: AtomicU64 = AtomicU64::new(1);

/// At most this many restores may be open at once, so a caller that never
/// finishes cannot grow the registry without bound.
const MAX_OPEN_LOADERS: usize = 16;

fn restore_error(error: MlsError) -> i32 {
    match error {
        MlsError::UnsupportedFormat => PM_CRYPTO_STATE_FORMAT_UNSUPPORTED,
        _ => PM_CRYPTO_ERROR,
    }
}

/// Starts a format-4 restore (D70): opens and checks the sealed root for
/// this account and device under `state_key`. Its generation must be at
/// least `minimum_generation`; it is written to `out_generation`, and the
/// caller must require it to equal its stored counter. Add every stored
/// record with [`pm_crypto_restore_add`], then call
/// [`pm_crypto_restore_finish`] or [`pm_crypto_restore_abort`]. Returns
/// [`PM_CRYPTO_STATE_FORMAT_UNSUPPORTED`] for a root in a format this build
/// does not read (a format 2/3 blob is migrated with
/// [`pm_crypto_device_migrate_v3`] instead).
///
/// # Safety
/// All slices must remain readable for the call. Output pointers must be
/// valid writable storage.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_restore_begin(
    account_id: PmByteSlice,
    device_id: PmByteSlice,
    state_key: PmByteSlice,
    minimum_generation: u64,
    sealed_root: PmByteSlice,
    out_loader: *mut u64,
    out_generation: *mut u64,
) -> i32 {
    ffi_call(|| {
        if out_loader.is_null() || out_generation.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let account_id = unsafe { borrowed(account_id, MAX_ID_BYTES)? };
        let device_id = unsafe { borrowed(device_id, MAX_ID_BYTES)? };
        let state_key = unsafe { borrowed(state_key, STATE_KEY_BYTES)? };
        if state_key.len() != STATE_KEY_BYTES {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let root = unsafe { borrowed(sealed_root, MAX_SEALED_ROOT_BYTES)? };
        let loader =
            RestoreLoader::begin(account_id, device_id, state_key, minimum_generation, root)
                .map_err(restore_error)?;
        let generation = loader.generation();
        let mut open = loaders().lock().map_err(|_| PM_CRYPTO_ERROR)?;
        if open.len() >= MAX_OPEN_LOADERS {
            return Err(PM_CRYPTO_ERROR);
        }
        let token = NEXT_LOADER.fetch_add(1, Ordering::Relaxed);
        open.insert(token, loader);
        // SAFETY: Both outputs were checked above.
        unsafe {
            out_loader.write(token);
            out_generation.write(generation);
        }
        Ok(())
    })
}

/// Adds one stored record to an open restore. It must be listed in the
/// root, not added before, and match its listed generation and digest.
/// Any failure poisons the restore: finish then fails too.
///
/// # Safety
/// `sealed_record` must remain readable for the call.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_restore_add(loader: u64, sealed_record: PmByteSlice) -> i32 {
    ffi_call(|| {
        let sealed = unsafe { borrowed(sealed_record, MAX_SEALED_RECORD_BYTES)? };
        let mut open = loaders().lock().map_err(|_| PM_CRYPTO_ERROR)?;
        let loader = open.get_mut(&loader).ok_or(PM_CRYPTO_INVALID_ARGUMENT)?;
        loader.add(sealed).map_err(|_| PM_CRYPTO_ERROR)
    })
}

/// Ends an open restore. Succeeds only if every record the root lists was
/// added and checked; then writes a new device handle and the generation.
/// The token is spent either way.
///
/// # Safety
/// Output pointers must be valid writable storage. The returned handle
/// must be destroyed exactly once.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_restore_finish(
    loader: u64,
    out_handle: *mut *mut PmCryptoHandle,
    out_generation: *mut u64,
) -> i32 {
    ffi_call(|| {
        let loader = loaders()
            .lock()
            .map_err(|_| PM_CRYPTO_ERROR)?
            .remove(&loader)
            .ok_or(PM_CRYPTO_INVALID_ARGUMENT)?;
        if out_handle.is_null() || out_generation.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let (device, generation) = loader.finish().map_err(|_| PM_CRYPTO_ERROR)?;
        // SAFETY: Both outputs were checked and are written only after the
        // whole state was restored.
        unsafe {
            out_generation.write(generation);
            out_handle.write(new_handle(device));
        }
        Ok(())
    })
}

/// Drops an open restore without a device. Returns
/// [`PM_CRYPTO_INVALID_ARGUMENT`] for a token that is not open.
#[no_mangle]
pub extern "C" fn pm_crypto_restore_abort(loader: u64) -> i32 {
    ffi_call(|| {
        let removed = loaders()
            .lock()
            .map_err(|_| PM_CRYPTO_ERROR)?
            .remove(&loader);
        removed.map(drop).ok_or(PM_CRYPTO_INVALID_ARGUMENT)
    })
}

/// Opens a format 2 or 3 blob for the one-way migration to format 4 (D70
/// section 5). Runs every check of the old restore and requires its
/// counter to equal `counter`. Inactive groups and key pairs no group owns
/// are dropped; their number is written to `out_dropped`. Every record of
/// the returned device is pending: the caller seals them with
/// [`pm_crypto_device_seal_changes`] at `counter + 1` and stores the root
/// and all records, deleting any records stored beside the old blob, in
/// one transaction. Returns [`PM_CRYPTO_STATE_FORMAT_UNSUPPORTED`] for any
/// other format.
///
/// # Safety
/// All slices must remain readable for the call. Output pointers must be
/// valid writable storage. The returned handle must be destroyed exactly
/// once.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_migrate_v3(
    account_id: PmByteSlice,
    device_id: PmByteSlice,
    state_key: PmByteSlice,
    counter: u64,
    sealed_state: PmByteSlice,
    out_handle: *mut *mut PmCryptoHandle,
    out_dropped: *mut u64,
) -> i32 {
    ffi_call(|| {
        if out_handle.is_null() || out_dropped.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let account_id = unsafe { borrowed(account_id, MAX_ID_BYTES)? };
        let device_id = unsafe { borrowed(device_id, MAX_ID_BYTES)? };
        let state_key = unsafe { borrowed(state_key, STATE_KEY_BYTES)? };
        if state_key.len() != STATE_KEY_BYTES || counter == 0 {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let sealed = unsafe { borrowed(sealed_state, MAX_LEGACY_STATE_BYTES)? };
        let (device, dropped) =
            MlsDevice::migrate_v3(account_id, device_id, state_key, counter, sealed)
                .map_err(restore_error)?;
        // SAFETY: Both outputs were checked above.
        unsafe {
            out_dropped.write(dropped as u64);
            out_handle.write(new_handle(device));
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
    let boxed = unsafe { Box::from_raw(raw) };
    // SecretVLBytes uses zeroize's non-elidable clearing on drop. Reuse the
    // exact allocation; no extra secret copy or competing allocator contract.
    let secret: tls_codec::SecretVLBytes = boxed.into_vec().into();
    drop(secret);
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

/// ABI v7: hash32 || claim_tag32 || approval_tag32 || sas_mac_prefix4.
///
/// The SAS shown to the user is the prefix as a big-endian integer modulo
/// 10^8: 8 digits, about 26.6 bits. The prefix and both tags are MACs keyed
/// from the 128-bit link secret, so a relay without the secret cannot grind
/// keys to match them; if the secret leaks, the 8 digits alone fall to about
/// 10^4 key generations per side. See
/// [`crate::mls::derive_device_link_verification`].
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_link_transcript_hash(
    handle: *mut PmCryptoHandle,
    protocol_version: PmByteSlice,
    server_origin: PmByteSlice,
    link_id: PmByteSlice,
    link_secret: PmByteSlice,
    peer_device_id: PmByteSlice,
    peer_signing_public_key: PmByteSlice,
    link_nonce: PmByteSlice,
    local_is_existing_device: u8,
    out: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if local_is_existing_device > 1 {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let protocol_version = unsafe { borrowed(protocol_version, 64)? };
        let server_origin = unsafe { borrowed(server_origin, 2048)? };
        let link_id = unsafe { borrowed(link_id, MAX_ID_BYTES)? };
        let link_secret = unsafe { borrowed(link_secret, 16)? };
        let peer_device_id = unsafe { borrowed(peer_device_id, MAX_ID_BYTES)? };
        let peer_signing_public_key = unsafe { borrowed(peer_signing_public_key, 32)? };
        let link_nonce = unsafe { borrowed(link_nonce, 32)? };
        if peer_signing_public_key.len() != 32 || link_nonce.len() != 32 {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let transcript_hash = unsafe {
            with_device(handle, |device| {
                device
                    .derive_device_link_verification(
                        protocol_version,
                        server_origin,
                        link_id,
                        link_secret,
                        peer_device_id,
                        peer_signing_public_key,
                        link_nonce,
                        local_is_existing_device == 1,
                    )
                    .map(|v| [v.transcript_hash, v.claim_tag, v.approval_tag, v.sas_bytes].concat())
                    .map_err(|_| PM_CRYPTO_INVALID_ARGUMENT)
            })?
        };
        unsafe { output(out, transcript_hash) }
    })
}

/// ABI v7 locator. `secret` must be readable and `out` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_link_locator(
    secret: PmByteSlice,
    out: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let secret = unsafe { borrowed(secret, 16)? };
        let locator =
            crate::mls::device_link_locator(secret).map_err(|_| PM_CRYPTO_INVALID_ARGUMENT)?;
        unsafe { output(out, locator) }
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

/// Frames a change set: `u32 root_len || root || u32 count`, then per
/// change `u8 kind || u16 id_len || id || u64 generation || u8 present`
/// and, when present, `u32 len || sealed`. Big-endian throughout.
fn encode_change_set(set: ChangeSet) -> Result<Vec<u8>, i32> {
    let mut size = 8usize.saturating_add(set.root.len());
    for change in &set.changes {
        size = size
            .saturating_add(16 + change.id.len())
            .saturating_add(change.sealed.as_ref().map_or(0, Vec::len));
    }
    if size > MAX_CHANGE_SET_BYTES
        || set
            .changes
            .iter()
            .any(|change| change.id.len() > usize::from(u16::MAX))
    {
        wipe_change_set(set);
        return Err(PM_CRYPTO_ERROR);
    }
    let mut out = Vec::with_capacity(size);
    out.extend_from_slice(&(set.root.len() as u32).to_be_bytes());
    out.extend_from_slice(&set.root);
    out.extend_from_slice(&(set.changes.len() as u32).to_be_bytes());
    for change in &set.changes {
        out.push(change.kind);
        out.extend_from_slice(&(change.id.len() as u16).to_be_bytes());
        out.extend_from_slice(&change.id);
        out.extend_from_slice(&change.generation.to_be_bytes());
        match &change.sealed {
            Some(sealed) => {
                out.push(1);
                out.extend_from_slice(&(sealed.len() as u32).to_be_bytes());
                out.extend_from_slice(sealed);
            }
            None => out.push(0),
        }
    }
    wipe_change_set(set);
    Ok(out)
}

fn wipe_change_set(set: ChangeSet) {
    wipe(set.root);
    for change in set.changes {
        if let Some(sealed) = change.sealed {
            wipe(sealed);
        }
    }
}

/// Seals what changed since the last seal or restore (ABI 10, D70) at
/// `generation`, which must be the stored counter plus one. The output is
/// the root and every changed record ([`encode_change_set`]); the caller
/// stores all of it, with the root at `generation`, in one transaction.
/// Returns [`PM_CRYPTO_RECORD_LIMIT`] with `u8 kind || id` in `out` when a
/// record would be over its cap. After any failure, and after a store that
/// did not commit, the caller restores the committed state before going on.
///
/// # Safety
/// `handle` must be live, `state_key` readable, and `out` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_seal_changes(
    handle: *mut PmCryptoHandle,
    state_key: PmByteSlice,
    generation: u64,
    out: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let key = unsafe { borrowed(state_key, STATE_KEY_BYTES)? };
        if key.len() != STATE_KEY_BYTES || generation == 0 || out.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let sealed = unsafe {
            with_device_mut(handle, |device| {
                match device.seal_changes(key, generation) {
                    Ok(set) => encode_change_set(set).map(Ok),
                    Err(SealError::RecordLimit { kind, id }) => {
                        let mut named = vec![kind];
                        named.extend_from_slice(&id);
                        Ok(Err(named))
                    }
                    Err(SealError::Mls(_)) => Err(PM_CRYPTO_ERROR),
                }
            })?
        };
        match sealed {
            Ok(bytes) => unsafe { output(out, bytes) },
            Err(named) => {
                unsafe { output(out, named)? };
                Err(PM_CRYPTO_RECORD_LIMIT)
            }
        }
    })
}

/// Deletes this device's state for `group_id` (D70): the user deleted the
/// chat. Writes 1 to `out_deleted` if a group was stored, else 0. The next
/// seal drops its record. Only a user action may call this: a group left
/// by a removal is already gone.
///
/// # Safety
/// `handle` must be live, `group_id` readable, and `out_deleted` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_delete(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    out_deleted: *mut u8,
) -> i32 {
    ffi_call(|| {
        if out_deleted.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let deleted = unsafe {
            with_device(handle, |device| {
                device.delete_group(group_id).map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        // SAFETY: out_deleted was checked above.
        unsafe { out_deleted.write(u8::from(deleted)) };
        Ok(())
    })
}

/// Drops every key package whose `not_after` passed more than 24 hours
/// before `now_unix_seconds` (D70). Writes how many went to `out_removed`.
///
/// # Safety
/// `handle` must be live and `out_removed` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_device_prune_key_packages(
    handle: *mut PmCryptoHandle,
    now_unix_seconds: u64,
    out_removed: *mut u64,
) -> i32 {
    ffi_call(|| {
        if out_removed.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let removed = unsafe {
            with_device(handle, |device| {
                device
                    .prune_key_packages(now_unix_seconds)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        // SAFETY: out_removed was checked above.
        unsafe { out_removed.write(removed as u64) };
        Ok(())
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

/// Joins and persists the group carried by an MLS Welcome. A stored group
/// under the same id (a re-add after a removal) is replaced only when it is
/// inactive, that is, this device applied its own removal
/// (`MlsDevice::join_group`).
///
/// # Safety
/// `handle` must be live and `welcome` readable for the call.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_join(
    handle: *mut PmCryptoHandle,
    expected_group_id: PmByteSlice,
    welcome: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let expected_group_id = unsafe { borrowed(expected_group_id, MAX_ID_BYTES)? };
        let welcome = unsafe { borrowed(welcome, MAX_HANDSHAKE_BYTES)? };
        unsafe {
            with_device(handle, |device| {
                device
                    .join_group(expected_group_id, welcome)
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

/// Adds one verified key package and returns the commit and Welcome.
/// Deprecated, tests only: it merges before the server accepts the commit,
/// so a lost epoch race forks this device. The app stages through
/// [`pm_crypto_group_stage_commit`].
///
/// # Safety
/// `handle` must be live, slices readable, and both outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_add_member(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    key_package: PmByteSlice,
    expected_account_id: PmByteSlice,
    expected_device_id: PmByteSlice,
    out_commit: *mut PmOwnedBuffer,
    out_welcome: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_commit.is_null() || out_welcome.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let key_package = unsafe { borrowed(key_package, MAX_KEY_PACKAGE_BYTES)? };
        let expected_account_id = unsafe { borrowed(expected_account_id, MAX_ID_BYTES)? };
        let expected_device_id = unsafe { borrowed(expected_device_id, MAX_ID_BYTES)? };
        let messages = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                let messages = device
                    .add_member(
                        &mut group,
                        key_package,
                        expected_account_id,
                        expected_device_id,
                    )
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

/// Parsed form of the membership change list passed to
/// [`pm_crypto_group_stage_commit`]:
///
/// ```text
/// version:u8 (=1) add_count:u16 { kp_len:u32 kp account_len:u16 account
///   device_len:u16 device }* remove_count:u16 { account_len:u16 account
///   device_len:u16 device }*
/// ```
///
/// All integers are big-endian. Trailing bytes are rejected.
struct MembershipChanges<'a> {
    adds: Vec<MemberAdd<'a>>,
    removes: Vec<MemberIdentity<'a>>,
}

fn parse_membership_changes(input: &[u8]) -> Result<MembershipChanges<'_>, i32> {
    struct Reader<'a> {
        input: &'a [u8],
        offset: usize,
    }
    impl<'a> Reader<'a> {
        fn take(&mut self, len: usize) -> Result<&'a [u8], i32> {
            let end = self
                .offset
                .checked_add(len)
                .ok_or(PM_CRYPTO_INVALID_ARGUMENT)?;
            let value = self
                .input
                .get(self.offset..end)
                .ok_or(PM_CRYPTO_INVALID_ARGUMENT)?;
            self.offset = end;
            Ok(value)
        }
        fn u16(&mut self) -> Result<usize, i32> {
            let bytes = self.take(2)?;
            Ok(u16::from_be_bytes([bytes[0], bytes[1]]) as usize)
        }
        fn u32(&mut self) -> Result<usize, i32> {
            let bytes = self.take(4)?;
            Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize)
        }
        fn id(&mut self) -> Result<&'a [u8], i32> {
            let len = self.u16()?;
            if len == 0 || len > MAX_ID_BYTES {
                return Err(PM_CRYPTO_INVALID_ARGUMENT);
            }
            self.take(len)
        }
    }
    let mut reader = Reader { input, offset: 0 };
    if reader.take(1)?[0] != MEMBERSHIP_CHANGES_VERSION {
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    let add_count = reader.u16()?;
    if add_count > MAX_MEMBERSHIP_CHANGES {
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    let mut adds = Vec::with_capacity(add_count);
    for _ in 0..add_count {
        let kp_len = reader.u32()?;
        if kp_len == 0 || kp_len > MAX_KEY_PACKAGE_BYTES {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let key_package = reader.take(kp_len)?;
        let account_id = reader.id()?;
        let device_id = reader.id()?;
        adds.push(MemberAdd {
            key_package,
            account_id,
            device_id,
        });
    }
    let remove_count = reader.u16()?;
    // An empty list (no adds, no removes) asks for a self-update commit.
    if remove_count > MAX_MEMBERSHIP_CHANGES {
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    let mut removes = Vec::with_capacity(remove_count);
    for _ in 0..remove_count {
        let account_id = reader.id()?;
        let device_id = reader.id()?;
        removes.push(MemberIdentity {
            account_id,
            device_id,
        });
    }
    if reader.offset != input.len() {
        return Err(PM_CRYPTO_INVALID_ARGUMENT);
    }
    Ok(MembershipChanges { adds, removes })
}

/// Stages one commit adding and removing devices, without merging it (ABI
/// 6, card I51). `out_welcome` is empty (null, 0) when nothing is added.
/// `out_epoch` receives the epoch the commit was built on. The caller merges
/// with [`pm_crypto_group_merge_pending_commit`] once the server accepts the
/// commit, or drops it with [`pm_crypto_group_clear_pending_commit`].
///
/// An empty change list (no adds and no removes) stages a self-update: a
/// commit with an update path and no proposals that refreshes this device's
/// leaf key (`MlsDevice::stage_self_update`). Before this, an empty list was
/// refused, so an older ABI 9 library still fails closed on it.
///
/// # Safety
/// `handle` must be live, slices readable, and all outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_stage_commit(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    changes: PmByteSlice,
    out_commit: *mut PmOwnedBuffer,
    out_welcome: *mut PmOwnedBuffer,
    out_epoch: *mut u64,
) -> i32 {
    ffi_call(|| {
        if out_commit.is_null() || out_welcome.is_null() || out_epoch.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let changes = unsafe { borrowed(changes, MAX_HANDSHAKE_BYTES)? };
        let changes = parse_membership_changes(changes)?;
        let staged = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                if changes.adds.is_empty() && changes.removes.is_empty() {
                    return device
                        .stage_self_update(&mut group)
                        .map_err(|_| PM_CRYPTO_ERROR);
                }
                device
                    .stage_membership_commit(&mut group, &changes.adds, &changes.removes)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        if staged.commit.is_empty() {
            wipe(staged.welcome);
            return Err(PM_CRYPTO_ERROR);
        }
        // All three targets were checked above, so nothing below can fail
        // after a buffer has been handed over.
        let commit = into_owned(staged.commit);
        let welcome = into_owned(staged.welcome);
        unsafe {
            out_commit.write(commit);
            out_welcome.write(welcome);
            out_epoch.write(staged.epoch);
        }
        Ok(())
    })
}

/// Merges this device's staged commit after the server accepted it. A group
/// without a staged commit is left as it is; the caller checks the epoch.
///
/// # Safety
/// `handle` must be live and `group_id` readable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_merge_pending_commit(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                if !device.has_pending_commit(&group) {
                    return Ok(());
                }
                device
                    .merge_pending_commit(&mut group)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })
        }
    })
}

/// Drops this device's staged commit after the server refused it.
///
/// # Safety
/// `handle` must be live and `group_id` readable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_clear_pending_commit(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .clear_pending_commit(&mut group)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })
        }
    })
}

/// Reports the group's current epoch and whether a staged commit waits.
///
/// # Safety
/// `handle` must be live, `group_id` readable, and both outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_epoch(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    out_epoch: *mut u64,
    out_pending: *mut u8,
) -> i32 {
    ffi_call(|| {
        if out_epoch.is_null() || out_pending.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let (epoch, pending) = unsafe {
            with_device(handle, |device| {
                let group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                Ok((
                    device.group_epoch(&group),
                    device.has_pending_commit(&group),
                ))
            })?
        };
        unsafe {
            out_epoch.write(epoch);
            out_pending.write(u8::from(pending));
        }
        Ok(())
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
/// It merges at once, before any server has accepted the commit, so a
/// commit that loses the epoch race forks this device from the group. The
/// app does not call it; it stages self-updates through
/// [`pm_crypto_group_stage_commit`] with an empty change list.
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
        // Checked before the merge, so a refused output never advances the group.
        if out_commit.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
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

/// Derives a server-independent safety transcript for the current group.
///
/// # Safety
/// `handle` must be live, `group_id` readable, and both outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_safety_number(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    out_hash: *mut PmOwnedBuffer,
    out_digits: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_hash.is_null() || out_digits.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let verification = unsafe {
            with_device(handle, |device| {
                let group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .conversation_safety_number(&group)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe {
            output(out_hash, verification.transcript_hash)?;
            output(out_digits, verification.sas.into_bytes())
        }
    })
}

/// Removes every leaf carrying the account/device credential and returns the
/// committed removal. Deprecated, tests only: it merges before the server
/// accepts the commit, so a lost epoch race forks this device. The app
/// stages through [`pm_crypto_group_stage_commit`].
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
        // Checked before the merge, so a refused output never advances the group.
        if out_commit.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let account_id = unsafe { borrowed(account_id, MAX_ID_BYTES)? };
        let device_id = unsafe { borrowed(device_id, MAX_ID_BYTES)? };
        let commit = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                // Every leaf carrying this identity goes.
                let leaves = device
                    .member_indices(&group, account_id, device_id)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                let commit = device
                    .remove_members(&mut group, &leaves)
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
        if out_ciphertext.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
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
        if ciphertext.len() > MAX_CIPHERTEXT_BYTES {
            // Unreachable with the margin above. The sender ratchet has
            // advanced; the message is dropped rather than returned
            // undecryptable.
            wipe(ciphertext);
            return Err(PM_CRYPTO_ERROR);
        }
        unsafe { output(out_ciphertext, ciphertext) }
    })
}

/// Decrypts and authenticates one MLS application message. Returns
/// [`PM_CRYPTO_SENDER_MISMATCH`] when the MLS sender is not the claimed one
/// and [`PM_CRYPTO_SENDER_REMOVED`] for a past-epoch message whose sender has
/// left the group. In both cases the ratchet has advanced, so the caller
/// commits its state and keeps no content.
///
/// # Safety
/// `handle` must be live, slices readable, and `out_plaintext` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_decrypt(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    ciphertext: PmByteSlice,
    sender_account_id: PmByteSlice,
    sender_device_id: PmByteSlice,
    out_plaintext: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        // Checked before decrypting: a decrypt consumes its ratchet step.
        if out_plaintext.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let ciphertext = unsafe { borrowed(ciphertext, MAX_CIPHERTEXT_BYTES)? };
        let sender_account_id = unsafe { borrowed(sender_account_id, MAX_ID_BYTES)? };
        let sender_device_id = unsafe { borrowed(sender_device_id, MAX_ID_BYTES)? };
        let plaintext = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .decrypt(&mut group, ciphertext, sender_account_id, sender_device_id)
                    .map_err(|error| match error {
                        MlsError::SenderMismatch => PM_CRYPTO_SENDER_MISMATCH,
                        MlsError::SenderRemoved => PM_CRYPTO_SENDER_REMOVED,
                        _ => PM_CRYPTO_ERROR,
                    })
            })?
        };
        unsafe { output(out_plaintext, plaintext) }
    })
}

/// Encrypts one independently authenticated attachment chunk.
///
/// # Safety
/// All slices must remain readable for the call and `out_ciphertext` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_attachment_encrypt_chunk(
    key: PmByteSlice,
    nonce_prefix: PmByteSlice,
    chunk_index: u32,
    context: PmByteSlice,
    plaintext: PmByteSlice,
    out_ciphertext: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let key = unsafe { borrowed(key, ATTACHMENT_KEY_BYTES)? };
        let nonce_prefix = unsafe { borrowed(nonce_prefix, ATTACHMENT_NONCE_PREFIX_BYTES)? };
        if key.len() != ATTACHMENT_KEY_BYTES || nonce_prefix.len() != ATTACHMENT_NONCE_PREFIX_BYTES
        {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let context = unsafe { borrowed(context, 512)? };
        let plaintext = unsafe { borrowed(plaintext, attachment::MAX_ATTACHMENT_CHUNK)? };
        let encrypted =
            attachment::encrypt_chunk(key, nonce_prefix, chunk_index, context, plaintext)
                .map_err(|_| PM_CRYPTO_ERROR)?;
        unsafe { output(out_ciphertext, encrypted) }
    })
}

/// Decrypts and authenticates one attachment chunk.
///
/// # Safety
/// All slices must remain readable for the call and `out_plaintext` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_attachment_decrypt_chunk(
    key: PmByteSlice,
    nonce_prefix: PmByteSlice,
    chunk_index: u32,
    context: PmByteSlice,
    ciphertext: PmByteSlice,
    out_plaintext: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        let key = unsafe { borrowed(key, ATTACHMENT_KEY_BYTES)? };
        let nonce_prefix = unsafe { borrowed(nonce_prefix, ATTACHMENT_NONCE_PREFIX_BYTES)? };
        if key.len() != ATTACHMENT_KEY_BYTES || nonce_prefix.len() != ATTACHMENT_NONCE_PREFIX_BYTES
        {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let context = unsafe { borrowed(context, 512)? };
        let ciphertext = unsafe { borrowed(ciphertext, attachment::MAX_ATTACHMENT_CHUNK + 16)? };
        let decrypted =
            attachment::decrypt_chunk(key, nonce_prefix, chunk_index, context, ciphertext)
                .map_err(|_| PM_CRYPTO_ERROR)?;
        unsafe { output(out_plaintext, decrypted) }
    })
}

#[cfg(test)]
#[path = "ffi/records_tests.rs"]
mod records_tests;

#[cfg(test)]
mod tests {
    #[test]
    fn membership_change_lists_are_bounded_and_exact() {
        let mut valid = vec![1u8, 0, 1];
        valid.extend_from_slice(&3u32.to_be_bytes());
        valid.extend_from_slice(b"kp!");
        valid.extend_from_slice(&[0, 1, b'a', 0, 1, b'd']);
        valid.extend_from_slice(&[0, 1]);
        valid.extend_from_slice(&[0, 1, b'b', 0, 1, b'e']);
        let parsed = super::parse_membership_changes(&valid).unwrap();
        assert_eq!(parsed.adds.len(), 1);
        assert_eq!(parsed.adds[0].key_package, b"kp!");
        assert_eq!(parsed.removes[0].device_id, b"e");

        let mut trailing = valid.clone();
        trailing.push(0);
        assert!(super::parse_membership_changes(&trailing).is_err());
        assert!(super::parse_membership_changes(&valid[..valid.len() - 1]).is_err());
        assert!(super::parse_membership_changes(&[2, 0, 0, 0, 0]).is_err());
        // Nothing to change is a self-update request.
        let empty = super::parse_membership_changes(&[1, 0, 0, 0, 0]).unwrap();
        assert!(empty.adds.is_empty() && empty.removes.is_empty());
        assert!(super::parse_membership_changes(&[1, 0, 0, 0, 0, 0]).is_err());
        // Empty identity.
        let mut empty_id = vec![1u8, 0, 0, 0, 1];
        empty_id.extend_from_slice(&[0, 0, 0, 1, b'x']);
        assert!(super::parse_membership_changes(&empty_id).is_err());
        // A huge declared key package length cannot overflow.
        let mut huge = vec![1u8, 0, 1];
        huge.extend_from_slice(&u32::MAX.to_be_bytes());
        assert!(super::parse_membership_changes(&huge).is_err());
    }

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

    const SECRET: u8 = 0xa7;

    fn secret_with_spare_capacity(len: usize) -> Vec<u8> {
        let mut value = Vec::with_capacity(len * 4);
        value.resize(len, SECRET);
        value
    }

    #[test]
    fn owned_outputs_never_release_an_unwiped_secret() {
        // A Vec with spare capacity used to go through into_boxed_slice,
        // whose realloc may free the original block unwiped.
        let mut out = PmOwnedBuffer::default();
        let value = secret_with_spare_capacity(1000);
        crate::test_memory::watch_secret(SECRET);
        assert_eq!(unsafe { output(&mut out, value) }, Ok(()));
        assert_eq!(crate::test_memory::unwiped_releases(), 0);
        assert_eq!(out.len, 1000);
        let held = unsafe { core::slice::from_raw_parts(out.data, out.len) };
        assert!(held.iter().all(|byte| *byte == SECRET));
        crate::test_memory::watch_secret(SECRET);
        unsafe { pm_crypto_buffer_free(out) };
        assert_eq!(crate::test_memory::unwiped_releases(), 0);

        // An exact-capacity Vec is handed over without a copy.
        let exact = vec![SECRET; 64];
        let address = exact.as_ptr();
        let mut out = PmOwnedBuffer::default();
        assert_eq!(unsafe { output(&mut out, exact) }, Ok(()));
        assert_eq!(out.data.cast_const(), address);
        unsafe { pm_crypto_buffer_free(out) };

        // A rejected target wipes the output it refused.
        crate::test_memory::watch_secret(SECRET);
        assert_eq!(
            unsafe { output(ptr::null_mut(), secret_with_spare_capacity(100)) },
            Err(PM_CRYPTO_INVALID_ARGUMENT)
        );
        assert_eq!(crate::test_memory::unwiped_releases(), 0);

        let mut first = PmOwnedBuffer::default();
        crate::test_memory::watch_secret(SECRET);
        assert_eq!(
            unsafe {
                two_outputs(
                    &mut first,
                    secret_with_spare_capacity(100),
                    ptr::null_mut(),
                    secret_with_spare_capacity(100),
                )
            },
            Err(PM_CRYPTO_INVALID_ARGUMENT)
        );
        assert_eq!(crate::test_memory::unwiped_releases(), 0);
        assert!(first.data.is_null());

        let mut targets = [PmOwnedBuffer::default(); 2];
        let [a, b] = &mut targets;
        crate::test_memory::watch_secret(SECRET);
        assert_eq!(
            unsafe {
                three_outputs(
                    [a, b, ptr::null_mut()],
                    [
                        secret_with_spare_capacity(100),
                        secret_with_spare_capacity(100),
                        secret_with_spare_capacity(100),
                    ],
                )
            },
            Err(PM_CRYPTO_INVALID_ARGUMENT)
        );
        assert_eq!(crate::test_memory::unwiped_releases(), 0);
        assert!(targets.iter().all(|target| target.data.is_null()));

        // Success paths copy exactly and leave nothing unwiped behind.
        let mut pair = [PmOwnedBuffer::default(); 2];
        let [first, second] = &mut pair;
        crate::test_memory::watch_secret(SECRET);
        assert_eq!(
            unsafe {
                two_outputs(
                    first,
                    secret_with_spare_capacity(10),
                    second,
                    secret_with_spare_capacity(20),
                )
            },
            Ok(())
        );
        assert_eq!(crate::test_memory::unwiped_releases(), 0);
        assert_eq!((pair[0].len, pair[1].len), (10, 20));
        unsafe {
            pm_crypto_buffer_free(pair[0]);
            pm_crypto_buffer_free(pair[1]);
        }
    }

    #[test]
    fn largest_plaintext_round_trips_through_the_ffi() {
        let mut alice = ptr::null_mut();
        let mut bob = ptr::null_mut();
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b"acct_a"), slice(b"dev_a"), &mut alice) },
            PM_CRYPTO_OK
        );
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b"acct_b"), slice(b"dev_b"), &mut bob) },
            PM_CRYPTO_OK
        );
        let mut package = PmOwnedBuffer::default();
        assert_eq!(
            unsafe { pm_crypto_device_create_key_package(bob, &mut package) },
            PM_CRYPTO_OK
        );
        let package = unsafe { take(package) };
        assert_eq!(
            unsafe { pm_crypto_group_create(alice, slice(b"conv_big")) },
            PM_CRYPTO_OK
        );
        let (mut commit, mut welcome) = (PmOwnedBuffer::default(), PmOwnedBuffer::default());
        assert_eq!(
            unsafe {
                pm_crypto_group_add_member(
                    alice,
                    slice(b"conv_big"),
                    slice(&package),
                    slice(b"acct_b"),
                    slice(b"dev_b"),
                    &mut commit,
                    &mut welcome,
                )
            },
            PM_CRYPTO_OK
        );
        let _ = unsafe { take(commit) };
        let welcome = unsafe { take(welcome) };
        assert_eq!(
            unsafe { pm_crypto_group_join(bob, slice(b"conv_big"), slice(&welcome)) },
            PM_CRYPTO_OK
        );

        let plaintext = vec![0x5a; MAX_MESSAGE_BYTES];
        let mut ciphertext = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_group_encrypt(
                    alice,
                    slice(b"conv_big"),
                    slice(&plaintext),
                    &mut ciphertext,
                )
            },
            PM_CRYPTO_OK
        );
        let ciphertext = unsafe { take(ciphertext) };
        assert!(ciphertext.len() > MAX_MESSAGE_BYTES);
        assert!(ciphertext.len() <= MAX_MESSAGE_BYTES + 1024);
        let mut decrypted = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_group_decrypt(
                    bob,
                    slice(b"conv_big"),
                    slice(&ciphertext),
                    slice(b"acct_a"),
                    slice(b"dev_a"),
                    &mut decrypted,
                )
            },
            PM_CRYPTO_OK
        );
        assert!(unsafe { take(decrypted) } == plaintext);
        // One byte more is refused before anything is encrypted.
        let mut refused = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_group_encrypt(
                    alice,
                    slice(b"conv_big"),
                    slice(&vec![0x5a; MAX_MESSAGE_BYTES + 1]),
                    &mut refused,
                )
            },
            PM_CRYPTO_INVALID_ARGUMENT
        );
        unsafe {
            pm_crypto_device_destroy(alice);
            pm_crypto_device_destroy(bob);
        }
    }

    #[test]
    fn decrypt_with_a_null_output_is_rejected() {
        let mut alice = ptr::null_mut();
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b"acct_a"), slice(b"dev_a"), &mut alice) },
            PM_CRYPTO_OK
        );
        assert_eq!(
            unsafe { pm_crypto_group_create(alice, slice(b"conv_null")) },
            PM_CRYPTO_OK
        );
        let mut ciphertext = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                pm_crypto_group_encrypt(alice, slice(b"conv_null"), slice(b"x"), &mut ciphertext)
            },
            PM_CRYPTO_OK
        );
        let ciphertext = unsafe { take(ciphertext) };
        assert_eq!(
            unsafe {
                pm_crypto_group_decrypt(
                    alice,
                    slice(b"conv_null"),
                    slice(&ciphertext),
                    slice(b"acct_a"),
                    slice(b"dev_a"),
                    ptr::null_mut(),
                )
            },
            PM_CRYPTO_INVALID_ARGUMENT
        );
        unsafe { pm_crypto_device_destroy(alice) };
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
        let table = super::records_tests::seal(handle, &key, 1).unwrap();
        unsafe { pm_crypto_device_destroy(handle) };

        let (restored, counter) =
            super::records_tests::restore(b"acct_a", b"dev_a", &key, 1, &table).unwrap();
        assert_eq!(counter, 1);
        unsafe { pm_crypto_device_destroy(restored) };
    }

    #[test]
    fn restore_reports_an_unsupported_state_format_separately() {
        let mut handle = ptr::null_mut();
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b"acct_a"), slice(b"dev_a"), &mut handle) },
            PM_CRYPTO_OK
        );
        let key = [9_u8; STATE_KEY_BYTES];
        let table = super::records_tests::seal(handle, &key, 1).unwrap();
        unsafe { pm_crypto_device_destroy(handle) };
        let restore = |root: &[u8]| {
            let mut table = table.clone();
            table.root = root.to_vec();
            match super::records_tests::restore(b"acct_a", b"dev_a", &key, 1, &table) {
                Ok((restored, _)) => {
                    unsafe { pm_crypto_device_destroy(restored) };
                    PM_CRYPTO_OK
                }
                Err(code) => code,
            }
        };
        assert_eq!(restore(&table.root), PM_CRYPTO_OK);
        let mut old_format = table.root.clone();
        old_format[8..10].copy_from_slice(&1u16.to_be_bytes());
        assert_eq!(restore(&old_format), PM_CRYPTO_STATE_FORMAT_UNSUPPORTED);
        let mut tampered = table.root.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert_eq!(restore(&tampered), PM_CRYPTO_ERROR);
    }

    #[test]
    fn invalid_ffi_inputs_fail_without_partial_outputs() {
        let mut locator = PmOwnedBuffer::default();
        assert_eq!(
            unsafe { pm_crypto_device_link_locator(slice(&[1; 15]), &mut locator) },
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert!(locator.data.is_null());
        assert_eq!(locator.len, 0);
        assert_eq!(
            unsafe { pm_crypto_device_link_locator(slice(&[1; 16]), &mut locator) },
            PM_CRYPTO_OK
        );
        assert_eq!(unsafe { take(locator) }.len(), 32);
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
                    slice(b"acct_bob"),
                    slice(b"dev_bob"),
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
            unsafe { pm_crypto_group_join(bob, slice(b"conv_test"), slice(&welcome)) },
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
                    slice(b"acct_alice"),
                    slice(b"dev_alice"),
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

    #[test]
    fn eager_commits_refuse_a_null_output_before_merging() {
        let mut alice = ptr::null_mut();
        let mut bob = ptr::null_mut();
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b"acct_a"), slice(b"dev_a"), &mut alice) },
            PM_CRYPTO_OK
        );
        assert_eq!(
            unsafe { pm_crypto_device_create(slice(b"acct_b"), slice(b"dev_b"), &mut bob) },
            PM_CRYPTO_OK
        );
        let mut package = PmOwnedBuffer::default();
        assert_eq!(
            unsafe { pm_crypto_device_create_key_package(bob, &mut package) },
            PM_CRYPTO_OK
        );
        let package = unsafe { take(package) };
        assert_eq!(
            unsafe { pm_crypto_group_create(alice, slice(b"conv_null")) },
            PM_CRYPTO_OK
        );
        let (mut commit, mut welcome) = (PmOwnedBuffer::default(), PmOwnedBuffer::default());
        assert_eq!(
            unsafe {
                pm_crypto_group_add_member(
                    alice,
                    slice(b"conv_null"),
                    slice(&package),
                    slice(b"acct_b"),
                    slice(b"dev_b"),
                    &mut commit,
                    &mut welcome,
                )
            },
            PM_CRYPTO_OK
        );
        let _ = unsafe { take(commit) };
        let _ = unsafe { take(welcome) };
        let epoch = |handle| {
            let (mut epoch, mut pending) = (0u64, 0u8);
            assert_eq!(
                unsafe {
                    pm_crypto_group_epoch(handle, slice(b"conv_null"), &mut epoch, &mut pending)
                },
                PM_CRYPTO_OK
            );
            (epoch, pending)
        };
        let before = epoch(alice);

        // A NULL output must fail before the group advances, or the caller
        // gets an error and no commit while this device moved on alone.
        assert_eq!(
            unsafe { pm_crypto_group_self_update(alice, slice(b"conv_null"), ptr::null_mut()) },
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(epoch(alice), before);
        assert_eq!(
            unsafe {
                pm_crypto_group_remove_member(
                    alice,
                    slice(b"conv_null"),
                    slice(b"acct_b"),
                    slice(b"dev_b"),
                    ptr::null_mut(),
                )
            },
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(epoch(alice), before);
        unsafe {
            pm_crypto_device_destroy(alice);
            pm_crypto_device_destroy(bob);
        }
    }

    #[test]
    fn release_profile_keeps_ffi_panic_guard_active() {
        let result = ffi_call(|| -> Result<(), i32> {
            panic!("panic guard test");
        });
        assert_eq!(result, PM_CRYPTO_PANIC);
    }

    #[test]
    fn release_profile_keeps_overflow_checks_active() {
        let result = ffi_call(|| -> Result<(), i32> {
            let left = std::hint::black_box(usize::MAX);
            let right = std::hint::black_box(1_usize);
            let _wrapped = left + right;
            Ok(())
        });
        assert_eq!(result, PM_CRYPTO_PANIC);
    }
}
