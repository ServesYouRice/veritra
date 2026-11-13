//! ABI 14 (L1): the new C entry points, called the way Dart will call them.

use super::l1_calls::*;
use super::*;
use crate::l1::{self, Body, Change, Pair, Signer};
use crate::mls::{MemberAdd, StagedCommitMessages};

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

const ENTROPY: [u8; 30] = [0x21; 30];
const OTHER_ENTROPY: [u8; 30] = [0x22; 30];

struct Member {
    handle: *mut PmCryptoHandle,
    account: &'static [u8],
    device: &'static [u8],
    key: [u8; 32],
}

fn member(account: &'static [u8], device: &'static [u8]) -> Member {
    let device_state = MlsDevice::new(account, device).unwrap();
    let key: [u8; 32] = device_state.signing_public_key().try_into().unwrap();
    Member {
        handle: new_handle(device_state),
        account,
        device,
        key,
    }
}

impl Member {
    fn pair(&self) -> Pair {
        Pair {
            device_id: self.device.to_vec(),
            signing_key: self.key,
        }
    }

    /// Signs a body through `pm_crypto_c7_sign` with the L1 label and
    /// assembles the statement, the way Dart does.
    fn sign(&self, body: &Body) -> Result<Vec<u8>, i32> {
        let bytes = l1::encode_body(body).unwrap();
        self.sign_bytes(&bytes)
    }

    fn sign_bytes(&self, bytes: &[u8]) -> Result<Vec<u8>, i32> {
        let mut signature = PmOwnedBuffer::default();
        let status = unsafe {
            pm_crypto_c7_sign(
                self.handle,
                slice(l1::LABEL_SIG),
                slice(bytes),
                &mut signature,
            )
        };
        if status != PM_CRYPTO_OK {
            assert!(is_empty(&signature));
            return Err(status);
        }
        let signature: [u8; 64] = unsafe { take(signature) }.try_into().unwrap();
        Ok(
            l1::assemble_statement(bytes, &Signer::Device(self.device.to_vec()), &signature)
                .unwrap(),
        )
    }
}

fn sorted(mut pairs: Vec<Pair>) -> Vec<Pair> {
    pairs.sort_by(|a, b| a.device_id.cmp(&b.device_id));
    pairs
}

fn body(
    account: &[u8],
    change: Change,
    version: u64,
    prev: Option<&[u8]>,
    entries: Vec<Pair>,
    recovery_key: Option<[u8; 32]>,
) -> Body {
    Body {
        account_id: account.to_vec(),
        version,
        prev_hash: prev.map_or([0; 32], |bytes| {
            l1::parse_statement(bytes).unwrap().list_hash()
        }),
        created_at_ms: 1_700_000_000_000,
        change,
        entries,
        recovery_key,
        frank_keys: Vec::new(),
    }
}

/// The account most tests here belong to.
const ACCOUNT_A: &[u8] = b"acct_a";

unsafe fn check_step(prev: &[u8], statement: &[u8], history: &[u8]) -> (i32, Vec<u8>) {
    unsafe { check_step_for(ACCOUNT_A, prev, statement, history) }
}

unsafe fn check_step_for(
    account: &[u8],
    prev: &[u8],
    statement: &[u8],
    history: &[u8],
) -> (i32, Vec<u8>) {
    let mut summary = PmOwnedBuffer::default();
    let status = unsafe {
        pm_crypto_l1_check_step(
            slice(account),
            if prev.is_empty() { EMPTY } else { slice(prev) },
            slice(statement),
            if history.is_empty() {
                EMPTY
            } else {
                slice(history)
            },
            &mut summary,
        )
    };
    if status != PM_CRYPTO_OK {
        assert!(is_empty(&summary));
        return (status, Vec::new());
    }
    (status, unsafe { take(summary) })
}

