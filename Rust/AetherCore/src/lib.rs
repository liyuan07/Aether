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

// Most clipboard segments are short. Preserve every native grapheme boundary
// while storing offsets in the narrowest lossless representation.
enum Boundaries {
    Implicit,
    U8(Box<[u8]>),
    U16(Box<[u16]>),
    U32(Box<[u32]>),
    Native(Box<[usize]>),
}
impl Boundaries {
    fn new(values: &[usize]) -> Self {
        let Some(&last) = values.last() else {
            return Self::Implicit;
        };
        if u8::try_from(last).is_ok() {
            Self::U8(values.iter().map(|&v| v as u8).collect())
        } else if u16::try_from(last).is_ok() {
            Self::U16(values.iter().map(|&v| v as u16).collect())
        } else if u32::try_from(last).is_ok() {
            Self::U32(values.iter().map(|&v| v as u32).collect())
        } else {
            Self::Native(values.into())
        }
    }
    fn boundary(&self, index: usize) -> usize {
        match self {
            Self::Implicit => index,
            Self::U8(v) => v[index] as usize,
            Self::U16(v) => v[index] as usize,
            Self::U32(v) => v[index] as usize,
            Self::Native(v) => v[index],
        }
    }
    fn position(&self, byte: usize) -> Option<usize> {
        match self {
            Self::Implicit => Some(byte),
            Self::U8(v) => v.binary_search(&u8::try_from(byte).ok()?).ok(),
            Self::U16(v) => v.binary_search(&u16::try_from(byte).ok()?).ok(),
            Self::U32(v) => v.binary_search(&u32::try_from(byte).ok()?).ok(),
            Self::Native(v) => v.binary_search(&byte).ok(),
        }
    }
}

struct Segment {
    bytes: Vec<u8>,
    boundaries: Boundaries,
    character_count: usize,
    mask: u128,
    numeric: bool,
}
impl Segment {
    fn boundary(&self, index: usize) -> usize {
        self.boundaries.boundary(index)
    }
    fn position(&self, byte: usize) -> Option<usize> {
        self.boundaries.position(byte)
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
    std::sync::Arc::into_raw(std::sync::Arc::new(Segment {
        bytes: bytes.to_vec(),
        boundaries: Boundaries::new(&owned_boundaries),
        character_count,
        mask,
        numeric: numeric != 0,
    }))
    .cast_mut()
    .cast()
}
/// # Safety
/// The pointer is either null or a live handle returned by create, freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_destroy(segment: *mut c_void) {
    if !segment.is_null() {
        drop(unsafe { std::sync::Arc::from_raw(segment.cast::<Segment>()) });
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
struct SearchDocument(Vec<std::sync::Arc<Segment>>);

#[repr(C)]
pub struct SearchRankEntry {
    pub score: isize,
    pub timestamp: f64,
}
/// # Safety
/// Entries are readable and order is writable for the given lengths, disjoint,
/// and valid for this call. Failure leaves output unchanged.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_rank(
    entries: *const SearchRankEntry,
    count: usize,
    order: *mut usize,
    capacity: usize,
) -> u8 {
    if count == 0 {
        return 1;
    }
    if entries.is_null() || order.is_null() || capacity < count {
        return 0;
    }
    let entries = unsafe { std::slice::from_raw_parts(entries, count) };
    if entries.iter().any(|entry| !entry.timestamp.is_finite()) {
        return 0;
    }
    let order = unsafe { std::slice::from_raw_parts_mut(order, count) };
    for (index, value) in order.iter_mut().enumerate() {
        *value = index;
    }
    order.sort_by(|&a, &b| {
        entries[b].score.cmp(&entries[a].score).then_with(|| {
            entries[b]
                .timestamp
                .partial_cmp(&entries[a].timestamp)
                .unwrap()
        })
    });
    1
}

/// # Safety
/// Span is readable; each non-null handle came from search_create and is live.
/// Returned document retains segments independently of the source handles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_document_create(
    segments: *const *const c_void,
    count: usize,
) -> *mut c_void {
    if count != 0 && segments.is_null() {
        return std::ptr::null_mut();
    }
    let span = if count == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(segments, count) }
    };
    let owned = span
        .iter()
        .filter(|p| !p.is_null())
        .map(|p| unsafe {
            let segment = p.cast::<Segment>();
            std::sync::Arc::increment_strong_count(segment);
            std::sync::Arc::from_raw(segment)
        })
        .collect();
    Box::into_raw(Box::new(SearchDocument(owned))).cast()
}

/// # Safety
/// Span and documents are live for this call. Result owns its own segment refs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_document_merge(
    documents: *const *const c_void,
    count: usize,
) -> *mut c_void {
    if count != 0 && documents.is_null() {
        return std::ptr::null_mut();
    }
    let span = if count == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(documents, count) }
    };
    let owned = span
        .iter()
        .filter(|p| !p.is_null())
        .flat_map(|p| unsafe { (&*p.cast::<SearchDocument>()).0.iter().cloned() })
        .collect();
    Box::into_raw(Box::new(SearchDocument(owned))).cast()
}

