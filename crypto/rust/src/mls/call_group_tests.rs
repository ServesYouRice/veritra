//! B6 (ABI 28) tests: the call-group marker, the call join, the media key's
//! refusal of other groups and calls, and the refusals an older key package
//! or a marker change meet. Bad commits are built with OpenMLS directly.

use super::*;

const GROUP: &[u8] = b"call_group_abi28";
const CALL: &[u8] = b"call_1";
const CONVERSATION: &[u8] = b"conv_parent";

fn device(name: &str) -> MlsDevice {
    MlsDevice::new(
        format!("acct_{name}").as_bytes(),
        format!("dev_{name}").as_bytes(),
    )
    .unwrap()
}

fn add<'a>(key_package: &'a [u8], account: &'a [u8], device: &'a [u8]) -> MemberAdd<'a> {
    MemberAdd {
        key_package,
        account_id: account,
        device_id: device,
    }
}

/// Alice creates the call group and adds Bob; both are at epoch 1.
fn call_pair() -> ([MlsDevice; 2], [MlsGroup; 2]) {
    let [alice, bob] = [device("alice"), device("bob")];
    let mut alice_group = alice.create_call_group(GROUP, CALL, CONVERSATION).unwrap();
    let bob_kp = bob.create_key_package().unwrap();
    let staged = alice
        .stage_membership_commit(
            &mut alice_group,
            &[add(&bob_kp, b"acct_bob", b"dev_bob")],
            &[],
        )
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    let bob_group = bob
        .join_call_group(GROUP, &staged.welcome, CALL, CONVERSATION)
        .unwrap();
    ([alice, bob], [alice_group, bob_group])
}

fn key(device: &MlsDevice, group: &MlsGroup, call: &[u8]) -> Result<Vec<u8>, MlsError> {
    device
        .b6_media_key(group, call, b"acct_alice", b"dev_alice", 0)
        .map(|key| key.as_slice().to_vec())
}

#[test]
fn the_marker_has_a_fixed_strict_encoding() {
    let marker = crate::b6::encode_call_marker(b"c1", b"conv").unwrap();
    assert_eq!(marker, b"\x01\x00\x02c1\x00\x04conv");
    assert_eq!(
        crate::b6::decode_call_marker(&marker).unwrap(),
        (&b"c1"[..], &b"conv"[..])
    );
    let mut trailing = marker.clone();
    trailing.push(0);
    let mut other_format = marker.clone();
    other_format[0] = 2;
    let long = [b'x'; 129];
    for bad in [
        &[][..],
        &trailing,
        &other_format,
        &marker[..marker.len() - 1],
        b"\x01\x00\x00\x00\x04conv",
        b"\x01\x00\x02c1\x00\x00",
    ] {
        assert!(crate::b6::decode_call_marker(bad).is_err(), "{bad:?}");
    }
    assert!(crate::b6::encode_call_marker(b"", b"conv").is_err());
    assert!(crate::b6::encode_call_marker(b"c1", &long).is_err());
    assert!(crate::b6::encode_call_marker(&long[..128], &long[..128]).is_ok());
}

#[test]
fn a_call_group_requires_and_carries_exactly_its_marker() {
    let alice = device("alice");
    let group = alice.create_call_group(GROUP, CALL, CONVERSATION).unwrap();
    assert!(same_extensions(
        group.extensions(),
        &genesis_extensions(CALL, CONVERSATION).unwrap()
    ));
    assert_eq!(bound_call_id(&group).unwrap(), CALL);
    let own = group.own_leaf_node().unwrap();
    assert!(own.capabilities().extensions().contains(&call_type()));

    // A conversation group has no marker and gives no media key.
    let plain = alice.create_group(b"conv_plain").unwrap();
    assert!(marker_of(plain.extensions()).is_none());
    assert_eq!(bound_call_id(&plain).err(), Some(MlsError::InvalidState));
    assert_eq!(
        key(&alice, &plain, CALL).err(),
        Some(MlsError::InvalidState)
    );
    // Nor does a C4 record group.
    let record = alice
        .create_group_with_record(b"conv_record", b"g0")
        .unwrap();
    assert_eq!(
        key(&alice, &record, CALL).err(),
        Some(MlsError::InvalidState)
    );

    // Malformed ids store nothing.
    let long = [b'x'; 129];
    for (call, conversation) in [(&b""[..], CONVERSATION), (CALL, &long[..])] {
        assert!(alice
            .create_call_group(b"call_bad", call, conversation)
            .is_err());
        assert!(alice.load_group(b"call_bad").is_err());
    }
}

#[test]
fn the_media_key_is_only_for_the_bound_call() {
    let ([alice, bob], [alice_group, bob_group]) = call_pair();
    let k = key(&alice, &alice_group, CALL).unwrap();
    assert_eq!(k, key(&bob, &bob_group, CALL).unwrap());
    assert_eq!(
        key(&alice, &alice_group, b"call_2").err(),
        Some(MlsError::InvalidState)
    );
    assert_eq!(
        key(&bob, &bob_group, b"call_").err(),
        Some(MlsError::InvalidState)
    );
}

