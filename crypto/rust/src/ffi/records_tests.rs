//! ABI 10 (D70 S3): change sets, the three-step restore, the v3 migration,
//! group delete, key package pruning and the -8 / -9 codes, through the C
//! entry points.

use super::*;
use std::collections::BTreeMap;

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

/// A stand-in for the app's records table and root singleton.
#[derive(Clone, Default)]
pub(crate) struct Table {
    pub(crate) generation: u64,
    pub(crate) root: Vec<u8>,
    pub(crate) records: BTreeMap<(u8, Vec<u8>), Vec<u8>>,
}

struct Reader<'a>(&'a [u8]);
impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> &'a [u8] {
        let (head, tail) = self.0.split_at(n);
        self.0 = tail;
        head
    }
    fn u8(&mut self) -> u8 {
        self.take(1)[0]
    }
    fn u16(&mut self) -> usize {
        u16::from_be_bytes(self.take(2).try_into().unwrap()).into()
    }
    fn u32(&mut self) -> usize {
        u32::from_be_bytes(self.take(4).try_into().unwrap()) as usize
    }
    fn u64(&mut self) -> u64 {
        u64::from_be_bytes(self.take(8).try_into().unwrap())
    }
}

/// One parsed change: kind, id, generation, sealed record or delete.
type Change = (u8, Vec<u8>, u64, Option<Vec<u8>>);

fn parse(bytes: &[u8]) -> (Vec<u8>, Vec<Change>) {
    let mut reader = Reader(bytes);
    let root_len = reader.u32();
    let root = reader.take(root_len).to_vec();
    let count = reader.u32();
    let mut changes = Vec::new();
    for _ in 0..count {
        let kind = reader.u8();
        let id_len = reader.u16();
        let id = reader.take(id_len).to_vec();
        let generation = reader.u64();
        let sealed = match reader.u8() {
            1 => {
                let len = reader.u32();
                Some(reader.take(len).to_vec())
            }
            0 => None,
            other => panic!("bad presence byte {other}"),
        };
        changes.push((kind, id, generation, sealed));
    }
    assert!(reader.0.is_empty());
    (root, changes)
}

fn seal_raw(handle: *mut PmCryptoHandle, key: &[u8], generation: u64) -> Result<Vec<u8>, i32> {
    let mut out = PmOwnedBuffer::default();
    let code = unsafe { pm_crypto_device_seal_changes(handle, slice(key), generation, &mut out) };
    let bytes = if out.data.is_null() {
        Vec::new()
    } else {
        unsafe { take(out) }
    };
    if code == PM_CRYPTO_OK {
        Ok(bytes)
    } else {
        // Only the record-limit code names a record.
        assert_eq!(bytes.is_empty(), code != PM_CRYPTO_RECORD_LIMIT);
        Err(code)
    }
}

impl Table {
    pub(crate) fn apply(&mut self, bytes: &[u8]) -> Vec<Change> {
        let (root, changes) = parse(bytes);
        self.generation += 1;
        self.root = root;
        for (kind, id, generation, sealed) in &changes {
            assert_eq!(*generation, self.generation);
            match sealed {
                Some(sealed) => {
                    self.records.insert((*kind, id.clone()), sealed.clone());
                }
                None => {
                    self.records.remove(&(*kind, id.clone()));
                }
            }
        }
        changes
    }

    fn commit(&mut self, handle: *mut PmCryptoHandle, key: &[u8]) -> Vec<Change> {
        let bytes = seal_raw(handle, key, self.generation + 1).unwrap();
        self.apply(&bytes)
    }
}

/// Seals a fresh device's state at `generation` into a new table.
pub(crate) fn seal(handle: *mut PmCryptoHandle, key: &[u8], generation: u64) -> Result<Table, i32> {
    let bytes = seal_raw(handle, key, generation)?;
    let mut table = Table {
        generation: generation - 1,
        ..Table::default()
    };
    table.apply(&bytes);
    Ok(table)
}

