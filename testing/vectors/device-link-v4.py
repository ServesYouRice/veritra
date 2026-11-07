"""Independent reference for testing/vectors/device-link-v4.json (L1-3).

Run: python3 -I testing/vectors/device-link-v4.py > testing/vectors/device-link-v4.json
Uses only the standard library (hashlib, hmac), not the Rust code, so the
Rust test that reads the JSON checks the protocol against a second
implementation. See docs/designs/L1-3-link-commitment.md.
"""

import hashlib
import hmac
import json


def lp(value: bytes) -> bytes:
    assert len(value) < 65536
    return len(value).to_bytes(2, "big") + value


def hkdf(secret: bytes, label: bytes) -> bytes:
    prk = hmac.new(b"\x00" * 32, secret, hashlib.sha256).digest()
    return hmac.new(prk, label + b"\x01", hashlib.sha256).digest()


VERSION = b"veritra-device-link-v4"
inputs = {
    "origin": b"https://example.test",
    "link_id": b"link_01",
    "account_id": b"acct_01",
    "nonce": bytes([0x11]) * 32,
    "source_device_id": b"dev_old",
    "source_signing_key": bytes([0x22]) * 32,
    "recipient_device_id": b"dev_new",
    "recipient_signing_key": bytes([0x33]) * 32,
    "transfer_public_key": bytes([0x44]) * 32,
    "secret": bytes([0x55]) * 16,
    "source_random": bytes([0x66]) * 32,
    "recipient_random": bytes([0x77]) * 32,
}

commitment = hashlib.sha256(
    b"".join(
        lp(v)
        for v in [
            b"veritra-device-link-commitment",
            VERSION,
            inputs["origin"],
            inputs["account_id"],
            inputs["source_device_id"],
            inputs["source_signing_key"],
            inputs["source_random"],
        ]
    )
).digest()

transcript = b"".join(
    lp(v)
    for v in [
        b"veritra-device-link-transcript",
        VERSION,
        inputs["origin"],
        inputs["link_id"],
        inputs["account_id"],
        inputs["nonce"],
        inputs["source_device_id"],
        inputs["source_signing_key"],
        inputs["recipient_device_id"],
        inputs["recipient_signing_key"],
        inputs["transfer_public_key"],
        commitment,
        inputs["recipient_random"],
    ]
)
secret = inputs["secret"]
claim_tag = hmac.new(hkdf(secret, b"veritra-link-claim-v4"), transcript, hashlib.sha256).digest()
approval_tag = hmac.new(
    hkdf(secret, b"veritra-link-approval-v4"), transcript, hashlib.sha256
).digest()
sas_mac = hmac.new(
    hkdf(secret, b"veritra-link-sas-v4"), transcript + lp(inputs["source_random"]), hashlib.sha256
).digest()
sas = "%08d" % (int.from_bytes(sas_mac[:4], "big") % 100_000_000)

vector = {
    "description": "L1-3 device link v4: source commitment, claim transcript, tags and SAS",
    "protocol_version": VERSION.decode(),
    "inputs": {
        k: (v.decode() if k in ("origin", "link_id", "account_id", "source_device_id", "recipient_device_id") else v.hex())
        for k, v in inputs.items()
    },
    "source_commitment": commitment.hex(),
    "transcript_hash": hashlib.sha256(transcript).hexdigest(),
    "claim_tag": claim_tag.hex(),
    "approval_tag": approval_tag.hex(),
    "link_key": hkdf(secret, b"veritra-link-handoff-v4").hex(),
    "sas_bytes": sas_mac[:4].hex(),
    "sas": sas,
}
print(json.dumps(vector, indent=2))