#[test]
fn the_device_signs_a_genesis_and_only_its_own() {
    let alice = member(b"acct_a", b"dev_a1");
    let bob = member(b"acct_a", b"dev_b1");
    let genesis = body(
        b"acct_a",
        Change::Genesis,
        1,
        None,
        vec![alice.pair()],
        None,
    );
    let statement = alice.sign(&genesis).unwrap();
    // The statement verifies as a genesis, and its summary says so.
    let (status, summary) = unsafe { check_step(&[], &statement, &[]) };
    assert_eq!(status, PM_CRYPTO_OK);
    assert_eq!(summary[0], 1);
    assert_eq!(summary[1], Change::Genesis as u8);
    assert_eq!(
        summary,
        l1::encode_summary(&l1::parse_statement(&statement).unwrap()).unwrap()
    );

    // A genesis that lists another device, or a different key, is refused
    // before signing.
    let other = body(b"acct_a", Change::Genesis, 1, None, vec![bob.pair()], None);
    assert_eq!(alice.sign(&other), Err(PM_CRYPTO_L1_RULE));
    let mut forged = alice.pair();
    forged.signing_key = bob.key;
    let forged = body(b"acct_a", Change::Genesis, 1, None, vec![forged], None);
    assert_eq!(alice.sign(&forged), Err(PM_CRYPTO_L1_RULE));
    let two = body(
        b"acct_a",
        Change::Genesis,
        1,
        None,
        sorted(vec![alice.pair(), bob.pair()]),
        None,
    );
    assert_eq!(alice.sign(&two), Err(PM_CRYPTO_L1_RULE));
    // Another account's list is not this device's to sign.
    let foreign = body(
        b"acct_z",
        Change::Genesis,
        1,
        None,
        vec![alice.pair()],
        None,
    );
    assert_eq!(alice.sign(&foreign), Err(PM_CRYPTO_L1_RULE));
    // A recovery version is signed by the recovery key only.
    let recovery = body(
        b"acct_a",
        Change::Recovery,
        2,
        Some(&statement),
        vec![alice.pair()],
        Some([9; 32]),
    );
    assert_eq!(
        alice.sign_bytes(&l1::encode_body(&recovery).unwrap()),
        Err(PM_CRYPTO_L1_RULE)
    );
    // Bytes that are not a body are malformed, and nothing is signed.
    assert_eq!(
        alice.sign_bytes(b"not a device list body"),
        Err(PM_CRYPTO_L1_MALFORMED)
    );
    let mut trailing = l1::encode_body(&genesis).unwrap();
    trailing.push(0);
    assert_eq!(alice.sign_bytes(&trailing), Err(PM_CRYPTO_L1_MALFORMED));
    // A migration genesis may list the others, but must list this device.
    let migration = body(
        b"acct_a",
        Change::MigrationGenesis,
        1,
        None,
        sorted(vec![alice.pair(), bob.pair()]),
        None,
    );
    let statement = alice.sign(&migration).unwrap();
    assert_eq!(unsafe { check_step(&[], &statement, &[]) }.0, PM_CRYPTO_OK);
    let without = body(
        b"acct_a",
        Change::MigrationGenesis,
        1,
        None,
        vec![bob.pair()],
        None,
    );
    assert_eq!(alice.sign(&without), Err(PM_CRYPTO_L1_RULE));
}

