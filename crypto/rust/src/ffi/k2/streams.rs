//! Chunk-fed, fully bounded bundle operations. Stream handles contain only a
//! weak device reference; destroying a device invalidates and wipes its stream.
use super::*;
use crate::{
    attachment::MAX_ATTACHMENT_CHUNK,
    history::{self, ExpectedBundle, HandoffPayload},
};
use std::sync::atomic::{AtomicBool, Ordering};
use tls_codec::SecretVLBytes;

static LARGE_STREAM: AtomicBool = AtomicBool::new(false);
struct Lease;
impl Lease {
    fn acquire() -> Result<Self, i32> {
        LARGE_STREAM
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| PM_CRYPTO_ERROR)?;
        Ok(Self)
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        LARGE_STREAM.store(false, Ordering::Release);
    }
}

pub struct PmHistoryStream {
    state: Arc<Mutex<StreamState>>,
}
pub(crate) struct StreamState {
    owner: Weak<Mutex<MlsDevice>>,
    id: TransferId,
    mode: Mode,
    lease: Option<Lease>,
}
enum Mode {
    Source {
        payload: SecretVLBytes,
        length: usize,
        created: u64,
        counter: u64,
        version: u8,
    },
    Receive {
        ciphertext: Vec<u8>,
        expected: HandoffPayload,
        version: u8,
    },
    Ciphertext {
        bytes: Vec<u8>,
        offset: usize,
    },
    Plaintext {
        bytes: SecretVLBytes,
        offset: usize,
    },
    Closed,
}
impl StreamState {
    pub(super) fn blocks(&self, request: &Request<'_>) -> bool {
        if self.lease.is_none() {
            return false;
        }
        if matches!(request, Request::Importing(id, _) if *id==self.id)
            && matches!(self.mode, Mode::Plaintext { .. })
        {
            // Fully authenticated receiver capability. Only the metadata
            // Ready->Importing transition may coexist with this live lease.
            return false;
        }
        match request {
            Request::Begin(c, ..) | Request::Accept(c, ..) => {
                c.origin == self.id.origin && c.link_id == self.id.link_id
            }
            Request::Expire(..) => true,
            _ => request.mutation_id() == Some(&self.id),
        }
    }
    fn close(&mut self) {
        self.mode = Mode::Closed;
        self.lease = None;
    }
    fn owner(&self) -> Result<Arc<Mutex<MlsDevice>>, i32> {
        if self.lease.is_none() {
            return Err(PM_CRYPTO_ERROR);
        }
        self.owner.upgrade().ok_or(PM_CRYPTO_ERROR)
    }
}
pub(crate) fn invalidate(handle: &PmCryptoHandle) {
    let active = handle
        .active_stream
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if let Some(s) = active.upgrade() {
        s.lock().unwrap_or_else(|e| e.into_inner()).close();
    }
}
fn header(bytes: &[u8], op: u16) -> Result<Reader<'_>, i32> {
    let mut r = Reader { bytes, at: 0 };
    if r.take(5)? != b"PK2Q\x01" || r.u16()? != op {
        return Err(BAD);
    }
    Ok(r)
}
fn result(op: u16, size: usize) -> Vec<u8> {
    let mut b = Vec::with_capacity(size);
    b.extend_from_slice(b"PK2R\x01");
    b.extend_from_slice(&op.to_be_bytes());
    b
}
fn lp(out: &mut Vec<u8>, value: &[u8]) {
    out.extend_from_slice(&(value.len() as u16).to_be_bytes());
    out.extend_from_slice(value);
}
fn overlap(a: usize, n: usize, b: usize, m: usize) -> Result<bool, i32> {
    Ok(a < b.checked_add(m).ok_or(BAD)? && b < a.checked_add(n).ok_or(BAD)?)
}
unsafe fn output_check(
    out: *mut PmOwnedBuffer,
    request: PmByteSlice,
    handle: usize,
    handle_size: usize,
) -> Result<(), i32> {
    if out.is_null()
        || overlap(
            out as usize,
            std::mem::size_of::<PmOwnedBuffer>(),
            request.data as usize,
            request.len,
        )?
        || overlap(
            out as usize,
            std::mem::size_of::<PmOwnedBuffer>(),
            handle,
            handle_size,
        )?
    {
        return Err(BAD);
    }
    unsafe {
        out.write(PmOwnedBuffer::default());
    }
    Ok(())
}
unsafe fn begin(
    handle: *mut PmCryptoHandle,
    request: PmByteSlice,
    out_stream: *mut *mut PmHistoryStream,
    out: *mut PmOwnedBuffer,
    op: u16,
) -> i32 {
    ffi_call(|| {
        if out_stream.is_null() {
            return Err(BAD);
        }
        if overlap(
            out_stream as usize,
            std::mem::size_of::<*mut PmHistoryStream>(),
            out as usize,
            std::mem::size_of::<PmOwnedBuffer>(),
        )? || overlap(
            out_stream as usize,
            std::mem::size_of::<*mut PmHistoryStream>(),
            request.data as usize,
            request.len,
        )? || overlap(
            out_stream as usize,
            std::mem::size_of::<*mut PmHistoryStream>(),
            handle as usize,
            std::mem::size_of::<PmCryptoHandle>(),
        )? {
            return Err(BAD);
        }
        unsafe {
            output_check(
                out,
                request,
                handle as usize,
                std::mem::size_of::<PmCryptoHandle>(),
            )?;
            out_stream.write(ptr::null_mut());
        }
        let bytes = unsafe { borrowed(request, MAX_CONTROL)? };
        let mut r = header(bytes, op)?;
        let id = r.id()?;
        let now = r.u64()?;
        enum Start<'a> {
            Source(u64, u64, u8, usize),
            Receive(&'a [u8], u8),
        }
        let start = match op {
            20 => {
                let created = r.u64()?;
                let counter = r.u64()?;
                let version = r.take(1)?[0];
                let length = usize::try_from(r.u64()?).map_err(|_| BAD)?;
                if created == 0
                    || created > now
                    || counter == 0
                    || version == 0
                    || length > history::MAX_PADDED_HISTORY - 8
                {
                    return Err(BAD);
                }
                Start::Source(created, counter, version, length)
            }
            23 => {
                let handoff = r.blob(8192)?;
                let version = r.take(1)?[0];
                if version == 0 {
                    return Err(BAD);
                }
                Start::Receive(handoff, version)
            }
            _ => return Err(BAD),
        };
        r.finish()?;
        let handle = unsafe { handle.as_ref() }.ok_or(BAD)?;
        let mut registration = handle.active_stream.lock().map_err(|_| PM_CRYPTO_ERROR)?;
        let lease = Lease::acquire()?;
        let mut device = handle.device.lock().map_err(|_| PM_CRYPTO_ERROR)?;
        let (mode, metadata) = match start {
            Start::Source(created, counter, version, length) => {
                let record = device
                    .history_record(&id, now)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                if record.direction != Direction::Outgoing
                    || record.stage != crate::mls::transfer::Stage::Approved
                {
                    return Err(PM_CRYPTO_ERROR);
                }
                (
                    Mode::Source {
                        payload: SecretVLBytes::new(Vec::with_capacity(length)),
                        length,
                        created,
                        counter,
                        version,
                    },
                    result(op, 7),
                )
            }
            Start::Receive(handoff, version) => {
                let expected = device
                    .open_history_stream_handoff(&id, handoff, now)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                let size = usize::try_from(expected.ciphertext_size).map_err(|_| BAD)?;
                if size > history::MAX_HISTORY_CIPHERTEXT {
                    return Err(BAD);
                }
                let mut metadata = result(op, 7 + 66 + 32 + 8 + 32 + 8);
                lp(&mut metadata, &expected.blob_id);
                metadata.extend_from_slice(&expected.ciphertext_sha256);
                metadata.extend_from_slice(&expected.ciphertext_size.to_be_bytes());
                metadata.extend_from_slice(&expected.header_sha256);
                metadata.extend_from_slice(&expected.snapshot_counter.to_be_bytes());
                (
                    Mode::Receive {
                        ciphertext: Vec::with_capacity(size),
                        expected,
                        version,
                    },
                    metadata,
                )
            }
        };
        let state = Arc::new(Mutex::new(StreamState {
            owner: Arc::downgrade(&handle.device),
            id,
            mode,
            lease: Some(lease),
        }));
        *registration = Arc::downgrade(&state);
        let stream = Box::into_raw(Box::new(PmHistoryStream { state }));
        unsafe {
            output(out, metadata)?;
            out_stream.write(stream);
        }
        Ok(())
    })
}

