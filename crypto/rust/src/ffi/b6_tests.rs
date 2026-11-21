//! ABI 28 (B6): the call-group entry points, called the way Dart calls them.

use super::b6_calls::*;
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

const GROUP: &[u8] = b"b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6";
const CALL: &[u8] = b"call_ffi";
const CONVERSATION: &[u8] = b"conv_parent";

fn create(account: &[u8], device: &[u8]) -> *mut PmCryptoHandle {
    let mut handle = ptr::null_mut();
    assert_eq!(
        unsafe { pm_crypto_device_create(slice(account), slice(device), &mut handle) },
        PM_CRYPTO_OK
    );
    handle
}

fn key_package(handle: *mut PmCryptoHandle) -> Vec<u8> {
    let mut out = PmOwnedBuffer::default();
    assert_eq!(
        unsafe { pm_crypto_device_create_key_package(handle, &mut out) },
        PM_CRYPTO_OK
    );
    unsafe { take(out) }
}

fn signing_key(handle: *mut PmCryptoHandle) -> Vec<u8> {
    let mut out = PmOwnedBuffer::default();
    assert_eq!(
        unsafe { pm_crypto_device_signing_public_key(handle, &mut out) },
        PM_CRYPTO_OK
    );
    unsafe { take(out) }
}

/// A version 2 change list that only adds `(key package, account, device,
/// signing key)`.
#[allow(clippy::type_complexity)]
fn adds(adds: &[(&[u8], &[u8], &[u8], &[u8])]) -> Vec<u8> {
    let mut out = vec![MEMBERSHIP_CHANGES_VERSION_KEYED];
    out.extend_from_slice(&(adds.len() as u16).to_be_bytes());
    for (key_package, account, device, key) in adds {
        out.extend_from_slice(&(key_package.len() as u32).to_be_bytes());
        out.extend_from_slice(key_package);
        for id in [account, device] {
            out.extend_from_slice(&(id.len() as u16).to_be_bytes());
            out.extend_from_slice(id);
        }
        out.extend_from_slice(key);
    }
    out.extend_from_slice(&0u16.to_be_bytes());
    out
}

/// Stages and merges a commit; returns the Welcome.
fn add_and_merge(handle: *mut PmCryptoHandle, group: &[u8], changes: &[u8]) -> Vec<u8> {
    let (mut commit, mut welcome, mut epoch) =
        (PmOwnedBuffer::default(), PmOwnedBuffer::default(), 0u64);
    assert_eq!(
        unsafe {
            pm_crypto_group_stage_commit(
                handle,
                slice(group),
                slice(changes),
                &mut commit,
                &mut welcome,
                &mut epoch,
            )
        },
        PM_CRYPTO_OK
    );
    drop(unsafe { take(commit) });
    assert_eq!(
        unsafe { pm_crypto_group_merge_pending_commit(handle, slice(group)) },
        PM_CRYPTO_OK
    );
    unsafe { take(welcome) }
}

fn media_key(
    handle: *mut PmCryptoHandle,
    group: &[u8],
    call: &[u8],
    sender: (&[u8], &[u8]),
) -> Result<Vec<u8>, i32> {
    let mut out = PmOwnedBuffer::default();
    let status = unsafe {
        pm_crypto_group_b6_media_key(
            handle,
            slice(group),
            slice(call),
            slice(sender.0),
            slice(sender.1),
            0,
            &mut out,
        )
    };
    if status == PM_CRYPTO_OK {
        Ok(unsafe { take(out) })
    } else {
        assert!(out.data.is_null() && out.len == 0, "nothing written");
        Err(status)
    }
}

fn b6_join(handle: *mut PmCryptoHandle, welcome: &[u8], call: &[u8], conversation: &[u8]) -> i32 {
    unsafe {
        pm_crypto_group_b6_join(
            handle,
            slice(GROUP),
            slice(welcome),
            slice(call),
            slice(conversation),
        )
    }
}

