//! A device removed from a conversation and later re-added must be able to
//! join again from the new Welcome, whether or not it processed its own
//! removal commit first. The server resets the device's roster window on a
//! re-add, so a device that was offline during its removal never sees that
//! commit: its first event after the re-add is the Welcome.
//!
//! A Welcome must still never replace an active group on the say-so of a
//! device that was not a member of it (see `docs/crypto.md`, "Rejoining a
//! conversation").

use openmls::prelude::MlsGroup;
use private_messenger_crypto::mls::{MemberAdd, MemberIdentity, MlsDevice, MlsError};

const GROUP_ID: &[u8] = b"conv_rejoin";
const STATE_KEY: [u8; 32] = [7; 32];

struct Member {
    device: MlsDevice,
    account: Vec<u8>,
    device_id: Vec<u8>,
}

impl Member {
    fn new(name: &str) -> Self {
        let account = format!("acct_{name}").into_bytes();
        let device_id = format!("dev_{name}").into_bytes();
        let device = MlsDevice::new(&account, &device_id).unwrap();
        Self {
            device,
            account,
            device_id,
        }
    }

    fn identity(&self) -> MemberIdentity<'_> {
        MemberIdentity {
            account_id: &self.account,
            device_id: &self.device_id,
        }
    }

    /// Stages and merges one commit, as the app does after the server
    /// accepts it. Returns the commit and the Welcome (empty without adds).
    fn commit(
        &self,
        group: &mut MlsGroup,
        adds: &[&Member],
        removes: &[&Member],
    ) -> (Vec<u8>, Vec<u8>) {
        let packages: Vec<_> = adds
            .iter()
            .map(|member| member.device.create_key_package().unwrap())
            .collect();
        let adds: Vec<_> = adds
            .iter()
            .zip(&packages)
            .map(|(member, package)| MemberAdd {
                key_package: package,
                account_id: &member.account,
                device_id: &member.device_id,
            })
            .collect();
        let removes: Vec<_> = removes.iter().map(|member| member.identity()).collect();
        let staged = self
            .device
            .stage_membership_commit(group, &adds, &removes)
            .unwrap();
        self.device.merge_pending_commit(group).unwrap();
        (staged.commit, staged.welcome)
    }

    fn self_update(&self, group: &mut MlsGroup) -> Vec<u8> {
        let staged = self.device.stage_self_update(group).unwrap();
        self.device.merge_pending_commit(group).unwrap();
        staged.commit
    }

    fn send(&self, group: &mut MlsGroup, to: &Member, to_group: &mut MlsGroup, text: &[u8]) {
        let ciphertext = self.device.encrypt(group, text).unwrap();
        let plaintext = to
            .device
            .decrypt(to_group, &ciphertext, &self.account, &self.device_id)
            .unwrap();
        assert_eq!(plaintext, text);
    }
}

/// Alice creates the conversation and adds Bob; both hold the group.
fn alice_and_bob() -> (Member, Member, MlsGroup, MlsGroup) {
    let alice = Member::new("alice");
    let bob = Member::new("bob");
    let mut alice_group = alice.device.create_group(GROUP_ID).unwrap();
    let (_, welcome) = alice.commit(&mut alice_group, &[&bob], &[]);
    let mut bob_group = bob.device.join_group(GROUP_ID, &welcome).unwrap();
    alice.send(&mut alice_group, &bob, &mut bob_group, b"before removal");
    (alice, bob, alice_group, bob_group)
}

fn assert_rejoined(alice: &Member, alice_group: &mut MlsGroup, bob: &Member, welcome: &[u8]) {
    let mut bob_group = bob
        .device
        .join_group(GROUP_ID, welcome)
        .expect("a re-added device joins from its new Welcome");
    assert!(bob_group.is_active());
    assert_eq!(bob_group.epoch(), alice_group.epoch());
    alice.send(alice_group, bob, &mut bob_group, b"welcome back");
    bob.send(&mut bob_group, alice, alice_group, b"glad to be back");

    // The replaced group left nothing behind: the state seals and restores,
    // and a second removal and re-add works the same way.
    let sealed = bob.device.seal_state(&STATE_KEY, 2).unwrap();
    let (restored, _) =
        MlsDevice::restore_state(&bob.account, &bob.device_id, &STATE_KEY, 2, &sealed).unwrap();
    let mut restored_group = restored.load_group(GROUP_ID).unwrap();
    let ciphertext = alice.device.encrypt(alice_group, b"after restore").unwrap();
    assert_eq!(
        restored
            .decrypt(
                &mut restored_group,
                &ciphertext,
                &alice.account,
                &alice.device_id
            )
            .unwrap(),
        b"after restore"
    );
    let bob = Member {
        device: restored,
        account: bob.account.clone(),
        device_id: bob.device_id.clone(),
    };
    let (removal, _) = alice.commit(alice_group, &[], &[&bob]);
    bob.device
        .process_commit(&mut restored_group, &removal)
        .unwrap();
    assert!(!restored_group.is_active());
    let (_, welcome) = alice.commit(alice_group, &[&bob], &[]);
    let mut again = bob.device.join_group(GROUP_ID, &welcome).unwrap();
    alice.send(alice_group, &bob, &mut again, b"second return");
}

#[test]
fn a_device_that_processed_its_removal_rejoins() {
    let (alice, bob, mut alice_group, mut bob_group) = alice_and_bob();
    let (removal, _) = alice.commit(&mut alice_group, &[], &[&bob]);
    bob.device.process_commit(&mut bob_group, &removal).unwrap();
    assert!(!bob_group.is_active());

    let (_, welcome) = alice.commit(&mut alice_group, &[&bob], &[]);
    assert_rejoined(&alice, &mut alice_group, &bob, &welcome);
}

