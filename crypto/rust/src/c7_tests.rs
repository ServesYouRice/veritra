use super::*;
use ed25519_dalek::{Signer, SigningKey};
use serde_json::{json, Value};

/// `testing/vectors/c7-primitives-v1.json`: known answers for the C7 crypto
/// primitives. Rust checks all of it; Dart checks the stateless calls
/// (`mobile/test/c7_primitives_test.dart`); the Go check arrives with the
/// server (`server/internal/c7vector`, step 3). The exporter root
/// itself cannot be pinned here (OpenMLS offers no way to start a group from
/// fixed secrets); `mls.rs` tests pin it as "the staged export equals the
/// post-merge export, in every group", and this file pins the label and
/// context bytes.
const VECTOR: &str = include_str!("../../../testing/vectors/c7-primitives-v1.json");

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

fn text(value: &Value) -> &[u8] {
    value.as_str().expect("string").as_bytes()
}

fn array<const N: usize>(value: &Value) -> [u8; N] {
    unhex(value).try_into().expect("length")
}

/// Every output of the vector, computed from its inputs alone.
fn compute(inputs: &Value) -> Value {
    let community = text(&inputs["community_id"]);
    let channel = text(&inputs["channel_id"]);
    let conversation = text(&inputs["conversation_id"]);
    let sender = text(&inputs["sender_device_id"]);
    let action = text(&inputs["action_id"]);
    let group = text(&inputs["group_id"]);
    let old_group = text(&inputs["old_group_id"]);
    let root = unhex(&inputs["root_hex"]);
    let signing = SigningKey::from_bytes(&array(&inputs["signing_seed_hex"]));
    let public = signing.verifying_key().to_bytes();

    // Keys.
    let chk = rekey_chk(&root, community, channel).unwrap();
    let chk = chk.as_slice();
    let body_key = post_body_key(chk, community, channel, sender, action).unwrap();
    let slot_key_value = slot_key(chk, community, channel, sender, action).unwrap();
    let previous_chk: [u8; 32] = array(&inputs["previous_chk_hex"]);

    // A sealed body.
    let aad = body_aad(conversation, channel, sender, action).unwrap();
    let plaintext = unhex(&inputs["body_plaintext_hex"]);
    let nonce: [u8; 12] = array(&inputs["body_nonce_hex"]);
    let sealed = seal_with_nonce(body_key.as_slice(), nonce, &aad, &plaintext).unwrap();

    // A post signature.
    let vap1_hash: [u8; 32] = Sha256::digest(unhex(&inputs["padded_vap1_hex"])).into();
    let post_fields = post_signed_fields(
        community,
        channel,
        action,
        group,
        inputs["epoch"].as_u64().unwrap(),
        sender,
        inputs["generation"].as_u64().unwrap(),
        &vap1_hash,
    )
    .unwrap();
    let post_input = signing_input(SIGN_DOMAIN_POST, &post_fields).unwrap();
    let post_signature = signing.sign(&post_input).to_bytes();

    // A full record, signed.
    let mut record = HistoryRecord {
        community_id: community.to_vec(),
        channel_id: channel.to_vec(),
        seq: inputs["seq"].as_u64().unwrap() as u32,
        prev: array(&inputs["prev_hex"]),
        mode: MODE_FULL,
        reason: REASON_SWITCH,
        group_id: group.to_vec(),
        epoch: inputs["epoch"].as_u64().unwrap(),
        close_group_id: group.to_vec(),
        close_epoch: inputs["epoch"].as_u64().unwrap(),
        chk_commit: chk_commit(chk).unwrap(),
        actor_device_id: sender.to_vec(),
        sig: [0; 64],
    };
    let record_input =
        signing_input(SIGN_DOMAIN_HISTORY, &record.signed_fields().unwrap()).unwrap();
    record.sig = signing.sign(&record_input).to_bytes();
    let full = record.encode().unwrap();

    // The same record as a proposal, and a move.
    let compact = CompactRecord {
        seq: record.seq,
        prev: record.prev,
        mode: MODE_FULL,
        reason: REASON_SWITCH,
        close_epoch: record.close_epoch,
        key: chk.try_into().unwrap(),
        sig: record.sig,
        moved: None,
    };
    let context = RecordContext {
        community_id: community,
        channel_id: channel,
        group_id: group,
        epoch: record.epoch,
        actor_device_id: sender,
    };
    let expands = compact.expand(&context).unwrap() == record;
    let moved = CompactRecord {
        reason: REASON_MOVE,
        moved: Some((old_group.to_vec(), [0xAB; MOVE_WRAP_BYTES])),
        ..compact.clone()
    };

    // A generation entry and a sealed slot.
    let entry = GenerationEntry {
        epoch: inputs["epoch"].as_u64().unwrap(),
        key_commit: chk_commit(chk).unwrap(),
        previous: Some((inputs["previous_epoch"].as_u64().unwrap(), previous_chk)),
    };
    let entry_bytes = entry.encode();
    let plain = slot_plain(&full, &entry_bytes).unwrap();
    let slot_nonce: [u8; 12] = array(&inputs["slot_nonce_hex"]);
    let slot = seal_with_nonce(slot_key_value.as_slice(), slot_nonce, &aad, &plain).unwrap();

    let lengths: Vec<Value> = [1usize, 2, 30, 500, 508]
        .iter()
        .map(|n| {
            json!({
                "channels": n,
                "body0_padded": body0_padded_len(*n).unwrap(),
                "history_sync_body": history_sync_body_len(*n).unwrap(),
            })
        })
        .collect();

    json!({
        "chk_hex": hex(chk),
        "body_key_hex": hex(body_key.as_slice()),
        "slot_key_hex": hex(slot_key_value.as_slice()),
        "chk_commit_hex": hex(&chk_commit(chk).unwrap()),
        "body_aad_hex": hex(&aad),
        "sealed_body_hex": hex(&sealed),
        "exporter_label": EXPORTER_LABEL,
        "exporter_context_hex": hex(&exporter_context(group, inputs["epoch"].as_u64().unwrap()).unwrap()),
        "signing_public_key_hex": hex(&public),
        "post_signed_fields_hex": hex(&post_fields),
        "post_signature_hex": hex(&post_signature),
        "record_signed_fields_hex": hex(&record.signed_fields().unwrap()),
        "record_full_hex": hex(&full),
        "record_hash_hex": hex(&record.hash().unwrap()),
        "record_compact_hex": hex(&compact.encode().unwrap()),
        "record_compact_expands_to_full": expands,
        "record_move_compact_hex": hex(&moved.encode().unwrap()),
        "generation_entry_hex": hex(&entry_bytes),
        "zero_generation_entry_hex": hex(&[0u8; ENTRY_BYTES]),
        "slot_plain_hex": hex(&plain),
        "slot_hex": hex(&slot),
        "lengths": lengths,
    })
}

