// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Clipboard store decisions and exact maintenance-source identity.
use crate::{abi::Uuid, clipboard_history::Row};
use std::ffi::c_void;
#[derive(PartialEq, Eq)]
struct Group {
    id: Uuid,
    items: Vec<Uuid>,
}
#[derive(Default)]
pub struct Identity {
    history: Vec<Uuid>,
    pinned: Vec<Uuid>,
    groups: Vec<Group>,
}
#[repr(C)]
pub struct Changes {
    history: u8,
    pinned: u8,
    groups: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_clipboard_identity_create() -> *mut Identity {
    Box::into_raw(Box::new(Identity::default()))
}
/// # Safety
/// Identity is exclusively borrowed during construction. 0=history,1=pinned,2=new group,3=group item.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_identity_append(
    identity: *mut Identity,
    section: u8,
    id: Uuid,
) -> u8 {
    let Some(identity) = (unsafe { identity.as_mut() }) else {
        return 0;
    };
    match section {
        0 => identity.history.push(id),
        1 => identity.pinned.push(id),
        2 => identity.groups.push(Group { id, items: vec![] }),
        3 => {
            let Some(group) = identity.groups.last_mut() else {
                return 0;
            };
            group.items.push(id);
        }
        _ => return 0,
    }
    1
}
/// # Safety
/// Identities are live and immutable. Exact sequence comparison deliberately ignores non-ID fields,
/// matching the original source-staleness contract; no collision-prone fingerprints are used.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_identity_changes(
    left: *const Identity,
    right: *const Identity,
) -> Changes {
    let (Some(left), Some(right)) = (unsafe { left.as_ref() }, unsafe { right.as_ref() }) else {
        return Changes {
            history: 1,
            pinned: 1,
            groups: 1,
        };
    };
    Changes {
        history: u8::from(left.history != right.history),
        pinned: u8::from(left.pinned != right.pinned),
        groups: u8::from(left.groups != right.groups),
    }
}
/// # Safety
/// Destroy once after all concurrent reads; null is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_identity_destroy(identity: *mut Identity) {
    if !identity.is_null() {
        drop(unsafe { Box::from_raw(identity) });
    }
}
#[repr(C)]
pub struct Activation {
    pub section: u8,
    pub index: isize,
}
type Find = unsafe extern "C" fn(*mut c_void, u8) -> isize;
/// # Safety
/// Callback/context are valid for the synchronous call, never retained. Native callback supplies
/// primitive first-position lookup; core chooses pinned-before-history and never scans history on a pin hit.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_activation_plan(
    find: Option<Find>,
    context: *mut c_void,
) -> Activation {
    let Some(find) = find else {
        return Activation {
            section: 2,
            index: -1,
        };
    };
    for section in [0, 1] {
        let index = unsafe { find(context, section) };
        if index >= 0 {
            return Activation { section, index };
        }
    }
    Activation {
        section: 2,
        index: -1,
    }
}
/// # Safety
/// Rows are readable for count entries. matching carries stringData presence; text compatibility
/// includes text/url/rtf/unknown only, including empty present strings and the original empty-group rule.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_clipboard_group_copy_text(rows: *const Row, count: usize) -> u8 {
    if count == 0 {
        return 1;
    }
    if rows.is_null() {
        return 0;
    }
    u8::from(
        unsafe { std::slice::from_raw_parts(rows, count) }
            .iter()
            .all(|row| matches!(row.kind, 0 | 1 | 4 | 5) && row.matching != 0),
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn maintenance_identity_distinguishes_order_sections_and_group_topology() {
        unsafe {
            let a = aether_clipboard_identity_create();
            let b = aether_clipboard_identity_create();
            let id = Uuid { bytes: [1; 16] };
            let other = Uuid { bytes: [2; 16] };
            for owner in [a, b] {
                aether_clipboard_identity_append(owner, 0, id);
                aether_clipboard_identity_append(owner, 2, other);
                aether_clipboard_identity_append(owner, 3, id);
            }
            let same = aether_clipboard_identity_changes(a, b);
            assert_eq!((same.history, same.pinned, same.groups), (0, 0, 0));
            aether_clipboard_identity_append(b, 1, id);
            aether_clipboard_identity_append(b, 2, id);
            let changed = aether_clipboard_identity_changes(a, b);
            assert_eq!((changed.history, changed.pinned, changed.groups), (0, 1, 1));
            aether_clipboard_identity_destroy(a);
            aether_clipboard_identity_destroy(b);
        }
    }
    #[test]
    fn activation_prefers_pin_and_group_copy_requires_all_compatible_text() {
        unsafe {
            unsafe extern "C" fn find(context: *mut c_void, section: u8) -> isize {
                let calls = unsafe { &mut *context.cast::<Vec<u8>>() };
                calls.push(section);
                if section == 0 { 3 } else { 0 }
            }
            let mut calls = vec![];
            let result =
                aether_clipboard_activation_plan(Some(find), (&mut calls as *mut Vec<u8>).cast());
            assert_eq!((result.section, result.index), (0, 3));
            assert_eq!(calls, vec![0]);
            for kind in 0..6 {
                let row = Row {
                    id: Uuid { bytes: [0; 16] },
                    timestamp: 0.,
                    kind,
                    matching: 1,
                    protected: 0,
                    valid: 1,
                };
                assert_eq!(
                    aether_clipboard_group_copy_text(&row, 1),
                    u8::from(matches!(kind, 0 | 1 | 4 | 5))
                );
            }
            assert_eq!(aether_clipboard_group_copy_text(std::ptr::null(), 0), 1);
        }
    }
}
