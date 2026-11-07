//! ABI 13 (C7): the new C entry points, called the way Dart will call them.

use super::*;
use crate::mls::{MemberIdentity, StagedCommitMessages};

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

unsafe fn is_empty(buffer: &PmOwnedBuffer) -> bool {
    buffer.data.is_null() && buffer.len == 0
}

#[test]
fn derive_seal_open_and_the_key_mismatch_code() {
    let key = [1u8; 32];
    let info = b"info bytes";
    let mut derived = PmOwnedBuffer::default();
    unsafe {
        assert_eq!(
            pm_crypto_c7_derive(
                slice(&key),
                slice(crate::c7::LABEL_POST),
                slice(info),
                &mut derived
            ),
            PM_CRYPTO_OK
        );
    }
    let derived = unsafe { take(derived) };
    assert_eq!(
        derived,
        crate::c7::derive(&key, crate::c7::LABEL_POST, info)
            .unwrap()
            .as_slice()
    );
    let mut refused = PmOwnedBuffer::default();
    unsafe {
        // The encryption label is not callable from outside.
        assert_eq!(
            pm_crypto_c7_derive(
                slice(&key),
                slice(b"veritra-c7-enc-v1"),
                slice(info),
                &mut refused
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_c7_derive(
                slice(&key[..31]),
                slice(crate::c7::LABEL_POST),
                slice(info),
                &mut refused
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_c7_derive(
                slice(&key),
                slice(crate::c7::LABEL_POST),
                slice(info),
                ptr::null_mut()
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
    }
    assert!(unsafe { is_empty(&refused) });

    let (aad, plaintext) = (b"aad", b"the body");
    let mut sealed = PmOwnedBuffer::default();
    unsafe {
        assert_eq!(
            pm_crypto_c7_seal(slice(&key), slice(aad), slice(plaintext), &mut sealed),
            PM_CRYPTO_OK
        );
    }
    let sealed = unsafe { take(sealed) };
    assert_eq!(sealed.len(), crate::c7::SEAL_OVERHEAD + plaintext.len());
    let mut opened = PmOwnedBuffer::default();
    unsafe {
        assert_eq!(
            pm_crypto_c7_open(slice(&key), slice(aad), slice(&sealed), &mut opened),
            PM_CRYPTO_OK
        );
    }
    assert_eq!(unsafe { take(opened) }, plaintext);

    // Another key: the distinct mismatch code, nothing written.
    let mut nothing = PmOwnedBuffer::default();
    let other = [2u8; 32];
    assert_eq!(
        unsafe { pm_crypto_c7_open(slice(&other), slice(aad), slice(&sealed), &mut nothing) },
        PM_CRYPTO_C7_KEY_MISMATCH
    );
    assert!(unsafe { is_empty(&nothing) });
    // The right key with another aad or altered bytes: a plain error.
    assert_eq!(
        unsafe { pm_crypto_c7_open(slice(&key), slice(b"nope"), slice(&sealed), &mut nothing) },
        PM_CRYPTO_ERROR
    );
    let mut altered = sealed.clone();
    *altered.last_mut().unwrap() ^= 1;
    assert_eq!(
        unsafe { pm_crypto_c7_open(slice(&key), slice(aad), slice(&altered), &mut nothing) },
        PM_CRYPTO_ERROR
    );
    assert!(unsafe { is_empty(&nothing) });
    // Empty and null inputs are refused.
    assert_eq!(
        unsafe { pm_crypto_c7_seal(slice(&key), slice(aad), slice(b""), &mut nothing) },
        PM_CRYPTO_INVALID_ARGUMENT
    );
    assert_eq!(
        unsafe { pm_crypto_c7_seal(slice(&key), slice(b""), slice(plaintext), &mut nothing) },
        PM_CRYPTO_INVALID_ARGUMENT
    );
    assert_eq!(
        unsafe { pm_crypto_c7_open(slice(&key), slice(aad), slice(&sealed), ptr::null_mut()) },
        PM_CRYPTO_INVALID_ARGUMENT
    );
    let mut commit = PmOwnedBuffer::default();
    unsafe {
        assert_eq!(
            pm_crypto_c7_chk_commit(slice(&key), &mut commit),
            PM_CRYPTO_OK
        );
    }
    assert_eq!(
        unsafe { take(commit) },
        crate::c7::chk_commit(&key).unwrap().to_vec()
    );
}

/// Alice, Bob and Carol in one group at epoch 1, with the devices still
/// outside any handle so the test can stage commits on them.
fn three_members(group_id: &[u8]) -> [MlsDevice; 3] {
    let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
    let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
    let carol = MlsDevice::new(b"acct_carol", b"dev_carol").unwrap();
    let mut group = alice.create_group(group_id).unwrap();
    let (bob_kp, carol_kp) = (
        bob.create_key_package().unwrap(),
        carol.create_key_package().unwrap(),
    );
    let staged: StagedCommitMessages = alice
        .stage_membership_commit(
            &mut group,
            &[
                MemberAdd {
                    key_package: &bob_kp,
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                },
                MemberAdd {
                    key_package: &carol_kp,
                    account_id: b"acct_carol",
                    device_id: b"dev_carol",
                },
            ],
            &[],
        )
        .unwrap();
    alice.merge_pending_commit(&mut group).unwrap();
    bob.join_group(group_id, &staged.welcome).unwrap();
    carol.join_group(group_id, &staged.welcome).unwrap();
    [alice, bob, carol]
}

struct Outcome {
    status: i32,
    flags: u8,
    epoch: u64,
    root: Option<Vec<u8>>,
}

unsafe fn c7_process(handle: *mut PmCryptoHandle, group: &[u8], commit: &[u8]) -> Outcome {
    let (mut flags, mut epoch, mut root) = (9u8, 9u64, PmOwnedBuffer::default());
    let status = unsafe {
        pm_crypto_group_c7_process_commit(
            handle,
            slice(group),
            slice(commit),
            &mut flags,
            &mut epoch,
            &mut root,
        )
    };
    let root = if unsafe { is_empty(&root) } {
        None
    } else {
        Some(unsafe { take(root) })
    };
    Outcome {
        status,
        flags,
        epoch,
        root,
    }
}

unsafe fn c7_merge(handle: *mut PmCryptoHandle, group: &[u8]) -> Outcome {
    let (mut flags, mut epoch, mut root) = (9u8, 9u64, PmOwnedBuffer::default());
    let status = unsafe {
        pm_crypto_group_c7_merge_pending_commit(
            handle,
            slice(group),
            &mut flags,
            &mut epoch,
            &mut root,
        )
    };
    let root = if unsafe { is_empty(&root) } {
        None
    } else {
        Some(unsafe { take(root) })
    };
    Outcome {
        status,
        flags,
        epoch,
        root,
    }
}

#[test]
fn commit_calls_report_flags_epoch_and_root_through_the_abi() {
    let group = b"conv_ffi_c7";
    let [alice, bob, carol] = three_members(group);
    let staged = {
        let mut g = alice.load_group(group).unwrap();
        alice
            .stage_membership_commit(
                &mut g,
                &[],
                &[MemberIdentity {
                    account_id: b"acct_bob",
                    device_id: b"dev_bob",
                }],
            )
            .unwrap()
    };
    let (alice, bob, carol) = (new_handle(alice), new_handle(bob), new_handle(carol));
    unsafe {
        // A merge with nothing staged is refused and leaves the outputs zero.
        let none = c7_merge(carol, group);
        assert_eq!(none.status, PM_CRYPTO_ERROR);
        assert_eq!((none.flags, none.epoch), (0, 0));
        assert!(none.root.is_none());

        let own = c7_merge(alice, group);
        assert_eq!(own.status, PM_CRYPTO_OK);
        assert_eq!(own.flags, PM_CRYPTO_C7_COMMIT_REMOVED);
        assert_eq!(own.epoch, 2);
        let own_root = own.root.expect("root for a removal");
        assert_eq!(own_root.len(), 32);

        let seen = c7_process(carol, group, &staged.commit);
        assert_eq!(seen.status, PM_CRYPTO_OK);
        assert_eq!(seen.flags, PM_CRYPTO_C7_COMMIT_REMOVED);
        assert_eq!(seen.epoch, 2);
        assert_eq!(seen.root.as_deref(), Some(own_root.as_slice()));

        // The removed device: ok, removed and self, no root, group gone.
        let removed = c7_process(bob, group, &staged.commit);
        assert_eq!(removed.status, PM_CRYPTO_OK);
        assert_eq!(
            removed.flags,
            PM_CRYPTO_C7_COMMIT_REMOVED | PM_CRYPTO_C7_COMMIT_REMOVED_SELF
        );
        assert_eq!(removed.epoch, 2);
        assert!(removed.root.is_none());
        let mut epoch = 0u64;
        let mut pending = 0u8;
        assert_eq!(
            pm_crypto_group_epoch(bob, slice(group), &mut epoch, &mut pending),
            PM_CRYPTO_ERROR
        );

        // The root derives the per-channel key through the ABI.
        let mut info = PmOwnedBuffer::default();
        let info_bytes = crate::c7::rekey_info(b"comm", b"chan").unwrap();
        assert_eq!(
            pm_crypto_c7_derive(
                slice(&own_root),
                slice(crate::c7::LABEL_REKEY_CHK),
                slice(&info_bytes),
                &mut info
            ),
            PM_CRYPTO_OK
        );
        assert_eq!(
            take(info),
            crate::c7::rekey_chk(&own_root, b"comm", b"chan")
                .unwrap()
                .as_slice()
        );

        // A refused output pointer stops the call before it touches the group.
        let mut flags = 0u8;
        let mut epoch = 0u64;
        assert_eq!(
            pm_crypto_group_c7_process_commit(
                carol,
                slice(group),
                slice(&staged.commit),
                &mut flags,
                &mut epoch,
                ptr::null_mut()
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        for handle in [alice, bob, carol] {
            pm_crypto_device_destroy(handle);
        }
    }
}

#[test]
fn decrypt_with_epoch_member_key_and_signatures_through_the_abi() {
    let group = b"conv_ffi_c7_keys";
    let [alice, bob, _] = three_members(group);
    let message = {
        let mut g = bob.load_group(group).unwrap();
        bob.encrypt(&mut g, b"hello c7").unwrap()
    };
    let bob_key = bob.signing_public_key().to_vec();
    let (alice, bob) = (new_handle(alice), new_handle(bob));
    unsafe {
        let (mut plain, mut epoch) = (PmOwnedBuffer::default(), 9u64);
        assert_eq!(
            pm_crypto_group_c7_decrypt(
                alice,
                slice(group),
                slice(&message),
                slice(b"acct_bob"),
                slice(b"dev_bob"),
                &mut plain,
                &mut epoch
            ),
            PM_CRYPTO_OK
        );
        assert_eq!((take(plain), epoch), (b"hello c7".to_vec(), 1));

        // A sender mismatch is the plain call's code, with epoch 0.
        let spoof = {
            let device = (*bob).device.lock().unwrap();
            let mut g = device.load_group(group).unwrap();
            device.encrypt(&mut g, b"second").unwrap()
        };
        let (mut plain, mut epoch) = (PmOwnedBuffer::default(), 9u64);
        assert_eq!(
            pm_crypto_group_c7_decrypt(
                alice,
                slice(group),
                slice(&spoof),
                slice(b"acct_carol"),
                slice(b"dev_carol"),
                &mut plain,
                &mut epoch
            ),
            PM_CRYPTO_SENDER_MISMATCH
        );
        assert_eq!(epoch, 0);
        assert!(is_empty(&plain));

        // The member key read, then a signature made by Bob and checked.
        let mut key = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_group_member_signature_key(
                alice,
                slice(group),
                slice(b"acct_bob"),
                slice(b"dev_bob"),
                &mut key
            ),
            PM_CRYPTO_OK
        );
        let key = take(key);
        assert_eq!(key, bob_key);
        let mut nobody = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_group_member_signature_key(
                alice,
                slice(group),
                slice(b"acct_zed"),
                slice(b"dev_zed"),
                &mut nobody
            ),
            PM_CRYPTO_ERROR
        );

        let fields = b"signed fields";
        let mut signature = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_c7_sign(
                bob,
                slice(crate::c7::SIGN_DOMAIN_HISTORY),
                slice(fields),
                &mut signature
            ),
            PM_CRYPTO_OK
        );
        let signature = take(signature);
        assert_eq!(signature.len(), 64);
        let mut valid = 9u8;
        for (domain, message, expected) in [
            (crate::c7::SIGN_DOMAIN_HISTORY, &fields[..], 1u8),
            (crate::c7::SIGN_DOMAIN_POST, &fields[..], 0),
            (crate::c7::SIGN_DOMAIN_HISTORY, b"other fields", 0),
        ] {
            assert_eq!(
                pm_crypto_c7_verify(
                    slice(domain),
                    slice(&key),
                    slice(message),
                    slice(&signature),
                    &mut valid
                ),
                PM_CRYPTO_OK
            );
            assert_eq!(valid, expected);
        }
        // Unlisted domains neither sign nor verify; a bad length is refused.
        let mut refused = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_c7_sign(
                bob,
                slice(b"veritra-c7-other-v1"),
                slice(fields),
                &mut refused
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert!(is_empty(&refused));
        assert_eq!(
            pm_crypto_c7_verify(
                slice(b"veritra-c7-other-v1"),
                slice(&key),
                slice(fields),
                slice(&signature),
                &mut valid
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_c7_verify(
                slice(crate::c7::SIGN_DOMAIN_POST),
                slice(&key),
                slice(fields),
                slice(&signature[..63]),
                &mut valid
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        pm_crypto_device_destroy(alice);
        pm_crypto_device_destroy(bob);
    }
}
