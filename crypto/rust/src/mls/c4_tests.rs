//! C4 (ABI 20) tests: the role record carrier, the producer, the two-phase
//! receive and the refusals. Bad commits are built with OpenMLS directly,
//! bypassing the producer's own checks.

use super::super::records::SealedTable;
use super::*;

const KEY: [u8; 32] = [0x44; 32];
const GROUP: &[u8] = b"conv_c4";

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

/// Runs a direct OpenMLS call on `group` inside its storage scope.
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

/// Alice creates a record group with genesis `g0` and adds Bob and Carol
/// with record `r1`; everyone is at epoch 1.
fn record_group(group_id: &[u8]) -> ([MlsDevice; 3], [MlsGroup; 3]) {
    let [alice, bob, carol] = [device("alice"), device("bob"), device("carol")];
    let mut alice_group = alice.create_group_with_record(group_id, b"g0").unwrap();
    let (bob_kp, carol_kp) = (
        bob.create_key_package().unwrap(),
        carol.create_key_package().unwrap(),
    );
    let adds = [
        add(&bob_kp, b"acct_bob", b"dev_bob"),
        add(&carol_kp, b"acct_carol", b"dev_carol"),
    ];
    let staged = alice
        .stage_commit_with_record(&mut alice_group, &adds, &[None, None], &[], Some(b"r1"))
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    let bob_group = bob.join_group(group_id, &staged.welcome).unwrap();
    let carol_group = carol.join_group(group_id, &staged.welcome).unwrap();
    ([alice, bob, carol], [alice_group, bob_group, carol_group])
}

fn accounts(names: &[&str]) -> Vec<Vec<u8>> {
    names
        .iter()
        .map(|name| format!("acct_{name}").into_bytes())
        .collect()
}

/// Builds a commit from `device` with the given GroupContextExtensions
/// proposal straight through OpenMLS, then clears it on the sender.
fn crafted_gce(
    device: &MlsDevice,
    group: &mut MlsGroup,
    extensions: Extensions<GroupContext>,
) -> Option<Vec<u8>> {
    let commit = in_scope(device, group, |g| {
        let bundle = g
            .commit_builder()
            .propose_group_context_extensions(extensions)
            .ok()?
            .load_psks(device.provider.storage())
            .ok()?
            .build(
                device.provider.rand(),
                device.provider.crypto(),
                &device.signer,
                |_| true,
            )
            .ok()?
            .stage_commit(&device.provider)
            .ok()?;
        Some(bundle.into_messages().0.tls_serialize_detached().unwrap())
    });
    device.clear_pending_commit(group).unwrap();
    commit
}

fn record_ext(record: &[u8]) -> Extension {
    Extension::Unknown(ROLE_EXTENSION_TYPE, UnknownExtension(record.to_vec()))
}

fn required(types: &[ExtensionType], credentials: &[CredentialType]) -> Extension {
    Extension::RequiredCapabilities(RequiredCapabilitiesExtension::new(types, &[], credentials))
}

fn role() -> ExtensionType {
    ExtensionType::Unknown(ROLE_EXTENSION_TYPE)
}

/// Carol's two-phase stage refuses `commit` with `expected`, holds nothing
/// and moves nothing; then a valid commit from Alice on the same epoch
/// applies on Bob's and Carol's side, carrying `next` as the record.
fn assert_refused(
    devices: &[MlsDevice; 3],
    groups: &mut [MlsGroup; 3],
    commit: &[u8],
    expected: MlsError,
    next: &[u8],
) {
    let [alice, bob, carol] = devices;
    let epoch = carol.group_epoch(&groups[2]);
    assert_eq!(
        carol.stage_incoming_commit(&mut groups[2], commit).err(),
        Some(expected)
    );
    assert!(!carol.held.holds(GROUP));
    assert_eq!(carol.group_epoch(&groups[2]), epoch);
    let mut stored = carol.load_group(GROUP).unwrap();
    assert_eq!(carol.group_epoch(&stored), epoch);
    let staged = alice
        .stage_commit_with_record(&mut groups[0], &[], &[], &[], Some(next))
        .unwrap();
    alice.merge_pending_commit(&mut groups[0]).unwrap();
    for (device, group) in [(bob, &mut groups[1]), (carol, &mut stored)] {
        let review = device.stage_incoming_commit(group, &staged.commit).unwrap();
        assert_eq!(review.record_after.as_deref(), Some(next));
        device.merge_incoming_commit(group, &staged.commit).unwrap();
    }
    groups[2] = stored;
}