#[test]
fn vector_matches() {
    let vector: Value = serde_json::from_str(VECTOR).expect("vector parses");
    assert_eq!(compute(&vector["inputs"]), vector["outputs"]);
}

#[test]
fn vector_values_open_and_verify_independently() {
    let vector: Value = serde_json::from_str(VECTOR).expect("vector parses");
    let (inputs, outputs) = (&vector["inputs"], &vector["outputs"]);
    let aad = unhex(&outputs["body_aad_hex"]);
    let opened = open(
        &unhex(&outputs["body_key_hex"]),
        &aad,
        &unhex(&outputs["sealed_body_hex"]),
    )
    .unwrap();
    assert_eq!(opened.as_slice(), unhex(&inputs["body_plaintext_hex"]));
    // The slot opens under its key and holds the record then the entry.
    let slot = open(
        &unhex(&outputs["slot_key_hex"]),
        &aad,
        &unhex(&outputs["slot_hex"]),
    )
    .unwrap();
    assert_eq!(slot.as_slice(), unhex(&outputs["slot_plain_hex"]));
    // Signatures verify with the public key and no other domain.
    let key = unhex(&outputs["signing_public_key_hex"]);
    assert!(verify(
        SIGN_DOMAIN_POST,
        &key,
        &unhex(&outputs["post_signed_fields_hex"]),
        &unhex(&outputs["post_signature_hex"])
    )
    .unwrap());
    assert!(!verify(
        SIGN_DOMAIN_HISTORY,
        &key,
        &unhex(&outputs["post_signed_fields_hex"]),
        &unhex(&outputs["post_signature_hex"])
    )
    .unwrap());
    let record = HistoryRecord::decode(&unhex(&outputs["record_full_hex"])).unwrap();
    assert!(verify(
        SIGN_DOMAIN_HISTORY,
        &key,
        &record.signed_fields().unwrap(),
        &record.sig
    )
    .unwrap());
    // Sizes stated in the design.
    assert_eq!(unhex(&outputs["record_full_hex"]).len(), 512);
    assert_eq!(unhex(&outputs["record_compact_hex"]).len(), 143);
    assert_eq!(unhex(&outputs["generation_entry_hex"]).len(), 128);
    assert_eq!(unhex(&outputs["slot_hex"]).len(), 700);
    let lengths = outputs["lengths"].as_array().unwrap();
    let at = |n: u64| {
        lengths
            .iter()
            .find(|entry| entry["channels"] == n)
            .unwrap()
            .clone()
    };
    assert_eq!(at(500)["body0_padded"], 64_512);
    assert_eq!(at(500)["history_sync_body"], 414_636);
    assert_eq!(at(30)["history_sync_body"], 25_476);
    assert_eq!(at(508)["body0_padded"], 65_536);
}

