// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Capture {
    pub last_change: i64,
    pub pending_change: i64,
    pub pending: u8,
    pub failures: u8,
    pub needed: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_capture_probe(mut s: Capture, change: i64) -> Capture {
    s.needed = 0;
    if change == s.last_change {
        s.pending = 0;
        s.failures = 0;
        return s;
    }
    if s.pending == 0 || s.pending_change != change {
        s.pending_change = change;
        s.pending = 1;
        s.failures = 0;
    }
    s.needed = 1;
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_capture_failed(mut s: Capture, change: i64) -> Capture {
    s.failures = s.failures.saturating_add(1);
    s.needed = 0;
    if s.failures >= 4 {
        s.last_change = change;
        s.pending = 0;
        s.failures = 0;
    }
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_capture_observed(mut s: Capture, change: i64) -> Capture {
    s.last_change = change;
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_capture_committed(mut s: Capture, change: i64) -> Capture {
    s.last_change = change;
    s.pending = 0;
    s.failures = 0;
    s.needed = 0;
    s
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Work {
    pub history_revision: u64,
    pub maintenance_generation: u64,
    pub last_maintenance: f64,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_history_changed(mut s: Work) -> Work {
    s.history_revision = s.history_revision.wrapping_add(1);
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_maintenance_begin(mut s: Work, now: f64) -> Work {
    s.maintenance_generation = s.maintenance_generation.wrapping_add(1);
    s.last_maintenance = now;
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_revision_current(s: Work, revision: u64) -> u8 {
    u8::from(s.history_revision == revision)
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_maintenance_current(s: Work, generation: u64) -> u8 {
    u8::from(s.maintenance_generation == generation)
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_maintenance_due(s: Work, now: f64) -> u8 {
    u8::from(now - s.last_maintenance >= 86400.0)
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Writer {
    pub pending: u8,
    pub cleanup: u8,
    pub scheduled: u8,
    pub schedule: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_writer_enqueue(mut s: Writer, cleanup: u8) -> Writer {
    s.pending = 1;
    s.cleanup = u8::from(s.cleanup != 0 || cleanup != 0);
    s.schedule = u8::from(s.scheduled == 0);
    s.scheduled = 1;
    s
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct WriteStep {
    pub state: Writer,
    pub write: u8,
    pub cleanup: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_writer_take(s: Writer) -> WriteStep {
    WriteStep {
        state: Writer::default(),
        write: s.pending,
        cleanup: s.cleanup,
    }
}

use crate::abi::Bytes;
use std::collections::HashSet;
/// Names are canonically normalized by the platform before this borrowed-byte call.
/// # Safety
/// Spans and their bytes remain readable; output is writable for capacity indices.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_resource_plan(
    kept: *const Bytes,
    kept_count: usize,
    files: *const Bytes,
    file_count: usize,
    output: *mut usize,
    capacity: usize,
) -> usize {
    if (kept_count > 0 && kept.is_null()) || (file_count > 0 && files.is_null()) {
        return 0;
    }
    let kept = if kept_count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(kept, kept_count) }
    };
    let files = if file_count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(files, file_count) }
    };
    let mut names = HashSet::with_capacity(kept.len());
    for name in kept {
        let Some(bytes) = (unsafe { name.slice() }) else {
            return 0;
        };
        names.insert(bytes);
    }
    let mut indices = Vec::new();
    for (i, name) in files.iter().enumerate() {
        let Some(bytes) = (unsafe { name.slice() }) else {
            return 0;
        };
        if !names.contains(bytes) {
            indices.push(i);
        }
    }
    if indices.len() > capacity || (!indices.is_empty() && output.is_null()) {
        return 0;
    }
    if !indices.is_empty() {
        unsafe {
            std::ptr::copy_nonoverlapping(indices.as_ptr(), output, indices.len());
        }
    }
    indices.len()
}