#[test]
fn key_packages_and_creators_advertise_the_role_extension() {
    let alice = device("alice");
    let package = KeyPackageIn::tls_deserialize_exact(alice.create_key_package().unwrap())
        .unwrap()
        .validate(alice.provider.crypto(), ProtocolVersion::Mls10)
        .unwrap();
    let capabilities = package.leaf_node().capabilities();
    assert_eq!(capabilities.extensions(), &[role()]);
    // Everything else stays OpenMLS's default.
    let defaults = Capabilities::default();
    assert_eq!(capabilities.versions(), defaults.versions());
    assert_eq!(capabilities.ciphersuites(), defaults.ciphersuites());
    assert_eq!(capabilities.proposals(), defaults.proposals());
    assert_eq!(capabilities.credentials(), defaults.credentials());

    // A plain group carries no record and requires nothing, but its
    // creator's leaf still advertises the extension.
    let plain = alice.create_group(b"conv_plain").unwrap();
    assert!(plain.extensions().iter().next().is_none());
    let own = plain.own_leaf_node().unwrap();
    assert!(own.capabilities().extensions().contains(&role()));
    assert_eq!(
        alice.role_state(&plain).unwrap(),
        (None, accounts(&["alice"]))
    );

    // A record group requires it and carries the genesis record.
    let group = alice.create_group_with_record(GROUP, b"genesis").unwrap();
    assert!(requires_role(group.extensions()));
    assert_eq!(
        alice.role_state(&group).unwrap(),
        (Some(b"genesis".to_vec()), accounts(&["alice"]))
    );
    assert_eq!(group.extensions().iter().count(), 2);
}

#[test]
fn group_creation_refuses_a_malformed_genesis() {
    let alice = device("alice");
    for record in [&b""[..], &vec![1; MAX_ROLE_RECORD_BYTES + 1]] {
        assert_eq!(
            alice
                .create_group_with_record(b"conv_bad_genesis", record)
                .err(),
            Some(MlsError::InvalidState)
        );
        assert!(alice.load_group(b"conv_bad_genesis").is_err());
    }
    let largest = vec![7; MAX_ROLE_RECORD_BYTES];
    let group = alice
        .create_group_with_record(b"conv_big_genesis", &largest)
        .unwrap();
    assert_eq!(alice.role_state(&group).unwrap().0, Some(largest));
}

