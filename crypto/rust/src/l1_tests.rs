use super::*;
use crate::recovery;
use ed25519_dalek::{Signer as _, SigningKey};
use serde_json::{json, Value};

/// `testing/vectors/l1-device-list-v1.json`: the shared known-answer vector
/// for the approved-device list. Rust checks all of it; the Go server tests
/// (`server/internal/httpapi/vdl1_vector_test.go`) check it with an
/// independent reimplementation; Dart checks it through the native calls
/// (`mobile/test/l1_device_list_native_test.dart`). Every signing seed is a
/// fixed test value, so the file regenerates byte for byte:
/// `cargo test --lib l1::tests::print_vector -- --ignored --nocapture`.
const VECTOR: &str = include_str!("../../../testing/vectors/l1-device-list-v1.json");

const ACCOUNT: &[u8] = b"acct_00112233445566778899aabbccddeeff";
const OTHER_ACCOUNT: &[u8] = b"acct_ffeeddccbbaa99887766554433221100";
const K0_ENTROPY: [u8; 30] = [
    0x0f, 0x1e, 0x2d, 0x3c, 0x4b, 0x5a, 0x69, 0x78, 0x87, 0x96, 0xa5, 0xb4, 0xc3, 0xd2, 0xe1, 0xf0,
    0x01, 0x12, 0x23, 0x34, 0x45, 0x56, 0x67, 0x78, 0x89, 0x9a, 0xab, 0xbc, 0xcd, 0xde,
];
const SECOND_ENTROPY: [u8; 30] = [0x42; 30];

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
    key: SigningKey,
}

impl Actor {
    fn new(id: &'static [u8], seed: u8) -> Self {
        Self {
            id,
            key: SigningKey::from_bytes(&[seed; 32]),
        }
    }

    fn public(&self) -> [u8; 32] {
        self.key.verifying_key().to_bytes()
    }

    fn pair(&self) -> Pair {
        Pair {
            device_id: self.id.to_vec(),
            signing_key: self.public(),
        }
    }
}

struct Cast {
    a: Actor,
    b: Actor,
    c: Actor,
    d: Actor,
    e: Actor,
    outsider: Actor,
}

fn cast() -> Cast {
    Cast {
        a: Actor::new(b"dev_a0a0a0a0a0a0a0a0", 0x11),
        b: Actor::new(b"dev_b1b1b1b1b1b1b1b1", 0x22),
        c: Actor::new(b"dev_c2c2c2c2c2c2c2c2", 0x33),
        d: Actor::new(b"dev_d3d3d3d3d3d3d3d3", 0x44),
        e: Actor::new(b"dev_e4e4e4e4e4e4e4e4", 0x55),
        outsider: Actor::new(b"dev_f5f5f5f5f5f5f5f5", 0x66),
    }
}

fn list_public(entropy: &[u8]) -> [u8; 32] {
    recovery::list_public(recovery::list_seed(entropy).unwrap().as_slice()).unwrap()
}

fn entries(actors: &[&Actor]) -> Vec<Pair> {
    let mut pairs: Vec<Pair> = actors.iter().map(|actor| actor.pair()).collect();
    pairs.sort_by(|left, right| left.device_id.cmp(&right.device_id));
    pairs
}

fn body_of(
    change: Change,
    version: u64,
    prev: Option<&Statement>,
    created_at_ms: u64,
    entries: Vec<Pair>,
    recovery_key: Option<[u8; 32]>,
) -> Body {
    Body {
        account_id: ACCOUNT.to_vec(),
        version,
        prev_hash: prev.map_or([0; 32], Statement::list_hash),
        created_at_ms,
        change,
        entries,
        recovery_key,
    }
}

fn sign_with(body_bytes: &[u8], signer: &Signer, key: &SigningKey) -> Vec<u8> {
    let message = signed_message(body_bytes, signer).unwrap();
    let signature = key.sign(&message).to_bytes();
    assemble_statement(body_bytes, signer, &signature).unwrap()
}

fn by_device(body: &Body, actor: &Actor) -> Vec<u8> {
    sign_with(
        &encode_body(body).unwrap(),
        &Signer::Device(actor.id.to_vec()),
        &actor.key,
    )
}

fn by_recovery(body: &Body, entropy: &[u8]) -> Vec<u8> {
    let seed = recovery::list_seed(entropy).unwrap();
    let key = SigningKey::from_bytes(seed.as_slice().try_into().unwrap());
    sign_with(&encode_body(body).unwrap(), &Signer::Recovery, &key)
}

fn parsed(bytes: &[u8]) -> Statement {
    parse_statement(bytes).unwrap()
}

/// Bytes of a body assembled by hand, with none of the encoder's checks.
#[allow(clippy::too_many_arguments)]
fn raw_body(
    account: &[u8],
    version: u64,
    prev_hash: [u8; 32],
    change: u8,
    entries: &[(&[u8], [u8; 32])],
    has_recovery: u8,
    recovery_key: Option<[u8; 32]>,
    format: u8,
) -> Vec<u8> {
    let mut out = b"VDL1".to_vec();
    out.push(format);
    out.extend_from_slice(&(account.len() as u16).to_be_bytes());
    out.extend_from_slice(account);
    out.extend_from_slice(&version.to_be_bytes());
    out.extend_from_slice(&prev_hash);
    out.extend_from_slice(&1_700_000_000_000u64.to_be_bytes());
    out.push(change);
    out.push(entries.len() as u8);
    for (id, key) in entries {
        out.extend_from_slice(&(id.len() as u16).to_be_bytes());
        out.extend_from_slice(id);
        out.extend_from_slice(key);
    }
    out.push(has_recovery);
    if let Some(key) = recovery_key {
        out.extend_from_slice(&key);
    }
    out
}

fn raw_statement(body: &[u8], kind: u8, id: &[u8], signature: [u8; 64]) -> Vec<u8> {
    let mut out = body.to_vec();
    out.push(kind);
    out.extend_from_slice(&(id.len() as u16).to_be_bytes());
    out.extend_from_slice(id);
    out.extend_from_slice(&signature);
    out
}

