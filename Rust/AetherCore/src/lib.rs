// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use std::ffi::c_void;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Countdown {
    pub value: f64,
    pub phase: u32,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_core_abi_version() -> u32 {
    1
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_countdown_start(state: Countdown, duration: f64, now: f64) -> Countdown {
    if !duration.is_finite() || duration <= 0.0 {
        state
    } else {
        Countdown {
            value: now + duration,
            phase: 1,
        }
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_countdown_remaining(state: Countdown, now: f64) -> f64 {
    match state.phase {
        1 => state.value - now,
        2 => state.value,
        _ => 0.0,
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_countdown_pause(state: Countdown, now: f64) -> Countdown {
    if state.phase == 1 {
        Countdown {
            value: state.value - now,
            phase: 2,
        }
    } else {
        state
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_countdown_resume(state: Countdown, now: f64) -> Countdown {
    if state.phase == 2 {
        Countdown {
            value: now + state.value,
            phase: 1,
        }
    } else {
        state
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Guide {
    pub required: u16,
    pub held: u8,
    pub cancelled: u8,
    pub visible: u8,
    pub transition: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_guide_update(mut s: Guide, active: u16, event: u8) -> Guide {
    s.transition = 0;
    match event {
        0 => {
            let held = active & s.required == s.required;
            if held && s.held == 0 {
                s.held = 1;
                s.cancelled = 0;
                s.visible = 0;
                s.transition = 1;
            } else if !held && s.held != 0 {
                s.transition = if s.visible != 0 { 4 } else { 3 };
                s.held = 0;
                s.cancelled = 0;
                s.visible = 0;
            }
        }
        1 if s.held != 0 => {
            s.cancelled = 1;
            s.visible = 0;
            s.transition = 3;
        }
        2 if s.held != 0 && s.cancelled == 0 && s.visible == 0 => {
            s.visible = 1;
            s.transition = 2;
        }
        _ => {}
    }
    s
}

struct Segment {
    bytes: Vec<u8>,
    boundaries: Vec<usize>,
    character_count: usize,
    mask: u128,
    numeric: bool,
}
impl Segment {
    fn boundary(&self, index: usize) -> usize {
        if self.boundaries.is_empty() {
            index
        } else {
            self.boundaries[index]
        }
    }
    fn position(&self, byte: usize) -> Option<usize> {
        if self.boundaries.is_empty() {
            Some(byte)
        } else {
            self.boundaries.binary_search(&byte).ok()
        }
    }
    fn score(&self, segment: &Self) -> i32 {
        let qn = self.character_count;
        let sn = segment.character_count;
        if qn == 0 || sn == 0 {
            return -1;
        }
        // Search only at Character boundaries, matching Swift String's semantics.
        // UTF-8 is validated at creation; Rust's substring search avoids walking
        // every grapheme for the overwhelmingly common ASCII/history path.
        let haystack = unsafe { std::str::from_utf8_unchecked(&segment.bytes) };
        let needle = unsafe { std::str::from_utf8_unchecked(&self.bytes) };
        for (start, _) in haystack.match_indices(needle) {
            let end = start + self.bytes.len();
            if let Some(position) = segment.position(start) {
                if segment.position(end).is_some() {
                    return if position == 0 {
                        20_000 - sn.min(5_000) as i32
                    } else {
                        15_000 - position.min(5_000) as i32
                    };
                }
            }
        }
        if self.numeric || qn > 16 || sn > 1_024 || segment.mask & self.mask != self.mask {
            return -1;
        }
        let mut qi = 0;
        let mut first = None;
        let mut last = 0;
        let mut previous = None;
        let mut pairs = 0;
        let max_span = (qn + 8).max(qn * 3);
        for si in 0..sn {
            if first.is_some_and(|f| si - f + 1 > max_span) {
                return -1;
            }
            if segment.bytes[segment.boundary(si)..segment.boundary(si + 1)]
                != self.bytes[self.boundary(qi)..self.boundary(qi + 1)]
            {
                continue;
            }
            if first.is_none() {
                first = Some(si);
            }
            if previous == si.checked_sub(1) && previous.is_some() {
                pairs += 1;
            }
            previous = Some(si);
            last = si;
            qi += 1;
            if qi == qn {
                break;
            }
        }
        if qi != qn {
            return -1;
        }
        let first = first.unwrap_or(0);
        1_000 + qn as i32 * 40 + pairs * 25 - (last - first + 1) as i32 - first as i32
    }
}
/// # Safety
/// Buffers must be readable for the provided lengths during this call. Boundaries
/// include zero and the final byte length and must delimit canonical graphemes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_create(
    bytes: *const u8,
    length: usize,
    boundaries: *const usize,
    count: usize,
    numeric: u8,
) -> *mut c_void {
    if bytes.is_null() {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(bytes, length) };
    if std::str::from_utf8(bytes).is_err() {
        return std::ptr::null_mut();
    }
    let boundaries = if boundaries.is_null() {
        if !bytes.is_ascii() {
            return std::ptr::null_mut();
        }
        &[][..]
    } else {
        if count == 0 {
            return std::ptr::null_mut();
        }
        let boundaries = unsafe { std::slice::from_raw_parts(boundaries, count) };
        if boundaries[0] != 0
            || boundaries[count - 1] != length
            || boundaries.windows(2).any(|v| v[0] >= v[1])
        {
            return std::ptr::null_mut();
        }
        boundaries
    };
    let owned_boundaries = if boundaries.is_empty() && bytes.windows(2).any(|v| v == b"\r\n") {
        (0..=length)
            .filter(|&i| i == 0 || i == length || !(bytes[i - 1] == b'\r' && bytes[i] == b'\n'))
            .collect()
    } else {
        boundaries.to_vec()
    };
    let character_count = if owned_boundaries.is_empty() {
        length
    } else {
        owned_boundaries.len() - 1
    };
    let mask = bytes
        .iter()
        .filter(|b| **b < 128)
        .fold(0, |mask, b| mask | (1_u128 << b));
    Box::into_raw(Box::new(Segment {
        bytes: bytes.to_vec(),
        boundaries: owned_boundaries,
        character_count,
        mask,
        numeric: numeric != 0,
    }))
    .cast()
}
/// # Safety
/// The pointer is either null or a live handle returned by create, freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_destroy(segment: *mut c_void) {
    if !segment.is_null() {
        drop(unsafe { Box::from_raw(segment.cast::<Segment>()) });
    }
}
/// # Safety
/// Both pointers must be live immutable handles returned by create for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_score(query: *const c_void, segment: *const c_void) -> i32 {
    if query.is_null() || segment.is_null() {
        return -1;
    }
    unsafe { (&*query.cast::<Segment>()).score(&*segment.cast::<Segment>()) }
}
/// Scores a document in one bridge call, borrowing each immutable segment.
/// # Safety
/// Query and non-null segment handles are live for this call. The pointer span is readable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_best_score(
    query: *const c_void,
    segments: *const *const c_void,
    count: usize,
) -> i32 {
    if query.is_null() || (count != 0 && segments.is_null()) {
        return -1;
    }
    let segments = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(segments, count) }
    };
    let query = unsafe { &*query.cast::<Segment>() };
    segments
        .iter()
        .filter(|segment| !segment.is_null())
        .map(|segment| unsafe { query.score(&*segment.cast::<Segment>()) })
        .max()
        .unwrap_or(-1)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn countdown_preserves_overtime_and_value_semantics() {
        let s = aether_countdown_start(Countdown::default(), 10.0, 0.0);
        let p = aether_countdown_pause(s, 15.0);
        assert_eq!(
            aether_countdown_remaining(aether_countdown_resume(p, 100.0), 103.0),
            -8.0
        );
        assert_eq!(aether_countdown_remaining(s, 5.0), 5.0);
        assert_eq!(aether_countdown_start(s, f64::NAN, 5.0).value, s.value);
    }
    #[test]
    fn guide_cancel_cannot_show_until_release() {
        let s = aether_guide_update(
            Guide {
                required: 3,
                ..Guide::default()
            },
            3,
            0,
        );
        assert_eq!(s.transition, 1);
        let s = aether_guide_update(s, 0, 1);
        assert_eq!(aether_guide_update(s, 0, 2).transition, 0);
        assert_eq!(aether_guide_update(s, 0, 0).transition, 3);
    }
    fn ascii(s: &str, numeric: bool) -> Segment {
        Segment {
            bytes: s.as_bytes().to_vec(),
            boundaries: vec![],
            character_count: s.len(),
            mask: s.bytes().fold(0, |m, b| m | 1_u128 << b),
            numeric,
        }
    }
    #[test]
    fn search_contract() {
        assert_eq!(
            ascii("clipman", false).score(&ascii("clipboard manager", false)),
            1_392
        );
        assert_eq!(ascii("123", true).score(&ascii("1x2x3", false)), -1);
        assert_eq!(ascii("abc", false).score(&ascii("abcde", false)), 19_995);
        assert_eq!(ascii("abc", false).score(&ascii("xxabc", false)), 14_998);
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct EyeCare {
    pub value: f64,
    pub away_date: f64,
    pub phase: u32,
    pub paused_phase: u32,
    pub reason: u32,
    pub away_active: u8,
    pub changed: u8,
}
impl EyeCare {
    fn start(&mut self, now: f64, duration: f64) {
        self.away_active = 0;
        self.phase = 1;
        self.value = now + duration.max(0.0);
    }
    fn pause(&mut self, now: f64, reason: u32) -> bool {
        match self.phase {
            1 | 2 => {
                self.paused_phase = self.phase;
                self.value = (self.value - now).max(0.0);
            }
            3 => {
                self.paused_phase = 3;
                self.value = 0.0;
            }
            4 if self.reason == 2 && reason == 1 => {
                self.away_active = 0;
            }
            _ => return false,
        }
        self.phase = 4;
        self.reason = reason;
        true
    }
    fn resume(&mut self, now: f64) -> bool {
        if self.phase != 4 {
            return false;
        }
        self.away_active = 0;
        self.phase = self.paused_phase;
        if self.phase == 1 || self.phase == 2 {
            self.value = now + self.value.max(0.0);
        }
        true
    }
}
// Events: start, stop, advance, pause, resume, complete, away, return.
#[unsafe(no_mangle)]
pub extern "C" fn aether_eyecare_event(
    mut s: EyeCare,
    event: u32,
    now: f64,
    duration: f64,
    threshold: f64,
    reason: u32,
) -> EyeCare {
    s.changed = 0;
    let changed = match event {
        0 => {
            s.start(now, duration);
            true
        }
        1 => {
            s.away_active = 0;
            s.phase = 0;
            true
        }
        2 if s.phase == 1 && s.value <= now => {
            s.phase = 2;
            s.value = now + duration.max(0.0);
            true
        }
        2 if s.phase == 2 && s.value <= now => {
            s.phase = 3;
            true
        }
        3 => s.pause(now, reason),
        4 => s.resume(now),
        5 if s.phase == 3 => {
            s.start(now, duration);
            true
        }
        6 if s.phase != 0 && s.phase != 4 => {
            s.away_date = now;
            s.away_active = 1;
            s.pause(now, 2)
        }
        7 if s.phase == 4 && s.reason == 2 && s.away_active != 0 => {
            if now - s.away_date >= threshold.max(0.0) {
                s.start(now, duration);
                true
            } else {
                s.resume(now)
            }
        }
        _ => false,
    };
    s.changed = u8::from(changed);
    s
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_eyecare_remaining(s: EyeCare, now: f64) -> f64 {
    match s.phase {
        1 | 2 => (s.value - now).max(0.0),
        4 => s.value.max(0.0),
        _ => 0.0,
    }
}

mod geometry;
mod memo;
mod prompt;
mod prompt_store;
mod shortcuts;
mod storage;
mod versioned;

mod quick_clipboard;

mod clipboard_history;

mod abi;

mod clipboard_schedule;

mod clipboard_archive;

mod json;

mod port_lifecycle;

mod port_history;

mod device_tree;

mod smc_contract;

mod port_policy;

mod port_power;

mod port_roster;

mod port_join;

mod port_transports;

mod port_decode;

mod abc_guard;
mod app_order;

mod port_enrichment;
mod preferences;