#[test]
fn the_l1_label_cannot_sign_raw_bytes_or_be_verified_as_a_c7_domain() {
    let alice = member(b"acct_a", b"dev_a1");
    let mut verified = 7u8;
    unsafe {
        // The L1 label is not a C7 verify domain.
        assert_eq!(
            pm_crypto_c7_verify(
                slice(l1::LABEL_SIG),
                slice(&alice.key),
                slice(b"message"),
                slice(&[0u8; 64]),
                &mut verified,
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(verified, 7);
        // Other labels still do not sign, and the C7 ones still do.
        let mut out = PmOwnedBuffer::default();
        for label in [
            &b"veritra-l1-device-list-hash-v1"[..],
            b"veritra-enrollment-proof-v1",
        ] {
            assert_eq!(
                pm_crypto_c7_sign(alice.handle, slice(label), slice(b"message"), &mut out),
                PM_CRYPTO_INVALID_ARGUMENT
            );
        }
        assert_eq!(
            pm_crypto_c7_sign(
                alice.handle,
                slice(b"veritra-c7-post-sig-v1"),
                slice(b"message"),
                &mut out,
            ),
            PM_CRYPTO_OK
        );
        assert_eq!(take(out).len(), 64);
    }
    // An L1 signature is not a C7 signature over the same bytes, and the other
    // way round: the signed bytes differ by label and by what is hashed.
    let genesis = body(
        b"acct_a",
        Change::Genesis,
        1,
        None,
        vec![alice.pair()],
        None,
    );
    let bytes = l1::encode_body(&genesis).unwrap();
    let statement = alice.sign_bytes(&bytes).unwrap();
    let parsed = l1::parse_statement(&statement).unwrap();
    for domain in crate::c7::SIGN_DOMAINS {
        assert!(!crate::c7::verify(domain, &alice.key, &bytes, &parsed.signature).unwrap());
    }
}

/// A chain built with real devices: A genesis, A adds B, B sets the recovery
/// key, A is removed by B.
#[allow(clippy::vec_init_then_push)]
fn real_chain(a: &Member, b: &Member) -> Vec<Vec<u8>> {
    let rk = recovery::derive(&ENTROPY).unwrap().rk_list_pub;
    let mut statements: Vec<Vec<u8>> = Vec::new();
    statements.push(
        a.sign(&body(
            a.account,
            Change::Genesis,
            1,
            None,
            vec![a.pair()],
            None,
        ))
        .unwrap(),
    );
    statements.push(
        a.sign(&body(
            a.account,
            Change::Add,
            2,
            Some(&statements[0]),
            sorted(vec![a.pair(), b.pair()]),
            None,
        ))
        .unwrap(),
    );
    statements.push(
        b.sign(&body(
            a.account,
            Change::RecoveryKey,
            3,
            Some(&statements[1]),
            sorted(vec![a.pair(), b.pair()]),
            Some(rk),
        ))
        .unwrap(),
    );
    statements.push(
        b.sign(&body(
            a.account,
            Change::Remove,
            4,
            Some(&statements[2]),
            vec![b.pair()],
            Some(rk),
        ))
        .unwrap(),
    );
    statements
}

fn chain_bytes(statements: &[Vec<u8>]) -> Vec<u8> {
    let mut out = (statements.len() as u16).to_be_bytes().to_vec();
    for statement in statements {
        out.extend_from_slice(&(statement.len() as u16).to_be_bytes());
        out.extend_from_slice(statement);
    }
    out
}

#[test]
fn real_devices_build_a_chain_the_abi_verifies_step_and_whole() {
    let a = member(b"acct_a", b"dev_a1");
    let b = member(b"acct_a", b"dev_b1");
    let statements = real_chain(&a, &b);
    unsafe {
        let mut history: Vec<u8> = Vec::new();
        for (index, statement) in statements.iter().enumerate() {
            let prev = if index == 0 {
                &[][..]
            } else {
                &statements[index - 1]
            };
            let (status, _) = check_step(prev, statement, &history);
            assert_eq!(status, PM_CRYPTO_OK, "step {}", index + 1);
        }
        history.clear();
        let mut result = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_l1_check_chain(
                slice(ACCOUNT_A),
                slice(&chain_bytes(&statements)),
                &mut result
            ),
            PM_CRYPTO_OK
        );
        let result = take(result);
        let parsed: Vec<_> = statements
            .iter()
            .map(|bytes| l1::parse_statement(bytes).unwrap())
            .collect();
        let expected =
            l1::encode_chain_result(&l1::check_chain(ACCOUNT_A, &parsed).unwrap()).unwrap();
        assert_eq!(result, expected);

        // B signs nothing for a removed device, and a rollback to the second
        // version is refused as a chain error.
        let (status, _) = check_step(&statements[2], &statements[1], &[]);
        assert_eq!(status, PM_CRYPTO_L1_CHAIN);
        // A gap.
        let (status, _) = check_step(&statements[0], &statements[2], &[]);
        assert_eq!(status, PM_CRYPTO_L1_CHAIN);
        // Argument errors are not statement errors.
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_l1_check_step(slice(ACCOUNT_A), EMPTY, EMPTY, EMPTY, &mut out),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_l1_check_step(
                slice(ACCOUNT_A),
                EMPTY,
                slice(&statements[0]),
                EMPTY,
                core::ptr::null_mut()
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_l1_check_chain(slice(ACCOUNT_A), slice(&[0, 0]), &mut out),
            PM_CRYPTO_L1_MALFORMED
        );
        assert!(is_empty(&out));
        let mut truncated = chain_bytes(&statements);
        truncated.pop();
        assert_eq!(
            pm_crypto_l1_check_chain(slice(ACCOUNT_A), slice(&truncated), &mut out),
            PM_CRYPTO_L1_MALFORMED
        );
    }
    // A device that is removed no longer signs for the list.
    let late = body(
        b"acct_a",
        Change::Add,
        5,
        Some(&statements[3]),
        sorted(vec![a.pair(), b.pair()]),
        l1::parse_statement(&statements[3])
            .unwrap()
            .body
            .recovery_key,
    );
    let statement = a.sign(&late).unwrap();
    assert_eq!(
        unsafe { check_step(&statements[3], &statement, &[]) }.0,
        PM_CRYPTO_L1_RULE
    );
}

fn derive_list_pub(entropy: &[u8]) -> Vec<u8> {
    let (mut a, mut b, mut c, mut d) = (
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
    );
    unsafe {
        assert_eq!(
            pm_crypto_recovery_key_derive(slice(entropy), &mut a, &mut b, &mut c, &mut d),
            PM_CRYPTO_OK
        );
        take(a);
        take(b);
        take(c);
        take(d)
    }
}

#[test]
fn recovery_signs_change_four_from_the_held_seed_or_typed_entropy() {
    let old = member(b"acct_a", b"dev_a1");
    let recovered = member(b"acct_a", b"dev_r1");
    let rk = derive_list_pub(&ENTROPY);
    let rk_array: [u8; 32] = rk.clone().try_into().unwrap();
    let genesis = old
        .sign(&body(
            old.account,
            Change::Genesis,
            1,
            None,
            vec![old.pair()],
            None,
        ))
        .unwrap();
    let with_rk = old
        .sign(&body(
            old.account,
            Change::RecoveryKey,
            2,
            Some(&genesis),
            vec![old.pair()],
            Some(rk_array),
        ))
        .unwrap();
    let recovery_body = body(
        b"acct_a",
        Change::Recovery,
        3,
        Some(&with_rk),
        vec![recovered.pair()],
        Some(rk_array),
    );
    let bytes = l1::encode_body(&recovery_body).unwrap();
    let history = {
        let mut out = 1u16.to_be_bytes().to_vec();
        out.extend_from_slice(&(old.device.len() as u16).to_be_bytes());
        out.extend_from_slice(old.device);
        out.extend_from_slice(&old.key);
        out
    };
    unsafe {
        // Nothing held: the held-seed call has no seed to use.
        let mut statement = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_l1_sign_recovery(
                recovered.handle,
                slice(&with_rk),
                slice(&history),
                slice(&bytes),
                EMPTY,
                &mut statement,
            ),
            PM_CRYPTO_L1_NO_SEED
        );
        let mut public = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_l1_recovery_hold_public(recovered.handle, &mut public),
            PM_CRYPTO_OK
        );
        assert!(is_empty(&public));

        // Hold the seed derived from the typed entropy; its public key is the
        // one the derive call reports.
        assert_eq!(
            pm_crypto_l1_recovery_hold(recovered.handle, slice(&ENTROPY)),
            PM_CRYPTO_OK
        );
        assert_eq!(
            pm_crypto_l1_recovery_hold_public(recovered.handle, &mut public),
            PM_CRYPTO_OK
        );
        assert_eq!(take(public), rk);
        // Wrong length is an argument error and changes nothing.
        assert_eq!(
            pm_crypto_l1_recovery_hold(recovered.handle, slice(&ENTROPY[..29])),
            PM_CRYPTO_INVALID_ARGUMENT
        );

        // A body that is not this device's recovery version is refused with
        // no signature: another device, two devices, a device signer's change.
        for wrong in [
            body(
                b"acct_a",
                Change::Recovery,
                3,
                Some(&with_rk),
                vec![old.pair()],
                Some(rk_array),
            ),
            body(
                b"acct_a",
                Change::Recovery,
                3,
                Some(&with_rk),
                sorted(vec![recovered.pair(), old.pair()]),
                Some(rk_array),
            ),
            body(
                b"acct_a",
                Change::Add,
                3,
                Some(&with_rk),
                sorted(vec![recovered.pair(), old.pair()]),
                Some(rk_array),
            ),
        ] {
            let wrong = l1::encode_body(&wrong).unwrap();
            let mut out = PmOwnedBuffer::default();
            assert_eq!(
                pm_crypto_l1_sign_recovery(
                    recovered.handle,
                    slice(&with_rk),
                    slice(&history),
                    slice(&wrong),
                    EMPTY,
                    &mut out,
                ),
                PM_CRYPTO_L1_RULE
            );
            assert!(is_empty(&out));
        }
        // Typed entropy that is not the head's recovery key signs nothing,
        // and neither does a head that is not the version the body chains
        // from. The held seed is still held after a refusal.
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_l1_sign_recovery(
                recovered.handle,
                slice(&with_rk),
                slice(&history),
                slice(&bytes),
                slice(&OTHER_ENTROPY),
                &mut out,
            ),
            PM_CRYPTO_L1_SIGNATURE
        );
        assert!(is_empty(&out));
        assert_eq!(
            pm_crypto_l1_sign_recovery(
                recovered.handle,
                slice(&genesis),
                slice(&history),
                slice(&bytes),
                EMPTY,
                &mut out,
            ),
            PM_CRYPTO_L1_CHAIN
        );
        // A refusal keeps the seed.
        assert_eq!(
            pm_crypto_l1_recovery_hold_public(recovered.handle, &mut public),
            PM_CRYPTO_OK
        );
        assert_eq!(take(public), rk);

        // The held seed signs, the statement verifies, and the seed is gone.
        assert_eq!(
            pm_crypto_l1_sign_recovery(
                recovered.handle,
                slice(&with_rk),
                slice(&history),
                slice(&bytes),
                EMPTY,
                &mut out,
            ),
            PM_CRYPTO_OK
        );
        let signed = take(out);
        let (status, summary) = check_step(&with_rk, &signed, &history);
        assert_eq!(status, PM_CRYPTO_OK);
        assert_eq!(summary[1], Change::Recovery as u8);
        assert_eq!(summary[2], l1::SIGNER_RECOVERY);
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_l1_sign_recovery(
                recovered.handle,
                slice(&with_rk),
                slice(&history),
                slice(&bytes),
                EMPTY,
                &mut out,
            ),
            PM_CRYPTO_L1_NO_SEED
        );
        assert_eq!(
            pm_crypto_l1_recovery_hold_public(recovered.handle, &mut public),
            PM_CRYPTO_OK
        );
        assert!(is_empty(&public));

        // The typed-entropy fallback signs the same statement (Ed25519 is
        // deterministic) and keeps nothing.
        assert_eq!(
            pm_crypto_l1_sign_recovery(
                recovered.handle,
                slice(&with_rk),
                slice(&history),
                slice(&bytes),
                slice(&ENTROPY),
                &mut out,
            ),
            PM_CRYPTO_OK
        );
        assert_eq!(take(out), signed);
        assert_eq!(
            pm_crypto_l1_recovery_hold_public(recovered.handle, &mut public),
            PM_CRYPTO_OK
        );
        assert!(is_empty(&public));

        // Dropping a hold reports whether there was one.
        let mut was_held = 9u8;
        assert_eq!(
            pm_crypto_l1_recovery_hold_drop(recovered.handle, &mut was_held),
            PM_CRYPTO_OK
        );
        assert_eq!(was_held, 0);
        assert_eq!(
            pm_crypto_l1_recovery_hold(recovered.handle, slice(&ENTROPY)),
            PM_CRYPTO_OK
        );
        assert_eq!(
            pm_crypto_l1_recovery_hold_drop(recovered.handle, &mut was_held),
            PM_CRYPTO_OK
        );
        assert_eq!(was_held, 1);
    }
}

