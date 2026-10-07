// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Session-only layout memory. No window titles, paths, AX objects or persistence.
use crate::{
    abi::Uuid,
    geometry::{Rect, aether_rect_source},
};
use std::collections::HashMap;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Window {
    pub frame: Rect,
    pub id: i64,
    pub pid: i32,
    pub flags: u8,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Screen {
    pub frame: Rect,
    pub visible: Rect,
    pub id: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Saved {
    pub window: Window,
    pub screen: Screen,
}
#[repr(C)]
pub struct SavedView {
    pub saved: Saved,
    pub valid: u8,
}
struct Undo {
    operation: Uuid,
    pid: i32,
    layouts: HashMap<i64, Saved>,
}
pub struct History {
    layouts: HashMap<i64, HashMap<u32, Saved>>,
    undo: Option<Undo>,
}
pub struct Snapshot {
    operation: Uuid,
    pid: i32,
    layouts: Vec<Saved>,
}
#[repr(C)]
pub struct SnapshotInfo {
    pub operation: Uuid,
    pub pid: i32,
    pub count: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn aether_window_history_create() -> *mut History {
    Box::into_raw(Box::new(History {
        layouts: HashMap::new(),
        undo: None,
    }))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_history_destroy(history: *mut History) {
    if !history.is_null() {
        drop(unsafe { Box::from_raw(history) });
    }
}
/// All history methods require a live, serially accessed handle. No native borrows survive return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_history_record(
    history: *mut History,
    saved: Saved,
    operation: Uuid,
) -> u8 {
    let Some(history) = (unsafe { history.as_mut() }) else {
        return 0;
    };
    history
        .layouts
        .entry(saved.window.id)
        .or_default()
        .insert(saved.screen.id, saved);
    if history
        .undo
        .as_ref()
        .is_none_or(|undo| undo.operation != operation)
    {
        history.undo = Some(Undo {
            operation,
            pid: saved.window.pid,
            layouts: HashMap::new(),
        });
    }
    history
        .undo
        .as_mut()
        .unwrap()
        .layouts
        .entry(saved.window.id)
        .or_insert(saved);
    1
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_history_saved(
    history: *const History,
    id: i64,
    screen: u32,
) -> SavedView {
    let saved = unsafe { history.as_ref() }
        .and_then(|h| h.layouts.get(&id))
        .and_then(|s| s.get(&screen));
    SavedView {
        saved: saved.copied().unwrap_or_default(),
        valid: u8::from(saved.is_some()),
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_history_has_undo(history: *const History) -> u8 {
    u8::from(unsafe { history.as_ref() }.is_some_and(|h| h.undo.is_some()))
}
/// mode 0 removes all remembered layouts and undo; mode 1 removes only restored undo entries.
/// Invalid mode/input leaves history untouched. IDs are borrowed synchronously.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_history_remove(
    history: *mut History,
    ids: *const i64,
    count: usize,
    mode: u8,
) -> u8 {
    if mode > 1 || (count > 0 && ids.is_null()) {
        return 0;
    }
    let Some(history) = (unsafe { history.as_mut() }) else {
        return 0;
    };
    let ids = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ids, count) }
    };
    for id in ids {
        if mode == 0 {
            history.layouts.remove(id);
        }
        if let Some(undo) = history.undo.as_mut() {
            undo.layouts.remove(id);
        }
    }
    if history
        .undo
        .as_ref()
        .is_some_and(|undo| undo.layouts.is_empty())
    {
        history.undo = None;
    }
    1
}
/// An owned immutable snapshot remains valid after further mutations and history destruction.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_history_snapshot(history: *const History) -> *mut Snapshot {
    let Some(undo) = (unsafe { history.as_ref() }).and_then(|h| h.undo.as_ref()) else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(Snapshot {
        operation: undo.operation,
        pid: undo.pid,
        layouts: undo.layouts.values().copied().collect(),
    }))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_snapshot_info(snapshot: *const Snapshot) -> SnapshotInfo {
    unsafe { snapshot.as_ref() }.map_or(
        SnapshotInfo {
            operation: Uuid { bytes: [0; 16] },
            pid: 0,
            count: 0,
        },
        |s| SnapshotInfo {
            operation: s.operation,
            pid: s.pid,
            count: s.layouts.len(),
        },
    )
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_snapshot_saved(
    snapshot: *const Snapshot,
    index: usize,
) -> SavedView {
    let saved = unsafe { snapshot.as_ref() }.and_then(|s| s.layouts.get(index));
    SavedView {
        saved: saved.copied().unwrap_or_default(),
        valid: u8::from(saved.is_some()),
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_snapshot_destroy(snapshot: *mut Snapshot) {
    if !snapshot.is_null() {
        drop(unsafe { Box::from_raw(snapshot) });
    }
}

/// Canonical native CGRect dimensions are provided for selection; history stores raw rectangles.
/// Windows/screens are borrowed only until return. No candidate array or per-window FFI call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_focus_choose(
    windows: *const Window,
    count: usize,
    screens: *const Screen,
    screen_count: usize,
    target: u32,
    restore_minimized: u8,
) -> isize {
    if (count > 0 && windows.is_null()) || (screen_count > 0 && screens.is_null()) {
        return -1;
    }
    let windows = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(windows, count) }
    };
    let screens = if screen_count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(screens, screen_count) }
    };
    let eligible = |w: &Window| {
        w.flags & 1 != 0
            && w.flags & 2 == 0
            && w.frame.width > 0.0
            && w.frame.height > 0.0
            && (restore_minimized != 0 || w.flags & 4 == 0)
    };
    let mut first = None;
    let mut main = None;
    for (index, window) in windows.iter().enumerate().filter(|(_, w)| eligible(w)) {
        first.get_or_insert(index);
        if window.flags & 16 != 0 {
            return index as isize;
        }
        if window.flags & 32 != 0 {
            main.get_or_insert(index);
        }
    }
    if let Some(index) = main {
        return index as isize;
    }
    if first.is_none() {
        return -1;
    }
    let frames: Vec<_> = screens.iter().map(|s| s.frame).collect();
    for (index, window) in windows.iter().enumerate().filter(|(_, w)| eligible(w)) {
        let source = unsafe { aether_rect_source(window.frame, frames.as_ptr(), frames.len()) };
        if source >= 0 && screens[source as usize].id == target {
            return index as isize;
        }
    }
    first.map_or(-1, |i| i as isize)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owned_snapshot_preserves_first_undo_and_latest_memory() {
        unsafe {
            let history = aether_window_history_create();
            let operation = Uuid { bytes: [1; 16] };
            let mut saved = Saved {
                window: Window {
                    id: -1,
                    pid: 7,
                    ..Window::default()
                },
                screen: Screen {
                    id: u32::MAX,
                    ..Screen::default()
                },
            };
            saved.window.frame.x = -0.0;
            assert_eq!(aether_window_history_record(history, saved, operation), 1);
            saved.window.pid = 9;
            saved.window.frame.x = 10.0;
            aether_window_history_record(history, saved, operation);
            assert_eq!(
                aether_window_history_saved(history, -1, u32::MAX)
                    .saved
                    .window
                    .frame
                    .x,
                10.0
            );
            let snapshot = aether_window_history_snapshot(history);
            aether_window_history_destroy(history);
            assert_eq!(aether_window_snapshot_info(snapshot).pid, 7);
            let original = aether_window_snapshot_saved(snapshot, 0);
            assert_eq!(
                original.saved.window.frame.x.to_bits(),
                (-0.0_f64).to_bits()
            );
            assert_eq!(aether_window_snapshot_saved(snapshot, 1).valid, 0);
            aether_window_snapshot_destroy(snapshot);
        }
    }
    #[test]
    fn remove_vs_restored_and_invalid_spans() {
        unsafe {
            let history = aether_window_history_create();
            let saved = Saved {
                window: Window {
                    id: i64::MIN,
                    ..Window::default()
                },
                ..Saved::default()
            };
            aether_window_history_record(history, saved, Uuid { bytes: [0; 16] });
            assert_eq!(
                aether_window_history_remove(history, std::ptr::null(), 1, 0),
                0
            );
            assert_eq!(aether_window_history_remove(history, &i64::MIN, 1, 2), 0);
            assert_eq!(aether_window_history_has_undo(history), 1);
            aether_window_history_remove(history, &i64::MIN, 1, 1);
            assert_eq!(aether_window_history_has_undo(history), 0);
            assert_eq!(aether_window_history_saved(history, i64::MIN, 0).valid, 1);
            aether_window_history_remove(history, &i64::MIN, 1, 0);
            assert_eq!(aether_window_history_saved(history, i64::MIN, 0).valid, 0);
            aether_window_history_destroy(history);
            assert!(aether_window_history_snapshot(std::ptr::null()).is_null());
            assert_eq!(aether_window_snapshot_info(std::ptr::null()).count, 0);
            aether_window_snapshot_destroy(std::ptr::null_mut());
        }
    }
    #[test]
    fn focus_priority_and_invalid_input() {
        unsafe {
            let mut windows = [Window {
                frame: Rect {
                    width: 1.0,
                    height: 1.0,
                    ..Rect::default()
                },
                flags: 33,
                ..Window::default()
            }; 3];
            windows[2].flags = 17;
            assert_eq!(
                aether_window_focus_choose(windows.as_ptr(), 3, std::ptr::null(), 0, 0, 0),
                2
            );
            windows[2].flags |= 4;
            assert_eq!(
                aether_window_focus_choose(windows.as_ptr(), 3, std::ptr::null(), 0, 0, 0),
                0
            );
            assert_eq!(
                aether_window_focus_choose(std::ptr::null(), 1, std::ptr::null(), 0, 0, 0),
                -1
            );
        }
    }
}