unsafe fn stream_control(
    stream: *mut PmHistoryStream,
    device: *mut PmCryptoHandle,
    request: PmByteSlice,
    out: *mut PmOwnedBuffer,
    op: u16,
) -> i32 {
    ffi_call(|| {
        if !device.is_null()
            && overlap(
                out as usize,
                std::mem::size_of::<PmOwnedBuffer>(),
                device as usize,
                std::mem::size_of::<PmCryptoHandle>(),
            )?
        {
            return Err(BAD);
        }
        unsafe {
            output_check(
                out,
                request,
                stream as usize,
                std::mem::size_of::<PmHistoryStream>(),
            )?;
        }
        let maximum = if op == 21 {
            MAX_ATTACHMENT_CHUNK + 32
        } else {
            MAX_CONTROL
        };
        let mut r = header(unsafe { borrowed(request, maximum)? }, op)?;
        enum Action<'a> {
            Write(u64, &'a [u8]),
            Finish(u64),
            Read(u64, usize),
        }
        let action = match op {
            21 => Action::Write(r.u64()?, r.blob(MAX_ATTACHMENT_CHUNK)?),
            22 | 24 => Action::Finish(r.u64()?),
            25 => {
                let offset = r.u64()?;
                let length = u32::from_be_bytes(r.take(4)?.try_into().map_err(|_| BAD)?) as usize;
                if length == 0 || length > MAX_ATTACHMENT_CHUNK {
                    return Err(BAD);
                }
                Action::Read(offset, length)
            }
            _ => return Err(BAD),
        };
        r.finish()?;
        let stream = unsafe { stream.as_ref() }.ok_or(BAD)?;
        let mut state = stream.state.lock().map_err(|_| PM_CRYPTO_ERROR)?;
        let owner = state.owner()?;
        if matches!(op, 22 | 24) {
            let handle = unsafe { device.as_ref() }.ok_or(BAD)?;
            if !Arc::ptr_eq(&handle.device, &owner) {
                return Err(BAD);
            }
        }
        let bytes = match action {
            Action::Write(offset, bytes) => {
                let offset = usize::try_from(offset).map_err(|_| BAD)?;
                let end = offset.checked_add(bytes.len()).ok_or(BAD)?;
                match &mut state.mode {
                    Mode::Source {
                        payload, length, ..
                    } => {
                        if offset != payload.as_slice().len() || end > *length {
                            return Err(BAD);
                        }
                        for b in bytes {
                            payload.push(*b);
                        }
                    }
                    Mode::Receive {
                        ciphertext,
                        expected,
                        ..
                    } => {
                        if offset != ciphertext.len() || end as u64 > expected.ciphertext_size {
                            return Err(BAD);
                        }
                        ciphertext.extend_from_slice(bytes);
                    }
                    _ => return Err(PM_CRYPTO_ERROR),
                }
                let mut out = result(op, 15);
                out.extend_from_slice(&(end as u64).to_be_bytes());
                out
            }
            Action::Finish(now) if op == 22 => {
                let Mode::Source {
                    payload,
                    length,
                    created,
                    counter,
                    version,
                } = &state.mode
                else {
                    return Err(PM_CRYPTO_ERROR);
                };
                if payload.as_slice().len() != *length {
                    return Err(BAD);
                }
                let bundle = owner
                    .lock()
                    .map_err(|_| PM_CRYPTO_ERROR)?
                    .create_history_source_bundle(
                        &state.id,
                        payload.as_slice(),
                        *created,
                        *counter,
                        *version,
                        now,
                    )
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                let mut out = result(op, 7 + 66 + 32 + 32 + 8 + 4 + bundle.handoff.len());
                lp(&mut out, &bundle.transfer_id);
                out.extend_from_slice(&bundle.header_sha256);
                out.extend_from_slice(&bundle.ciphertext_sha256);
                out.extend_from_slice(&(bundle.ciphertext.len() as u64).to_be_bytes());
                out.extend_from_slice(&(bundle.handoff.len() as u32).to_be_bytes());
                out.extend_from_slice(&bundle.handoff);
                state.mode = Mode::Ciphertext {
                    bytes: bundle.ciphertext,
                    offset: 0,
                };
                out
            }
            Action::Finish(now) => {
                let Mode::Receive {
                    ciphertext,
                    expected,
                    version,
                } = &state.mode
                else {
                    return Err(PM_CRYPTO_ERROR);
                };
                let device = owner.lock().map_err(|_| PM_CRYPTO_ERROR)?;
                let record = device
                    .history_record(&state.id, now)
                    .map_err(|_| PM_CRYPTO_ERROR)?;
                let opened = history::open_bundle(
                    ciphertext,
                    &expected.secrets,
                    &ExpectedBundle {
                        account_id: &record.context.account_id,
                        source_device_id: &record.context.source_device_id,
                        snapshot_counter: expected.snapshot_counter,
                        header_sha256: &expected.header_sha256,
                        ciphertext_sha256: &expected.ciphertext_sha256,
                        ciphertext_size: expected.ciphertext_size,
                        plaintext_version: *version,
                    },
                )
                .map_err(|_| PM_CRYPTO_ERROR)?;
                let mut out = result(op, 32);
                out.extend_from_slice(&(opened.payload.as_slice().len() as u64).to_be_bytes());
                out.extend_from_slice(&opened.header.snapshot_counter.to_be_bytes());
                out.push(opened.header.plaintext_version);
                out.extend_from_slice(&opened.header.created_at_ms.to_be_bytes());
                state.mode = Mode::Plaintext {
                    bytes: opened.payload,
                    offset: 0,
                };
                out
            }
            Action::Read(offset, length) => {
                let (bytes, position) = match &mut state.mode {
                    Mode::Ciphertext { bytes, offset } => (bytes.as_slice(), offset),
                    Mode::Plaintext { bytes, offset } => (bytes.as_slice(), offset),
                    _ => return Err(PM_CRYPTO_ERROR),
                };
                if offset != *position as u64 {
                    return Err(BAD);
                }
                let end = bytes.len().min(position.checked_add(length).ok_or(BAD)?);
                let mut out = result(op, 20 + end - *position);
                out.extend_from_slice(&(end as u64).to_be_bytes());
                out.push(u8::from(end == bytes.len()));
                out.extend_from_slice(&((end - *position) as u32).to_be_bytes());
                out.extend_from_slice(&bytes[*position..end]);
                *position = end;
                out
            }
        };
        unsafe { output(out, bytes) }
    })
}