#[test]
fn the_recovered_device_cannot_return_a_removed_device() {
    // The history argument carries the no-return rule into the signing call.
    let old = member(b"acct_a", b"dev_a1");
    let recovered = member(b"acct_a", b"dev_r1");
    let rk: [u8; 32] = derive_list_pub(&ENTROPY).try_into().unwrap();
    let genesis = old
        .sign(&body(
            old.account,
            Change::Genesis,
            1,
            None,
            vec![old.pair()],
            None,
        ))
        .unwrap();
    let head = old
        .sign(&body(
            old.account,
            Change::RecoveryKey,
            2,
            Some(&genesis),
            vec![old.pair()],
            Some(rk),
        ))
        .unwrap();
    // The "recovered" device was listed and removed before (history says so).
    let history = {
        let mut out = 1u16.to_be_bytes().to_vec();
        out.extend_from_slice(&(recovered.device.len() as u16).to_be_bytes());
        out.extend_from_slice(recovered.device);
        out.extend_from_slice(&recovered.key);
        out
    };
    let bytes = l1::encode_body(&body(
        b"acct_a",
        Change::Recovery,
        3,
        Some(&head),
        vec![recovered.pair()],
        Some(rk),
    ))
    .unwrap();
    let mut out = PmOwnedBuffer::default();
    assert_eq!(
        unsafe {
            pm_crypto_l1_sign_recovery(
                recovered.handle,
                slice(&head),
                slice(&history),
                slice(&bytes),
                slice(&ENTROPY),
                &mut out,
            )
        },
        PM_CRYPTO_L1_RULE
    );
    assert!(is_empty(&out));
}

