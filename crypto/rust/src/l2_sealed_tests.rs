use super::*;
use rand_core::OsRng;
use voprf::{BlindedElement, PoprfServer};

fn blinded_elements(request: &[u8]) -> Vec<BlindedElement<Ristretto255>> {
    request
        .chunks_exact(ELEMENT_BYTES)
        .map(|chunk| BlindedElement::<Ristretto255>::deserialize(chunk).unwrap())
        .collect()
}

const VECTOR: &str = include_str!("../../../testing/vectors/l2-sealed-v1.json");

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

fn server(seed: &[u8]) -> PoprfServer<Ristretto255> {
    PoprfServer::<Ristretto255>::new_from_seed(seed, b"veritra-l2-test").unwrap()
}

fn public_key(server: &PoprfServer<Ristretto255>) -> Vec<u8> {
    <Ristretto255 as Group>::serialize_elem(server.get_public_key()).to_vec()
}

/// The server half, as the Go server runs it: evaluates the blinded
/// elements under `info` and returns `elements || proof`.
fn evaluate(server: &PoprfServer<Ristretto255>, request: &[u8], info: &[u8]) -> Vec<u8> {
    let blinded = blinded_elements(request);
    let prepared = server
        .batch_blind_evaluate_prepare(blinded.iter(), Some(info))
        .unwrap();
    let elements = prepared.prepared_evaluation_elements.collect::<Vec<_>>();
    let result = PoprfServer::<Ristretto255>::batch_blind_evaluate_finish(
        &mut OsRng,
        blinded.iter(),
        &elements,
        &prepared.prepared_tweak,
    )
    .unwrap();
    let mut out = Vec::new();
    for element in result.messages {
        out.extend_from_slice(&element.serialize());
    }
    out.extend_from_slice(&result.proof.serialize());
    out
}

#[test]
fn info_layout_is_fixed() {
    let info = info(b"conv_x", 0x0102_0304).unwrap();
    let mut expected = b"veritra-l2-sealed-v1".to_vec();
    expected.extend_from_slice(&[0, 6]);
    expected.extend_from_slice(b"conv_x");
    expected.extend_from_slice(&[1, 2, 3, 4]);
    // Nothing follows the epoch: no per-account or per-member-list number
    // (review M1).
    assert_eq!(info, expected);
    assert_eq!(super::info(b"", 1), Err(SealedError::InvalidInput));
    assert_eq!(super::info(&[b'a'; 129], 1), Err(SealedError::InvalidInput));
}

#[test]
fn tokens_round_trip_and_match_the_server_evaluation() {
    let server = server(&[7u8; 32]);
    let pk = public_key(&server);
    let request = token_request(&pk, b"conv_rt", 20_000, 5, &mut OsRng).unwrap();
    assert_eq!(request.request.len(), 5 * ELEMENT_BYTES);
    let info = info(b"conv_rt", 20_000).unwrap();
    let response = evaluate(&server, &request.request, &info);
    let tokens = token_finalize(&request.state, &response).unwrap();
    assert_eq!(tokens.len(), 5 * TOKEN_BYTES);
    let mut nonces = std::collections::HashSet::new();
    for token in tokens.chunks_exact(TOKEN_BYTES) {
        let (nonce, output) = token.split_at(NONCE_BYTES);
        assert!(nonces.insert(nonce.to_vec()), "nonces are fresh");
        // Redemption: the server recomputes the output from the nonce alone.
        let expected = server.evaluate(nonce, Some(&info)).unwrap();
        assert_eq!(output, expected.as_slice());
        // Another conversation or epoch gives another output.
        for other in [
            super::info(b"conv_other", 20_000).unwrap(),
            super::info(b"conv_rt", 20_001).unwrap(),
        ] {
            assert_ne!(server.evaluate(nonce, Some(&other)).unwrap(), expected);
        }
    }
}

