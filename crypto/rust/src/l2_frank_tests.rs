use super::*;
use crate::mls::{MemberAdd, MlsDevice};

const VECTOR: &str = include_str!("../../../testing/vectors/l2-frank-dv-v1.json");

fn vector() -> serde_json::Value {
    serde_json::from_str(VECTOR).unwrap()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
        .collect()
}

fn s(value: &serde_json::Value, key: &str) -> String {
    value[key].as_str().unwrap().to_string()
}

fn secret(byte: u8) -> StaticSecret {
    StaticSecret::from([byte; 32])
}

fn random_secret() -> StaticSecret {
    generate_secret().unwrap()
}

const CONV: &[u8] = b"conv_dv_vector";
const ACCOUNT: &[u8] = b"acct_dv_sender";
const DEVICE: &[u8] = b"dev_dv_sender";

fn commit() -> Vec<u8> {
    unhex("e84e3e81d8ac625060a472b2c311b19fc56e8472c80ffa0b304e63930158980a")
}

/// The vector's owner report seeds.
const OWNER_SEEDS: [u8; 3] = [0x31, 0x32, 0x33];

fn owner_public(seed_byte: u8) -> [u8; 32] {
    crate::report::public_key(&[seed_byte; 32]).unwrap()
}

/// The X25519 points of order 1, 2, 4 and 8 and their non-canonical
/// spellings (bit 255 set, or u ≥ p). Every one is refused as a key.
fn refused_keys() -> Vec<[u8; 32]> {
    let mut out = Vec::new();
    for point in crate::report::LOW_ORDER_POINTS_FOR_TESTS {
        out.push(point);
        let mut high = point;
        high[31] |= 0x80;
        out.push(high);
    }
    out
}

/// Non-canonical spellings of ordinary points: `u + p` (still below 2^255)
/// and `u` with bit 255 set. X25519 itself reduces them to the canonical
/// point; this module refuses them so one key has one encoding.
fn non_canonical_of(u: &[u8; 32]) -> Vec<[u8; 32]> {
    let mut high = *u;
    high[31] |= 0x80;
    let mut plus_p = [0u8; 32];
    let mut carry = 0u16;
    for i in 0..32 {
        let sum = u16::from(u[i]) + u16::from(P[i]) + carry;
        plus_p[i] = sum as u8;
        carry = sum >> 8;
    }
    let mut out = vec![high];
    if carry == 0 && plus_p[31] & 0x80 == 0 {
        out.push(plus_p);
    }
    out
}

