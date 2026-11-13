//! L1 format 2 (L2-3, ABI 26): franking keys in the device list.
//!
//! `testing/vectors/l1-device-list-v2.json` is the shared vector: Rust checks
//! all of it here and the Go server checks it with its own parser
//! (`server/internal/devicelist/vector_v2_test.go`). The format-1 vector is
//! unchanged and still checked by `l1_tests.rs`. Every seed is a fixed test
//! value, so the file regenerates byte for byte:
//! `cargo test --lib l1::v2_tests::print_vector -- --ignored --nocapture`.

use super::*;
use crate::recovery;
use ed25519_dalek::{Signer as _, SigningKey};
use serde_json::{json, Value};
use x25519_dalek::StaticSecret;

const VECTOR: &str = include_str!("../../../testing/vectors/l1-device-list-v2.json");
const ACCOUNT: &[u8] = b"acct_frank_00112233445566778899aabb";
const ENTROPY: [u8; 30] = [0x5a; 30];
const NEW_ENTROPY: [u8; 30] = [0x6b; 30];

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn unhex(value: &Value) -> Vec<u8> {
    let text = value.as_str().expect("hex string");
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex"))
        .collect()
}

#[derive(Clone)]
struct Actor {
    id: &'static [u8],
    seed: u8,
    key: SigningKey,
    frank_seed: u8,
}

impl Actor {
    fn new(id: &'static [u8], seed: u8, frank_seed: u8) -> Self {
        Self {
            id,
            seed,
            key: SigningKey::from_bytes(&[seed; 32]),
            frank_seed,
        }
    }

    fn pair(&self) -> Pair {
        Pair {
            device_id: self.id.to_vec(),
            signing_key: self.key.verifying_key().to_bytes(),
        }
    }

    fn frank(&self) -> FrankKey {
        FrankKey {
            device_id: self.id.to_vec(),
            key: crate::l2_frank::public_key(&StaticSecret::from([self.frank_seed; 32])),
        }
    }
}

struct Cast {
    a: Actor,
    b: Actor,
    c: Actor,
    d: Actor,
    outsider: Actor,
}

fn cast() -> Cast {
    Cast {
        a: Actor::new(b"dev_fa", 0x71, 0x81),
        b: Actor::new(b"dev_fb", 0x72, 0x82),
        c: Actor::new(b"dev_fc", 0x73, 0x83),
        d: Actor::new(b"dev_fd", 0x74, 0x84),
        outsider: Actor::new(b"dev_fz", 0x75, 0x85),
    }
}

fn sorted_pairs(actors: &[&Actor]) -> Vec<Pair> {
    let mut pairs: Vec<Pair> = actors.iter().map(|actor| actor.pair()).collect();
    pairs.sort_by(|l, r| l.device_id.cmp(&r.device_id));
    pairs
}

fn sorted_franks(franks: &[FrankKey]) -> Vec<FrankKey> {
    let mut out = franks.to_vec();
    out.sort_by(|l, r| l.device_id.cmp(&r.device_id));
    out
}

fn body(
    change: Change,
    prev: Option<&Statement>,
    entries: &[&Actor],
    recovery_key: Option<[u8; 32]>,
    franks: &[FrankKey],
) -> Body {
    Body {
        account_id: ACCOUNT.to_vec(),
        version: prev.map_or(1, |prev| prev.body.version + 1),
        prev_hash: prev.map_or([0; 32], Statement::list_hash),
        created_at_ms: 1_800_000_000_000 + prev.map_or(0, |prev| prev.body.version),
        change,
        entries: sorted_pairs(entries),
        recovery_key,
        frank_keys: sorted_franks(franks),
    }
}

fn list_public(entropy: &[u8]) -> [u8; 32] {
    recovery::list_public(recovery::list_seed(entropy).unwrap().as_slice()).unwrap()
}

/// Signs raw body bytes with no encoder checks (refusal cases need bodies
/// the encoder would refuse).
fn sign_raw(body_bytes: &[u8], signer: &Signer, key: &SigningKey) -> Vec<u8> {
    let message = signed_message(body_bytes, signer).unwrap();
    let mut out = body_bytes.to_vec();
    out.push(match signer {
        Signer::Device(_) => SIGNER_DEVICE,
        Signer::Recovery => SIGNER_RECOVERY,
    });
    let id: &[u8] = match signer {
        Signer::Device(id) => id,
        Signer::Recovery => &[],
    };
    out.extend_from_slice(&(id.len() as u16).to_be_bytes());
    out.extend_from_slice(id);
    out.extend_from_slice(&key.sign(&message).to_bytes());
    out
}

