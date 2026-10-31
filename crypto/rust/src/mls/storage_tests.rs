//! D70 S1 routing, scope and classifier tests for [`super::PartitionedStorage`].
//! Every write and delete in these tests (and in every other unit test
//! that drives an `MlsDevice`) is also checked against a flat twin store.

use super::super::{MlsDevice, MlsError, CIPHERSUITE};
use super::*;
use openmls::prelude::{
    tls_codec::Deserialize as _, KeyPackageIn, LeafNodeParameters, MlsGroup, MlsMessageBodyIn,
    MlsMessageIn, ProcessedMessageContent, ProtocolVersion, Welcome,
};
use openmls::schedule::{ExternalPsk, PreSharedKeyId, Psk};
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::{signatures::Signer, OpenMlsProvider};
use std::collections::BTreeSet;
use tls_codec::Serialize as _;

fn device(name: &str) -> MlsDevice {
    MlsDevice::new(
        format!("acct_{name}").as_bytes(),
        format!("dev_{name}").as_bytes(),
    )
    .unwrap()
}

fn storage(device: &MlsDevice) -> &PartitionedStorage {
    device.provider.storage()
}

fn owners(device: &MlsDevice) -> BTreeSet<String> {
    storage(device).snapshot().into_keys().collect()
}

/// The owners whose records an operation changed.
fn changed(before: &BTreeMap<String, Store>, after: &BTreeMap<String, Store>) -> BTreeSet<String> {
    before
        .keys()
        .chain(after.keys())
        .filter(|owner| before.get(*owner) != after.get(*owner))
        .cloned()
        .collect()
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|item| item.to_string()).collect()
}

fn in_scope<T>(
    device: &MlsDevice,
    group: &mut MlsGroup,
    call: impl FnOnce(&mut MlsGroup) -> T,
) -> T {
    let id = group.group_id().as_slice().to_vec();
    let mut out = None;
    device
        .in_group(&id, || {
            out = Some(call(group));
            Ok(())
        })
        .unwrap();
    out.unwrap()
}

fn package_ref(device: &MlsDevice, bytes: &[u8]) -> Vec<u8> {
    KeyPackageIn::tls_deserialize_exact(bytes)
        .unwrap()
        .validate(device.provider.crypto(), ProtocolVersion::Mls10)
        .unwrap()
        .hash_ref(device.provider.crypto())
        .unwrap()
        .as_slice()
        .to_vec()
}

fn pair(name: &[u8]) -> (MlsDevice, MlsDevice, MlsGroup, MlsGroup) {
    let alice = device("alice");
    let bob = device("bob");
    let mut alice_group = alice.create_group(name).unwrap();
    let add = alice
        .add_member(
            &mut alice_group,
            &bob.create_key_package().unwrap(),
            b"acct_bob",
            b"dev_bob",
        )
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    let bob_group = bob.join_group(name, &add.welcome).unwrap();
    (alice, bob, alice_group, bob_group)
}

#[test]
fn id_parser_matches_the_openmls_serializer() {
    let long: Vec<u8> = (0..=255).collect();
    for id in [
        &b""[..],
        b"a",
        b"conv_alpha",
        &[0, 9, 10, 99, 100, 199, 200, 255],
        &long,
    ] {
        let json = group_json(&GroupId::from_slice(id)).unwrap();
        let mut expected = ID_PREFIX.to_vec();
        let list: Vec<String> = id.iter().map(u8::to_string).collect();
        expected.extend_from_slice(list.join(",").as_bytes());
        expected.extend_from_slice(ID_SUFFIX);
        assert_eq!(json, expected);
        assert_eq!(parse_id(&json), Some((id.to_vec(), json.len())));
    }
    // A key package store is named by the package's own hash reference.
    let alice = device("alice");
    let package = alice.create_key_package().unwrap();
    let id = package_ref(&alice, &package);
    assert_eq!(
        owners(&alice),
        set(&["device", &format!("kp:{}", hex(&id))])
    );
}

