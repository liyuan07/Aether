// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::collections::{BTreeMap, VecDeque};
#[repr(C)]
pub struct Reading {
    id: i64,
    watts: f64,
    active: u8,
    has_power: u8,
    incoming: u8,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Summary {
    active_count: usize,
    watts_in: f64,
    watts_out: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Sample {
    id: i64,
    timestamp: f64,
    watts: f64,
}
#[derive(Default)]
pub struct Snapshot {
    // Compatibility history: last 60 readings, including duplicate timestamps and IDs.
    // This deliberately differs from the live chart's time-pruned segmented history.
    history: BTreeMap<i64, VecDeque<Sample>>,
}
impl Snapshot {
    fn apply(&mut self, readings: &[Reading], now: f64) -> Summary {
        let mut summary = Summary::default();
        for reading in readings {
            summary.active_count += usize::from(reading.active != 0);
            if reading.has_power == 0 {
                continue;
            }
            if reading.incoming != 0 {
                summary.watts_in += reading.watts;
            } else {
                summary.watts_out += reading.watts;
            }
            let history = self
                .history
                .entry(reading.id)
                .or_insert_with(|| VecDeque::with_capacity(60));
            if history.len() == 60 {
                history.pop_front();
            }
            history.push_back(Sample {
                id: reading.id,
                timestamp: now,
                watts: reading.watts,
            });
        }
        summary
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_port_snapshot_create() -> *mut Snapshot {
    Box::into_raw(Box::default())
}
/// # Safety
/// Core is live and destroyed exactly once after all borrowers finish.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_snapshot_destroy(core: *mut Snapshot) {
    if !core.is_null() {
        drop(unsafe { Box::from_raw(core) });
    }
}
/// # Safety
/// Core is exclusively borrowed; readings contains count readable records.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_snapshot_apply(
    core: *mut Snapshot,
    readings: *const Reading,
    count: usize,
    now: f64,
) -> Summary {
    let Some(core) = (unsafe { core.as_mut() }) else {
        return Summary::default();
    };
    let rows = if count == 0 {
        &[]
    } else {
        if readings.is_null() {
            return Summary::default();
        }
        unsafe { std::slice::from_raw_parts(readings, count) }
    };
    core.apply(rows, now)
}
/// # Safety
/// Core is live and not concurrently mutated; output is writable for capacity samples.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_port_snapshot_samples(
    core: *const Snapshot,
    output: *mut Sample,
    capacity: usize,
) -> usize {
    let Some(core) = (unsafe { core.as_ref() }) else {
        return 0;
    };
    let count = core.history.values().map(VecDeque::len).sum();
    if !output.is_null() && capacity >= count {
        for (index, sample) in core
            .history
            .values()
            .flat_map(|history| history.iter())
            .enumerate()
        {
            unsafe {
                output.add(index).write(*sample);
            }
        }
    }
    count
}