#[test]
fn shared_vector_designation_and_verification() {
    let vector = vector();
    assert_eq!(s(&vector, "label"), "veritra-frank-dv-v1");
    let sender = &vector["sender"];
    let f_s = secret_from_bytes(&unhex(&s(sender, "frank_secret"))).unwrap();
    let f_pub = public_key(&f_s);
    assert_eq!(hex(&f_pub), s(sender, "frank_public"));
    let conversation = s(&vector, "conversation_id");
    let account = s(sender, "account_id");
    let device = s(sender, "device_id");
    let commit = unhex(&s(&vector, "commit"));
    for owner in vector["owners"].as_array().unwrap() {
        let seed = unhex(&s(owner, "report_seed"));
        let report_public = crate::report::public_key(&seed).unwrap();
        assert_eq!(hex(&report_public), s(owner, "report_public"));
        let owner_secret = crate::report::x25519_secret(&seed).unwrap();
        assert_eq!(hex(owner_secret.as_bytes()), s(owner, "x25519_secret"));
        assert_eq!(hex(&kid(&report_public).unwrap()), s(owner, "kid"));
        // Z both ways.
        let z = shared(&f_s, &report_public).unwrap();
        assert_eq!(hex(&z), s(owner, "z"));
        assert_eq!(shared(&owner_secret, &f_pub).unwrap(), z);
        let input = tag_input(
            conversation.as_bytes(),
            account.as_bytes(),
            device.as_bytes(),
            &kid(&report_public).unwrap(),
            &commit,
        )
        .unwrap();
        assert_eq!(hex(&input), s(owner, "tag_input"));
        let k = tag_key_for_tests(&z, &f_pub, &report_public);
        assert_eq!(hex(&k), s(owner, "k"));
        let t = tag(&z, &f_pub, &report_public, &input).unwrap();
        assert_eq!(hex(&t), s(owner, "tag"));
    }
    for case in vector["designations"].as_array().unwrap() {
        let owners: Vec<u8> = case["owner_public_keys"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|key| unhex(key.as_str().unwrap()))
            .collect();
        let d = designate(
            &f_s,
            &owners,
            conversation.as_bytes(),
            account.as_bytes(),
            device.as_bytes(),
            &commit,
        )
        .unwrap();
        assert_eq!(hex(&d), s(case, "d"));
    }
    for case in vector["verify_cases"].as_array().unwrap() {
        let verdict = verify_with_report_seed(
            &unhex(&s(case, "report_seed")),
            &unhex(&s(case, "sender_frank_public")),
            s(case, "conversation_id").as_bytes(),
            s(case, "account_id").as_bytes(),
            s(case, "device_id").as_bytes(),
            &unhex(&s(case, "commit")),
            &unhex(&s(case, "d")),
        )
        .unwrap();
        assert_eq!(
            verdict as u64,
            case["result"].as_u64().unwrap(),
            "{}",
            s(case, "name")
        );
    }
    for key in vector["refused_public_keys"].as_array().unwrap() {
        let key = unhex(key["key"].as_str().unwrap());
        assert_eq!(check_public(&key), Err(DvError::InvalidInput));
    }
}

/// `K` as the vector records it (the module keeps it inside `tag`).
fn tag_key_for_tests(z: &[u8; 32], f: &[u8; 32], v: &[u8; 32]) -> Vec<u8> {
    let crypto = RustCrypto::default();
    let prk = crypto.hkdf_extract(HashType::Sha2_256, LABEL, z).unwrap();
    let info = [KEY_LABEL, f, v].concat();
    crypto
        .hkdf_expand(HashType::Sha2_256, prk.as_slice(), &info, 32)
        .unwrap()
        .as_slice()
        .to_vec()
}

#[test]
fn dh_agrees_both_ways_for_random_keys() {
    for _ in 0..64 {
        let a = random_secret();
        let b = random_secret();
        let (pa, pb) = (public_key(&a), public_key(&b));
        assert_eq!(shared(&a, &pb).unwrap(), shared(&b, &pa).unwrap());
        // A designation made by a verifies for b's report-style secret.
        let d = designate(&a, &pb, CONV, ACCOUNT, DEVICE, &commit()).unwrap();
        assert_eq!(
            verify(&b, &pa, CONV, ACCOUNT, DEVICE, &commit(), &d).unwrap(),
            DvVerdict::Valid
        );
    }
}

#[test]
fn the_report_secret_matches_the_published_report_key() {
    for _ in 0..16 {
        let seed = crate::report::generate_seed().unwrap();
        let secret = crate::report::x25519_secret(seed.as_slice()).unwrap();
        assert_eq!(
            public_key(&secret),
            crate::report::public_key(seed.as_slice()).unwrap()
        );
    }
}

fn three_owner_designation(sender: &StaticSecret) -> Vec<u8> {
    let owners: Vec<u8> = OWNER_SEEDS.iter().flat_map(|b| owner_public(*b)).collect();
    designate(sender, &owners, CONV, ACCOUNT, DEVICE, &commit()).unwrap()
}

fn check(
    seed_byte: u8,
    sender: &[u8],
    fields: (&[u8], &[u8], &[u8], &[u8]),
    d: &[u8],
) -> DvVerdict {
    verify_with_report_seed(
        &[seed_byte; 32],
        sender,
        fields.0,
        fields.1,
        fields.2,
        fields.3,
        d,
    )
    .unwrap()
}

