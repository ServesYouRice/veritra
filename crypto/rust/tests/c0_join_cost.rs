//! C0: what joining and leaving an MLS group costs at community sizes.
//!
//! Sizes count leaves (devices), not accounts: one account may hold up to ten
//! devices (D38). The group is built the way the app builds it today: the
//! creator adds every device in one staged commit (card I51). Add-only
//! commits carry no update path, so parent nodes stay blank and new leaves
//! sit unmerged. This "cold" tree is the normal case, not a rare one: every
//! join is an add-only commit. A commit that carries a path (a removal, a
//! self-update) then encrypts to whole subtrees. The "warm" numbers come from
//! a tree in which every even leaf has committed once, which fills every
//! parent node. `removal_cost_after_self_updates` measures the steps between:
//! a cold tree after k members have each committed one self-update.
//!
//! The quick case runs in `cargo test`. The measured sizes are ignored there
//! and run in release, with output:
//!
//! ```text
//! cargo test --locked --release --test c0_join_cost -- --ignored --nocapture --test-threads 1
//! ```
//!
//! Results are recorded in `testing/evidence/C0-community-groups.md`.

use std::time::{Duration, Instant};

use openmls::prelude::MlsGroup;
use private_messenger_crypto::mls::{MemberAdd, MemberIdentity, MlsDevice};

const GROUP_ID: &[u8] = b"conv_c0_bench";

struct Member {
    device: MlsDevice,
    account: Vec<u8>,
    device_id: Vec<u8>,
}