const IDENTITY_POINT: [u8; 32] = {
    let mut key = [0u8; 32];
    key[0] = 1;
    key
};

/// A 32-byte value that is not the encoding of any curve point.
fn invalid_point() -> [u8; 32] {
    (0u8..=255)
        .map(|first| {
            let mut key = [0x07u8; 32];
            key[0] = first;
            key[31] = 0x3f;
            key
        })
        .find(|key| VerifyingKey::from_bytes(key).is_err())
        .expect("some value is not a point")
}

struct Chain {
    statements: Vec<Vec<u8>>,
}

impl Chain {
    fn last(&self) -> Statement {
        parsed(self.statements.last().unwrap())
    }

    fn at(&self, version: usize) -> Statement {
        parsed(&self.statements[version - 1])
    }
}

/// Chain A: every change but the migration genesis.
///
/// 1 genesis (A) · 2 add B (by A) · 3 recovery key set (by B) · 4 add C (by A)
/// · 5 remove B (by B itself) · 6 recovery (D alone, by the recovery key)
/// · 7 recovery key replaced (by D) · 8 add E (by D)
fn chain_a(cast: &Cast) -> Chain {
    let rk1 = list_public(&K0_ENTROPY);
    let rk2 = list_public(&SECOND_ENTROPY);
    let t = 1_700_000_000_000u64;
    let mut statements: Vec<Vec<u8>> = Vec::new();
    let push = |statements: &mut Vec<Vec<u8>>, bytes: Vec<u8>| statements.push(bytes);
    let prev = |statements: &Vec<Vec<u8>>| parsed(statements.last().unwrap());

    let v1 = body_of(Change::Genesis, 1, None, t, entries(&[&cast.a]), None);
    push(&mut statements, by_device(&v1, &cast.a));
    let v2 = body_of(
        Change::Add,
        2,
        Some(&prev(&statements)),
        t + 1000,
        entries(&[&cast.a, &cast.b]),
        None,
    );
    push(&mut statements, by_device(&v2, &cast.a));
    let v3 = body_of(
        Change::RecoveryKey,
        3,
        Some(&prev(&statements)),
        t + 2000,
        entries(&[&cast.a, &cast.b]),
        Some(rk1),
    );
    push(&mut statements, by_device(&v3, &cast.b));
    let v4 = body_of(
        Change::Add,
        4,
        Some(&prev(&statements)),
        t + 3000,
        entries(&[&cast.a, &cast.b, &cast.c]),
        Some(rk1),
    );
    push(&mut statements, by_device(&v4, &cast.a));
    let v5 = body_of(
        Change::Remove,
        5,
        Some(&prev(&statements)),
        t + 4000,
        entries(&[&cast.a, &cast.c]),
        Some(rk1),
    );
    push(&mut statements, by_device(&v5, &cast.b));
    let v6 = body_of(
        Change::Recovery,
        6,
        Some(&prev(&statements)),
        t + 5000,
        entries(&[&cast.d]),
        Some(rk1),
    );
    push(&mut statements, by_recovery(&v6, &K0_ENTROPY));
    let v7 = body_of(
        Change::RecoveryKey,
        7,
        Some(&prev(&statements)),
        t + 6000,
        entries(&[&cast.d]),
        Some(rk2),
    );
    push(&mut statements, by_device(&v7, &cast.d));
    let v8 = body_of(
        Change::Add,
        8,
        Some(&prev(&statements)),
        t + 7000,
        entries(&[&cast.d, &cast.e]),
        Some(rk2),
    );
    push(&mut statements, by_device(&v8, &cast.d));
    Chain { statements }
}

/// Chain B: a migration genesis (A reviews and lists A, B and C, signed by
/// B), then a removal and an add.
fn chain_b(cast: &Cast) -> Chain {
    let t = 1_700_100_000_000u64;
    let mut statements: Vec<Vec<u8>> = Vec::new();
    let v1 = body_of(
        Change::MigrationGenesis,
        1,
        None,
        t,
        entries(&[&cast.a, &cast.b, &cast.c]),
        None,
    );
    statements.push(by_device(&v1, &cast.b));
    let v2 = body_of(
        Change::Remove,
        2,
        Some(&parsed(&statements[0])),
        t + 1000,
        entries(&[&cast.a, &cast.b]),
        None,
    );
    statements.push(by_device(&v2, &cast.a));
    let v3 = body_of(
        Change::Add,
        3,
        Some(&parsed(&statements[1])),
        t + 2000,
        entries(&[&cast.a, &cast.b, &cast.d]),
        None,
    );
    statements.push(by_device(&v3, &cast.b));
    Chain { statements }
}

fn pairs_json(pairs: &[Pair]) -> Value {
    Value::Array(
        pairs
            .iter()
            .map(|pair| json!({"device_id": String::from_utf8(pair.device_id.clone()).unwrap(), "signing_key_hex": hex(&pair.signing_key)}))
            .collect(),
    )
}

fn history_of(statements: &[&Statement]) -> Vec<Pair> {
    let mut history: Vec<Pair> = Vec::new();
    for statement in statements {
        for pair in &statement.body.entries {
            if !history.contains(pair) {
                history.push(pair.clone());
            }
        }
    }
    history
}

fn chain_hex(statements: &[Vec<u8>]) -> String {
    let mut out = (statements.len() as u16).to_be_bytes().to_vec();
    for statement in statements {
        out.extend_from_slice(&(statement.len() as u16).to_be_bytes());
        out.extend_from_slice(statement);
    }
    hex(&out)
}