/// Prints a fresh vector from the inputs in the file. Run by hand when the
/// encodings change on purpose (and bump the vector's version):
/// `cargo test --lib c7::tests::print_vector -- --ignored --nocapture`
#[test]
#[ignore]
fn print_vector() {
    let vector: Value = serde_json::from_str(VECTOR).expect("vector parses");
    let inputs = vector["inputs"].clone();
    let outputs = compute(&inputs);
    let document = json!({
        "version": vector["version"],
        "description": vector["description"],
        "inputs": inputs,
        "outputs": outputs,
    });
    println!("{}", serde_json::to_string_pretty(&document).unwrap());
}

// ---- derive ----------------------------------------------------------------

#[test]
fn derive_takes_only_listed_labels_and_exact_keys() {
    let key = [7u8; 32];
    for label in DERIVE_LABELS {
        assert_eq!(derive(&key, label, b"info").unwrap().as_slice().len(), 32);
    }
    // The encryption and commitment labels stay inside seal and open.
    assert_eq!(
        derive(&key, LABEL_ENC, b"").err(),
        Some(C7Error::InvalidInput)
    );
    assert_eq!(
        derive(&key, LABEL_KC, b"").err(),
        Some(C7Error::InvalidInput)
    );
    assert_eq!(
        derive(&key, b"veritra-c7-other-v1", b"x").err(),
        Some(C7Error::InvalidInput)
    );
    assert_eq!(
        derive(&key[..31], LABEL_POST, b"x").err(),
        Some(C7Error::InvalidInput)
    );
    assert_eq!(
        derive(&key, LABEL_POST, &[0u8; MAX_INFO_BYTES + 1]).err(),
        Some(C7Error::InvalidInput)
    );
}

#[test]
fn derived_keys_are_separated_by_label_key_and_every_context_field() {
    let chk = [3u8; 32];
    let base = post_body_key(&chk, b"com", b"chan", b"dev", b"act").unwrap();
    let same = post_body_key(&chk, b"com", b"chan", b"dev", b"act").unwrap();
    assert_eq!(base.as_slice(), same.as_slice());
    let mut seen = vec![base.as_slice().to_vec()];
    for key in [
        post_body_key(&[4u8; 32], b"com", b"chan", b"dev", b"act").unwrap(),
        post_body_key(&chk, b"cox", b"chan", b"dev", b"act").unwrap(),
        post_body_key(&chk, b"com", b"chax", b"dev", b"act").unwrap(),
        post_body_key(&chk, b"com", b"chan", b"dex", b"act").unwrap(),
        post_body_key(&chk, b"com", b"chan", b"dev", b"acx").unwrap(),
        // The same context under the slot label is another key.
        slot_key(&chk, b"com", b"chan", b"dev", b"act").unwrap(),
    ] {
        assert!(!seen.contains(&key.as_slice().to_vec()));
        seen.push(key.as_slice().to_vec());
    }
    // Length prefixes keep field boundaries: "ab"+"c" is not "a"+"bc".
    assert_ne!(
        post_body_key(&chk, b"ab", b"c", b"dev", b"act")
            .unwrap()
            .as_slice(),
        post_body_key(&chk, b"a", b"bc", b"dev", b"act")
            .unwrap()
            .as_slice()
    );
    assert_ne!(
        rekey_chk(&chk, b"ab", b"c").unwrap().as_slice(),
        rekey_chk(&chk, b"a", b"bc").unwrap().as_slice()
    );
    // A record's ids are 1 to 64 bytes.
    assert!(post_body_key(&chk, b"", b"chan", b"dev", b"act").is_err());
    assert!(post_body_key(&chk, &[b'x'; 65], b"chan", b"dev", b"act").is_err());
    assert!(post_body_key(&chk, &[b'x'; 64], b"chan", b"dev", b"act").is_ok());
}

#[test]
fn message_info_uses_u16_big_endian_prefixes() {
    assert_eq!(
        message_info(b"ab", b"c", b"d", b"e").unwrap(),
        [0, 2, b'a', b'b', 0, 1, b'c', 0, 1, b'd', 0, 1, b'e']
    );
    assert_eq!(
        exporter_context(b"grp", 0x0102_0304_0506_0708).unwrap(),
        [0, 3, b'g', b'r', b'p', 1, 2, 3, 4, 5, 6, 7, 8]
    );
    // The aad's channel id may be empty (a group-level message).
    assert_eq!(
        body_aad(b"c", b"", b"d", b"a").unwrap(),
        [0, 1, b'c', 0, 0, 0, 1, b'd', 0, 1, b'a']
    );
    assert!(exporter_context(b"", 1).is_err());
    assert!(exporter_context(&[1u8; 128], 1).is_ok());
    assert!(exporter_context(&[1u8; 129], 1).is_err());
}

