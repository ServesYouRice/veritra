//! ABI 20 (C4) entry points: the group role record.
//!
//! Design: `docs/designs/C4-custom-roles.md`; wire rules and output formats
//! in `docs/crypto.md` ("Group role state (C4)"). Rust carries the record as
//! opaque bytes (1 to 256 KiB) in GroupContext extension `0xF0C4`; Dart
//! decodes it and judges every change (`validateCommit`) between
//! [`pm_crypto_group_stage_incoming_commit`] and
//! [`pm_crypto_group_merge_incoming_commit`] or
//! [`pm_crypto_group_discard_incoming_commit`].

use super::{
    borrowed, ffi_call, into_owned, output, parse_membership_changes, wipe, with_device,
    write_commit_outcome, PmCryptoHandle, PmOwnedBuffer, MAX_HANDSHAKE_BYTES, MAX_ID_BYTES,
    MEMBERSHIP_CHANGES_VERSION_KEYED, PM_CRYPTO_ERROR, PM_CRYPTO_INVALID_ARGUMENT,
};
use crate::{
    mls::{encode_role_state, leave_proof, MAX_ROLE_RECORD_BYTES},
    PmByteSlice,
};

/// ABI 20 (C4 item 2): creates and persists a record group. Its context
/// requires extension `0xF0C4` and carries `record` (1 to 256 KiB; the app
/// passes `encodeGovernance(GovernanceState.genesis(creator))`).
/// [`super::pm_crypto_group_create`] stays for groups without a record (a
/// private channel's group).
///
/// # Safety
/// `handle` must be live and both slices readable for the call.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_create_with_roles(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    record: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let record = unsafe { borrowed(record, MAX_ROLE_RECORD_BYTES)? };
        unsafe {
            with_device(handle, |device| {
                device
                    .create_group_with_record(group_id, record)
                    .map(|_| ())
                    .map_err(|_| PM_CRYPTO_ERROR)
            })
        }
    })
}

/// ABI 20 (C4 item 3): [`super::pm_crypto_group_stage_commit`] that also
/// carries the group's new role record as one GroupContextExtensions
/// proposal. `changes` is a change list of version 2 only (every add names
/// the signing key its key package must hold, L1; version 1 is
/// `PM_CRYPTO_INVALID_ARGUMENT`), and it may hold no
/// adds and no removes: then the commit is the role change alone (never a
/// self-update). `record` (1 to 256 KiB) must differ from the group's
/// current record, and the group must already carry one; otherwise
/// `PM_CRYPTO_ERROR` and nothing is staged. Settle it with the usual merge
/// or clear calls.
///
/// # Safety
/// `handle` must be live, slices readable, and all outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_stage_commit_with_roles(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    changes: PmByteSlice,
    record: PmByteSlice,
    out_commit: *mut PmOwnedBuffer,
    out_welcome: *mut PmOwnedBuffer,
    out_epoch: *mut u64,
) -> i32 {
    ffi_call(|| {
        let record = unsafe { borrowed(record, MAX_ROLE_RECORD_BYTES)? };
        unsafe {
            stage_keyed(
                handle,
                group_id,
                changes,
                Some(record),
                None,
                out_commit,
                out_welcome,
                out_epoch,
            )
        }
    })
}