fn chain_json(name: &str, chain: &Chain) -> Value {
    let steps: Vec<Value> = chain
        .statements
        .iter()
        .map(|bytes| {
            let statement = parsed(bytes);
            let body = &statement.body;
            json!({
                "version": body.version,
                "change": body.change as u8,
                "statement_hex": hex(bytes),
                "body_hex": hex(statement.body_bytes()),
                "list_hash_hex": hex(&statement.list_hash()),
                "signer_kind": statement.signer.kind(),
                "signer_device_id": String::from_utf8(statement.signer.id().to_vec()).unwrap(),
                "signed_message_hex": hex(&signed_message(statement.body_bytes(), &statement.signer).unwrap()),
                "signature_hex": hex(&statement.signature),
                "entries": pairs_json(&body.entries),
                "recovery_key_hex": body.recovery_key.map(|key| hex(&key)),
            })
        })
        .collect();
    let statements: Vec<Statement> = chain.statements.iter().map(|b| parsed(b)).collect();
    let result = check_chain(&statements).unwrap();
    json!({
        "name": name,
        "steps": steps,
        "chain_hex": chain_hex(&chain.statements),
        "list_id_hex": hex(&result.list_id),
        "head_version": result.head.body.version,
        "pairs": result.pairs.iter().map(|listed| json!({
            "device_id": String::from_utf8(listed.pair.device_id.clone()).unwrap(),
            "signing_key_hex": hex(&listed.pair.signing_key),
            "added_version": listed.added_version,
            "removed_version": listed.removed_version,
        })).collect::<Vec<_>>(),
    })
}

struct Refused {
    name: &'static str,
    prev: Option<Vec<u8>>,
    statement: Vec<u8>,
    history: Vec<Pair>,
    error: L1Error,
}

fn refusal(
    name: &'static str,
    prev: Option<&Vec<u8>>,
    statement: Vec<u8>,
    history: &[Pair],
    error: L1Error,
) -> Refused {
    Refused {
        name,
        prev: prev.cloned(),
        statement,
        history: history.to_vec(),
        error,
    }
}