#[test]
fn every_owner_verifies_and_every_bound_field_matters() {
    let sender = random_secret();
    let f = public_key(&sender);
    let d = three_owner_designation(&sender);
    assert_eq!(d.len(), 3 * ENTRY_BYTES);
    let c = commit();
    for seed in OWNER_SEEDS {
        assert_eq!(
            check(seed, &f, (CONV, ACCOUNT, DEVICE, &c), &d),
            DvVerdict::Valid
        );
        assert_eq!(
            check(seed, &f, (b"conv_other", ACCOUNT, DEVICE, &c), &d),
            DvVerdict::Mismatch
        );
        assert_eq!(
            check(seed, &f, (CONV, b"acct_other", DEVICE, &c), &d),
            DvVerdict::Mismatch
        );
        assert_eq!(
            check(seed, &f, (CONV, ACCOUNT, b"dev_other", &c), &d),
            DvVerdict::Mismatch
        );
        let mut other_commit = c.clone();
        other_commit[31] ^= 1;
        assert_eq!(
            check(seed, &f, (CONV, ACCOUNT, DEVICE, &other_commit), &d),
            DvVerdict::Mismatch
        );
        // Another device's franking key (a framer's, or a rotated one).
        let other = public_key(&random_secret());
        assert_eq!(
            check(seed, &other, (CONV, ACCOUNT, DEVICE, &c), &d),
            DvVerdict::Mismatch
        );
    }
    // An owner whose key is not designated (a new seed after rotation).
    assert_eq!(
        check(0x34, &f, (CONV, ACCOUNT, DEVICE, &c), &d),
        DvVerdict::NotDesignated
    );
}

#[test]
fn a_tampered_entry_never_verifies_for_its_owner() {
    let sender = random_secret();
    let f = public_key(&sender);
    let d = three_owner_designation(&sender);
    let c = commit();
    // Map each entry to its owner by kid.
    for (position, entry) in d.chunks_exact(ENTRY_BYTES).enumerate() {
        let owner = OWNER_SEEDS
            .iter()
            .copied()
            .find(|seed| kid(&owner_public(*seed)).unwrap().as_slice() == &entry[..KID_BYTES])
            .unwrap();
        for byte in KID_BYTES..ENTRY_BYTES {
            let mut tampered = d.clone();
            tampered[position * ENTRY_BYTES + byte] ^= 0x80;
            assert_eq!(
                check(owner, &f, (CONV, ACCOUNT, DEVICE, &c), &tampered),
                DvVerdict::Mismatch
            );
        }
    }
}

#[test]
fn an_entry_moved_under_another_owners_kid_fails() {
    let sender = random_secret();
    let f = public_key(&sender);
    let c = commit();
    let a = owner_public(0x31);
    let b = owner_public(0x32);
    let da = designate(&sender, &a, CONV, ACCOUNT, DEVICE, &c).unwrap();
    let db = designate(&sender, &b, CONV, ACCOUNT, DEVICE, &c).unwrap();
    // A's tag under B's kid.
    let swapped = [&db[..KID_BYTES], &da[KID_BYTES..]].concat();
    assert_eq!(
        check(0x32, &f, (CONV, ACCOUNT, DEVICE, &c), &swapped),
        DvVerdict::Mismatch
    );
    assert_eq!(
        check(0x31, &f, (CONV, ACCOUNT, DEVICE, &c), &swapped),
        DvVerdict::NotDesignated
    );
}

#[test]
fn framing_needs_the_victims_secret() {
    // Mallory makes a designation over Alice's identity with her own
    // secret. Checked under Alice's listed key, it fails for every owner.
    let mallory = random_secret();
    let alice = random_secret();
    let d = three_owner_designation(&mallory);
    for seed in OWNER_SEEDS {
        assert_eq!(
            check(
                seed,
                &public_key(&alice),
                (CONV, ACCOUNT, DEVICE, &commit()),
                &d
            ),
            DvVerdict::Mismatch
        );
    }
}