fn by(body: &Body, actor: &Actor) -> Vec<u8> {
    sign_raw(
        &encode_body(body).unwrap(),
        &Signer::Device(actor.id.to_vec()),
        &actor.key,
    )
}

fn by_recovery(body: &Body, entropy: &[u8]) -> Vec<u8> {
    let seed = recovery::list_seed(entropy).unwrap();
    let key = SigningKey::from_bytes(seed.as_slice().try_into().unwrap());
    sign_raw(&encode_body(body).unwrap(), &Signer::Recovery, &key)
}

fn parsed(bytes: &[u8]) -> Statement {
    parse_statement(bytes).unwrap()
}

struct Chain {
    name: &'static str,
    statements: Vec<Vec<u8>>,
}

impl Chain {
    fn at(&self, version: usize) -> Statement {
        parsed(&self.statements[version - 1])
    }

    fn push(&mut self, statement: Vec<u8>) -> Statement {
        self.statements.push(statement);
        parsed(self.statements.last().unwrap())
    }
}

/// Every change kind, keys set by genesis, change 7 and recovery, and kept
/// across add, recovery-key change and remove.
fn chain_frank(cast: &Cast) -> Chain {
    let (a, b, c, d) = (&cast.a, &cast.b, &cast.c, &cast.d);
    let mut chain = Chain {
        name: "frank_keys_every_change",
        statements: Vec::new(),
    };
    let v1 = chain.push(by(
        &body(Change::Genesis, None, &[a], None, &[a.frank()]),
        a,
    ));
    let v2 = chain.push(by(
        &body(Change::Add, Some(&v1), &[a, b], None, &[a.frank()]),
        a,
    ));
    let v3 = chain.push(by(
        &body(
            Change::FrankKey,
            Some(&v2),
            &[a, b],
            None,
            &[a.frank(), b.frank()],
        ),
        b,
    ));
    let recovery = Some(list_public(&ENTROPY));
    let v4 = chain.push(by(
        &body(
            Change::RecoveryKey,
            Some(&v3),
            &[a, b],
            recovery,
            &[a.frank(), b.frank()],
        ),
        a,
    ));
    let v5 = chain.push(by(
        &body(
            Change::Add,
            Some(&v4),
            &[a, b, c],
            recovery,
            &[a.frank(), b.frank()],
        ),
        b,
    ));
    let v6 = chain.push(by(
        &body(Change::Remove, Some(&v5), &[b, c], recovery, &[b.frank()]),
        b,
    ));
    chain.push(by_recovery(
        &body(Change::Recovery, Some(&v6), &[d], recovery, &[d.frank()]),
        &ENTROPY,
    ));
    chain
}

/// A format-1 chain (an account from before L2-3) whose devices then set
/// their keys with change 7.
fn chain_migrate(cast: &Cast) -> Chain {
    let (a, b) = (&cast.a, &cast.b);
    let mut chain = Chain {
        name: "format_1_then_change_7",
        statements: Vec::new(),
    };
    let v1 = chain.push(by(&body(Change::Genesis, None, &[a], None, &[]), a));
    let v2 = chain.push(by(
        &body(Change::FrankKey, Some(&v1), &[a], None, &[a.frank()]),
        a,
    ));
    let v3 = chain.push(by(
        &body(Change::Add, Some(&v2), &[a, b], None, &[a.frank()]),
        a,
    ));
    chain.push(by(
        &body(
            Change::FrankKey,
            Some(&v3),
            &[a, b],
            None,
            &[a.frank(), b.frank()],
        ),
        b,
    ));
    chain
}

/// A migration genesis carries the signer's key; the other device sets its
/// own after.
fn chain_migration_genesis(cast: &Cast) -> Chain {
    let (a, b) = (&cast.a, &cast.b);
    let mut chain = Chain {
        name: "migration_genesis_then_change_7",
        statements: Vec::new(),
    };
    let v1 = chain.push(by(
        &body(Change::MigrationGenesis, None, &[a, b], None, &[a.frank()]),
        a,
    ));
    chain.push(by(
        &body(
            Change::FrankKey,
            Some(&v1),
            &[a, b],
            None,
            &[a.frank(), b.frank()],
        ),
        b,
    ));
    chain
}

