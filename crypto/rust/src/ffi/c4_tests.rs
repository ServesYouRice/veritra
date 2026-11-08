//! ABI 20 (C4): the new C entry points, called the way Dart will call them.

use super::c4_calls::*;
use super::*;

fn slice(bytes: &[u8]) -> PmByteSlice {
    PmByteSlice {
        data: bytes.as_ptr(),
        len: bytes.len(),
    }
}

const EMPTY: PmByteSlice = PmByteSlice {
    data: core::ptr::null(),
    len: 0,
};

unsafe fn take(buffer: PmOwnedBuffer) -> Vec<u8> {
    let value = unsafe { core::slice::from_raw_parts(buffer.data, buffer.len) }.to_vec();
    unsafe { pm_crypto_buffer_free(buffer) };
    value
}

fn is_empty(buffer: &PmOwnedBuffer) -> bool {
    buffer.data.is_null() && buffer.len == 0
}

const GROUP: &[u8] = b"conv_c4_ffi";

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

/// A version 1 change list.
fn changes(adds: &[(&[u8], &[u8], &[u8])], removes: &[(&[u8], &[u8])]) -> Vec<u8> {
    let mut out = vec![MEMBERSHIP_CHANGES_VERSION];
    out.extend_from_slice(&(adds.len() as u16).to_be_bytes());
    for (key_package, account, device) in adds {
        out.extend_from_slice(&(key_package.len() as u32).to_be_bytes());
        out.extend_from_slice(key_package);
        for id in [account, device] {
            out.extend_from_slice(&(id.len() as u16).to_be_bytes());
            out.extend_from_slice(id);
        }
    }
    out.extend_from_slice(&(removes.len() as u16).to_be_bytes());
    for (account, device) in removes {
        for id in [account, device] {
            out.extend_from_slice(&(id.len() as u16).to_be_bytes());
            out.extend_from_slice(id);
        }
    }
    out
}

struct Staged {
    commit: Vec<u8>,
    welcome: Vec<u8>,
    epoch: u64,
}

unsafe fn stage_with_roles(
    handle: *mut PmCryptoHandle,
    changes: &[u8],
    record: &[u8],
) -> Result<Staged, i32> {
    let (mut commit, mut welcome, mut epoch) =
        (PmOwnedBuffer::default(), PmOwnedBuffer::default(), 0u64);
    let record = if record.is_empty() {
        EMPTY
    } else {
        slice(record)
    };
    let status = unsafe {
        pm_crypto_group_stage_commit_with_roles(
            handle,
            slice(GROUP),
            slice(changes),
            record,
            &mut commit,
            &mut welcome,
            &mut epoch,
        )
    };
    if status != PM_CRYPTO_OK {
        assert!(is_empty(&commit) && is_empty(&welcome));
        return Err(status);
    }
    Ok(Staged {
        commit: unsafe { take(commit) },
        welcome: if is_empty(&welcome) {
            Vec::new()
        } else {
            unsafe { take(welcome) }
        },
        epoch,
    })
}

fn merge_own(handle: *mut PmCryptoHandle) {
    assert_eq!(
        unsafe { pm_crypto_group_merge_pending_commit(handle, slice(GROUP)) },
        PM_CRYPTO_OK
    );
}

fn join(handle: *mut PmCryptoHandle, welcome: &[u8]) {
    assert_eq!(
        unsafe { pm_crypto_group_join(handle, slice(GROUP), slice(welcome)) },
        PM_CRYPTO_OK
    );
}

