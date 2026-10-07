// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::abi::Uuid;
use std::ffi::c_void;

#[repr(C)]
#[derive(Default)]
pub struct GroupPlan {
    pub count: usize,
    pub selected: usize,
    pub create: u8,
    pub changed: u8,
    pub accepted: u8,
    pub identity: u8,
}
/// Actions: create/reuse=0, promote after successful platform copy=1, remove UUID=2, clear=3.
/// Matching borrows platform primitive field equality, evaluated only until the first matching group.
/// # Safety
/// IDs/output are valid for their spans. Matching/context remain valid synchronously and cannot unwind.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_groups_plan(
    ids: *const Uuid,
    count: usize,
    candidate_id: Uuid,
    unique_items: usize,
    action: u8,
    matching: Option<unsafe extern "C" fn(*mut c_void, usize) -> u8>,
    context: *mut c_void,
    output: *mut usize,
    capacity: usize,
) -> GroupPlan {
    if (count != 0 && ids.is_null()) || action > 3 || (action == 0 && unique_items < 2) {
        return GroupPlan::default();
    }
    let ids = if count == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(ids, count) }
    };
    let selected = match action {
        0 => {
            if count != 0 && matching.is_none() {
                return GroupPlan::default();
            }
            (0..count).find(|&index| unsafe { matching.unwrap()(context, index) != 0 })
        }
        1 => ids.iter().position(|id| *id == candidate_id),
        _ => None,
    };
    let create = action == 0 && selected.is_none();
    let changed = action != 1 || selected.is_some();
    let result_count = match action {
        0 => match count.checked_add(usize::from(create)) {
            Some(n) => n,
            None => return GroupPlan::default(),
        },
        1 => count,
        2 => ids.iter().filter(|id| **id != candidate_id).count(),
        3 => 0,
        _ => unreachable!(),
    };
    if result_count > capacity || (result_count != 0 && output.is_null()) {
        return GroupPlan::default();
    }
    let identity = match action {
        0 | 1 => !create && (selected.is_none() || selected == Some(0)),
        2 | 3 => result_count == count,
        _ => false,
    };
    let mut written = 0;
    let mut write = |index| {
        unsafe { output.add(written).write(index) };
        written += 1;
    };
    match action {
        0 | 1 => {
            if create {
                write(count);
            }
            if let Some(index) = selected {
                write(index);
            }
            for index in 0..count {
                if Some(index) != selected {
                    write(index);
                }
            }
        }
        2 => {
            for (index, id) in ids.iter().enumerate() {
                if *id != candidate_id {
                    write(index);
                }
            }
        }
        3 => {}
        _ => unreachable!(),
    }
    GroupPlan {
        count: result_count,
        selected: selected.unwrap_or(count),
        create: u8::from(create),
        changed: u8::from(changed),
        accepted: 1,
        identity: u8::from(identity),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    unsafe extern "C" fn matches(context: *mut c_void, index: usize) -> u8 {
        unsafe { (&*context.cast::<Vec<u8>>())[index] }
    }
    #[test]
    fn stable_order_first_match_and_all_uuid_removal() {
        unsafe {
            let ids = [
                Uuid { bytes: [1; 16] },
                Uuid { bytes: [2; 16] },
                Uuid { bytes: [1; 16] },
            ];
            let mut flags: Vec<u8> = vec![0, 1, 1];
            let context = (&mut flags as *mut Vec<u8>).cast();
            let mut out = [99; 4];
            let p = aether_clipboard_groups_plan(
                ids.as_ptr(),
                3,
                ids[0],
                2,
                0,
                Some(matches),
                context,
                out.as_mut_ptr(),
                4,
            );
            assert_eq!(
                (p.count, p.selected, p.create, p.changed, p.accepted),
                (3, 1, 0, 1, 1)
            );
            assert_eq!(&out[..3], &[1, 0, 2]);
            flags.fill(0);
            let p = aether_clipboard_groups_plan(
                ids.as_ptr(),
                3,
                ids[0],
                2,
                0,
                Some(matches),
                context,
                out.as_mut_ptr(),
                4,
            );
            assert_eq!((p.count, p.selected, p.create), (4, 3, 1));
            assert_eq!(out, [3, 0, 1, 2]);
            let p = aether_clipboard_groups_plan(
                ids.as_ptr(),
                3,
                ids[0],
                0,
                2,
                None,
                std::ptr::null_mut(),
                out.as_mut_ptr(),
                4,
            );
            assert_eq!((p.count, p.accepted), (1, 1));
            assert_eq!(out[0], 1);
            let p = aether_clipboard_groups_plan(
                ids.as_ptr(),
                3,
                Uuid { bytes: [9; 16] },
                0,
                1,
                None,
                std::ptr::null_mut(),
                out.as_mut_ptr(),
                4,
            );
            assert_eq!((p.changed, p.create, p.accepted), (0, 0, 1));
            assert_eq!(&out[..3], &[0, 1, 2]);
        }
    }
    #[test]
    fn invalid_inputs_never_write_output_and_empty_clear_is_valid() {
        unsafe {
            let id = Uuid { bytes: [0; 16] };
            let mut out = [77; 2];
            for action in [0, 1, 2, 3, 4, 255] {
                assert_eq!(
                    aether_clipboard_groups_plan(
                        std::ptr::null(),
                        1,
                        id,
                        2,
                        action,
                        None,
                        std::ptr::null_mut(),
                        out.as_mut_ptr(),
                        2
                    )
                    .accepted,
                    0
                );
                assert_eq!(out, [77; 2]);
            }
            assert_eq!(
                aether_clipboard_groups_plan(
                    std::ptr::null(),
                    0,
                    id,
                    1,
                    0,
                    None,
                    std::ptr::null_mut(),
                    out.as_mut_ptr(),
                    2
                )
                .accepted,
                0
            );
            assert_eq!(
                aether_clipboard_groups_plan(
                    std::ptr::null(),
                    0,
                    id,
                    2,
                    0,
                    None,
                    std::ptr::null_mut(),
                    out.as_mut_ptr(),
                    0
                )
                .accepted,
                0
            );
            assert_eq!(out, [77; 2]);
            assert_eq!(
                aether_clipboard_groups_plan(
                    std::ptr::null(),
                    0,
                    id,
                    0,
                    3,
                    None,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    0
                )
                .accepted,
                1
            );
        }
    }
}