struct Refused {
    name: String,
    prev: Option<Vec<u8>>,
    next: Vec<u8>,
    error: L1Error,
}

fn history_before(chain: &Chain, prev_version: usize) -> Vec<Pair> {
    // Every pair the versions before `prev` listed (check_step adds prev's).
    let mut pairs: Vec<Pair> = Vec::new();
    for statement in &chain.statements[..prev_version.saturating_sub(1)] {
        for pair in parsed(statement).body.entries {
            if !pairs.contains(&pair) {
                pairs.push(pair);
            }
        }
    }
    pairs
}

fn outcome(prev: Option<&[u8]>, next: &[u8], history: &[Pair]) -> Result<(), L1Error> {
    let next = parse_statement(next)?;
    let prev = prev.map(parsed);
    check_step(ACCOUNT, prev.as_ref(), &next, history)
}

/// A body of `base` written as format `format` with `section` appended by
/// hand (no encoder checks).
fn raw_with_section(base: &Body, format: u8, section: &[u8]) -> Vec<u8> {
    let mut plain = base.clone();
    plain.frank_keys.clear();
    let mut bytes = encode_body(&plain).unwrap();
    bytes[4] = format;
    bytes.extend_from_slice(section);
    bytes
}

fn section(franks: &[(&[u8], [u8; 32])]) -> Vec<u8> {
    let mut out = vec![franks.len() as u8];
    for (id, key) in franks {
        out.extend_from_slice(&(id.len() as u16).to_be_bytes());
        out.extend_from_slice(id);
        out.extend_from_slice(key);
    }
    out
}

