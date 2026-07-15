#ifndef VERITRA_CRYPTO_H
#define VERITRA_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#define PM_CRYPTO_UNAVAILABLE (-1)
#define PM_CRYPTO_ABI_VERSION (1u)

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

uint32_t pm_crypto_abi_version(void);
int32_t pm_crypto_available(void);
const char *pm_crypto_protocol(void);

/* These operations remain unavailable and do not read their arguments. */
int32_t pm_crypto_create_device_key_package(PmDeviceCredentialInput input,
                                            PmOutputBuffer output);
int32_t pm_crypto_encrypt(PmByteSlice conversation_id, PmByteSlice plaintext,
                          PmOutputBuffer output);
int32_t pm_crypto_decrypt(PmByteSlice conversation_id, PmByteSlice ciphertext,
                          PmOutputBuffer output);

#endif