fn begin(account: &[u8], device: &[u8], key: &[u8], minimum: u64, root: &[u8]) -> Result<u64, i32> {
    let mut loader = 0;
    let mut generation = 0;
    let code = unsafe {
        pm_crypto_restore_begin(
            slice(account),
            slice(device),
            slice(key),
            minimum,
            slice(root),
            &mut loader,
            &mut generation,
        )
    };
    if code != PM_CRYPTO_OK {
        return Err(code);
    }
    Ok(loader)
}

fn finish(loader: u64) -> Result<(*mut PmCryptoHandle, u64), i32> {
    let mut handle = ptr::null_mut();
    let mut generation = 0;
    let code = unsafe { pm_crypto_restore_finish(loader, &mut handle, &mut generation) };
    if code != PM_CRYPTO_OK {
        assert!(handle.is_null());
        return Err(code);
    }
    Ok((handle, generation))
}

/// Restores from every record in `table`, the way the app does.
pub(crate) fn restore(
    account: &[u8],
    device: &[u8],
    key: &[u8],
    minimum: u64,
    table: &Table,
) -> Result<(*mut PmCryptoHandle, u64), i32> {
    let loader = begin(account, device, key, minimum, &table.root)?;
    for sealed in table.records.values() {
        let code = unsafe { pm_crypto_restore_add(loader, slice(sealed)) };
        if code != PM_CRYPTO_OK {
            assert_eq!(pm_crypto_restore_abort(loader), PM_CRYPTO_OK);
            return Err(code);
        }
    }
    finish(loader)
}

const KEY: [u8; 32] = [3; 32];

fn create(account: &[u8], device: &[u8]) -> *mut PmCryptoHandle {
    let mut handle = ptr::null_mut();
    assert_eq!(
        unsafe { pm_crypto_device_create(slice(account), slice(device), &mut handle) },
        PM_CRYPTO_OK
    );
    handle
}

fn create_group(handle: *mut PmCryptoHandle, id: &[u8]) {
    assert_eq!(
        unsafe { pm_crypto_group_create(handle, slice(id)) },
        PM_CRYPTO_OK
    );
}

fn epoch(handle: *mut PmCryptoHandle, id: &[u8]) -> i32 {
    let mut epoch = 0;
    let mut pending = 0;
    unsafe { pm_crypto_group_epoch(handle, slice(id), &mut epoch, &mut pending) }
}

#[test]
fn change_sets_restore_through_the_loader() {
    let alice = create(b"acct_a", b"dev_a");
    let mut table = seal(alice, &KEY, 1).unwrap();
    assert_eq!(table.records.len(), 1, "a fresh device seals only itself");

    create_group(alice, b"conv_1");
    let changes = table.commit(alice, &KEY);
    assert!(changes
        .iter()
        .any(|(kind, id, _, sealed)| *kind == 2 && id == b"conv_1" && sealed.is_some()));
    // The generation rule: only the stored counter plus one seals.
    assert_eq!(seal_raw(alice, &KEY, 5), Err(PM_CRYPTO_ERROR));
    assert_eq!(seal_raw(alice, &KEY, 0), Err(PM_CRYPTO_INVALID_ARGUMENT));

    let (restored, generation) = restore(b"acct_a", b"dev_a", &KEY, 2, &table).unwrap();
    assert_eq!(generation, 2);
    assert_eq!(epoch(restored, b"conv_1"), PM_CRYPTO_OK);

    // Deleting the group drops its record with the next seal.
    let mut deleted = 9;
    assert_eq!(
        unsafe { pm_crypto_group_delete(restored, slice(b"conv_1"), &mut deleted) },
        PM_CRYPTO_OK
    );
    assert_eq!(deleted, 1);
    assert_eq!(
        unsafe { pm_crypto_group_delete(restored, slice(b"conv_1"), &mut deleted) },
        PM_CRYPTO_OK
    );
    assert_eq!(deleted, 0);
    assert_eq!(epoch(restored, b"conv_1"), PM_CRYPTO_ERROR);
    let changes = table.commit(restored, &KEY);
    assert!(changes
        .iter()
        .any(|(kind, id, _, sealed)| *kind == 2 && id == b"conv_1" && sealed.is_none()));
    assert!(!table.records.contains_key(&(2, b"conv_1".to_vec())));
    let (again, _) = restore(b"acct_a", b"dev_a", &KEY, 3, &table).unwrap();
    assert_eq!(epoch(again, b"conv_1"), PM_CRYPTO_ERROR);

    let mut removed = 9;
    assert_eq!(
        unsafe { pm_crypto_device_prune_key_packages(again, 0, &mut removed) },
        PM_CRYPTO_OK
    );
    assert_eq!(removed, 0);
    unsafe {
        pm_crypto_device_destroy(alice);
        pm_crypto_device_destroy(restored);
        pm_crypto_device_destroy(again);
    }
}

