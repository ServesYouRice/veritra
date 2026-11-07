//! D70 section 7 measurements: what sealing and activating cost with 1, 100
//! and 1,000 groups of 100 members, format 3 (one flat blob) against format
//! 4 (one record per group plus a root). Ignored in `cargo test`; run one
//! size per process so peak RSS belongs to that size:
//!
//! ```text
//! D70_GROUPS=100 cargo test --locked --release --test d70_seal_cost -- --ignored --nocapture
//! ```
//!
//! Results are recorded in `testing/evidence/D70-per-group-sealed-state.md`.

use std::time::Instant;

use private_messenger_crypto::mls::{ChangeSet, MemberAdd, MlsDevice, RestoreLoader};

const KEY: [u8; 32] = [0x55; 32];
const MEMBERS: usize = 100;

fn status_kib(field: &str) -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .unwrap()
        .lines()
        .find(|line| line.starts_with(field))
        .and_then(|line| line.split_whitespace().nth(1)?.parse().ok())
        .unwrap_or(0)
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    values[values.len() / 2]
}

fn bytes(set: &ChangeSet) -> usize {
    set.root.len()
        + set
            .changes
            .iter()
            .filter_map(|change| change.sealed.as_ref())
            .map(Vec::len)
            .sum::<usize>()
}

#[test]
#[ignore = "measurement; run in release with D70_GROUPS"]
fn seal_cost() {
    let groups: usize = std::env::var("D70_GROUPS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(1);
    let (account, device_id) = (b"acct_bench".to_vec(), b"dev_bench".to_vec());
    let mut device = MlsDevice::new(&account, &device_id).unwrap();

    // 99 other devices; their key packages are reused for every group.
    let others: Vec<(Vec<u8>, Vec<u8>, Vec<u8>)> = (0..MEMBERS - 1)
        .map(|i| {
            let a = format!("acct_m{i}").into_bytes();
            let d = format!("dev_m{i}").into_bytes();
            let package = MlsDevice::new(&a, &d)
                .unwrap()
                .create_key_package()
                .unwrap();
            (a, d, package)
        })
        .collect();
    let adds: Vec<MemberAdd> = others
        .iter()
        .map(|(a, d, p)| MemberAdd {
            key_package: p,
            account_id: a,
            device_id: d,
        })
        .collect();
    let ids: Vec<Vec<u8>> = (0..groups)
        .map(|i| format!("conv_{i:05}").into_bytes())
        .collect();
    let started = Instant::now();
    for id in &ids {
        let mut group = device.create_group(id).unwrap();
        device
            .stage_membership_commit(&mut group, &adds, &[])
            .unwrap();
        device.merge_pending_commit(&mut group).unwrap();
        assert_eq!(group.members().count(), MEMBERS);
    }
    let build_s = started.elapsed().as_secs_f64();
    let rss_built = status_kib("VmRSS:");

    let message = |device: &mut MlsDevice, i: usize| {
        let mut group = device.load_group(&ids[i % groups]).unwrap();
        device.encrypt(&mut group, b"bench message").unwrap();
    };

    // Format 3: every seal writes the whole state. At the cap it is refused.
    let mut v3_ms = Vec::new();
    let mut v3 = None;
    let mut v3_refused = false;
    for i in 0..5usize {
        message(&mut device, i);
        let t = Instant::now();
        match device.seal_state(&KEY, 1 + i as u64) {
            Ok(blob) => {
                v3_ms.push(t.elapsed().as_secs_f64() * 1e3);
                v3 = Some(blob);
            }
            Err(error) => {
                println!(
                    "D70_RESULT v3 seal refused: {error:?} after {:.1} ms",
                    t.elapsed().as_secs_f64() * 1e3
                );
                v3_refused = true;
                break;
            }
        }
    }
    let (v3_bytes, v3_median, v3_restore_ms) = match &v3 {
        Some(blob) => {
            let t = Instant::now();
            let _ = MlsDevice::restore_state(&account, &device_id, &KEY, 5, blob).unwrap();
            (blob.len(), median(v3_ms), t.elapsed().as_secs_f64() * 1e3)
        }
        None => (0, f64::NAN, f64::NAN),
    };
    let _ = v3_refused;
    let rss_v3_peak = status_kib("VmHWM:");

    // Format 4: the first seal writes every record, then one group per message.
    let first = device.seal_changes(&KEY, 1).unwrap();
    let first_bytes = bytes(&first);
    let records: Vec<Vec<u8>> = first
        .changes
        .iter()
        .filter_map(|change| change.sealed.clone())
        .collect();
    let root = first.root.clone();
    let mut v4_ms = Vec::new();
    let mut v4_bytes = Vec::new();
    for i in 0..20usize {
        message(&mut device, i * 7);
        let t = Instant::now();
        let set = device.seal_changes(&KEY, 2 + i as u64).unwrap();
        v4_ms.push(t.elapsed().as_secs_f64() * 1e3);
        assert_eq!(set.changes.len(), 1);
        v4_bytes.push(bytes(&set));
    }
    v4_bytes.sort();
    // Activation from the generation-1 table (every record).
    let t = Instant::now();
    let mut loader = RestoreLoader::begin(&account, &device_id, &KEY, 1, &root).unwrap();
    for sealed in &records {
        loader.add(sealed).unwrap();
    }
    let (restored, _) = loader.finish().unwrap();
    let v4_restore_ms = t.elapsed().as_secs_f64() * 1e3;
    drop(restored);
    let rss_peak = status_kib("VmHWM:");

    println!("D70_RESULT groups={groups} members={MEMBERS} build_s={build_s:.1}");
    println!(
        "D70_RESULT rss_after_build_mib={:.0} peak_rss_after_v3_mib={:.0} peak_rss_final_mib={:.0}",
        rss_built as f64 / 1024.0,
        rss_v3_peak as f64 / 1024.0,
        rss_peak as f64 / 1024.0
    );
    println!(
        "D70_RESULT v3 bytes_per_seal={} ms_per_seal_median={:.2} activation_ms={v3_restore_ms:.1}",
        v3_bytes, v3_median
    );
    println!(
        "D70_RESULT v4 first_seal_bytes={first_bytes} bytes_per_message_median={} root_bytes={} ms_per_seal_median={:.2} activation_ms={v4_restore_ms:.1}",
        v4_bytes[v4_bytes.len() / 2],
        root.len(),
        median(v4_ms)
    );
}