#[test]
fn low_order_and_non_canonical_keys_are_refused() {
    let sender = random_secret();
    let good = owner_public(0x31);
    for key in refused_keys()
        .into_iter()
        .chain(non_canonical_of(&good))
        .chain(non_canonical_of(&public_key(&sender)))
    {
        assert_eq!(
            check_public(&key),
            Err(DvError::InvalidInput),
            "{}",
            hex(&key)
        );
        assert_eq!(kid(&key), Err(DvError::InvalidInput));
        // Skipped as a verifier key, alone or among good ones.
        assert!(designate(&sender, &key, CONV, ACCOUNT, DEVICE, &commit())
            .unwrap()
            .is_empty());
        let both = [key.as_slice(), good.as_slice()].concat();
        assert_eq!(
            designate(&sender, &both, CONV, ACCOUNT, DEVICE, &commit()).unwrap(),
            designate(&sender, &good, CONV, ACCOUNT, DEVICE, &commit()).unwrap()
        );
        // As a claimed sender key it never verifies.
        let d = designate(&sender, &good, CONV, ACCOUNT, DEVICE, &commit()).unwrap();
        assert_eq!(
            check(0x31, &key, (CONV, ACCOUNT, DEVICE, &commit()), &d),
            DvVerdict::Mismatch
        );
    }
    // The non-canonical spellings are the same point to X25519 itself:
    // the refusal is this module's policy, not the curve's.
    let other = random_secret();
    let canonical = public_key(&other);
    for spelling in non_canonical_of(&canonical) {
        let z = sender.diffie_hellman(&PublicKey::from(spelling));
        assert_eq!(z.to_bytes(), shared(&sender, &canonical).unwrap());
    }
    // Low-order points force an all-zero Z.
    for point in crate::report::LOW_ORDER_POINTS_FOR_TESTS {
        assert!(!sender
            .diffie_hellman(&PublicKey::from(point))
            .was_contributory());
    }
}

#[test]
fn lengths_and_shapes_are_checked() {
    let sender = random_secret();
    let good = owner_public(0x31);
    let c = commit();
    assert_eq!(
        designate(&sender, &[], CONV, ACCOUNT, DEVICE, &c),
        Err(DvError::InvalidInput)
    );
    assert_eq!(
        designate(&sender, &good[..31], CONV, ACCOUNT, DEVICE, &c),
        Err(DvError::InvalidInput)
    );
    let seventeen: Vec<u8> = (0..17).flat_map(|_| good).collect();
    assert_eq!(
        designate(&sender, &seventeen, CONV, ACCOUNT, DEVICE, &c),
        Err(DvError::InvalidInput)
    );
    // Sixteen copies of one key give one entry.
    let sixteen: Vec<u8> = (0..16).flat_map(|_| good).collect();
    assert_eq!(
        designate(&sender, &sixteen, CONV, ACCOUNT, DEVICE, &c)
            .unwrap()
            .len(),
        ENTRY_BYTES
    );
    assert_eq!(
        designate(&sender, &good, CONV, ACCOUNT, DEVICE, &c[..31]),
        Err(DvError::InvalidInput)
    );
    assert_eq!(
        designate(&sender, &good, b"", ACCOUNT, DEVICE, &c),
        Err(DvError::InvalidInput)
    );
    assert_eq!(
        designate(&sender, &good, CONV, &[b'a'; 129], DEVICE, &c),
        Err(DvError::InvalidInput)
    );
    assert!(designate(&sender, &good, CONV, &[b'a'; 128], DEVICE, &c).is_ok());
    // Malformed designations are a mismatch, never an error or a pass.
    let f = public_key(&sender);
    let d = three_owner_designation(&sender);
    let mut unsorted = d[ENTRY_BYTES..2 * ENTRY_BYTES].to_vec();
    unsorted.extend_from_slice(&d[..ENTRY_BYTES]);
    let duplicate = [&d[..ENTRY_BYTES], &d[..ENTRY_BYTES]].concat();
    let too_many: Vec<u8> = (0..17u8)
        .flat_map(|i| {
            let mut entry = [0u8; ENTRY_BYTES];
            entry[0] = i;
            entry
        })
        .collect();
    for bad in [
        &[][..],
        &d[..ENTRY_BYTES - 1],
        &d[..ENTRY_BYTES + 1],
        &unsorted,
        &duplicate,
        &too_many,
    ] {
        assert_eq!(
            verify_with_report_seed(&[0x31; 32], &f, CONV, ACCOUNT, DEVICE, &c, bad).unwrap(),
            DvVerdict::Mismatch
        );
    }
    assert_eq!(
        verify_with_report_seed(&[0x31; 31], &f, CONV, ACCOUNT, DEVICE, &c, &d),
        Err(DvError::InvalidInput)
    );
}