// ---- groups --------------------------------------------------------------

fn parse_leaves(bytes: &[u8]) -> Vec<(Vec<u8>, Vec<u8>, Vec<u8>)> {
    let count = u16::from_be_bytes([bytes[0], bytes[1]]) as usize;
    let mut offset = 2;
    let mut out = Vec::new();
    for _ in 0..count {
        let mut fields = Vec::new();
        for _ in 0..2 {
            let len = u16::from_be_bytes([bytes[offset], bytes[offset + 1]]) as usize;
            fields.push(bytes[offset + 2..offset + 2 + len].to_vec());
            offset += 2 + len;
        }
        out.push((
            fields.remove(0),
            fields.remove(0),
            bytes[offset..offset + 32].to_vec(),
        ));
        offset += 32;
    }
    assert_eq!(offset, bytes.len());
    out
}

struct Added {
    status: i32,
    flags: u8,
    epoch: u64,
    added: Vec<(Vec<u8>, Vec<u8>, Vec<u8>)>,
    committer: Vec<(Vec<u8>, Vec<u8>, Vec<u8>)>,
    root: bool,
}

unsafe fn l1_process(handle: *mut PmCryptoHandle, group: &[u8], commit: &[u8]) -> Added {
    let (mut flags, mut epoch) = (9u8, 9u64);
    let (mut root, mut added, mut committer) = (
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
    );
    let status = unsafe {
        pm_crypto_group_l1_process_commit(
            handle,
            slice(group),
            slice(commit),
            &mut flags,
            &mut epoch,
            &mut root,
            &mut added,
            &mut committer,
        )
    };
    finish_added(status, flags, epoch, root, added, committer)
}

unsafe fn l1_merge(handle: *mut PmCryptoHandle, group: &[u8]) -> Added {
    let (mut flags, mut epoch) = (9u8, 9u64);
    let (mut root, mut added, mut committer) = (
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
        PmOwnedBuffer::default(),
    );
    let status = unsafe {
        pm_crypto_group_l1_merge_pending_commit(
            handle,
            slice(group),
            &mut flags,
            &mut epoch,
            &mut root,
            &mut added,
            &mut committer,
        )
    };
    finish_added(status, flags, epoch, root, added, committer)
}

