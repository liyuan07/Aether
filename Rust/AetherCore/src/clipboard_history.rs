// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::abi::Uuid;
use std::collections::HashSet;

// The platform supplies primitive Swift String/Data equality. Core chooses which fields define identity.
// Kinds: text=0,url=1,file=2,image=3,rtf=4,unknown=5.
// Flags: text equal=1,both hashes=2,hash equal=4,image filename equal=8,file URLs equal=16,
// RTF comparison supplied=32,RTF bytes equal=64.
fn comparison_fields(kind: u8, other_kind: u8, both_hashes: u8) -> u8 {
    if kind != other_kind {
        return 0;
    }
    match kind {
        3 => {
            if both_hashes != 0 {
                4
            } else {
                8
            }
        }
        2 => 16,
        _ => 1,
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_content_fields(kind: u8, other_kind: u8, both_hashes: u8) -> u8 {
    comparison_fields(kind, other_kind, both_hashes)
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_content_match(kind: u8, other_kind: u8, flags: u8) -> u8 {
    let fields = comparison_fields(kind, other_kind, flags & 2);
    if fields == 0 || flags & fields == 0 {
        return 0;
    }
    if kind == 4 {
        if flags & 32 == 0 {
            return 2;
        }
        return u8::from(flags & 64 != 0);
    }
    1
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_history_bounded(count: usize, limit: usize) -> u8 {
    u8::from(count <= limit)
}
/// Group identity deliberately compares persisted fields rather than capture content identity.
/// # Safety
/// If counts are equal and nonzero, flags point to at least left_count readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_group_equal(
    flags: *const u8,
    left_count: usize,
    right_count: usize,
) -> u8 {
    if left_count != right_count {
        return 0;
    }
    if left_count == 0 {
        return 1;
    }
    if flags.is_null() {
        return 0;
    }
    u8::from(
        unsafe { std::slice::from_raw_parts(flags, left_count) }
            .iter()
            .all(|v| v & 31 == 31),
    )
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Row {
    pub id: Uuid,
    pub timestamp: f64,
    pub kind: u8,
    pub matching: u8,
    pub protected: u8,
    pub valid: u8,
}
impl Row {
    fn payload(self) -> bool {
        self.kind == 3 || self.kind == 4
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Result {
    pub count: usize,
    pub inserted: u8,
    pub cleanup: u8,
}
fn trim(indices: &mut Vec<usize>, rows: &[Row], candidate: Row, limit: usize) -> bool {
    let Some(excess) = indices.len().checked_sub(limit) else {
        return false;
    };
    if excess == 0 {
        return false;
    }
    let row = |i: usize| if i == rows.len() { candidate } else { rows[i] };
    let mut removed = 0;
    let mut cleanup = false;
    // One reverse scan replaces repeated removal from the middle of a large history.
    for value in indices.iter_mut().rev() {
        let item = row(*value);
        if removed < excess && item.protected == 0 {
            cleanup |= item.payload();
            *value = usize::MAX;
            removed += 1;
        }
    }
    indices.retain(|&i| i != usize::MAX);
    if indices.len() > limit {
        cleanup |= indices[limit..].iter().any(|&i| row(i).payload());
        indices.truncate(limit);
    }
    cleanup
}
/// Actions: 0 insert, 1 trim, 2 valid/expiry selection, 3 matching IDs, 4 remove matching, 5 unique IDs.
/// Index rows.len() represents the candidate; no clipboard text crosses this planning ABI.
/// # Safety
/// Rows point to count readable elements; output points to capacity writable indices.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_history_plan(
    rows: *const Row,
    count: usize,
    candidate: Row,
    action: u8,
    limit: usize,
    cutoff: f64,
    has_cutoff: u8,
    output: *mut usize,
    capacity: usize,
) -> Result {
    if count > 0 && rows.is_null() {
        return Result::default();
    }
    let rows = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(rows, count) }
    };
    let mut result = Result::default();
    let mut indices = match action {
        0 => {
            if rows
                .iter()
                .any(|r| r.matching != 0 && r.timestamp >= candidate.timestamp)
            {
                result.cleanup = u8::from(candidate.kind == 4);
                (0..count).collect::<Vec<_>>()
            } else {
                let duplicate_ids: HashSet<_> = rows
                    .iter()
                    .filter(|r| r.matching != 0)
                    .map(|r| r.id)
                    .collect();
                result.cleanup = u8::from(rows.iter().any(|r| r.matching != 0 && r.payload()));
                let mut indices: Vec<_> = rows
                    .iter()
                    .enumerate()
                    .filter(|(_, r)| !duplicate_ids.contains(&r.id))
                    .map(|(i, _)| i)
                    .collect();
                let at = indices
                    .iter()
                    .position(|&i| rows[i].timestamp < candidate.timestamp)
                    .unwrap_or(indices.len());
                indices.insert(at, count);
                result.inserted = 1;
                indices
            }
        }
        1 => (0..count).collect(),
        2 => rows
            .iter()
            .enumerate()
            .filter(|(_, r)| r.valid != 0 && (has_cutoff == 0 || !(r.timestamp < cutoff)))
            .take(limit)
            .map(|(i, _)| i)
            .collect(),
        3 => rows
            .iter()
            .enumerate()
            .filter(|(_, r)| r.matching != 0)
            .map(|(i, _)| i)
            .collect(),
        4 => rows
            .iter()
            .enumerate()
            .filter(|(_, r)| r.matching == 0)
            .map(|(i, _)| i)
            .collect(),
        5 => {
            let mut seen = HashSet::new();
            rows.iter()
                .enumerate()
                .filter(|(_, r)| seen.insert(r.id))
                .map(|(i, _)| i)
                .collect()
        }
        _ => return result,
    };
    if action == 1 || (action == 0 && result.inserted != 0) {
        result.cleanup |= u8::from(trim(&mut indices, rows, candidate, limit));
    }
    result.count = indices.len();
    if result.count > capacity || (result.count > 0 && output.is_null()) {
        return Result::default();
    }
    if result.count > 0 {
        unsafe {
            std::ptr::copy_nonoverlapping(indices.as_ptr(), output, result.count);
        }
    }
    result
}

#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_tab_includes(tab: u8, kind: u8, pinned: u8) -> u8 {
    let included = match tab {
        0 => pinned == 0,
        1 => pinned == 0 && matches!(kind, 0 | 1 | 4 | 5),
        2 => pinned == 0 && kind == 3,
        3 => pinned == 0 && kind == 2,
        4 => pinned != 0,
        _ => false,
    };
    u8::from(included)
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct PinResult {
    pub history_count: usize,
    pub pinned_count: usize,
    pub pinned: u8,
}
/// # Safety
/// All input/output spans are readable/writable for their counts and capacities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_pin_plan(
    history: *const Row,
    history_count: usize,
    pinned: *const Row,
    pinned_count: usize,
    candidate: Row,
    candidate_pinned: u8,
    action: u8,
    limit: usize,
    history_output: *mut usize,
    history_capacity: usize,
    pinned_output: *mut usize,
    pinned_capacity: usize,
) -> PinResult {
    if (history_count > 0 && history.is_null()) || (pinned_count > 0 && pinned.is_null()) {
        return PinResult::default();
    }
    let history = if history_count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(history, history_count) }
    };
    let pinned = if pinned_count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(pinned, pinned_count) }
    };
    let unpin = action == 1
        || (action == 2 && (candidate_pinned != 0 || pinned.iter().any(|r| r.id == candidate.id)));
    let mut h: Vec<_> = (0..history_count).collect();
    let mut p: Vec<_> = (0..pinned_count).collect();
    if unpin {
        p.retain(|&i| pinned[i].id != candidate.id);
        h.insert(0, history_count);
        trim(&mut h, history, candidate, limit);
    } else {
        h.retain(|&i| history[i].id != candidate.id);
        if !pinned.iter().any(|r| r.id == candidate.id) {
            p.insert(0, pinned_count);
        }
    }
    if h.len() > history_capacity
        || p.len() > pinned_capacity
        || (!h.is_empty() && history_output.is_null())
        || (!p.is_empty() && pinned_output.is_null())
    {
        return PinResult::default();
    }
    unsafe {
        if !h.is_empty() {
            std::ptr::copy_nonoverlapping(h.as_ptr(), history_output, h.len());
        }
        if !p.is_empty() {
            std::ptr::copy_nonoverlapping(p.as_ptr(), pinned_output, p.len());
        }
    }
    PinResult {
        history_count: h.len(),
        pinned_count: p.len(),
        pinned: u8::from(!unpin),
    }
}