#[test]
fn a_record_commit_is_reviewed_then_merged_and_a_joiner_reads_it() {
    let ([alice, bob, carol], [mut alice_group, mut bob_group, mut carol_group]) =
        record_group(GROUP);
    // The joiners read the record the add carried.
    for (device, group) in [(&bob, &bob_group), (&carol, &carol_group)] {
        assert_eq!(
            device.role_state(group).unwrap(),
            (Some(b"r1".to_vec()), accounts(&["alice", "bob", "carol"]))
        );
    }

    // Bob's role change alone: no adds, no removes.
    let staged = bob
        .stage_commit_with_record(&mut bob_group, &[], &[], &[], Some(b"r2"))
        .unwrap();
    assert!(staged.welcome.is_empty());
    bob.merge_pending_commit(&mut bob_group).unwrap();

    let review = carol
        .stage_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    assert_eq!(
        review.committer,
        LeafPair {
            account_id: b"acct_bob".to_vec(),
            device_id: b"dev_bob".to_vec(),
            signing_key: bob.signing_public_key().to_vec(),
        }
    );
    assert_eq!(
        review.flags,
        REVIEW_RECORD_PROPOSAL | REVIEW_RECORD_BEFORE | REVIEW_RECORD_AFTER
    );
    assert_eq!(review.new_epoch, 2);
    assert_eq!(review.record_before.as_deref(), Some(&b"r1"[..]));
    assert_eq!(review.record_after.as_deref(), Some(&b"r2"[..]));
    assert_eq!(review.roster_before, accounts(&["alice", "bob", "carol"]));
    assert_eq!(review.roster_after, review.roster_before);
    assert!(review.added.is_empty());
    // Staged, not merged.
    assert_eq!(carol.group_epoch(&carol_group), 1);
    assert_eq!(
        carol.role_state(&carol_group).unwrap().0,
        Some(b"r1".to_vec())
    );
    assert_eq!(carol.group_epoch(&carol.load_group(GROUP).unwrap()), 1);

    let outcome = carol
        .merge_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    assert_eq!(outcome.new_epoch, 2);
    assert!(!outcome.removed_any && !outcome.added_any && outcome.root.is_none());
    assert_eq!(carol.group_epoch(&carol_group), 2);
    assert_eq!(
        carol.role_state(&carol_group).unwrap().0,
        Some(b"r2".to_vec())
    );
    assert!(!carol.held.holds(GROUP));

    // The same commit through Alice's staged path too; then they talk.
    alice
        .stage_incoming_commit(&mut alice_group, &staged.commit)
        .unwrap();
    alice
        .merge_incoming_commit(&mut alice_group, &staged.commit)
        .unwrap();
    let hello = carol.encrypt(&mut carol_group, b"hello").unwrap();
    assert_eq!(
        alice
            .decrypt(&mut alice_group, &hello, b"acct_carol", b"dev_carol")
            .unwrap(),
        b"hello"
    );
}

#[test]
fn a_bare_commit_in_a_record_group_reviews_the_record_unchanged() {
    let ([_, bob, carol], [_, mut bob_group, mut carol_group]) = record_group(GROUP);
    let update = bob.stage_self_update(&mut bob_group).unwrap();
    bob.merge_pending_commit(&mut bob_group).unwrap();
    let review = carol
        .stage_incoming_commit(&mut carol_group, &update.commit)
        .unwrap();
    assert_eq!(review.flags, REVIEW_RECORD_BEFORE | REVIEW_RECORD_AFTER);
    assert_eq!(review.record_before, review.record_after);
    carol
        .merge_incoming_commit(&mut carol_group, &update.commit)
        .unwrap();
    // The update path kept the capability: Bob can still carry a record.
    let staged = bob
        .stage_commit_with_record(&mut bob_group, &[], &[], &[], Some(b"r2"))
        .unwrap();
    carol
        .stage_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    carol
        .merge_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
}

#[test]
fn rosters_count_accounts_not_devices() {
    let ([alice, bob, carol], [mut alice_group, _, mut carol_group]) = record_group(GROUP);
    let laptop = MlsDevice::new(b"acct_bob", b"dev_bob_laptop").unwrap();
    let kp = laptop.create_key_package().unwrap();
    let staged = alice
        .stage_commit_with_record(
            &mut alice_group,
            &[add(&kp, b"acct_bob", b"dev_bob_laptop")],
            &[None],
            &[],
            Some(b"r2"),
        )
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    let review = carol
        .stage_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    assert_eq!(review.flags & REVIEW_ADDED, REVIEW_ADDED);
    assert_eq!(review.roster_after, accounts(&["alice", "bob", "carol"]));
    assert_eq!(review.added.len(), 1);
    assert_eq!(review.added[0].device_id, b"dev_bob_laptop");
    carol
        .merge_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();

    // Removing one of Bob's two devices keeps his account in the roster;
    // removing the last one drops it.
    let one = [MemberIdentity {
        account_id: b"acct_bob",
        device_id: b"dev_bob",
    }];
    let staged = alice
        .stage_commit_with_record(&mut alice_group, &[], &[], &one, None)
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    let review = carol
        .stage_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    assert_eq!(review.flags & REVIEW_REMOVED, REVIEW_REMOVED);
    assert_eq!(review.roster_after, accounts(&["alice", "bob", "carol"]));
    carol
        .merge_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    let last = [MemberIdentity {
        account_id: b"acct_bob",
        device_id: b"dev_bob_laptop",
    }];
    let staged = alice
        .stage_commit_with_record(&mut alice_group, &[], &[], &last, Some(b"pruned"))
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    let review = carol
        .stage_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    assert_eq!(review.roster_before, accounts(&["alice", "bob", "carol"]));
    assert_eq!(review.roster_after, accounts(&["alice", "carol"]));
    assert_eq!(review.record_after.as_deref(), Some(&b"pruned"[..]));
    let _ = bob;
}