#[derive(Debug, PartialEq)]
struct RoleState {
    record: Option<Vec<u8>>,
    roster: Vec<Vec<u8>>,
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> &'a [u8] {
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        head
    }
    fn u8(&mut self) -> u8 {
        self.take(1)[0]
    }
    fn u16(&mut self) -> usize {
        let b = self.take(2);
        usize::from(u16::from_be_bytes([b[0], b[1]]))
    }
    fn u32(&mut self) -> usize {
        let b = self.take(4);
        u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize
    }
    fn u64(&mut self) -> u64 {
        u64::from_be_bytes(self.take(8).try_into().unwrap())
    }
    fn lp(&mut self) -> Vec<u8> {
        let n = self.u16();
        self.take(n).to_vec()
    }
    fn accounts(&mut self) -> Vec<Vec<u8>> {
        let n = self.u16();
        (0..n).map(|_| self.lp()).collect()
    }
    fn record(&mut self, present: bool) -> Option<Vec<u8>> {
        let n = self.u32();
        let bytes = self.take(n).to_vec();
        if present {
            Some(bytes)
        } else {
            assert!(bytes.is_empty());
            None
        }
    }
    fn pair(&mut self) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        (self.lp(), self.lp(), self.take(32).to_vec())
    }
}

fn role_state_of(handle: *mut PmCryptoHandle, group: &[u8]) -> Result<RoleState, i32> {
    let mut out = PmOwnedBuffer::default();
    let status = unsafe { pm_crypto_group_role_state(handle, slice(group), &mut out) };
    if status != PM_CRYPTO_OK {
        assert!(is_empty(&out));
        return Err(status);
    }
    let bytes = unsafe { take(out) };
    let mut reader = Reader(&bytes);
    assert_eq!(reader.u8(), 1);
    let flags = reader.u8();
    assert!(flags <= 1);
    let roster = reader.accounts();
    let record = reader.record(flags == 1);
    assert!(reader.0.is_empty());
    Ok(RoleState { record, roster })
}

fn role_state(handle: *mut PmCryptoHandle) -> Result<RoleState, i32> {
    role_state_of(handle, GROUP)
}

#[derive(Debug)]
struct Review {
    flags: u8,
    epoch: u64,
    committer: (Vec<u8>, Vec<u8>, Vec<u8>),
    added: Vec<(Vec<u8>, Vec<u8>, Vec<u8>)>,
    before: Vec<Vec<u8>>,
    after: Vec<Vec<u8>>,
    record_before: Option<Vec<u8>>,
    record_after: Option<Vec<u8>>,
}

unsafe fn stage_incoming(handle: *mut PmCryptoHandle, commit: &[u8]) -> Result<Review, i32> {
    let mut out = PmOwnedBuffer::default();
    let status = unsafe {
        pm_crypto_group_stage_incoming_commit(handle, slice(GROUP), slice(commit), &mut out)
    };
    if status != PM_CRYPTO_OK {
        assert!(is_empty(&out));
        return Err(status);
    }
    let bytes = unsafe { take(out) };
    let mut reader = Reader(&bytes);
    assert_eq!(reader.u8(), 1);
    let flags = reader.u8();
    let epoch = reader.u64();
    let committer = reader.pair();
    let added = (0..reader.u16()).map(|_| reader.pair()).collect();
    let before = reader.accounts();
    let after = reader.accounts();
    let record_before = reader.record(flags & 16 != 0);
    let record_after = reader.record(flags & 32 != 0);
    assert!(reader.0.is_empty());
    Ok(Review {
        flags,
        epoch,
        committer,
        added,
        before,
        after,
        record_before,
        record_after,
    })
}

struct Merged {
    flags: u8,
    epoch: u64,
    root: bool,
    added: Vec<u8>,
    committer: Vec<u8>,
}

