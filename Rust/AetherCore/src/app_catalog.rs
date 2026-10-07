// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Group/order/default/legacy-seed planning using native String equality tokens.
use std::collections::HashMap;
#[repr(C)]
#[derive(Clone, Copy)]
pub struct App {
    pub initial: u64,
    pub bundle: u64,
    pub path: u64,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Group {
    pub initial: u64,
    pub default_bundle: u64,
    pub start: usize,
    pub count: usize,
    pub has_default: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Target {
    pub bundle: u64,
    pub path: u64,
    pub enabled: u8,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Info {
    pub count: usize,
    pub default_index: isize,
    pub seed_index: isize,
}
struct Row {
    indices: Vec<usize>,
    info: Info,
}
pub struct Plan {
    rows: Vec<Row>,
}
unsafe fn span<'a, T>(p: *const T, n: usize) -> Option<&'a [T]> {
    if n == 0 {
        Some(&[])
    } else if p.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(p, n) })
    }
}
/// Every input is borrowed only until return. Indices refer to the original applications.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_app_catalog_create(
    apps: *const App,
    n: usize,
    groups: *const Group,
    g: usize,
    preferences: *const u64,
    p: usize,
    targets: *const Target,
    t: usize,
) -> *mut Plan {
    let (Some(apps), Some(groups), Some(preferences), Some(targets)) = (
        unsafe { span(apps, n) },
        unsafe { span(groups, g) },
        unsafe { span(preferences, p) },
        unsafe { span(targets, t) },
    ) else {
        return std::ptr::null_mut();
    };
    if groups.iter().any(|r| {
        r.start
            .checked_add(r.count)
            .is_none_or(|end| end > preferences.len())
    }) {
        return std::ptr::null_mut();
    }
    let mut buckets: HashMap<u64, Vec<usize>> = HashMap::new();
    for (i, app) in apps.iter().enumerate() {
        buckets.entry(app.initial).or_default().push(i);
    }
    let mut rows = Vec::with_capacity(g);
    for group in groups {
        let candidates = buckets.get(&group.initial).map_or(&[][..], Vec::as_slice);
        let keys: Vec<_> = candidates.iter().map(|&i| apps[i].bundle).collect();
        let indices: Vec<_> =
            crate::app_order::ordered(&keys, &preferences[group.start..group.start + group.count])
                .into_iter()
                .map(|i| candidates[i])
                .collect();
        let default_index = if indices.len() == 1 {
            indices.first().copied()
        } else if group.has_default != 0 {
            indices
                .iter()
                .copied()
                .find(|&i| apps[i].bundle == group.default_bundle)
        } else {
            None
        };
        let seed_index = if indices.len() > 1 && group.has_default == 0 {
            targets
                .iter()
                .filter(|target| target.enabled != 0)
                .find_map(|target| {
                    indices
                        .iter()
                        .copied()
                        .find(|&i| apps[i].bundle == target.bundle || apps[i].path == target.path)
                })
        } else {
            None
        };
        let info = Info {
            count: indices.len(),
            default_index: default_index.map_or(-1, |i| i as isize),
            seed_index: seed_index.map_or(-1, |i| i as isize),
        };
        rows.push(Row { indices, info });
    }
    Box::into_raw(Box::new(Plan { rows }))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_app_catalog_info(plan: *const Plan, group: usize) -> Info {
    unsafe { plan.as_ref() }
        .and_then(|p| p.rows.get(group))
        .map_or(
            Info {
                count: 0,
                default_index: -1,
                seed_index: -1,
            },
            |r| r.info,
        )
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_app_catalog_index(
    plan: *const Plan,
    group: usize,
    index: usize,
) -> isize {
    unsafe { plan.as_ref() }
        .and_then(|p| p.rows.get(group))
        .and_then(|r| r.indices.get(index))
        .map_or(-1, |&i| i as isize)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_app_catalog_destroy(plan: *mut Plan) {
    if !plan.is_null() {
        drop(unsafe { Box::from_raw(plan) });
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owned_plan_duplicate_preferences_and_target_priority() {
        unsafe {
            let apps = vec![
                App {
                    initial: 1,
                    bundle: 10,
                    path: 100,
                },
                App {
                    initial: 1,
                    bundle: 20,
                    path: 200,
                },
                App {
                    initial: 1,
                    bundle: 10,
                    path: 300,
                },
            ];
            let groups = [Group {
                initial: 1,
                default_bundle: 0,
                start: 0,
                count: 2,
                has_default: 0,
            }];
            let prefs = [20, 20];
            let targets = [
                Target {
                    bundle: 10,
                    path: 0,
                    enabled: 0,
                },
                Target {
                    bundle: 0,
                    path: 300,
                    enabled: 1,
                },
                Target {
                    bundle: 20,
                    path: 0,
                    enabled: 1,
                },
            ];
            let plan = aether_app_catalog_create(
                apps.as_ptr(),
                apps.len(),
                groups.as_ptr(),
                1,
                prefs.as_ptr(),
                2,
                targets.as_ptr(),
                3,
            );
            drop(apps);
            let info = aether_app_catalog_info(plan, 0);
            assert_eq!(
                (info.count, info.default_index, info.seed_index),
                (3, -1, 1)
            ); // Duplicate bundle 10 keeps first path 100; path 300 is unavailable after ordering.
            // The next enabled target matches bundle 20.
            assert_eq!(info.seed_index, 1);
            assert_eq!(aether_app_catalog_index(plan, 0, 0), 1);
            assert_eq!(aether_app_catalog_index(plan, 0, 1), 1);
            assert_eq!(aether_app_catalog_index(plan, 0, 2), 0);
            assert_eq!(aether_app_catalog_index(plan, 0, 3), -1);
            aether_app_catalog_destroy(plan);
        }
    }
    #[test]
    fn invalid_ranges_and_null_access() {
        unsafe {
            let group = Group {
                initial: 1,
                default_bundle: 0,
                start: usize::MAX,
                count: 1,
                has_default: 0,
            };
            let nil = std::ptr::null();
            assert!(
                aether_app_catalog_create(nil, 0, &group, 1, nil.cast(), 0, nil.cast(), 0)
                    .is_null()
            );
            assert!(
                aether_app_catalog_create(nil, 1, nil.cast(), 0, nil.cast(), 0, nil.cast(), 0)
                    .is_null()
            );
            assert_eq!(aether_app_catalog_info(nil.cast(), 0).default_index, -1);
            assert_eq!(aether_app_catalog_index(nil.cast(), 0, 0), -1);
            aether_app_catalog_destroy(std::ptr::null_mut());
        }
    }
}