#[test]
fn the_producer_refuses_records_receivers_would_refuse() {
    let ([alice, bob, _], [mut alice_group, _, _]) = record_group(GROUP);
    let current = alice.role_state(&alice_group).unwrap().0.unwrap();
    for record in [&b""[..], &vec![1; MAX_ROLE_RECORD_BYTES + 1], &current] {
        assert_eq!(
            alice
                .stage_commit_with_record(&mut alice_group, &[], &[], &[], Some(record))
                .err(),
            Some(MlsError::InvalidState)
        );
        assert!(!alice.has_pending_commit(&alice_group));
    }
    // Nothing at all is still refused.
    assert_eq!(
        alice
            .stage_commit_with_record(&mut alice_group, &[], &[], &[], None)
            .err(),
        Some(MlsError::InvalidState)
    );
    // A group without a record never gains one.
    let mut plain = alice.create_group(b"conv_plain").unwrap();
    let kp = bob.create_key_package().unwrap();
    assert_eq!(
        alice
            .stage_commit_with_record(
                &mut plain,
                &[add(&kp, b"acct_bob", b"dev_bob")],
                &[None],
                &[],
                Some(b"late"),
            )
            .err(),
        Some(MlsError::InvalidState)
    );
    assert!(!alice.has_pending_commit(&plain));
    // The largest record goes through.
    let largest = vec![9; MAX_ROLE_RECORD_BYTES];
    alice
        .stage_commit_with_record(&mut alice_group, &[], &[], &[], Some(&largest))
        .unwrap();
}

#[test]
fn record_proposals_that_change_anything_else_are_refused() {
    let (devices, mut groups) = record_group(GROUP);
    let bob = &devices[1];
    // The current record is "r1" until the first refusal moves it on.
    let cases: Vec<(&str, Vec<Extension>)> = vec![
        (
            "same record",
            vec![required(&[role()], &[]), record_ext(b"r1")],
        ),
        ("drops the record", vec![required(&[role()], &[])]),
        (
            "empty record",
            vec![required(&[role()], &[]), record_ext(b"")],
        ),
        (
            "reordered",
            vec![record_ext(b"r2"), required(&[role()], &[])],
        ),
        (
            "changes the required capabilities",
            vec![
                required(&[role()], &[CredentialType::Basic]),
                record_ext(b"r2"),
            ],
        ),
        ("drops the required capabilities", vec![record_ext(b"r2")]),
    ];
    let mut refused = 0;
    for (index, (_name, extensions)) in cases.into_iter().enumerate() {
        let extensions = Extensions::from_vec(extensions).unwrap();
        // OpenMLS itself refuses some of these at the sender; whatever it
        // lets through, the receiver refuses by the C4 rule.
        if let Some(commit) = crafted_gce(bob, &mut groups[1], extensions) {
            let next = format!("next-{index}");
            assert_refused(
                &devices,
                &mut groups,
                &commit,
                MlsError::UnexpectedMessage,
                next.as_bytes(),
            );
            refused += 1;
        }
    }
    // At least the same-record, dropped-record, empty-record and reordered
    // proposals reach the receiver.
    assert!(refused >= 4, "only {refused} crafted proposals were built");
    // An oversized record (still under the 4 MiB handshake cap).
    let big = Extensions::from_vec(vec![
        required(&[role()], &[]),
        record_ext(&vec![2; MAX_ROLE_RECORD_BYTES + 1]),
    ])
    .unwrap();
    let commit = crafted_gce(bob, &mut groups[1], big).expect("OpenMLS builds it");
    assert_refused(
        &devices,
        &mut groups,
        &commit,
        MlsError::UnexpectedMessage,
        b"after-big",
    );
}

