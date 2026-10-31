//! D70 format 4 tests: change sets, the restore loader's refusals, caps,
//! pruning, D74 and the one-way migration from formats 2 and 3.

use super::super::state::{decode_records, encode_records};
use super::super::storage::hex;
use super::*;
use openmls::prelude::{
    tls_codec::Deserialize as _, KeyPackage, KeyPackageIn, LeafNodeParameters, Lifetime,
    ProtocolVersion,
};
use std::collections::HashMap;

const KEY: [u8; 32] = [0x55; 32];

fn device(name: &str) -> MlsDevice {
    MlsDevice::new(
        format!("acct_{name}").as_bytes(),
        format!("dev_{name}").as_bytes(),
    )
    .unwrap()
}

fn restore(table: &SealedTable, name: &str) -> Result<MlsDevice, MlsError> {
    table.restore(
        format!("acct_{name}").as_bytes(),
        format!("dev_{name}").as_bytes(),
        &KEY,
    )
}

/// The (kind, id, upsert?) of every change, in order.
fn summary(set: &ChangeSet) -> Vec<(u8, Vec<u8>, bool)> {
    set.changes
        .iter()
        .map(|change| (change.kind, change.id.clone(), change.sealed.is_some()))
        .collect()
}

fn package_id(device: &MlsDevice, bytes: &[u8]) -> Vec<u8> {
    KeyPackageIn::tls_deserialize_exact(bytes)
        .unwrap()
        .validate(device.provider.crypto(), ProtocolVersion::Mls10)
        .unwrap()
        .hash_ref(device.provider.crypto())
        .unwrap()
        .as_slice()
        .to_vec()
}

/// Alice's group with Bob in it; both sealed into their own tables.
fn pair(
    group_id: &[u8],
) -> (
    (MlsDevice, SealedTable, openmls::prelude::MlsGroup),
    (MlsDevice, SealedTable, openmls::prelude::MlsGroup),
) {
    let mut alice = device("alice");
    let mut bob = device("bob");
    let mut alice_table = SealedTable::start(&mut alice, &KEY);
    let mut bob_table = SealedTable::start(&mut bob, &KEY);
    let package = bob.create_key_package().unwrap();
    bob_table.commit(&mut bob, &KEY);
    let mut alice_group = alice.create_group(group_id).unwrap();
    let add = alice
        .add_member(&mut alice_group, &package, b"acct_bob", b"dev_bob")
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    alice_table.commit(&mut alice, &KEY);
    let bob_group = bob.join_group(group_id, &add.welcome).unwrap();
    bob_table.commit(&mut bob, &KEY);
    (
        (alice, alice_table, alice_group),
        (bob, bob_table, bob_group),
    )
}

#[test]
fn a_fresh_device_seals_every_record_and_restores_its_groups() {
    let mut alice = device("alice");
    let mut table = SealedTable::default();
    let first = table.commit(&mut alice, &KEY);
    assert_eq!(summary(&first), [(KIND_DEVICE, Vec::new(), true)]);
    let mut group = alice.create_group(b"conv_one").unwrap();
    alice.encrypt(&mut group, b"advance").unwrap();
    let second = table.commit(&mut alice, &KEY);
    // The device record did not change, so only the group is resealed.
    assert_eq!(summary(&second), [(KIND_GROUP, b"conv_one".to_vec(), true)]);
    assert_eq!(&second.root[8..10], &4u16.to_be_bytes());

    let restored = restore(&table, "alice").unwrap();
    assert_eq!(restored.signing_public_key(), alice.signing_public_key());
    let mut group = restored.load_group(b"conv_one").unwrap();
    restored.encrypt(&mut group, b"after restart").unwrap();
    assert!(restored.create_key_package().is_ok());
}

