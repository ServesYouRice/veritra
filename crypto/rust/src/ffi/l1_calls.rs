//! ABI 14 (L1, step L1-1) entry points: the approved-device list.
//!
//! Design: `docs/designs/L1-approved-device-list.md`. The format, the rules
//! and the failure kinds are in `crate::l1`; the device-bound parts are in
//! `crate::mls::list`. Nothing here is wired into the app. Signing a
//! device-list body as the device goes through `pm_crypto_c7_sign` (the one
//! credential-key sign entry point) with the L1 label; see there.

use super::{
    borrowed, ffi_call, into_owned, output, with_device, with_device_mut, write_commit_outcome,
    PmCryptoHandle, PmOwnedBuffer, MAX_HANDSHAKE_BYTES, MAX_ID_BYTES, PM_CRYPTO_ERROR,
    PM_CRYPTO_INVALID_ARGUMENT, PM_CRYPTO_L1_CHAIN, PM_CRYPTO_L1_MALFORMED, PM_CRYPTO_L1_NO_SEED,
    PM_CRYPTO_L1_RULE, PM_CRYPTO_L1_SIGNATURE,
};
use crate::{
    l1::{self, L1Error},
    mls::RecoverySignError,
    recovery, PmByteSlice,
};

fn l1_status(error: L1Error) -> i32 {
    match error {
        L1Error::Malformed => PM_CRYPTO_L1_MALFORMED,
        L1Error::Signature => PM_CRYPTO_L1_SIGNATURE,
        L1Error::Chain => PM_CRYPTO_L1_CHAIN,
        L1Error::Rule => PM_CRYPTO_L1_RULE,
    }
}

/// An input that may be absent: length 0 (the pointer may be null) is empty.
unsafe fn borrowed_optional<'a>(input: PmByteSlice, maximum: usize) -> Result<&'a [u8], i32> {
    if input.len == 0 {
        return Ok(&[]);
    }
    // SAFETY: forwarded; the caller's contract is the same as `borrowed`.
    unsafe { borrowed(input, maximum) }
}

/// Largest history a caller may pass (`u16` count and the pairs).
const MAX_HISTORY_BYTES: usize =
    2 + l1::MAX_HISTORY_PAIRS * (2 + crate::MAX_DEVICE_ID_BYTES + l1::KEY_BYTES);
/// Largest chain a caller may pass (`u16` count and the length-prefixed statements).
const MAX_CHAIN_BYTES: usize = 2 + l1::MAX_CHAIN_STATEMENTS * (2 + l1::MAX_STATEMENT_BYTES);

/// ABI 14 (L1): checks `statement` as the version after `prev` (`prev`
/// empty for a genesis) and writes its summary (`l1::encode_summary`:
/// change, signer, version, `list_hash`, `prev_hash`, time, account, the
/// entries and the recovery key) to `out_summary`. `history` is every pair
/// the chain listed before (`u16 n | n x (lp(device_id) | [32] key)`, may be
/// empty) and carries the no-return and one-key-one-device rules across the
/// chain; `prev`'s entries count as history automatically.
///
/// `expected_account_id` (required, 1 to 128 bytes) is the account the
/// caller asked about. A statement of any other account, a genesis included,
/// is refused with `PM_CRYPTO_L1_CHAIN`, so a valid chain of another account
/// can never pass for this one; the caller needs no account comparison of
/// its own.
///
/// Returns `PM_CRYPTO_OK`, or one of `PM_CRYPTO_L1_MALFORMED`, `_CHAIN`,
/// `_RULE`, `_SIGNATURE` (checked in that order), or
/// `PM_CRYPTO_INVALID_ARGUMENT` for a bad length or null output. Nothing is
/// kept; the pin and the keys table are the app's.
///
/// # Safety
/// Every slice must be readable (or empty where optional) and `out_summary`
/// writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_l1_check_step(
    expected_account_id: PmByteSlice,
    prev: PmByteSlice,
    statement: PmByteSlice,
    history: PmByteSlice,
    out_summary: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_summary.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let expected = unsafe { borrowed(expected_account_id, crate::MAX_ACCOUNT_ID_BYTES)? };
        let prev = unsafe { borrowed_optional(prev, l1::MAX_STATEMENT_BYTES)? };
        let statement = unsafe { borrowed(statement, l1::MAX_STATEMENT_BYTES)? };
        let history = unsafe { borrowed_optional(history, MAX_HISTORY_BYTES)? };
        let next = l1::parse_statement(statement).map_err(l1_status)?;
        let prev = if prev.is_empty() {
            None
        } else {
            Some(l1::parse_statement(prev).map_err(l1_status)?)
        };
        let history = l1::decode_pairs(history).map_err(l1_status)?;
        l1::check_step(expected, prev.as_ref(), &next, &history).map_err(l1_status)?;
        let summary = l1::encode_summary(&next).map_err(l1_status)?;
        unsafe { output(out_summary, summary) }
    })
}