#[test]
fn the_loader_refuses_incomplete_extra_and_stale_states() {
    let alice = create(b"acct_a", b"dev_a");
    let mut table = seal(alice, &KEY, 1).unwrap();
    create_group(alice, b"conv_1");
    let previous = table.clone();
    table.commit(alice, &KEY);

    // A missing record.
    let mut missing = table.clone();
    missing.records.remove(&(2, b"conv_1".to_vec()));
    assert_eq!(
        restore(b"acct_a", b"dev_a", &KEY, 2, &missing).err(),
        Some(PM_CRYPTO_ERROR)
    );
    // A record the root does not list (a stale table with a newer record).
    let mut extra = previous.clone();
    extra.records.insert(
        (2, b"conv_1".to_vec()),
        table.records[&(2, b"conv_1".to_vec())].clone(),
    );
    assert_eq!(
        restore(b"acct_a", b"dev_a", &KEY, 1, &extra).err(),
        Some(PM_CRYPTO_ERROR)
    );
    // A rolled-back root, a foreign device and a wrong key.
    assert_eq!(
        restore(b"acct_a", b"dev_a", &KEY, 2, &previous).err(),
        Some(PM_CRYPTO_ERROR)
    );
    assert_eq!(
        restore(b"acct_a", b"dev_b", &KEY, 2, &table).err(),
        Some(PM_CRYPTO_ERROR)
    );
    assert_eq!(
        restore(b"acct_a", b"dev_a", &[4; 32], 2, &table).err(),
        Some(PM_CRYPTO_ERROR)
    );

    // A token is spent by finish and by abort, and a failed add poisons.
    let loader = begin(b"acct_a", b"dev_a", &KEY, 2, &table.root).unwrap();
    assert_eq!(
        unsafe { pm_crypto_restore_add(loader, slice(&table.root)) },
        PM_CRYPTO_ERROR
    );
    for sealed in table.records.values() {
        let _ = unsafe { pm_crypto_restore_add(loader, slice(sealed)) };
    }
    assert_eq!(finish(loader).err(), Some(PM_CRYPTO_ERROR));
    assert_eq!(finish(loader).err(), Some(PM_CRYPTO_INVALID_ARGUMENT));
    assert_eq!(pm_crypto_restore_abort(loader), PM_CRYPTO_INVALID_ARGUMENT);
    assert_eq!(
        unsafe { pm_crypto_restore_add(loader, slice(&[1])) },
        PM_CRYPTO_INVALID_ARGUMENT
    );
    let loader = begin(b"acct_a", b"dev_a", &KEY, 2, &table.root).unwrap();
    assert_eq!(pm_crypto_restore_abort(loader), PM_CRYPTO_OK);
    assert_eq!(finish(loader).err(), Some(PM_CRYPTO_INVALID_ARGUMENT));
    unsafe { pm_crypto_device_destroy(alice) };
}

#[test]
fn an_oversized_group_is_named_with_the_record_limit_code() {
    let alice = create(b"acct_a", b"dev_a");
    let mut table = seal(alice, &KEY, 1).unwrap();
    create_group(alice, b"conv_huge");
    unsafe { &*alice }
        .device
        .lock()
        .unwrap()
        .oversize_group_for_test(b"conv_huge");
    let mut out = PmOwnedBuffer::default();
    let code = unsafe { pm_crypto_device_seal_changes(alice, slice(&KEY), 2, &mut out) };
    assert_eq!(code, PM_CRYPTO_RECORD_LIMIT);
    let named = unsafe { take(out) };
    assert_eq!(named[0], 2);
    assert_eq!(&named[1..], b"conv_huge");
    // Nothing was sealed: the committed state still restores.
    table.generation = 1;
    let (restored, generation) = restore(b"acct_a", b"dev_a", &KEY, 1, &table).unwrap();
    assert_eq!(generation, 1);
    unsafe {
        pm_crypto_device_destroy(alice);
        pm_crypto_device_destroy(restored);
    }
}

