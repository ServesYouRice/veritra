# I17 — Add encrypted attachment UX

Goal: encrypt attachments on device, transport ciphertext, and reveal plaintext only after authentication.

Read:

- mobile chat/composer/API/storage code
- server attachment/blob interfaces and routes
- I07 and I14 implementations

Do:

1. Derive a fresh attachment key and authenticated manifest per upload.
2. Stream encryption/decryption with strict size bounds; avoid whole-file memory loads.
3. Upload only ciphertext and authenticated non-content metadata.
4. Verify integrity before exposing previews or final files.
5. Handle cancellation, resume, retry, cleanup, and protected temporary files.

Done when: tamper/wrong-key tests fail closed and server/log/database checks find no plaintext content or key.

Verify: focused server and Flutter tests, including a large synthetic file.

Any new crypto primitive requires review; use existing reviewed library capabilities.