#[test]
fn a_wrong_key_info_or_proof_is_refused() {
    let server = server(&[7u8; 32]);
    let other = server_seeded(&[8u8; 32]);
    let pk = public_key(&server);
    let request = token_request(&pk, b"conv_bad", 1, 2, &mut OsRng).unwrap();
    let info = info(b"conv_bad", 1).unwrap();
    // Evaluated under another key (a per-user key the client did not pin).
    let response = evaluate(&other, &request.request, &info);
    assert_eq!(
        token_finalize(&request.state, &response),
        Err(SealedError::Verification)
    );
    // Evaluated under other info (another epoch).
    let wrong_info = super::info(b"conv_bad", 2).unwrap();
    let response = evaluate(&server, &request.request, &wrong_info);
    assert_eq!(
        token_finalize(&request.state, &response),
        Err(SealedError::Verification)
    );
    // A flipped bit in the proof, or elements swapped.
    let mut response = evaluate(&server, &request.request, &info);
    let last = response.len() - 1;
    response[last - 40] ^= 1;
    assert!(token_finalize(&request.state, &response).is_err());
    let good = evaluate(&server, &request.request, &info);
    let mut swapped = good.clone();
    swapped[..ELEMENT_BYTES].copy_from_slice(&good[ELEMENT_BYTES..2 * ELEMENT_BYTES]);
    swapped[ELEMENT_BYTES..2 * ELEMENT_BYTES].copy_from_slice(&good[..ELEMENT_BYTES]);
    assert_eq!(
        token_finalize(&request.state, &swapped),
        Err(SealedError::Verification)
    );
    // Wrong lengths and a damaged state.
    assert_eq!(
        token_finalize(&request.state, &good[..good.len() - 1]),
        Err(SealedError::InvalidInput)
    );
    let mut state = request.state.clone();
    state[0] = b'X';
    assert_eq!(
        token_finalize(&state, &good),
        Err(SealedError::InvalidInput)
    );
    assert_eq!(
        token_finalize(&request.state[..request.state.len() - 1], &good),
        Err(SealedError::InvalidInput)
    );
    assert!(token_finalize(&request.state, &good).is_ok());
}

fn server_seeded(seed: &[u8]) -> PoprfServer<Ristretto255> {
    server(seed)
}

#[test]
fn requests_refuse_bad_arguments() {
    let pk = public_key(&server(&[7u8; 32]));
    assert!(token_request(&pk, b"c", 1, 0, &mut OsRng).is_err());
    assert!(token_request(&pk, b"c", 1, MAX_BATCH + 1, &mut OsRng).is_err());
    assert!(token_request(&pk, b"c", 1, MAX_BATCH, &mut OsRng).is_ok());
    assert!(token_request(&pk[..31], b"c", 1, 1, &mut OsRng).is_err());
    // The identity is not a public key.
    assert!(token_request(&[0u8; 32], b"c", 1, 1, &mut OsRng).is_err());
    assert!(key_id(&[0u8; 32]).is_err());
}

#[test]
fn rfc9497_poprf_ristretto255_vectors() {
    let vector = vector();
    let rfc = &vector["rfc9497_poprf_ristretto255"];
    let server = PoprfServer::<Ristretto255>::new_from_seed(
        &unhex(rfc["seed"].as_str().unwrap()),
        &unhex(rfc["key_info"].as_str().unwrap()),
    )
    .unwrap();
    assert_eq!(hex(&public_key(&server)), rfc["pk"].as_str().unwrap());
    for case in rfc["cases"].as_array().unwrap() {
        let output = server
            .evaluate(
                &unhex(case["input"].as_str().unwrap()),
                Some(&unhex(case["info"].as_str().unwrap())),
            )
            .unwrap();
        assert_eq!(hex(&output), case["output"].as_str().unwrap());
        // The client finalizes the RFC's evaluation and proof to the same
        // output (a voprf client state is `blind || blinded element`).
        let client = PoprfClient::<Ristretto255>::deserialize(
            &[
                unhex(case["blind"].as_str().unwrap()),
                unhex(case["blinded_element"].as_str().unwrap()),
            ]
            .concat(),
        )
        .unwrap();
        let finalized = client
            .finalize(
                &unhex(case["input"].as_str().unwrap()),
                &EvaluationElement::deserialize(&unhex(
                    case["evaluation_element"].as_str().unwrap(),
                ))
                .unwrap(),
                &Proof::deserialize(&unhex(case["proof"].as_str().unwrap())).unwrap(),
                server.get_public_key(),
                Some(&unhex(case["info"].as_str().unwrap())),
            )
            .unwrap();
        assert_eq!(hex(&finalized), case["output"].as_str().unwrap());
    }
}