/// Each case breaks exactly one rule; the generator asserts the reason.
fn refused_cases(cast: &Cast, chain: &Chain) -> Vec<Refused> {
    let (a, b, c) = (&cast.a, &cast.b, &cast.c);
    let mut cases: Vec<(String, Option<usize>, Vec<u8>, L1Error)> = Vec::new();
    let genesis = body(Change::Genesis, None, &[a], None, &[]);
    let mg = body(Change::MigrationGenesis, None, &[a, b], None, &[]);
    let malformed_body = |name: &str, base: &Body, format: u8, sect: Vec<u8>| {
        (
            name.to_string(),
            None,
            sign_raw(
                &raw_with_section(base, format, &sect),
                &Signer::Device(a.id.to_vec()),
                &a.key,
            ),
            L1Error::Malformed,
        )
    };
    let fa = a.frank().key;
    let fb = b.frank().key;
    cases.push(malformed_body("format_2_with_no_key", &genesis, 2, vec![0]));
    cases.push(malformed_body(
        "format_1_with_a_key_section",
        &genesis,
        1,
        section(&[(a.id, fa)]),
    ));
    cases.push(malformed_body(
        "format_3",
        &genesis,
        3,
        section(&[(a.id, fa)]),
    ));
    cases.push(malformed_body(
        "key_for_an_unlisted_device",
        &genesis,
        2,
        section(&[(cast.outsider.id, fa)]),
    ));
    cases.push(malformed_body(
        "more_keys_than_devices",
        &genesis,
        2,
        section(&[(a.id, fa), (b.id, fb)]),
    ));
    cases.push(malformed_body(
        "keys_not_sorted",
        &mg,
        2,
        section(&[(b.id, fb), (a.id, fa)]),
    ));
    cases.push(malformed_body(
        "a_device_twice",
        &mg,
        2,
        section(&[(a.id, fa), (a.id, fb)]),
    ));
    cases.push(malformed_body(
        "one_key_for_two_devices",
        &mg,
        2,
        section(&[(a.id, fa), (b.id, fa)]),
    ));
    cases.push(malformed_body("truncated_key", &genesis, 2, {
        let mut s = section(&[(a.id, fa)]);
        s.pop();
        s
    }));
    let mut p_bytes = [0xffu8; 32];
    p_bytes[0] = 0xed;
    p_bytes[31] = 0x7f;
    let mut bad_keys: Vec<(String, [u8; 32])> = crate::report::LOW_ORDER_POINTS_FOR_TESTS
        .iter()
        .enumerate()
        .map(|(i, key)| (format!("low_order_key_{i}"), *key))
        .collect();
    bad_keys.push(("key_equal_to_p".into(), p_bytes));
    let mut high_bit = fa;
    high_bit[31] |= 0x80;
    bad_keys.push(("key_with_bit_255_set".into(), high_bit));
    for (name, key) in bad_keys {
        cases.push(malformed_body(&name, &genesis, 2, section(&[(a.id, key)])));
    }
    // change 8 is not a change kind.
    let mut change8 = encode_body(&body(Change::Genesis, None, &[a], None, &[a.frank()])).unwrap();
    let change_at = 4 + 1 + 2 + ACCOUNT.len() + 8 + 32 + 8;
    change8[change_at] = 8;
    cases.push((
        "change_8".into(),
        None,
        sign_raw(&change8, &Signer::Device(a.id.to_vec()), &a.key),
        L1Error::Malformed,
    ));

    // Rules. prev versions refer to chain_frank: v1 {A:fa}, v2 {A,B : A},
    // v3..v4 {A,B : A,B}, v5 {A,B,C : A,B}, v6 {B,C : B}.
    let v = |n: usize| chain.at(n);
    let fc = c.frank();
    let rec = Some(list_public(&ENTROPY));
    cases.push((
        "migration_genesis_sets_another_devices_key".into(),
        None,
        by(
            &body(Change::MigrationGenesis, None, &[a, b], None, &[b.frank()]),
            a,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "add_gives_the_new_device_a_key".into(),
        Some(1),
        by(
            &body(
                Change::Add,
                Some(&v(1)),
                &[a, b],
                None,
                &[a.frank(), b.frank()],
            ),
            a,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "add_changes_a_kept_key".into(),
        Some(4),
        by(
            &body(
                Change::Add,
                Some(&v(4)),
                &[a, b, c],
                rec,
                &[a.frank(), fc.clone()],
            ),
            b,
        ),
        L1Error::Rule,
    ));
    let other_a = FrankKey {
        device_id: a.id.to_vec(),
        key: crate::l2_frank::public_key(&StaticSecret::from([0x91; 32])),
    };
    cases.push((
        "change_7_replaces_the_signers_key".into(),
        Some(1),
        by(
            &body(
                Change::FrankKey,
                Some(&v(1)),
                &[a],
                None,
                std::slice::from_ref(&other_a),
            ),
            a,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "change_7_sets_another_devices_key".into(),
        Some(5),
        by(
            &body(
                Change::FrankKey,
                Some(&v(5)),
                &[a, b, c],
                rec,
                &[a.frank(), b.frank(), fc.clone()],
            ),
            b,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "change_7_drops_another_devices_key".into(),
        Some(5),
        by(
            &body(
                Change::FrankKey,
                Some(&v(5)),
                &[a, b, c],
                rec,
                &[b.frank(), fc.clone()],
            ),
            c,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "change_7_changes_another_devices_key".into(),
        Some(5),
        by(
            &body(
                Change::FrankKey,
                Some(&v(5)),
                &[a, b, c],
                rec,
                &[other_a.clone(), b.frank(), fc.clone()],
            ),
            c,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "change_7_without_the_signers_key".into(),
        Some(5),
        by(
            &body(
                Change::FrankKey,
                Some(&v(5)),
                &[a, b, c],
                rec,
                &[a.frank(), b.frank()],
            ),
            c,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "change_7_changes_the_devices".into(),
        Some(5),
        by(
            &body(
                Change::FrankKey,
                Some(&v(5)),
                &[b, c],
                rec,
                &[b.frank(), fc.clone()],
            ),
            c,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "change_7_changes_the_recovery_key".into(),
        Some(5),
        by(
            &body(
                Change::FrankKey,
                Some(&v(5)),
                &[a, b, c],
                Some(list_public(&NEW_ENTROPY)),
                &[a.frank(), b.frank(), fc.clone()],
            ),
            c,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "change_7_signed_by_the_recovery_key".into(),
        Some(5),
        by_recovery(
            &body(
                Change::FrankKey,
                Some(&v(5)),
                &[a, b, c],
                rec,
                &[a.frank(), b.frank(), fc.clone()],
            ),
            &ENTROPY,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "change_7_by_an_unlisted_device".into(),
        Some(5),
        by(
            &body(
                Change::FrankKey,
                Some(&v(5)),
                &[a, b, c],
                rec,
                &[a.frank(), b.frank(), fc.clone()],
            ),
            &cast.outsider,
        ),
        L1Error::Rule,
    ));
    cases.push((
        "remove_drops_a_kept_key".into(),
        Some(5),
        by(&body(Change::Remove, Some(&v(5)), &[b, c], rec, &[]), b),
        L1Error::Rule,
    ));
    cases.push((
        "recovery_key_change_adds_a_key".into(),
        Some(5),
        by(
            &body(
                Change::RecoveryKey,
                Some(&v(5)),
                &[a, b, c],
                Some(list_public(&NEW_ENTROPY)),
                &[a.frank(), b.frank(), fc.clone()],
            ),
            a,
        ),
        L1Error::Rule,
    ));
    // Signed by B's key while naming C as the signer.
    let mut forged = by(
        &body(
            Change::FrankKey,
            Some(&v(5)),
            &[a, b, c],
            rec,
            &[a.frank(), b.frank(), fc.clone()],
        ),
        c,
    );
    let body_bytes = parsed(&forged).body_bytes().to_vec();
    let message = signed_message(&body_bytes, &Signer::Device(c.id.to_vec())).unwrap();
    let signature = b.key.sign(&message).to_bytes();
    let len = forged.len();
    forged[len - 64..].copy_from_slice(&signature);
    cases.push((
        "change_7_bad_signature".into(),
        Some(5),
        forged,
        L1Error::Signature,
    ));

    cases
        .into_iter()
        .map(|(name, prev, next, error)| {
            let prev_bytes = prev.map(|n| chain.statements[n - 1].clone());
            let history = prev.map_or(Vec::new(), |n| history_before(chain, n));
            assert_eq!(
                outcome(prev_bytes.as_deref(), &next, &history),
                Err(error),
                "{name}"
            );
            Refused {
                name,
                prev: prev_bytes,
                next,
                error,
            }
        })
        .collect()
}

/// A recovered device takes the key of a device the chain removed: every
/// step passes alone, the whole chain does not.
fn chain_reused_key(cast: &Cast, frank: &Chain) -> Chain {
    let mut chain = Chain {
        name: "a_removed_devices_key_given_to_another",
        statements: frank.statements[..6].to_vec(),
    };
    let v6 = chain.at(6);
    let stolen = FrankKey {
        device_id: cast.d.id.to_vec(),
        key: cast.a.frank().key,
    };
    chain.push(by_recovery(
        &body(
            Change::Recovery,
            Some(&v6),
            &[&cast.d],
            Some(list_public(&ENTROPY)),
            &[stolen],
        ),
        &ENTROPY,
    ));
    chain
}

fn chain_json(chain: &Chain) -> Value {
    let statements: Vec<Statement> = chain.statements.iter().map(|s| parsed(s)).collect();
    let result = check_chain(ACCOUNT, &statements).expect(chain.name);
    json!({
        "name": chain.name,
        "statements": chain.statements.iter().map(|s| hex(s)).collect::<Vec<_>>(),
        "formats": statements.iter().map(|s| s.raw()[4]).collect::<Vec<_>>(),
        "head_list_hash": hex(&result.head.list_hash()),
        "pairs": result.pairs.iter().map(|listed| json!({
            "device_id": String::from_utf8(listed.pair.device_id.clone()).unwrap(),
            "signing_key": hex(&listed.pair.signing_key),
            "added_version": listed.added_version,
            "removed_version": listed.removed_version,
            "frank_key": listed.frank_key.map(|key| hex(&key)),
        })).collect::<Vec<_>>(),
        "chain_result": hex(&encode_chain_result(&result).unwrap()),
    })
}

fn compute() -> Value {
    let cast = cast();
    let frank = chain_frank(&cast);
    let chains = [
        chain_frank(&cast),
        chain_migrate(&cast),
        chain_migration_genesis(&cast),
    ];
    let refused = refused_cases(&cast, &frank);
    let reused = chain_reused_key(&cast, &frank);
    let reused_statements: Vec<Statement> = reused.statements.iter().map(|s| parsed(s)).collect();
    let reused_history = history_before(&reused, 6);
    assert_eq!(
        check_step(
            ACCOUNT,
            Some(&reused_statements[5]),
            &reused_statements[6],
            &reused_history
        ),
        Ok(())
    );
    assert_eq!(
        check_chain(ACCOUNT, &reused_statements).map(|_| ()),
        Err(L1Error::Rule)
    );
    let actors = [&cast.a, &cast.b, &cast.c, &cast.d, &cast.outsider];
    json!({
        "description": "L1 format 2 (L2-3, ABI 26): franking keys in the approved-device list (docs/crypto.md, \"Franking a sealed message\"; docs/designs/L1-approved-device-list.md, format 2). Valid chains with keys set by genesis, change 7 and recovery and kept by every other change, a format-1 chain moved to format 2, single-fault refusals and a chain that reuses a removed device's key. Every seed is a fixed test value. Checked by crypto/rust/src/l1_v2_tests.rs and server/internal/devicelist/vector_v2_test.go. Changing any value is a protocol change. Regenerate: cargo test --lib l1::v2_tests::print_vector -- --ignored --nocapture.",
        "inputs": {
            "account_id": String::from_utf8(ACCOUNT.to_vec()).unwrap(),
            "recovery_entropy": hex(&ENTROPY),
            "devices": actors.iter().map(|actor| json!({
                "device_id": String::from_utf8(actor.id.to_vec()).unwrap(),
                "ed25519_seed": hex(&[actor.seed; 32]),
                "signing_key": hex(&actor.pair().signing_key),
                "x25519_secret": hex(&[actor.frank_seed; 32]),
                "frank_key": hex(&actor.frank().key),
            })).collect::<Vec<_>>(),
        },
        "outputs": {
            "chains": chains.iter().map(chain_json).collect::<Vec<_>>(),
            "refused": refused.iter().map(|case| json!({
                "name": case.name,
                "prev": case.prev.as_ref().map(|bytes| hex(bytes)),
                "history": case.prev.as_ref().map_or(Vec::new(), |prev| {
                    let version = parsed(prev).body.version as usize;
                    history_before(&frank, version).iter().map(|pair| json!({
                        "device_id": String::from_utf8(pair.device_id.clone()).unwrap(),
                        "signing_key": hex(&pair.signing_key),
                    })).collect::<Vec<_>>()
                }),
                "next": hex(&case.next),
                "error": case.error.name(),
            })).collect::<Vec<_>>(),
            "refused_chains": [{
                "name": reused.name,
                "statements": reused.statements.iter().map(|s| hex(s)).collect::<Vec<_>>(),
                "every_step_alone": "ok",
                "error": L1Error::Rule.name(),
            }],
        },
    })
}

#[test]
#[ignore = "prints the vector; run to regenerate the file"]
fn print_vector() {
    println!("{}", serde_json::to_string_pretty(&compute()).unwrap());
}

#[test]
fn the_vector_file_is_what_the_code_produces() {
    let committed: Value = serde_json::from_str(VECTOR).expect("vector parses");
    assert_eq!(committed, compute(), "regenerate the vector (print_vector)");
}

#[test]
fn the_vector_cases_hold_from_the_file_alone() {
    let vector: Value = serde_json::from_str(VECTOR).unwrap();
    for chain in vector["outputs"]["chains"].as_array().unwrap() {
        let statements: Vec<Statement> = chain["statements"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| parse_statement(&unhex(s)).unwrap())
            .collect();
        let result = check_chain(ACCOUNT, &statements).unwrap();
        assert_eq!(
            hex(&encode_chain_result(&result).unwrap()),
            chain["chain_result"]
        );
        // Every statement re-encodes to its own bytes.
        for statement in &statements {
            assert_eq!(
                encode_body(&statement.body).unwrap(),
                statement.body_bytes()
            );
        }
    }
    let refused = vector["outputs"]["refused"].as_array().unwrap();
    assert!(refused.len() >= 30, "the vector must keep its coverage");
    for case in refused {
        let prev = case["prev"].as_str().map(|_| unhex(&case["prev"]));
        let history: Vec<Pair> = case["history"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pair| Pair {
                device_id: pair["device_id"].as_str().unwrap().as_bytes().to_vec(),
                signing_key: unhex(&pair["signing_key"]).try_into().unwrap(),
            })
            .collect();
        let got = outcome(prev.as_deref(), &unhex(&case["next"]), &history);
        assert_eq!(
            got.map_err(L1Error::name),
            Err(case["error"].as_str().unwrap()),
            "{}",
            case["name"]
        );
    }
}

#[test]
fn a_body_without_keys_is_format_1_byte_for_byte() {
    let cast = cast();
    let plain = body(Change::Genesis, None, &[&cast.a], None, &[]);
    let bytes = encode_body(&plain).unwrap();
    assert_eq!(bytes[4], FORMAT);
    let with_key = body(Change::Genesis, None, &[&cast.a], None, &[cast.a.frank()]);
    let frank_bytes = encode_body(&with_key).unwrap();
    assert_eq!(frank_bytes[4], FORMAT_FRANK);
    // Format 2 is format 1 with the byte changed and the section appended.
    assert_eq!(&frank_bytes[..4], &bytes[..4]);
    assert_eq!(&frank_bytes[5..bytes.len()], &bytes[5..]);
    assert_eq!(
        &frank_bytes[bytes.len()..],
        section(&[(cast.a.id, cast.a.frank().key)]).as_slice()
    );
}

#[test]
fn summaries_carry_the_frank_keys() {
    let cast = cast();
    let chain = chain_frank(&cast);
    let head = chain.at(7);
    let summary = encode_summary(&head).unwrap();
    assert!(summary.ends_with(&section(&[(cast.d.id, cast.d.frank().key)])));
    let plain = parsed(&by(
        &body(Change::Genesis, None, &[&cast.a], None, &[]),
        &cast.a,
    ));
    assert_eq!(*encode_summary(&plain).unwrap().last().unwrap(), 0);
}

/// Owner item 3: the key a device tags with is the key its list names. A
/// device signs only a list that gives it its own franking key, and the key
/// the chain reports for it is the one it designates with.
#[test]
fn the_franking_key_is_the_one_the_list_names() {
    let device = crate::mls::MlsDevice::new(ACCOUNT, b"dev_real").unwrap();
    let own = Pair {
        device_id: b"dev_real".to_vec(),
        signing_key: device.signing_public_key().try_into().unwrap(),
    };
    let frank = FrankKey {
        device_id: b"dev_real".to_vec(),
        key: device.l2_frank_public_key(),
    };
    let genesis = Body {
        account_id: ACCOUNT.to_vec(),
        version: 1,
        prev_hash: [0; 32],
        created_at_ms: 1,
        change: Change::Genesis,
        entries: vec![own.clone()],
        recovery_key: None,
        frank_keys: vec![frank.clone()],
    };
    let bytes = encode_body(&genesis).unwrap();
    let signature: [u8; 64] = device
        .l1_sign_device_list(&bytes)
        .unwrap()
        .try_into()
        .unwrap();
    let statement = parse_statement(
        &assemble_statement(&bytes, &Signer::Device(b"dev_real".to_vec()), &signature).unwrap(),
    )
    .unwrap();
    let result = check_chain(ACCOUNT, &[statement]).unwrap();
    let listed = result.pairs[0].frank_key.unwrap();
    assert_eq!(listed, device.l2_frank_public_key());
    // The listed key designates; any other key is refused.
    let owner = crate::l2_frank::public_key(&StaticSecret::from([0x31; 32]));
    assert!(device
        .l2_frank_designate(b"conv", &[7; 32], &listed, &owner)
        .is_ok());
    let mut wrong = listed;
    wrong[0] ^= 1;
    assert!(device
        .l2_frank_designate(b"conv", &[7; 32], &wrong, &owner)
        .is_err());

    // A list that gives this device any other franking key is not signed,
    // and neither is change 7 without its own key.
    let mut stranger = genesis.clone();
    stranger.frank_keys[0].key = cast().b.frank().key;
    assert_eq!(
        device.l1_sign_device_list(&encode_body(&stranger).unwrap()),
        Err(crate::mls::MlsError::InvalidIdentity)
    );
    let mut no_key = genesis;
    no_key.frank_keys.clear();
    let prev = parse_statement(
        &assemble_statement(
            &encode_body(&no_key).unwrap(),
            &Signer::Device(b"dev_real".to_vec()),
            &device
                .l1_sign_device_list(&encode_body(&no_key).unwrap())
                .unwrap()
                .try_into()
                .unwrap(),
        )
        .unwrap(),
    )
    .unwrap();
    let change7_without = Body {
        version: 2,
        prev_hash: prev.list_hash(),
        change: Change::FrankKey,
        ..no_key
    };
    assert_eq!(
        device.l1_sign_device_list(&encode_body(&change7_without).unwrap()),
        Err(crate::mls::MlsError::InvalidIdentity)
    );
}
