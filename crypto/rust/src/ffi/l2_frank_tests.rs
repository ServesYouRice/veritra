//! ABI 26 (L2-3): the designated-verifier franking entry points, called the
//! way Dart calls them: lengths, nulls, the listed-key refusal, the empty
//! (plain-form) answer and the three verdicts.

use super::*;

fn slice(bytes: &[u8]) -> PmByteSlice {
    PmByteSlice {
        data: bytes.as_ptr(),
        len: bytes.len(),
    }
}

const EMPTY: PmByteSlice = PmByteSlice {
    data: ptr::null(),
    len: 0,
};

unsafe fn take(buffer: PmOwnedBuffer) -> Vec<u8> {
    if buffer.data.is_null() {
        assert_eq!(buffer.len, 0);
        return Vec::new();
    }
    let value = unsafe { core::slice::from_raw_parts(buffer.data, buffer.len) }.to_vec();
    unsafe { pm_crypto_buffer_free(buffer) };
    value
}

fn owner(seed: u8) -> [u8; 32] {
    report::public_key(&[seed; 32]).unwrap()
}

unsafe fn designate(
    handle: *mut PmCryptoHandle,
    listed: &[u8],
    owners: &[u8],
    commit: &[u8],
) -> (i32, Vec<u8>) {
    let mut out = PmOwnedBuffer::default();
    let owners = if owners.is_empty() {
        EMPTY
    } else {
        slice(owners)
    };
    let code = unsafe {
        pm_crypto_l2_frank_designate(
            handle,
            slice(b"conv_ffi"),
            slice(commit),
            slice(listed),
            owners,
            &mut out,
        )
    };
    (code, unsafe { take(out) })
}

unsafe fn verify(seed: &[u8], sender: &[u8], d: &[u8]) -> (i32, u8) {
    let mut result = 0xffu8;
    let d = if d.is_empty() { EMPTY } else { slice(d) };
    let code = unsafe {
        pm_crypto_l2_frank_dv_verify(
            slice(seed),
            slice(sender),
            slice(b"conv_ffi"),
            slice(b"acct_ffi"),
            slice(b"dev_ffi"),
            slice(&[7u8; 32]),
            d,
            &mut result,
        )
    };
    (code, result)
}

#[test]
fn designate_and_verify_through_the_c_abi() {
    let handle = new_handle(MlsDevice::new(b"acct_ffi", b"dev_ffi").unwrap());
    unsafe {
        let mut key = PmOwnedBuffer::default();
        assert_eq!(
            pm_crypto_l2_frank_public_key(handle, &mut key),
            PM_CRYPTO_OK
        );
        let own = take(key);
        assert_eq!(own.len(), 32);
        assert_eq!(
            pm_crypto_l2_frank_public_key(handle, ptr::null_mut()),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        let commit = [7u8; 32];
        let owners = [owner(0x41), owner(0x42)].concat();
        let (code, d) = designate(handle, &own, &owners, &commit);
        assert_eq!(code, PM_CRYPTO_OK);
        assert_eq!(d.len(), 2 * crate::l2_frank::ENTRY_BYTES);
        assert_eq!(verify(&[0x41; 32], &own, &d), (PM_CRYPTO_OK, 1));
        assert_eq!(verify(&[0x42; 32], &own, &d), (PM_CRYPTO_OK, 1));
        assert_eq!(verify(&[0x43; 32], &own, &d), (PM_CRYPTO_OK, 2));
        let mut tampered = d.clone();
        tampered[20] ^= 1;
        let first = if d[..16] == crate::l2_frank::kid(&owner(0x41)).unwrap() {
            0x41
        } else {
            0x42
        };
        assert_eq!(verify(&[first; 32], &own, &tampered), (PM_CRYPTO_OK, 0));
        // Only invalid owner keys: OK with the empty (plain-form) answer.
        let (code, empty) = designate(handle, &own, &[0u8; 32], &commit);
        assert_eq!((code, empty.len()), (PM_CRYPTO_OK, 0));
        // A listed key other than the device's own: nothing is made.
        let mut other = own.clone();
        other[0] ^= 1;
        assert_eq!(
            designate(handle, &other, &owners, &commit).0,
            PM_CRYPTO_ERROR
        );
        // n = 0, n = 17, a partial key, a short commitment, a null output.
        assert_eq!(
            designate(handle, &own, &[], &commit).0,
            PM_CRYPTO_INVALID_ARGUMENT
        );
        let seventeen: Vec<u8> = (0..17).flat_map(|_| owner(0x41)).collect();
        assert_eq!(
            designate(handle, &own, &seventeen, &commit).0,
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            designate(handle, &own, &owners[..33], &commit).0,
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            designate(handle, &own, &owners, &commit[..31]).0,
            PM_CRYPTO_INVALID_ARGUMENT
        );
        assert_eq!(
            pm_crypto_l2_frank_designate(
                handle,
                slice(b"conv_ffi"),
                slice(&commit),
                slice(&own),
                slice(&owners),
                ptr::null_mut()
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        // Verify: an empty designation, a short seed, a null result.
        assert_eq!(verify(&[0x41; 32], &own, &[]).0, PM_CRYPTO_INVALID_ARGUMENT);
        assert_eq!(verify(&[0x41; 31], &own, &d).0, PM_CRYPTO_INVALID_ARGUMENT);
        assert_eq!(
            pm_crypto_l2_frank_dv_verify(
                slice(&[0x41; 32]),
                slice(&own),
                slice(b"conv_ffi"),
                slice(b"acct_ffi"),
                slice(b"dev_ffi"),
                slice(&commit),
                slice(&d),
                ptr::null_mut()
            ),
            PM_CRYPTO_INVALID_ARGUMENT
        );
        // A 17-entry designation is a mismatch, not an error.
        let long = vec![1u8; 17 * crate::l2_frank::ENTRY_BYTES];
        assert_eq!(verify(&[0x41; 32], &own, &long), (PM_CRYPTO_OK, 0));
        pm_crypto_device_destroy(handle);
    }
}