impl Member {
    fn new(label: &str, index: usize) -> Self {
        let account = format!("acct_{label}_{index}").into_bytes();
        let device_id = format!("dev_{label}_{index}").into_bytes();
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
}

/// One measured join: the committer stages and merges, the new device
/// processes the Welcome, one existing member processes the commit.
struct JoinSample {
    stage: Duration,
    merge: Duration,
    welcome_process: Duration,
    member_process: Duration,
    commit_bytes: usize,
    welcome_bytes: usize,
}

/// One measured removal (the commit carries an update path).
struct RemoveSample {
    stage: Duration,
    member_process: Duration,
    commit_bytes: usize,
}

struct Group {
    creator: Member,
    creator_group: MlsGroup,
    observer: Member,
    observer_group: MlsGroup,
    /// Devices added in the bulk commit, other than the observer. They hold
    /// no group state unless the warm phase gives them one.
    others: Vec<Member>,
    bulk_welcome_bytes: usize,
}

/// Builds a group of `leaves` devices with one bulk commit and lets one
/// member (the observer) join, so commits can be processed by a member.
/// Returns the bulk Welcome too, so every member can join the same tree.
fn build_group(leaves: usize) -> (Group, Vec<u8>) {
    assert!(leaves >= 2);
    let creator = Member::new("creator", 0);
    let mut creator_group = creator.device.create_group(GROUP_ID).unwrap();
    let observer = Member::new("observer", 0);
    let others = (0..leaves - 2)
        .map(|index| Member::new("member", index))
        .collect::<Vec<_>>();
    let key_packages = std::iter::once(&observer)
        .chain(others.iter())
        .map(|member| member.device.create_key_package().unwrap())
        .collect::<Vec<_>>();
    let adds = std::iter::once(&observer)
        .chain(others.iter())
        .zip(key_packages.iter())
        .map(|(member, key_package)| MemberAdd {
            key_package,
            account_id: &member.account,
            device_id: &member.device_id,
        })
        .collect::<Vec<_>>();
    let staged = creator
        .device
        .stage_membership_commit(&mut creator_group, &adds, &[])
        .unwrap();
    creator
        .device
        .merge_pending_commit(&mut creator_group)
        .unwrap();
    let observer_group = observer
        .device
        .join_group(GROUP_ID, &staged.welcome)
        .unwrap();
    assert_eq!(creator_group.members().count(), leaves);
    let bulk_welcome_bytes = staged.welcome.len();
    (
        Group {
            creator,
            creator_group,
            observer,
            observer_group,
            others,
            bulk_welcome_bytes,
        },
        staged.welcome,
    )
}

fn join_one(group: &mut Group, joiner: &Member) -> (JoinSample, MlsGroup) {
    let key_package = joiner.device.create_key_package().unwrap();
    let add = MemberAdd {
        key_package: &key_package,
        account_id: &joiner.account,
        device_id: &joiner.device_id,
    };
    let started = Instant::now();
    let staged = group
        .creator
        .device
        .stage_membership_commit(&mut group.creator_group, &[add], &[])
        .unwrap();
    let stage = started.elapsed();
    let started = Instant::now();
    group
        .creator
        .device
        .merge_pending_commit(&mut group.creator_group)
        .unwrap();
    let merge = started.elapsed();
    let started = Instant::now();
    let joined = joiner.device.join_group(GROUP_ID, &staged.welcome).unwrap();
    let welcome_process = started.elapsed();
    let started = Instant::now();
    group
        .observer
        .device
        .process_commit(&mut group.observer_group, &staged.commit)
        .unwrap();
    let member_process = started.elapsed();
    (
        JoinSample {
            stage,
            merge,
            welcome_process,
            member_process,
            commit_bytes: staged.commit.len(),
            welcome_bytes: staged.welcome.len(),
        },
        joined,
    )
}

fn remove_one(group: &mut Group, leaving: &Member) -> RemoveSample {
    let started = Instant::now();
    let staged = group
        .creator
        .device
        .stage_membership_commit(&mut group.creator_group, &[], &[leaving.identity()])
        .unwrap();
    let stage = started.elapsed();
    group
        .creator
        .device
        .merge_pending_commit(&mut group.creator_group)
        .unwrap();
    let started = Instant::now();
    group
        .observer
        .device
        .process_commit(&mut group.observer_group, &staged.commit)
        .unwrap();
    let member_process = started.elapsed();
    RemoveSample {
        stage,
        member_process,
        commit_bytes: staged.commit.len(),
    }
}

/// Gives every member a group state and lets every even leaf commit a
/// self-update that all members process, so no parent node stays blank.
/// Afterwards the creator and observer are in sync; nobody else matters.
fn warm_tree(group: &mut Group, welcome: &[u8]) {
    let mut states = group
        .others
        .iter()
        .map(|member| member.device.join_group(GROUP_ID, welcome).unwrap())
        .collect::<Vec<_>>();
    for committer in (0..group.others.len()).step_by(2) {
        let commit = group.others[committer]
            .device
            .self_update(&mut states[committer])
            .unwrap();
        group.others[committer]
            .device
            .merge_pending_commit(&mut states[committer])
            .unwrap();
        for (index, state) in states.iter_mut().enumerate() {
            if index != committer {
                group.others[index]
                    .device
                    .process_commit(state, &commit)
                    .unwrap();
            }
        }
        group
            .creator
            .device
            .process_commit(&mut group.creator_group, &commit)
            .unwrap();
        group
            .observer
            .device
            .process_commit(&mut group.observer_group, &commit)
            .unwrap();
    }
}

fn median(mut values: Vec<Duration>) -> Duration {
    values.sort();
    values[values.len() / 2]
}

fn ms(value: Duration) -> String {
    format!("{:.2}", value.as_secs_f64() * 1000.0)
}

struct Report {
    leaves: usize,
    bulk_welcome_bytes: usize,
    joins: Vec<JoinSample>,
    cold_first_remove: RemoveSample,
    cold_removes: Vec<RemoveSample>,
    warm_remove: Option<RemoveSample>,
}

fn measure(leaves: usize, rounds: usize, warm: bool) -> Report {
    let (mut group, _) = build_group(leaves);
    let joiners = (0..rounds)
        .map(|index| Member::new("joiner", index))
        .collect::<Vec<_>>();
    let mut joins = Vec::with_capacity(rounds);
    for joiner in &joiners {
        let (sample, mut joined) = join_one(&mut group, joiner);
        // The new device really holds the group: it reads the next message.
        let hello = group
            .creator
            .device
            .encrypt(&mut group.creator_group, b"synthetic")
            .unwrap();
        assert_eq!(
            joiner
                .device
                .decrypt(
                    &mut joined,
                    &hello,
                    &group.creator.account,
                    &group.creator.device_id
                )
                .unwrap(),
            b"synthetic"
        );
        group
            .observer
            .device
            .decrypt(
                &mut group.observer_group,
                &hello,
                &group.creator.account,
                &group.creator.device_id,
            )
            .unwrap();
        joins.push(sample);
    }
    let cold_first_remove = remove_one(&mut group, &joiners[0]);
    let cold_removes = joiners[1..]
        .iter()
        .map(|joiner| remove_one(&mut group, joiner))
        .collect::<Vec<_>>();
    let warm_remove = warm.then(|| {
        // A fresh group of the same size, warmed, then one removal.
        let (mut fresh, welcome) = build_group(leaves);
        warm_tree(&mut fresh, &welcome);
        let leaving = fresh.others.pop().unwrap();
        remove_one(&mut fresh, &leaving)
    });
    Report {
        leaves,
        bulk_welcome_bytes: group.bulk_welcome_bytes,
        joins,
        cold_first_remove,
        cold_removes,
        warm_remove,
    }
}

fn print_header() {
    println!(
        "| leaves | add: stage ms | add: merge ms | welcome: join ms | commit: member ms \
         | commit B | welcome B | bulk welcome B | cold remove 1st: stage ms / member ms / B \
         | cold remove median: stage ms / member ms / B | warm remove: stage ms / member ms / B |"
    );
    println!("|---|---|---|---|---|---|---|---|---|---|---|");
}

fn print_report(report: &Report) {
    let joins = &report.joins;
    let removes = &report.cold_removes;
    let remove_median = if removes.is_empty() {
        "-".to_string()
    } else {
        format!(
            "{} / {} / {}",
            ms(median(removes.iter().map(|r| r.stage).collect())),
            ms(median(removes.iter().map(|r| r.member_process).collect())),
            removes[removes.len() / 2].commit_bytes
        )
    };
    let warm = report.warm_remove.as_ref().map_or("-".to_string(), |r| {
        format!(
            "{} / {} / {}",
            ms(r.stage),
            ms(r.member_process),
            r.commit_bytes
        )
    });
    println!(
        "| {} | {} | {} | {} | {} | {} | {} | {} | {} / {} / {} | {} | {} |",
        report.leaves,
        ms(median(joins.iter().map(|j| j.stage).collect())),
        ms(median(joins.iter().map(|j| j.merge).collect())),
        ms(median(joins.iter().map(|j| j.welcome_process).collect())),
        ms(median(joins.iter().map(|j| j.member_process).collect())),
        joins[joins.len() / 2].commit_bytes,
        joins[joins.len() / 2].welcome_bytes,
        report.bulk_welcome_bytes,
        ms(report.cold_first_remove.stage),
        ms(report.cold_first_remove.member_process),
        report.cold_first_remove.commit_bytes,
        remove_median,
        warm,
    );
}

#[test]
fn join_cost_quick_case_does_real_work() {
    let report = measure(10, 2, true);
    assert_eq!(report.joins.len(), 2);
    // The Welcome carries the ratchet tree, so it is larger than the commit.
    assert!(report.joins[0].welcome_bytes > report.joins[0].commit_bytes);
    assert!(report.cold_first_remove.commit_bytes > 0);
    assert!(report.warm_remove.is_some());
}

#[test]
#[ignore = "measurement: run in release with --ignored --nocapture"]
fn join_cost_by_group_size() {
    print_header();
    for (leaves, rounds, warm) in [
        (10, 7, true),
        (100, 7, true),
        (200, 5, true),
        (1000, 5, false),
    ] {
        print_report(&measure(leaves, rounds, warm));
    }
}

/// A fixed shuffle (xorshift), so every run picks the same members.
fn shuffled(count: usize) -> Vec<usize> {
    let mut order = (0..count).collect::<Vec<_>>();
    let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
    for index in (1..count).rev() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        order.swap(index, (state % (index as u64 + 1)) as usize);
    }
    order
}