#[test]
fn each_operation_reseals_only_its_own_records() {
    let ((mut alice, mut alice_table, mut alice_group), (mut bob, mut bob_table, mut bob_group)) =
        pair(b"conv_routing");

    // A key package is its own record.
    let package = bob.create_key_package().unwrap();
    let id = package_id(&bob, &package);
    assert_eq!(
        summary(&bob_table.commit(&mut bob, &KEY)),
        [(KIND_KEY_PACKAGE, id.clone(), true)]
    );

    // A join writes its group and deletes the key package it used.
    let mut other = alice.create_group(b"conv_second").unwrap();
    let add = alice
        .add_member(&mut other, &package, b"acct_bob", b"dev_bob")
        .unwrap();
    alice.merge_pending_commit(&mut other).unwrap();
    assert_eq!(
        summary(&alice_table.commit(&mut alice, &KEY)),
        [(KIND_GROUP, b"conv_second".to_vec(), true)]
    );
    bob.join_group(b"conv_second", &add.welcome).unwrap();
    assert_eq!(
        summary(&bob_table.commit(&mut bob, &KEY)),
        [
            (KIND_GROUP, b"conv_second".to_vec(), true),
            (KIND_KEY_PACKAGE, id, false)
        ]
    );

    // A message touches only its group, on both sides.
    let message = alice.encrypt(&mut alice_group, b"hello").unwrap();
    assert_eq!(
        summary(&alice_table.commit(&mut alice, &KEY)),
        [(KIND_GROUP, b"conv_routing".to_vec(), true)]
    );
    bob.decrypt(&mut bob_group, &message, b"acct_alice", b"dev_alice")
        .unwrap();
    assert_eq!(
        summary(&bob_table.commit(&mut bob, &KEY)),
        [(KIND_GROUP, b"conv_routing".to_vec(), true)]
    );

    // Nothing changed: only the root moves on.
    let idle = bob_table.commit(&mut bob, &KEY);
    assert!(idle.changes.is_empty());

    // Restored devices still talk.
    let alice = restore(&alice_table, "alice").unwrap();
    let bob = restore(&bob_table, "bob").unwrap();
    let mut alice_group = alice.load_group(b"conv_routing").unwrap();
    let mut bob_group = bob.load_group(b"conv_routing").unwrap();
    let reply = bob.encrypt(&mut bob_group, b"reply").unwrap();
    assert_eq!(
        alice
            .decrypt(&mut alice_group, &reply, b"acct_bob", b"dev_bob")
            .unwrap(),
        b"reply"
    );
}

#[test]
fn restore_refuses_stale_missing_extra_foreign_and_tampered_records() {
    let ((mut alice, mut table, mut group), (_bob, bob_table, _)) = pair(b"conv_refuse");
    let group_key = (KIND_GROUP, b"conv_refuse".to_vec());
    let stale = table.records[&group_key].clone();
    alice.encrypt(&mut group, b"moves the group on").unwrap();
    table.commit(&mut alice, &KEY);
    assert!(restore(&table, "alice").is_ok());

    let refused = |table: &SealedTable| {
        assert_eq!(
            restore(table, "alice").map(|_| ()),
            Err(MlsError::InvalidState)
        );
    };
    // A stale record: right identity, listed id, older generation.
    let mut old = table.clone();
    old.records.insert(group_key.clone(), stale.clone());
    refused(&old);
    // A missing record.
    let mut missing = table.clone();
    missing.records.remove(&group_key);
    refused(&missing);
    // An extra record: listed nowhere.
    let mut extra = table.clone();
    extra
        .records
        .insert((KIND_GROUP, b"conv_extra".to_vec()), stale.clone());
    refused(&extra);
    // The same record twice.
    let mut loader =
        RestoreLoader::begin(b"acct_alice", b"dev_alice", &KEY, 1, &table.root).unwrap();
    loader.add(&table.records[&group_key]).unwrap();
    assert_eq!(
        loader.add(&table.records[&group_key]),
        Err(MlsError::InvalidState)
    );
    assert_eq!(loader.finish().map(|_| ()), Err(MlsError::InvalidState));
    // A foreign record: Bob's group record for the same conversation.
    let mut foreign = table.clone();
    foreign
        .records
        .insert(group_key.clone(), bob_table.records[&group_key].clone());
    refused(&foreign);
    // A tampered record and a tampered root.
    let mut tampered = table.clone();
    *tampered
        .records
        .get_mut(&group_key)
        .unwrap()
        .last_mut()
        .unwrap() ^= 1;
    refused(&tampered);
    let mut tampered_root = table.clone();
    *tampered_root.root.last_mut().unwrap() ^= 1;
    refused(&tampered_root);
    // Wrong key or identity.
    assert_eq!(
        table
            .restore(b"acct_alice", b"dev_alice", &[9; 32])
            .map(|_| ()),
        Err(MlsError::InvalidState)
    );
    assert_eq!(
        table.restore(b"acct_bob", b"dev_alice", &KEY).map(|_| ()),
        Err(MlsError::InvalidState)
    );
    // Another device's root.
    let mut other_root = table.clone();
    other_root.root = bob_table.root.clone();
    refused(&other_root);
    // A root below the minimum is a rollback.
    assert_eq!(
        RestoreLoader::begin(
            b"acct_alice",
            b"dev_alice",
            &KEY,
            table.generation + 1,
            &table.root
        )
        .map(|_| ()),
        Err(MlsError::Rollback)
    );
    // A record presented as the root, and the root as a record.
    assert_eq!(
        RestoreLoader::begin(
            b"acct_alice",
            b"dev_alice",
            &KEY,
            1,
            &table.records[&group_key]
        )
        .map(|_| ()),
        Err(MlsError::InvalidState)
    );
    let mut loader =
        RestoreLoader::begin(b"acct_alice", b"dev_alice", &KEY, 1, &table.root).unwrap();
    assert_eq!(loader.add(&table.root), Err(MlsError::InvalidState));
}

