// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Default catalog and ordered, non-destructive version migrations. Native equality is
//! borrowed only for the synchronous call, preserving Swift String/action semantics.
use crate::{abi::Bytes, shortcuts::Key};
use std::{collections::HashSet, ffi::c_void};
#[path = "shortcut_defaults_catalog.rs"]
mod catalog;
use catalog::{GROUPS, RECIPES};

enum Action {
    Application(&'static str, &'static str, &'static str),
    Folder(u8),
    Terminal,
    Desktop,
    Layout(u8),
    Remap(Key),
}
struct Recipe {
    name: &'static str,
    source: Key,
    action: Action,
}

#[repr(C)]
pub struct RecipeView {
    name: Bytes,
    display: Bytes,
    bundle: Bytes,
    path: Bytes,
    source: Key,
    target: Key,
    kind: u8,
    argument: u8,
    valid: u8,
}
fn bytes(s: &'static str) -> Bytes {
    Bytes {
        data: s.as_ptr(),
        length: s.len(),
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_shortcut_default_version() -> i64 {
    10
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_shortcut_default_recipe(index: usize) -> RecipeView {
    let mut view = RecipeView {
        name: bytes(""),
        display: bytes(""),
        bundle: bytes(""),
        path: bytes(""),
        source: Key::default(),
        target: Key::default(),
        kind: 0,
        argument: 0,
        valid: 0,
    };
    if let Some(r) = RECIPES.get(index) {
        view.name = bytes(r.name);
        view.source = r.source;
        view.valid = 1;
        match r.action {
            Action::Application(display, bundle, path) => {
                view.display = bytes(display);
                view.bundle = bytes(bundle);
                view.path = bytes(path);
            }
            Action::Folder(argument) => {
                view.kind = 1;
                view.argument = argument;
            }
            Action::Terminal => view.kind = 2,
            Action::Desktop => view.kind = 3,
            Action::Layout(argument) => {
                view.kind = 4;
                view.argument = argument;
            }
            Action::Remap(target) => {
                view.kind = 5;
                view.target = target;
            }
        }
    }
    view
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RuleRef {
    pub index: usize,
    pub recipe: u8,
}
pub struct Plan {
    rules: Vec<RuleRef>,
    identity: bool,
}
type Matches = unsafe extern "C" fn(*mut c_void, usize, u8, usize) -> u8;
fn append(rules: &mut Vec<RuleRef>, additions: &[usize], originals: &[Key]) {
    let mut occupied: HashSet<Key> = rules
        .iter()
        .map(|r| {
            if r.recipe == 0 {
                originals[r.index]
            } else {
                RECIPES[r.index].source
            }
        })
        .collect();
    for &index in additions {
        if occupied.insert(RECIPES[index].source) {
            rules.push(RuleRef { index, recipe: 1 });
        }
    }
}
fn remove(rules: &mut Vec<RuleRef>, defaults: &[usize], matches: Matches, context: *mut c_void) {
    rules.retain(|r| {
        !defaults
            .iter()
            .any(|&d| unsafe { matches(context, r.index, r.recipe, d) != 0 })
    });
}
/// Borrows keys and callback context only until return. Returned plan owns indices;
/// no original keys, native rules, or callback pointers survive this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_defaults_plan(
    keys: *const Key,
    count: usize,
    mode: u8,
    version: i64,
    matches: Option<Matches>,
    context: *mut c_void,
) -> *mut Plan {
    if mode > 2
        || (count > 0 && keys.is_null())
        || (mode == 0 && count != 0)
        || (mode == 2 && version < 9 && matches.is_none())
    {
        return std::ptr::null_mut();
    }
    let originals = if count == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(keys, count) }
    };
    let mut rules: Vec<_> = (0..count)
        .map(|index| RuleRef { index, recipe: 0 })
        .collect();
    if mode < 2 {
        append(&mut rules, GROUPS[10], originals);
        append(&mut rules, GROUPS[7], originals);
    } else {
        if version < 1 {
            append(&mut rules, GROUPS[1], originals);
        }
        // Each stage removes only untouched defaults, then fills unoccupied sources.
        for (threshold, removals, additions) in [
            (3, &[2][..], 3),
            (5, &[4][..], 5),
            (6, &[5][..], 6),
            (7, &[3, 6][..], 7),
            (8, &[0, 1][..], 8),
        ] {
            if version < threshold {
                for &group in removals {
                    remove(&mut rules, GROUPS[group], matches.unwrap(), context);
                }
                append(&mut rules, GROUPS[additions], originals);
            }
        }
        if version < 9 {
            remove(&mut rules, GROUPS[11], matches.unwrap(), context);
        }
        if version < 10 {
            append(&mut rules, GROUPS[12], originals);
        }
    }
    let identity = rules.len() == count
        && rules
            .iter()
            .enumerate()
            .all(|(i, r)| r.recipe == 0 && r.index == i);
    Box::into_raw(Box::new(Plan { rules, identity }))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_defaults_count(plan: *const Plan) -> usize {
    unsafe { plan.as_ref() }.map_or(0, |p| p.rules.len())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_defaults_identity(plan: *const Plan) -> u8 {
    unsafe { plan.as_ref() }.is_some_and(|p| p.identity) as u8
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_defaults_ref(plan: *const Plan, index: usize) -> RuleRef {
    unsafe { plan.as_ref() }
        .and_then(|p| p.rules.get(index))
        .copied()
        .unwrap_or(RuleRef {
            index: usize::MAX,
            recipe: 0,
        })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_defaults_destroy(plan: *mut Plan) {
    if !plan.is_null() {
        drop(unsafe { Box::from_raw(plan) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    unsafe extern "C" fn never(_: *mut c_void, _: usize, _: u8, _: usize) -> u8 {
        0
    }
    #[test]
    fn owned_plan_and_occupied_disabled_sources() {
        unsafe {
            let keys: Vec<_> = GROUPS[10].iter().map(|&i| RECIPES[i].source).collect();
            let plan = aether_shortcut_defaults_plan(
                keys.as_ptr(),
                keys.len(),
                1,
                0,
                None,
                std::ptr::null_mut(),
            );
            drop(keys); // plan retains neither keys nor native context
            assert_eq!(aether_shortcut_defaults_count(plan), 20);
            assert_eq!(
                aether_shortcut_defaults_ref(plan, 0),
                RuleRef {
                    index: 0,
                    recipe: 0
                }
            );
            assert_eq!(aether_shortcut_defaults_ref(plan, 8).recipe, 1);
            assert_eq!(aether_shortcut_defaults_ref(plan, 20).index, usize::MAX);
            aether_shortcut_defaults_destroy(plan);
        }
    }
    #[test]
    fn invalid_inputs_and_future_versions() {
        unsafe {
            let nil = std::ptr::null();
            let ctx = std::ptr::null_mut();
            assert!(aether_shortcut_defaults_plan(nil, 1, 1, 0, None, ctx).is_null());
            assert!(aether_shortcut_defaults_plan(nil, 0, 3, 0, None, ctx).is_null());
            assert!(aether_shortcut_defaults_plan(nil, 0, 2, 8, None, ctx).is_null());
            let plan = aether_shortcut_defaults_plan(nil, 0, 2, i64::MAX, None, ctx);
            assert_eq!(aether_shortcut_defaults_identity(plan), 1);
            aether_shortcut_defaults_destroy(plan);
            let plan = aether_shortcut_defaults_plan(nil, 0, 2, i64::MIN, Some(never), ctx);
            assert!(!plan.is_null());
            aether_shortcut_defaults_destroy(plan);
            assert_eq!(aether_shortcut_default_recipe(usize::MAX).valid, 0);
            assert_eq!(aether_shortcut_defaults_count(nil.cast()), 0);
            aether_shortcut_defaults_destroy(ctx.cast());
        }
    }
}