fn finish_added(
    status: i32,
    flags: u8,
    epoch: u64,
    root: PmOwnedBuffer,
    added: PmOwnedBuffer,
    committer: PmOwnedBuffer,
) -> Added {
    let has_root = !is_empty(&root);
    if has_root {
        unsafe { take(root) };
    }
    let parse = |buffer: PmOwnedBuffer| {
        if is_empty(&buffer) {
            Vec::new()
        } else {
            parse_leaves(&unsafe { take(buffer) })
        }
    };
    Added {
        status,
        flags,
        epoch,
        added: parse(added),
        committer: parse(committer),
        root: has_root,
    }
}

fn triple(account: &[u8], device: &[u8], key: &[u8]) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    (account.to_vec(), device.to_vec(), key.to_vec())
}

#[allow(clippy::type_complexity)]
fn keyed_changes(adds: &[(&[u8], &[u8], &[u8], &[u8])], removes: &[(&[u8], &[u8])]) -> Vec<u8> {
    let mut out = vec![MEMBERSHIP_CHANGES_VERSION_KEYED];
    out.extend_from_slice(&(adds.len() as u16).to_be_bytes());
    for (key_package, account, device, signing_key) in adds {
        out.extend_from_slice(&(key_package.len() as u32).to_be_bytes());
        out.extend_from_slice(key_package);
        out.extend_from_slice(&(account.len() as u16).to_be_bytes());
        out.extend_from_slice(account);
        out.extend_from_slice(&(device.len() as u16).to_be_bytes());
        out.extend_from_slice(device);
        out.extend_from_slice(signing_key);
    }
    out.extend_from_slice(&(removes.len() as u16).to_be_bytes());
    for (account, device) in removes {
        out.extend_from_slice(&(account.len() as u16).to_be_bytes());
        out.extend_from_slice(account);
        out.extend_from_slice(&(device.len() as u16).to_be_bytes());
        out.extend_from_slice(device);
    }
    out
}

unsafe fn stage(
    handle: *mut PmCryptoHandle,
    group: &[u8],
    changes: &[u8],
) -> Result<StagedCommitMessages, i32> {
    let (mut commit, mut welcome, mut epoch) =
        (PmOwnedBuffer::default(), PmOwnedBuffer::default(), 0u64);
    let status = unsafe {
        pm_crypto_group_stage_commit(
            handle,
            slice(group),
            slice(changes),
            &mut commit,
            &mut welcome,
            &mut epoch,
        )
    };
    if status != PM_CRYPTO_OK {
        assert!(is_empty(&commit) && is_empty(&welcome));
        return Err(status);
    }
    Ok(StagedCommitMessages {
        commit: unsafe { take(commit) },
        welcome: if is_empty(&welcome) {
            Vec::new()
        } else {
            unsafe { take(welcome) }
        },
        epoch,
    })
}