#[test]
fn only_format_4_roots_open_and_other_versions_are_unsupported() {
    let mut alice = device("alice");
    let table = SealedTable::start(&mut alice, &KEY);
    for version in [0u16, 1, 2, 3, 5, u16::MAX] {
        let mut root = table.root.clone();
        root[8..10].copy_from_slice(&version.to_be_bytes());
        assert_eq!(
            RestoreLoader::begin(b"acct_alice", b"dev_alice", &KEY, 1, &root).map(|_| ()),
            Err(MlsError::UnsupportedFormat),
            "version {version}"
        );
    }
    let mut magic = table.root.clone();
    magic[0] ^= 1;
    assert_eq!(
        RestoreLoader::begin(b"acct_alice", b"dev_alice", &KEY, 1, &magic).map(|_| ()),
        Err(MlsError::InvalidState)
    );
    // A genuine format-3 blob is not a root; the format-3 reader refuses a
    // format-4 root the same way.
    let v3 = include_bytes!("../../tests/fixtures/state-v3/source.bin");
    assert_eq!(
        RestoreLoader::begin(b"acct_fixture3", b"dev_src", &[0x73; 32], 51, v3).map(|_| ()),
        Err(MlsError::UnsupportedFormat)
    );
    assert_eq!(
        MlsDevice::restore_state(b"acct_alice", b"dev_alice", &KEY, 1, &table.root).map(|_| ()),
        Err(MlsError::UnsupportedFormat)
    );
}

#[test]
fn sealing_follows_the_generation_rule() {
    let mut alice = device("alice");
    assert!(matches!(
        alice.seal_changes(&KEY, 2),
        Err(SealError::Mls(MlsError::InvalidState))
    ));
    let mut table = SealedTable::start(&mut alice, &KEY);
    // A second seal at the same generation, or one that skips, is refused.
    assert!(alice.seal_changes(&KEY, 1).is_err());
    assert!(alice.seal_changes(&KEY, 3).is_err());
    assert!(alice.seal_changes(&KEY[..31], 2).is_err());
    table.commit(&mut alice, &KEY);
    // A restore resets the rule to the restored generation.
    let mut restored = restore(&table, "alice").unwrap();
    assert!(restored.seal_changes(&KEY, 2).is_err());
    assert!(restored.seal_changes(&KEY, 3).is_ok());
}

#[test]
fn own_removal_and_group_delete_drop_the_group_record() {
    let ((alice, mut alice_table, mut alice_group), (mut bob, mut bob_table, mut bob_group)) =
        pair(b"conv_leave");
    let late = alice.encrypt(&mut alice_group, b"before removal").unwrap();
    let staged = alice
        .stage_membership_commit(
            &mut alice_group,
            &[],
            &[super::super::MemberIdentity {
                account_id: b"acct_bob",
                device_id: b"dev_bob",
            }],
        )
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    bob.process_commit(&mut bob_group, &staged.commit).unwrap();
    assert!(!bob_group.is_active());
    // The whole group store went with the removal.
    assert!(!bob
        .provider
        .storage()
        .snapshot()
        .contains_key("group:conv_leave"));
    assert_eq!(
        summary(&bob_table.commit(&mut bob, &KEY)),
        [(KIND_GROUP, b"conv_leave".to_vec(), false)]
    );
    let bob = restore(&bob_table, "bob").unwrap();
    // A deleted group fails like a missing one: load, and so decrypt.
    assert_eq!(
        bob.load_group(b"conv_leave").map(|_| ()),
        Err(MlsError::InvalidState)
    );
    drop(late);

    // A user's delete drops an active group.
    let mut alice = alice;
    assert!(alice.delete_group(b"conv_leave").unwrap());
    assert!(!alice.delete_group(b"conv_leave").unwrap());
    assert_eq!(
        summary(&alice_table.commit(&mut alice, &KEY)),
        [(KIND_GROUP, b"conv_leave".to_vec(), false)]
    );
    let alice = restore(&alice_table, "alice").unwrap();
    assert_eq!(
        alice.load_group(b"conv_leave").map(|_| ()),
        Err(MlsError::InvalidState)
    );
}

