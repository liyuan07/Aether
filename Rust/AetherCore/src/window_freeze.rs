// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Frozen cohort and geometry plan. Native CGRect normalization/history lookup are borrowed primitives.
use crate::{
    geometry::{Rect, aether_rect_avoid_overlap, aether_rect_destination, aether_rect_source},
    window_layout::{Screen, Window, choose_focus},
    window_progress::{Collection, aether_window_collection_update},
};
use std::{collections::HashSet, ffi::c_void};
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Input {
    pub window: Window,
    pub raw: Rect,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Saved {
    pub frame: Rect,
    pub visible: Rect,
    pub screen: u32,
    pub minimized: u8,
    pub valid: u8,
}
type Lookup = unsafe extern "C" fn(*mut c_void, usize, u32, u8) -> Saved;
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Entry {
    pub window: usize,
    pub source: usize,
    pub target: usize,
    pub desired: Rect,
    pub minimized: u8,
    pub valid: u8,
}
pub struct Plan {
    entries: Vec<Entry>,
    info: Info,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Info {
    pub collection: Collection,
    pub count: usize,
    pub preferred: isize,
    pub fullscreen: usize,
    pub minimized: usize,
    pub unreadable: usize,
    pub ready: u8,
    pub disconnected: u8,
}
/// Input buffers and lookup/context are borrowed synchronously. Output owns only indices and geometry.
/// scope: 0 existing, 1 appearing excluding IDs, 2 undo including IDs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_freeze_plan(
    inputs: *const Input,
    count: usize,
    screens: *const Screen,
    screen_count: usize,
    ids: *const i64,
    id_count: usize,
    scope: u8,
    target_id: u32,
    restore: u8,
    collection: Collection,
    now: f64,
    lookup: Option<Lookup>,
    context: *mut c_void,
) -> *mut Plan {
    if scope > 2
        || (count > 0 && inputs.is_null())
        || (screen_count > 0 && screens.is_null())
        || (id_count > 0 && ids.is_null())
    {
        return std::ptr::null_mut();
    }
    let inputs = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(inputs, count) }
    };
    let screens = if screen_count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(screens, screen_count) }
    };
    let ids: HashSet<_> = if id_count == 0 {
        HashSet::new()
    } else {
        unsafe { std::slice::from_raw_parts(ids, id_count) }
            .iter()
            .copied()
            .collect()
    };
    let candidates: Vec<_> = inputs
        .iter()
        .enumerate()
        .filter(|(_, input)| match scope {
            1 => !ids.contains(&input.window.id),
            2 => ids.contains(&input.window.id),
            _ => true,
        })
        .map(|(index, _)| index)
        .collect();
    let mut plan = Plan {
        entries: Vec::new(),
        info: Info {
            collection,
            preferred: -1,
            ..Info::default()
        },
    };
    if scope == 1 {
        let update = aether_window_collection_update(
            collection,
            u8::from(candidates.iter().any(|&i| inputs[i].window.flags & 1 != 0)),
            now,
        );
        plan.info.collection = update.state;
        if update.ready == 0 {
            return Box::into_raw(Box::new(plan));
        }
    }
    plan.info.ready = 1;
    plan.info.preferred = choose_focus(
        candidates.iter().map(|&i| (i, &inputs[i].window)),
        screens,
        target_id,
        restore,
    )
    .map_or(-1, |i| i as isize);
    let frames: Vec<_> = screens.iter().map(|s| s.frame).collect();
    let sources: Vec<_> = candidates
        .iter()
        .map(|&i| {
            let w = inputs[i].window;
            if w.flags & 1 != 0 && w.flags & 2 == 0 {
                unsafe { aether_rect_source(w.frame, frames.as_ptr(), frames.len()) }
            } else {
                -1
            }
        })
        .collect();
    let mut occupied: Vec<_> = candidates
        .iter()
        .zip(&sources)
        .filter_map(|(&i, &source)| {
            (source >= 0 && screens[source as usize].id == target_id)
                .then_some(inputs[i].window.frame)
        })
        .collect();
    for (&index, &source) in candidates.iter().zip(&sources) {
        let input = inputs[index];
        let window = input.window;
        if window.flags & 1 == 0 {
            continue;
        }
        if window.flags & 2 != 0 {
            plan.info.fullscreen += 1;
            continue;
        }
        if scope != 2 && window.flags & 4 != 0 && restore == 0 {
            plan.info.minimized += 1;
            continue;
        }
        if !(window.frame.width > 0.0 && window.frame.height > 0.0) {
            plan.info.unreadable += 1;
            continue;
        }
        if source < 0 {
            continue;
        }
        let source = source as usize;
        let target;
        let desired;
        let minimized;
        if scope == 2 {
            let saved = lookup.map_or(Saved::default(), |f| unsafe {
                f(context, index, target_id, 1)
            });
            let Some(position) = screens
                .iter()
                .position(|s| saved.valid != 0 && s.id == saved.screen)
            else {
                plan.info.disconnected = 1;
                continue;
            };
            target = position;
            desired = aether_rect_destination(
                saved.frame,
                saved.visible,
                screens[target].visible,
                u8::from(window.flags & 8 != 0),
            );
            minimized = u8::from(saved.minimized != 0);
        } else {
            let Some(position) = screens.iter().position(|s| s.id == target_id) else {
                continue;
            };
            target = position;
            minimized = 0;
            if screens[source].id == screens[target].id {
                desired = input.raw;
            } else {
                let saved = lookup.map_or(Saved::default(), |f| unsafe {
                    f(context, index, target_id, 0)
                });
                let frame = if saved.valid != 0 {
                    saved.frame
                } else {
                    window.frame
                };
                let visible = if saved.valid != 0 {
                    saved.visible
                } else {
                    screens[source].visible
                };
                let proposed = aether_rect_destination(
                    frame,
                    visible,
                    screens[target].visible,
                    u8::from(window.flags & 8 != 0),
                );
                desired = unsafe {
                    aether_rect_avoid_overlap(
                        proposed,
                        occupied.as_ptr(),
                        occupied.len(),
                        screens[target].visible,
                    )
                };
                occupied.push(desired);
            }
        }
        plan.entries.push(Entry {
            window: index,
            source,
            target,
            desired,
            minimized,
            valid: 1,
        });
    }
    plan.info.count = plan.entries.len();
    Box::into_raw(Box::new(plan))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_freeze_info(plan: *const Plan) -> Info {
    unsafe { plan.as_ref() }.map_or(
        Info {
            preferred: -1,
            ..Info::default()
        },
        |p| p.info,
    )
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_freeze_entry(plan: *const Plan, index: usize) -> Entry {
    unsafe { plan.as_ref() }
        .and_then(|p| p.entries.get(index))
        .copied()
        .unwrap_or_default()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_window_freeze_destroy(plan: *mut Plan) {
    if !plan.is_null() {
        drop(unsafe { Box::from_raw(plan) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn input(id: i64, flags: u8) -> Input {
        Input {
            window: Window {
                frame: Rect {
                    width: 10.0,
                    height: 10.0,
                    ..Rect::default()
                },
                id,
                flags,
                ..Window::default()
            },
            raw: Rect {
                width: -10.0,
                height: 10.0,
                ..Rect::default()
            },
        }
    }
    #[test]
    fn owned_indices_and_raw_same_screen_geometry() {
        unsafe {
            let inputs = vec![input(i64::MIN, 9), input(i64::MAX, 3), input(0, 5)];
            let screens = [Screen {
                frame: Rect {
                    width: 100.0,
                    height: 100.0,
                    ..Rect::default()
                },
                id: 0,
                ..Screen::default()
            }];
            let plan = aether_window_freeze_plan(
                inputs.as_ptr(),
                inputs.len(),
                screens.as_ptr(),
                1,
                std::ptr::null(),
                0,
                0,
                0,
                0,
                Collection::default(),
                0.0,
                None,
                std::ptr::null_mut(),
            );
            drop(inputs);
            let info = aether_window_freeze_info(plan);
            assert_eq!((info.count, info.fullscreen, info.minimized), (1, 1, 1));
            assert_eq!(aether_window_freeze_entry(plan, 0).desired.width, -10.0);
            assert_eq!(aether_window_freeze_entry(plan, 1).valid, 0);
            aether_window_freeze_destroy(plan);
        }
    }
    #[test]
    fn cohort_gate_invalid_inputs_and_missing_undo() {
        unsafe {
            let input = input(1, 9);
            let nil = std::ptr::null();
            let ctx = std::ptr::null_mut();
            assert!(
                aether_window_freeze_plan(
                    nil,
                    1,
                    nil.cast(),
                    0,
                    nil.cast(),
                    0,
                    0,
                    0,
                    0,
                    Collection::default(),
                    0.0,
                    None,
                    ctx
                )
                .is_null()
            );
            assert!(
                aether_window_freeze_plan(
                    nil,
                    0,
                    nil.cast(),
                    0,
                    nil.cast(),
                    0,
                    3,
                    0,
                    0,
                    Collection::default(),
                    0.0,
                    None,
                    ctx
                )
                .is_null()
            );
            let plan = aether_window_freeze_plan(
                &input,
                1,
                nil.cast(),
                0,
                &1,
                1,
                1,
                0,
                0,
                Collection::default(),
                0.0,
                None,
                ctx,
            );
            assert_eq!(aether_window_freeze_info(plan).ready, 0);
            aether_window_freeze_destroy(plan);
            assert_eq!(aether_window_freeze_info(nil.cast()).preferred, -1);
            aether_window_freeze_destroy(ctx.cast());
        }
    }
}
