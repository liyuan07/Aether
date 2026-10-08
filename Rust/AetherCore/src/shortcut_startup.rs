// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
//! Startup configuration sequencing. Native effects supply typed DTOs and platform preference APIs.
use std::ffi::c_void;
type Effect = unsafe extern "C" fn(*mut c_void, u8) -> i64;
/// # Safety
/// Effect/context are valid synchronously and never retained. Native effects capture nonfatal errors.
/// A failed migration save must publish stored rules and must not advance the migration version.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_shortcut_startup(
    effect: Option<Effect>,
    context: *mut c_void,
) -> u8 {
    let Some(effect) = effect else {
        return 0;
    };
    let perform = |step| unsafe { effect(context, step) };
    let recovered = perform(0) != 0;
    if !recovered || perform(1) == 0 {
        perform(2);
        perform(3);
    }
    perform(4); // Guide preferences retain their original read position.
    if recovered && perform(5) != 0 {
        perform(6); // Legacy targets from stored rules, even when migration changes the rules.
        if perform(7) < crate::shortcut_defaults::aether_shortcut_default_version() {
            perform(8);
            if perform(9) != 0 {
                perform(10);
                perform(11);
            } else {
                perform(12);
            }
        } else {
            perform(12);
        }
    } else {
        perform(13);
        if perform(14) != 0 {
            perform(10);
        }
    }
    1
}
#[cfg(test)]
mod tests {
    use super::*;
    struct State {
        recovered: bool,
        stored: bool,
        version: i64,
        saved: bool,
        calls: Vec<u8>,
    }
    unsafe extern "C" fn effect(pointer: *mut c_void, step: u8) -> i64 {
        let state = unsafe { &mut *pointer.cast::<State>() };
        state.calls.push(step);
        match step {
            0 => i64::from(state.recovered),
            1 => 1,
            5 => i64::from(state.stored),
            7 => state.version,
            9 | 14 => i64::from(state.saved),
            _ => 1,
        }
    }
    #[test]
    fn initialization_keeps_stored_rules_after_failed_upgrade_and_retries_defaults_safely() {
        for (recovered, stored, version, saved, expected) in [
            (true, true, 0, true, vec![0_u8, 1, 4, 5, 6, 7, 8, 9, 10, 11]),
            (true, true, 0, false, vec![0_u8, 1, 4, 5, 6, 7, 8, 9, 12]),
            (true, true, i64::MAX, true, vec![0_u8, 1, 4, 5, 6, 7, 12]),
            (false, false, 0, true, vec![0_u8, 2, 3, 4, 13, 14, 10]),
            (true, false, 0, false, vec![0_u8, 1, 4, 5, 13, 14]),
        ] {
            let mut state = State {
                recovered,
                stored,
                version,
                saved,
                calls: vec![],
            };
            assert_eq!(
                unsafe { aether_shortcut_startup(Some(effect), (&mut state as *mut State).cast()) },
                1
            );
            assert_eq!(state.calls, expected);
        }
    }
}