/// Builds a key package for `device` with a chosen lifetime and stores it,
/// as `create_key_package` does.
/// Returns the store id (hash reference).
fn package_with_lifetime(device: &MlsDevice, not_before: u64, not_after: u64) -> Vec<u8> {
    let bundle = KeyPackage::builder()
        .key_package_lifetime(Lifetime::init(not_before, not_after))
        .build(
            CIPHERSUITE,
            &device.provider,
            &device.signer,
            device.credential.clone(),
        )
        .unwrap();
    bundle
        .key_package()
        .hash_ref(device.provider.crypto())
        .unwrap()
        .as_slice()
        .to_vec()
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

#[test]
fn key_package_pruning_drops_only_long_expired_packages() {
    let mut alice = device("alice");
    let mut table = SealedTable::start(&mut alice, &KEY);
    let live = alice.create_key_package().unwrap();
    let day = 24 * 60 * 60;
    let long_gone = package_with_lifetime(&alice, now() - 100 * day, now() - 2 * day);
    let just_expired = package_with_lifetime(&alice, now() - 10 * day, now() - 3600);
    table.commit(&mut alice, &KEY);
    assert_eq!(alice.key_package_count().unwrap(), 3);
    assert_eq!(alice.prune_key_packages(now()).unwrap(), 1);
    assert_eq!(
        summary(&table.commit(&mut alice, &KEY)),
        [(KIND_KEY_PACKAGE, long_gone, false)]
    );
    let alice = restore(&table, "alice").unwrap();
    let owners = alice.provider.storage().snapshot();
    assert!(owners.contains_key(&format!("kp:{}", hex(&package_id(&alice, &live)))));
    assert!(owners.contains_key(&format!("kp:{}", hex(&just_expired))));
    // Nothing more goes until the grace period passes.
    assert_eq!(alice.prune_key_packages(now()).unwrap(), 0);
    assert_eq!(alice.prune_key_packages(now() + 86 * day).unwrap(), 2);
}

#[test]
fn a_full_key_package_pool_is_refused_at_creation() {
    let alice = device("alice");
    for _ in 0..MAX_KEY_PACKAGES {
        alice.create_key_package().unwrap();
    }
    assert_eq!(alice.create_key_package(), Err(MlsError::InvalidState));
    assert_eq!(alice.key_package_count().unwrap(), MAX_KEY_PACKAGES);
}

#[test]
fn an_oversized_group_names_itself_and_keeps_its_change() {
    let mut alice = device("alice");
    let mut table = SealedTable::start(&mut alice, &KEY);
    let mut group = alice.create_group(b"conv_huge").unwrap();
    table.commit(&mut alice, &KEY);
    alice.encrypt(&mut group, b"dirty").unwrap();
    // Nine queued proposals of 4 MiB each: every value fits, the record
    // does not.
    let padding: Vec<Vec<u8>> = (0..9u8)
        .map(|i| {
            alice
                .provider
                .storage()
                .pad_group_for_test(b"conv_huge", i, MAX_GROUP_VALUE_BYTES)
        })
        .collect();
    let generation = table.generation + 1;
    assert_eq!(
        alice.seal_changes(&KEY, generation).unwrap_err(),
        SealError::RecordLimit {
            kind: KIND_GROUP,
            id: b"conv_huge".to_vec()
        }
    );
    // Nothing was sealed: the same generation seals once the group fits,
    // and the group's change is still there.
    for key in padding {
        alice
            .provider
            .storage()
            .unpad_group_for_test(b"conv_huge", &key);
    }
    assert_eq!(
        summary(&table.commit(&mut alice, &KEY)),
        [(KIND_GROUP, b"conv_huge".to_vec(), true)]
    );
    // A single value over 4 MiB is over the cap too.
    alice
        .provider
        .storage()
        .pad_group_for_test(b"conv_huge", 0, MAX_GROUP_VALUE_BYTES + 1);
    assert!(matches!(
        alice.seal_changes(&KEY, table.generation + 1),
        Err(SealError::RecordLimit {
            kind: KIND_GROUP,
            ..
        })
    ));
    let restored = restore(&table, "alice").unwrap();
    assert!(restored.load_group(b"conv_huge").is_ok());
}

/// Sets every `not_after` in a JSON value.
fn expire(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, item) in map.iter_mut() {
                if key == "not_after" {
                    *item = serde_json::json!(1);
                } else {
                    expire(item);
                }
            }
        }
        serde_json::Value::Array(items) => items.iter_mut().for_each(expire),
        _ => {}
    }
}

#[test]
fn d74_a_welcome_for_a_pruned_or_expired_key_package_is_unavailable() {
    let alice = device("alice");
    let bob = device("bob");
    // Pruned: the package named is gone.
    let package = bob.create_key_package().unwrap();
    let mut group = alice.create_group(b"conv_pruned").unwrap();
    let add = alice
        .add_member(&mut group, &package, b"acct_bob", b"dev_bob")
        .unwrap();
    alice.merge_pending_commit(&mut group).unwrap();
    assert!(bob
        .provider
        .storage()
        .drop_key_package(&package_id(&bob, &package))
        .unwrap());
    assert_eq!(
        bob.join_group(b"conv_pruned", &add.welcome).map(|_| ()),
        Err(MlsError::KeyPackageUnavailable)
    );

    // Expired: the package is held, but its lifetime is over. Nothing is
    // consumed.
    let package = bob.create_key_package().unwrap();
    let id = package_id(&bob, &package);
    let mut group = alice.create_group(b"conv_expired").unwrap();
    let add = alice
        .add_member(&mut group, &package, b"acct_bob", b"dev_bob")
        .unwrap();
    alice.merge_pending_commit(&mut group).unwrap();
    bob.provider
        .storage()
        .edit_key_package_for_test(&id, expire);
    let before = bob.provider.storage().snapshot();
    assert_eq!(
        bob.join_group(b"conv_expired", &add.welcome).map(|_| ()),
        Err(MlsError::KeyPackageUnavailable)
    );
    assert!(before == bob.provider.storage().snapshot());

    // A live package still joins.
    let package = bob.create_key_package().unwrap();
    let mut group = alice.create_group(b"conv_live").unwrap();
    let add = alice
        .add_member(&mut group, &package, b"acct_bob", b"dev_bob")
        .unwrap();
    alice.merge_pending_commit(&mut group).unwrap();
    bob.join_group(b"conv_live", &add.welcome).unwrap();
}