unsafe fn merge_incoming(handle: *mut PmCryptoHandle, commit: &[u8]) -> Result<Merged, i32> {
    let (mut flags, mut epoch) = (0xFFu8, 0xFFu64);
    let (mut root, mut added, mut committer) = (
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
    );
    let status = unsafe {
        pm_crypto_group_merge_incoming_commit(
            handle,
            slice(GROUP),
            slice(commit),
            &mut flags,
            &mut epoch,
            &mut root,
            &mut added,
            &mut committer,
        )
    };
    if status != PM_CRYPTO_OK {
        assert_eq!((flags, epoch), (0, 0));
        assert!(is_empty(&root) && is_empty(&added) && is_empty(&committer));
        return Err(status);
    }
    let has_root = !is_empty(&root);
    if has_root {
        assert_eq!(unsafe { take(root) }.len(), 32);
    }
    Ok(Merged {
        flags,
        epoch,
        root: has_root,
        added: unsafe { take(added) },
        committer: unsafe { take(committer) },
    })
}

fn discard(handle: *mut PmCryptoHandle) -> u8 {
    let mut held = 0xFF;
    assert_eq!(
        unsafe { pm_crypto_group_discard_incoming_commit(handle, slice(GROUP), &mut held) },
        PM_CRYPTO_OK
    );
    held
}

fn epoch_and_pending(handle: *mut PmCryptoHandle) -> (u64, u8) {
    let (mut epoch, mut pending) = (0, 0);
    assert_eq!(
        unsafe { pm_crypto_group_epoch(handle, slice(GROUP), &mut epoch, &mut pending) },
        PM_CRYPTO_OK
    );
    (epoch, pending)
}

fn destroy(handles: &[*mut PmCryptoHandle]) {
    for handle in handles {
        unsafe { pm_crypto_device_destroy(*handle) };
    }
}

fn leaf_pair_bytes(account: &[u8], device: &[u8], key: &[u8]) -> Vec<u8> {
    let mut out = vec![0, 1];
    for part in [account, device] {
        out.extend_from_slice(&(part.len() as u16).to_be_bytes());
        out.extend_from_slice(part);
    }
    out.extend_from_slice(key);
    out
}

#[test]
fn a_record_group_is_created_reviewed_merged_and_read_through_the_abi() {
    let alice = create(b"acct_alice", b"dev_alice");
    let bob = create(b"acct_bob", b"dev_bob");
    let carol = create(b"acct_carol", b"dev_carol");
    assert_eq!(
        unsafe { pm_crypto_group_create_with_roles(alice, slice(GROUP), slice(b"g0")) },
        PM_CRYPTO_OK
    );
    assert_eq!(
        role_state(alice).unwrap(),
        RoleState {
            record: Some(b"g0".to_vec()),
            roster: vec![b"acct_alice".to_vec()],
        }
    );

    // The add carries the stamped record; the joiners read it.
    let (bob_kp, carol_kp) = (key_package(bob), key_package(carol));
    let add = unsafe {
        stage_with_roles(
            alice,
            &changes(
                &[
                    (&bob_kp, b"acct_bob", b"dev_bob"),
                    (&carol_kp, b"acct_carol", b"dev_carol"),
                ],
                &[],
            ),
            b"r1",
        )
    }
    .unwrap();
    assert_eq!(add.epoch, 0);
    merge_own(alice);
    join(bob, &add.welcome);
    join(carol, &add.welcome);
    let everyone = vec![
        b"acct_alice".to_vec(),
        b"acct_bob".to_vec(),
        b"acct_carol".to_vec(),
    ];
    for handle in [alice, bob, carol] {
        assert_eq!(
            role_state(handle).unwrap(),
            RoleState {
                record: Some(b"r1".to_vec()),
                roster: everyone.clone(),
            }
        );
    }

    // Bob removes Carol and prunes the record; Alice reviews it first.
    let removal =
        unsafe { stage_with_roles(bob, &changes(&[], &[(b"acct_carol", b"dev_carol")]), b"r2") }
            .unwrap();
    assert!(removal.welcome.is_empty());
    merge_own(bob);
    let review = unsafe { stage_incoming(alice, &removal.commit) }.unwrap();
    assert_eq!(review.flags, 1 | 8 | 16 | 32);
    assert_eq!(review.epoch, 2);
    assert_eq!(
        review.committer,
        (b"acct_bob".to_vec(), b"dev_bob".to_vec(), signing_key(bob))
    );
    assert!(review.added.is_empty());
    assert_eq!(review.before, everyone);
    assert_eq!(
        review.after,
        vec![b"acct_alice".to_vec(), b"acct_bob".to_vec()]
    );
    assert_eq!(review.record_before.as_deref(), Some(&b"r1"[..]));
    assert_eq!(review.record_after.as_deref(), Some(&b"r2"[..]));
    assert_eq!(epoch_and_pending(alice).0, 1);

    let merged = unsafe { merge_incoming(alice, &removal.commit) }.unwrap();
    assert_eq!(merged.flags, PM_CRYPTO_C7_COMMIT_REMOVED);
    assert_eq!(merged.epoch, 2);
    assert!(merged.root);
    assert_eq!(merged.added, [0, 0]);
    assert_eq!(
        merged.committer,
        leaf_pair_bytes(b"acct_bob", b"dev_bob", &signing_key(bob))
    );
    assert_eq!(epoch_and_pending(alice).0, 2);
    assert_eq!(role_state(alice).unwrap().record, Some(b"r2".to_vec()));

    // Carol's own removal: reviewed, merged, her group is gone.
    let review = unsafe { stage_incoming(carol, &removal.commit) }.unwrap();
    assert_eq!(review.flags & 4, 4);
    let merged = unsafe { merge_incoming(carol, &removal.commit) }.unwrap();
    assert_eq!(
        merged.flags & PM_CRYPTO_C7_COMMIT_REMOVED_SELF,
        PM_CRYPTO_C7_COMMIT_REMOVED_SELF
    );
    assert!(!merged.root);
    assert_eq!(role_state(carol).err(), Some(PM_CRYPTO_ERROR));
    destroy(&[alice, bob, carol]);
}