fn has_group(handle: *mut PmCryptoHandle, group: &[u8]) -> bool {
    let (mut epoch, mut pending) = (0u64, 0u8);
    unsafe { pm_crypto_group_epoch(handle, slice(group), &mut epoch, &mut pending) == PM_CRYPTO_OK }
}

#[test]
fn a_call_group_is_joined_only_for_its_call_and_keys_come_only_from_it() {
    assert_eq!(crate::pm_crypto_abi_version(), 28);
    let alice = create(b"acct_alice", b"dev_alice");
    let joiners = [
        (b"acct_bob".as_slice(), b"dev_bob".as_slice()),
        (b"acct_carol", b"dev_carol"),
        (b"acct_dave", b"dev_dave"),
        (b"acct_erin", b"dev_erin"),
    ];
    let handles: Vec<_> = joiners
        .iter()
        .map(|(account, device)| create(account, device))
        .collect();
    assert_eq!(
        unsafe { pm_crypto_group_b6_create(alice, slice(GROUP), slice(CALL), slice(CONVERSATION)) },
        PM_CRYPTO_OK
    );
    // Malformed ids are refused before anything is stored.
    let long = [b'x'; 129];
    for (call, conversation) in [(&long[..], CONVERSATION), (CALL, &long[..])] {
        assert_eq!(
            unsafe {
                pm_crypto_group_b6_create(
                    alice,
                    slice(b"other_group"),
                    slice(call),
                    slice(conversation),
                )
            },
            PM_CRYPTO_INVALID_ARGUMENT
        );
    }
    assert!(!has_group(alice, b"other_group"));

    let packages: Vec<_> = handles.iter().map(|h| key_package(*h)).collect();
    let keys: Vec<_> = handles.iter().map(|h| signing_key(*h)).collect();
    let list: Vec<_> = joiners
        .iter()
        .enumerate()
        .map(|(i, (account, device))| {
            (
                packages[i].as_slice(),
                *account,
                *device,
                keys[i].as_slice(),
            )
        })
        .collect();
    let welcome = add_and_merge(alice, GROUP, &adds(&list));

    // Bob joins the room he asked for.
    assert_eq!(
        b6_join(handles[0], &welcome, CALL, CONVERSATION),
        PM_CRYPTO_OK
    );
    // Carol asked for another call, Dave for another conversation: refused,
    // nothing stored.
    assert_eq!(
        b6_join(handles[1], &welcome, b"call_other", CONVERSATION),
        PM_CRYPTO_ERROR
    );
    assert_eq!(
        b6_join(handles[2], &welcome, CALL, b"conv_other"),
        PM_CRYPTO_ERROR
    );
    // Erin's plain join refuses a call group.
    assert_eq!(
        unsafe { pm_crypto_group_join(handles[3], slice(GROUP), slice(&welcome)) },
        PM_CRYPTO_ERROR
    );
    for handle in &handles[1..] {
        assert!(!has_group(*handle, GROUP));
    }
    // A device the Welcome is not for gets the "not mine" code.
    let zed = create(b"acct_zed", b"dev_zed");
    drop(key_package(zed));
    assert_eq!(
        b6_join(zed, &welcome, CALL, CONVERSATION),
        PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE
    );

    // Both members derive the same key for the bound call, and only for it.
    let bob = (b"acct_bob".as_slice(), b"dev_bob".as_slice());
    let key = media_key(alice, GROUP, CALL, bob).unwrap();
    assert_eq!(key.len(), 32);
    assert_eq!(media_key(handles[0], GROUP, CALL, bob).unwrap(), key);
    assert_eq!(
        media_key(alice, GROUP, b"call_other", bob),
        Err(PM_CRYPTO_ERROR)
    );

    // A conversation group (no marker) gives no media key.
    assert_eq!(
        unsafe { pm_crypto_group_create(alice, slice(b"conv_plain")) },
        PM_CRYPTO_OK
    );
    assert_eq!(
        media_key(alice, b"conv_plain", CALL, (b"acct_alice", b"dev_alice")),
        Err(PM_CRYPTO_ERROR)
    );

    for handle in handles.into_iter().chain([alice, zed]) {
        unsafe { pm_crypto_device_destroy(handle) };
    }
}
