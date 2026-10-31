//! Test-only live-allocation measurement. No allocator override in the library.
use std::{
    alloc::{GlobalAlloc, Layout, System},
    cell::Cell,
    sync::atomic::{AtomicUsize, Ordering},
};
struct Counting;
#[global_allocator]
static ALLOCATOR: Counting = Counting;
static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
fn add(bytes: usize) {
    let now = LIVE.fetch_add(bytes, Ordering::Relaxed) + bytes;
    PEAK.fetch_max(now, Ordering::Relaxed);
}
// Per-thread secret watch: while set, every block this thread hands back to
// the allocator (dealloc, or the source of a realloc) is scanned for a run of
// the marker byte. Const-initialized, so reading it never allocates.
thread_local! {
    static WATCH: Cell<Option<u8>> = const { Cell::new(None) };
    static LEAKED: Cell<usize> = const { Cell::new(0) };
}
const MARKER_RUN: usize = 32;
fn scan(p: *const u8, size: usize) {
    let Ok(Some(marker)) = WATCH.try_with(Cell::get) else {
        return;
    };
    // SAFETY: p is a live block of `size` bytes owned by the caller of
    // dealloc/realloc, read before it is released.
    let bytes = unsafe { core::slice::from_raw_parts(p, size) };
    let mut run = 0;
    for byte in bytes {
        run = if *byte == marker { run + 1 } else { 0 };
        if run == MARKER_RUN {
            let _ = LEAKED.try_with(|count| count.set(count.get() + 1));
            return;
        }
    }
}
// SAFETY: All allocation/layout contracts delegate unchanged to System.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(layout) };
        if !p.is_null() {
            add(layout.size());
        }
        p
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { System.alloc_zeroed(layout) };
        if !p.is_null() {
            add(layout.size());
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
        scan(p, layout.size());
        unsafe { System.dealloc(p, layout) };
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
    }
    unsafe fn realloc(&self, p: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        // realloc may move the block and free the source without wiping it.
        scan(p, layout.size());
        let next = unsafe { System.realloc(p, layout, size) };
        if !next.is_null() {
            LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
            add(size);
        }
        next
    }
}
pub(crate) fn begin() -> usize {
    let baseline = LIVE.load(Ordering::Relaxed);
    PEAK.store(baseline, Ordering::Relaxed);
    baseline
}
pub(crate) fn peak_extra(baseline: usize) -> usize {
    PEAK.load(Ordering::Relaxed).saturating_sub(baseline)
}
/// Starts counting this thread's released blocks that still hold `marker`.
pub(crate) fn watch_secret(marker: u8) {
    LEAKED.with(|count| count.set(0));
    WATCH.with(|watch| watch.set(Some(marker)));
}
/// Stops the watch and returns how many released blocks held the marker.
pub(crate) fn unwiped_releases() -> usize {
    WATCH.with(|watch| watch.set(None));
    LEAKED.with(Cell::get)
}