#[test]
fn classifier_refuses_unknown_malformed_and_ambiguous_keys() {
    let group = |label: &[u8], body: &[u8], version: [u8; 2]| {
        let mut key = label.to_vec();
        key.extend_from_slice(body);
        key.extend_from_slice(&version);
        key
    };
    let id = br#"{"value":{"vec":[1,2]}}"#;
    assert_eq!(
        classify(&group(b"Tree", id, [0, 1])),
        Some(Owner::Group(vec![1, 2]))
    );
    assert_eq!(
        classify(&group(
            b"EpochKeyPairs",
            br#"{"value":{"vec":[1,2]}}30"#,
            [0, 1]
        )),
        Some(Owner::Group(vec![1, 2]))
    );
    assert_eq!(
        classify(&group(
            b"QueuedProposal",
            br#"[{"value":{"vec":[1,2]}},{"value":{"vec":[7]}}]"#,
            [0, 1]
        )),
        Some(Owner::Group(vec![1, 2]))
    );
    assert_eq!(
        classify(&group(b"KeyPackage", br#"{"value":{"vec":[255]}}"#, [0, 1])),
        Some(Owner::KeyPackage(vec![255]))
    );
    assert_eq!(
        classify(&group(b"SignatureKeyPair", br#"{"value":[1,2,3]}"#, [0, 1])),
        Some(Owner::Device)
    );
    assert_eq!(
        classify(&group(b"EncryptionKeyPair", br#"{"value":[1]}"#, [0, 1])),
        Some(Owner::Unowned)
    );
    for bad in [
        group(b"Unknown", id, [0, 1]),
        group(b"Tree", id, [0, 2]),
        group(b"Tree", id, [0, 0]),
        id.to_vec(),
        group(b"Tree", br#"{"value":{"vec":[01]}}"#, [0, 1]),
        group(b"Tree", br#"{"value":{"vec":[256]}}"#, [0, 1]),
        group(b"Tree", br#"{"value":{"vec":[1, 2]}}"#, [0, 1]),
        group(b"Tree", br#"{"value":{"vec":[1,]}}"#, [0, 1]),
        group(b"Tree", br#"{"value":{"vec":[1,2]}}x"#, [0, 1]),
        group(b"Tree", br#"{"value":{"vec":[1,2]}"#, [0, 1]),
        group(b"Tree", b"x", [0, 1]),
        group(b"EpochKeyPairs", id, [0, 1]),
        group(b"EpochKeyPairs", br#"{"value":{"vec":[1,2]}}3a"#, [0, 1]),
        group(b"QueuedProposal", br#"[{"value":{"vec":[1,2]}}]"#, [0, 1]),
        group(b"KeyPackage", br#"{"value":{"vec":[1]}},"#, [0, 1]),
        group(b"SignatureKeyPair", br#"{"value":[1,2]"#, [0, 1]),
        // OpenMLS draft-feature labels are refused, not guessed.
        group(b"ApplicationExportTree", id, [0, 1]),
    ] {
        assert_eq!(classify(&bad), None, "{}", String::from_utf8_lossy(&bad));
        let mut records = Store::new();
        records.insert(bad, b"x".to_vec());
        assert!(matches!(
            PartitionedStorage::from_records(records),
            Err(MlsError::InvalidState)
        ));
    }
}

#[test]
fn every_operation_touches_only_its_own_owners() {
    let alice = device("alice");
    let bob = device("bob");
    assert_eq!(owners(&alice), set(&["device"]));

    let before = storage(&bob).snapshot();
    let package = bob.create_key_package().unwrap();
    let kp = format!("kp:{}", hex(&package_ref(&bob, &package)));
    assert_eq!(changed(&before, &storage(&bob).snapshot()), set(&[&kp]));

    let mut other = alice.create_group(b"conv_other").unwrap();
    let before = storage(&alice).snapshot();
    let mut group = alice.create_group(b"conv_route").unwrap();
    assert_eq!(
        changed(&before, &storage(&alice).snapshot()),
        set(&["group:conv_route"])
    );

    let before = storage(&alice).snapshot();
    let add = alice
        .add_member(&mut group, &package, b"acct_bob", b"dev_bob")
        .unwrap();
    alice.merge_pending_commit(&mut group).unwrap();
    assert_eq!(
        changed(&before, &storage(&alice).snapshot()),
        set(&["group:conv_route"])
    );

    // Joining consumes the key package and creates the group.
    let before = storage(&bob).snapshot();
    let mut bob_group = bob.join_group(b"conv_route", &add.welcome).unwrap();
    assert_eq!(
        changed(&before, &storage(&bob).snapshot()),
        set(&[&kp, "group:conv_route"])
    );
    assert!(!owners(&bob).contains(&kp));

    for step in 0..4 {
        let before = (storage(&alice).snapshot(), storage(&bob).snapshot());
        match step {
            0 => {
                let message = alice.encrypt(&mut group, b"routed").unwrap();
                bob.decrypt(&mut bob_group, &message, b"acct_alice", b"dev_alice")
                    .unwrap();
            }
            1 => {
                let staged = alice.stage_self_update(&mut group).unwrap();
                alice.merge_pending_commit(&mut group).unwrap();
                bob.process_commit(&mut bob_group, &staged.commit).unwrap();
            }
            2 => {
                alice.stage_self_update(&mut group).unwrap();
                alice.clear_pending_commit(&mut group).unwrap();
            }
            _ => {
                alice.load_group(b"conv_route").unwrap();
            }
        }
        let after = (storage(&alice).snapshot(), storage(&bob).snapshot());
        let expected = if step == 3 {
            set(&[])
        } else {
            set(&["group:conv_route"])
        };
        assert_eq!(changed(&before.0, &after.0), expected, "step {step}");
        if step < 2 {
            assert_eq!(changed(&before.1, &after.1), expected, "step {step}");
        }
    }
    alice.encrypt(&mut other, b"other group").unwrap();
    assert_eq!(storage(&alice).unowned_count(), 0);
}

#[test]
fn no_standalone_key_pair_survives_any_device_operation() {
    // The design expected `clear_pending_commit` to leak the staged leaf's
    // key pair. In OpenMLS 0.9.2 a commit's path keys live inside the
    // staged commit (the group state record), never as standalone pairs.
    let (alice, bob, mut alice_group, mut bob_group) = pair(b"conv_leak");
    let check = |device: &MlsDevice| {
        let flat = storage(device).flat();
        assert!(
            !flat.keys().any(|key| key.starts_with(b"EncryptionKeyPair")),
            "standalone key pair found"
        );
    };
    for _ in 0..2 {
        let staged = alice.stage_self_update(&mut alice_group).unwrap();
        check(&alice);
        alice.clear_pending_commit(&mut alice_group).unwrap();
        check(&alice);
        let staged_again = alice.stage_self_update(&mut alice_group).unwrap();
        alice.merge_pending_commit(&mut alice_group).unwrap();
        bob.process_commit(&mut bob_group, &staged_again.commit)
            .unwrap();
        let _ = staged;
        check(&alice);
        check(&bob);
    }
    let carol = device("carol");
    let staged = alice
        .stage_membership_commit(
            &mut alice_group,
            &[super::super::MemberAdd {
                key_package: &carol.create_key_package().unwrap(),
                account_id: b"acct_carol",
                device_id: b"dev_carol",
            }],
            &[],
        )
        .unwrap();
    alice.clear_pending_commit(&mut alice_group).unwrap();
    check(&alice);
    check(&carol);
    let _ = staged;
}

#[test]
fn the_scope_guard_refuses_other_groups_and_unscoped_calls() {
    let (alice, _bob, mut group, _) = pair(b"conv_scope");
    let mut other = alice.create_group(b"conv_scope_other").unwrap();
    let store = storage(&alice);
    let before = store.snapshot();

    // A group-keyed call with no scope.
    assert!(matches!(
        store.write_own_leaf_index(&GroupId::from_slice(b"conv_scope"), &LeafNodeIndex::new(3)),
        Err(PartitionError::OutOfScope)
    ));
    assert!(matches!(
        MlsGroup::load(store, &GroupId::from_slice(b"conv_scope")),
        Err(PartitionError::OutOfScope)
    ));
    // A group-keyed call for another group, inside a scope, fails the whole
    // operation even though the closure ignores the error.
    assert_eq!(
        alice.in_group(b"conv_scope", || {
            let _ = store.write_own_leaf_index(
                &GroupId::from_slice(b"conv_scope_other"),
                &LeafNodeIndex::new(3),
            );
            Ok(())
        }),
        Err(MlsError::Storage)
    );
    // The same through OpenMLS: Alice's other group used in the wrong scope.
    assert_eq!(
        alice.in_group(b"conv_scope", || {
            other
                .create_message(&alice.provider, &alice.signer, b"wrong scope")
                .map(|_| ())
                .map_err(|_| MlsError::GroupOperation)
        }),
        Err(MlsError::Storage)
    );
    // An update proposal writes a standalone key pair; with no scope the
    // call is refused and nothing is written.
    assert!(group
        .propose_self_update(
            &alice.provider,
            &alice.signer,
            LeafNodeParameters::default()
        )
        .is_err());
    // Scopes do not nest.
    assert_eq!(
        alice.in_group(b"conv_scope", || alice
            .load_group(b"conv_scope")
            .map(|_| ())),
        Err(MlsError::Storage)
    );
    assert_eq!(changed(&before, &store.snapshot()), set(&[]));
    // The scope is cleared after a refusal: normal operations work.
    alice.load_group(b"conv_scope").unwrap();
    alice.encrypt(&mut other, b"fine").unwrap();
}

/// Drives every storage method OpenMLS 0.9.2 can call without draft
/// features, by category, and checks each was routed (the flat twin check
/// runs after every write and delete).
#[test]
fn every_storage_method_is_routed() {
    let (alice, bob, mut alice_group, mut bob_group) = pair(b"conv_all");

    // Group: an update proposal (standalone key pair under scope, queued
    // proposal, own leaf node), a removed proposal, a commit to the
    // pending proposal and its processing.
    let (_, unwanted) = in_scope(&bob, &mut bob_group, |g| {
        g.propose_self_update(&bob.provider, &bob.signer, LeafNodeParameters::default())
    })
    .unwrap();
    in_scope(&bob, &mut bob_group, |g| {
        g.remove_pending_proposal(bob.provider.storage(), &unwanted)
    })
    .unwrap();
    in_scope(&bob, &mut bob_group, |g| {
        g.clear_pending_proposals(bob.provider.storage())
    })
    .unwrap();
    let (proposal, _) = in_scope(&bob, &mut bob_group, |g| {
        g.propose_self_update(&bob.provider, &bob.signer, LeafNodeParameters::default())
    })
    .unwrap();
    let standalone = |device: &MlsDevice| {
        storage(device)
            .flat()
            .keys()
            .filter(|key| key.starts_with(b"EncryptionKeyPair"))
            .count()
    };
    assert_eq!(standalone(&bob), 2);
    assert!(owners(&bob).contains("group:conv_all"));
    let proposal = MlsMessageIn::tls_deserialize_exact(proposal.tls_serialize_detached().unwrap())
        .unwrap()
        .try_into_protocol_message()
        .unwrap();
    in_scope(&alice, &mut alice_group, |g| {
        let processed = g.process_message(&alice.provider, proposal).unwrap();
        let ProcessedMessageContent::ProposalMessage(queued) = processed.into_content() else {
            panic!("expected a proposal");
        };
        g.store_pending_proposal(alice.provider.storage(), *queued)?;
        // OpenMLS 0.9.2 never calls this getter itself.
        let refs = alice
            .provider
            .storage()
            .queued_proposal_refs::<_, openmls::ciphersuite::hash_ref::ProposalRef>(g.group_id())?;
        assert_eq!(refs.len(), 1);
        Ok::<_, PartitionError>(())
    })
    .unwrap();
    let (commit, _, _) = in_scope(&alice, &mut alice_group, |g| {
        g.commit_to_pending_proposals(&alice.provider, &alice.signer)
    })
    .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    let commit = MlsMessageIn::tls_deserialize_exact(commit.tls_serialize_detached().unwrap())
        .unwrap()
        .try_into_protocol_message()
        .unwrap();
    in_scope(&bob, &mut bob_group, |g| {
        let processed = g.process_message(&bob.provider, commit).unwrap();
        let ProcessedMessageContent::StagedCommitMessage(staged) = processed.into_content() else {
            panic!("expected a commit");
        };
        g.merge_staged_commit(&bob.provider, *staged)
    })
    .unwrap();
    // Bob's applied update deleted its pair. The withdrawn proposal's pair
    // stays: an OpenMLS leak Veritra never hits (it makes no update
    // proposals), filed under the group that made it.
    assert_eq!(standalone(&bob), 1);
    let message = alice.encrypt(&mut alice_group, b"after proposals").unwrap();
    assert_eq!(
        bob.decrypt(&mut bob_group, &message, b"acct_alice", b"dev_alice")
            .unwrap(),
        b"after proposals"
    );
    // Group deletion (the join-over-inactive path uses it).
    in_scope(&alice, &mut alice_group, |g| {
        g.delete(alice.provider.storage())
    })
    .unwrap();

    // Device: PSKs (unused by Veritra), read by a commit that injects one,
    // and signature key deletion.
    let psk = Psk::External(ExternalPsk::new(b"psk_id".to_vec()));
    let psk_id = PreSharedKeyId::new(CIPHERSUITE, alice.provider.rand(), psk.clone()).unwrap();
    let before = storage(&alice).snapshot();
    psk_id.store(&alice.provider, &[5; 32]).unwrap();
    assert_eq!(
        changed(&before, &storage(&alice).snapshot()),
        set(&["device"])
    );
    let mut solo = alice.create_group(b"conv_psk").unwrap();
    in_scope(&alice, &mut solo, |g| {
        g.propose_pre_shared_key(&alice.provider, &alice.signer, psk_id)
            .unwrap();
        g.commit_to_pending_proposals(&alice.provider, &alice.signer)
            .unwrap();
        g.merge_pending_commit(&alice.provider)
    })
    .unwrap();
    let before = storage(&alice).snapshot();
    storage(&alice).delete_psk(&psk).unwrap();
    let throwaway = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).unwrap();
    throwaway.store(storage(&alice)).unwrap();
    assert!(SignatureKeyPair::read(
        storage(&alice),
        throwaway.public(),
        CIPHERSUITE.signature_algorithm()
    )
    .is_some());
    SignatureKeyPair::delete(
        storage(&alice),
        throwaway.public(),
        CIPHERSUITE.signature_algorithm(),
    )
    .unwrap();
    assert_eq!(
        changed(&before, &storage(&alice).snapshot()),
        set(&["device"])
    );
    let _ = throwaway.sign(b"x");

    let hits: BTreeSet<&str> = storage(&alice)
        .hits()
        .union(&storage(&bob).hits())
        .copied()
        .collect();
    let all = [
        "write_mls_join_config",
        "append_own_leaf_node",
        "queue_proposal",
        "write_tree",
        "write_interim_transcript_hash",
        "write_context",
        "write_confirmation_tag",
        "write_group_state",
        "write_message_secrets",
        "write_resumption_psk_store",
        "write_own_leaf_index",
        "write_group_epoch_secrets",
        "write_signature_key_pair",
        "write_encryption_key_pair",
        "write_encryption_epoch_key_pairs",
        "write_key_package",
        "write_psk",
        "mls_group_join_config",
        "own_leaf_nodes",
        "queued_proposal_refs",
        "queued_proposals",
        "tree",
        "group_context",
        "interim_transcript_hash",
        "confirmation_tag",
        "group_state",
        "message_secrets",
        "resumption_psk_store",
        "own_leaf_index",
        "group_epoch_secrets",
        "signature_key_pair",
        "encryption_key_pair",
        "encryption_epoch_key_pairs",
        "key_package",
        "psk",
        "remove_proposal",
        "delete_own_leaf_nodes",
        "delete_group_config",
        "delete_tree",
        "delete_confirmation_tag",
        "delete_group_state",
        "delete_context",
        "delete_interim_transcript_hash",
        "delete_message_secrets",
        "delete_all_resumption_psk_secrets",
        "delete_own_leaf_index",
        "delete_group_epoch_secrets",
        "clear_proposal_queue",
        "delete_signature_key_pair",
        "delete_encryption_key_pair",
        "delete_encryption_epoch_key_pairs",
        "delete_key_package",
        "delete_psk",
    ];
    assert_eq!(all.len(), 53);
    let missing: Vec<_> = all.iter().filter(|name| !hits.contains(*name)).collect();
    assert!(missing.is_empty(), "not exercised: {missing:?}");
    assert!(hits.iter().all(|name| all.contains(name)));
}

/// A Welcome is server-controlled and may name thousands of key packages.
/// Each must cost one direct lookup, not one per stored package.
#[test]
fn a_welcome_with_many_bogus_secrets_costs_one_lookup_each() {
    const PACKAGES: usize = 100;
    const BOGUS: usize = 1000;
    let alice = device("alice");
    let bob = device("bob");
    let mut packages: Vec<Vec<u8>> = (0..PACKAGES)
        .map(|_| bob.create_key_package().unwrap())
        .collect();
    let mut group = alice.create_group(b"conv_bogus").unwrap();
    let add = alice
        .add_member(
            &mut group,
            &packages.pop().unwrap(),
            b"acct_bob",
            b"dev_bob",
        )
        .unwrap();
    let message = MlsMessageIn::tls_deserialize_exact(&add.welcome).unwrap();
    let MlsMessageBodyIn::Welcome(welcome) = message.extract() else {
        panic!("expected a Welcome");
    };
    let json = serde_json::to_value(&welcome).unwrap();
    let real = json["secrets"][0].clone();
    let bogus: Vec<_> = (0..BOGUS)
        .map(|i| {
            let mut secret = real.clone();
            let reference: Vec<u8> = (0..32).map(|j| (i * 31 + j * 7) as u8).collect();
            secret["new_member"]["value"]["vec"] = serde_json::json!(reference);
            secret
        })
        .collect();
    let encode = |secrets: Vec<serde_json::Value>| {
        let mut json = json.clone();
        json["secrets"] = serde_json::Value::Array(secrets);
        let welcome: Welcome = serde_json::from_value(json).unwrap();
        // MLSMessage header (version, wire format), then the Welcome.
        let mut bytes = add.welcome[..4].to_vec();
        bytes.extend(welcome.tls_serialize_detached().unwrap());
        bytes
    };

    // Only bogus secrets: no package matches, the join fails and nothing
    // changes (D74: refused as naming no held key package).
    let before = storage(&bob).snapshot();
    let probes = storage(&bob).package_probes();
    let started = std::time::Instant::now();
    assert_eq!(
        bob.join_group(b"conv_bogus", &encode(bogus.clone()))
            .map(|_| ()),
        Err(MlsError::KeyPackageUnavailable)
    );
    let elapsed = started.elapsed();
    let used = storage(&bob).package_probes() - probes;
    eprintln!("{BOGUS} bogus secrets, {PACKAGES} packages: {used} store probes, {elapsed:?}");
    assert!(used <= BOGUS, "{used} store probes");
    assert_eq!(changed(&before, &storage(&bob).snapshot()), set(&[]));

    // The real secret after the bogus ones still joins, and only its
    // package is consumed.
    let mut secrets = bogus;
    secrets.push(real);
    bob.join_group(b"conv_bogus", &encode(secrets)).unwrap();
    let left = owners(&bob)
        .iter()
        .filter(|owner| owner.starts_with("kp:"))
        .count();
    assert_eq!(left, PACKAGES - 1);
}
