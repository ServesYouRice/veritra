//! ABI8 local control codec. No server JSON or secret private-key exports.
use super::*;
use crate::mls::{
    link_v3::{EnrollmentProof, LinkContext},
    transfer::{Direction, TransferId},
};
use sha2::{Digest, Sha256};

const MAX_CONTROL: usize = 64 * 1024;
const BAD: i32 = PM_CRYPTO_INVALID_ARGUMENT;

pub(super) mod streams;

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}
impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], i32> {
        let end = self.at.checked_add(n).ok_or(BAD)?;
        let value = self.bytes.get(self.at..end).ok_or(BAD)?;
        self.at = end;
        Ok(value)
    }
    fn u16(&mut self) -> Result<u16, i32> {
        Ok(u16::from_be_bytes(
            self.take(2)?.try_into().map_err(|_| BAD)?,
        ))
    }
    fn u64(&mut self) -> Result<u64, i32> {
        Ok(u64::from_be_bytes(
            self.take(8)?.try_into().map_err(|_| BAD)?,
        ))
    }
    fn fixed(&mut self) -> Result<[u8; 32], i32> {
        self.take(32)?.try_into().map_err(|_| BAD)
    }
    fn text(&mut self, max: usize) -> Result<&'a [u8], i32> {
        let value = self.blob16(max)?;
        std::str::from_utf8(value).map_err(|_| BAD)?;
        Ok(value)
    }
    fn blob16(&mut self, max: usize) -> Result<&'a [u8], i32> {
        let n = self.u16()? as usize;
        if n == 0 || n > max {
            return Err(BAD);
        }
        self.take(n)
    }
    fn blob(&mut self, max: usize) -> Result<&'a [u8], i32> {
        let n = u32::from_be_bytes(self.take(4)?.try_into().map_err(|_| BAD)?) as usize;
        if n == 0 || n > max {
            return Err(BAD);
        }
        self.take(n)
    }
    fn id(&mut self) -> Result<TransferId, i32> {
        Ok(TransferId::new(self.text(2048)?, self.text(128)?))
    }
    fn context(&mut self) -> Result<LinkContext, i32> {
        let id = self.id()?;
        Ok(LinkContext {
            origin: id.origin,
            link_id: id.link_id,
            account_id: self.text(128)?.to_vec(),
            nonce: self.fixed()?,
            source_device_id: self.text(128)?.to_vec(),
            source_signing_key: self.fixed()?,
            recipient_device_id: self.text(128)?.to_vec(),
            recipient_signing_key: self.fixed()?,
            transfer_public_key: self.fixed()?,
        })
    }
    fn finish(&self) -> Result<(), i32> {
        if self.at == self.bytes.len() {
            Ok(())
        } else {
            Err(BAD)
        }
    }
}