#[test]
fn chk_commit_is_a_domain_separated_hash_of_the_key() {
    let key = [9u8; 32];
    let mut expected = Sha256::new();
    expected.update(b"veritra-c7-chk-v1");
    expected.update(key);
    assert_eq!(
        chk_commit(&key).unwrap().as_slice(),
        expected.finalize().as_slice()
    );
    assert_ne!(chk_commit(&key).unwrap(), chk_commit(&[8u8; 32]).unwrap());
    assert!(chk_commit(&key[..31]).is_err());
}

// ---- seal and open ----------------------------------------------------------

#[test]
fn seal_open_round_trip_and_framing() {
    let key = [1u8; 32];
    let sealed = seal(&key, b"aad", b"hello").unwrap();
    assert_eq!(sealed.len(), SEAL_OVERHEAD + 5);
    assert_eq!(open(&key, b"aad", &sealed).unwrap().as_slice(), b"hello");
    // The first 32 bytes are the commitment, whatever the message.
    assert_eq!(
        &sealed[..32],
        &seal(&key, b"other", b"other text").unwrap()[..32]
    );
    // A random nonce: two seals of one message differ.
    assert_ne!(sealed, seal(&key, b"aad", b"hello").unwrap());
    assert!(key_matches(&key, &sealed).unwrap());
    assert!(!key_matches(&[2u8; 32], &sealed).unwrap());
}

#[test]
fn open_checks_the_commitment_first_and_reports_which_check_failed() {
    let key = [1u8; 32];
    let sealed = seal(&key, b"aad", b"hello").unwrap();
    // Another key: a mismatch, not an authentication failure.
    assert_eq!(
        open(&[2u8; 32], b"aad", &sealed).err(),
        Some(C7Error::KeyMismatch)
    );
    // A flipped commitment bit is a mismatch too.
    let mut flipped = sealed.clone();
    flipped[0] ^= 1;
    assert_eq!(
        open(&key, b"aad", &flipped).err(),
        Some(C7Error::KeyMismatch)
    );
    // A matching commitment with anything else altered fails to authenticate.
    for index in [HASH_BYTES, HASH_BYTES + NONCE_BYTES, sealed.len() - 1] {
        let mut altered = sealed.clone();
        altered[index] ^= 1;
        assert_eq!(
            open(&key, b"aad", &altered).err(),
            Some(C7Error::Authentication)
        );
    }
    assert_eq!(
        open(&key, b"other aad", &sealed).err(),
        Some(C7Error::Authentication)
    );
    // Short, empty and oversized inputs are invalid, not panics.
    assert_eq!(
        open(&key, b"aad", &sealed[..SEAL_OVERHEAD - 1]).err(),
        Some(C7Error::InvalidInput)
    );
    assert_eq!(
        open(&key, &[0u8; MAX_AAD_BYTES + 1], &sealed).err(),
        Some(C7Error::InvalidInput)
    );
    assert_eq!(
        open(&key[..31], b"aad", &sealed).err(),
        Some(C7Error::InvalidInput)
    );
}

#[test]
fn seal_accepts_the_largest_body_and_refuses_more() {
    let key = [1u8; 32];
    let largest = vec![5u8; MAX_PLAINTEXT_BYTES];
    let sealed = seal(&key, b"aad", &largest).unwrap();
    assert_eq!(sealed.len(), SEAL_OVERHEAD + MAX_PLAINTEXT_BYTES);
    assert_eq!(open(&key, b"aad", &sealed).unwrap().as_slice(), largest);
    assert_eq!(
        seal(&key, b"aad", &vec![5u8; MAX_PLAINTEXT_BYTES + 1]).err(),
        Some(C7Error::InvalidInput)
    );
    // An empty plaintext seals (the FFI refuses empty slices, Rust does not).
    assert_eq!(seal(&key, b"", b"").unwrap().len(), SEAL_OVERHEAD);
}

#[test]
fn two_keys_never_open_one_sealed_body() {
    // The commitment is a hash of the key: a body sealed under one key is
    // not accepted under another, so no body has two readings.
    let (a, b) = ([1u8; 32], [2u8; 32]);
    let sealed = seal(&a, b"aad", b"text").unwrap();
    assert!(open(&a, b"aad", &sealed).is_ok());
    assert!(open(&b, b"aad", &sealed).is_err());
}

// ---- history_sync pieces ----------------------------------------------------

