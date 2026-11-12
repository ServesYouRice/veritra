#!/usr/bin/env python3
"""Writes testing/vectors/c7-sync-v1.json: one whole `history_sync` as a
sender puts it on the wire (docs/designs/C7-channel-history.md, decision 5,
"history_sync body layout"), built here independently of the Rust, Go and
Dart code that check it. Fixed nonces, keys and VAP1 padding make it
reproducible: `python3 testing/vectors/c7-sync-v1.py` rewrites the same
file. Needs the `cryptography` package; the checks themselves do not.
"""
import base64
import hashlib
import hmac
import json
import os
import struct

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def lp(value: bytes) -> bytes:
    return struct.pack(">H", len(value)) + value


def u64(value: int) -> bytes:
    return struct.pack(">Q", value)


def derive(key: bytes, label: str, info: bytes) -> bytes:
    """HKDF-SHA256 with salt = label, ikm = key, 32 bytes out."""
    prk = hmac.new(label.encode(), key, hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()


def seal(key: bytes, nonce: bytes, aad: bytes, plain: bytes) -> bytes:
    k_enc = derive(key, "veritra-c7-enc-v1", b"")
    kc = derive(key, "veritra-c7-kc-v1", b"")
    return kc + nonce + AESGCM(k_enc).encrypt(nonce, plain, aad)


def chk_commit(key: bytes) -> bytes:
    return hashlib.sha256(b"veritra-c7-chk-v1" + key).digest()


def p(n: int) -> int:
    return 256 * -(-(512 + 128 * n) // 256)


def fill(seed: int, n: int) -> bytes:
    return bytes((seed + 7 * i) % 256 for i in range(n))


community = "comm_" + "1" * 32
conversation = "conv_" + "2" * 32
sender = "dev_" + "4" * 32
action = "5" * 48
for_epoch = 21
sign_seed = fill(9, 32)
body_key = fill(17, 32)
body_nonce = fill(33, 12)

# Two channels, sorted by their UTF-8 bytes. The first hands over its key
# (head record, entry with a wrap); the second is a channel this sender
# holds no state for (zero head, zero entry, a random key_c).
signer = Ed25519PrivateKey.from_private_bytes(sign_seed)
public = signer.public_key().public_bytes_raw()


def record(channel: str, key: bytes) -> bytes:
    signed = (lp(community.encode()) + lp(channel.encode())
              + struct.pack(">I", 3) + fill(61, 32) + bytes([1, 1])
              + lp(conversation.encode()) + u64(10)
              + lp(conversation.encode()) + u64(10)
              + chk_commit(key) + lp(sender.encode()))
    sig = signer.sign(b"veritra-c7-history-v1" + signed)
    full = bytes([1]) + signed + sig
    return full + bytes(512 - len(full))


chan_a = "chan_" + "3" * 32
chan_b = "chan_" + "6" * 32
first_key = fill(71, 32)   # CHK of the generation that opened at epoch 10
current = fill(101, 32)    # CHK of the generation current at for_epoch (20)
entry_a = u64(20) + chk_commit(current) + u64(10) + first_key
entry_a += bytes(128 - len(entry_a))
channels = [
    {
        "channel_id": chan_a,
        "key_hex": current.hex(),
        "slot_nonce_hex": fill(131, 12).hex(),
        "slot_plain_hex": (record(chan_a, first_key) + entry_a).hex(),
    },
    {
        "channel_id": chan_b,
        "key_hex": fill(151, 32).hex(),
        "slot_nonce_hex": fill(171, 12).hex(),
        "slot_plain_hex": bytes(640).hex(),
    },
]

inner = json.dumps({
    "v": 2,
    "type": "history_sync",
    "conversation_id": conversation,
    "sender_device_id": sender,
    "action_id": action,
    "hidden": True,
    "body": {
        "for_epoch": for_epoch,
        "channels": [[c["channel_id"], base64.b64encode(
            bytes.fromhex(c["key_hex"])).decode()] for c in channels],
    },
}, separators=(",", ":")).encode()
padded_len = p(len(channels))
vap1 = b"VAP1" + struct.pack(">I", len(inner)) + inner
vap1 += fill(191, padded_len - len(vap1))

# The group-level message: channel "" in the aad and in the signed fields.
aad = lp(conversation.encode()) + lp(b"") + lp(sender.encode()) + lp(action.encode())
signed_fields = (lp(community.encode()) + lp(b"") + lp(action.encode())
                 + lp(conversation.encode()) + u64(for_epoch + 1)
                 + lp(sender.encode()) + u64(0) + hashlib.sha256(vap1).digest())
post_sig = signer.sign(b"veritra-c7-post-sig-v1" + signed_fields)
body0 = seal(body_key, body_nonce, aad, post_sig + vap1)
slots = b""
for c in channels:
    info = (lp(community.encode()) + lp(c["channel_id"].encode())
            + lp(sender.encode()) + lp(action.encode()))
    slot_key = derive(bytes.fromhex(c["key_hex"]), "veritra-c7-slot-v1", info)
    c["slot_key_hex"] = slot_key.hex()
    slots += seal(slot_key, bytes.fromhex(c["slot_nonce_hex"]), aad,
                  bytes.fromhex(c["slot_plain_hex"]))
sealed = body0 + slots
assert len(sealed) == padded_len + 124 + 700 * len(channels)

vector = {
    "version": 1,
    "description": (
        "C7 history_sync as sent: seal(body_key, sig | body0 padded to P(N)) "
        "followed by N 700-byte slots, each sealed under "
        "HKDF(key_c, veritra-c7-slot-v1, lp(community) | lp(channel) | "
        "lp(sender) | lp(action)) with the group-level aad (channel \"\"). "
        "Generated by c7-sync-v1.py; Rust, Go and Dart open and check it."),
    "inputs": {
        "community_id": community,
        "conversation_id": conversation,
        "sender_device_id": sender,
        "action_id": action,
        "for_epoch": for_epoch,
        "message_epoch": for_epoch + 1,
        "signing_seed_hex": sign_seed.hex(),
        "body_key_hex": body_key.hex(),
        "body_nonce_hex": body_nonce.hex(),
        "channels": channels,
    },
    "outputs": {
        "signing_public_key_hex": public.hex(),
        "body_aad_hex": aad.hex(),
        "body0_padded_vap1_hex": vap1.hex(),
        "body0_inner_json": inner.decode(),
        "post_signed_fields_hex": signed_fields.hex(),
        "post_signature_hex": post_sig.hex(),
        "sealed_body_hex": sealed.hex(),
        "sealed_body_sha256_hex": hashlib.sha256(sealed).hexdigest(),
        "body0_sealed_length": len(body0),
        "sealed_body_length": len(sealed),
    },
}
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "c7-sync-v1.json")
with open(out, "w", encoding="utf-8") as handle:
    json.dump(vector, handle, indent=2)
    handle.write("\n")