fn device(account: &str, device: &str) -> MlsDevice {
    MlsDevice::new(account.as_bytes(), device.as_bytes()).unwrap()
}

/// The franking key the tags are made under is the device's own fixed key,
/// the one its L1 entry lists: designate refuses any other listed key, and
/// two devices never share one.
#[test]
fn designate_refuses_a_key_other_than_the_listed_one() {
    let alice = device("acct_dv_alice", "dev_dv_alice");
    let bob = device("acct_dv_bob", "dev_dv_bob");
    let own = alice.l2_frank_public_key();
    assert_ne!(own, bob.l2_frank_public_key());
    let owners = owner_public(0x31);
    assert!(alice
        .l2_frank_designate(CONV, &commit(), &bob.l2_frank_public_key(), &owners)
        .is_err());
    assert!(alice
        .l2_frank_designate(CONV, &commit(), &[0u8; 32], &owners)
        .is_err());
    let d = alice
        .l2_frank_designate(CONV, &commit(), &own, &owners)
        .unwrap();
    assert_eq!(
        check(
            0x31,
            &own,
            (CONV, b"acct_dv_alice", b"dev_dv_alice", &commit()),
            &d
        ),
        DvVerdict::Valid
    );
    // Bound to the device's own identity, never another.
    assert_eq!(
        check(0x31, &own, (CONV, ACCOUNT, DEVICE, &commit()), &d),
        DvVerdict::Mismatch
    );
}

#[test]
fn the_franking_key_survives_seal_and_restore() {
    let mut alice = device("acct_dv_seal", "dev_dv_seal");
    let key = [0x5au8; 32];
    let before = alice.l2_frank_public_key();
    let restored = alice.reload_for_test(&key);
    assert_eq!(restored.l2_frank_public_key(), before);
}

#[test]
fn device_record_sections_parse_strictly() {
    use crate::mls::list_sections_for_tests as sections;
    let frank = sections::encode_frank(&[7u8; 32]);
    let held = sections::encode_held(&[9u8; 32]);
    assert!(matches!(sections::decode(&[]), Ok((false, None))));
    assert!(matches!(sections::decode(&held), Ok((true, None))));
    let (has_held, key) = sections::decode(&frank).unwrap();
    assert!(!has_held);
    assert_eq!(key.unwrap(), public_key(&StaticSecret::from([7u8; 32])));
    let both = [held.clone(), frank.clone()].concat();
    let (has_held, key) = sections::decode(&both).unwrap();
    assert!(has_held && key.is_some());
    // Out of order, trailing bytes, a wrong version or a cut section.
    for bad in [
        [frank.clone(), held.clone()].concat(),
        [frank.clone(), vec![0]].concat(),
        frank[..frank.len() - 1].to_vec(),
        {
            let mut wrong = frank.clone();
            wrong[4] = 2;
            wrong
        },
        b"VFK0".to_vec(),
    ] {
        assert!(sections::decode(&bad).is_err());
    }
}