#[test]
fn shared_vector_exchange_and_key_id() {
    let vector = vector();
    assert_eq!(vector["suite"], SUITE);
    let server = PoprfServer::<Ristretto255>::new_from_seed(
        &unhex(vector["server_seed"].as_str().unwrap()),
        vector["key_info"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let pk = public_key(&server);
    assert_eq!(hex(&pk), vector["public_key"].as_str().unwrap());
    assert_eq!(
        hex(&key_id(&pk).unwrap()),
        vector["key_id"].as_str().unwrap()
    );
    let case = &vector["info_case"];
    let info = info(
        case["conversation_id"].as_str().unwrap().as_bytes(),
        case["epoch"].as_u64().unwrap() as u32,
    )
    .unwrap();
    assert_eq!(hex(&info), case["info"].as_str().unwrap());
    let exchange = &vector["exchange"];
    let state = unhex(exchange["state"].as_str().unwrap());
    let response = unhex(exchange["response"].as_str().unwrap());
    let tokens = token_finalize(&state, &response).unwrap();
    assert_eq!(hex(&tokens), exchange["tokens"].as_str().unwrap());
    for token in tokens.chunks_exact(TOKEN_BYTES) {
        let (nonce, output) = token.split_at(NONCE_BYTES);
        assert_eq!(
            server.evaluate(nonce, Some(&info)).unwrap().as_slice(),
            output
        );
    }
    // The state names the vector's key and info.
    assert_eq!(&state[5..37], pk.as_slice());
}

/// Writes `testing/vectors/l2-sealed-v1.json` (run once with --ignored;
/// the committed file is what every language checks).
#[test]
#[ignore]
fn generate_vector() {
    let seed = [0x5cu8; 32];
    let key_info = "veritra-l2-vector";
    let server = PoprfServer::<Ristretto255>::new_from_seed(&seed, key_info.as_bytes()).unwrap();
    let pk = public_key(&server);
    let (conversation, epoch) = ("conv_l2_vector", 20_404u32);
    let info = info(conversation.as_bytes(), epoch).unwrap();
    let request = token_request(&pk, conversation.as_bytes(), epoch, 2, &mut OsRng).unwrap();
    let response = evaluate(&server, &request.request, &info);
    let tokens = token_finalize(&request.state, &response).unwrap();
    let rfc = serde_json::json!({
        "seed": "a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3",
        "key_info": "74657374206b6579",
        "sk": "145c79c108538421ac164ecbe131942136d5570b16d8bf41a24d4337da981e07",
        "pk": "c647bef38497bc6ec077c22af65b696efa43bff3b4a1975a3e8e0a1c5a79d631",
        "cases": [
            {"input": "00", "info": "7465737420696e666f",
             "blind": "64d37aed22a27f5191de1c1d69fadb899d8862b58eb4220029e036ec4c1f6706",
             "blinded_element": "c8713aa89241d6989ac142f22dba30596db635c772cbf25021fdd8f3d461f715",
             "evaluation_element": "1a4b860d808ff19624731e67b5eff20ceb2df3c3c03b906f5693e2078450d874",
             "proof": "41ad1a291aa02c80b0915fbfbb0c0afa15a57e2970067a602ddb9e8fd6b7100de32e1ecff943a36f0b10e3dae6bd266cdeb8adf825d86ef27dbc6c0e30c52206",
             "output": "ca688351e88afb1d841fde4401c79efebb2eb75e7998fa9737bd5a82a152406d38bd29f680504e54fd4587eddcf2f37a2617ac2fbd2993f7bdf45442ace7d221"},
            {"input": "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a", "info": "7465737420696e666f",
             "blind": "64d37aed22a27f5191de1c1d69fadb899d8862b58eb4220029e036ec4c1f6706",
             "blinded_element": "f0f0b209dd4d5f1844dac679acc7761b91a2e704879656cb7c201e82a99ab07d",
             "evaluation_element": "8c3c9d064c334c6991e99f286ea2301d1bde170b54003fb9c44c6d7bd6fc1540",
             "proof": "4c39992d55ffba38232cdac88fe583af8a85441fefd7d1d4a8d0394cd1de77018bf135c174f20281b3341ab1f453fe72b0293a7398703384bed822bfdeec8908",
             "output": "7c6557b276a137922a0bcfc2aa2b35dd78322bd500235eb6d6b6f91bc5b56a52de2d65612d503236b321f5d0bebcbc52b64b92e426f29c9b8b69f52de98ae507"}
        ]
    });
    let out = serde_json::json!({
        "description": "L2-3 sealed sender (D122): RFC 9497 POPRF ristretto255-SHA512 token exchange, info layout, key id and the RFC's own POPRF vectors (sealed franking is l2-frank-dv-v1.json). Rules: docs/crypto.md, Sealed sender with VOPRF tokens.",
        "suite": SUITE,
        "server_seed": hex(&seed),
        "key_info": key_info,
        "public_key": hex(&pk),
        "key_id": hex(&key_id(&pk).unwrap()),
        "info_case": {
            "conversation_id": conversation,
            "epoch": epoch,
            "info": hex(&info),
        },
        "exchange": {
            "count": 2,
            "state": hex(&request.state),
            "request": hex(&request.request),
            "response": hex(&response),
            "tokens": hex(&tokens),
        },
        "rfc9497_poprf_ristretto255": rfc,
    });
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../testing/vectors/l2-sealed-v1.json"
    );
    std::fs::write(path, serde_json::to_string_pretty(&out).unwrap() + "\n").unwrap();
}