// --- migration -------------------------------------------------------

const V3_KEY: [u8; 32] = [0x73; 32];

/// Opens a format 2/3 blob, lets `change` edit its record map, and seals it
/// again under the same header (so the same identity and counter).
fn reseal_v3(
    sealed: &[u8],
    key: &[u8],
    change: impl FnOnce(&mut HashMap<Vec<u8>, Vec<u8>>),
) -> Vec<u8> {
    let mut reader = super::super::state::Reader::new(sealed);
    reader.take(8).unwrap();
    let version = reader.u16().unwrap();
    reader.u64().unwrap();
    for _ in 0..3 {
        reader.u16_bytes().unwrap();
    }
    let nonce = reader.take(12).unwrap().to_vec();
    let aad_end = reader.offset;
    let length = reader.u32().unwrap() as usize;
    let ciphertext = reader.take(length).unwrap();
    let cipher = Aes256Gcm::new_from_slice(key).unwrap();
    let nonce = Nonce::try_from(nonce.as_slice()).unwrap();
    let plaintext = cipher
        .decrypt(
            &nonce,
            Payload {
                msg: ciphertext,
                aad: &sealed[..aad_end],
            },
        )
        .unwrap();
    assert_eq!(version, 3);
    let mut payload = Reader::new(&plaintext);
    assert_eq!(payload.take(8).unwrap(), b"PMMLSPL3");
    let records_len = payload.u32().unwrap() as usize;
    let mut records = decode_records(payload.take(records_len).unwrap()).unwrap();
    let transfers = plaintext[payload.offset..].to_vec();
    change(&mut records);
    let mut sorted: Vec<(&[u8], &[u8])> = records
        .iter()
        .map(|(k, v)| (k.as_slice(), v.as_slice()))
        .collect();
    sorted.sort();
    let encoded = encode_records(&sorted).unwrap();
    let mut plaintext = b"PMMLSPL3".to_vec();
    plaintext.extend_from_slice(&(encoded.len() as u32).to_be_bytes());
    plaintext.extend_from_slice(&encoded);
    plaintext.extend_from_slice(&transfers);
    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: &plaintext,
                aad: &sealed[..aad_end],
            },
        )
        .unwrap();
    let mut out = sealed[..aad_end].to_vec();
    out.extend_from_slice(&(ciphertext.len() as u32).to_be_bytes());
    out.extend_from_slice(&ciphertext);
    out
}

/// The flat records of a v3 blob, by owner, as the format-3 reader splits
/// them.
fn v3_owners(
    sealed: &[u8],
    account: &[u8],
    device: &[u8],
    key: &[u8],
    counter: u64,
) -> BTreeMap<String, Store> {
    MlsDevice::restore_state(account, device, key, counter, sealed)
        .unwrap()
        .0
        .provider
        .storage()
        .snapshot()
}