#[test]
fn history_sync_sizes_match_the_design() {
    assert_eq!(body0_padded_len(1).unwrap(), 768);
    assert_eq!(body0_padded_len(2).unwrap(), 768);
    assert_eq!(body0_padded_len(3).unwrap(), 1024);
    assert_eq!(body0_padded_len(30).unwrap(), 4352);
    assert_eq!(body0_padded_len(500).unwrap(), 64_512);
    assert_eq!(body0_padded_len(508).unwrap(), 65_536);
    assert!(body0_padded_len(0).is_err());
    assert!(body0_padded_len(509).is_err());
    assert_eq!(history_sync_body_len(30).unwrap(), 25_476);
    assert_eq!(history_sync_body_len(500).unwrap(), 414_636);
    assert_eq!(SLOT_BYTES, 700);
    // Every valid N maps back from its length, and nothing else does.
    for n in 1..=508 {
        let len = history_sync_body_len(n).unwrap();
        assert_eq!(history_sync_channel_count(len), Some(n));
        assert_eq!(history_sync_channel_count(len + 1), None);
        assert_eq!(history_sync_channel_count(len - 1), None);
    }
    assert_eq!(history_sync_channel_count(0), None);
    assert_eq!(
        history_sync_channel_count(history_sync_body_len(508).unwrap() + 700),
        None
    );
}

#[test]
fn generation_entries_round_trip_and_refuse_loose_bytes() {
    let entry = GenerationEntry {
        epoch: 20,
        key_commit: [4u8; 32],
        previous: Some((10, [5u8; 32])),
    };
    let bytes = entry.encode();
    assert_eq!(bytes.len(), 128);
    assert_eq!(&bytes[..8], &20u64.to_be_bytes());
    assert_eq!(GenerationEntry::decode(&bytes).unwrap(), Some(entry));
    // No wrap: the first generation of a period.
    let first = GenerationEntry {
        epoch: 10,
        key_commit: [4u8; 32],
        previous: None,
    };
    assert_eq!(&first.encode()[40..80], &[0u8; 40]);
    assert_eq!(
        GenerationEntry::decode(&first.encode()).unwrap(),
        Some(first.clone())
    );
    // Epoch 0 is a real previous epoch; a zero key is what marks "no wrap".
    let zero_epoch = GenerationEntry {
        epoch: 1,
        key_commit: [4u8; 32],
        previous: Some((0, [5u8; 32])),
    };
    assert_eq!(
        GenerationEntry::decode(&zero_epoch.encode()).unwrap(),
        Some(zero_epoch)
    );
    // The zero entry (a random slot's plaintext tail) is no entry.
    assert_eq!(GenerationEntry::decode(&[0u8; 128]).unwrap(), None);
    // Loose bytes: padding, a zero key under an epoch, a wrong length.
    let mut padded = bytes;
    padded[100] = 1;
    assert!(GenerationEntry::decode(&padded).is_err());
    let mut stray = first.encode();
    stray[47] = 1;
    assert!(GenerationEntry::decode(&stray).is_err());
    assert!(GenerationEntry::decode(&[0u8; 127]).is_err());
}

fn ids() -> (&'static [u8], &'static [u8], &'static [u8], &'static [u8]) {
    (b"comm", b"chan", b"dev_sender", b"action_1")
}

#[test]
fn slots_open_only_under_their_key_channel_sender_and_action() {
    let (community, channel, sender, action) = ids();
    let key_c = [6u8; 32];
    let aad = body_aad(b"conv_1", channel, sender, action).unwrap();
    let plain = slot_plain(&[1u8; RECORD_BYTES], &[2u8; ENTRY_BYTES]).unwrap();
    let slot = slot_seal(&key_c, community, channel, sender, action, &aad, &plain).unwrap();
    assert_eq!(slot.len(), SLOT_BYTES);
    assert_eq!(
        slot_open(&key_c, community, channel, sender, action, &aad, &slot)
            .unwrap()
            .as_slice(),
        plain
    );
    // A candidate key that is not the slot's key is a mismatch.
    assert_eq!(
        slot_open(&[7u8; 32], community, channel, sender, action, &aad, &slot).err(),
        Some(C7Error::KeyMismatch)
    );
    // The slot key binds channel, sender and action: another binding
    // derives another key, which the commitment rejects.
    for (c, d, a) in [
        (&b"chax"[..], sender, action),
        (channel, &b"dev_other"[..], action),
        (channel, sender, &b"action_2"[..]),
    ] {
        assert_eq!(
            slot_open(&key_c, community, c, d, a, &aad, &slot).err(),
            Some(C7Error::KeyMismatch)
        );
    }
    // The aad is the envelope's: another aad fails authentication.
    assert_eq!(
        slot_open(&key_c, community, channel, sender, action, b"other", &slot).err(),
        Some(C7Error::Authentication)
    );
    // Wrong plaintext size and wrong slot size.
    assert!(slot_seal(
        &key_c,
        community,
        channel,
        sender,
        action,
        &aad,
        &plain[1..]
    )
    .is_err());
    assert!(slot_open(&key_c, community, channel, sender, action, &aad, &slot[1..]).is_err());
    assert!(slot_plain(&[0u8; 511], &[0u8; 128]).is_err());
}