#[test]
fn adds_carry_the_expected_signing_key_and_commits_report_their_pairs() {
    let group = b"conv_l1_pairs";
    let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
    let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
    let carol = MlsDevice::new(b"acct_carol", b"dev_carol").unwrap();
    let alice_key = alice.signing_public_key().to_vec();
    let bob_key = bob.signing_public_key().to_vec();
    let carol_key = carol.signing_public_key().to_vec();
    let bob_kp = bob.create_key_package().unwrap();
    let carol_kp = carol.create_key_package().unwrap();
    // Alice's group with Bob in it, through the plain Rust API.
    let mut alice_group = alice.create_group(group).unwrap();
    let first: StagedCommitMessages = alice
        .stage_membership_commit(
            &mut alice_group,
            &[MemberAdd {
                key_package: &bob_kp,
                account_id: b"acct_bob",
                device_id: b"dev_bob",
            }],
            &[],
        )
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    bob.join_group(group, &first.welcome).unwrap();
    let (alice, bob) = (new_handle(alice), new_handle(bob));

    unsafe {
        // Every leaf, in leaf order, with its key.
        let mut members = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_group_members(alice, slice(group), &mut members),
            PM_CRYPTO_OK
        );
        assert_eq!(
            parse_leaves(&take(members)),
            vec![
                triple(b"acct_alice", b"dev_alice", &alice_key),
                triple(b"acct_bob", b"dev_bob", &bob_key),
            ]
        );
        let mut members = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_group_members(alice, slice(b"conv_unknown"), &mut members),
            PM_CRYPTO_ERROR
        );
        assert!(is_empty(&members));
        assert_eq!(
            pm_crypto_group_members(alice, slice(group), core::ptr::null_mut()),
            PM_CRYPTO_INVALID_ARGUMENT
        );

        // A key package whose leaf key differs from the expected one is
        // refused (version 2); the right key stages; version 1 still stages.
        let wrong_key = [0xEE; 32];
        let refused = keyed_changes(&[(&carol_kp, b"acct_carol", b"dev_carol", &wrong_key)], &[]);
        assert_eq!(stage(alice, group, &refused).err(), Some(PM_CRYPTO_ERROR));
        let mut epoch = 0u64;
        let mut pending = 9u8;
        assert_eq!(
            pm_crypto_group_epoch(alice, slice(group), &mut epoch, &mut pending),
            PM_CRYPTO_OK
        );
        assert_eq!(pending, 0, "a refused add stages nothing");
        let truncated_key =
            keyed_changes(&[(&carol_kp, b"acct_carol", b"dev_carol", &carol_key)], &[]);
        assert_eq!(
            stage(alice, group, &truncated_key[..truncated_key.len() - 3]).err(),
            Some(PM_CRYPTO_INVALID_ARGUMENT)
        );
        let accepted = stage(alice, group, &truncated_key).unwrap();
        assert!(!accepted.welcome.is_empty());

        // Her own merge reports the pairs her commit added, and her own
        // pair as the committer.
        let own = l1_merge(alice, group);
        assert_eq!(own.status, PM_CRYPTO_OK);
        assert_eq!(own.flags, PM_CRYPTO_C7_COMMIT_ADDED);
        assert_eq!(own.epoch, 2);
        assert_eq!(
            own.added,
            vec![triple(b"acct_carol", b"dev_carol", &carol_key)]
        );
        assert_eq!(
            own.committer,
            vec![triple(b"acct_alice", b"dev_alice", &alice_key)]
        );
        assert!(!own.root);
        // Nothing staged: refused, outputs empty.
        let none = l1_merge(alice, group);
        assert_eq!(none.status, PM_CRYPTO_ERROR);
        assert!(none.added.is_empty() && none.committer.is_empty());
        assert_eq!((none.flags, none.epoch), (0, 0));

        // Bob sees the same pairs from the commit bytes alone.
        let seen = l1_process(bob, group, &accepted.commit);
        assert_eq!(seen.status, PM_CRYPTO_OK);
        assert_eq!(seen.flags, PM_CRYPTO_C7_COMMIT_ADDED);
        assert_eq!(seen.epoch, 2);
        assert_eq!(seen.added, own.added);
        assert_eq!(seen.committer, own.committer);
        let mut members = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_group_members(bob, slice(group), &mut members),
            PM_CRYPTO_OK
        );
        assert_eq!(parse_leaves(&take(members)).len(), 3);

        // A removal commit reports no added pairs but its committer and root.
        let removal = stage(bob, group, &{
            let mut out = vec![MEMBERSHIP_CHANGES_VERSION];
            out.extend_from_slice(&0u16.to_be_bytes());
            out.extend_from_slice(&1u16.to_be_bytes());
            for id in [&b"acct_carol"[..], b"dev_carol"] {
                out.extend_from_slice(&(id.len() as u16).to_be_bytes());
                out.extend_from_slice(id);
            }
            out
        })
        .unwrap();
        let bob_own = l1_merge(bob, group);
        assert_eq!(bob_own.flags, PM_CRYPTO_C7_COMMIT_REMOVED);
        assert!(bob_own.added.is_empty());
        assert_eq!(
            bob_own.committer,
            vec![triple(b"acct_bob", b"dev_bob", &bob_key)]
        );
        assert!(bob_own.root);
        let alice_seen = l1_process(alice, group, &removal.commit);
        assert_eq!(alice_seen.status, PM_CRYPTO_OK);
        assert_eq!(alice_seen.flags, PM_CRYPTO_C7_COMMIT_REMOVED);
        assert_eq!(alice_seen.committer, bob_own.committer);
        assert!(alice_seen.root);

        // A refused commit leaves every output empty and the epoch alone.
        let refused = l1_process(alice, group, b"not a commit");
        assert_ne!(refused.status, PM_CRYPTO_OK);
        assert!(refused.added.is_empty() && refused.committer.is_empty() && !refused.root);
        assert_eq!((refused.flags, refused.epoch), (0, 0));
        let null = pm_crypto_group_l1_process_commit(
            alice,
            slice(group),
            slice(&removal.commit),
            core::ptr::null_mut(),
            &mut 0u64,
            &mut PmOwnedBuffer::default(),
            &mut PmOwnedBuffer::default(),
            &mut PmOwnedBuffer::default(),
        );
        assert_eq!(null, PM_CRYPTO_INVALID_ARGUMENT);
    }
}

#[test]
fn derive_reports_the_list_key() {
    let derived = recovery::derive(&ENTROPY).unwrap();
    assert_eq!(derive_list_pub(&ENTROPY), derived.rk_list_pub.to_vec());
}