macro_rules! begin_export {
    ($name:ident,$op:expr) => {
        /// ABI8 bundle begin. Input/output must be disjoint; destroy output stream once.
        /// # Safety
        /// Device must be live, request readable, outputs writable and disjoint.
        #[no_mangle]
        pub unsafe extern "C" fn $name(
            device: *mut PmCryptoHandle,
            request: PmByteSlice,
            stream: *mut *mut PmHistoryStream,
            out: *mut PmOwnedBuffer,
        ) -> i32 {
            unsafe { begin(device, request, stream, out, $op) }
        }
    };
}
begin_export!(pm_crypto_k2_source_begin, 20);
begin_export!(pm_crypto_k2_receive_begin_bundle, 23);
macro_rules! stream_export {
    ($name:ident,$op:expr) => {
        /// ABI8 chunk operation. Requests/results follow the K2 local framing.
        /// # Safety
        /// Stream must be live; input readable, output writable and disjoint.
        #[no_mangle]
        pub unsafe extern "C" fn $name(
            stream: *mut PmHistoryStream,
            request: PmByteSlice,
            out: *mut PmOwnedBuffer,
        ) -> i32 {
            unsafe { stream_control(stream, ptr::null_mut(), request, out, $op) }
        }
    };
}
stream_export!(pm_crypto_k2_stream_write, 21);
stream_export!(pm_crypto_k2_stream_read, 25);
macro_rules! finish_export {
    ($name:ident,$op:expr) => {
        /// ABI8 bundle finish. Native mutations remain tentative until durable commit.
        /// # Safety
        /// Device/stream must be live; request readable; output writable and disjoint.
        #[no_mangle]
        pub unsafe extern "C" fn $name(
            device: *mut PmCryptoHandle,
            stream: *mut PmHistoryStream,
            request: PmByteSlice,
            out: *mut PmOwnedBuffer,
        ) -> i32 {
            unsafe { stream_control(stream, device, request, out, $op) }
        }
    };
}
finish_export!(pm_crypto_k2_source_finish, 22);
finish_export!(pm_crypto_k2_receive_finish, 24);
/// Invalidates a process-local stream and drops its zeroizing buffers.
/// # Safety
/// Stream must be null or library-owned and destroyed exactly once.
#[no_mangle]
pub unsafe extern "C" fn pm_crypto_k2_stream_destroy(stream: *mut PmHistoryStream) {
    if !stream.is_null() {
        let stream = unsafe { Box::from_raw(stream) };
        stream
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Seek, SeekFrom, Write};
    static TEST_SERIAL: Mutex<()> = Mutex::new(());
    struct Fixture {
        source: *mut PmCryptoHandle,
        recipient: *mut PmCryptoHandle,
        id: TransferId,
    }
    impl Fixture {
        fn new() -> Self {
            let source = MlsDevice::new(b"account", b"source").unwrap();
            let mut recipient = MlsDevice::new(b"account", b"recipient").unwrap();
            let context = LinkContext {
                origin: b"https://example.test".to_vec(),
                link_id: b"link".to_vec(),
                account_id: b"account".to_vec(),
                nonce: [9; 32],
                source_device_id: b"source".to_vec(),
                source_signing_key: source.signing_public_key().try_into().unwrap(),
                recipient_device_id: b"recipient".to_vec(),
                recipient_signing_key: recipient.signing_public_key().try_into().unwrap(),
                transfer_public_key: [0; 32],
            };
            let id = TransferId::new(&context.origin, &context.link_id);
            let (key, v) = recipient
                .begin_history_receive(context.clone(), &[8; 16], 1000, 100)
                .unwrap();
            let context = LinkContext {
                transfer_public_key: key,
                ..context
            };
            let mut source = source;
            source
                .accept_history_claim(
                    context,
                    &[8; 16],
                    1000,
                    100,
                    &v.transcript_hash,
                    &v.claim_tag,
                )
                .unwrap();
            source
                .prepare_history_approval(&id, v.sas.as_bytes(), 100)
                .unwrap();
            source
                .approve_history_transfer(&id, &v.approval_tag, 100, 100)
                .unwrap();
            recipient
                .approve_history_transfer(&id, &v.approval_tag, 100, 100)
                .unwrap();
            let handle = |d| {
                Box::into_raw(Box::new(PmCryptoHandle {
                    device: Arc::new(Mutex::new(d)),
                    active_stream: Mutex::new(Weak::new()),
                }))
            };
            Self {
                source: handle(source),
                recipient: handle(recipient),
                id,
            }
        }
        fn start(&self, length: usize) -> Result<*mut PmHistoryStream, i32> {
            let mut b = frame(20);
            self.put_id(&mut b);
            b.extend_from_slice(&100u64.to_be_bytes());
            b.extend_from_slice(&100u64.to_be_bytes());
            b.extend_from_slice(&31u64.to_be_bytes());
            b.push(4);
            b.extend_from_slice(&(length as u64).to_be_bytes());
            self.begin(self.source, 20, &b).map(|v| v.0)
        }
        fn put_id(&self, b: &mut Vec<u8>) {
            lp(b, &self.id.origin);
            lp(b, &self.id.link_id);
        }
        fn begin(
            &self,
            d: *mut PmCryptoHandle,
            op: u16,
            b: &[u8],
        ) -> Result<(*mut PmHistoryStream, Vec<u8>), i32> {
            let mut stream = ptr::null_mut();
            let mut out = PmOwnedBuffer::default();
            let code = unsafe { begin(d, slice(b), &mut stream, &mut out, op) };
            if code == 0 {
                Ok((stream, take(out)))
            } else {
                assert!(stream.is_null());
                assert!(out.data.is_null());
                Err(code)
            }
        }
        fn receive(&self, handoff: &[u8]) -> Result<(*mut PmHistoryStream, Vec<u8>), i32> {
            let mut b = frame(23);
            self.put_id(&mut b);
            b.extend_from_slice(&100u64.to_be_bytes());
            b.extend_from_slice(&(handoff.len() as u32).to_be_bytes());
            b.extend_from_slice(handoff);
            b.push(4);
            self.begin(self.recipient, 23, &b)
        }
        fn restart_recipient(&mut self) {
            let old = unsafe { &*self.recipient };
            let sealed = old.device.lock().unwrap().seal_state(&[7; 32], 31).unwrap();
            let (d, _) =
                MlsDevice::restore_state(b"account", b"recipient", &[7; 32], 31, &sealed).unwrap();
            unsafe { pm_crypto_device_destroy(self.recipient) };
            self.recipient = Box::into_raw(Box::new(PmCryptoHandle {
                device: Arc::new(Mutex::new(d)),
                active_stream: Mutex::new(Weak::new()),
            }));
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            unsafe {
                pm_crypto_device_destroy(self.source);
                pm_crypto_device_destroy(self.recipient);
            }
        }
    }
    struct Stream(*mut PmHistoryStream);
    impl Drop for Stream {
        fn drop(&mut self) {
            unsafe { pm_crypto_k2_stream_destroy(self.0) }
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
    fn call(
        stream: &Stream,
        device: *mut PmCryptoHandle,
        op: u16,
        b: &[u8],
    ) -> Result<Vec<u8>, i32> {
        let mut out = PmOwnedBuffer::default();
        let code = unsafe { stream_control(stream.0, device, slice(b), &mut out, op) };
        if code == 0 {
            Ok(take(out))
        } else {
            assert!(out.data.is_null());
            Err(code)
        }
    }
    fn write(stream: &Stream, offset: usize, bytes: &[u8]) -> Result<Vec<u8>, i32> {
        let mut b = frame(21);
        b.extend_from_slice(&(offset as u64).to_be_bytes());
        b.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        b.extend_from_slice(bytes);
        call(stream, ptr::null_mut(), 21, &b)
    }
    fn finish(stream: &Stream, device: *mut PmCryptoHandle, op: u16) -> Result<Vec<u8>, i32> {
        let mut b = frame(op);
        b.extend_from_slice(&100u64.to_be_bytes());
        call(stream, device, op, &b)
    }
    fn read(stream: &Stream, offset: usize, length: usize) -> Result<Vec<u8>, i32> {
        let mut b = frame(25);
        b.extend_from_slice(&(offset as u64).to_be_bytes());
        b.extend_from_slice(&(length as u32).to_be_bytes());
        call(stream, ptr::null_mut(), 25, &b)
    }
    fn handoff(metadata: &[u8]) -> Vec<u8> {
        let mut r = Reader {
            bytes: metadata,
            at: 7,
        };
        assert_eq!(r.text(64).unwrap().len(), 64);
        r.take(72).unwrap();
        let h = r.blob(8192).unwrap().to_vec();
        r.finish().unwrap();
        h
    }

    #[test]
    fn stream_roundtrip_authentication_leases_and_import_restart() {
        let _serial = TEST_SERIAL.lock().unwrap();
        let mut fixture = Fixture::new();
        let length = MAX_ATTACHMENT_CHUNK + 57;
        let source = Stream(fixture.start(length).unwrap());
        assert_eq!(fixture.start(0), Err(PM_CRYPTO_ERROR));
        assert_eq!(read(&source, 0, 1), Err(PM_CRYPTO_ERROR));
        let mut forget = frame(10);
        fixture.put_id(&mut forget);
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            unsafe { control(fixture.source, slice(&forget), &mut out, 10) },
            PM_CRYPTO_ERROR
        );
        let bytes = vec![0x51; MAX_ATTACHMENT_CHUNK];
        assert_eq!(write(&source, 1, &bytes), Err(BAD));
        write(&source, 0, &bytes).unwrap();
        assert_eq!(finish(&source, fixture.source, 22), Err(BAD));
        write(&source, bytes.len(), &[0x52; 57]).unwrap();
        assert_eq!(finish(&source, fixture.recipient, 22), Err(BAD));
        let metadata = finish(&source, fixture.source, 22).unwrap();
        let h = handoff(&metadata);
        assert_eq!(finish(&source, fixture.source, 22), Err(PM_CRYPTO_ERROR));
        let mut ciphertext = Vec::new();
        let mut offset = 0;
        loop {
            let chunk = read(&source, offset, MAX_ATTACHMENT_CHUNK).unwrap();
            offset = u64::from_be_bytes(chunk[7..15].try_into().unwrap()) as usize;
            ciphertext.extend_from_slice(&chunk[20..]);
            if chunk[15] == 1 {
                break;
            }
        }
        drop(source);
        assert_eq!(fixture.start(0), Err(PM_CRYPTO_ERROR));
        // Tampering cannot expose any plaintext, even after all bytes arrive.
        let (receiver, _) = fixture.receive(&h).unwrap();
        let receiver = Stream(receiver);
        assert_eq!(read(&receiver, 0, 1), Err(PM_CRYPTO_ERROR));
        let mut importing = frame(9);
        fixture.put_id(&mut importing);
        importing.extend_from_slice(&100u64.to_be_bytes());
        assert_eq!(
            unsafe { control(fixture.recipient, slice(&importing), &mut out, 9) },
            PM_CRYPTO_ERROR
        );
        let mut corrupted = ciphertext.clone();
        let last = corrupted.len() - 1;
        corrupted[last] ^= 1;
        for (i, chunk) in corrupted.chunks(MAX_ATTACHMENT_CHUNK).enumerate() {
            write(&receiver, i * MAX_ATTACHMENT_CHUNK, chunk).unwrap();
        }
        assert_eq!(
            finish(&receiver, fixture.recipient, 24),
            Err(PM_CRYPTO_ERROR)
        );
        assert_eq!(read(&receiver, 0, 1), Err(PM_CRYPTO_ERROR));
        drop(receiver);
        // Ready state survives a download/authentication crash.
        fixture.restart_recipient();
        let (receiver, verified) = fixture.receive(&h).unwrap();
        let receiver = Stream(receiver);
        assert_eq!(&verified[9..73], &metadata[9..73]);
        for (i, chunk) in ciphertext.chunks(MAX_ATTACHMENT_CHUNK).enumerate() {
            write(&receiver, i * MAX_ATTACHMENT_CHUNK, chunk).unwrap();
        }
        let opened = finish(&receiver, fixture.recipient, 24).unwrap();
        assert_eq!(
            unsafe { control(fixture.recipient, slice(&importing), &mut out, 9) },
            0
        );
        let _ = take(out);
        assert_eq!(
            unsafe { control(fixture.recipient, slice(&importing), &mut out, 9) },
            0
        );
        let _ = take(out);
        assert_eq!(
            u64::from_be_bytes(opened[7..15].try_into().unwrap()) as usize,
            length
        );
        assert_eq!(u64::from_be_bytes(opened[24..32].try_into().unwrap()), 100);
        let first = read(&receiver, 0, MAX_ATTACHMENT_CHUNK).unwrap();
        assert_eq!(&first[20..], bytes.as_slice());
        assert_eq!(read(&receiver, 0, 1), Err(BAD));
        let last = read(&receiver, MAX_ATTACHMENT_CHUNK, MAX_ATTACHMENT_CHUNK).unwrap();
        assert_eq!(&last[20..], &[0x52; 57]);
        assert_eq!(last[15], 1);
        assert_eq!(
            unsafe { &*fixture.recipient }
                .device
                .lock()
                .unwrap()
                .history_record(&fixture.id, 100)
                .unwrap()
                .stage as u8,
            4
        );
        drop(receiver);
        // Crash after importing was persisted, before durable application DB
        // import: the exact handoff and file can still be reopened.
        fixture.restart_recipient();
        let (reopened, _) = fixture.receive(&h).unwrap();
        let reopened = Stream(reopened);
        for (i, chunk) in ciphertext.chunks(MAX_ATTACHMENT_CHUNK).enumerate() {
            write(&reopened, i * MAX_ATTACHMENT_CHUNK, chunk).unwrap();
        }
        finish(&reopened, fixture.recipient, 24).unwrap();
        assert_eq!(&read(&reopened, 0, 1).unwrap()[20..], &[0x51]);
    }

    #[test]
    fn device_destroy_wipes_stream_and_releases_global_lease() {
        let _serial = TEST_SERIAL.lock().unwrap();
        let mut fixture = Fixture::new();
        assert_eq!(fixture.start(history::MAX_PADDED_HISTORY - 7), Err(BAD));
        let stream = Stream(fixture.start(32).unwrap());
        write(&stream, 0, &[7; 32]).unwrap();
        let mut request = frame(22);
        request.extend_from_slice(&100u64.to_be_bytes());
        let mut out = PmOwnedBuffer::default();
        assert_eq!(
            unsafe {
                stream_control(
                    stream.0,
                    fixture.source,
                    slice(&request),
                    fixture.source.cast(),
                    22,
                )
            },
            BAD
        );
        assert_eq!(
            unsafe { stream_control(stream.0, fixture.source, slice(&request), &mut out, 22) },
            0
        );
        let _ = take(out);
        unsafe { pm_crypto_device_destroy(fixture.source) };
        fixture.source = ptr::null_mut();
        assert!(matches!(
            unsafe { &*stream.0 }.state.lock().unwrap().mode,
            Mode::Closed
        ));
        assert!(!LARGE_STREAM.load(Ordering::Acquire));
        assert_eq!(read(&stream, 0, 1), Err(PM_CRYPTO_ERROR));
        assert_eq!(write(&stream, 0, &[1]), Err(PM_CRYPTO_ERROR));
        let next = Fixture::new();
        let next_stream = Stream(next.start(0).unwrap());
        let metadata = finish(&next_stream, next.source, 22).unwrap();
        assert!(handoff(&metadata).len() < 8192);
    }

    #[test]
    #[ignore = "measurement: run alone with --exact --ignored --nocapture"]
    fn maximum_bundle_allocation_measurement() {
        let _serial = TEST_SERIAL.lock().unwrap();
        let fixture = Fixture::new();
        let chunk = vec![0x5a; MAX_ATTACHMENT_CHUNK];
        let baseline = crate::test_memory::begin();
        let length = history::MAX_PADDED_HISTORY - 8;
        let path = std::env::temp_dir().join(format!(
            "veritra-k2-ciphertext-measure-{}.bin",
            std::process::id()
        ));
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        let source = Stream(fixture.start(length).unwrap());
        let mut offset = 0;
        while offset < length {
            let n = (length - offset).min(chunk.len());
            write(&source, offset, &chunk[..n]).unwrap();
            offset += n;
        }
        let metadata = finish(&source, fixture.source, 22).unwrap();
        let h = handoff(&metadata);
        offset = 0;
        loop {
            let value = read(&source, offset, MAX_ATTACHMENT_CHUNK).unwrap();
            offset = u64::from_be_bytes(value[7..15].try_into().unwrap()) as usize;
            file.write_all(&value[20..]).unwrap();
            if value[15] == 1 {
                break;
            }
        }
        file.sync_all().unwrap();
        drop(source);
        let (receiver, _) = fixture.receive(&h).unwrap();
        let receiver = Stream(receiver);
        file.seek(SeekFrom::Start(0)).unwrap();
        let mut input = vec![0; MAX_ATTACHMENT_CHUNK];
        offset = 0;
        loop {
            let n = file.read(&mut input).unwrap();
            if n == 0 {
                break;
            }
            write(&receiver, offset, &input[..n]).unwrap();
            offset += n;
        }
        let opened = finish(&receiver, fixture.recipient, 24).unwrap();
        assert_eq!(
            u64::from_be_bytes(opened[7..15].try_into().unwrap()) as usize,
            length
        );
        offset = 0;
        loop {
            let value = read(&receiver, offset, MAX_ATTACHMENT_CHUNK).unwrap();
            assert!(value[20..].iter().all(|v| *v == 0x5a));
            offset = u64::from_be_bytes(value[7..15].try_into().unwrap()) as usize;
            if value[15] == 1 {
                break;
            }
        }
        assert_eq!(offset, length);
        drop(receiver);
        drop(file);
        std::fs::remove_file(path).unwrap();
        let peak = crate::test_memory::peak_extra(baseline);
        println!("K2_CAP payload_bytes={length} padded_bytes={} peak_extra_allocated_bytes={peak} baseline_bytes={baseline}",history::MAX_PADDED_HISTORY);
        assert!(
            peak <= 200 * 1024 * 1024,
            "{peak} exceeds200MiB working allocation budget"
        );
    }
}
