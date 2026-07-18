#ifndef VERITRA_CRYPTO_H
#define VERITRA_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#define PM_CRYPTO_UNAVAILABLE (-1)
#define PM_CRYPTO_ABI_VERSION (2u)
#define PM_CRYPTO_OK (0)
#define PM_CRYPTO_INVALID_ARGUMENT (-2)
#define PM_CRYPTO_ERROR (-3)
#define PM_CRYPTO_PANIC (-4)

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
 * once; freeing zeroes its contents before releasing memory.
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
int32_t pm_crypto_device_sign_enrollment_challenge(PmCryptoHandle *handle,
                                                   PmByteSlice challenge,
                                                   PmOwnedBuffer *out);
int32_t pm_crypto_device_create_key_package(PmCryptoHandle *handle,
                                            PmOwnedBuffer *out);
int32_t pm_crypto_device_create_enrollment_credential(
    PmCryptoHandle *handle, PmByteSlice challenge,
    PmOwnedBuffer *out_key_package, PmOwnedBuffer *out_signing_public_key,
    PmOwnedBuffer *out_challenge_signature);
int32_t pm_crypto_device_seal_state(PmCryptoHandle *handle,
                                    PmByteSlice state_key, uint64_t counter,
                                    PmOwnedBuffer *out);
int32_t pm_crypto_group_create(PmCryptoHandle *handle, PmByteSlice group_id);
int32_t pm_crypto_group_join(PmCryptoHandle *handle, PmByteSlice welcome);
int32_t pm_crypto_group_add_member(PmCryptoHandle *handle,
                                   PmByteSlice group_id,
                                   PmByteSlice key_package,
                                   PmOwnedBuffer *out_commit,
                                   PmOwnedBuffer *out_welcome);
int32_t pm_crypto_group_process_commit(PmCryptoHandle *handle,
                                       PmByteSlice group_id,
                                       PmByteSlice commit);
int32_t pm_crypto_group_self_update(PmCryptoHandle *handle,
                                    PmByteSlice group_id,
                                    PmOwnedBuffer *out_commit);
int32_t pm_crypto_group_remove_member(
    PmCryptoHandle *handle, PmByteSlice group_id, PmByteSlice account_id,
    PmByteSlice device_id, PmOwnedBuffer *out_commit);
int32_t pm_crypto_group_encrypt(PmCryptoHandle *handle, PmByteSlice group_id,
                                PmByteSlice plaintext,
                                PmOwnedBuffer *out_ciphertext);
int32_t pm_crypto_group_decrypt(PmCryptoHandle *handle, PmByteSlice group_id,
                                PmByteSlice ciphertext,
                                PmOwnedBuffer *out_plaintext);

/* These operations remain unavailable and do not read their arguments. */
int32_t pm_crypto_create_device_key_package(PmDeviceCredentialInput input,
                                            PmOutputBuffer output);
int32_t pm_crypto_encrypt(PmByteSlice conversation_id, PmByteSlice plaintext,
                          PmOutputBuffer output);
int32_t pm_crypto_decrypt(PmByteSlice conversation_id, PmByteSlice ciphertext,
                          PmOutputBuffer output);

#endif