#[test]
fn a_record_proposal_in_a_group_without_a_record_is_refused() {
    let [alice, bob] = [device("alice"), device("bob")];
    let mut alice_group = alice.create_group(b"conv_plain").unwrap();
    let kp = bob.create_key_package().unwrap();
    let staged = alice
        .stage_membership_commit(&mut alice_group, &[add(&kp, b"acct_bob", b"dev_bob")], &[])
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    let mut bob_group = bob.join_group(b"conv_plain", &staged.welcome).unwrap();
    // Every leaf supports the extension, so OpenMLS accepts the migration;
    // Veritra does not (no migration, C0's rule).
    let migrate =
        Extensions::from_vec(vec![required(&[role()], &[]), record_ext(b"late")]).unwrap();
    let commit = crafted_gce(&alice, &mut alice_group, migrate).expect("OpenMLS builds it");
    assert_eq!(
        bob.stage_incoming_commit(&mut bob_group, &commit).err(),
        Some(MlsError::UnexpectedMessage)
    );
    assert_eq!(bob.group_epoch(&bob_group), 1);
    assert_eq!(bob.role_state(&bob_group).unwrap().0, None);
}

#[test]
fn the_one_shot_calls_refuse_any_record_proposal() {
    let ([alice, bob, carol], [mut alice_group, mut bob_group, mut carol_group]) =
        record_group(GROUP);
    let staged = bob
        .stage_commit_with_record(&mut bob_group, &[], &[], &[], Some(b"r2"))
        .unwrap();
    for (device, group) in [(&alice, &mut alice_group), (&carol, &mut carol_group)] {
        assert_eq!(
            device
                .process_commit_with_outcome(group, &staged.commit)
                .err(),
            Some(MlsError::UnexpectedMessage)
        );
        assert_eq!(device.group_epoch(group), 1);
    }
    // A bare commit in a record group still goes through the one-shot path.
    bob.clear_pending_commit(&mut bob_group).unwrap();
    let update = bob.stage_self_update(&mut bob_group).unwrap();
    bob.merge_pending_commit(&mut bob_group).unwrap();
    let mut stored = alice.load_group(GROUP).unwrap();
    alice.process_commit(&mut stored, &update.commit).unwrap();
    assert_eq!(alice.group_epoch(&stored), 2);
}

#[test]
fn a_key_package_without_the_capability_cannot_join_a_record_group() {
    let ([alice, _, _], [mut alice_group, _, _]) = record_group(GROUP);
    let old = device("dave");
    // An ABI 19 key package: OpenMLS's default capabilities.
    let package = KeyPackage::builder()
        .build(
            CIPHERSUITE,
            &old.provider,
            &old.signer,
            old.credential.clone(),
        )
        .unwrap()
        .key_package()
        .tls_serialize_detached()
        .unwrap();
    assert!(alice
        .stage_commit_with_record(
            &mut alice_group,
            &[add(&package, b"acct_dave", b"dev_dave")],
            &[None],
            &[],
            Some(b"r2"),
        )
        .is_err());
    assert!(!alice.has_pending_commit(&alice_group));
    // In a plain group it still joins.
    let mut plain = alice.create_group(b"conv_plain").unwrap();
    alice
        .stage_membership_commit(&mut plain, &[add(&package, b"acct_dave", b"dev_dave")], &[])
        .unwrap();
}

