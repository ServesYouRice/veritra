use super::*;
use crate::mls::{MemberAdd, MemberIdentity, MlsDevice};
use openmls::prelude::{KeyPackageIn, MlsMessageBodyIn, MlsMessageIn, ProtocolVersion, WireFormat};
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::OpenMlsProvider as _;
use tls_codec::Deserialize as _;

const VECTOR: &str = include_str!("../../../testing/vectors/l2-padding-v1.json");

fn vector() -> serde_json::Value {
    serde_json::from_str(VECTOR).unwrap()
}

#[test]
fn bucket_edges() {
    assert_eq!(bucket(0), Some(256));
    assert_eq!(bucket(1), Some(256));
    assert_eq!(bucket(255), Some(256));
    assert_eq!(bucket(256), Some(256));
    assert_eq!(bucket(257), Some(512));
    assert_eq!(bucket(4095), Some(4096));
    assert_eq!(bucket(4096), Some(4096));
    assert_eq!(bucket(4097), Some(8192));
    assert_eq!(bucket(8192), Some(8192));
    assert_eq!(bucket(8193), Some(16384));
    assert_eq!(bucket(MAX_PADDED), Some(MAX_PADDED));
    assert_eq!(bucket(MAX_PADDED + 1), None);
    assert_eq!(bucket(usize::MAX), None);
}

#[test]
fn shared_vector_matches_the_rule() {
    let vector = vector();
    assert_eq!(vector["pad_extension_type"], PAD_EXTENSION_TYPE);
    assert_eq!(vector["block"], BLOCK);
    assert_eq!(vector["linear_limit"], LINEAR_LIMIT);
    assert_eq!(vector["max_padded"], MAX_PADDED);
    let cases = vector["buckets"].as_array().unwrap();
    assert!(cases.len() >= 10);
    for case in cases {
        let length = case["length"].as_u64().unwrap() as usize;
        let expected = case["padded"].as_u64().map(|value| value as usize);
        assert_eq!(bucket(length), expected, "length {length}");
    }
}

#[test]
fn key_package_size_formula_reaches_every_bucket() {
    // A bare package of 300..5000 bytes always lands exactly on a bucket.
    for bare in 64..6000 {
        let pad = key_package_pad(bare).unwrap();
        let size = key_package_size(bare, pad);
        assert_eq!(bucket(size), Some(size), "bare {bare}");
        assert!(size >= key_package_size(bare, 0));
    }
}

fn device(account: &str, device: &str) -> MlsDevice {
    MlsDevice::new(account.as_bytes(), device.as_bytes()).unwrap()
}

#[test]
fn key_packages_are_padded_and_valid() {
    // Identity lengths of a few bytes to the 128-byte maximum.
    for (account, device_id) in [
        ("a", "d"),
        ("acct_0123456789", "dev_0123456789"),
        (&"a".repeat(128)[..], &"d".repeat(128)[..]),
    ] {
        let alice = device(account, device_id);
        let bytes = alice.create_key_package().unwrap();
        assert_eq!(bucket(bytes.len()), Some(bytes.len()), "{account}");
        let package = KeyPackageIn::tls_deserialize_exact(&bytes)
            .unwrap()
            .validate(
                OpenMlsRustCrypto::default().crypto(),
                ProtocolVersion::Mls10,
            )
            .unwrap();
        let pads: Vec<_> = package
            .extensions()
            .iter()
            .filter(|extension| matches!(extension, Extension::Unknown(PAD_EXTENSION_TYPE, _)))
            .collect();
        assert_eq!(pads.len(), 1);
        assert!(!malformed_pad(pads[0]));
    }
}

#[test]
fn malformed_pads_are_recognised() {
    assert!(!malformed_pad(&pad_extension(0)));
    assert!(!malformed_pad(&pad_extension(300)));
    let nonzero = Extension::Unknown(PAD_EXTENSION_TYPE, UnknownExtension(vec![0, 1, 0]));
    assert!(malformed_pad(&nonzero));
    let other = Extension::Unknown(0xF0C4, UnknownExtension(vec![1, 2, 3]));
    assert!(!malformed_pad(&other));
}

struct Member {
    device: MlsDevice,
    account: String,
    device_id: String,
}

fn member(index: usize) -> Member {
    let account = format!("acct_l2_{index}");
    let device_id = format!("dev_l2_{index}");
    Member {
        device: device(&account, &device_id),
        account,
        device_id,
    }
}

fn welcome_len(welcome: &[u8]) -> usize {
    let message = MlsMessageIn::tls_deserialize_exact(welcome).unwrap();
    assert!(matches!(message.extract(), MlsMessageBodyIn::Welcome(_)));
    welcome.len()
}