/// End to end through MLS: Alice's sealed message carries a designation
/// to two owners; the receiver learns the sender from MLS only, and keeps
/// `d`, which it cannot check. Mallory, a member, posts a sealed message
/// whose commitment names Alice: her designation is over her own identity
/// (the only one the device signs for), and under Alice's listed key it
/// fails for every owner.
#[test]
fn sealed_designation_through_mls_and_framing_fails() {
    let alice = device("acct_fs_alice", "dev_fs_alice");
    let bob = device("acct_fs_bob", "dev_fs_bob");
    let mallory = device("acct_fs_mallory", "dev_fs_mallory");
    let conversation = b"conv_fs";
    let mut group = alice.create_group(conversation).unwrap();
    let bob_package = bob.create_key_package().unwrap();
    let mallory_package = mallory.create_key_package().unwrap();
    let staged = alice
        .stage_membership_commit(
            &mut group,
            &[
                MemberAdd {
                    key_package: &bob_package,
                    account_id: b"acct_fs_bob",
                    device_id: b"dev_fs_bob",
                },
                MemberAdd {
                    key_package: &mallory_package,
                    account_id: b"acct_fs_mallory",
                    device_id: b"dev_fs_mallory",
                },
            ],
            &[],
        )
        .unwrap();
    alice.merge_pending_commit(&mut group).unwrap();
    let mut bob_group = bob.join_group(conversation, &staged.welcome).unwrap();
    let mut mallory_group = mallory.join_group(conversation, &staged.welcome).unwrap();
    let owners: Vec<u8> = [0x31u8, 0x32]
        .iter()
        .flat_map(|b| owner_public(*b))
        .collect();
    let c = [0x42u8; 32];

    let d = alice
        .l2_frank_designate(conversation, &c, &alice.l2_frank_public_key(), &owners)
        .unwrap();
    let ciphertext = alice.encrypt(&mut group, &d).unwrap();
    let (plaintext, account, device_id) = bob.decrypt_sealed(&mut bob_group, &ciphertext).unwrap();
    assert_eq!(plaintext, d);
    for seed in [0x31u8, 0x32] {
        assert_eq!(
            check(
                seed,
                &alice.l2_frank_public_key(),
                (conversation, &account, &device_id, &c),
                &plaintext
            ),
            DvVerdict::Valid
        );
    }

    let framed = mallory
        .l2_frank_designate(conversation, &c, &mallory.l2_frank_public_key(), &owners)
        .unwrap();
    let ciphertext = mallory.encrypt(&mut mallory_group, &framed).unwrap();
    let (plaintext, account, _) = bob.decrypt_sealed(&mut bob_group, &ciphertext).unwrap();
    assert_eq!(account, b"acct_fs_mallory");
    for seed in [0x31u8, 0x32] {
        assert_eq!(
            check(
                seed,
                &alice.l2_frank_public_key(),
                (conversation, b"acct_fs_alice", b"dev_fs_alice", &c),
                &plaintext
            ),
            DvVerdict::Mismatch
        );
    }
    // Mallory cannot make a designation for any key but her own listed one.
    assert!(mallory
        .l2_frank_designate(conversation, &c, &alice.l2_frank_public_key(), &owners)
        .is_err());
}

/// No exported function hands out a franking or report X25519 secret:
/// every function that returns or exposes one is crate-internal.
#[test]
fn no_public_function_returns_a_secret() {
    for (name, source) in [
        ("l2_frank.rs", include_str!("l2_frank.rs")),
        ("report.rs", include_str!("report.rs")),
        ("mls.rs", include_str!("mls.rs")),
    ] {
        for line in source.lines() {
            let line = line.trim_start();
            if line.starts_with("pub fn") || line.starts_with("pub unsafe") {
                // Taking a secret is fine (the owner's check takes its own);
                // returning one is not.
                let returns = line.split("->").nth(1).unwrap_or("");
                assert!(
                    !returns.contains("StaticSecret")
                        && !returns.contains("SharedSecret")
                        && !line.contains("frank_secret"),
                    "{name}: {line}"
                );
            }
        }
    }
    let ffi = include_str!("ffi.rs");
    assert!(!ffi.contains("frank_secret_bytes"));
    assert!(!ffi.contains("x25519_secret"));
}