#[test]
fn a_v3_blob_migrates_to_records() {
    let alice = create(b"acct_a", b"dev_a");
    create_group(alice, b"conv_1");
    let blob = unsafe { &*alice }
        .device
        .lock()
        .unwrap()
        .seal_state(&KEY, 5)
        .unwrap();
    let migrate = |counter: u64, blob: &[u8]| {
        let mut handle = ptr::null_mut();
        let mut dropped = 9;
        let code = unsafe {
            pm_crypto_device_migrate_v3(
                slice(b"acct_a"),
                slice(b"dev_a"),
                slice(&KEY),
                counter,
                slice(blob),
                &mut handle,
                &mut dropped,
            )
        };
        (code, handle, dropped)
    };
    // The counter must be the stored one.
    assert_eq!(migrate(4, &blob).0, PM_CRYPTO_ERROR);
    assert_eq!(migrate(6, &blob).0, PM_CRYPTO_ERROR);
    let (code, migrated, dropped) = migrate(5, &blob);
    assert_eq!(code, PM_CRYPTO_OK);
    assert_eq!(dropped, 0);
    let mut table = Table {
        generation: 5,
        ..Table::default()
    };
    table.commit(migrated, &KEY);
    assert!(table.records.contains_key(&(2, b"conv_1".to_vec())));
    let (restored, generation) = restore(b"acct_a", b"dev_a", &KEY, 6, &table).unwrap();
    assert_eq!(generation, 6);
    assert_eq!(epoch(restored, b"conv_1"), PM_CRYPTO_OK);

    // A format 4 root is not a migration input, and a format 4 restore
    // does not take a v3 blob.
    assert_eq!(
        migrate(6, &table.root).0,
        PM_CRYPTO_STATE_FORMAT_UNSUPPORTED
    );
    assert_eq!(
        begin(b"acct_a", b"dev_a", &KEY, 5, &blob).err(),
        Some(PM_CRYPTO_STATE_FORMAT_UNSUPPORTED)
    );
    unsafe {
        pm_crypto_device_destroy(alice);
        pm_crypto_device_destroy(migrated);
        pm_crypto_device_destroy(restored);
    }
}

#[test]
fn a_welcome_for_a_key_package_this_device_lacks_has_its_own_code() {
    let alice = create(b"acct_a", b"dev_a");
    let bob = create(b"acct_b", b"dev_b");
    let carol = create(b"acct_c", b"dev_c");
    create_group(alice, b"conv_1");
    let mut package = PmOwnedBuffer::default();
    assert_eq!(
        unsafe { pm_crypto_device_create_key_package(bob, &mut package) },
        PM_CRYPTO_OK
    );
    let package = unsafe { take(package) };
    let mut commit = PmOwnedBuffer::default();
    let mut welcome = PmOwnedBuffer::default();
    assert_eq!(
        unsafe {
            pm_crypto_group_add_member(
                alice,
                slice(b"conv_1"),
                slice(&package),
                slice(b"acct_b"),
                slice(b"dev_b"),
                &mut commit,
                &mut welcome,
            )
        },
        PM_CRYPTO_OK
    );
    drop(unsafe { take(commit) });
    let welcome = unsafe { take(welcome) };
    assert_eq!(
        unsafe { pm_crypto_group_join(carol, slice(b"conv_1"), slice(&welcome)) },
        PM_CRYPTO_WELCOME_KEY_PACKAGE_UNAVAILABLE
    );
    assert_eq!(
        unsafe { pm_crypto_group_join(bob, slice(b"conv_1"), slice(&welcome)) },
        PM_CRYPTO_OK
    );
    unsafe {
        pm_crypto_device_destroy(alice);
        pm_crypto_device_destroy(bob);
        pm_crypto_device_destroy(carol);
    }
}