/// Adds `members` to a group of `alice` in one staged commit; returns the
/// Welcome and the commit.
fn add_all(
    alice: &MlsDevice,
    group: &mut openmls::prelude::MlsGroup,
    members: &[Member],
) -> (Vec<u8>, Vec<u8>) {
    let packages: Vec<_> = members
        .iter()
        .map(|member| member.device.create_key_package().unwrap())
        .collect();
    let adds: Vec<_> = members
        .iter()
        .zip(&packages)
        .map(|(member, package)| MemberAdd {
            key_package: package,
            account_id: member.account.as_bytes(),
            device_id: member.device_id.as_bytes(),
        })
        .collect();
    let staged = alice.stage_membership_commit(group, &adds, &[]).unwrap();
    alice.merge_pending_commit(group).unwrap();
    (staged.welcome, staged.commit)
}

#[test]
fn welcomes_are_padded_and_joinable_at_many_sizes() {
    let alice = device("acct_l2_alice", "dev_l2_alice");
    let mut group = alice.create_group(b"conv_l2_pad").unwrap();
    let mut joined: Vec<(Member, openmls::prelude::MlsGroup)> = Vec::new();
    let mut sizes = Vec::new();
    // Group sizes 2..=42, several adds at once at the larger sizes, cover
    // linear buckets and the step into powers of two.
    let mut next = 0;
    for batch in [1, 1, 1, 2, 3, 5, 8, 12, 8] {
        let members: Vec<_> = (next..next + batch).map(member).collect();
        next += batch;
        let (welcome, commit) = add_all(&alice, &mut group, &members);
        let size = welcome_len(&welcome);
        assert_eq!(bucket(size), Some(size), "welcome of {size} bytes");
        sizes.push(size);
        // The commit is a PrivateMessage padded by MLS.
        let parsed = MlsMessageIn::tls_deserialize_exact(&commit).unwrap();
        assert_eq!(parsed.wire_format(), WireFormat::PrivateMessage);
        for (existing, theirs) in &mut joined {
            existing.device.process_commit(theirs, &commit).unwrap();
        }
        for new in members {
            let theirs = new.device.join_group(b"conv_l2_pad", &welcome).unwrap();
            joined.push((new, theirs));
        }
    }
    assert!(sizes.iter().any(|&size| size > LINEAR_LIMIT), "{sizes:?}");
    // A message still flows after every padded join.
    let ciphertext = alice.encrypt(&mut group, b"hello").unwrap();
    for (member, theirs) in &mut joined {
        let (plaintext, account, device_id) =
            member.device.decrypt_sealed(theirs, &ciphertext).unwrap();
        assert_eq!(plaintext, b"hello");
        assert_eq!(account, b"acct_l2_alice");
        assert_eq!(device_id, b"dev_l2_alice");
    }
}

#[test]
fn a_removal_commit_is_a_private_message() {
    let alice = device("acct_l2_alice", "dev_l2_alice");
    let mut group = alice.create_group(b"conv_l2_rm").unwrap();
    let bob = member(1);
    add_all(&alice, &mut group, std::slice::from_ref(&bob));
    let staged = alice
        .stage_membership_commit(
            &mut group,
            &[],
            &[MemberIdentity {
                account_id: bob.account.as_bytes(),
                device_id: bob.device_id.as_bytes(),
            }],
        )
        .unwrap();
    assert!(staged.welcome.is_empty());
    let commit = MlsMessageIn::tls_deserialize_exact(&staged.commit).unwrap();
    assert_eq!(commit.wire_format(), WireFormat::PrivateMessage);
}

#[test]
fn sealed_decrypt_returns_the_mls_sender_whatever_the_transport_says() {
    let alice = device("acct_l2_alice", "dev_l2_alice");
    let mut group = alice.create_group(b"conv_l2_sealed").unwrap();
    let members = vec![member(3), member(4)];
    let (welcome, _) = add_all(&alice, &mut group, &members);
    let mut groups: Vec<_> = members
        .iter()
        .map(|joiner| {
            joiner
                .device
                .join_group(b"conv_l2_sealed", &welcome)
                .unwrap()
        })
        .collect();
    let ciphertext = alice.encrypt(&mut group, b"from alice").unwrap();
    let (plaintext, account, device_id) = members[0]
        .device
        .decrypt_sealed(&mut groups[0], &ciphertext)
        .unwrap();
    assert_eq!(plaintext, b"from alice");
    assert_eq!(account, b"acct_l2_alice");
    assert_eq!(device_id, b"dev_l2_alice");
    // Bob's message: the sealed path names Bob, never anyone the server
    // might claim.
    let from_bob = members[0]
        .device
        .encrypt(&mut groups[0], b"from bob")
        .unwrap();
    let (_, account, device_id) = members[1]
        .device
        .decrypt_sealed(&mut groups[1], &from_bob)
        .unwrap();
    assert_eq!(account, members[0].account.as_bytes());
    assert_eq!(device_id, members[0].device_id.as_bytes());
    // The identified path still refuses a forged outer sender (D25).
    let ciphertext = alice.encrypt(&mut group, b"again").unwrap();
    assert_eq!(
        members[1].device.decrypt(
            &mut groups[1],
            &ciphertext,
            members[0].account.as_bytes(),
            members[0].device_id.as_bytes(),
        ),
        Err(crate::mls::MlsError::SenderMismatch)
    );
    // Garbage is refused.
    assert!(members[0]
        .device
        .decrypt_sealed(&mut groups[0], b"not mls")
        .is_err());
}