/// Writes `testing/vectors/l2-frank-dv-v1.json` (run once with --ignored;
/// the committed file is what Rust, Go and Dart check).
#[test]
#[ignore]
fn generate_vector() {
    let sender_bytes = [0x21u8; 32];
    let f_s = secret_from_bytes(&sender_bytes).unwrap();
    let f_pub = public_key(&f_s);
    let (conversation, account, device) = ("conv_dv_vector", "acct_dv_sender", "dev_dv_sender");
    let c = commit();
    let mut owners = Vec::new();
    for seed_byte in OWNER_SEEDS {
        let seed = [seed_byte; 32];
        let report_public = crate::report::public_key(&seed).unwrap();
        let owner_secret = crate::report::x25519_secret(&seed).unwrap();
        let id = kid(&report_public).unwrap();
        let z = shared(&f_s, &report_public).unwrap();
        let input = tag_input(
            conversation.as_bytes(),
            account.as_bytes(),
            device.as_bytes(),
            &id,
            &c,
        )
        .unwrap();
        owners.push(serde_json::json!({
            "report_seed": hex(&seed),
            "x25519_secret": hex(owner_secret.as_bytes()),
            "report_public": hex(&report_public),
            "kid": hex(&id),
            "z": hex(&z),
            "k": hex(&tag_key_for_tests(&z, &f_pub, &report_public)),
            "tag_input": hex(&input),
            "tag": hex(&tag(&z, &f_pub, &report_public, &input).unwrap()),
        }));
    }
    let design = |seeds: &[u8]| {
        let keys: Vec<String> = seeds.iter().map(|b| hex(&owner_public(*b))).collect();
        let bytes: Vec<u8> = seeds.iter().flat_map(|b| owner_public(*b)).collect();
        let d = designate(
            &f_s,
            &bytes,
            conversation.as_bytes(),
            account.as_bytes(),
            device.as_bytes(),
            &c,
        )
        .unwrap();
        (keys, d)
    };
    let (keys1, d1) = design(&[0x31]);
    let (keys3, d3) = design(&[0x33, 0x31, 0x32]);
    let mut with_bad = keys3.clone();
    with_bad.insert(1, hex(&[0u8; 32]));
    with_bad.push(hex(&crate::report::LOW_ORDER_POINTS_FOR_TESTS[2]));
    let mut tampered = d3.clone();
    tampered[KID_BYTES] ^= 1;
    let case = |name: &str,
                seed: u8,
                sender: &[u8],
                conv: &str,
                acct: &str,
                dev: &str,
                commit: &[u8],
                d: &[u8]| {
        let verdict = verify_with_report_seed(
            &[seed; 32],
            sender,
            conv.as_bytes(),
            acct.as_bytes(),
            dev.as_bytes(),
            commit,
            d,
        )
        .unwrap();
        serde_json::json!({
            "name": name,
            "report_seed": hex(&[seed; 32]),
            "sender_frank_public": hex(sender),
            "conversation_id": conv,
            "account_id": acct,
            "device_id": dev,
            "commit": hex(commit),
            "d": hex(d),
            "result": verdict as u8,
        })
    };
    let first_owner = OWNER_SEEDS
        .iter()
        .copied()
        .find(|seed| kid(&owner_public(*seed)).unwrap().as_slice() == &d3[..KID_BYTES])
        .unwrap();
    let mut other_commit = c.clone();
    other_commit[0] ^= 1;
    let verify_cases = vec![
        case(
            "valid owner 1",
            0x31,
            &f_pub,
            conversation,
            account,
            device,
            &c,
            &d3,
        ),
        case(
            "valid owner 2",
            0x32,
            &f_pub,
            conversation,
            account,
            device,
            &c,
            &d3,
        ),
        case(
            "valid owner 3",
            0x33,
            &f_pub,
            conversation,
            account,
            device,
            &c,
            &d3,
        ),
        case(
            "not designated (rotated owner key)",
            0x34,
            &f_pub,
            conversation,
            account,
            device,
            &c,
            &d3,
        ),
        case(
            "tampered tag",
            first_owner,
            &f_pub,
            conversation,
            account,
            device,
            &c,
            &tampered,
        ),
        case(
            "other account",
            0x31,
            &f_pub,
            conversation,
            "acct_other",
            device,
            &c,
            &d3,
        ),
        case(
            "other device",
            0x31,
            &f_pub,
            conversation,
            account,
            "dev_other",
            &c,
            &d3,
        ),
        case(
            "other conversation",
            0x31,
            &f_pub,
            "conv_other",
            account,
            device,
            &c,
            &d3,
        ),
        case(
            "other commitment",
            0x31,
            &f_pub,
            conversation,
            account,
            device,
            &other_commit,
            &d3,
        ),
        case(
            "other sender key",
            0x31,
            &public_key(&secret(0x22)),
            conversation,
            account,
            device,
            &c,
            &d3,
        ),
        case(
            "low-order sender key",
            0x31,
            &crate::report::LOW_ORDER_POINTS_FOR_TESTS[3],
            conversation,
            account,
            device,
            &c,
            &d3,
        ),
    ];
    let mut refused = Vec::new();
    for key in refused_keys() {
        refused.push(serde_json::json!({"kind": "low_order", "key": hex(&key)}));
    }
    for key in non_canonical_of(&owner_public(0x31))
        .into_iter()
        .chain(non_canonical_of(&f_pub))
    {
        refused.push(serde_json::json!({"kind": "non_canonical", "key": hex(&key)}));
    }
    let out = serde_json::json!({
        "description": "L2-3 designated-verifier franking of a sealed message (owner decision 2026-11-12, crypto ABI 26): the X25519 static-DH tag of a franking commitment for each pinned owner report key, its kid, HKDF key and HMAC tag, designations sorted by kid, verify verdicts (1 valid, 0 mismatch, 2 not designated) and the public keys every implementation refuses (low-order points and non-canonical spellings). Every secret is a fixed test value. Rules: docs/crypto.md, Franking a sealed message. Checked by crypto/rust/src/l2_frank_tests.rs, server/internal/sealedsender/frank_dv_test.go (independent: Go x/crypto/curve25519 and the standard library) and mobile/test/l2_frank_dv_native_test.dart (FFI).",
        "version": 1,
        "label": std::str::from_utf8(LABEL).unwrap(),
        "kid_label": std::str::from_utf8(KID_LABEL).unwrap(),
        "key_label": std::str::from_utf8(KEY_LABEL).unwrap(),
        "conversation_id": conversation,
        "commit": hex(&c),
        "sender": {
            "account_id": account,
            "device_id": device,
            "frank_secret": hex(&sender_bytes),
            "frank_public": hex(&f_pub),
        },
        "owners": owners,
        "designations": [
            {"name": "one owner", "owner_public_keys": keys1, "d": hex(&d1)},
            {"name": "three owners, given unsorted", "owner_public_keys": keys3, "d": hex(&d3)},
            {"name": "three owners with an all-zero and a low-order key skipped", "owner_public_keys": with_bad, "d": hex(&d3)},
        ],
        "verify_cases": verify_cases,
        "refused_public_keys": refused,
    });
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../testing/vectors/l2-frank-dv-v1.json"
    );
    std::fs::write(path, serde_json::to_string_pretty(&out).unwrap() + "\n").unwrap();
}