#[test]
fn a_refused_commit_is_discarded_and_the_one_shot_call_refuses_it() {
    let alice = create(b"acct_alice", b"dev_alice");
    let bob = create(b"acct_bob", b"dev_bob");
    assert_eq!(
        unsafe { pm_crypto_group_create_with_roles(alice, slice(GROUP), slice(b"g0")) },
        PM_CRYPTO_OK
    );
    let bob_kp = key_package(bob);
    let add = unsafe {
        stage_with_roles(
            alice,
            &changes(&[(&bob_kp, b"acct_bob", b"dev_bob")], &[]),
            b"r1",
        )
    }
    .unwrap();
    merge_own(alice);
    join(bob, &add.welcome);

    // A role change alone (an empty change list with a record).
    let change = unsafe { stage_with_roles(alice, &changes(&[], &[]), b"r2") }.unwrap();
    assert!(change.welcome.is_empty());
    assert_eq!(epoch_and_pending(alice), (1, 1));
    // The one-shot calls never merge a record proposal.
    assert_eq!(
        unsafe { pm_crypto_group_process_commit(bob, slice(GROUP), slice(&change.commit)) },
        PM_CRYPTO_ERROR
    );
    assert_eq!(epoch_and_pending(bob).0, 1);

    // Alice's next commit: staged, discarded, never merged.
    assert_eq!(
        unsafe { pm_crypto_group_clear_pending_commit(alice, slice(GROUP)) },
        PM_CRYPTO_OK
    );
    let next = unsafe { stage_with_roles(alice, &changes(&[], &[]), b"r3") }.unwrap();
    let review = unsafe { stage_incoming(bob, &next.commit) }.unwrap();
    assert_eq!(review.record_after.as_deref(), Some(&b"r3"[..]));
    assert_eq!(
        review.committer,
        (
            b"acct_alice".to_vec(),
            b"dev_alice".to_vec(),
            signing_key(alice)
        )
    );
    assert_eq!(discard(bob), 1);
    assert_eq!(discard(bob), 0);
    assert_eq!(
        unsafe { merge_incoming(bob, &next.commit) }.err(),
        Some(PM_CRYPTO_ERROR)
    );
    assert_eq!(epoch_and_pending(bob).0, 1);
    assert_eq!(role_state(bob).unwrap().record, Some(b"r1".to_vec()));
    destroy(&[alice, bob]);
}