/// ABI 24 (C4 leave proof in the commit, `docs/crypto.md`): stages a
/// commit as [`pm_crypto_group_stage_commit_with_roles`] does, with the
/// leave statements the app holds for the devices it removes in the
/// commit's authenticated data. `record` may be empty: the commit then
/// carries no record proposal and must add or remove someone. `changes` is
/// version 2 only. `leave_proofs` is a `VCL1` list (`"VCL1" || u8 count
/// (1..16) || { u32 leaf || u16 64 || signature }*`, distinct leaves); a
/// malformed or empty list is `PM_CRYPTO_INVALID_ARGUMENT`. Statements that
/// name a leaf the commit keeps, or that no longer verify (the leaf changed
/// since it signed), are dropped; with none left the commit carries no AAD.
/// Settle it with the usual merge or clear calls.
///
/// # Safety
/// `handle` must be live, slices readable, and all outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_stage_commit_proven(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    changes: PmByteSlice,
    record: PmByteSlice,
    leave_proofs: PmByteSlice,
    out_commit: *mut PmOwnedBuffer,
    out_welcome: *mut PmOwnedBuffer,
    out_epoch: *mut u64,
) -> i32 {
    ffi_call(|| {
        let record = if record.len == 0 {
            None
        } else {
            Some(unsafe { borrowed(record, MAX_ROLE_RECORD_BYTES)? })
        };
        let proofs = unsafe {
            borrowed(
                leave_proofs,
                5 + leave_proof::MAX_STATEMENTS * leave_proof::STATEMENT_BYTES,
            )?
        };
        if leave_proof::parse_aad(proofs).is_none() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        unsafe {
            stage_keyed(
                handle,
                group_id,
                changes,
                record,
                Some(proofs),
                out_commit,
                out_welcome,
                out_epoch,
            )
        }
    })
}

/// ABI 24: this device's signed leave statement for `group_id`
/// (`u32 leaf_index || u16 64 || signature`, 70 bytes): RFC 9420
/// SignWithLabel with its leaf signature key, label `"VeritraC4Leave1"`,
/// over the group id, its leaf index and its leaf encryption key now. It
/// is valid until this leaf changes; a cancelled leave self-updates.
///
/// # Safety
/// `handle` must be live, `group_id` readable and `out_statement` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_c4_sign_leave(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    out_statement: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_statement.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        unsafe { out_statement.write(PmOwnedBuffer::default()) };
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let statement = unsafe {
            with_device(handle, |device| {
                let group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device.sign_leave(&group).map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe { output(out_statement, statement) }
    })
}

/// The body of the keyed staging calls: change list version 2 only.
/// # Safety
/// As the public staging calls: `handle` live, slices readable, outputs
/// writable.
#[allow(clippy::too_many_arguments)]
unsafe fn stage_keyed(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    changes: PmByteSlice,
    record: Option<&[u8]>,
    leave_proofs: Option<&[u8]>,
    out_commit: *mut PmOwnedBuffer,
    out_welcome: *mut PmOwnedBuffer,
    out_epoch: *mut u64,
) -> Result<(), i32> {
    {
        if out_commit.is_null() || out_welcome.is_null() || out_epoch.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let changes = unsafe { borrowed(changes, MAX_HANDSHAKE_BYTES)? };
        // Version 2 only: no new path that skips the L1 key check.
        if changes.first() != Some(&MEMBERSHIP_CHANGES_VERSION_KEYED) {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let changes = parse_membership_changes(changes)?;
        let staged = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .stage_commit_proven(
                        &mut group,
                        &changes.adds,
                        &changes.expected_keys,
                        &changes.removes,
                        record,
                        leave_proofs,
                    )
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        if staged.commit.is_empty() {
            wipe(staged.welcome);
            return Err(PM_CRYPTO_ERROR);
        }
        let commit = into_owned(staged.commit);
        let welcome = into_owned(staged.welcome);
        unsafe {
            out_commit.write(commit);
            out_welcome.write(welcome);
            out_epoch.write(staged.epoch);
        }
        Ok(())
    }
}

/// ABI 20 (C4 item 4, phase one): processes a remote commit up to its
/// staged form, checks it (`inspect_commit`, which here also accepts one
/// role-record proposal), and holds it in memory without merging. The
/// group's epoch does not move. `out_review` gets the review
/// (`docs/crypto.md`, "Group role state (C4)"): flags, the new epoch, the
/// committer's `(account, device, key)` from the MLS tree, the added leaves,
/// the account roster before and after, and the record before and after.
///
/// Staging again for the same group replaces what was held. The commit's
/// handshake ratchet step is used up by staging: if Dart refuses the commit
/// it calls [`pm_crypto_group_discard_incoming_commit`] and restores its
/// committed state instead of sealing.
///
/// # Safety
/// `handle` must be live, slices readable and `out_review` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_stage_incoming_commit(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    commit: PmByteSlice,
    out_review: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_review.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        unsafe { out_review.write(PmOwnedBuffer::default()) };
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let commit = unsafe { borrowed(commit, MAX_HANDSHAKE_BYTES)? };
        let review = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                let review = device
                    .stage_incoming_commit(&mut group, commit)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                match review.encode() {
                    Ok(encoded) => Ok(encoded),
                    Err(_) => {
                        // Never hold a commit Dart was not told about.
                        let _ = device.discard_incoming_commit(group_id);
                        Err(PM_CRYPTO_ERROR)
                    }
                }
            })?
        };
        unsafe { output(out_review, review) }
    })
}