/// Stages (and then drops) the removal of one member, so the tree is left
/// as it was. Returns the stage time and the commit size.
fn staged_removal_size(group: &mut Group, leaving: &Member) -> (Duration, usize) {
    let started = Instant::now();
    let staged = group
        .creator
        .device
        .stage_membership_commit(&mut group.creator_group, &[], &[leaving.identity()])
        .unwrap();
    let stage = started.elapsed();
    group
        .creator
        .device
        .clear_pending_commit(&mut group.creator_group)
        .unwrap();
    (stage, staged.commit.len())
}

/// Builds a cold tree of `leaves` devices, then lets members, in a fixed
/// random order, each commit one self-update. At each checkpoint it stages
/// one removal and prints its size, and the size of the last self-update.
fn removal_after_self_updates(leaves: usize, checkpoints: &[usize]) {
    let (mut group, welcome) = build_group(leaves);
    let max_updates = *checkpoints.iter().max().unwrap();
    // The last member never updates; it is the one whose removal is staged.
    let leaving = group.others.pop().unwrap();
    let order = shuffled(group.others.len());
    let updaters = order[..max_updates].to_vec();
    let mut states = updaters
        .iter()
        .map(|&index| {
            group.others[index]
                .device
                .join_group(GROUP_ID, &welcome)
                .unwrap()
        })
        .collect::<Vec<_>>();
    let mut done = 0;
    let mut last_update_bytes = 0;
    for &checkpoint in checkpoints {
        while done < checkpoint {
            let member = &group.others[updaters[done]];
            let commit = member.device.self_update(&mut states[done]).unwrap();
            member
                .device
                .merge_pending_commit(&mut states[done])
                .unwrap();
            last_update_bytes = commit.len();
            for (other, state) in states.iter_mut().enumerate() {
                if other != done {
                    group.others[updaters[other]]
                        .device
                        .process_commit(state, &commit)
                        .unwrap();
                }
            }
            group
                .creator
                .device
                .process_commit(&mut group.creator_group, &commit)
                .unwrap();
            done += 1;
        }
        let (stage, bytes) = staged_removal_size(&mut group, &leaving);
        let update = if checkpoint == 0 {
            "-".to_string()
        } else {
            last_update_bytes.to_string()
        };
        println!(
            "| {leaves} | {checkpoint} | {} | {bytes} | {} | {update} |",
            ms(stage),
            bytes * (leaves - 1),
        );
    }
}

#[test]
fn removal_cost_quick_case_shrinks_after_self_updates() {
    let (mut group, welcome) = build_group(16);
    let leaving = group.others.pop().unwrap();
    let (_, cold) = staged_removal_size(&mut group, &leaving);
    let mut state = group.others[0]
        .device
        .join_group(GROUP_ID, &welcome)
        .unwrap();
    let commit = group.others[0].device.self_update(&mut state).unwrap();
    group.others[0]
        .device
        .merge_pending_commit(&mut state)
        .unwrap();
    group
        .creator
        .device
        .process_commit(&mut group.creator_group, &commit)
        .unwrap();
    let (_, after) = staged_removal_size(&mut group, &leaving);
    assert!(cold > 0 && after > 0);
    assert!(after <= cold);
}

#[test]
#[ignore = "measurement: run in release with --ignored --nocapture"]
fn removal_cost_after_self_updates() {
    println!(
        "| leaves | self-updates done | removal stage ms | removal commit B \
         | removal egress B (commit x other devices) | last self-update commit B |"
    );
    println!("|---|---|---|---|---|---|");
    removal_after_self_updates(200, &[0, 1, 10, 50, 100]);
    removal_after_self_updates(1000, &[0, 1, 10, 50, 100]);
}