#[test]
fn bad_arguments_are_refused_before_any_work() {
    let alice = create(b"acct_alice", b"dev_alice");
    let too_big = vec![1u8; crate::mls::MAX_ROLE_RECORD_BYTES + 1];
    for record in [EMPTY, slice(&too_big)] {
        assert_eq!(
            unsafe { pm_crypto_group_create_with_roles(alice, slice(GROUP), record) },
            PM_CRYPTO_INVALID_ARGUMENT
        );
    }
    assert_eq!(role_state(alice).err(), Some(PM_CRYPTO_ERROR));
    assert_eq!(
        unsafe { pm_crypto_group_create_with_roles(alice, slice(GROUP), slice(b"g0")) },
        PM_CRYPTO_OK
    );
    // No record, an oversized one, or the same one: nothing is staged.
    for (record, expected) in [
        (&b""[..], PM_CRYPTO_INVALID_ARGUMENT),
        (&too_big, PM_CRYPTO_INVALID_ARGUMENT),
        (b"g0", PM_CRYPTO_ERROR),
    ] {
        assert_eq!(
            unsafe { stage_with_roles(alice, &changes(&[], &[]), record) }.err(),
            Some(expected)
        );
        assert_eq!(epoch_and_pending(alice), (0, 0));
    }
    // Null outputs.
    let mut commit = PmOwnedBuffer::default();
    let mut epoch = 0;
    assert_eq!(
        unsafe {
            pm_crypto_group_stage_commit_with_roles(
                alice,
                slice(GROUP),
                slice(&changes(&[], &[])),
                slice(b"r1"),
                &mut commit,
                ptr::null_mut(),
                &mut epoch,
            )
        },
        PM_CRYPTO_INVALID_ARGUMENT
    );
    assert_eq!(
        unsafe {
            pm_crypto_group_stage_incoming_commit(alice, slice(GROUP), slice(b"x"), ptr::null_mut())
        },
        PM_CRYPTO_INVALID_ARGUMENT
    );
    assert_eq!(
        unsafe { pm_crypto_group_discard_incoming_commit(alice, slice(GROUP), ptr::null_mut()) },
        PM_CRYPTO_INVALID_ARGUMENT
    );
    assert_eq!(
        unsafe { pm_crypto_group_role_state(alice, slice(GROUP), ptr::null_mut()) },
        PM_CRYPTO_INVALID_ARGUMENT
    );
    // Garbage is not a commit; nothing is held.
    assert_eq!(
        unsafe { stage_incoming(alice, b"not a commit") }.err(),
        Some(PM_CRYPTO_ERROR)
    );
    assert_eq!(discard(alice), 0);
    // A plain group reads as no record.
    assert_eq!(
        unsafe { pm_crypto_group_create(alice, slice(b"conv_plain")) },
        PM_CRYPTO_OK
    );
    assert_eq!(
        role_state_of(alice, b"conv_plain").unwrap(),
        RoleState {
            record: None,
            roster: vec![b"acct_alice".to_vec()],
        }
    );
    let mut out = PmOwnedBuffer::default();
    assert_eq!(
        unsafe { pm_crypto_group_role_state(alice, slice(b"conv_plain"), &mut out) },
        PM_CRYPTO_OK
    );
    let mut expected = vec![1, 0, 0, 1, 0, 10];
    expected.extend_from_slice(b"acct_alice");
    expected.extend_from_slice(&[0, 0, 0, 0]);
    assert_eq!(unsafe { take(out) }, expected);
    destroy(&[alice]);
}