enum Request<'a> {
    Begin(LinkContext, &'a [u8], u64, u64),
    Accept(LinkContext, &'a [u8], u64, u64, [u8; 32], [u8; 32]),
    Inspect(TransferId, u64),
    Proof(
        TransferId,
        u64,
        &'a [u8],
        [u8; 32],
        &'a [u8],
        &'a [u8],
        &'a [u8],
        [u8; 32],
        [u8; 32],
        [u8; 32],
    ),
    Confirm(TransferId, &'a [u8], u64),
    ApprovalRead(TransferId, u64),
    Approved(TransferId, [u8; 32], u64, u64),
    Posted(TransferId, u64),
    Importing(TransferId, u64),
    Forget(TransferId),
    Expire(u64),
}
impl<'a> Request<'a> {
    fn mutation_id(&self) -> Option<&TransferId> {
        match self {
            Self::Begin(..) | Self::Accept(..) => None,
            Self::Confirm(id, ..)
            | Self::Approved(id, ..)
            | Self::Posted(id, ..)
            | Self::Importing(id, ..)
            | Self::Forget(id) => Some(id),
            _ => None,
        }
    }
    fn parse(bytes: &'a [u8], operation: u16) -> Result<Self, i32> {
        let mut r = Reader { bytes, at: 0 };
        if r.take(5)? != b"PK2Q\x01" || r.u16()? != operation {
            return Err(BAD);
        }
        let request = match operation {
            1 => Self::Begin(r.context()?, r.take(16)?, r.u64()?, r.u64()?),
            2 => Self::Accept(
                r.context()?,
                r.take(16)?,
                r.u64()?,
                r.u64()?,
                r.fixed()?,
                r.fixed()?,
            ),
            3 => Self::Inspect(r.id()?, r.u64()?),
            4 => Self::Proof(
                r.id()?,
                r.u64()?,
                r.text(64)?,
                r.fixed()?,
                r.text(64)?,
                r.blob16(MAX_CHALLENGE_BYTES)?,
                r.blob(MAX_KEY_PACKAGE_BYTES)?,
                r.fixed()?,
                r.fixed()?,
                r.fixed()?,
            ),
            5 => Self::Confirm(r.id()?, r.take(8)?, r.u64()?),
            6 => Self::ApprovalRead(r.id()?, r.u64()?),
            7 => Self::Approved(r.id()?, r.fixed()?, r.u64()?, r.u64()?),
            8 => Self::Posted(r.id()?, r.u64()?),
            9 => Self::Importing(r.id()?, r.u64()?),
            10 => Self::Forget(r.id()?),
            11 => Self::Expire(r.u64()?),
            _ => return Err(BAD),
        };
        r.finish()?;
        Ok(request)
    }
    fn run(self, d: &mut MlsDevice, operation: u16) -> Result<Vec<u8>, i32> {
        // All result lengths are known. Allocate once, including the exact
        // framing, to avoid reallocating buffers containing approval MACs.
        let size = match operation {
            1 => 111,
            2 => 79,
            3 => 106,
            4 => 103,
            5 => 16,
            6 => 71,
            7 => 15,
            8..=10 => 8,
            11 => 9,
            _ => return Err(BAD),
        };
        let mut out = Vec::with_capacity(size);
        out.extend_from_slice(b"PK2R\x01");
        out.extend_from_slice(&operation.to_be_bytes());
        let fail = |_| PM_CRYPTO_ERROR;
        let verification = |out: &mut Vec<u8>, v: &crate::mls::DeviceLinkVerification| {
            out.extend_from_slice(&v.transcript_hash);
            out.extend_from_slice(&v.claim_tag);
            out.extend_from_slice(v.sas.as_bytes());
        };
        match self {
            Self::Begin(c, s, e, n) => {
                let (key, v) = d.begin_history_receive(c, s, e, n).map_err(fail)?;
                out.extend_from_slice(&key);
                verification(&mut out, &v);
            }
            Self::Accept(c, s, e, n, h, t) => {
                let v = d.accept_history_claim(c, s, e, n, &h, &t).map_err(fail)?;
                verification(&mut out, &v);
            }
            Self::Inspect(id, n) => {
                let r = d.history_record(&id, n).map_err(fail)?;
                out.extend_from_slice(&[
                    r.direction as u8,
                    r.stage as u8,
                    u8::from(r.approval_intent_at_ms != 0),
                ]);
                for t in [r.link_expires_at_ms, r.approved_at_ms, r.expires_at_ms] {
                    out.extend_from_slice(&t.to_be_bytes());
                }
                verification(&mut out, &r.verification);
            }
            Self::Proof(
                id,
                n,
                locator,
                request,
                name,
                challenge,
                package,
                claim,
                device,
                session,
            ) => {
                let r = d.history_record(&id, n).map_err(fail)?;
                if r.direction != Direction::Incoming || n >= r.link_expires_at_ms {
                    return Err(PM_CRYPTO_ERROR);
                }
                d.validate_local_key_package(package).map_err(fail)?;
                let p = EnrollmentProof {
                    origin: &r.context.origin,
                    locator,
                    reservation_request_id: &request,
                    link_id: &r.context.link_id,
                    account_id: &r.context.account_id,
                    device_id: &r.context.recipient_device_id,
                    device_name: name,
                    challenge,
                    key_package: package,
                    transfer_public_key: &r.context.transfer_public_key,
                    transcript_hash: r
                        .verification
                        .transcript_hash
                        .as_slice()
                        .try_into()
                        .map_err(|_| BAD)?,
                    claim_tag: r
                        .verification
                        .claim_tag
                        .as_slice()
                        .try_into()
                        .map_err(|_| BAD)?,
                    claim_token_hash: &claim,
                    device_secret_hash: &device,
                    initial_session_token_hash: &session,
                };
                out.extend_from_slice(&d.sign_link_v3_enrollment(&p).map_err(fail)?);
                out.extend_from_slice(&Sha256::digest(
                    p.message(d.signing_public_key()).map_err(fail)?,
                ));
            }
            Self::Confirm(id, s, n) => {
                // Deliberately discard internal return tag: only a subsequent
                // accessor after the service's durable commit may expose it.
                let tag: tls_codec::SecretVLBytes =
                    d.prepare_history_approval(&id, s, n).map_err(fail)?.into();
                drop(tag);
                out.push(1);
                out.extend_from_slice(
                    &d.history_record(&id, n)
                        .map_err(fail)?
                        .approval_intent_at_ms
                        .to_be_bytes(),
                );
            }
            Self::ApprovalRead(id, n) => {
                let (h, t) = d.history_approval_request(&id, n).map_err(fail)?;
                out.extend_from_slice(h);
                out.extend_from_slice(t);
            }
            Self::Approved(id, t, a, n) => {
                d.approve_history_transfer(&id, &t, a, n).map_err(fail)?;
                out.extend_from_slice(
                    &d.history_record(&id, n)
                        .map_err(fail)?
                        .expires_at_ms
                        .to_be_bytes(),
                );
            }
            Self::Posted(id, n) => {
                d.mark_history_handoff_posted(&id, n).map_err(fail)?;
                out.push(4);
            }
            Self::Importing(id, n) => {
                d.mark_history_importing(&id, n).map_err(fail)?;
                out.push(4);
            }
            Self::Forget(id) => out.push(u8::from(d.cancel_history_transfer(&id))),
            Self::Expire(n) => {
                if n == 0 {
                    return Err(BAD);
                }
                out.extend_from_slice(&(d.expire_history_transfers(n) as u16).to_be_bytes());
            }
        }
        debug_assert_eq!(out.len(), size);
        Ok(out)
    }
}

unsafe fn control(
    handle: *mut PmCryptoHandle,
    request: PmByteSlice,
    out: *mut PmOwnedBuffer,
    op: u16,
) -> i32 {
    ffi_call(|| {
        if out.is_null() {
            return Err(BAD);
        }
        let start = out as usize;
        let end = start
            .checked_add(std::mem::size_of::<PmOwnedBuffer>())
            .ok_or(BAD)?;
        let input_start = request.data as usize;
        let input_end = input_start.checked_add(request.len).ok_or(BAD)?;
        let handle_start = handle as usize;
        let handle_end = handle_start
            .checked_add(std::mem::size_of::<PmCryptoHandle>())
            .ok_or(BAD)?;
        if (start < input_end && input_start < end) || (start < handle_end && handle_start < end) {
            return Err(BAD);
        }
        // SAFETY: caller supplies writable output storage, disjoint from input.
        unsafe {
            out.write(PmOwnedBuffer::default());
        }
        let request = Request::parse(unsafe { borrowed(request, MAX_CONTROL)? }, op)?;
        let handle = unsafe { handle.as_ref() }.ok_or(BAD)?;
        // Hold registration lock until this control completes, so a begin
        // cannot race a same-record mutation or global expiry sweep.
        let active = handle.active_stream.lock().map_err(|_| PM_CRYPTO_ERROR)?;
        if let Some(stream) = active.upgrade() {
            let s = stream.lock().map_err(|_| PM_CRYPTO_ERROR)?;
            if s.blocks(&request) {
                return Err(PM_CRYPTO_ERROR);
            }
        }
        let mut device = handle.device.lock().map_err(|_| PM_CRYPTO_ERROR)?;
        let result = request.run(&mut device, op)?;
        unsafe { output(out, result) }
    })
}

macro_rules! control_export {
    ($name:ident,$op:expr) => {
        /// ABI8 bounded local control operation. See the K2 ABI specification.
        ///
        /// # Safety
        /// Handle must be live. Input must be readable and output writable and
        /// disjoint from input/handle. Free successful output exactly once.
        #[no_mangle]
        pub unsafe extern "C" fn $name(
            handle: *mut PmCryptoHandle,
            request: PmByteSlice,
            out: *mut PmOwnedBuffer,
        ) -> i32 {
            unsafe { control(handle, request, out, $op) }
        }
    };
}
control_export!(pm_crypto_k2_receive_begin, 1);
control_export!(pm_crypto_k2_source_accept, 2);
control_export!(pm_crypto_k2_inspect, 3);
control_export!(pm_crypto_k2_enrollment_proof, 4);
control_export!(pm_crypto_k2_source_confirm, 5);
control_export!(pm_crypto_k2_source_approval_request, 6);
control_export!(pm_crypto_k2_apply_approval, 7);
control_export!(pm_crypto_k2_source_posted, 8);
control_export!(pm_crypto_k2_importing, 9);
control_export!(pm_crypto_k2_forget, 10);
control_export!(pm_crypto_k2_expire, 11);

#[cfg(test)]
mod tests {
    use super::*;

    struct Device(*mut PmCryptoHandle);
    impl Device {
        fn new(id: &[u8]) -> Self {
            let mut handle = ptr::null_mut();
            assert_eq!(
                unsafe { pm_crypto_device_create(slice(b"account"), slice(id), &mut handle) },
                0
            );
            Self(handle)
        }
        fn key(&self) -> [u8; 32] {
            unsafe { &*self.0 }
                .device
                .lock()
                .unwrap()
                .signing_public_key()
                .try_into()
                .unwrap()
        }
        fn restart(&mut self) {
            let mut out = PmOwnedBuffer::default();
            assert_eq!(
                unsafe { pm_crypto_device_seal_state(self.0, slice(&[7; 32]), 11, &mut out) },
                0
            );
            let state = take(out);
            let mut handle = ptr::null_mut();
            let mut counter = 0;
            let device_id = unsafe { &*self.0 }
                .device
                .lock()
                .unwrap()
                .history_transfer_context(&TransferId::new(b"https://example.test", b"link"), 100)
                .unwrap();
            let local_id = if self.key() == device_id.source_signing_key {
                b"source".as_slice()
            } else {
                b"new".as_slice()
            };
            assert_eq!(
                unsafe {
                    pm_crypto_device_restore(
                        slice(b"account"),
                        slice(local_id),
                        slice(&[7; 32]),
                        11,
                        slice(&state),
                        &mut handle,
                        &mut counter,
                    )
                },
                0
            );
            assert_eq!(counter, 11);
            unsafe { pm_crypto_device_destroy(self.0) };
            self.0 = handle;
        }
        fn call(&self, op: u16, bytes: &[u8]) -> Result<Vec<u8>, i32> {
            let mut out = PmOwnedBuffer::default();
            let code = unsafe { control(self.0, slice(bytes), &mut out, op) };
            if code == 0 {
                Ok(take(out))
            } else {
                assert!(out.data.is_null());
                assert_eq!(out.len, 0);
                Err(code)
            }
        }
    }
    impl Drop for Device {
        fn drop(&mut self) {
            unsafe { pm_crypto_device_destroy(self.0) }
        }
    }
    fn slice(b: &[u8]) -> PmByteSlice {
        PmByteSlice {
            data: b.as_ptr(),
            len: b.len(),
        }
    }
    fn take(b: PmOwnedBuffer) -> Vec<u8> {
        let value = unsafe { std::slice::from_raw_parts(b.data, b.len) }.to_vec();
        unsafe { pm_crypto_buffer_free(b) };
        value
    }
    fn frame(op: u16) -> Vec<u8> {
        let mut b = b"PK2Q\x01".to_vec();
        b.extend_from_slice(&op.to_be_bytes());
        b
    }
    fn lp(b: &mut Vec<u8>, value: &[u8]) {
        b.extend_from_slice(&(value.len() as u16).to_be_bytes());
        b.extend_from_slice(value);
    }
    fn id(b: &mut Vec<u8>) {
        lp(b, b"https://example.test");
        lp(b, b"link");
    }
    fn context(b: &mut Vec<u8>, s: &Device, r: &Device, key: &[u8]) {
        id(b);
        lp(b, b"account");
        b.extend_from_slice(&[9; 32]);
        lp(b, b"source");
        b.extend_from_slice(&s.key());
        lp(b, b"new");
        b.extend_from_slice(&r.key());
        b.extend_from_slice(key);
    }
    fn receive(s: &Device, r: &Device) -> (Vec<u8>, Vec<u8>) {
        let mut begin = frame(1);
        context(&mut begin, s, r, &[0; 32]);
        begin.extend_from_slice(&[8; 16]);
        begin.extend_from_slice(&1000u64.to_be_bytes());
        begin.extend_from_slice(&100u64.to_be_bytes());
        let result = r.call(1, &begin).unwrap();
        (begin, result)
    }
    fn accept(s: &Device, r: &Device, received: &[u8]) -> Vec<u8> {
        let mut b = frame(2);
        context(&mut b, s, r, &received[7..39]);
        b.extend_from_slice(&[8; 16]);
        b.extend_from_slice(&1000u64.to_be_bytes());
        b.extend_from_slice(&100u64.to_be_bytes());
        b.extend_from_slice(&received[39..103]);
        s.call(2, &b).unwrap()
    }

    #[test]
    fn control_persistence_masks_approval_and_reuses_recipient_key() {
        let mut s = Device::new(b"source");
        let mut r = Device::new(b"new");
        let (begin, result) = receive(&s, &r);
        assert_eq!(result.len(), 111);
        let verification = accept(&s, &r, &result);
        assert_eq!(verification[7..], result[39..]);
        let mut request = frame(6);
        id(&mut request);
        request.extend_from_slice(&100u64.to_be_bytes());
        assert_eq!(s.call(6, &request), Err(PM_CRYPTO_ERROR));
        let mut confirm = frame(5);
        id(&mut confirm);
        confirm.extend_from_slice(&verification[71..79]);
        confirm.extend_from_slice(&100u64.to_be_bytes());
        let intent = s.call(5, &confirm).unwrap();
        assert_eq!(intent.len(), 16);
        assert_eq!(
            &intent[7..],
            &[vec![1], 100u64.to_be_bytes().to_vec()].concat()
        );
        // Storage boundary is exercised by sealing/restoring before accessor.
        s.restart();
        r.restart();
        assert_eq!(r.call(1, &begin).unwrap(), result);
        assert_eq!(s.call(5, &confirm).unwrap(), intent);
        let approval = s.call(6, &request).unwrap();
        assert_eq!(approval.len(), 71);
        assert!(!result.windows(32).any(|x| x == &approval[39..]));
        assert!(!verification.windows(32).any(|x| x == &approval[39..]));
        for d in [&s, &r] {
            let mut approved = frame(7);
            id(&mut approved);
            approved.extend_from_slice(&approval[39..]);
            approved.extend_from_slice(&100u64.to_be_bytes());
            approved.extend_from_slice(&100u64.to_be_bytes());
            let first = d.call(7, &approved).unwrap();
            assert_eq!(d.call(7, &approved).unwrap(), first);
            let mut inspect = frame(3);
            id(&mut inspect);
            inspect.extend_from_slice(&100u64.to_be_bytes());
            let status = d.call(3, &inspect).unwrap();
            assert_eq!(status.len(), 106);
            assert_eq!(status[8], 2);
            let mut posted = frame(8);
            id(&mut posted);
            posted.extend_from_slice(&100u64.to_be_bytes());
            assert_eq!(d.call(8, &posted), Err(PM_CRYPTO_ERROR));
            let mut importing = posted;
            importing[6] = 9;
            assert_eq!(d.call(9, &importing), Err(PM_CRYPTO_ERROR));
        }
        let mut forget = frame(10);
        id(&mut forget);
        assert_eq!(r.call(10, &forget).unwrap()[7], 1);
        assert_eq!(r.call(10, &forget).unwrap()[7], 0);
        let mut expire = frame(11);
        expire.extend_from_slice(&u64::MAX.to_be_bytes());
        assert_eq!(&s.call(11, &expire).unwrap()[7..], &[0, 1]);
    }

    #[test]
    fn enrollment_proof_checks_native_keypackage_and_frozen_context() {
        let s = Device::new(b"source");
        let r = Device::new(b"new");
        let (_, received) = receive(&s, &r);
        let package = unsafe { &*r.0 }
            .device
            .lock()
            .unwrap()
            .create_key_package()
            .unwrap();
        let proof = |package: &[u8]| {
            let mut b = frame(4);
            id(&mut b);
            b.extend_from_slice(&100u64.to_be_bytes());
            lp(&mut b, &[b'a'; 64]);
            b.extend_from_slice(&[0x11; 32]);
            lp(&mut b, b"New phone");
            lp(&mut b, &[0xff, 0, 1]);
            b.extend_from_slice(&(package.len() as u32).to_be_bytes());
            b.extend_from_slice(package);
            for v in [0x77, 0x88, 0x99] {
                b.extend_from_slice(&[v; 32]);
            }
            b
        };
        let request = proof(&package);
        let first = r.call(4, &request).unwrap();
        assert_eq!(first.len(), 103);
        assert_eq!(r.call(4, &request).unwrap(), first);
        let other = unsafe { &*s.0 }
            .device
            .lock()
            .unwrap()
            .create_key_package()
            .unwrap();
        assert_eq!(r.call(4, &proof(&other)), Err(PM_CRYPTO_ERROR));
        assert_eq!(s.call(4, &request), Err(PM_CRYPTO_ERROR));
        assert_eq!(received.len(), 111);
    }

    #[test]
    fn malformed_controls_fail_before_mutation_and_output_aliases_reject() {
        let s = Device::new(b"source");
        let r = Device::new(b"new");
        let (begin, result) = receive(&s, &r);
        for end in 0..begin.len() {
            assert_eq!(r.call(1, &begin[..end]), Err(BAD));
        }
        let mut extra = begin.clone();
        extra.push(0);
        assert_eq!(r.call(1, &extra), Err(BAD));
        let mut version = begin.clone();
        version[4] = 2;
        assert_eq!(r.call(1, &version), Err(BAD));
        assert_eq!(r.call(2, &begin), Err(BAD));
        let mut secret_changed = begin.clone();
        let index = secret_changed.len() - 32;
        secret_changed[index] ^= 1;
        assert_eq!(r.call(1, &secret_changed), Err(PM_CRYPTO_ERROR));
        assert_eq!(r.call(1, &begin).unwrap(), result);
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            unsafe { control(ptr::null_mut(), slice(&begin), &mut out, 1) },
            BAD
        );
        assert!(out.data.is_null());
        assert_eq!(
            unsafe { control(r.0, slice(&begin), ptr::null_mut(), 1) },
            BAD
        );
        assert_eq!(unsafe { control(r.0, slice(&begin), r.0.cast(), 1) }, BAD);
        let mut input = begin.clone();
        assert_eq!(
            unsafe { control(r.0, slice(&input), input.as_mut_ptr().cast(), 1) },
            BAD
        );
        assert_eq!(input, begin);
    }
}