/// Every rule violation, each with exactly one fault.
fn refused_cases(cast: &Cast, a: &Chain) -> Vec<Refused> {
    let rk1 = list_public(&K0_ENTROPY);
    let rk2 = list_public(&SECOND_ENTROPY);
    let t = 1_700_000_000_000u64;
    let key = |actor: &Actor| (actor.id, actor.public());
    let sig = [0xA5u8; 64];
    let mut cases: Vec<Refused> = Vec::new();

    // ---- malformed -------------------------------------------------------
    let good = |change: u8| raw_body(ACCOUNT, 1, [0; 32], change, &[key(&cast.a)], 0, None, 1);
    let malformed = |name: &'static str, body: Vec<u8>| {
        refusal(
            name,
            None,
            raw_statement(&body, 1, cast.a.id, sig),
            &[],
            L1Error::Malformed,
        )
    };
    let mut bad_magic = good(1);
    bad_magic[0] = b'X';
    cases.push(malformed("bad magic", bad_magic));
    cases.push(malformed(
        "format 2",
        raw_body(ACCOUNT, 1, [0; 32], 1, &[key(&cast.a)], 0, None, 2),
    ));
    cases.push(malformed(
        "version 0",
        raw_body(ACCOUNT, 0, [0; 32], 1, &[key(&cast.a)], 0, None, 1),
    ));
    cases.push(malformed(
        "unknown change 7",
        raw_body(ACCOUNT, 1, [0; 32], 7, &[key(&cast.a)], 0, None, 1),
    ));
    cases.push(malformed(
        "unknown change 0",
        raw_body(ACCOUNT, 1, [0; 32], 0, &[key(&cast.a)], 0, None, 1),
    ));
    cases.push(malformed(
        "genesis with a prev_hash",
        raw_body(ACCOUNT, 1, [9; 32], 1, &[key(&cast.a)], 0, None, 1),
    ));
    cases.push(malformed(
        "genesis at version 2",
        raw_body(ACCOUNT, 2, [0; 32], 1, &[key(&cast.a)], 0, None, 1),
    ));
    cases.push(malformed(
        "add at version 1",
        raw_body(ACCOUNT, 1, [0; 32], 2, &[key(&cast.a)], 0, None, 1),
    ));
    cases.push(malformed(
        "no entries",
        raw_body(ACCOUNT, 1, [0; 32], 1, &[], 0, None, 1),
    ));
    let seventeen: Vec<(Vec<u8>, [u8; 32])> = (0..17u8)
        .map(|i| {
            (
                format!("dev_{i:02}").into_bytes(),
                SigningKey::from_bytes(&[i + 1; 32])
                    .verifying_key()
                    .to_bytes(),
            )
        })
        .collect();
    let seventeen_refs: Vec<(&[u8], [u8; 32])> = seventeen
        .iter()
        .map(|(id, key)| (id.as_slice(), *key))
        .collect();
    cases.push(malformed(
        "17 entries",
        raw_body(ACCOUNT, 1, [0; 32], 6, &seventeen_refs, 0, None, 1),
    ));
    cases.push(malformed(
        "entries not sorted",
        raw_body(
            ACCOUNT,
            1,
            [0; 32],
            6,
            &[key(&cast.b), key(&cast.a)],
            0,
            None,
            1,
        ),
    ));
    cases.push(malformed(
        "device id repeated",
        raw_body(
            ACCOUNT,
            1,
            [0; 32],
            6,
            &[(cast.a.id, cast.a.public()), (cast.a.id, cast.b.public())],
            0,
            None,
            1,
        ),
    ));
    cases.push(malformed(
        "signing key repeated",
        raw_body(
            ACCOUNT,
            1,
            [0; 32],
            6,
            &[(cast.a.id, cast.a.public()), (cast.b.id, cast.a.public())],
            0,
            None,
            1,
        ),
    ));
    cases.push(malformed(
        "empty device id",
        raw_body(
            ACCOUNT,
            1,
            [0; 32],
            1,
            &[(&b""[..], cast.a.public())],
            0,
            None,
            1,
        ),
    ));
    cases.push(malformed(
        "empty account id",
        raw_body(b"", 1, [0; 32], 1, &[key(&cast.a)], 0, None, 1),
    ));
    let long_id = [b'd'; 129];
    cases.push(malformed(
        "device id over 128 bytes",
        raw_body(
            ACCOUNT,
            1,
            [0; 32],
            1,
            &[(&long_id[..], cast.a.public())],
            0,
            None,
            1,
        ),
    ));
    cases.push(malformed(
        "has_recovery 2",
        raw_body(ACCOUNT, 1, [0; 32], 1, &[key(&cast.a)], 2, Some(rk1), 1),
    ));
    cases.push(malformed(
        "has_recovery 1 without a key",
        raw_body(ACCOUNT, 1, [0; 32], 1, &[key(&cast.a)], 1, None, 1),
    ));
    cases.push(malformed(
        "small-order signing key",
        raw_body(
            ACCOUNT,
            1,
            [0; 32],
            1,
            &[(cast.a.id, IDENTITY_POINT)],
            0,
            None,
            1,
        ),
    ));
    cases.push(malformed(
        "signing key that is not a point",
        raw_body(
            ACCOUNT,
            1,
            [0; 32],
            1,
            &[(cast.a.id, invalid_point())],
            0,
            None,
            1,
        ),
    ));
    cases.push(malformed(
        "small-order recovery key",
        raw_body(
            ACCOUNT,
            2,
            [1; 32],
            5,
            &[key(&cast.a)],
            1,
            Some(IDENTITY_POINT),
            1,
        ),
    ));
    // Whole-statement shape.
    let v1 = a.statements[0].clone();
    let mut trailing = v1.clone();
    trailing.push(0);
    cases.push(refusal(
        "trailing byte",
        None,
        trailing,
        &[],
        L1Error::Malformed,
    ));
    cases.push(refusal(
        "truncated signature",
        None,
        v1[..v1.len() - 1].to_vec(),
        &[],
        L1Error::Malformed,
    ));
    cases.push(refusal(
        "statement over 4096 bytes",
        None,
        {
            let mut long = v1.clone();
            long.resize(MAX_STATEMENT_BYTES + 1, 0);
            long
        },
        &[],
        L1Error::Malformed,
    ));
    let body1 = a.at(1).body_bytes().to_vec();
    cases.push(refusal(
        "signer kind 3",
        None,
        raw_statement(&body1, 3, cast.a.id, sig),
        &[],
        L1Error::Malformed,
    ));
    cases.push(refusal(
        "recovery signer with a device id",
        None,
        raw_statement(&body1, 2, cast.a.id, sig),
        &[],
        L1Error::Malformed,
    ));
    cases.push(refusal(
        "device signer with no id",
        None,
        raw_statement(&body1, 1, b"", sig),
        &[],
        L1Error::Malformed,
    ));

    // ---- chain -----------------------------------------------------------
    let (p1, p2, p3, p5) = (
        &a.statements[0],
        &a.statements[1],
        &a.statements[2],
        &a.statements[4],
    );
    let (s1, s2, s3, s4, s5) = (a.at(1), a.at(2), a.at(3), a.at(4), a.at(5));
    let hist_p2 = history_of(&[&s1, &s2]);
    let hist_p3 = history_of(&[&s1, &s2, &s3]);
    let hist_p5 = history_of(&[&s1, &s2, &s3, &s4, &s5]);
    let _ = p3;
    let add_c = |version: u64, prev: &Statement, signer: &Actor| {
        let body = body_of(
            Change::Add,
            version,
            Some(prev),
            t,
            entries(&[&cast.a, &cast.b, &cast.c]),
            None,
        );
        by_device(&body, signer)
    };
    let mut other_account = body_of(
        Change::Add,
        3,
        Some(&s2),
        t,
        entries(&[&cast.a, &cast.b, &cast.c]),
        None,
    );
    other_account.account_id = OTHER_ACCOUNT.to_vec();
    cases.push(refusal(
        "wrong account",
        Some(p2),
        by_device(&other_account, &cast.a),
        &hist_p2,
        L1Error::Chain,
    ));
    cases.push(refusal(
        "version gap",
        Some(p2),
        add_c(4, &s2, &cast.a),
        &hist_p2,
        L1Error::Chain,
    ));
    cases.push(refusal(
        "same version again (rollback)",
        Some(p2),
        add_c(2, &s2, &cast.a),
        &hist_p2,
        L1Error::Chain,
    ));
    cases.push(refusal(
        "lower version (rollback)",
        Some(p3),
        by_device(
            &body_of(
                Change::Add,
                2,
                Some(&s1),
                t,
                entries(&[&cast.a, &cast.b]),
                None,
            ),
            &cast.a,
        ),
        &hist_p3,
        L1Error::Chain,
    ));
    cases.push(refusal(
        "wrong prev_hash (fork)",
        Some(p2),
        add_c(3, &s1, &cast.a),
        &hist_p2,
        L1Error::Chain,
    ));
    cases.push(refusal(
        "genesis after a genesis (new genesis)",
        Some(p1),
        by_device(
            &body_of(Change::Genesis, 1, None, t, entries(&[&cast.b]), None),
            &cast.b,
        ),
        &[],
        L1Error::Chain,
    ));
    cases.push(refusal(
        "add with no previous version",
        None,
        add_c(3, &s2, &cast.a),
        &[],
        L1Error::Chain,
    ));

    // ---- rule ------------------------------------------------------------
    let with = |change: Change,
                version: u64,
                prev: &Statement,
                list: &[&Actor],
                recovery: Option<[u8; 32]>| {
        body_of(change, version, Some(prev), t, entries(list), recovery)
    };
    cases.push(refusal(
        "add by a device that is not listed",
        Some(p2),
        by_device(
            &with(Change::Add, 3, &s2, &[&cast.a, &cast.b, &cast.c], None),
            &cast.outsider,
        ),
        &hist_p2,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "add of two devices at once",
        Some(p2),
        by_device(
            &with(
                Change::Add,
                3,
                &s2,
                &[&cast.a, &cast.b, &cast.c, &cast.d],
                None,
            ),
            &cast.a,
        ),
        &hist_p2,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "add that also drops the signer",
        Some(p2),
        by_device(
            &with(Change::Add, 3, &s2, &[&cast.b, &cast.c], None),
            &cast.a,
        ),
        &hist_p2,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "add that swaps a device instead of adding one",
        Some(p2),
        by_device(
            &with(Change::Add, 3, &s2, &[&cast.a, &cast.c], None),
            &cast.a,
        ),
        &hist_p2,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "add that changes the recovery key",
        Some(p2),
        by_device(
            &with(Change::Add, 3, &s2, &[&cast.a, &cast.b, &cast.c], Some(rk1)),
            &cast.a,
        ),
        &hist_p2,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "add signed by the recovery key",
        Some(p3),
        by_recovery(
            &with(Change::Add, 4, &s3, &[&cast.a, &cast.b, &cast.c], Some(rk1)),
            &K0_ENTROPY,
        ),
        &hist_p3,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "add of a removed device (no return, same id and key)",
        Some(p5),
        by_device(
            &with(Change::Add, 6, &s5, &[&cast.a, &cast.b, &cast.c], Some(rk1)),
            &cast.a,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    let b_new_key = Actor {
        id: cast.b.id,
        key: SigningKey::from_bytes(&[0x77; 32]),
    };
    cases.push(refusal(
        "add of a removed device id with a new key (no return)",
        Some(p5),
        by_device(
            &with(
                Change::Add,
                6,
                &s5,
                &[&cast.a, &b_new_key, &cast.c],
                Some(rk1),
            ),
            &cast.a,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    let b_new_id = Actor {
        id: b"dev_b9b9b9b9b9b9b9b9",
        key: cast.b.key.clone(),
    };
    cases.push(refusal(
        "add of a removed key under a new device id (no return)",
        Some(p5),
        by_device(
            &with(
                Change::Add,
                6,
                &s5,
                &[&cast.a, &b_new_id, &cast.c],
                Some(rk1),
            ),
            &cast.a,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "remove by a device that is not listed",
        Some(p5),
        by_device(
            &with(Change::Remove, 6, &s5, &[&cast.a], Some(rk1)),
            &cast.outsider,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "remove that removes nothing",
        Some(p5),
        by_device(
            &with(Change::Remove, 6, &s5, &[&cast.a, &cast.c], Some(rk1)),
            &cast.a,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "remove that also adds a device",
        Some(p5),
        by_device(
            &with(Change::Remove, 6, &s5, &[&cast.d], Some(rk1)),
            &cast.a,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "remove that changes the recovery key",
        Some(p5),
        by_device(
            &with(Change::Remove, 6, &s5, &[&cast.a], Some(rk2)),
            &cast.a,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "remove signed by the recovery key",
        Some(p5),
        by_recovery(
            &with(Change::Remove, 6, &s5, &[&cast.a], Some(rk1)),
            &K0_ENTROPY,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "recovery signed by a device",
        Some(p5),
        by_device(
            &with(Change::Recovery, 6, &s5, &[&cast.d], Some(rk1)),
            &cast.a,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "recovery when the head has no recovery key",
        Some(p2),
        by_recovery(
            &with(Change::Recovery, 3, &s2, &[&cast.d], None),
            &K0_ENTROPY,
        ),
        &hist_p2,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "recovery that lists two devices",
        Some(p5),
        by_recovery(
            &with(Change::Recovery, 6, &s5, &[&cast.d, &cast.e], Some(rk1)),
            &K0_ENTROPY,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "recovery that lists a device the chain had",
        Some(p5),
        by_recovery(
            &with(Change::Recovery, 6, &s5, &[&cast.b], Some(rk1)),
            &K0_ENTROPY,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "recovery that changes the recovery key",
        Some(p5),
        by_recovery(
            &with(Change::Recovery, 6, &s5, &[&cast.d], Some(rk2)),
            &K0_ENTROPY,
        ),
        &hist_p5,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "recovery key change by a device that is not listed",
        Some(p3),
        by_device(
            &with(Change::RecoveryKey, 4, &s3, &[&cast.a, &cast.b], Some(rk2)),
            &cast.outsider,
        ),
        &hist_p3,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "recovery key change that changes nothing",
        Some(p3),
        by_device(
            &with(Change::RecoveryKey, 4, &s3, &[&cast.a, &cast.b], Some(rk1)),
            &cast.a,
        ),
        &hist_p3,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "recovery key change that also changes the devices",
        Some(p3),
        by_device(
            &with(Change::RecoveryKey, 4, &s3, &[&cast.a], Some(rk2)),
            &cast.a,
        ),
        &hist_p3,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "recovery key change signed by the recovery key",
        Some(p3),
        by_recovery(
            &with(Change::RecoveryKey, 4, &s3, &[&cast.a, &cast.b], Some(rk2)),
            &K0_ENTROPY,
        ),
        &hist_p3,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "genesis with two devices",
        None,
        by_device(
            &body_of(
                Change::Genesis,
                1,
                None,
                t,
                entries(&[&cast.a, &cast.b]),
                None,
            ),
            &cast.a,
        ),
        &[],
        L1Error::Rule,
    ));
    cases.push(refusal(
        "genesis with a recovery key",
        None,
        by_device(
            &body_of(Change::Genesis, 1, None, t, entries(&[&cast.a]), Some(rk1)),
            &cast.a,
        ),
        &[],
        L1Error::Rule,
    ));
    cases.push(refusal(
        "genesis signed by a device it does not list",
        None,
        by_device(
            &body_of(Change::Genesis, 1, None, t, entries(&[&cast.a]), None),
            &cast.b,
        ),
        &[],
        L1Error::Rule,
    ));
    cases.push(refusal(
        "genesis signed by the recovery key",
        None,
        by_recovery(
            &body_of(Change::Genesis, 1, None, t, entries(&[&cast.a]), None),
            &K0_ENTROPY,
        ),
        &[],
        L1Error::Rule,
    ));
    cases.push(refusal(
        "migration genesis signed by a device it does not list",
        None,
        by_device(
            &body_of(
                Change::MigrationGenesis,
                1,
                None,
                t,
                entries(&[&cast.a, &cast.b]),
                None,
            ),
            &cast.c,
        ),
        &[],
        L1Error::Rule,
    ));

    // ---- signature -------------------------------------------------------
    let flip = |mut bytes: Vec<u8>, offset: usize| {
        let at = bytes.len() - offset;
        bytes[at] ^= 1;
        bytes
    };
    let honest_add = by_device(
        &with(Change::Add, 3, &s2, &[&cast.a, &cast.b, &cast.c], None),
        &cast.a,
    );
    cases.push(refusal(
        "signature bit flipped",
        Some(p2),
        flip(honest_add.clone(), 1),
        &hist_p2,
        L1Error::Signature,
    ));
    cases.push(refusal(
        "signature r bit flipped",
        Some(p2),
        flip(honest_add.clone(), 64),
        &hist_p2,
        L1Error::Signature,
    ));
    // S + L: the same signature with its scalar made non-canonical.
    let mut malleated = honest_add.clone();
    let s_at = malleated.len() - 32;
    add_group_order(&mut malleated[s_at..]);
    cases.push(refusal(
        "signature scalar not reduced (S + L)",
        Some(p2),
        malleated,
        &hist_p2,
        L1Error::Signature,
    ));
    cases.push(refusal(
        "signed by another listed device's key",
        Some(p2),
        sign_with(
            &encode_body(&with(
                Change::Add,
                3,
                &s2,
                &[&cast.a, &cast.b, &cast.c],
                None,
            ))
            .unwrap(),
            &Signer::Device(cast.a.id.to_vec()),
            &cast.b.key,
        ),
        &hist_p2,
        L1Error::Signature,
    ));
    cases.push(refusal(
        "signer id altered after signing (not listed)",
        Some(p2),
        {
            let mut bytes = honest_add.clone();
            // The signer id sits after the body, the kind byte and its length;
            // its last character becomes one no device has.
            let at = bytes.len() - 64 - 1;
            bytes[at] = b'z';
            bytes
        },
        &hist_p2,
        L1Error::Rule,
    ));
    cases.push(refusal(
        "signed as kind 2 but stated as kind 1",
        Some(p2),
        {
            let body = encode_body(&with(
                Change::Add,
                3,
                &s2,
                &[&cast.a, &cast.b, &cast.c],
                None,
            ))
            .unwrap();
            let message = signed_message(&body, &Signer::Recovery).unwrap();
            let signature = cast.a.key.sign(&message).to_bytes();
            assemble_statement(&body, &Signer::Device(cast.a.id.to_vec()), &signature).unwrap()
        },
        &hist_p2,
        L1Error::Signature,
    ));
    cases.push(refusal(
        "recovery statement signed by a device key",
        Some(p5),
        sign_with(
            &encode_body(&with(Change::Recovery, 6, &s5, &[&cast.d], Some(rk1))).unwrap(),
            &Signer::Recovery,
            &cast.a.key,
        ),
        &hist_p5,
        L1Error::Signature,
    ));
    cases.push(refusal(
        "recovery statement signed by the wrong recovery key",
        Some(p5),
        by_recovery(
            &with(Change::Recovery, 6, &s5, &[&cast.d], Some(rk1)),
            &SECOND_ENTROPY,
        ),
        &hist_p5,
        L1Error::Signature,
    ));
    cases.push(refusal(
        "genesis signature bit flipped",
        None,
        flip(a.statements[0].clone(), 1),
        &[],
        L1Error::Signature,
    ));
    cases.push(refusal(
        "body signed under the hash label instead of the signature label",
        None,
        {
            let body = encode_body(&body_of(
                Change::Genesis,
                1,
                None,
                t,
                entries(&[&cast.a]),
                None,
            ))
            .unwrap();
            let mut message = LABEL_HASH.to_vec();
            message.extend_from_slice(&Sha256::digest(&body));
            message.push(1);
            message.extend_from_slice(&(cast.a.id.len() as u16).to_be_bytes());
            message.extend_from_slice(cast.a.id);
            let signature = cast.a.key.sign(&message).to_bytes();
            assemble_statement(&body, &Signer::Device(cast.a.id.to_vec()), &signature).unwrap()
        },
        &[],
        L1Error::Signature,
    ));
    cases
}

/// Adds the Ed25519 group order L to a 32-byte little-endian scalar.
fn add_group_order(scalar: &mut [u8]) {
    const L: [u8; 32] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde,
        0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
    ];
    let mut carry = 0u16;
    for (byte, add) in scalar.iter_mut().zip(L) {
        let sum = u16::from(*byte) + u16::from(add) + carry;
        *byte = (sum & 0xff) as u8;
        carry = sum >> 8;
    }
    assert_eq!(carry, 0, "S + L must fit in 256 bits");
}

fn refused_json(cases: &[Refused]) -> Value {
    Value::Array(
        cases
            .iter()
            .map(|case| {
                json!({
                    "name": case.name,
                    "prev_hex": case.prev.as_ref().map(|bytes| hex(bytes)),
                    "statement_hex": hex(&case.statement),
                    "history": pairs_json(&case.history),
                    "error": case.error.name(),
                })
            })
            .collect(),
    )
}

/// Raw Ed25519 cases, to pin how the strict client verifier and Go's
/// `crypto/ed25519` differ. `server_accepts` is what Go's `Verify` answers
/// (checked by the Go test); every case a client accepts, the server must
/// accept.
fn edge_cases() -> Vec<Value> {
    let key = SigningKey::from_bytes(&[0x11; 32]);
    let public = key.verifying_key().to_bytes();
    let message = b"veritra-l1 edge case".to_vec();
    let signature = key.sign(&message).to_bytes();
    let mut high_s = signature;
    add_group_order(&mut high_s[32..]);
    let mut identity_signature = [0u8; 64];
    identity_signature[0] = 1;
    let mut wrong_message = message.clone();
    wrong_message[0] ^= 1;
    let case = |name: &str, public: [u8; 32], message: &[u8], signature: [u8; 64], server: bool| {
        let client = VerifyingKey::from_bytes(&public)
            .map(|key| {
                key.verify_strict(message, &Signature::from_bytes(&signature))
                    .is_ok()
            })
            .unwrap_or(false);
        json!({
            "name": name,
            "public_key_hex": hex(&public),
            "message_hex": hex(message),
            "signature_hex": hex(&signature),
            "client_accepts": client,
            "server_accepts": server,
        })
    };
    vec![
        case("valid signature", public, &message, signature, true),
        case("message changed", public, &wrong_message, signature, false),
        case(
            "scalar not reduced (S + L)",
            public,
            &message,
            high_s,
            false,
        ),
        case(
            "small-order key (identity) with R = identity and S = 0",
            IDENTITY_POINT,
            &message,
            identity_signature,
            true,
        ),
    ]
}

fn compute() -> Value {
    let cast = cast();
    let a = chain_a(&cast);
    let b = chain_b(&cast);
    let refused = refused_cases(&cast, &a);
    let devices: Vec<Value> = [&cast.a, &cast.b, &cast.c, &cast.d, &cast.e, &cast.outsider]
        .iter()
        .zip([0x11u8, 0x22, 0x33, 0x44, 0x55, 0x66])
        .map(|(actor, seed)| {
            json!({
                "device_id": String::from_utf8(actor.id.to_vec()).unwrap(),
                "signing_seed_hex": hex(&[seed; 32]),
                "signing_key_hex": hex(&actor.public()),
            })
        })
        .collect();
    json!({
        "version": 1,
        "description": "L1 approved-device list (docs/designs/L1-approved-device-list.md, step L1-1, ABI 14): VDL1 statements, the signature and hash labels, two valid chains (every change kind), single-fault refusals and Ed25519 edge cases. Every signing seed is a fixed test value. Checked by crypto/rust/src/l1_tests.rs, server/internal/httpapi/vdl1_vector_test.go and mobile/test/l1_device_list_native_test.dart. Changing any value is a protocol change. Regenerate: cargo test --lib l1::tests::print_vector -- --ignored --nocapture.",
        "labels": {
            "signature": String::from_utf8(LABEL_SIG.to_vec()).unwrap(),
            "hash": String::from_utf8(LABEL_HASH.to_vec()).unwrap(),
        },
        "inputs": {
            "account_id": String::from_utf8(ACCOUNT.to_vec()).unwrap(),
            "devices": devices,
            "recovery": [
                {"entropy_hex": hex(&K0_ENTROPY), "rk_list_pub_hex": hex(&list_public(&K0_ENTROPY)),
                 "list_seed_hex": hex(recovery::list_seed(&K0_ENTROPY).unwrap().as_slice())},
                {"entropy_hex": hex(&SECOND_ENTROPY), "rk_list_pub_hex": hex(&list_public(&SECOND_ENTROPY)),
                 "list_seed_hex": hex(recovery::list_seed(&SECOND_ENTROPY).unwrap().as_slice())},
            ],
        },
        "outputs": {
            "chains": [chain_json("A: every change except the migration genesis", &a), chain_json("B: migration genesis, remove, add", &b)],
            "refused": refused_json(&refused),
            "edge_cases": edge_cases(),
        },
    })
}

fn pairs_of(value: &Value) -> Vec<Pair> {
    value
        .as_array()
        .expect("pairs")
        .iter()
        .map(|pair| Pair {
            device_id: pair["device_id"].as_str().unwrap().as_bytes().to_vec(),
            signing_key: unhex(&pair["signing_key_hex"]).try_into().unwrap(),
        })
        .collect()
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
fn the_vector_chains_verify_step_by_step_and_whole() {
    let vector: Value = serde_json::from_str(VECTOR).unwrap();
    for chain in vector["outputs"]["chains"].as_array().unwrap() {
        let steps = chain["steps"].as_array().unwrap();
        let mut previous: Option<Statement> = None;
        let mut history: Vec<Pair> = Vec::new();
        for step in steps {
            let bytes = unhex(&step["statement_hex"]);
            let statement = parse_statement(&bytes).unwrap();
            assert_eq!(statement.raw(), bytes.as_slice());
            assert_eq!(statement.body.version, step["version"].as_u64().unwrap());
            assert_eq!(
                statement.body.change as u8,
                step["change"].as_u64().unwrap() as u8
            );
            assert_eq!(
                statement.list_hash().as_slice(),
                unhex(&step["list_hash_hex"])
            );
            assert_eq!(statement.body_bytes(), unhex(&step["body_hex"]).as_slice());
            // The signed message and signature the vector states are the ones
            // the code makes and verifies.
            assert_eq!(
                signed_message(statement.body_bytes(), &statement.signer).unwrap(),
                unhex(&step["signed_message_hex"])
            );
            assert_eq!(
                statement.signature.as_slice(),
                unhex(&step["signature_hex"])
            );
            assert_eq!(pairs_of(&step["entries"]), statement.body.entries);
            check_step(previous.as_ref(), &statement, &history).unwrap();
            // The history may also be empty: `prev` alone is enough for a
            // chain with no returns.
            if previous.is_some() {
                check_step(previous.as_ref(), &statement, &[]).unwrap();
            }
            for pair in &statement.body.entries {
                if !history.contains(pair) {
                    history.push(pair.clone());
                }
            }
            previous = Some(statement);
        }
        let statements = decode_chain(&unhex(&chain["chain_hex"])).unwrap();
        let result = check_chain(&statements).unwrap();
        assert_eq!(result.list_id.as_slice(), unhex(&chain["list_id_hex"]));
        assert_eq!(
            result.head.body.version,
            chain["head_version"].as_u64().unwrap()
        );
        let pairs = chain["pairs"].as_array().unwrap();
        assert_eq!(result.pairs.len(), pairs.len());
        for (listed, expected) in result.pairs.iter().zip(pairs) {
            assert_eq!(
                listed.pair.device_id,
                expected["device_id"].as_str().unwrap().as_bytes()
            );
            assert_eq!(
                listed.pair.signing_key.as_slice(),
                unhex(&expected["signing_key_hex"])
            );
            assert_eq!(
                listed.added_version,
                expected["added_version"].as_u64().unwrap()
            );
            assert_eq!(
                listed.removed_version,
                expected["removed_version"].as_u64().unwrap()
            );
        }
    }
}

#[test]
fn every_refusal_in_the_vector_is_refused_for_its_one_reason() {
    let vector: Value = serde_json::from_str(VECTOR).unwrap();
    let cases = vector["outputs"]["refused"].as_array().unwrap();
    assert!(cases.len() >= 60, "the vector must keep its coverage");
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let bytes = unhex(&case["statement_hex"]);
        let history = pairs_of(&case["history"]);
        let prev = case["prev_hex"]
            .as_str()
            .map(|_| parsed(&unhex(&case["prev_hex"])));
        let result = parse_statement(&bytes)
            .and_then(|statement| check_step(prev.as_ref(), &statement, &history));
        assert_eq!(
            result.map_err(L1Error::name),
            Err(case["error"].as_str().unwrap()),
            "case: {name}"
        );
    }
}

#[test]
fn the_edge_cases_pin_the_strict_verifier() {
    let vector: Value = serde_json::from_str(VECTOR).unwrap();
    for case in vector["outputs"]["edge_cases"].as_array().unwrap() {
        let public: [u8; 32] = unhex(&case["public_key_hex"]).try_into().unwrap();
        let signature: [u8; 64] = unhex(&case["signature_hex"]).try_into().unwrap();
        let accepted = VerifyingKey::from_bytes(&public)
            .map(|key| {
                key.verify_strict(
                    &unhex(&case["message_hex"]),
                    &Signature::from_bytes(&signature),
                )
                .is_ok()
            })
            .unwrap_or(false);
        assert_eq!(
            accepted,
            case["client_accepts"].as_bool().unwrap(),
            "{case}"
        );
        // The server must never refuse what an honest client signs.
        assert!(
            !case["client_accepts"].as_bool().unwrap() || case["server_accepts"].as_bool().unwrap()
        );
    }
}

#[test]
fn recovery_list_key_is_separate_from_the_claim_proof_key() {
    let derived = recovery::derive(&K0_ENTROPY).unwrap();
    assert_eq!(derived.rk_list_pub, list_public(&K0_ENTROPY));
    assert_ne!(derived.rk_list_pub, derived.rk_auth_pub);
    assert_ne!(derived.rk_list_pub, derived.rk_pub);
}

#[test]
fn labels_are_disjoint_from_the_other_signing_labels() {
    for other in [
        &b"veritra-enrollment-proof-v1"[..],
        b"veritra-device-link-enrollment-v3",
        b"veritra-k2-handoff-sig-v1",
        crate::c7::SIGN_DOMAIN_POST,
        crate::c7::SIGN_DOMAIN_HISTORY,
        recovery::PROOF_LABEL,
    ] {
        assert!(!LABEL_SIG.starts_with(other) && !other.starts_with(LABEL_SIG));
        assert!(!LABEL_HASH.starts_with(other) && !other.starts_with(LABEL_HASH));
    }
    assert!(!LABEL_SIG.starts_with(LABEL_HASH) && !LABEL_HASH.starts_with(LABEL_SIG));
}

#[test]
fn the_encoder_refuses_what_the_parser_refuses() {
    let cast = cast();
    let good = body_of(Change::Genesis, 1, None, 0, entries(&[&cast.a]), None);
    assert!(encode_body(&good).is_ok());
    let mut unsorted = body_of(
        Change::MigrationGenesis,
        1,
        None,
        0,
        vec![cast.b.pair(), cast.a.pair()],
        None,
    );
    assert_eq!(encode_body(&unsorted), Err(L1Error::Malformed));
    unsorted.entries.clear();
    assert_eq!(encode_body(&unsorted), Err(L1Error::Malformed));
}

#[test]
fn history_is_only_extra_exclusion_and_prev_always_counts() {
    // A removal's pair is excluded even when the caller's history is empty
    // for the pair that `prev` lists; and history alone excludes the rest.
    let cast = cast();
    let chain = chain_a(&cast);
    let s5 = chain.at(5);
    let readd_b = by_device(
        &body_of(
            Change::Add,
            6,
            Some(&s5),
            0,
            entries(&[&cast.a, &cast.b, &cast.c]),
            Some(list_public(&K0_ENTROPY)),
        ),
        &cast.a,
    );
    let readd_b = parsed(&readd_b);
    // Without history B is not known to have been removed: the caller must
    // pass it (the chain check does).
    assert_eq!(check_step(Some(&s5), &readd_b, &[]), Ok(()));
    let history = history_of(&[&chain.at(1), &chain.at(2), &chain.at(3), &chain.at(4), &s5]);
    assert_eq!(
        check_step(Some(&s5), &readd_b, &history),
        Err(L1Error::Rule)
    );
    // And check_chain, which builds the history itself, refuses the same.
    let mut statements: Vec<Statement> = (1..=5).map(|v| chain.at(v)).collect();
    statements.push(readd_b);
    assert_eq!(check_chain(&statements), Err(L1Error::Rule));
}

#[test]
fn a_chain_must_start_at_version_one_and_stay_in_bounds() {
    let cast = cast();
    let chain = chain_a(&cast);
    assert_eq!(check_chain(&[]), Err(L1Error::Malformed));
    let tail: Vec<Statement> = (2..=4).map(|v| chain.at(v)).collect();
    assert_eq!(check_chain(&tail), Err(L1Error::Chain));
    let mut out_of_order = vec![chain.at(1), chain.at(3)];
    assert_eq!(check_chain(&out_of_order), Err(L1Error::Chain));
    out_of_order.clear();
    assert!(decode_chain(&[0, 0]).is_err());
    assert!(decode_chain(&[0, 1, 0, 0]).is_err());
}

#[test]
fn summaries_and_pairs_round_trip() {
    let cast = cast();
    let chain = chain_a(&cast);
    let head = chain.last();
    let summary = encode_summary(&head).unwrap();
    assert_eq!(summary[0], 1);
    assert_eq!(summary[1], Change::Add as u8);
    let pairs = vec![cast.a.pair(), cast.b.pair()];
    let mut encoded = (pairs.len() as u16).to_be_bytes().to_vec();
    for pair in &pairs {
        encoded.extend_from_slice(&(pair.device_id.len() as u16).to_be_bytes());
        encoded.extend_from_slice(&pair.device_id);
        encoded.extend_from_slice(&pair.signing_key);
    }
    assert_eq!(decode_pairs(&encoded).unwrap(), pairs);
    assert_eq!(decode_pairs(&[]).unwrap(), vec![]);
    assert!(decode_pairs(&encoded[..encoded.len() - 1]).is_err());
    let mut trailing = encoded.clone();
    trailing.push(0);
    assert!(decode_pairs(&trailing).is_err());
}