#[test]
fn an_update_path_that_drops_the_capability_is_refused() {
    let (devices, mut groups) = record_group(GROUP);
    let bob = &devices[1];
    let built = in_scope(bob, &mut groups[1], |g| {
        let bundle = g
            .commit_builder()
            .force_self_update(true)
            .leaf_node_parameters(
                LeafNodeParameters::builder()
                    .with_capabilities(Capabilities::default())
                    .build(),
            )
            .load_psks(bob.provider.storage())
            .ok()?
            .build(
                bob.provider.rand(),
                bob.provider.crypto(),
                &bob.signer,
                |_| true,
            )
            .ok()?
            .stage_commit(&bob.provider)
            .ok()?;
        Some(bundle.into_messages().0.tls_serialize_detached().unwrap())
    });
    bob.clear_pending_commit(&mut groups[1]).unwrap();
    // OpenMLS 0.9.2 refuses it at the sender already (the leaf must keep
    // the required capability); should a later version build it, the
    // receiver must still refuse it.
    if let Some(commit) = built {
        let carol = &devices[2];
        assert!(carol
            .stage_incoming_commit(&mut groups[2], &commit)
            .is_err());
        assert_eq!(carol.group_epoch(&groups[2]), 1);
    }
}

#[test]
fn a_removed_device_reviews_and_merges_its_own_removal() {
    let ([alice, _, carol], [mut alice_group, _, mut carol_group]) = record_group(GROUP);
    let gone = [MemberIdentity {
        account_id: b"acct_carol",
        device_id: b"dev_carol",
    }];
    let staged = alice
        .stage_commit_with_record(&mut alice_group, &[], &[], &gone, Some(b"pruned"))
        .unwrap();
    alice.merge_pending_commit(&mut alice_group).unwrap();
    let review = carol
        .stage_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    assert_eq!(
        review.flags & (REVIEW_REMOVED | REVIEW_REMOVED_SELF | REVIEW_RECORD_PROPOSAL),
        REVIEW_REMOVED | REVIEW_REMOVED_SELF | REVIEW_RECORD_PROPOSAL
    );
    assert_eq!(review.committer.account_id, b"acct_alice");
    assert_eq!(review.roster_after, accounts(&["alice", "bob"]));
    assert_eq!(review.record_after.as_deref(), Some(&b"pruned"[..]));
    let outcome = carol
        .merge_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    assert!(outcome.removed_self && outcome.root.is_none());
    // The group store went with the removal (D70).
    assert_eq!(carol.load_group(GROUP).err(), Some(MlsError::InvalidState));
}

#[test]
fn a_merge_must_name_the_staged_commit_on_its_epoch() {
    let ([alice, bob, carol], [mut alice_group, mut bob_group, mut carol_group]) =
        record_group(GROUP);
    let from_bob = bob
        .stage_commit_with_record(&mut bob_group, &[], &[], &[], Some(b"bob"))
        .unwrap();
    let from_alice = alice
        .stage_commit_with_record(&mut alice_group, &[], &[], &[], Some(b"alice"))
        .unwrap();

    // Nothing held: refused.
    assert_eq!(
        carol
            .merge_incoming_commit(&mut carol_group, &from_bob.commit)
            .err(),
        Some(MlsError::InvalidState)
    );
    carol
        .stage_incoming_commit(&mut carol_group, &from_bob.commit)
        .unwrap();
    // Other bytes: refused, and the staged commit stays held.
    assert_eq!(
        carol
            .merge_incoming_commit(&mut carol_group, &from_alice.commit)
            .err(),
        Some(MlsError::InvalidState)
    );
    assert!(carol.held.holds(GROUP));
    assert_eq!(carol.group_epoch(&carol_group), 1);

    // The epoch moves underneath it (Alice's commit, merged outside the
    // device's calls): the held commit no longer applies.
    in_scope(&carol, &mut carol_group, |g| {
        let message = MlsMessageIn::tls_deserialize_exact(&from_alice.commit)
            .unwrap()
            .try_into_protocol_message()
            .unwrap();
        let processed = g.process_message(&carol.provider, message).unwrap();
        let ProcessedMessageContent::StagedCommitMessage(staged) = processed.into_content() else {
            panic!("not a commit");
        };
        g.merge_staged_commit(&carol.provider, *staged).unwrap();
    });
    assert_eq!(carol.group_epoch(&carol_group), 2);
    assert_eq!(
        carol
            .merge_incoming_commit(&mut carol_group, &from_bob.commit)
            .err(),
        Some(MlsError::InvalidState)
    );
    assert_eq!(carol.group_epoch(&carol_group), 2);
    assert_eq!(
        carol.role_state(&carol_group).unwrap().0,
        Some(b"alice".to_vec())
    );
}