/// # Safety
/// Document is null or a live owned handle destroyed once, after scoring ends.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_document_destroy(document: *mut c_void) {
    if !document.is_null() {
        drop(unsafe { Box::from_raw(document.cast::<SearchDocument>()) });
    }
}

/// # Safety
/// Both handles are live and immutable for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_search_document_score(
    query: *const c_void,
    document: *const c_void,
) -> i32 {
    if query.is_null() || document.is_null() {
        return -1;
    }
    let query = unsafe { &*query.cast::<Segment>() };
    let document = unsafe { &*document.cast::<SearchDocument>() };
    document
        .0
        .iter()
        .map(|segment| query.score(segment))
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
            boundaries: Boundaries::Implicit,
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
    #[test]
    fn ranking_is_stable_and_refuses_invalid_spans_without_writes() {
        let entries = [
            SearchRankEntry {
                score: isize::MIN,
                timestamp: 9.0,
            },
            SearchRankEntry {
                score: isize::MAX,
                timestamp: -0.0,
            },
            SearchRankEntry {
                score: isize::MAX,
                timestamp: 0.0,
            },
            SearchRankEntry {
                score: isize::MAX,
                timestamp: 1.0,
            },
        ];
        let mut order = [99; 4];
        unsafe {
            assert_eq!(
                aether_search_rank(entries.as_ptr(), 4, order.as_mut_ptr(), 4),
                1
            );
            assert_eq!(order, [3, 1, 2, 0]);
            for timestamp in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
                assert_eq!(
                    aether_search_rank(
                        [SearchRankEntry {
                            score: 0,
                            timestamp
                        }]
                        .as_ptr(),
                        1,
                        order.as_mut_ptr(),
                        4
                    ),
                    0
                );
                assert_eq!(order, [3, 1, 2, 0]);
            }
            assert_eq!(
                aether_search_rank(entries.as_ptr(), 4, order.as_mut_ptr(), 3),
                0
            );
            assert_eq!(order, [3, 1, 2, 0]);
            assert_eq!(
                aether_search_rank(std::ptr::null(), 1, order.as_mut_ptr(), 4),
                0
            );
            assert_eq!(
                aether_search_rank(std::ptr::null(), 0, std::ptr::null_mut(), 0),
                1
            );
        }
    }
    #[test]
    fn document_retains_shared_segments_after_source_handles_are_destroyed() {
        unsafe {
            let query = aether_search_create(b"abc".as_ptr(), 3, std::ptr::null(), 0, 0);
            let segment = aether_search_create(b"abcde".as_ptr(), 5, std::ptr::null(), 0, 0);
            let document = aether_search_document_create(
                [segment.cast_const(), segment.cast_const(), std::ptr::null()].as_ptr(),
                3,
            );
            let owner = &*document.cast::<SearchDocument>();
            assert_eq!(owner.0.len(), 2);
            assert!(std::sync::Arc::ptr_eq(&owner.0[0], &owner.0[1]));
            assert_eq!(std::sync::Arc::strong_count(&owner.0[0]), 3);
            aether_search_destroy(segment);
            assert_eq!(std::sync::Arc::strong_count(&owner.0[0]), 2);
            let merged = aether_search_document_merge([document.cast_const()].as_ptr(), 1);
            aether_search_document_destroy(document);
            assert_eq!(aether_search_document_score(query, merged), 19_995);
            aether_search_document_destroy(merged);
            let empty = aether_search_document_create(std::ptr::null(), 0);
            assert_eq!(aether_search_document_score(query, empty), -1);
            aether_search_document_destroy(empty);
            assert!(aether_search_document_create(std::ptr::null(), 1).is_null());
            assert!(aether_search_document_merge(std::ptr::null(), 1).is_null());
            aether_search_destroy(query);
        }
    }
    #[test]
    fn compact_boundaries_preserve_offsets_at_every_width_transition() {
        let mut limits = vec![255_usize, 256, 65535, 65536, u32::MAX as usize];
        if usize::BITS > 32 {
            limits.push(u32::MAX as usize + 1);
        }
        for last in limits {
            let values = [0, 1, last - 1, last];
            let compact = Boundaries::new(&values);
            for (index, &offset) in values.iter().enumerate() {
                assert_eq!(compact.boundary(index), offset);
                assert_eq!(compact.position(offset), Some(index));
            }
            assert_eq!(compact.position(2), None);
            assert_eq!(compact.position(last + 1), None);
        }
        assert!(matches!(Boundaries::new(&[0, 255]), Boundaries::U8(_)));
        assert!(matches!(Boundaries::new(&[0, 256]), Boundaries::U16(_)));
        assert!(matches!(Boundaries::new(&[0, 65536]), Boundaries::U32(_)));
        let implicit = Boundaries::new(&[]);
        assert_eq!(implicit.boundary(37), 37);
        assert_eq!(implicit.position(37), Some(37));
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

mod application_intent;
mod geometry;
mod memo;
mod prompt;
mod prompt_store;
mod shortcut_defaults;
mod shortcuts;
mod storage;
mod versioned;
mod window_layout;

mod quick_clipboard;

mod clipboard_groups;
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