#[test]
fn genuine_v3_fixture_migrates_to_records_and_keeps_working() {
    let sealed = include_bytes!("../../tests/fixtures/state-v3/source.bin");
    let old = v3_owners(sealed, b"acct_fixture3", b"dev_src", &V3_KEY, 51);
    let (mut source, dropped) =
        MlsDevice::migrate_v3(b"acct_fixture3", b"dev_src", &V3_KEY, 51, sealed).unwrap();
    // The inactive group is dropped and counted; nothing else is.
    assert_eq!(dropped, old["group:conv_gamma"].len());
    let mut expected = old.clone();
    expected.remove("group:conv_gamma");
    assert_eq!(source.provider.storage().snapshot(), expected);

    // The first seal emits every record; the table then restores.
    let mut table = SealedTable {
        generation: 51,
        ..Default::default()
    };
    let set = table.commit(&mut source, &V3_KEY);
    let mut kinds: Vec<u8> = set.changes.iter().map(|change| change.kind).collect();
    kinds.sort();
    assert_eq!(
        kinds,
        [
            KIND_DEVICE,
            KIND_GROUP,
            KIND_GROUP,
            KIND_KEY_PACKAGE,
            KIND_KEY_PACKAGE
        ]
    );
    assert!(set.changes.iter().all(|change| change.sealed.is_some()));
    assert_eq!(table.generation, 52);
    let source = table
        .restore(b"acct_fixture3", b"dev_src", &V3_KEY)
        .unwrap();
    assert_eq!(source.provider.storage().snapshot(), expected);
    assert_eq!(source.pending_transfers.len(), 2);
    assert_eq!(
        source.signing_public_key(),
        include_bytes!("../../tests/fixtures/state-v3/source-public.bin")
    );

    // The staged commit merges and the peer follows; both ways work.
    let (peer, _) = MlsDevice::restore_state(
        b"acct_peer3",
        b"dev_peer",
        &[0x74; 32],
        52,
        include_bytes!("../../tests/fixtures/state-v3/peer.bin"),
    )
    .unwrap();
    let mut alpha = source.load_group(b"conv_alpha").unwrap();
    assert!(source.has_pending_commit(&alpha));
    source.merge_pending_commit(&mut alpha).unwrap();
    let mut peer_alpha = peer.load_group(b"conv_alpha").unwrap();
    peer.process_commit(
        &mut peer_alpha,
        include_bytes!("../../tests/fixtures/state-v3/staged-update.bin"),
    )
    .unwrap();
    let message = source.encrypt(&mut alpha, b"synthetic-v4-out").unwrap();
    assert_eq!(
        peer.decrypt(&mut peer_alpha, &message, b"acct_fixture3", b"dev_src")
            .unwrap(),
        b"synthetic-v4-out"
    );
    let reply = peer.encrypt(&mut peer_alpha, b"synthetic-v4-in").unwrap();
    assert_eq!(
        source
            .decrypt(&mut alpha, &reply, b"acct_peer3", b"dev_peer")
            .unwrap(),
        b"synthetic-v4-in"
    );
    let mut beta = source.load_group(b"conv_beta").unwrap();
    assert_eq!(
        source
            .decrypt(
                &mut beta,
                include_bytes!("../../tests/fixtures/state-v3/peer-next.bin"),
                b"acct_peer3",
                b"dev_peer"
            )
            .unwrap(),
        b"synthetic-beta-after-upgrade"
    );
    assert_eq!(
        source.load_group(b"conv_gamma").map(|_| ()),
        Err(MlsError::InvalidState)
    );
    // An unclaimed key package still opens a Welcome.
    let unclaimed = include_bytes!("../../tests/fixtures/state-v3/unclaimed-1.bin");
    let mut fresh = peer.create_group(b"conv_delta").unwrap();
    let add = peer
        .add_member(&mut fresh, unclaimed, b"acct_fixture3", b"dev_src")
        .unwrap();
    peer.merge_pending_commit(&mut fresh).unwrap();
    source.join_group(b"conv_delta", &add.welcome).unwrap();

    // The migration is one way: neither reader takes a format-4 root.
    assert_eq!(
        MlsDevice::restore_state(b"acct_fixture3", b"dev_src", &V3_KEY, 52, &table.root)
            .map(|_| ()),
        Err(MlsError::UnsupportedFormat)
    );
    assert_eq!(
        MlsDevice::migrate_v3(b"acct_fixture3", b"dev_src", &V3_KEY, 52, &table.root).map(|_| ()),
        Err(MlsError::UnsupportedFormat)
    );
}

#[test]
fn migration_requires_the_stored_counter_and_identity() {
    let sealed = include_bytes!("../../tests/fixtures/state-v3/source.bin");
    assert_eq!(
        MlsDevice::migrate_v3(b"acct_fixture3", b"dev_src", &V3_KEY, 52, sealed).map(|_| ()),
        Err(MlsError::Rollback)
    );
    assert_eq!(
        MlsDevice::migrate_v3(b"acct_fixture3", b"dev_src", &V3_KEY, 50, sealed).map(|_| ()),
        Err(MlsError::InvalidState)
    );
    assert_eq!(
        MlsDevice::migrate_v3(b"acct_fixture3", b"dev_other", &V3_KEY, 51, sealed).map(|_| ()),
        Err(MlsError::InvalidState)
    );
    assert_eq!(
        MlsDevice::migrate_v3(b"acct_fixture3", b"dev_src", &[1; 32], 51, sealed).map(|_| ()),
        Err(MlsError::InvalidState)
    );
    let mut v1 = sealed.to_vec();
    v1[8..10].copy_from_slice(&1u16.to_be_bytes());
    assert_eq!(
        MlsDevice::migrate_v3(b"acct_fixture3", b"dev_src", &V3_KEY, 51, &v1).map(|_| ()),
        Err(MlsError::UnsupportedFormat)
    );
}