/// ABI 20 (C4 item 4, phase two): merges the commit held for this group
/// once Dart accepted its review. `commit` must be the bytes that were
/// staged and the group must still be on the epoch they were staged on;
/// otherwise `PM_CRYPTO_ERROR`, nothing changes and the commit stays held.
/// The outputs are those of [`super::l1_calls::pm_crypto_group_l1_process_commit`]
/// (flags, new epoch, the C7 root of a removal that keeps this device, the
/// added pairs and the committer pair); the root is derived here, never at
/// staging. A commit that removes this device drops its group store.
///
/// # Safety
/// `handle` must be live, slices readable and all five outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_merge_incoming_commit(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    commit: PmByteSlice,
    out_flags: *mut u8,
    out_epoch: *mut u64,
    out_root: *mut PmOwnedBuffer,
    out_added: *mut PmOwnedBuffer,
    out_committer: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_flags.is_null()
            || out_epoch.is_null()
            || out_root.is_null()
            || out_added.is_null()
            || out_committer.is_null()
        {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        // SAFETY: Targets checked above; reset before any work that can fail.
        unsafe {
            out_flags.write(0);
            out_epoch.write(0);
            out_root.write(PmOwnedBuffer::default());
            out_added.write(PmOwnedBuffer::default());
            out_committer.write(PmOwnedBuffer::default());
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let commit = unsafe { borrowed(commit, MAX_HANDSHAKE_BYTES)? };
        let outcome = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .merge_incoming_commit(&mut group, commit)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        // Both pair buffers were encoded before the merge.
        unsafe {
            out_added.write(into_owned(outcome.added_pairs.clone()));
            out_committer.write(into_owned(outcome.committer_pair.clone()));
            write_commit_outcome(outcome, out_flags, out_epoch, out_root);
        }
        Ok(())
    })
}

/// ABI 20 (C4): drops the commit held for this group (Dart refused it).
/// The group is not touched. `out_was_held` gets 1 when one was held.
///
/// # Safety
/// `handle` must be live, `group_id` readable and `out_was_held` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_discard_incoming_commit(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    out_was_held: *mut u8,
) -> i32 {
    ffi_call(|| {
        if out_was_held.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let held = unsafe {
            with_device(handle, |device| {
                device
                    .discard_incoming_commit(group_id)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe { out_was_held.write(u8::from(held)) };
        Ok(())
    })
}

/// ABI 20 (C4 item 5): the group's current role record and account roster
/// (after a join or a restore): `u8 format = 1 | u8 flags (1: record
/// present) | u16 n { u16 len | account }* (sorted, distinct) | u32 len |
/// record` (len 0 when the group has no record).
///
/// # Safety
/// `handle` must be live, `group_id` readable and `out_state` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_role_state(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    out_state: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_state.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let state = unsafe {
            with_device(handle, |device| {
                let group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                let (record, roster) = device.role_state(&group).map_err(|_| PM_CRYPTO_ERROR)?;
                encode_role_state(record.as_deref(), &roster).map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe { output(out_state, state) }
    })
}