/// ABI 14 (L1): checks a whole chain from its genesis (`u16 count |
/// count x (u16 len | statement)`, at most 256 statements): every step, with
/// the no-return and one-key-one-device rules over the history so far. On
/// success `out_result` holds `l1::encode_chain_result`: the head's summary,
/// the list identity (`list_hash` of version 1) and every pair the chain
/// listed with the versions that added and removed it. `expected_account_id`
/// (required, 1 to 128 bytes) is the account asked about: a chain of another
/// account is refused with `PM_CRYPTO_L1_CHAIN`. Errors as
/// [`pm_crypto_l1_check_step`].
///
/// # Safety
/// `expected_account_id` and `chain` must be readable and `out_result`
/// writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_l1_check_chain(
    expected_account_id: PmByteSlice,
    chain: PmByteSlice,
    out_result: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_result.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let expected = unsafe { borrowed(expected_account_id, crate::MAX_ACCOUNT_ID_BYTES)? };
        let chain = unsafe { borrowed(chain, MAX_CHAIN_BYTES)? };
        let statements = l1::decode_chain(chain).map_err(l1_status)?;
        let result = l1::check_chain(expected, &statements).map_err(l1_status)?;
        let encoded = l1::encode_chain_result(&result).map_err(l1_status)?;
        unsafe { output(out_result, encoded) }
    })
}

/// ABI 14 (L1): keeps the device-list recovery seed derived from the typed
/// 30-byte RK entropy in this device's sealed record (a recovered phone
/// waiting out the recovery delay; D94). The entropy is not kept and the seed
/// never leaves Rust. Seal as usual afterwards. A library older than ABI 14
/// refuses a record that holds a seed.
///
/// # Safety
/// `handle` must be live and `entropy` readable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_l1_recovery_hold(
    handle: *mut PmCryptoHandle,
    entropy: PmByteSlice,
) -> i32 {
    ffi_call(|| {
        let entropy = unsafe { borrowed(entropy, recovery::ENTROPY_BYTES)? };
        if entropy.len() != recovery::ENTROPY_BYTES {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        unsafe {
            with_device_mut(handle, |device| {
                device
                    .hold_recovery_list_seed(entropy)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })
        }
    })
}

/// ABI 14 (L1): the public key (32 bytes) of the held recovery-list seed, or
/// an empty (null, 0) buffer when none is held. The app compares it with the
/// recovery key on the head of the account's chain before it signs.
///
/// # Safety
/// `handle` must be live and `out_public` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_l1_recovery_hold_public(
    handle: *mut PmCryptoHandle,
    out_public: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_public.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        unsafe { out_public.write(PmOwnedBuffer::default()) };
        let public = unsafe {
            with_device(handle, |device| {
                device
                    .held_recovery_list_public()
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        if let Some(public) = public {
            unsafe { out_public.write(into_owned(public.to_vec())) };
        }
        Ok(())
    })
}

/// ABI 14 (L1): forgets the held recovery-list seed (a cancelled or expired
/// claim). `out_was_held` gets 1 when one was held, else 0. Seal afterwards.
///
/// # Safety
/// `handle` must be live and `out_was_held` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_l1_recovery_hold_drop(
    handle: *mut PmCryptoHandle,
    out_was_held: *mut u8,
) -> i32 {
    ffi_call(|| {
        if out_was_held.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let held =
            unsafe { with_device_mut(handle, |device| Ok(device.drop_recovery_list_hold()))? };
        unsafe { out_was_held.write(u8::from(held)) };
        Ok(())
    })
}

/// ABI 14 (L1): signs change 4 (a recovery version) with the recovery-derived
/// key and returns the whole statement. `entropy` empty uses the held seed
/// (dropped once the statement is made; seal afterwards), else the seed is
/// derived from the typed 30-byte entropy (nothing is kept).
///
/// `body` must be a change-4 body for this device's account listing exactly
/// this device with its own signing key, and the finished statement must
/// pass the same check as [`pm_crypto_l1_check_step`] against `prev` (the
/// account's head at completion; required) and `history`, so no signature is
/// returned for a version the chain would refuse, one whose head recovery key
/// is not this seed's included. `PM_CRYPTO_L1_NO_SEED` when `entropy` is empty
/// and none is held; the L1 kinds as above otherwise.
///
/// # Safety
/// `handle` must be live, slices readable (or empty where optional) and
/// `out_statement` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_l1_sign_recovery(
    handle: *mut PmCryptoHandle,
    prev: PmByteSlice,
    history: PmByteSlice,
    body: PmByteSlice,
    entropy: PmByteSlice,
    out_statement: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_statement.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let prev = unsafe { borrowed(prev, l1::MAX_STATEMENT_BYTES)? };
        let history = unsafe { borrowed_optional(history, MAX_HISTORY_BYTES)? };
        let body = unsafe { borrowed(body, l1::MAX_STATEMENT_BYTES)? };
        let entropy = unsafe { borrowed_optional(entropy, recovery::ENTROPY_BYTES)? };
        if !entropy.is_empty() && entropy.len() != recovery::ENTROPY_BYTES {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let history = l1::decode_pairs(history).map_err(l1_status)?;
        let entropy = (!entropy.is_empty()).then_some(entropy);
        let statement = unsafe {
            with_device_mut(handle, |device| {
                device
                    .l1_sign_recovery(prev, &history, body, entropy)
                    .map_err(|error| match error {
                        RecoverySignError::NoSeed => PM_CRYPTO_L1_NO_SEED,
                        RecoverySignError::Refused(kind) => l1_status(kind),
                        RecoverySignError::Failed => PM_CRYPTO_ERROR,
                    })
            })?
        };
        unsafe { output(out_statement, statement) }
    })
}

