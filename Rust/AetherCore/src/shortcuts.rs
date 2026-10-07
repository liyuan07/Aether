// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
use crate::abi::Uuid;
use std::collections::{BTreeSet, HashMap, HashSet};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Key {
    pub code: u16,
    pub physical: u16,
    pub modifiers: u8,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Rule {
    pub source: Key,
    pub target: Key,
    pub enabled: u8,
    pub remap: u8,
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_shortcut_resolve(
    required: u8,
    event: u8,
    physical: u16,
    active: u16,
    remap: u8,
) -> u8 {
    if active & physical != physical {
        return 0;
    }
    let (required, event) = if physical & 256 != 0 && physical & 192 == 0 {
        (required & !8, event & !8)
    } else {
        (required, event)
    };
    if required == event {
        1
    } else if remap != 0 && required & 4 == 0 && event == required | 4 {
        2
    } else {
        0
    }
}
fn logical(physical: u16) -> u8 {
    (u8::from(physical & 3 != 0))
        | (u8::from(physical & 12 != 0) << 1)
        | (u8::from(physical & 48 != 0) << 2)
        | (u8::from(physical & 192 != 0) << 3)
}
/// # Safety
/// The input must be readable for count rules, or null with count zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_claims(key: Key, rules: *const Rule, count: usize) -> u8 {
    if count == 0 || rules.is_null() {
        return 0;
    }
    let rules = unsafe { std::slice::from_raw_parts(rules, count) };
    u8::from(rules.iter().any(|r| {
        r.enabled != 0
            && r.source.code == key.code
            && r.source.modifiers | logical(r.source.physical) == key.modifiers
    }))
}
struct Issue {
    kind: u32,
    source: usize,
    members: Vec<usize>,
}
pub struct Validation {
    issues: Vec<Issue>,
    count: usize,
}
#[repr(C)]
pub struct IssueView {
    pub kind: u32,
    pub source: usize,
    pub members: *const usize,
    pub count: usize,
}
/// # Safety
/// Rules must be readable for count elements. The returned handle owns its data.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_validate(
    rules: *const Rule,
    count: usize,
) -> *mut Validation {
    if count != 0 && rules.is_null() {
        return std::ptr::null_mut();
    }
    let rules = if count == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(rules, count) }
    };
    let mut issues = Vec::new();
    let mut groups: HashMap<Key, Vec<usize>> = HashMap::new();
    let mut remaps: HashMap<Key, (Key, usize)> = HashMap::new();
    for (index, rule) in rules.iter().enumerate().filter(|(_, r)| r.enabled != 0) {
        if rule.source.modifiers == 0 && rule.source.physical == 0 {
            issues.push(Issue {
                kind: 0,
                source: index,
                members: vec![index],
            });
        }
        groups.entry(rule.source).or_default().push(index);
        if rule.remap != 0 {
            remaps.entry(rule.source).or_insert((rule.target, index));
        }
    }
    for members in groups.into_values().filter(|v| v.len() > 1) {
        issues.push(Issue {
            kind: 1,
            source: members[0],
            members,
        });
    }
    let mut reported = BTreeSet::new();
    for source in remaps.keys() {
        let mut visited = HashMap::new();
        let mut cursor = *source;
        while let Some(&(target, id)) = remaps.get(&cursor) {
            if visited.contains_key(&cursor) {
                let mut ids: Vec<usize> = visited.values().copied().collect();
                ids.push(id);
                ids.sort_unstable();
                ids.dedup();
                reported.insert(ids);
                break;
            }
            visited.insert(cursor, id);
            cursor = target;
        }
    }
    for members in reported {
        issues.push(Issue {
            kind: 2,
            source: members[0],
            members,
        });
    }
    Box::into_raw(Box::new(Validation { issues, count }))
}
/// Compute both monitoring states once for the validated immutable rule snapshot.
/// UUID membership intentionally expands to every matching UUID, including disabled
/// duplicates, matching the original Set<UUID> followed by native rule filtering.
/// # Safety
/// Handle must be live and correspond to these rules/IDs. Buffers are borrowed only
/// until return. Invalid input leaves output untouched; count zero accepts null spans.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_execution_flags(
    handle: *const Validation,
    rules: *const Rule,
    ids: *const Uuid,
    count: usize,
    flags: *mut u8,
    capacity: usize,
) -> u8 {
    let Some(validation) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    if validation.count != count
        || capacity < count
        || (count > 0 && (rules.is_null() || ids.is_null() || flags.is_null()))
    {
        return 0;
    }
    if count == 0 {
        return 1;
    }
    let rules = unsafe { std::slice::from_raw_parts(rules, count) };
    let ids = unsafe { std::slice::from_raw_parts(ids, count) };
    let invalid: HashSet<Uuid> = validation
        .issues
        .iter()
        .flat_map(|issue| issue.members.iter().map(|&index| ids[index]))
        .collect();
    let mut without_monitoring = HashSet::new();
    let mut with_monitoring = HashSet::new();
    for (rule, &id) in rules.iter().zip(ids) {
        if rule.enabled != 0 && !invalid.contains(&id) {
            with_monitoring.insert(id);
            if rule.source.physical == 0 {
                without_monitoring.insert(id);
            }
        }
    }
    for (index, id) in ids.iter().enumerate() {
        unsafe {
            *flags.add(index) = u8::from(without_monitoring.contains(id))
                | (u8::from(with_monitoring.contains(id)) << 1);
        }
    }
    1
}
#[unsafe(no_mangle)]
pub extern "C" fn aether_shortcut_execution_mask(
    monitoring: u8,
    permission: u8,
    recording: u8,
) -> u8 {
    if permission == 0 || recording != 0 {
        0
    } else if monitoring == 0 {
        1
    } else {
        2
    }
}
/// # Safety
/// A live validation handle returned by validate; null yields zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_validation_count(handle: *const Validation) -> usize {
    if handle.is_null() {
        0
    } else {
        unsafe { (&*handle).issues.len() }
    }
}
/// # Safety
/// Handle must be live. Output borrows memory until validation_destroy.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_validation_issue(
    handle: *const Validation,
    index: usize,
) -> IssueView {
    let empty = IssueView {
        kind: 3,
        source: 0,
        members: std::ptr::null(),
        count: 0,
    };
    if handle.is_null() {
        return empty;
    }
    let Some(issue) = (unsafe { &*handle }).issues.get(index) else {
        return empty;
    };
    IssueView {
        kind: issue.kind,
        source: issue.source,
        members: issue.members.as_ptr(),
        count: issue.members.len(),
    }
}
/// # Safety
/// Free a live handle exactly once; null is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_validation_destroy(handle: *mut Validation) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}
fn standard(code: u16, modifiers: u8) -> Key {
    Key {
        code,
        physical: 0,
        modifiers,
    }
}
fn tiling(key: Key) -> bool {
    (123..=126).contains(&key.code) && key.modifiers & 1 != 0 && key.modifiers & !7 == 0
}
/// # Safety
/// Branch must be readable for count keys, or null with count zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_menu_include(
    key: Key,
    top: isize,
    branch: *const Key,
    count: usize,
) -> u8 {
    if top <= 1 || (count != 0 && branch.is_null()) {
        return 0;
    }
    let branch = if count == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(branch, count) }
    };
    let edit = [
        standard(7, 8),
        standard(8, 8),
        standard(9, 8),
        standard(0, 8),
    ];
    if edit.iter().filter(|k| branch.contains(k)).count() >= 3 {
        return u8::from(
            key.code != 128
                && !edit.contains(&key)
                && key != standard(6, 8)
                && key != standard(6, 12),
        );
    }
    if branch.contains(&standard(46, 8))
        && (branch.contains(&standard(13, 8))
            || branch.contains(&standard(3, 9))
            || branch.iter().copied().any(tiling))
    {
        let window = [
            standard(13, 8),
            standard(13, 10),
            standard(46, 8),
            standard(46, 10),
            standard(3, 9),
        ];
        return u8::from(!window.contains(&key) && !tiling(key));
    }
    1
}