// ---- records ----------------------------------------------------------------

fn sample_record() -> HistoryRecord {
    HistoryRecord {
        community_id: vec![b'c'; 64],
        channel_id: vec![b'h'; 64],
        seq: 7,
        prev: [3u8; 32],
        mode: MODE_FULL,
        reason: REASON_SWITCH,
        group_id: vec![b'g'; 64],
        epoch: 42,
        close_group_id: vec![b'o'; 64],
        close_epoch: 41,
        chk_commit: [4u8; 32],
        actor_device_id: vec![b'd'; 64],
        sig: [9u8; 64],
    }
}

#[test]
fn full_records_fit_512_bytes_even_with_64_byte_ids() {
    let record = sample_record();
    let bytes = record.encode().unwrap();
    assert_eq!(bytes.len(), 512);
    // 481 bytes used: the design's maximum.
    assert!(bytes[481..].iter().all(|byte| *byte == 0));
    assert_eq!(bytes[480], 9);
    assert_eq!(bytes[0], 1);
    assert_eq!(HistoryRecord::decode(&bytes).unwrap(), record);
    assert_eq!(
        record.hash().unwrap(),
        <[u8; 32]>::from(Sha256::digest(bytes))
    );
    // The signed fields are the form without version byte and signature.
    let fields = record.signed_fields().unwrap();
    assert_eq!(fields.len(), 481 - 1 - 64);
    assert_eq!(&bytes[1..1 + fields.len()], fields.as_slice());
}

#[test]
fn records_refuse_loose_structure() {
    let record = sample_record();
    let bytes = record.encode().unwrap();
    // Padding must be zero, the version 1, the length exact.
    let mut loose = bytes;
    loose[500] = 1;
    assert!(HistoryRecord::decode(&loose).is_err());
    let mut version = bytes;
    version[0] = 2;
    assert!(HistoryRecord::decode(&version).is_err());
    assert!(HistoryRecord::decode(&bytes[..511]).is_err());
    // Ids: 1 to 64 bytes.
    for change in [
        |r: &mut HistoryRecord| r.community_id = vec![],
        |r: &mut HistoryRecord| r.channel_id = vec![b'x'; 65],
        |r: &mut HistoryRecord| r.group_id = vec![],
        |r: &mut HistoryRecord| r.close_group_id = vec![b'x'; 65],
        |r: &mut HistoryRecord| r.actor_device_id = vec![],
        |r: &mut HistoryRecord| r.seq = SEQ_LIMIT,
        |r: &mut HistoryRecord| r.mode = 2,
        |r: &mut HistoryRecord| r.reason = 3,
    ] {
        let mut bad = sample_record();
        change(&mut bad);
        assert!(bad.encode().is_err());
    }
    // seq = 2^32 - 2 is the last valid one.
    let mut last = sample_record();
    last.seq = SEQ_LIMIT - 1;
    assert_eq!(
        HistoryRecord::decode(&last.encode().unwrap()).unwrap(),
        last
    );
}

#[test]
fn compact_records_are_143_bytes_and_a_move_adds_its_fields() {
    let compact = CompactRecord {
        seq: 3,
        prev: [1u8; 32],
        mode: MODE_FULL,
        reason: REASON_SWITCH,
        close_epoch: 9,
        key: [2u8; 32],
        sig: [3u8; 64],
        moved: None,
    };
    let bytes = compact.encode().unwrap();
    assert_eq!(bytes.len(), COMPACT_BYTES);
    assert_eq!(CompactRecord::decode(&bytes).unwrap(), compact);
    // Trailing bytes and short input are refused.
    assert!(CompactRecord::decode(&[bytes.as_slice(), &[0]].concat()).is_err());
    assert!(CompactRecord::decode(&bytes[..142]).is_err());

    let moved = CompactRecord {
        reason: REASON_MOVE,
        moved: Some((b"old_group".to_vec(), [7u8; MOVE_WRAP_BYTES])),
        ..compact.clone()
    };
    let moved_bytes = moved.encode().unwrap();
    assert_eq!(moved_bytes.len(), COMPACT_BYTES + 2 + 9 + MOVE_WRAP_BYTES);
    assert_eq!(CompactRecord::decode(&moved_bytes).unwrap(), moved);
    // A move needs its fields and only a move has them.
    assert!(CompactRecord {
        moved: None,
        ..moved.clone()
    }
    .encode()
    .is_err());
    assert!(CompactRecord {
        reason: REASON_SWITCH,
        ..moved
    }
    .encode()
    .is_err());
    // A move's compact bytes cut short are refused, not read as a switch.
    assert!(CompactRecord::decode(&moved_bytes[..COMPACT_BYTES + 2]).is_err());
}