/// ABI 14 (L1): every leaf of the group as `u16 n | n x (lp(account_id) |
/// lp(device_id) | [32] signature key)`, in leaf order, read from the
/// group's current tree. Duplicate identities are listed as they are. After a
/// Welcome the app judges each pair against its account's list.
///
/// # Safety
/// `handle` must be live, `group_id` readable and `out_members` writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_members(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
    out_members: *mut PmOwnedBuffer,
) -> i32 {
    ffi_call(|| {
        if out_members.is_null() {
            return Err(PM_CRYPTO_INVALID_ARGUMENT);
        }
        let group_id = unsafe { borrowed(group_id, MAX_ID_BYTES)? };
        let leaves = unsafe {
            with_device(handle, |device| {
                let group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device.group_leaf_pairs(&group).map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        let triples: Vec<_> = leaves.iter().map(|leaf| leaf.as_triple()).collect();
        let encoded = l1::encode_leaf_pairs(&triples).map_err(|_| PM_CRYPTO_ERROR)?;
        unsafe { output(out_members, encoded) }
    })
}

/// Writes the two L1 extras of a commit outcome. They were encoded before
/// the merge (`MlsDevice::commit_outcome`), so this only copies bytes and
/// cannot fail after the state has changed.
unsafe fn write_l1_pairs(
    outcome: &crate::mls::CommitOutcome,
    out_added: *mut PmOwnedBuffer,
    out_committer: *mut PmOwnedBuffer,
) {
    // SAFETY: the caller checked both targets before the commit was applied.
    unsafe {
        out_added.write(into_owned(outcome.added_pairs.clone()));
        out_committer.write(into_owned(outcome.committer_pair.clone()));
    }
}

/// ABI 14 (L1): [`pm_crypto_group_c7_process_commit`] that also returns the
/// pairs the commit brought in. `out_added` is `u16 n | n x (lp(account_id) |
/// lp(device_id) | [32] signature key)` for the leaves of its Add proposals
/// (n may be 0), `out_committer` the same shape with the committer's one
/// pair; both read from the staged commit and tree, never from a server
/// label. Everything else is as the C7 call: flags, epoch and (for a removal
/// that keeps this device) the exporter root. The commit is never refused
/// for an L1 reason (D94): the app judges the pairs afterwards and holds the
/// conversation, so one bad commit cannot stall sync. All outputs are checked
/// and zeroed first.
///
/// # Safety
/// `handle` must be live, slices readable and all five outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_l1_process_commit(
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
                    .process_commit_with_outcome(&mut group, commit)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe {
            write_l1_pairs(&outcome, out_added, out_committer);
            write_commit_outcome(outcome, out_flags, out_epoch, out_root);
        }
        Ok(())
    })
}

/// ABI 14 (L1): [`pm_crypto_group_c7_merge_pending_commit`] that also
/// returns the pairs this device's own staged commit added (and this
/// device's own pair as the committer), in the shapes of
/// [`pm_crypto_group_l1_process_commit`]. A group with nothing staged is
/// `PM_CRYPTO_ERROR` and is left as it is.
///
/// # Safety
/// `handle` must be live, `group_id` readable and all five outputs writable.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_group_l1_merge_pending_commit(
    handle: *mut PmCryptoHandle,
    group_id: PmByteSlice,
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
        let outcome = unsafe {
            with_device(handle, |device| {
                let mut group = device.load_group(group_id).map_err(|_| PM_CRYPTO_ERROR)?;
                device
                    .merge_pending_commit_with_outcome(&mut group)
                    .map_err(|_| PM_CRYPTO_ERROR)
            })?
        };
        unsafe {
            write_l1_pairs(&outcome, out_added, out_committer);
            write_commit_outcome(outcome, out_flags, out_epoch, out_root);
        }
        Ok(())
    })
}