/// Once the device has applied its removal it is in no group under this id,
/// so the Welcome counts as a fresh join, whoever sends it.
#[test]
fn a_device_that_processed_its_removal_rejoins_through_a_newer_member() {
    let (alice, bob, mut alice_group, mut bob_group) = alice_and_bob();
    let carol = Member::new("carol");
    let (removal, _) = alice.commit(&mut alice_group, &[], &[&bob]);
    bob.device.process_commit(&mut bob_group, &removal).unwrap();
    let (_, carol_welcome) = alice.commit(&mut alice_group, &[&carol], &[]);
    let mut carol_group = carol.device.join_group(GROUP_ID, &carol_welcome).unwrap();

    let (_, welcome) = carol.commit(&mut carol_group, &[&bob], &[]);
    let mut bob_group = bob.device.join_group(GROUP_ID, &welcome).unwrap();
    carol.send(&mut carol_group, &bob, &mut bob_group, b"hello again");
}

#[test]
fn a_device_that_never_saw_its_removal_rejoins() {
    let (alice, bob, mut alice_group, bob_group) = alice_and_bob();
    let (_removal, _) = alice.commit(&mut alice_group, &[], &[&bob]);
    alice.self_update(&mut alice_group);
    // Bob was offline: his stored group is still active at the old epoch.
    assert!(bob_group.is_active());

    let (_, welcome) = alice.commit(&mut alice_group, &[&bob], &[]);
    assert_rejoined(&alice, &mut alice_group, &bob, &welcome);
}

/// Bob's stored group still loads, active and at the same epoch.
fn assert_untouched(bob: &Member, epoch: u64) {
    let stored = bob.device.load_group(GROUP_ID).unwrap();
    assert!(stored.is_active());
    assert_eq!(stored.epoch().as_u64(), epoch);
}

#[test]
fn a_device_outside_the_active_group_cannot_replace_it() {
    let (_alice, bob, _alice_group, bob_group) = alice_and_bob();
    let epoch = bob_group.epoch().as_u64();

    // A device the server made up builds its own group under the same id
    // and pushes its epoch past Bob's, so only the sender rule can refuse.
    let mallory = Member::new("mallory");
    let mut forged = mallory.device.create_group(GROUP_ID).unwrap();
    for _ in 0..3 {
        mallory.self_update(&mut forged);
    }
    let (_, welcome) = mallory.commit(&mut forged, &[&bob], &[]);
    assert!(forged.epoch().as_u64() > epoch);

    assert_eq!(
        bob.device.join_group(GROUP_ID, &welcome).err(),
        Some(MlsError::GroupOperation)
    );
    assert_untouched(&bob, epoch);
}

/// The server can publish a key package under a real member's identity
/// (until L1); a sender with Alice's identity but not her signing key is
/// not Alice.
#[test]
fn a_look_alike_of_an_old_member_cannot_replace_the_active_group() {
    let (_alice, bob, _alice_group, bob_group) = alice_and_bob();
    let epoch = bob_group.epoch().as_u64();
    let look_alike = Member::new("alice");
    let mut forged = look_alike.device.create_group(GROUP_ID).unwrap();
    for _ in 0..3 {
        look_alike.self_update(&mut forged);
    }
    let (_, welcome) = look_alike.commit(&mut forged, &[&bob], &[]);
    assert!(forged.epoch().as_u64() > epoch);

    assert_eq!(
        bob.device.join_group(GROUP_ID, &welcome).err(),
        Some(MlsError::GroupOperation)
    );
    assert_untouched(&bob, epoch);
}

#[test]
fn an_active_group_is_not_replaced_by_an_older_or_equal_epoch() {
    let (alice, bob, mut alice_group, mut bob_group) = alice_and_bob();
    // Bob's view moves ahead of Alice's (three of his updates she never
    // applies), so her later Welcome carries an epoch no higher than his.
    for _ in 0..3 {
        bob.self_update(&mut bob_group);
    }
    let epoch = bob_group.epoch().as_u64();

    // Alice forks: she removes and re-adds Bob from her view, at an epoch
    // no higher than Bob's.
    let (_removal, _) = alice.commit(&mut alice_group, &[], &[&bob]);
    let (_, welcome) = alice.commit(&mut alice_group, &[&bob], &[]);
    assert!(alice_group.epoch().as_u64() <= epoch);

    assert_eq!(
        bob.device.join_group(GROUP_ID, &welcome).err(),
        Some(MlsError::GroupOperation)
    );
    assert_untouched(&bob, epoch);
}

/// Residual, pinned so a change to it is deliberate: when the device never
/// saw its removal and the member re-adding it joined after that removal,
/// nothing the device holds shows that member belongs to the group, so the
/// join is refused and the stale group stays.
#[test]
fn a_rejoin_from_a_member_unknown_to_the_stale_group_is_refused() {
    let (alice, bob, mut alice_group, bob_group) = alice_and_bob();
    let epoch = bob_group.epoch().as_u64();
    let carol = Member::new("carol");
    let (_removal, _) = alice.commit(&mut alice_group, &[], &[&bob]);
    let (_, carol_welcome) = alice.commit(&mut alice_group, &[&carol], &[]);
    let mut carol_group = carol.device.join_group(GROUP_ID, &carol_welcome).unwrap();

    let (_, welcome) = carol.commit(&mut carol_group, &[&bob], &[]);
    assert_eq!(
        bob.device.join_group(GROUP_ID, &welcome).err(),
        Some(MlsError::GroupOperation)
    );
    assert_untouched(&bob, epoch);
}