#[test]
fn expanding_a_compact_record_fills_what_the_message_supplies() {
    let context = RecordContext {
        community_id: b"comm",
        channel_id: b"chan",
        group_id: b"group_new",
        epoch: 50,
        actor_device_id: b"dev_actor",
    };
    let key = [8u8; 32];
    let opens = CompactRecord {
        seq: 1,
        prev: [0u8; 32],
        mode: MODE_FULL,
        reason: REASON_SWITCH,
        close_epoch: 50,
        key,
        sig: [5u8; 64],
        moved: None,
    };
    let full = opens.expand(&context).unwrap();
    assert_eq!(full.chk_commit, chk_commit(&key).unwrap());
    assert_eq!(full.close_group_id, b"group_new");
    assert_eq!(
        (full.group_id.as_slice(), full.epoch),
        (&b"group_new"[..], 50)
    );
    assert_eq!(full.actor_device_id, b"dev_actor");
    // A record that opens no key carries zeros, whatever its random `key`.
    let closes = CompactRecord {
        mode: MODE_MEMBERS_FROM_JOIN,
        ..opens.clone()
    };
    assert_eq!(closes.expand(&context).unwrap().chk_commit, [0u8; 32]);
    // A move names its old group.
    let moved = CompactRecord {
        reason: REASON_MOVE,
        moved: Some((b"group_old".to_vec(), [1u8; MOVE_WRAP_BYTES])),
        ..opens
    };
    assert_eq!(moved.expand(&context).unwrap().close_group_id, b"group_old");
}

// ---- signatures ---------------------------------------------------------------

#[test]
fn verify_refuses_unknown_domains_and_bad_lengths_and_rejects_tampering() {
    let signing = SigningKey::from_bytes(&[5u8; 32]);
    let public = signing.verifying_key().to_bytes();
    let message = b"fields";
    let signature = signing
        .sign(&signing_input(SIGN_DOMAIN_POST, message).unwrap())
        .to_bytes();
    assert!(verify(SIGN_DOMAIN_POST, &public, message, &signature).unwrap());
    assert!(!verify(SIGN_DOMAIN_POST, &public, b"fieldz", &signature).unwrap());
    let mut flipped = signature;
    flipped[10] ^= 1;
    assert!(!verify(SIGN_DOMAIN_POST, &public, message, &flipped).unwrap());
    assert!(!verify(SIGN_DOMAIN_POST, &[0xFFu8; 32], message, &signature).unwrap());
    // Wrong domain.
    assert!(!verify(SIGN_DOMAIN_HISTORY, &public, message, &signature).unwrap());
    assert_eq!(
        verify(b"veritra-c7-other-v1", &public, message, &signature).err(),
        Some(C7Error::InvalidInput)
    );
    assert_eq!(
        verify(SIGN_DOMAIN_POST, &public[..31], message, &signature).err(),
        Some(C7Error::InvalidInput)
    );
    assert_eq!(
        verify(SIGN_DOMAIN_POST, &public, message, &signature[..63]).err(),
        Some(C7Error::InvalidInput)
    );
    assert!(signing_input(b"MLS 1.0 x", message).is_err());
}

#[test]
fn a_post_signature_binds_every_field() {
    let hash = [1u8; 32];
    let base = post_signed_fields(b"c", b"h", b"a", b"g", 5, b"d", 3, &hash).unwrap();
    for changed in [
        post_signed_fields(b"x", b"h", b"a", b"g", 5, b"d", 3, &hash),
        post_signed_fields(b"c", b"x", b"a", b"g", 5, b"d", 3, &hash),
        post_signed_fields(b"c", b"h", b"x", b"g", 5, b"d", 3, &hash),
        post_signed_fields(b"c", b"h", b"a", b"x", 5, b"d", 3, &hash),
        post_signed_fields(b"c", b"h", b"a", b"g", 6, b"d", 3, &hash),
        post_signed_fields(b"c", b"h", b"a", b"g", 5, b"x", 3, &hash),
        post_signed_fields(b"c", b"h", b"a", b"g", 5, b"d", 4, &hash),
        post_signed_fields(b"c", b"h", b"a", b"g", 5, b"d", 3, &[2u8; 32]),
    ] {
        assert_ne!(changed.unwrap(), base);
    }
}

// ---- the ordering vector (build step 3) -------------------------------------

/// `testing/vectors/c7-ordering-v1.json`: the ordering table's rows, the
/// implicit genesis, the generation windows and the 512-byte VAP1 slack. The
/// table itself is app logic (Dart `c7_history.dart`, re-written in Go in
/// `server/internal/c7vector`); Rust adds no table, so here it checks what the
/// core's own encodings imply: the vector is well formed, covers every row,
/// and its window and slack arithmetic follow the sizes the core enforces.
const ORDERING: &str = include_str!("../../../testing/vectors/c7-ordering-v1.json");

