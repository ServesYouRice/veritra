#ifndef VERITRA_CRYPTO_H
#define VERITRA_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#define PM_CRYPTO_UNAVAILABLE (-1)
#define PM_CRYPTO_ABI_VERSION (9u)
#define PM_CRYPTO_OK (0)
#define PM_CRYPTO_INVALID_ARGUMENT (-2)
#define PM_CRYPTO_ERROR (-3)
#define PM_CRYPTO_PANIC (-4)
/* Decrypted, but the MLS sender is not the claimed account/device (ABI 5). */
#define PM_CRYPTO_SENDER_MISMATCH (-5)
/* ABI 9, pm_crypto_device_restore only: the sealed state has the right magic
 * but a format version this build does not read (format 1 from OpenMLS
 * 0.8.1, or a newer build). The version is NOT authenticated: it may lead
 * only to a re-link/re-provision flow, never to weaker checks. Wrong key,
 * tampering, identity mismatch and corruption stay PM_CRYPTO_ERROR. */
#define PM_CRYPTO_STATE_FORMAT_UNSUPPORTED (-6)
/* ABI 9: decrypted from a retained past epoch, but the sender has left the
 * group. The ratchet has advanced: commit state, keep no content, exactly as
 * for PM_CRYPTO_SENDER_MISMATCH. */
#define PM_CRYPTO_SENDER_REMOVED (-7)

typedef struct {
  const uint8_t *data;
  size_t len;
} PmByteSlice;

typedef struct {
  uint8_t *data;
  size_t capacity;
  size_t *written;
} PmOutputBuffer;

typedef struct {
  PmByteSlice account_id;
  PmByteSlice device_id;
  PmByteSlice signing_public_key;
} PmDeviceCredentialInput;

typedef struct PmCryptoHandle PmCryptoHandle;
typedef struct PmHistoryStream PmHistoryStream;

typedef struct {
  uint8_t *data;
  size_t len;
} PmOwnedBuffer;

uint32_t pm_crypto_abi_version(void);
int32_t pm_crypto_available(void);
const char *pm_crypto_protocol(void);

/*
 * Device handles and owned buffers are library-owned. A successful handle must
 * be destroyed exactly once. A non-empty owned buffer must be freed exactly
 * once; freeing zeroes its contents before releasing memory. Each buffer is
 * an exact-length allocation, and the library wipes any copy it drops,
 * including an output refused because its target pointer was NULL.
 *
 * These ownership and group-lifecycle primitives are available for binding
 * development, but pm_crypto_available() remains PM_CRYPTO_UNAVAILABLE until
 * enrollment, both mobile bindings, recovery, and independent review are
 * complete.
 */
int32_t pm_crypto_device_create(PmByteSlice account_id, PmByteSlice device_id,
                                PmCryptoHandle **out_handle);
int32_t pm_crypto_device_restore(
    PmByteSlice account_id, PmByteSlice device_id, PmByteSlice state_key,
    uint64_t minimum_counter, PmByteSlice sealed_state,
    PmCryptoHandle **out_handle, uint64_t *out_counter);
void pm_crypto_device_destroy(PmCryptoHandle *handle);
void pm_crypto_buffer_free(PmOwnedBuffer buffer);
int32_t pm_crypto_device_signing_public_key(PmCryptoHandle *handle,
                                            PmOwnedBuffer *out);
/* ABI 7: returns the 32-byte public locator. */
int32_t pm_crypto_device_link_locator(PmByteSlice secret, PmOwnedBuffer *out);
/* ABI 8 control frames: PK2Q/PK2R v1, u16-BE operation, bounded64KiB.
 * See docs/designs/K2-abi8-boundary.md for exact fields and persistence rules.
 * Each success returns one owned buffer. Failure resets out to null/zero.
 * source_confirm NEVER returns approval_tag. Persist its intent/state before
 * calling source_approval_request or sending HTTP. No private key is exported.
 * Bundle stream symbols are reserved for a later complete implementation. */