/// A crash anywhere before the app commits the migration leaves the v3
/// blob as it was: the migration runs again to the same records. After
/// the commit only the format-4 path opens the state.
#[test]
fn a_crash_at_each_migration_step_leaves_v3_intact_and_reruns() {
    let sealed = include_bytes!("../../tests/fixtures/state-v3/source.bin");
    let migrate = || {
        MlsDevice::migrate_v3(b"acct_fixture3", b"dev_src", &V3_KEY, 51, sealed)
            .unwrap()
            .0
    };
    // Crash after classifying.
    drop(migrate());
    // Crash after sealing, before the commit.
    let mut first = migrate();
    let uncommitted = first.seal_changes(&V3_KEY, 52).unwrap();
    drop(first);
    // The rerun seals the same records.
    let mut table = SealedTable {
        generation: 51,
        ..Default::default()
    };
    let mut again = migrate();
    let set = table.commit(&mut again, &V3_KEY);
    let ids = |set: &ChangeSet| -> Vec<(u8, Vec<u8>)> {
        set.changes
            .iter()
            .map(|change| (change.kind, change.id.clone()))
            .collect()
    };
    assert_eq!(ids(&set), ids(&uncommitted));
    // A change set from the crashed run never mixes with the committed one.
    let mut mixed = table.clone();
    let stray = &uncommitted.changes[0];
    mixed.records.insert(
        (stray.kind, stray.id.clone()),
        stray.sealed.clone().unwrap(),
    );
    assert_eq!(
        mixed
            .restore(b"acct_fixture3", b"dev_src", &V3_KEY)
            .map(|_| ()),
        Err(MlsError::InvalidState)
    );
    // After the commit, the state opens as records only.
    assert!(table.restore(b"acct_fixture3", b"dev_src", &V3_KEY).is_ok());
}

#[test]
fn genuine_v2_fixture_migrates() {
    let sealed = include_bytes!("../../tests/fixtures/state-v2/source.bin");
    let (mut source, dropped) =
        MlsDevice::migrate_v3(b"acct_fixture", b"dev_old", &[0x71; 32], 41, sealed).unwrap();
    assert_eq!(dropped, 0);
    let mut table = SealedTable {
        generation: 41,
        ..Default::default()
    };
    table.commit(&mut source, &[0x71; 32]);
    let source = table
        .restore(b"acct_fixture", b"dev_old", &[0x71; 32])
        .unwrap();
    let mut group = source.load_group(b"conv_fixture").unwrap();
    assert_eq!(
        source
            .decrypt(
                &mut group,
                include_bytes!("../../tests/fixtures/state-v2/peer-next.bin"),
                b"acct_peer",
                b"dev_peer"
            )
            .unwrap(),
        b"synthetic-after-upgrade"
    );
}

