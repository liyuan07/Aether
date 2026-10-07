// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Retry/acknowledgement and completion policies. Native adapter owns AX calls and cancellation checks.
use crate::geometry::{Rect, aether_rect_approximately_equal};
const MINIMIZED: u8 = 1;
const RECORDED: u8 = 2;
const COMPLETE: u8 = 4;
const FAILED: u8 = 8;
const CLOSED: u8 = 16;
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Progress {
    pub desired: Rect,
    pub next_attempt: f64,
    pub attempts: u8,
    pub flags: u8,
}
#[repr(C)]
pub struct Decision {
    pub state: Progress,
    pub command: u8,
    pub disconnected: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_window_progress_create(desired: Rect, minimized: u8) -> Progress {
    Progress {
        desired,
        next_attempt: 0.0,
        attempts: 0,
        flags: if minimized == 0 { 0 } else { MINIMIZED },
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_window_progress_decide(
    mut state: Progress,
    current: u8,
    fullscreen: u8,
    target: u8,
    positioned: u8,
    restored: u8,
    now: f64,
) -> Decision {
    let mut command = 0;
    let mut disconnected = 0;
    if state.flags & (COMPLETE | FAILED) == 0 {
        if current == 0 || fullscreen != 0 {
            state.flags |= COMPLETE | CLOSED;
        } else if target == 0 {
            state.flags |= FAILED;
            disconnected = 1;
        } else if positioned != 0 && restored != 0 {
            state.flags |= COMPLETE;
        } else if now >= state.next_attempt {
            if state.attempts >= 3 {
                state.flags |= FAILED;
            } else {
                state.attempts += 1;
                state.next_attempt = now + 0.04;
                command = if positioned == 0 { 1 } else { 2 };
            }
        }
    }
    Decision {
        state,
        command,
        disconnected,
    }
}
#[repr(C)]
pub struct Acknowledgement {
    pub state: Progress,
    pub record: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_window_progress_ack(
    mut state: Progress,
    changed: u8,
    undo: u8,
) -> Acknowledgement {
    let record = u8::from(changed != 0 && state.flags & RECORDED == 0 && undo == 0);
    if record != 0 {
        state.flags |= RECORDED;
    }
    Acknowledgement { state, record }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SummaryEntry {
    pub original: Rect,
    pub desired: Rect,
    pub flags: u8,
    pub preferred: u8,
}
#[repr(C)]
pub struct Summary {
    pub moved: usize,
    pub failed: usize,
    pub focus: isize,
    pub restored: usize,
    pub command: u8,
    pub valid: u8,
}
/// Summary reads compact geometry/flags rather than allocating filtered copies of full native progress.
/// command 0 pending, 1 restore undo, 2 finish with optional focus. Invalid input leaves output untouched.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_progress_summary(
    entries: *const SummaryEntry,
    count: usize,
    unreadable: usize,
    undo: u8,
    restored: *mut usize,
    capacity: usize,
) -> Summary {
    let mut result = Summary {
        moved: 0,
        failed: unreadable,
        focus: -1,
        restored: 0,
        command: 0,
        valid: 0,
    };
    if (count > 0 && entries.is_null())
        || (undo != 0 && (capacity < count || (count > 0 && restored.is_null())))
    {
        return result;
    }
    let entries = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(entries, count) }
    };
    let mut done = true;
    let mut first = None;
    let mut preferred = None;
    for (index, entry) in entries.iter().enumerate() {
        if entry.flags & COMPLETE != 0
            && entry.flags & CLOSED == 0
            && aether_rect_approximately_equal(entry.original, entry.desired) == 0
        {
            result.moved += 1;
        }
        if entry.flags & FAILED != 0 {
            result.failed += 1;
        }
        if entry.flags & (COMPLETE | FAILED) == 0 {
            done = false;
        }
        if entry.flags & COMPLETE != 0 {
            if undo != 0 {
                unsafe {
                    *restored.add(result.restored) = index;
                }
                result.restored += 1;
            }
            if entry.flags & (CLOSED | MINIMIZED) == 0 {
                first.get_or_insert(index);
                if entry.preferred != 0 {
                    preferred.get_or_insert(index);
                }
            }
        }
    }
    if done {
        result.command = if undo != 0 { 1 } else { 2 };
        if undo == 0 {
            result.focus = preferred.or(first).map_or(-1, |index| index as isize);
        }
    }
    result.valid = 1;
    result
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Collection {
    pub first: f64,
    pub has_first: u8,
}
#[repr(C)]
pub struct CollectionDecision {
    pub state: Collection,
    pub ready: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_window_collection_update(
    mut state: Collection,
    standard: u8,
    now: f64,
) -> CollectionDecision {
    if standard == 0 {
        return CollectionDecision { state, ready: 0 };
    }
    if state.has_first == 0 {
        state.first = now;
        state.has_first = 1;
    }
    CollectionDecision {
        ready: u8::from(now - state.first >= 0.12),
        state,
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_window_scope_time_limit(scope: u8) -> f64 {
    match scope {
        1 => 1.5,
        2 => 0.8,
        _ => 0.35,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn attempts_confirmation_and_first_success_ack() {
        let mut state = aether_window_progress_create(Rect::default(), 0);
        for tick in [0.0, 0.05, 0.1] {
            let decision = aether_window_progress_decide(state, 1, 0, 1, 0, 0, tick);
            assert_eq!(decision.command, 1);
            state = decision.state;
        }
        assert_eq!(
            aether_window_progress_decide(state, 1, 0, 1, 0, 0, 0.11)
                .state
                .flags
                & FAILED,
            0
        );
        assert_ne!(
            aether_window_progress_decide(state, 1, 0, 1, 0, 0, 0.15)
                .state
                .flags
                & FAILED,
            0
        );
        let success = aether_window_progress_ack(state, 1, 0);
        assert_eq!(success.record, 1);
        assert_eq!(aether_window_progress_ack(success.state, 1, 0).record, 0);
        assert_eq!(aether_window_progress_ack(state, 1, 1).record, 0);
        assert_eq!(
            aether_window_progress_decide(state, 1, 0, 1, 1, 0, 0.15).command,
            0 // Position writes and restoration share the same three-attempt budget.
        );
        assert_ne!(
            aether_window_progress_decide(state, 1, 0, 1, 1, 1, 0.11)
                .state
                .flags
                & COMPLETE,
            0
        );
        assert_eq!(
            aether_window_progress_decide(
                aether_window_progress_create(Rect::default(), 0),
                1,
                0,
                1,
                1,
                0,
                0.15
            )
            .command,
            2
        );
    }
    #[test]
    fn closed_before_disconnected_and_fixed_collection_window() {
        let state = aether_window_progress_create(Rect::default(), 0);
        let closed = aether_window_progress_decide(state, 0, 0, 0, 0, 0, 0.0);
        assert_eq!(closed.disconnected, 0);
        assert_eq!(closed.state.flags, COMPLETE | CLOSED);
        let first = aether_window_collection_update(Collection::default(), 1, 1.0);
        assert_eq!(first.ready, 0);
        let absent = aether_window_collection_update(first.state, 0, 1.2);
        assert_eq!(absent.state.first, 1.0);
        assert_eq!(
            aether_window_collection_update(absent.state, 1, 1.2).ready,
            1
        );
        assert_eq!(
            aether_window_collection_update(Collection::default(), 1, f64::NAN).ready,
            0
        );
    }
    #[test]
    fn summary_and_invalid_buffers() {
        unsafe {
            let entries = [
                SummaryEntry {
                    original: Rect::default(),
                    desired: Rect::default(),
                    flags: COMPLETE | CLOSED,
                    preferred: 1,
                },
                SummaryEntry {
                    original: Rect::default(),
                    desired: Rect::default(),
                    flags: COMPLETE,
                    preferred: 0,
                },
            ];
            let result =
                aether_window_progress_summary(entries.as_ptr(), 2, 1, 0, std::ptr::null_mut(), 0);
            assert_eq!((result.command, result.focus, result.failed), (2, 1, 1));
            let mut restored = [99; 2];
            assert_eq!(
                aether_window_progress_summary(entries.as_ptr(), 2, 0, 1, restored.as_mut_ptr(), 1)
                    .valid,
                0
            );
            assert_eq!(restored, [99, 99]);
            let undo =
                aether_window_progress_summary(entries.as_ptr(), 2, 0, 1, restored.as_mut_ptr(), 2);
            assert_eq!((undo.command, undo.restored), (1, 2));
            assert_eq!(restored, [0, 1]);
            assert_eq!(
                aether_window_progress_summary(std::ptr::null(), 0, 0, 0, std::ptr::null_mut(), 0)
                    .command,
                2
            );
        }
    }
}