/// A key package for `account`/`device_id` with the given extensions, built
/// outside `MlsDevice` the way another client could.
fn foreign_key_package(account: &str, device_id: &str, pad: Option<Extension>) -> Vec<u8> {
    use openmls::prelude::{
        BasicCredential, Capabilities, Ciphersuite, CredentialWithKey, ExtensionType, Extensions,
        KeyPackage,
    };
    use openmls_basic_credential::SignatureKeyPair;
    use tls_codec::Serialize as _;
    let suite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
    let mut identity = vec![1u8];
    identity.extend_from_slice(&(account.len() as u16).to_be_bytes());
    identity.extend_from_slice(account.as_bytes());
    identity.extend_from_slice(&(device_id.len() as u16).to_be_bytes());
    identity.extend_from_slice(device_id.as_bytes());
    let provider = OpenMlsRustCrypto::default();
    let signer = SignatureKeyPair::new(suite.signature_algorithm()).unwrap();
    let credential = CredentialWithKey {
        credential: BasicCredential::new(identity).into(),
        signature_key: signer.public().into(),
    };
    let capabilities = Capabilities::new(
        None,
        None,
        Some(&[
            ExtensionType::Unknown(0xF0C4),
            ExtensionType::Unknown(PAD_EXTENSION_TYPE),
        ]),
        None,
        None,
    );
    let mut builder = KeyPackage::builder().leaf_node_capabilities(capabilities);
    if let Some(pad) = pad {
        builder = builder.key_package_extensions(Extensions::single(pad).unwrap());
    }
    builder
        .build(suite, &provider, &signer, credential)
        .unwrap()
        .key_package()
        .tls_serialize_detached()
        .unwrap()
}

#[test]
fn unpadded_packages_are_still_added_and_bad_pads_refused() {
    let alice = device("acct_l2_alice", "dev_l2_alice");
    let mut group = alice.create_group(b"conv_l2_bad").unwrap();
    // An ABI 22 package (no pad) is still accepted.
    let old = foreign_key_package("acct_old", "dev_old", None);
    let add = MemberAdd {
        key_package: &old,
        account_id: b"acct_old",
        device_id: b"dev_old",
    };
    let staged = alice
        .stage_membership_commit(&mut group, &[add], &[])
        .unwrap();
    assert_eq!(bucket(staged.welcome.len()), Some(staged.welcome.len()));
    alice.clear_pending_commit(&mut group).unwrap();
    // A pad with non-zero data is refused before anything is staged.
    let bad = foreign_key_package(
        "acct_bad",
        "dev_bad",
        Some(Extension::Unknown(
            PAD_EXTENSION_TYPE,
            UnknownExtension(vec![7; 40]),
        )),
    );
    let add = MemberAdd {
        key_package: &bad,
        account_id: b"acct_bad",
        device_id: b"dev_bad",
    };
    assert_eq!(
        alice.stage_membership_commit(&mut group, &[add], &[]).err(),
        Some(crate::mls::MlsError::InvalidKeyPackage)
    );
    assert!(!alice.has_pending_commit(&group));
}

/// Prints a fresh padded key package for `key_package_hex` in the vector.
#[test]
#[ignore]
fn print_vector_key_package() {
    let bytes = device("acct_vector", "dev_vector")
        .create_key_package()
        .unwrap();
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    println!("KP={hex}");
}

#[test]
fn vector_key_package_is_padded_and_valid() {
    let vector = vector();
    let hex = vector["key_package_hex"].as_str().unwrap();
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&hex[index..index + 2], 16).unwrap())
        .collect();
    assert_eq!(bucket(bytes.len()), Some(bytes.len()));
    // Structure only: the package's lifetime expires, so it is not
    // validated here (fresh packages are, above). The pad sits right after
    // the leaf node: type 0xF0A2, then its zero data, then the signature.
    KeyPackageIn::tls_deserialize_exact(&bytes).unwrap();
    let marker = bytes
        .windows(2)
        .rposition(|pair| pair == PAD_EXTENSION_TYPE.to_be_bytes())
        .unwrap();
    assert!(bytes[marker + 4..bytes.len() - 66]
        .iter()
        .all(|&byte| byte == 0));
}
