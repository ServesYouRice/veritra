use private_messenger_crypto::mls::MlsDevice;
use std::{fs, path::Path};

fn main() {
    let path = Path::new("tests/fixtures/state-v2");
    fs::create_dir_all(path).unwrap();
    let source = MlsDevice::new(b"acct_fixture", b"dev_old").unwrap();
    let peer = MlsDevice::new(b"acct_peer", b"dev_peer").unwrap();
    let mut source_group = source.create_group(b"conv_fixture").unwrap();
    let add = source.add_member(&mut source_group, &peer.create_key_package().unwrap(), b"acct_peer", b"dev_peer").unwrap();
    source.merge_pending_commit(&mut source_group).unwrap();
    let mut peer_group = peer.join_group(b"conv_fixture", &add.welcome).unwrap();
    let first = source.encrypt(&mut source_group, b"synthetic-before-upgrade").unwrap();
    peer.decrypt(&mut peer_group, &first, b"acct_fixture", b"dev_old").unwrap();
    let source_state = source.seal_state(&[0x71; 32], 41).unwrap();
    assert_eq!(&source_state[8..10], &2u16.to_be_bytes());
    let continuation = peer.encrypt(&mut peer_group, b"synthetic-after-upgrade").unwrap();
    let peer_state = peer.seal_state(&[0x72; 32], 42).unwrap();
    assert_eq!(&peer_state[8..10], &2u16.to_be_bytes());
    fs::write(path.join("source.bin"), source_state).unwrap();
    fs::write(path.join("peer.bin"), peer_state).unwrap();
    fs::write(path.join("peer-next.bin"), continuation).unwrap();
    fs::write(path.join("source-public.bin"), source.signing_public_key()).unwrap();
}
