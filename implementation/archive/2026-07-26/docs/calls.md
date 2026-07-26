# Calls

The MVP server includes call signaling scaffolding. Media is not production-ready.

Signaling metadata is restricted to the exact versioned encrypted envelope
`{"version":1,"ciphertext":"<base64>","protocol":"mls10-openmls-v1"}`.
Unknown fields are rejected, so plaintext SDP and ICE candidates cannot be
stored in `call_sessions.metadata_json`.

## Direction

- 1:1 calls first.
- Pion is preferred for embedded Go signaling/media experiments.
- LiveKit is the reference for a production SFU if group calls require it.
- Small group calls should not make the default deployment heavy.

Call E2EE status must be documented before enabling production media.