#[test]
fn a_discarded_commit_changes_nothing_and_cannot_be_staged_again() {
    let ([_, bob, carol], [_, mut bob_group, _]) = record_group(GROUP);
    let mut table = SealedTable::default();
    let mut carol = carol;
    table.commit(&mut carol, &KEY);
    let staged = bob
        .stage_commit_with_record(&mut bob_group, &[], &[], &[], Some(b"r2"))
        .unwrap();

    let mut group = carol.load_group(GROUP).unwrap();
    carol
        .stage_incoming_commit(&mut group, &staged.commit)
        .unwrap();
    assert!(carol.discard_incoming_commit(GROUP).unwrap());
    assert!(!carol.discard_incoming_commit(GROUP).unwrap());
    assert_eq!(
        carol
            .merge_incoming_commit(&mut group, &staged.commit)
            .err(),
        Some(MlsError::InvalidState)
    );
    assert_eq!(carol.group_epoch(&group), 1);
    assert_eq!(carol.role_state(&group).unwrap().0, Some(b"r1".to_vec()));
    // Staging consumed the commit's handshake ratchet step: the same bytes
    // never stage twice on this state...
    let mut again = carol.load_group(GROUP).unwrap();
    assert!(carol
        .stage_incoming_commit(&mut again, &staged.commit)
        .is_err());
    // ...so the app restores its committed state (never sealing after a
    // discard), and from there the commit stages and merges.
    let restored = table.restore(b"acct_carol", b"dev_carol", &KEY).unwrap();
    let mut group = restored.load_group(GROUP).unwrap();
    assert_eq!(restored.role_state(&group).unwrap().0, Some(b"r1".to_vec()));
    restored
        .stage_incoming_commit(&mut group, &staged.commit)
        .unwrap();
    restored
        .merge_incoming_commit(&mut group, &staged.commit)
        .unwrap();
    assert_eq!(restored.role_state(&group).unwrap().0, Some(b"r2".to_vec()));
}

#[test]
fn the_record_survives_seal_and_restore_and_nothing_held_does() {
    let ([_, bob, mut carol], [_, mut bob_group, mut carol_group]) = record_group(GROUP);
    let staged = bob
        .stage_commit_with_record(&mut bob_group, &[], &[], &[], Some(b"r2"))
        .unwrap();
    carol
        .stage_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    let mut table = SealedTable::default();
    table.commit(&mut carol, &KEY);
    let restored = table.restore(b"acct_carol", b"dev_carol", &KEY).unwrap();
    assert!(!restored.held.holds(GROUP));
    let mut group = restored.load_group(GROUP).unwrap();
    assert_eq!(
        restored.role_state(&group).unwrap(),
        (Some(b"r1".to_vec()), accounts(&["alice", "bob", "carol"]))
    );
    assert_eq!(
        restored
            .merge_incoming_commit(&mut group, &staged.commit)
            .err(),
        Some(MlsError::InvalidState)
    );
}

#[test]
fn deleting_processing_or_an_own_merge_forgets_a_held_commit() {
    let ([alice, bob, carol], [mut alice_group, mut bob_group, mut carol_group]) =
        record_group(GROUP);
    let staged = bob
        .stage_commit_with_record(&mut bob_group, &[], &[], &[], Some(b"r2"))
        .unwrap();
    carol
        .stage_incoming_commit(&mut carol_group, &staged.commit)
        .unwrap();
    assert!(carol.held.holds(GROUP));
    assert!(carol.delete_group(GROUP).unwrap());
    assert!(!carol.held.holds(GROUP));

    // A one-shot process on the group forgets it too.
    alice
        .stage_incoming_commit(&mut alice_group, &staged.commit)
        .unwrap();
    bob.clear_pending_commit(&mut bob_group).unwrap();
    let update = bob.stage_self_update(&mut bob_group).unwrap();
    // (Alice's held commit is Bob's dropped one; his update wins instead.)
    let mut stored = alice.load_group(GROUP).unwrap();
    alice.process_commit(&mut stored, &update.commit).unwrap();
    assert!(!alice.held.holds(GROUP));
    // And so does merging its own commit: Bob's next commit is held, then
    // Alice's own commit on the same epoch wins.
    bob.merge_pending_commit(&mut bob_group).unwrap();
    let next = bob
        .stage_commit_with_record(&mut bob_group, &[], &[], &[], Some(b"bob-next"))
        .unwrap();
    alice
        .stage_incoming_commit(&mut stored, &next.commit)
        .unwrap();
    assert!(alice.held.holds(GROUP));
    let own = alice
        .stage_commit_with_record(&mut stored, &[], &[], &[], Some(b"own"))
        .unwrap();
    assert_eq!(own.epoch, 2);
    alice.merge_pending_commit(&mut stored).unwrap();
    assert!(!alice.held.holds(GROUP));
}