#[test]
fn a_welcome_is_joined_only_for_the_room_asked_for() {
    let [alice, bob, carol, dave, erin] = ["alice", "bob", "carol", "dave", "erin"].map(device);
    let mut group = alice.create_call_group(GROUP, CALL, CONVERSATION).unwrap();
    let packages = [&bob, &carol, &dave, &erin].map(|d| d.create_key_package().unwrap());
    let adds = [
        add(&packages[0], b"acct_bob", b"dev_bob"),
        add(&packages[1], b"acct_carol", b"dev_carol"),
        add(&packages[2], b"acct_dave", b"dev_dave"),
        add(&packages[3], b"acct_erin", b"dev_erin"),
    ];
    let staged = alice
        .stage_membership_commit(&mut group, &adds, &[])
        .unwrap();
    alice.merge_pending_commit(&mut group).unwrap();
    let welcome = &staged.welcome;

    // Another call, another conversation, or the plain join: refused, and
    // nothing is stored.
    assert_eq!(
        carol
            .join_call_group(GROUP, welcome, b"call_2", CONVERSATION)
            .err(),
        Some(MlsError::InvalidIdentity)
    );
    assert_eq!(
        dave.join_call_group(GROUP, welcome, CALL, b"conv_other")
            .err(),
        Some(MlsError::InvalidIdentity)
    );
    assert_eq!(
        erin.join_group(GROUP, welcome).err(),
        Some(MlsError::InvalidIdentity)
    );
    for refused in [&carol, &dave, &erin] {
        assert!(refused.load_group(GROUP).is_err());
    }
    // Malformed ids are refused before the Welcome is opened.
    assert_eq!(
        bob.join_call_group(GROUP, welcome, b"", CONVERSATION).err(),
        Some(MlsError::InvalidIdentity)
    );
    let joined = bob
        .join_call_group(GROUP, welcome, CALL, CONVERSATION)
        .unwrap();
    assert_eq!(bound_call_id(&joined).unwrap(), CALL);
    assert_eq!(
        key(&bob, &joined, CALL).unwrap(),
        key(&alice, &group, CALL).unwrap()
    );
}

#[test]
fn the_call_join_refuses_a_conversation_group() {
    let [alice, bob] = [device("alice"), device("bob")];
    let mut group = alice.create_group(GROUP).unwrap();
    let bob_kp = bob.create_key_package().unwrap();
    let staged = alice
        .stage_membership_commit(&mut group, &[add(&bob_kp, b"acct_bob", b"dev_bob")], &[])
        .unwrap();
    alice.merge_pending_commit(&mut group).unwrap();
    assert_eq!(
        bob.join_call_group(GROUP, &staged.welcome, CALL, CONVERSATION)
            .err(),
        Some(MlsError::InvalidIdentity)
    );
    assert!(bob.load_group(GROUP).is_err());
}

#[test]
fn an_older_key_package_cannot_be_added_to_a_call_group() {
    // An ABI 27 key package: role and pad extensions, no call marker.
    let [alice, old] = [device("alice"), device("old")];
    let bundle = KeyPackage::builder()
        .leaf_node_capabilities(Capabilities::new(
            None,
            None,
            Some(&[
                ExtensionType::Unknown(c4::ROLE_EXTENSION_TYPE),
                ExtensionType::Unknown(crate::l2::PAD_EXTENSION_TYPE),
            ]),
            None,
            None,
        ))
        .build(
            CIPHERSUITE,
            &old.provider,
            &old.signer,
            old.credential.clone(),
        )
        .unwrap();
    let package = bundle.key_package().tls_serialize_detached().unwrap();
    let mut group = alice.create_call_group(GROUP, CALL, CONVERSATION).unwrap();
    assert!(alice
        .stage_membership_commit(&mut group, &[add(&package, b"acct_old", b"dev_old")], &[])
        .is_err());
    assert!(group.pending_commit().is_none());
    // A conversation group still takes it.
    let mut plain = alice.create_group(b"conv_plain").unwrap();
    assert!(alice
        .stage_membership_commit(&mut plain, &[add(&package, b"acct_old", b"dev_old")], &[])
        .is_ok());
}

#[test]
fn the_marker_never_changes_and_self_updates_keep_it() {
    let ([alice, bob], [mut alice_group, mut bob_group]) = call_pair();
    // Alice tries to rebind the group to another call through OpenMLS
    // directly; Bob refuses the commit and keeps his epoch.
    let rebound = genesis_extensions(b"call_2", CONVERSATION).unwrap();
    let id = alice_group.group_id().as_slice().to_vec();
    let mut commit = None;
    alice
        .in_group(&id, || {
            let bundle = alice_group
                .commit_builder()
                .propose_group_context_extensions(rebound)
                .unwrap()
                .load_psks(alice.provider.storage())
                .unwrap()
                .build(
                    alice.provider.rand(),
                    alice.provider.crypto(),
                    &alice.signer,
                    |_| true,
                )
                .unwrap()
                .stage_commit(&alice.provider)
                .unwrap();
            commit = Some(bundle.into_messages().0.tls_serialize_detached().unwrap());
            Ok(())
        })
        .unwrap();
    alice.clear_pending_commit(&mut alice_group).unwrap();
    let epoch = bob.group_epoch(&bob_group);
    assert!(bob
        .process_commit_with_outcome(&mut bob_group, &commit.unwrap())
        .is_err());
    let mut bob_group = bob.load_group(GROUP).unwrap();
    assert_eq!(bob.group_epoch(&bob_group), epoch);
    assert_eq!(bound_call_id(&bob_group).unwrap(), CALL);

    // A self-update (the hourly one) keeps the leaf's capabilities, so the
    // group still requires and carries the marker afterwards.
    let staged = bob.stage_self_update(&mut bob_group).unwrap();
    bob.merge_pending_commit(&mut bob_group).unwrap();
    alice
        .process_commit_with_outcome(&mut alice_group, &staged.commit)
        .unwrap();
    assert_eq!(bound_call_id(&alice_group).unwrap(), CALL);
    assert_eq!(
        key(&alice, &alice_group, CALL).unwrap(),
        key(&bob, &bob_group, CALL).unwrap()
    );
}
