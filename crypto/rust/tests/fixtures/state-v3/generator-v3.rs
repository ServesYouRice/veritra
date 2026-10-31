// Archived generator for the genuine format-3 fixture. It ran once as an
// ignored in-crate test (transfers are crate-private) from
// `crypto/rust/src/mls/state.rs` on top of commit 5102363, before the D70
// S1 storage split, and was then removed from the crate. Do not regenerate
// these files with a later encoder: the test's purpose is an independent
// input.
//
// Historic run: VERITRA_WRITE_V3_FIXTURE=1 cargo test --locked --lib \
//   mls::state::fixture_v3::generate -- --ignored
#[test]
#[ignore]
fn generate() {
    use super::super::{
        link_v3::LinkContext,
        transfer::{Stage, TransferId},
        MemberAdd, MemberIdentity, MlsDevice,
    };
    use std::{fs, path::Path};
    if std::env::var_os("VERITRA_WRITE_V3_FIXTURE").is_none() {
        return;
    }
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/state-v3");
    fs::create_dir_all(&dir).unwrap();
    let source = MlsDevice::new(b"acct_fixture3", b"dev_src").unwrap();
    let peer = MlsDevice::new(b"acct_peer3", b"dev_peer").unwrap();
    let remover = MlsDevice::new(b"acct_q3", b"dev_q").unwrap();

    // conv_alpha: created by source, peer joins, one message each way, then
    // source stages a self-update that is never merged before sealing.
    let mut alpha = source.create_group(b"conv_alpha").unwrap();
    let staged_add = source
        .stage_membership_commit(
            &mut alpha,
            &[MemberAdd {
                key_package: &peer.create_key_package().unwrap(),
                account_id: b"acct_peer3",
                device_id: b"dev_peer",
            }],
            &[],
        )
        .unwrap();
    source.merge_pending_commit(&mut alpha).unwrap();
    let mut peer_alpha = peer
        .join_group(b"conv_alpha", &staged_add.welcome)
        .unwrap();
    let hello = source.encrypt(&mut alpha, b"synthetic-alpha-1").unwrap();
    peer.decrypt(&mut peer_alpha, &hello, b"acct_fixture3", b"dev_src")
        .unwrap();
    let reply = peer.encrypt(&mut peer_alpha, b"synthetic-alpha-2").unwrap();
    source
        .decrypt(&mut alpha, &reply, b"acct_peer3", b"dev_peer")
        .unwrap();

    // conv_beta: created by peer, source joins from a key package.
    let mut peer_beta = peer.create_group(b"conv_beta").unwrap();
    let add = peer
        .add_member(
            &mut peer_beta,
            &source.create_key_package().unwrap(),
            b"acct_fixture3",
            b"dev_src",
        )
        .unwrap();
    peer.merge_pending_commit(&mut peer_beta).unwrap();
    let mut beta = source.join_group(b"conv_beta", &add.welcome).unwrap();
    let beta_hello = source.encrypt(&mut beta, b"synthetic-beta-1").unwrap();
    peer.decrypt(&mut peer_beta, &beta_hello, b"acct_fixture3", b"dev_src")
        .unwrap();

    // conv_gamma: source joins, then is removed and applies its removal.
    let mut q_gamma = remover.create_group(b"conv_gamma").unwrap();
    let add = remover
        .add_member(
            &mut q_gamma,
            &source.create_key_package().unwrap(),
            b"acct_fixture3",
            b"dev_src",
        )
        .unwrap();
    remover.merge_pending_commit(&mut q_gamma).unwrap();
    let mut gamma = source.join_group(b"conv_gamma", &add.welcome).unwrap();
    let removal = remover
        .stage_membership_commit(
            &mut q_gamma,
            &[],
            &[MemberIdentity {
                account_id: b"acct_fixture3",
                device_id: b"dev_src",
            }],
        )
        .unwrap();
    remover.merge_pending_commit(&mut q_gamma).unwrap();
    source.process_commit(&mut gamma, &removal.commit).unwrap();
    assert!(!gamma.is_active());

    // Two unclaimed key packages.
    let unclaimed_one = source.create_key_package().unwrap();
    let unclaimed_two = source.create_key_package().unwrap();

    // Staged, unmerged self-update in conv_alpha.
    let staged_update = source.stage_self_update(&mut alpha).unwrap();
    assert!(source.has_pending_commit(&alpha));

    // K2 transfers: one outgoing (source approved) and one incoming.
    let mut source = source;
    let mut new_device = MlsDevice::new(b"acct_fixture3", b"dev_new").unwrap();
    let mut outgoing = LinkContext {
        origin: b"https://fixture.test".to_vec(),
        link_id: b"link_out".to_vec(),
        account_id: b"acct_fixture3".to_vec(),
        nonce: [3; 32],
        source_device_id: b"dev_src".to_vec(),
        source_signing_key: source.signing_public_key().try_into().unwrap(),
        recipient_device_id: b"dev_new".to_vec(),
        recipient_signing_key: new_device.signing_public_key().try_into().unwrap(),
        transfer_public_key: [0; 32],
    };
    let (public, verification) = new_device
        .begin_history_receive(outgoing.clone(), &[9; 16], 2_000, 1_000)
        .unwrap();
    outgoing.transfer_public_key = public;
    source
        .accept_history_claim(
            outgoing.clone(),
            &[9; 16],
            2_000,
            1_000,
            &verification.transcript_hash,
            &verification.claim_tag,
        )
        .unwrap();
    let out_id = TransferId::new(&outgoing.origin, &outgoing.link_id);
    source
        .prepare_history_approval(&out_id, verification.sas.as_bytes(), 1_050)
        .unwrap();
    source
        .approve_history_transfer(&out_id, &verification.approval_tag, 1_100, 1_100)
        .unwrap();
    assert!(source.pending_transfers[&out_id].stage == Stage::Approved);
    let old_device = MlsDevice::new(b"acct_fixture3", b"dev_old2").unwrap();
    let incoming = LinkContext {
        origin: b"https://fixture.test".to_vec(),
        link_id: b"link_in".to_vec(),
        account_id: b"acct_fixture3".to_vec(),
        nonce: [4; 32],
        source_device_id: b"dev_old2".to_vec(),
        source_signing_key: old_device.signing_public_key().try_into().unwrap(),
        recipient_device_id: b"dev_src".to_vec(),
        recipient_signing_key: source.signing_public_key().try_into().unwrap(),
        transfer_public_key: [0; 32],
    };
    source
        .begin_history_receive(incoming, &[8; 16], 2_000, 1_000)
        .unwrap();
    assert_eq!(source.pending_transfers.len(), 2);

    let source_state = source.seal_state(&[0x73; 32], 51).unwrap();
    assert_eq!(&source_state[8..10], &3u16.to_be_bytes());
    // Peer continuation in conv_beta, captured after the peer seals.
    let peer_next = peer
        .encrypt(&mut peer_beta, b"synthetic-beta-after-upgrade")
        .unwrap();
    let peer_state = peer.seal_state(&[0x74; 32], 52).unwrap();
    assert_eq!(&peer_state[8..10], &3u16.to_be_bytes());
    fs::write(dir.join("source.bin"), source_state).unwrap();
    fs::write(dir.join("source-public.bin"), source.signing_public_key()).unwrap();
    fs::write(dir.join("peer.bin"), peer_state).unwrap();
    fs::write(dir.join("peer-next.bin"), peer_next).unwrap();
    fs::write(dir.join("staged-update.bin"), staged_update.commit).unwrap();
    fs::write(dir.join("unclaimed-1.bin"), unclaimed_one).unwrap();
    fs::write(dir.join("unclaimed-2.bin"), unclaimed_two).unwrap();
    let _ = peer_alpha;
}