#[test]
fn a_welcome_with_an_unrequired_record_is_refused() {
    let [alice, bob] = [device("alice"), device("bob")];
    // A context that carries the record without requiring the extension,
    // built past the device's own constructor.
    let extensions = Extensions::from_vec(vec![record_ext(b"g0")]).unwrap();
    let config = group_create_config_with(Some(extensions));
    let built = alice.in_group(b"conv_unrequired", || {
        MlsGroup::new_with_group_id(
            &alice.provider,
            &alice.signer,
            &config,
            GroupId::from_slice(b"conv_unrequired"),
            alice.credential.clone(),
        )
        .map_err(|_| MlsError::GroupOperation)
    });
    // OpenMLS 0.9.2 lets the creator build it; the joiner must refuse.
    let mut group = built.expect("OpenMLS builds the group");
    let kp = bob.create_key_package().unwrap();
    let staged = alice
        .stage_membership_commit(&mut group, &[add(&kp, b"acct_bob", b"dev_bob")], &[])
        .unwrap();
    assert_eq!(
        bob.join_group(b"conv_unrequired", &staged.welcome).err(),
        Some(MlsError::InvalidIdentity)
    );
}

#[test]
fn review_and_state_encodings_are_exact() {
    let review = CommitReview {
        flags: REVIEW_ADDED | REVIEW_RECORD_PROPOSAL | REVIEW_RECORD_AFTER,
        new_epoch: 0x0102_0304_0506_0708,
        committer: LeafPair {
            account_id: b"a".to_vec(),
            device_id: b"d".to_vec(),
            signing_key: vec![0xAA; 32],
        },
        added: vec![LeafPair {
            account_id: b"b".to_vec(),
            device_id: b"e".to_vec(),
            signing_key: vec![0xBB; 32],
        }],
        roster_before: vec![b"a".to_vec()],
        roster_after: vec![b"a".to_vec(), b"b".to_vec()],
        record_before: None,
        record_after: Some(b"RR".to_vec()),
    };
    let mut expected = vec![1, 2 | 8 | 32, 1, 2, 3, 4, 5, 6, 7, 8];
    expected.extend_from_slice(&[0, 1, b'a', 0, 1, b'd']);
    expected.extend_from_slice(&[0xAA; 32]);
    expected.extend_from_slice(&[0, 1, 0, 1, b'b', 0, 1, b'e']);
    expected.extend_from_slice(&[0xBB; 32]);
    expected.extend_from_slice(&[0, 1, 0, 1, b'a']);
    expected.extend_from_slice(&[0, 2, 0, 1, b'a', 0, 1, b'b']);
    expected.extend_from_slice(&[0, 0, 0, 0]);
    expected.extend_from_slice(&[0, 0, 0, 2, b'R', b'R']);
    assert_eq!(review.encode().unwrap(), expected);

    assert_eq!(
        encode_role_state(Some(b"X"), &[b"a".to_vec()]).unwrap(),
        [1, 1, 0, 1, 0, 1, b'a', 0, 0, 0, 1, b'X']
    );
    assert_eq!(
        encode_role_state(None, &[]).unwrap(),
        [1, 0, 0, 0, 0, 0, 0, 0]
    );
}