#[test]
fn migration_files_owned_standalone_pairs_drops_the_rest_and_refuses_unknown_labels() {
    let alice = device("alice");
    let bob = device("bob");
    let mut group = alice.create_group(b"conv_pairs").unwrap();
    let add = alice
        .add_member(
            &mut group,
            &bob.create_key_package().unwrap(),
            b"acct_bob",
            b"dev_bob",
        )
        .unwrap();
    alice.merge_pending_commit(&mut group).unwrap();
    let mut bob_group = bob.join_group(b"conv_pairs", &add.welcome).unwrap();
    // An update proposal writes a standalone pair and an own leaf node.
    bob.in_group(b"conv_pairs", || {
        bob_group
            .propose_self_update(&bob.provider, &bob.signer, LeafNodeParameters::default())
            .map_err(|_| MlsError::GroupOperation)
    })
    .unwrap();
    let v3 = bob.seal_state(&KEY, 7).unwrap();
    let standalone = |store: &Store| {
        store
            .keys()
            .filter(|key| key.starts_with(b"EncryptionKeyPair"))
            .count()
    };
    assert_eq!(
        standalone(&v3_owners(&v3, b"acct_bob", b"dev_bob", &KEY, 7)["unowned"]),
        1
    );
    // A leaked pair no group owns.
    let leaked = reseal_v3(&v3, &KEY, |records| {
        let mut key = b"EncryptionKeyPair".to_vec();
        key.extend_from_slice(br#"{"key":{"vec":[1,2,3]}}"#);
        key.extend_from_slice(&1u16.to_be_bytes());
        records.insert(key, b"{}".to_vec());
    });
    let (mut migrated, dropped) =
        MlsDevice::migrate_v3(b"acct_bob", b"dev_bob", &KEY, 7, &leaked).unwrap();
    assert_eq!(dropped, 1);
    let owners = migrated.provider.storage().snapshot();
    assert_eq!(standalone(&owners["group:conv_pairs"]), 1);
    assert!(!owners.contains_key("unowned"));
    let mut table = SealedTable {
        generation: 7,
        ..Default::default()
    };
    table.commit(&mut migrated, &KEY);
    let restored = restore(&table, "bob").unwrap();
    assert_eq!(
        standalone(&restored.provider.storage().snapshot()["group:conv_pairs"]),
        1
    );

    // An unknown label fails the migration closed.
    let unknown = reseal_v3(&v3, &KEY, |records| {
        records.insert(b"FutureLabel{}\x00\x01".to_vec(), b"x".to_vec());
    });
    assert_eq!(
        MlsDevice::migrate_v3(b"acct_bob", b"dev_bob", &KEY, 7, &unknown).map(|_| ()),
        Err(MlsError::InvalidState)
    );
}

/// One world of three devices sharing five groups.
struct World {
    devices: Vec<MlsDevice>,
    tables: Vec<SealedTable>,
}

const NAMES: [&str; 3] = ["ann", "ben", "cat"];

fn ids(index: usize) -> (Vec<u8>, Vec<u8>) {
    (
        format!("acct_{}", NAMES[index]).into_bytes(),
        format!("dev_{}", NAMES[index]).into_bytes(),
    )
}

impl World {
    fn seal(&mut self, index: usize) {
        let device = &mut self.devices[index];
        self.tables[index].commit(device, &KEY);
    }

    fn restart(&mut self, index: usize) {
        self.seal(index);
        self.devices[index] = restore(&self.tables[index], NAMES[index]).unwrap();
    }

    fn message(&mut self, id: &[u8], sender: usize, text: &[u8]) {
        let mut group = self.devices[sender].load_group(id).unwrap();
        let ciphertext = self.devices[sender].encrypt(&mut group, text).unwrap();
        let (account, device) = ids(sender);
        for receiver in (0..3).filter(|receiver| *receiver != sender) {
            let mut group = self.devices[receiver].load_group(id).unwrap();
            assert_eq!(
                self.devices[receiver]
                    .decrypt(&mut group, &ciphertext, &account, &device)
                    .unwrap(),
                text
            );
        }
    }

    fn self_update(&mut self, id: &[u8], sender: usize) {
        let mut group = self.devices[sender].load_group(id).unwrap();
        let staged = self.devices[sender].stage_self_update(&mut group).unwrap();
        self.devices[sender]
            .merge_pending_commit(&mut group)
            .unwrap();
        for receiver in (0..3).filter(|receiver| *receiver != sender) {
            let mut group = self.devices[receiver].load_group(id).unwrap();
            self.devices[receiver]
                .process_commit(&mut group, &staged.commit)
                .unwrap();
        }
    }

    /// Epoch and safety number of every group on every device.
    fn view(&self, groups: &[Vec<u8>]) -> Vec<(u64, String)> {
        let mut out = Vec::new();
        for device in &self.devices {
            for id in groups {
                let group = device.load_group(id).unwrap();
                out.push((
                    group.epoch().as_u64(),
                    device.conversation_safety_number(&group).unwrap().sas,
                ));
            }
        }
        out
    }
}

/// Random operations over three devices and five groups. One world
/// restarts devices from their sealed tables at random; its twin runs the
/// same operations and never restarts. Every message decrypts in both, and
/// epochs and safety numbers stay equal.
#[test]
fn restarts_from_records_match_a_twin_that_never_restarts() {
    let mut seed: u64 = 0x5eed_d70d_0000_0001;
    let mut next = move |bound: usize| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        (seed % bound as u64) as usize
    };
    let groups: Vec<Vec<u8>> = (0..5).map(|i| format!("conv_p{i}").into_bytes()).collect();
    let mut devices: Vec<MlsDevice> = NAMES.iter().map(|name| device(name)).collect();
    // Group i: device i % 3 adds the other two in one commit.
    for (index, id) in groups.iter().enumerate() {
        let owner = index % 3;
        let members: Vec<usize> = (0..3).filter(|member| *member != owner).collect();
        let packages: Vec<Vec<u8>> = members
            .iter()
            .map(|member| devices[*member].create_key_package().unwrap())
            .collect();
        let identities: Vec<(Vec<u8>, Vec<u8>)> = members.iter().map(|m| ids(*m)).collect();
        let adds: Vec<super::super::MemberAdd<'_>> = packages
            .iter()
            .zip(&identities)
            .map(|(package, (account, device))| super::super::MemberAdd {
                key_package: package,
                account_id: account,
                device_id: device,
            })
            .collect();
        let mut group = devices[owner].create_group(id).unwrap();
        let staged = devices[owner]
            .stage_membership_commit(&mut group, &adds, &[])
            .unwrap();
        devices[owner].merge_pending_commit(&mut group).unwrap();
        for member in members {
            devices[member].join_group(id, &staged.welcome).unwrap();
        }
    }
    let mut tables: Vec<SealedTable> = devices
        .iter_mut()
        .map(|device| SealedTable::start(device, &KEY))
        .collect();
    // The twin starts from the same sealed state.
    let mut twin = World {
        devices: (0..3)
            .map(|index| restore(&tables[index], NAMES[index]).unwrap())
            .collect(),
        tables: tables.clone(),
    };
    let mut world = World {
        devices: std::mem::take(&mut devices),
        tables: std::mem::take(&mut tables),
    };
    for step in 0..150 {
        let id = groups[next(groups.len())].clone();
        let sender = next(3);
        match next(5) {
            0 | 1 => {
                let text = format!("message {step}").into_bytes();
                world.message(&id, sender, &text);
                twin.message(&id, sender, &text);
            }
            2 => {
                world.self_update(&id, sender);
                twin.self_update(&id, sender);
            }
            3 => world.restart(sender),
            _ => world.seal(sender),
        }
        assert_eq!(world.view(&groups), twin.view(&groups), "step {step}");
    }
    // A final restart of everyone changes nothing.
    for index in 0..3 {
        world.restart(index);
    }
    assert_eq!(world.view(&groups), twin.view(&groups));
}