int32_t pm_crypto_k2_receive_begin(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_accept(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_inspect(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_enrollment_proof(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_confirm(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_approval_request(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_apply_approval(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_posted(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_importing(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_forget(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_expire(PmCryptoHandle *, PmByteSlice, PmOwnedBuffer *);
/* ABI8 bounded bundle streams. One large stream process-wide. All results
 * use PK2R framing; write/read chunks max1MiB, total padded frame max64MiB.
 * Incoming read fails until receive_finish authenticates the complete bundle.
 * Device destroy invalidates/wipes the stream; destroy the stream pointer once
 * afterward too. Never persist pointers or write plaintext snapshots to disk.
 * source_finish/receive_begin_bundle include the verified transfer ID.
 * Persist ciphertext cache+exact opaque handoff+sealed state before HTTP. */
int32_t pm_crypto_k2_source_begin(PmCryptoHandle *, PmByteSlice,
    PmHistoryStream **, PmOwnedBuffer *);
int32_t pm_crypto_k2_receive_begin_bundle(PmCryptoHandle *, PmByteSlice,
    PmHistoryStream **, PmOwnedBuffer *);
int32_t pm_crypto_k2_stream_write(PmHistoryStream *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_stream_read(PmHistoryStream *, PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_source_finish(PmCryptoHandle *, PmHistoryStream *,
    PmByteSlice, PmOwnedBuffer *);
int32_t pm_crypto_k2_receive_finish(PmCryptoHandle *, PmHistoryStream *,
    PmByteSlice, PmOwnedBuffer *);
void pm_crypto_k2_stream_destroy(PmHistoryStream *);
/* ABI 7: returns hash32, claim MAC32, approval MAC32, SAS prefix4. The SAS
 * is prefix4 (big-endian) mod 10^8: 8 digits, about 26.6 bits. The prefix
 * and both tags are MACs keyed from the 128-bit out-of-band link secret, so
 * a relay without it cannot grind keys to match; if the secret leaks, the 8
 * digits alone fall to about 10^4 key generations per side. */
int32_t pm_crypto_device_link_transcript_hash(
    PmCryptoHandle *handle, PmByteSlice protocol_version,
    PmByteSlice server_origin, PmByteSlice link_id, PmByteSlice link_secret,
    PmByteSlice peer_device_id,
    PmByteSlice peer_signing_public_key, PmByteSlice link_nonce,
    uint8_t local_is_existing_device, PmOwnedBuffer *out);
int32_t pm_crypto_device_create_key_package(PmCryptoHandle *handle,
                                            PmOwnedBuffer *out);
/* ABI 9: the only enrollment signature. It covers
 * "veritra-enrollment-proof-v1" || u16-BE len || challenge || signing key ||
 * SHA-256(key package); the raw challenge signer was removed. */
int32_t pm_crypto_device_create_enrollment_credential(
    PmCryptoHandle *handle, PmByteSlice challenge,
    PmOwnedBuffer *out_key_package, PmOwnedBuffer *out_signing_public_key,
    PmOwnedBuffer *out_challenge_signature);
int32_t pm_crypto_device_seal_state(PmCryptoHandle *handle,
                                    PmByteSlice state_key, uint64_t counter,
                                    PmOwnedBuffer *out);
int32_t pm_crypto_group_create(PmCryptoHandle *handle, PmByteSlice group_id);
/*
 * Joins the group carried by a Welcome for expected_group_id. A device
 * removed and later re-added still stores the old group under that id; the
 * Welcome replaces it only when the stored group is inactive (this device
 * applied its own removal). An active stored group is never replaced:
 * PM_CRYPTO_ERROR, with the group and the key package kept, until the
 * device has processed its removal commit. See docs/crypto.md, "Rejoining a
 * conversation".
 */
int32_t pm_crypto_group_join(PmCryptoHandle *handle,
                             PmByteSlice expected_group_id,
                             PmByteSlice welcome);
/*
 * Deprecated, tests only. Merges its commit at once, before the server has
 * accepted it, so a commit that loses the epoch race forks this device. Not
 * used by the app; use pm_crypto_group_stage_commit, then
 * pm_crypto_group_merge_pending_commit after the server accepts it.
 */
int32_t pm_crypto_group_add_member(PmCryptoHandle *handle,
                                   PmByteSlice group_id,
                                   PmByteSlice key_package,
                                   PmByteSlice expected_account_id,
                                   PmByteSlice expected_device_id,
                                   PmOwnedBuffer *out_commit,
                                   PmOwnedBuffer *out_welcome);
/*
 * ABI 6 (card I51): one staged, unmerged commit adding and removing devices.
 * changes: version:u8(=1) add_count:u16 {kp_len:u32 kp account_len:u16
 * account device_len:u16 device}* remove_count:u16 {account_len:u16 account
 * device_len:u16 device}*, big-endian. out_welcome is empty (NULL, 0) when
 * nothing is added. Merge after the server accepts the commit; clear it
 * after a refusal.
 * An empty list (add_count 0, remove_count 0) stages a self-update: a commit
 * with an update path and no proposals that refreshes this device's leaf key
 * (2026-10-31; earlier ABI 9 builds refuse an empty list).
 */
int32_t pm_crypto_group_stage_commit(PmCryptoHandle *handle,
                                     PmByteSlice group_id, PmByteSlice changes,
                                     PmOwnedBuffer *out_commit,
                                     PmOwnedBuffer *out_welcome,
                                     uint64_t *out_epoch);
int32_t pm_crypto_group_merge_pending_commit(PmCryptoHandle *handle,
                                             PmByteSlice group_id);
int32_t pm_crypto_group_clear_pending_commit(PmCryptoHandle *handle,
                                             PmByteSlice group_id);
int32_t pm_crypto_group_epoch(PmCryptoHandle *handle, PmByteSlice group_id,
                              uint64_t *out_epoch, uint8_t *out_pending);
int32_t pm_crypto_group_process_commit(PmCryptoHandle *handle,
                                       PmByteSlice group_id,
                                       PmByteSlice commit);
/*
 * Deprecated, tests only. Merges its update commit at once, before the
 * server has accepted it, so a commit that loses the epoch race forks this
 * device. Not used by the app; use pm_crypto_group_stage_commit with an
 * empty change list.
 */
int32_t pm_crypto_group_self_update(PmCryptoHandle *handle,
                                    PmByteSlice group_id,
                                    PmOwnedBuffer *out_commit);
int32_t pm_crypto_group_safety_number(PmCryptoHandle *handle,
                                      PmByteSlice group_id,
                                      PmOwnedBuffer *out_hash,
                                      PmOwnedBuffer *out_digits);
/*
 * Deprecated, tests only. Merges its removal commit at once, before the
 * server has accepted it, so a commit that loses the epoch race forks this
 * device. Not used by the app; use pm_crypto_group_stage_commit.
 */
int32_t pm_crypto_group_remove_member(
    PmCryptoHandle *handle, PmByteSlice group_id, PmByteSlice account_id,
    PmByteSlice device_id, PmOwnedBuffer *out_commit);
/*
 * Plaintext is at most 1 MiB (1048576 bytes); ciphertext accepted by decrypt
 * is at most 1 MiB + 4096 bytes. Encrypt never returns ciphertext above the
 * decrypt ceiling, so every successful encrypt can be decrypted.
 */
int32_t pm_crypto_group_encrypt(PmCryptoHandle *handle, PmByteSlice group_id,
                                PmByteSlice plaintext,
                                PmOwnedBuffer *out_ciphertext);
int32_t pm_crypto_group_decrypt(PmCryptoHandle *handle, PmByteSlice group_id,
                                PmByteSlice ciphertext,
                                PmByteSlice sender_account_id,
                                PmByteSlice sender_device_id,
                                PmOwnedBuffer *out_plaintext);
int32_t pm_crypto_attachment_encrypt_chunk(
    PmByteSlice key, PmByteSlice nonce_prefix, uint32_t chunk_index,
    PmByteSlice context, PmByteSlice plaintext, PmOwnedBuffer *out_ciphertext);
int32_t pm_crypto_attachment_decrypt_chunk(
    PmByteSlice key, PmByteSlice nonce_prefix, uint32_t chunk_index,
    PmByteSlice context, PmByteSlice ciphertext, PmOwnedBuffer *out_plaintext);

/* These operations remain unavailable and do not read their arguments. */
int32_t pm_crypto_create_device_key_package(PmDeviceCredentialInput input,
                                            PmOutputBuffer output);
int32_t pm_crypto_encrypt(PmByteSlice conversation_id, PmByteSlice plaintext,
                          PmOutputBuffer output);
int32_t pm_crypto_decrypt(PmByteSlice conversation_id, PmByteSlice ciphertext,
                          PmOutputBuffer output);

#endif