#[test]
fn ordering_vector_is_well_formed_and_covers_every_row() {
    let vector: Value = serde_json::from_str(ORDERING).expect("ordering vector parses");
    let mut rows = std::collections::BTreeSet::new();
    for case in vector["ordering"]["cases"].as_array().unwrap() {
        for step in case["steps"].as_array().unwrap() {
            let expect = &step["expect"];
            if let Some(row) = expect["row"].as_u64() {
                assert!((1..=7).contains(&row));
                rows.insert(row.to_string());
            } else if expect["row"] == "invalid" {
                rows.insert("invalid".into());
            }
            if let Some(record) = step.get("record") {
                // A record the core could encode: seq below the limit.
                assert!(record["seq"].as_u64().unwrap() < u64::from(SEQ_LIMIT));
            }
        }
    }
    let want: Vec<String> = ["1", "2", "3", "4", "5", "6", "7", "invalid"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert_eq!(rows.into_iter().collect::<Vec<_>>(), want);
    assert_eq!(vector["implicit_genesis"]["expect"]["head"], Value::Null);
    assert_eq!(
        vector["implicit_genesis"]["expect"]["mode"],
        "members_from_join"
    );
}

#[test]
fn window_cases_follow_decision_6() {
    let vector: Value = serde_json::from_str(ORDERING).expect("ordering vector parses");
    let windows = vector["windows"].as_array().unwrap();
    assert!(windows.len() >= 10);
    for window in windows {
        let generation = &window["generation"];
        let body = &window["body"];
        let epoch = generation["epoch"].as_u64().unwrap();
        let close = generation["close_epoch"].as_u64();
        let signed_epoch = body["signed_epoch"].as_u64().unwrap();
        let accepted = window["in_current_period"].as_bool().unwrap()
            && body["signed_gen"].as_u64().unwrap() == epoch
            && body["signed_group"] == generation["group"]
            && signed_epoch == body["route_epoch"].as_u64().unwrap()
            && signed_epoch >= epoch
            && close.is_none_or(|close| signed_epoch < close);
        assert_eq!(accepted, window["accept"], "{}", window["name"]);
    }
}

#[test]
fn record_message_fits_the_smallest_bucket_with_the_stated_slack() {
    let vector: Value = serde_json::from_str(ORDERING).expect("ordering vector parses");
    let slack = &vector["vap1_slack"];
    for case in slack["cases"].as_array().unwrap() {
        let compact = case["compact_bytes"].as_u64().unwrap() as usize;
        // The same key order as the app's inner JSON; base64 without a line
        // break, standard alphabet.
        let encoded_len = compact.div_ceil(3) * 4;
        let inner = format!(
            "{{\"v\":2,\"type\":\"history_change\",\"conversation_id\":\"{}\",\"sender_device_id\":\"{}\",\"action_id\":\"{}\",\"channel_id\":\"{}\",\"hidden\":true,\"body\":{{\"r\":\"{}\"}}}}",
            slack["conversation_id"].as_str().unwrap(),
            slack["sender_device_id"].as_str().unwrap(),
            slack["action_id"].as_str().unwrap(),
            slack["channel_id"].as_str().unwrap(),
            "A".repeat(encoded_len)
        );
        let framed = inner.len() + 8;
        let vap1 = framed.div_ceil(256) * 256;
        assert_eq!(inner.len() as u64, case["inner_json_bytes"]);
        assert_eq!(framed as u64, case["framed_bytes"]);
        assert_eq!(vap1 as u64, case["vap1_bytes"]);
        assert_eq!((vap1 - framed) as u64, case["slack"]);
        assert!(vap1 <= MAX_VAP1_BYTES);
    }
    // The compact record in the primitives vector is the 143-byte case.
    let primitives: Value = serde_json::from_str(VECTOR).unwrap();
    assert_eq!(
        unhex(&primitives["outputs"]["record_compact_hex"]).len(),
        COMPACT_BYTES
    );
}

#[test]
fn sequence_cap_cases_follow_decision_4() {
    let vector: Value = serde_json::from_str(ORDERING).expect("ordering vector parses");
    let cap = &vector["seq_cap"];
    let (max_jump, ceiling) = (
        cap["max_jump"].as_i64().unwrap(),
        cap["ceiling"].as_i64().unwrap(),
    );
    assert_eq!(max_jump, 1024);
    // Room above any valid record always remains below the structural limit.
    assert!(ceiling + max_jump < i64::from(SEQ_LIMIT));
    for case in cap["cases"].as_array().unwrap() {
        let (highest, seq) = (
            case["highest"].as_i64().unwrap(),
            case["seq"].as_i64().unwrap(),
        );
        let valid = seq <= ceiling && (highest < 0 || seq <= highest + max_jump);
        assert_eq!(valid, case["valid"], "highest {highest} seq {seq}");
    }
}