#[test]
fn the_chain_checks_are_bound_to_the_account_asked_about() {
    let a = member(b"acct_a", b"dev_a1");
    let b = member(b"acct_a", b"dev_b1");
    let statements = real_chain(&a, &b);
    // The same valid chain, asked for as another account: refused as a chain
    // error by the step check (genesis and later versions) and the whole.
    let other: &[u8] = b"acct_other";
    unsafe {
        for (index, statement) in statements.iter().enumerate() {
            let prev = if index == 0 {
                &[][..]
            } else {
                &statements[index - 1]
            };
            let (status, summary) = check_step_for(other, prev, statement, &[]);
            assert_eq!(status, PM_CRYPTO_L1_CHAIN, "step {}", index + 1);
            assert!(summary.is_empty());
        }
        let chain = chain_bytes(&statements);
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_l1_check_chain(slice(other), slice(&chain), &mut out),
            PM_CRYPTO_L1_CHAIN
        );
        assert!(is_empty(&out));
        // A prefix of the account's own name is another account.
        assert_eq!(
            pm_crypto_l1_check_chain(slice(b"acct_"), slice(&chain), &mut out),
            PM_CRYPTO_L1_CHAIN
        );
        // The expected account is required: empty and over-long arguments
        // are argument errors, not statement errors.
        let long = [b'x'; 129];
        for bad in [EMPTY, slice(&long)] {
            assert_eq!(
                pm_crypto_l1_check_chain(bad, slice(&chain), &mut out),
                PM_CRYPTO_INVALID_ARGUMENT
            );
            assert_eq!(
                pm_crypto_l1_check_step(bad, EMPTY, slice(&statements[0]), EMPTY, &mut out),
                PM_CRYPTO_INVALID_ARGUMENT
            );
        }
        assert!(is_empty(&out));
        // The right account still verifies.
        assert_eq!(
            pm_crypto_l1_check_chain(slice(ACCOUNT_A), slice(&chain), &mut out),
            PM_CRYPTO_OK
        );
        take(out);
    }
}

/// D94: a commit is applied, then held; it is never refused for an L1
/// reason, and nothing fails after the merge. A member that commits an Add
/// whose credential ids are not UTF-8 is merged, and the pairs come back as
/// the raw bytes.
#[test]
fn a_non_utf8_device_id_in_an_add_is_merged_and_reported_as_bytes() {
    let group = b"conv_l1_non_utf8";
    let bad_account: &[u8] = b"\xc3\x28_acct";
    let bad_device: &[u8] = b"\xff\xfe";
    let alice = MlsDevice::new(b"acct_alice", b"dev_alice").unwrap();
    let bob = MlsDevice::new(b"acct_bob", b"dev_bob").unwrap();
    let mallory = MlsDevice::new(bad_account, bad_device).unwrap();
    let mallory_key = mallory.signing_public_key().to_vec();
    let bob_kp = bob.create_key_package().unwrap();
    let mallory_kp = mallory.create_key_package().unwrap();
    let mut alice_group = alice.create_group(group).unwrap();
    let first: StagedCommitMessages = alice
        .stage_membership_commit(
            &mut alice_group,
            &[MemberAdd {
                key_package: &bob_kp,
                account_id: b"acct_bob",
                device_id: b"dev_bob",
            }],
            &[],
        )
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    bob.join_group(group, &first.welcome).unwrap();
    let (alice, bob) = (new_handle(alice), new_handle(bob));
    unsafe {
        let changes = keyed_changes(&[(&mallory_kp, bad_account, bad_device, &mallory_key)], &[]);
        let staged = stage(alice, group, &changes).unwrap();
        // Bob merges it and is told the bytes, status OK.
        let seen = l1_process(bob, group, &staged.commit);
        assert_eq!(seen.status, PM_CRYPTO_OK);
        assert_eq!(seen.epoch, 2);
        assert_eq!(seen.flags, PM_CRYPTO_C7_COMMIT_ADDED);
        assert_eq!(
            seen.added,
            vec![triple(bad_account, bad_device, &mallory_key)]
        );
        assert_eq!(seen.committer.len(), 1);
        let mut epoch = 0u64;
        let mut pending = 9u8;
        assert_eq!(
            pm_crypto_group_epoch(bob, slice(group), &mut epoch, &mut pending),
            PM_CRYPTO_OK
        );
        assert_eq!(epoch, 2, "the commit is applied");
        // Her own merge reports the same bytes, and the members are listed.
        let own = l1_merge(alice, group);
        assert_eq!(own.status, PM_CRYPTO_OK);
        assert_eq!(own.added, seen.added);
        let mut members = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_group_members(bob, slice(group), &mut members),
            PM_CRYPTO_OK
        );
        let leaves = parse_leaves(&take(members));
        assert_eq!(leaves.len(), 3);
        assert_eq!(leaves[2], triple(bad_account, bad_device, &mallory_key));
    }
}