#[cfg(test)]
mod execution_tests {
    use super::*;
    #[test]
    fn duplicate_uuid_membership_and_invalid_buffers() {
        unsafe {
            let mut rules = [
                Rule {
                    source: standard(1, 8),
                    enabled: 1,
                    ..Rule::default()
                },
                Rule {
                    source: standard(2, 8),
                    enabled: 0,
                    ..Rule::default()
                },
            ];
            let ids = [Uuid { bytes: [1; 16] }; 2];
            let validation = aether_shortcut_validate(rules.as_ptr(), rules.len());
            let mut flags = [99; 2];
            assert_eq!(
                aether_shortcut_execution_flags(
                    validation,
                    rules.as_ptr(),
                    ids.as_ptr(),
                    2,
                    flags.as_mut_ptr(),
                    1
                ),
                0
            );
            assert_eq!(flags, [99, 99]);
            assert_eq!(
                aether_shortcut_execution_flags(
                    validation,
                    rules.as_ptr(),
                    ids.as_ptr(),
                    1,
                    flags.as_mut_ptr(),
                    2
                ),
                0
            );
            assert_eq!(
                aether_shortcut_execution_flags(
                    validation,
                    std::ptr::null(),
                    ids.as_ptr(),
                    2,
                    flags.as_mut_ptr(),
                    2
                ),
                0
            );
            assert_eq!(flags, [99, 99]);
            assert_eq!(
                aether_shortcut_execution_flags(
                    validation,
                    rules.as_ptr(),
                    ids.as_ptr(),
                    2,
                    flags.as_mut_ptr(),
                    2
                ),
                1
            );
            assert_eq!(flags, [3, 3]);
            aether_validation_destroy(validation);
            rules[0].source.physical = 256;
            let validation = aether_shortcut_validate(rules.as_ptr(), 2);
            assert_eq!(
                aether_shortcut_execution_flags(
                    validation,
                    rules.as_ptr(),
                    ids.as_ptr(),
                    2,
                    flags.as_mut_ptr(),
                    2
                ),
                1
            );
            assert_eq!(flags, [2, 2]);
            aether_validation_destroy(validation);
            let empty = aether_shortcut_validate(std::ptr::null(), 0);
            assert_eq!(
                aether_shortcut_execution_flags(
                    empty,
                    std::ptr::null(),
                    std::ptr::null(),
                    0,
                    std::ptr::null_mut(),
                    0
                ),
                1
            );
            aether_validation_destroy(empty);
        }
    }
    #[test]
    fn permission_and_recording_gate_both_monitoring_states() {
        for monitoring in [0, 1, 255] {
            assert_eq!(aether_shortcut_execution_mask(monitoring, 0, 0), 0);
            assert_eq!(aether_shortcut_execution_mask(monitoring, 1, 1), 0);
            assert_eq!(aether_shortcut_execution_mask(monitoring, 255, 255), 0);
            assert_eq!(
                aether_shortcut_execution_mask(monitoring, 1, 0),
                if monitoring == 0 { 1 } else { 2 }
            );
        }
    }
}
